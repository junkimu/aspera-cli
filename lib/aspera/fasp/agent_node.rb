# frozen_string_literal: true

require 'aspera/fasp/agent_base'
require 'aspera/fasp/transfer_spec'
require 'aspera/node'
require 'aspera/log'
require 'tty-spinner'

module Aspera
  module Fasp
    # this singleton class is used by the CLI to provide a common interface to start a transfer
    # before using it, the use must set the `node_api` member.
    class AgentNode < Aspera::Fasp::AgentBase
      # option include: root_id if the node is an access key
      attr_writer :options

      def initialize(options)
        raise 'node specification must be Hash' unless options.is_a?(Hash)
        %i[url username password].each { |k| raise "missing parameter [#{k}] in node specification: #{options}" unless options.key?(k) }
        super()
        # root id is required for access key
        @root_id = options[:root_id]
        rest_params = { base_url: options[:url]}
        if /^Bearer /.match?(options[:password])
          rest_params[:headers] = {
            Aspera::Node::HEADER_X_ASPERA_ACCESS_KEY => options[:username],
            'Authorization'                          => options[:password]
          }
          raise 'root_id is required for access key' if @root_id.nil?
        else
          rest_params[:auth] = {
            type:     :basic,
            username: options[:username],
            password: options[:password]
          }
        end
        @node_api = Rest.new(rest_params)
        # TODO: currently only supports one transfer. This is bad shortcut. but ok for CLI.
        @transfer_id = nil
      end

      # used internally to ensure node api is set before using.
      def node_api_
        raise StandardError, 'Before using this object, set the node_api attribute to a Aspera::Rest object' if @node_api.nil?
        return @node_api
      end
      # use this to read the node_api end point.
      attr_reader :node_api

      # use this to set the node_api end point before using the class.
      def node_api=(new_value)
        if !@node_api.nil? && !new_value.nil?
          Log.log.warn('overriding existing node api value')
        end
        @node_api = new_value
      end

      # generic method
      def start_transfer(transfer_spec)
        # add root id if access key
        if !@root_id.nil?
          case transfer_spec['direction']
          when Fasp::TransferSpec::DIRECTION_SEND then transfer_spec['source_root_id'] = @root_id
          when Fasp::TransferSpec::DIRECTION_RECEIVE then transfer_spec['destination_root_id'] = @root_id
          else raise "unexpected direction in ts: #{transfer_spec['direction']}"
          end
        end
        # manage special additional parameter
        if transfer_spec.key?('EX_ssh_key_paths') && transfer_spec['EX_ssh_key_paths'].is_a?(Array) && !transfer_spec['EX_ssh_key_paths'].empty?
          # not standard, so place standard field
          if transfer_spec.key?('ssh_private_key')
            Log.log.warn('Both ssh_private_key and EX_ssh_key_paths are present, using ssh_private_key')
          else
            Log.log.warn('EX_ssh_key_paths has multiple keys, using first one only') unless transfer_spec['EX_ssh_key_paths'].length.eql?(1)
            transfer_spec['ssh_private_key'] = File.read(transfer_spec['EX_ssh_key_paths'].first)
            transfer_spec.delete('EX_ssh_key_paths')
          end
        end
        if transfer_spec['tags'].is_a?(Hash) && transfer_spec['tags']['aspera'].is_a?(Hash)
          transfer_spec['tags']['aspera']['xfer_retry'] ||= 150
        end
        # Optimisation in case of sending to the same node (TODO: probably remove this, as /etc/hosts shall be used for that)
        if !transfer_spec['wss_enabled'] && transfer_spec['remote_host'].eql?(URI.parse(node_api_.params[:base_url]).host)
          transfer_spec['remote_host'] = '127.0.0.1'
        end
        resp = node_api_.create('ops/transfers', transfer_spec)[:data]
        @transfer_id = resp['id']
        Log.log.debug{"tr_id=#{@transfer_id}"}
        return @transfer_id
      end

      # generic method
      def wait_for_transfers_completion
        started = false
        spinner = nil
        # lets emulate management events to display progress bar
        loop do
          # status is empty sometimes with status 200...
          transfer_data = node_api_.read("ops/transfers/#{@transfer_id}")[:data] || {'status' => 'unknown'} rescue {'status' => 'waiting(read error)'}
          case transfer_data['status']
          when 'completed'
            notify_end(@transfer_id)
            break
          when 'waiting', 'partially_completed', 'unknown', 'waiting(read error)'
            if spinner.nil?
              spinner = TTY::Spinner.new('[:spinner] :title', format: :classic)
              spinner.start
            end
            spinner.update(title: transfer_data['status'])
            spinner.spin
          when 'running'
            if !started && transfer_data['precalc'].is_a?(Hash) &&
                transfer_data['precalc']['status'].eql?('ready')
              notify_begin(@transfer_id, transfer_data['precalc']['bytes_expected'])
              started = true
            else
              notify_progress(@transfer_id, transfer_data['bytes_transferred'])
            end
          else
            Log.log.warn{"transfer_data -> #{transfer_data}"}
            raise Fasp::Error, "#{transfer_data['status']}: #{transfer_data['error_desc']}"
          end
          sleep(1)
        end
        # TODO: get status of sessions
        return []
      end
    end
  end
end
