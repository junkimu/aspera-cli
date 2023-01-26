# frozen_string_literal: true

require 'English'
require 'aspera/cli/plugin'
require 'aspera/sync'
require 'aspera/log'
require 'open3'

module Aspera
  module Cli
    module Plugins
      # Execute Aspera Sync
      class Sync < Aspera::Cli::Plugin
        def initialize(env, transfer_spec: nil)
          super(env)
          options.add_opt_simple(:sync_info, 'Information for sync instance and sessions (Hash)')
          options.add_opt_simple(:sync_session, 'Name of session to use for admin commands. default: first in parameters')
          options.parse_options!
          return if env[:man_only]
          @params = options.get_option(:sync_info, is_type: :mandatory)
          Aspera::Sync.update_parameters_with_transfer_spec(@params, transfer_spec) unless transfer_spec.nil?
        end

        ACTIONS = %i[start admin].freeze

        def execute_action
          command = options.get_next_command(ACTIONS)
          case command
          when :start
            Aspera::Sync.new(@params).start
            return Main.result_success
          when :admin
            sync_admin = Aspera::SyncAdmin.new(@params, options.get_option(:sync_session))
            command2 = options.get_next_command([:status])
            case command2
            when :status
              return {type: :single_object, data: sync_admin.status}
            end # command2
          end # command
        end # execute_action
      end # Sync
    end # Plugins
  end # Cli
end # Aspera
