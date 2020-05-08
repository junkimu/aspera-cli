require 'asperalm/fasp/local'
require 'asperalm/fasp/connect'
require 'asperalm/fasp/node'
require 'asperalm/fasp/aoc'
require 'asperalm/fasp/http_gw'
require 'asperalm/cli/listener/logger'
require 'asperalm/cli/listener/progress_multi'

module Asperalm
  module Cli
    # The Transfer agent is a common interface to start a transfer using
    # one of the supported transfer agents
    # provides CLI options to select one of the transfer agents (fasp client)
    class TransferAgent
      # special value for --sources : read file list from arguments
      FILE_LIST_FROM_ARGS='@args'
      # special value for --sources : read file list from transfer spec (--ts)
      FILE_LIST_FROM_TRANSFER_SPEC='@ts'
      private_constant :FILE_LIST_FROM_ARGS,:FILE_LIST_FROM_TRANSFER_SPEC
      # @param cli_objects external objects: option manager, config file manager
      def initialize(cli_objects)
        @opt_mgr=cli_objects[:options]
        @config=cli_objects[:config]
        # transfer spec overrides provided on command line
        @transfer_spec_cmdline={}
        # the currently selected transfer agent
        @agent=nil
        # source/destination pair, like "paths" of transfer spec
        @transfer_paths=nil
        @opt_mgr.set_obj_attr(:ts,self,:option_transfer_spec)
        @opt_mgr.set_obj_attr(:local_resume,Fasp::Local.instance,:resume_policy_parameters)
        @opt_mgr.add_opt_simple(:ts,"override transfer spec values (Hash, use @json: prefix), current=#{@opt_mgr.get_option(:ts,:optional)}")
        @opt_mgr.add_opt_simple(:local_resume,"set resume policy (Hash, use @json: prefix), current=#{@opt_mgr.get_option(:local_resume,:optional)}")
        @opt_mgr.add_opt_simple(:to_folder,"destination folder for downloaded files")
        @opt_mgr.add_opt_simple(:sources,"list of source files (see doc)")
        @opt_mgr.add_opt_simple(:transfer_info,"additional information for transfer client")
        @opt_mgr.add_opt_list(:src_type,[:list,:pair],"type of file list")
        @opt_mgr.add_opt_list(:transfer,[:direct,:httpgw,:connect,:node,:aoc],"type of transfer")
        @opt_mgr.set_option(:transfer,:direct)
        @opt_mgr.set_option(:src_type,:list)
        @opt_mgr.parse_options!
      end

      def option_transfer_spec; @transfer_spec_cmdline; end

      def option_transfer_spec=(value); @transfer_spec_cmdline.merge!(value); end

      def option_transfer_spec_deep_merge(ts); @transfer_spec_cmdline.deep_merge!(ts); end

      # @return one of the Fasp:: agents based on parameters
      def set_agent_by_options
        if @agent.nil?
          agent_type=@opt_mgr.get_option(:transfer,:mandatory)
          case agent_type
          when :direct
            @agent=Fasp::Local.instance
            # TODO: option to choose progress format
            # a- @agent.quiet=false
            # b- disable custom progress
          when :httpgw
            httpgw_config=@opt_mgr.get_option(:transfer_info,:mandatory)
            raise CliBadArgument,"transfer_info must have url" unless httpgw_config.has_key?('url')
            @agent=Fasp::HttpGW.instance
            @agent.url=httpgw_config['url']
          when :connect
            @agent=Fasp::Connect.instance
          when :node
            @agent=Fasp::Node.instance
            # get not api only if it is not already set
            if @agent.node_api.nil?
              # way for code to setup alternate node api in avance
              # support: @preset:<name>
              # support extended values
              node_config=@opt_mgr.get_option(:transfer_info,:optional)
              # if not specified: use default node
              if node_config.nil?
                param_set_name=@config.get_plugin_default_config_name(:node)
                raise CliBadArgument,"No default node configured, Please specify --#{:transfer_info.to_s.gsub('_','-')}" if param_set_name.nil?
                node_config=@config.preset_by_name(param_set_name)
              end
              Log.log.debug("node=#{node_config}")
              raise CliBadArgument,"the node configuration shall be Hash, not #{node_config.class} (#{node_config}), use either @json:<json> or @preset:<parameter set name>" if !node_config.is_a?(Hash)
              # now check there are required parameters
              sym_config=[:url,:username,:password].inject({}) do |h,param|
                raise CliBadArgument,"missing parameter [#{param}] in node specification: #{node_config}" if !node_config.has_key?(param.to_s)
                h[param]=node_config[param.to_s]
                h
              end
              @agent.node_api=Rest.new({
                :base_url => sym_config[:url],
                :auth     => {
                :type     =>:basic,
                :username => sym_config[:username],
                :password => sym_config[:password]
                }})
            end
          when :aoc
            aoc_config=@opt_mgr.get_option(:transfer_info,:optional)
            if aoc_config.nil?
              param_set_name=@config.get_plugin_default_config_name(:aspera)
              raise CliBadArgument,"No default AoC configured, Please specify --#{:transfer_info.to_s.gsub('_','-')}" if param_set_name.nil?
              aoc_config=@config.preset_by_name(param_set_name)
            end
            Log.log.debug("aoc=#{aoc_config}")
            raise CliBadArgument,"the aoc configuration shall be Hash, not #{aoc_config.class} (#{aoc_config}), refer to manual" if !aoc_config.is_a?(Hash)
            # convert keys to symbol
            aoc_config=aoc_config.symbolize_keys
            # convert auth to symbol
            aoc_config[:auth]=aoc_config[:auth].to_sym if aoc_config[:auth].is_a?(String)
            aoc_config[:private_key]=ExtendedValue.instance.evaluate(aoc_config[:private_key])
            @agent=Fasp::Aoc.new(aoc_config)
          else raise "INTERNAL ERROR"
          end
          @agent.add_listener(Listener::Logger.new)
          @agent.add_listener(Listener::ProgressMulti.new)
        end
        return nil
      end

      # return destination folder for transfers
      # sets default if needed
      # param: 'send' or 'receive'
      def destination_folder(direction)
        dest_folder=@opt_mgr.get_option(:to_folder,:optional)
        return dest_folder unless dest_folder.nil?
        dest_folder=@transfer_spec_cmdline['destination_root']
        return dest_folder unless dest_folder.nil?
        # default: / on remote, . on local
        case direction.to_s
        when 'send';dest_folder='/'
        when 'receive';dest_folder='.'
        else raise "wrong direction: #{direction}"
        end
        return dest_folder
      end

      # This is how the list of files to be transfered is specified
      # get paths suitable for transfer spec from command line
      # @return {:source=>(mandatory), :destination=>(optional)}
      # computation is done only once, cache is kept in @transfer_paths
      def ts_source_paths
        # return cache if set
        return @transfer_paths unless @transfer_paths.nil?
        # start with lower priority : get paths from transfer spec on command line
        @transfer_paths=@transfer_spec_cmdline['paths'] if @transfer_spec_cmdline.has_key?('paths')
        # is there a source list option ?
        file_list=@opt_mgr.get_option(:sources,:optional)
        case file_list
        when nil,FILE_LIST_FROM_ARGS
          Log.log.debug("getting file list as parameters")
          # get remaining arguments
          file_list=@opt_mgr.get_next_argument("source file list",:multiple)
          raise CliBadArgument,"specify at least one file on command line or use --sources=#{FILE_LIST_FROM_TRANSFER_SPEC} to use transfer spec" if !file_list.is_a?(Array) or file_list.empty?
        when FILE_LIST_FROM_TRANSFER_SPEC
          Log.log.debug("assume list provided in transfer spec")
          raise CliBadArgument,"transfer spec on command line must have sources" if @transfer_paths.nil?
          # here we assume check of sources is made in transfer agent
          return @transfer_paths
        when Array
          Log.log.debug("getting file list as extended value")
          raise CliBadArgument,"sources must be a Array of String" if !file_list.select{|f|!f.is_a?(String)}.empty?
        else
          raise CliBadArgument,"sources must be a Array, not #{file_list.class}"
        end
        # here, file_list is an Array or String
        if !@transfer_paths.nil?
          Log.log.warn("--sources overrides paths from --ts")
        end
        case @opt_mgr.get_option(:src_type,:mandatory)
        when :list
          # when providing a list, just specify source
          @transfer_paths=file_list.map{|i|{'source'=>i}}
        when :pair
          raise CliBadArgument,"whe using pair, provide even number of paths: #{file_list.length}" unless file_list.length.even?
          @transfer_paths=file_list.each_slice(2).to_a.map{|s,d|{'source'=>s,'destination'=>d}}
        else raise "ERROR"
        end
        Log.log.debug("paths=#{@transfer_paths}")
        return @transfer_paths
      end

      # start a transfer and wait for completion, plugins shall use this method
      # @param transfer_spec
      # @param options specific options for the transfer_agent
      # options[:src] specifies how destination_root is set (how transfer spec was generated)
      # other options are carried to specific agent
      def start(transfer_spec,options)
        # check parameters
        raise "transfer_spec must be hash" unless transfer_spec.is_a?(Hash)
        raise "options must be hash" unless options.is_a?(Hash)
        # process :src option
        case transfer_spec['direction']
        when 'receive'
          # init default if required in any case
          @transfer_spec_cmdline['destination_root']=destination_folder(transfer_spec['direction'])
        when 'send'
          case options[:src]
          when :direct
            # init default if required
            @transfer_spec_cmdline['destination_root']=destination_folder(transfer_spec['direction'])
          when :node_gen3
            # in that case, destination is set in return by application (API/upload_setup)
            # but to_folder was used in intial api call
            @transfer_spec_cmdline.delete('destination_root')
          when :node_gen4
            @transfer_spec_cmdline['destination_root']='/'
          else
            raise StandardError,"InternalError: unsupported value: #{options[:src]}"
          end
        end

        # only used here
        options.delete(:src)

        # update command line paths, unless destination already has one
        @transfer_spec_cmdline['paths']=transfer_spec['paths'] || ts_source_paths

        transfer_spec.merge!(@transfer_spec_cmdline)
        # create transfer agent
        self.set_agent_by_options
        Log.log.debug("transfer agent is a #{@agent.class}")
        @agent.start_transfer(transfer_spec,options)
        result=@agent.wait_for_transfers_completion
        Fasp::Manager.validate_status_list(result)
        return result
      end

      # shut down if agent requires it
      def shutdown
        @agent.shutdown if @agent.respond_to?(:shutdown)
      end

      # helper method for above method
      def self.session_status(statuses)
        error_statuses=statuses.select{|i|!i.eql?(:success)}
        return :success if error_statuses.empty?
        return error_statuses.first
      end

    end
  end
end
