# frozen_string_literal: true

require 'aspera/fasp/agent_base'
require 'aspera/fasp/transfer_spec'
require 'aspera/cli/info'

module Aspera
  module Cli
    # The Transfer agent is a common interface to start a transfer using
    # one of the supported transfer agents
    # provides CLI options to select one of the transfer agents (FASP/ascp client)
    class TransferAgent
      # special value for --sources : read file list from arguments
      FILE_LIST_FROM_ARGS = '@args'
      # special value for --sources : read file list from transfer spec (--ts)
      FILE_LIST_FROM_TRANSFER_SPEC = '@ts'
      FILE_LIST_OPTIONS = [FILE_LIST_FROM_ARGS, FILE_LIST_FROM_TRANSFER_SPEC, 'Array'].freeze
      DEFAULT_TRANSFER_NOTIFY_TEMPLATE = <<~END_OF_TEMPLATE
        From: <%=from_name%> <<%=from_email%>>
        To: <<%=to%>>
        Subject: <%=subject%>

        Transfer is: <%=global_transfer_status%>

        <%=ts.to_yaml%>
      END_OF_TEMPLATE
      # % (formatting bug in eclipse)
      private_constant :FILE_LIST_FROM_ARGS,
        :FILE_LIST_FROM_TRANSFER_SPEC,
        :FILE_LIST_OPTIONS,
        :DEFAULT_TRANSFER_NOTIFY_TEMPLATE
      TRANSFER_AGENTS = Fasp::AgentBase.agent_list.freeze

      class << self
        # @return :success if all sessions statuses returned by "start" are success
        # else return the first error exception object
        def session_status(statuses)
          error_statuses = statuses.reject{|i|i.eql?(:success)}
          return :success if error_statuses.empty?
          return error_statuses.first
        end
      end

      # @param env external objects: option manager, config file manager
      def initialize(opt_mgr, config_plugin)
        @opt_mgr = opt_mgr
        @config = config_plugin
        # command line can override transfer spec
        @transfer_spec_command_line = {'create_dir' => true}
        # options for transfer agent
        @transfer_info = {}
        # the currently selected transfer agent
        @agent = nil
        # source/destination pair, like "paths" of transfer spec
        @transfer_paths = nil
        @opt_mgr.declare(:ts, 'Override transfer spec values', types: Hash, handler: {o: self, m: :option_transfer_spec})
        @opt_mgr.declare(:to_folder, 'Destination folder for transferred files')
        @opt_mgr.declare(:sources, "How list of transferred files is provided (#{FILE_LIST_OPTIONS.join(',')})")
        @opt_mgr.declare(:src_type, 'Type of file list', values: %i[list pair], default: :list)
        @opt_mgr.declare(:transfer, 'Type of transfer agent', values: TRANSFER_AGENTS, default: :direct)
        @opt_mgr.declare(:transfer_info, 'Parameters for transfer agent', types: Hash, handler: {o: self, m: :transfer_info})
        @opt_mgr.parse_options!
      end

      def option_transfer_spec; @transfer_spec_command_line; end

      # multiple option are merged
      def option_transfer_spec=(value)
        raise 'option ts shall be a Hash' unless value.is_a?(Hash)
        @transfer_spec_command_line.deep_merge!(value)
      end

      # add other transfer spec parameters
      def option_transfer_spec_deep_merge(ts); @transfer_spec_command_line.deep_merge!(ts); end

      # @return [Hash] transfer spec with updated values from command line, including removed values
      def updated_ts(transfer_spec={})
        transfer_spec.deep_merge!(@transfer_spec_command_line)
        # recursively remove values that are nil (user wants to delete)
        transfer_spec.deep_do { |hash, key, value, _unused| hash.delete(key) if value.nil?}
        return transfer_spec
      end

      attr_reader :transfer_info

      # multiple option are merged
      def transfer_info=(value)
        @transfer_info.deep_merge!(value)
      end

      def agent_instance=(instance)
        @agent = instance
      end

      # analyze options and create new agent if not already created or set
      def set_agent_by_options
        return nil unless @agent.nil?
        agent_type = @opt_mgr.get_option(:transfer, mandatory: true)
        # agent plugin is loaded on demand to avoid loading unnecessary dependencies
        require "aspera/fasp/agent_#{agent_type}"
        # set keys as symbols
        agent_options = @opt_mgr.get_option(:transfer_info).symbolize_keys
        # special cases
        case agent_type
        when :node
          if agent_options.empty?
            param_set_name = @config.get_plugin_default_config_name(:node)
            raise Cli::BadArgument, "No default node configured. Please specify #{Manager.option_name_to_line(:transfer_info)}" if param_set_name.nil?
            agent_options = @config.preset_by_name(param_set_name).symbolize_keys
          end
        when :direct
          # by default do not display ascp native progress bar
          agent_options[:quiet] = true unless agent_options.key?(:quiet)
          agent_options[:check_ignore] = ->(host, port){@config.ignore_cert?(host, port)}
          agent_options[:trusted_certs] = @config.trusted_cert_locations(files_only: true) unless agent_options.key?(:trusted_certs)
        end
        agent_options[:progress] = @config.progress_bar
        # get agent instance
        new_agent = Kernel.const_get("Aspera::Fasp::Agent#{agent_type.capitalize}").new(agent_options)
        self.agent_instance = new_agent
        return nil
      end

      # return destination folder for transfers
      # sets default if needed
      # param: 'send' or 'receive'
      def destination_folder(direction)
        dest_folder = @opt_mgr.get_option(:to_folder)
        # do not expand path, if user wants to expand path: user @path:
        return dest_folder unless dest_folder.nil?
        dest_folder = @transfer_spec_command_line['destination_root']
        return dest_folder unless dest_folder.nil?
        # default: / on remote, . on local
        case direction.to_s
        when Fasp::TransferSpec::DIRECTION_SEND then dest_folder = '/'
        when Fasp::TransferSpec::DIRECTION_RECEIVE then dest_folder = '.'
        else raise "wrong direction: #{direction}"
        end
        return dest_folder
      end

      # @return [Array] list of source files
      def source_list
        return ts_source_paths.map do |i|
          i['source']
        end
      end

      # This is how the list of files to be transferred is specified
      # get paths suitable for transfer spec from command line
      # @return [Hash] {source: (mandatory), destination: (optional)}
      # computation is done only once, cache is kept in @transfer_paths
      def ts_source_paths
        # return cache if set
        return @transfer_paths unless @transfer_paths.nil?
        # start with lower priority : get paths from transfer spec on command line
        @transfer_paths = @transfer_spec_command_line['paths'] if @transfer_spec_command_line.key?('paths')
        # is there a source list option ?
        file_list = @opt_mgr.get_option(:sources)
        case file_list
        when nil, FILE_LIST_FROM_ARGS
          Log.log.debug('getting file list as parameters')
          # get remaining arguments
          file_list = @opt_mgr.get_next_argument('source file list', expected: :multiple)
          raise Cli::BadArgument, 'specify at least one file on command line or use ' \
            "--sources=#{FILE_LIST_FROM_TRANSFER_SPEC} to use transfer spec" if !file_list.is_a?(Array) || file_list.empty?
        when FILE_LIST_FROM_TRANSFER_SPEC
          Log.log.debug('assume list provided in transfer spec')
          special_case_direct_with_list =
            @opt_mgr.get_option(:transfer, mandatory: true).eql?(:direct) &&
            Fasp::Parameters.ts_has_ascp_file_list(@transfer_spec_command_line, @opt_mgr.get_option(:transfer_info))
          raise Cli::BadArgument, 'transfer spec on command line must have sources' if @transfer_paths.nil? && !special_case_direct_with_list
          # here we assume check of sources is made in transfer agent
          return @transfer_paths
        when Array
          Log.log.debug('getting file list as extended value')
          raise Cli::BadArgument, 'sources must be a Array of String' if !file_list.reject{|f|f.is_a?(String)}.empty?
        else
          raise Cli::BadArgument, "sources must be a Array, not #{file_list.class}"
        end
        # here, file_list is an Array or String
        if !@transfer_paths.nil?
          Log.log.warn('--sources overrides paths from --ts')
        end
        case @opt_mgr.get_option(:src_type, mandatory: true)
        when :list
          # when providing a list, just specify source
          @transfer_paths = file_list.map{|i|{'source' => i}}
        when :pair
          raise Cli::BadArgument, "When using pair, provide an even number of paths: #{file_list.length}" unless file_list.length.even?
          @transfer_paths = file_list.each_slice(2).to_a.map{|s, d|{'source' => s, 'destination' => d}}
        else raise 'Unsupported src_type'
        end
        Log.log.debug{"paths=#{@transfer_paths}"}
        return @transfer_paths
      end

      # start a transfer and wait for completion, plugins shall use this method
      # @param transfer_spec [Hash]
      # @param rest_token [Rest] if oauth token regeneration supported
      def start(transfer_spec, rest_token: nil)
        # check parameters
        raise 'transfer_spec must be hash' unless transfer_spec.is_a?(Hash)
        # process :src option
        case transfer_spec['direction']
        when Fasp::TransferSpec::DIRECTION_RECEIVE
          # init default if required in any case
          @transfer_spec_command_line['destination_root'] ||= destination_folder(transfer_spec['direction'])
        when Fasp::TransferSpec::DIRECTION_SEND
          if transfer_spec.dig('tags', Fasp::TransferSpec::TAG_RESERVED, 'node', 'access_key')
            # gen4
            @transfer_spec_command_line.delete('destination_root') if @transfer_spec_command_line.key?('destination_root_id')
          elsif transfer_spec.key?('token')
            # gen3
            # in that case, destination is set in return by application (API/upload_setup)
            # but to_folder was used in initial API call
            @transfer_spec_command_line.delete('destination_root')
          else
            # init default if required
            @transfer_spec_command_line['destination_root'] ||= destination_folder(transfer_spec['direction'])
          end
        end
        # update command line paths, unless destination already has one
        @transfer_spec_command_line['paths'] = transfer_spec['paths'] || ts_source_paths
        # updated transfer spec with command line
        updated_ts(transfer_spec)
        # create transfer agent
        set_agent_by_options
        Log.log.debug{"transfer agent is a #{@agent.class}"}
        @agent.start_transfer(transfer_spec, token_regenerator: rest_token)
        # list of: :success or "error message string"
        result = @agent.wait_for_completion
        send_email_transfer_notification(transfer_spec, result)
        return result
      end

      def send_email_transfer_notification(transfer_spec, statuses)
        return if @opt_mgr.get_option(:notify_to).nil?
        global_status = self.class.session_status(statuses)
        email_vars = {
          global_transfer_status: global_status,
          subject:                "#{PROGRAM_NAME} transfer: #{global_status}",
          body:                   "Transfer is: #{global_status}",
          ts:                     transfer_spec
        }
        @config.send_email_template(email_template_default: DEFAULT_TRANSFER_NOTIFY_TEMPLATE, values: email_vars)
      end

      # shut down if agent requires it
      def shutdown
        @agent.shutdown if @agent.respond_to?(:shutdown)
      end
    end
  end
end
