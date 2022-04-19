# frozen_string_literal: true

module Aspera
  module Cli
    # base class for plugins modules
    class Plugin
      # operation without id
      GLOBAL_OPS = %i[create list].freeze
      # operation on specific instance
      INSTANCE_OPS = %i[modify delete show].freeze
      ALL_OPS = [GLOBAL_OPS,INSTANCE_OPS].flatten.freeze
      # max number of items for list command
      MAX_ITEMS = 'max'
      # max number of pages for list command
      MAX_PAGES = 'pmax'

      # global for inherited classes
      @@options_created = false # rubocop:disable Style/ClassVars

      def initialize(env)
        @agents = env
        # check presence in descendant of mandatory method and constant
        raise StandardError,"missing method 'execute_action' in #{self.class}" unless respond_to?(:execute_action)
        raise StandardError,'ACTIONS shall be redefined by subclass' unless self.class.constants.include?(:ACTIONS)
        options.parser.separator('')
        options.parser.separator("COMMAND: #{self.class.name.split('::').last.downcase}")
        options.parser.separator("SUBCOMMANDS: #{self.class.const_get(:ACTIONS).map(&:to_s).join(' ')}")
        options.parser.separator('OPTIONS:')
        return if @@options_created
        options.add_opt_simple(:value,'extended value for create, update, list filter')
        options.add_opt_simple(:property,'name of property to set')
        options.add_opt_simple(:id,"resource identifier (#{INSTANCE_OPS.join(',')})")
        options.parse_options!
        @@options_created = true # rubocop:disable Style/ClassVars
      end

      # must be called AFTER the instance action
      def instance_identifier
        res_id = options.get_option(:id)
        res_id = options.get_next_argument('identifier') if res_id.nil?
        return res_id
      end

      # TODO
      def get_next_id_command(instance_ops: INSTANCE_OPS,global_ops: GLOBAL_OPS)
        return get_next_argument('command',expected: command_list)
      end

      # @param command [Symbol] command to execute: create show list modify delete
      # @param rest_api [Rest] api to use
      # @param res_class_path [String] sub path in URL to resource relative to base url
      # @param display_fields [Array] fields to display by default
      # @param id_default [String] default identifier to use for existing entity commands (show, modify)
      # @param use_subkey [bool] true if the result is in a subkey of the json
      def entity_command(command,rest_api,res_class_path,display_fields: nil,id_default: nil,use_subkey: false)
        if INSTANCE_OPS.include?(command)
          begin
            one_res_id = instance_identifier
          rescue StandardError => e
            raise e if id_default.nil?
            one_res_id = id_default
          end
          one_res_path = "#{res_class_path}/#{one_res_id}"
        end
        # parameters mandatory for create/modify
        if %i[create modify].include?(command)
          parameters = options.get_option(:value,is_type: :mandatory)
        end
        # parameters optional for list
        if [:list].include?(command)
          parameters = options.get_option(:value)
        end
        case command
        when :create
          return {type: :single_object, data: rest_api.create(res_class_path,parameters)[:data], fields: display_fields}
        when :show
          return {type: :single_object, data: rest_api.read(one_res_path)[:data], fields: display_fields}
        when :list
          resp = rest_api.read(res_class_path,parameters)
          data = resp[:data]
          # TODO: not generic : which application is this for ?
          if resp[:http]['Content-Type'].start_with?('application/vnd.api+json')
            data = data[res_class_path]
          end
          data = data[res_class_path] if use_subkey
          return {type: :object_list, data: data, fields: display_fields}
        when :modify
          property = options.get_option(:property)
          parameters = {property => parameters} unless property.nil?
          rest_api.update(one_res_path,parameters)
          return Main.result_status('modified')
        when :delete
          rest_api.delete(one_res_path)
          return Main.result_status('deleted')
        else
          raise "unknown action: #{command}"
        end
      end

      # implement generic rest operations on given resource path
      def entity_action(rest_api,res_class_path,**opts)
        #res_name=res_class_path.gsub(%r{^.*/},'').gsub(%r{s$},'').gsub('_',' ')
        command = options.get_next_command(ALL_OPS)
        return entity_command(command,rest_api,res_class_path,**opts)
      end

      # shortcuts for plugin environment
      def options; return @agents[:options];end

      def transfer; return @agents[:transfer];end

      def config; return @agents[:config];end

      def format; return @agents[:formater];end

      def persistency; return @agents[:persistency];end
    end # Plugin
  end # Cli
end # Aspera
