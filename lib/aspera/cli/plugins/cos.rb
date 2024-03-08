# frozen_string_literal: true

require 'aspera/cli/plugin'
require 'aspera/cli/plugins/node'
require 'aspera/cos_node'
require 'aspera/assert'

module Aspera
  module Cli
    module Plugins
      class Cos < Aspera::Cli::Plugin
        def initialize(env)
          super(env)
          options.declare(:bucket, 'Bucket name')
          options.declare(:endpoint, 'Storage endpoint (URL)')
          options.declare(:apikey, 'Storage API key')
          options.declare(:crn, 'Resource instance id (CRN)')
          options.declare(:service_credentials, 'IBM Cloud service credentials', types: Hash)
          options.declare(:region, 'Storage region')
          options.declare(:identity, "Authentication URL (#{CosNode::IBM_CLOUD_TOKEN_URL})", default: CosNode::IBM_CLOUD_TOKEN_URL)
          options.parse_options!
        end

        ACTIONS = %i[node].freeze

        def execute_action
          command = options.get_next_command(ACTIONS)
          case command
          when :node
            # get service credentials, Hash, e.g. @json:@file:...
            service_credentials = options.get_option(:service_credentials)
            cos_node_params = {
              auth_url: options.get_option(:identity, mandatory: true),
              bucket:   options.get_option(:bucket, mandatory: true),
              endpoint: options.get_option(:endpoint)
            }
            if service_credentials.nil?
              assert(!cos_node_params[:endpoint].nil?, exception_class: Cli::BadArgument){'endpoint required when service credentials not provided'}
              cos_node_params[:api_key] = options.get_option(:apikey, mandatory: true)
              cos_node_params[:instance_id] = options.get_option(:crn, mandatory: true)
            else
              assert(cos_node_params[:endpoint].nil?, exception_class: Cli::BadArgument){'endpoint not allowed when service credentials provided'}
              cos_node_params.merge!(CosNode.parameters_from_svc_credentials(service_credentials, options.get_option(:region, mandatory: true)))
            end
            api_node = CosNode.new(**cos_node_params)
            node_plugin = Node.new(@agents, api: api_node)
            command = options.get_next_command(Node::COMMANDS_COS)
            return node_plugin.execute_action(command)
          end
        end
      end
    end
  end
end
