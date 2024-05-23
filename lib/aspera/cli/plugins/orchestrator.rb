# frozen_string_literal: true

require 'aspera/cli/basic_auth_plugin'
require 'aspera/nagios'
require 'aspera/log'
require 'aspera/assert'
require 'xmlsimple'

module Aspera
  module Cli
    module Plugins
      class Orchestrator < Cli::BasicAuthPlugin
        class << self
          STANDARD_PATH = '/aspera/orchestrator'
          def detect(address_or_url)
            address_or_url = "https://#{address_or_url}" unless address_or_url.match?(%r{^[a-z]{1,6}://})
            urls = [address_or_url]
            urls.push("#{address_or_url}#{STANDARD_PATH}") unless address_or_url.end_with?(STANDARD_PATH)
            error = nil
            urls.each do |base_url|
              next unless base_url.match?('https?://')
              api = Rest.new(base_url: base_url)
              test_endpoint = 'api/remote_node_ping'
              result = api.read(test_endpoint, {format: :json})
              next unless result[:data]['remote_orchestrator_info']
              url = result[:http].uri.to_s
              return {
                version: result[:data]['remote_orchestrator_info']['orchestrator-version'],
                url:     url[0..url.index(test_endpoint) - 2]
              }
            rescue StandardError => e
              error = e
              Log.log.debug{"detect error: #{e}"}
            end
            raise error if error
            return nil
          end

          def wizard(object:, private_key_path: nil, pub_key_pem: nil)
            options = object.options
            return {
              preset_value: {
                url:      options.get_option(:url, mandatory: true),
                username: options.get_option(:username, mandatory: true),
                password: options.get_option(:password, mandatory: true)
              },
              test_args:    'workflow list'
            }
          end
        end

        def initialize(**env)
          super
          options.declare(:result, "Specify result value as: 'work_step:parameter'")
          options.declare(:synchronous, 'Wait for completion', values: :bool, default: :no)
          options.declare(:ret_style, 'How return type is requested in api', values: %i[header arg ext], default: :arg)
          options.declare(:auth_style, 'Authentication type', values: %i[arg_pass head_basic apikey], default: :head_basic)
          options.parse_options!
        end

        ACTIONS = %i[health info workflow plugins processes].freeze

        # call orchestrator api
        # @param endpoint [String] the endpoint to call
        # @param prefix [String] the prefix to add to the endpoint
        # @param id [String] the id to add to the endpoint
        # @param ret_style [Symbol] the return style, :header, :arg, :ext(extension)
        # @param format [String] the format to request, 'json', 'xml', nil
        # @param args [Hash] the arguments to pass
        # @param xml_arrays [Boolean] if true, force arrays in xml parsing
        def call_ao(endpoint, prefix: 'api', id: nil, ret_style: nil, format: 'json', args: nil, xml_arrays: true)
          # calls are GET
          call_args = {operation: 'GET', subpath: endpoint}
          # specify prefix if necessary
          call_args[:subpath] = "#{prefix}/#{call_args[:subpath]}" unless prefix.nil?
          # specify id if necessary
          call_args[:subpath] = "#{call_args[:subpath]}/#{id}" unless id.nil?
          ret_style = options.get_option(:ret_style, mandatory: true) if ret_style.nil?
          call_args[:query] = args unless args.nil?
          unless format.nil?
            case ret_style
            when :header
              call_args[:headers] = {'Accept' => "application/#{format}" }
            when :arg
              call_args[:query] ||= {}
              call_args[:query][:format] = format
            when :ext
              call_args[:subpath] = "#{call_args[:subpath]}.#{format}"
            else Aspera.error_unexpected_value(ret_style)
            end
          end
          result = @api_orch.call(**call_args)
          result[:data] = XmlSimple.xml_in(result[:http].body, {'ForceArray' => xml_arrays}) if format.eql?('xml')
          Log.log.debug{Log.dump(:data, result[:data])}
          return result
        end

        def execute_action
          auth_params =
            case options.get_option(:auth_style, mandatory: true)
            when :arg_pass
              {
                type:      :url,
                url_query: {
                  'login'    => options.get_option(:username, mandatory: true),
                  'password' => options.get_option(:password, mandatory: true) }
              }
            when :head_basic
              {
                type:     :basic,
                username: options.get_option(:username, mandatory: true),
                password: options.get_option(:password, mandatory: true)
              }
            when :apikey
              raise 'Not implemented'
            end

          @api_orch = Rest.new(
            base_url: options.get_option(:url, mandatory: true),
            auth: auth_params
          )

          command1 = options.get_next_command(ACTIONS)
          case command1
          when :health
            nagios = Nagios.new
            begin
              info = call_ao('remote_node_ping', format: 'xml', xml_arrays: false)[:data]
              nagios.add_ok('api', 'accessible')
              nagios.check_product_version('api', 'orchestrator', info['orchestrator-version'])
            rescue StandardError => e
              nagios.add_critical('node api', e.to_s)
            end
            return nagios.result
          when :info
            result = call_ao('remote_node_ping', format: 'xml', xml_arrays: false)[:data]
            return {type: :single_object, data: result}
          when :processes
            # TODO: Bug ? API has only XML format
            result = call_ao('processes_status', format: 'xml')[:data]
            return {type: :object_list, data: result['process']}
          when :plugins
            # TODO: Bug ? only json format on url
            result = call_ao('plugin_version')[:data]
            return {type: :object_list, data: result['Plugin']}
          when :workflow
            command = options.get_next_command(%i[list status inputs details start export])
            unless [:list].include?(command)
              wf_id = instance_identifier
            end
            case command
            when :status
              wf_id = nil if wf_id.eql?(ExtendedValue::ALL)
              result = call_ao('workflows_status', id: wf_id)[:data]
              return {type: :object_list, data: result['workflows']['workflow']}
            when :list
              result = call_ao('workflows_list', id: 0)[:data]
              return {
                type:   :object_list,
                data:   result['workflows']['workflow'],
                fields: %w[id portable_id name published_status published_revision_id latest_revision_id last_modification]
              }
            when :details
              result = call_ao('workflow_details', id: wf_id)[:data]
              return {type: :object_list, data: result['workflows']['workflow']['statuses']}
            when :inputs
              result = call_ao('workflow_inputs_spec', id: wf_id)[:data]
              return {type: :single_object, data: result['workflow_inputs_spec']}
            when :export
              result = call_ao('export_workflow', id: wf_id, format: nil)[:http]
              return {type: :text, data: result.body}
            when :start
              result = {
                type: :single_object,
                data: nil
              }
              call_params = {format: :json}
              # get external parameters if any
              options.get_next_argument('external_parameters', mandatory: false, type: Hash, default: {}).each do |name, value|
                call_params["external_parameters[#{name}]"] = value
              end
              # synchronous call ?
              call_params['synchronous'] = true if options.get_option(:synchronous, mandatory: true)
              # expected result for synchro call ?
              result_location = options.get_option(:result)
              unless result_location.nil?
                result[:type] = :status
                fields = result_location.split(':')
                raise Cli::BadArgument, "Expects: work_step:result_name : #{result_location}" if fields.length != 2
                call_params['explicit_output_step'] = fields[0]
                call_params['explicit_output_variable'] = fields[1]
                # implicitly, call is synchronous
                call_params['synchronous'] = true
              end
              if call_params['synchronous']
                result[:type] = :text
              end
              result[:data] = call_ao('initiate', id: wf_id, args: call_params)[:data]
              return result
            end
          else Aspera.error_unexpected_value(command)
          end
        end
        private :call_ao
      end
    end
  end
end
