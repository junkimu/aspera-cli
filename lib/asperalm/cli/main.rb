require 'asperalm/cli/manager'
require 'asperalm/cli/plugins/config'
require 'asperalm/cli/extended_value'
require 'asperalm/cli/transfer_agent'
require 'asperalm/open_application'
require 'asperalm/temp_file_manager'
require 'asperalm/persistency_file'
require 'asperalm/log'
require 'asperalm/rest'
require 'asperalm/files_api'
require 'text-table'
require 'fileutils'
require 'singleton'
require 'yaml'
require 'pp'

module Asperalm
  module Cli
    # The main CLI class
    class Main
      include Singleton
      # "tool" class method is an alias to "instance" of singleton
      singleton_class.send(:alias_method, :tool, :instance)
      def self.gem_version
        File.read(File.join(gem_root,@@GEM_NAME,'VERSION')).chomp
      end

      private
      # name of application, also foldername where config is stored
      @@PROGRAM_NAME = 'mlia'
      @@GEM_NAME = 'asperalm'
      # Container module of current class : Asperalm::Cli
      @@CLI_MODULE=Module.nesting[1].to_s
      # Path to Plugin classes: Asperalm::Cli::Plugins
      @@PLUGINS_MODULE=@@CLI_MODULE+'::Plugins'
      FIELDS_ALL='ALL'
      FIELDS_DEFAULT='DEF'
      @@VERBOSE_LEVELS=[:normal,:minimal,:quiet]

      # find the root folder of gem where this class is
      def self.gem_root
        File.expand_path(@@CLI_MODULE.to_s.gsub('::','/').gsub(%r([^/]+),'..'),File.dirname(__FILE__))
      end

      # =============================================================
      # Parameter handlers
      #

      def option_insecure; Rest.insecure ; end

      def option_insecure=(value); Rest.insecure = value; end

      def option_ui; OpenApplication.instance.url_method; end

      def option_ui=(value); OpenApplication.instance.url_method=value; end

      def option_preset; nil; end

      def option_preset=(value)
        @opt_mgr.add_option_preset(@config_plugin.preset_by_name(value))
      end

      attr_accessor :option_flat_hash
      attr_accessor :option_table_style

      # minimum initialization
      def initialize
        # overriding parameters on transfer spec
        @option_help=false
        @option_show_config=false
        @option_flat_hash=true
        @option_table_style=':.:'
        @opt_mgr=Manager.new(self.program_name)
        @plugin_env={:options=>@opt_mgr}
        @transfer_mgr=TransferAgent.new(@plugin_env)
        @plugin_env[:transfer]=@transfer_mgr
        @config_plugin=Plugins::Config.new(@plugin_env,self.program_name,@@GEM_NAME,self.class.gem_version)
        @plugin_env[:config]=@config_plugin
        # set application folder for modules
        PersistencyFile.default_folder=@config_plugin.main_folder
        Oauth.persistency_folder=@config_plugin.main_folder
        ExtendedValue.instance.set_handler('preset',:reader,lambda{|v|@config_plugin.preset_by_name(v)})
        Fasp::Parameters.file_list_folder=File.join(@config_plugin.main_folder,'filelists')
      end

      # local options
      def init_options
        @opt_mgr.parser.banner = "NAME\n\t#{self.program_name} -- a command line tool for Aspera Applications (v#{self.class.gem_version})\n\n"
        @opt_mgr.parser.separator "SYNOPSIS"
        @opt_mgr.parser.separator "\t#{self.program_name} COMMANDS [OPTIONS] [ARGS]"
        @opt_mgr.parser.separator ""
        @opt_mgr.parser.separator "DESCRIPTION"
        @opt_mgr.parser.separator "\tUse Aspera application to perform operations on command line."
        @opt_mgr.parser.separator "\tOAuth 2.0 is used for authentication in Files, Several authentication methods are provided."
        @opt_mgr.parser.separator "\tDocumentation and examples: #{@config_plugin.gem_url}"
        @opt_mgr.parser.separator "\texecute: #{self.program_name} conf doc"
        @opt_mgr.parser.separator ""
        @opt_mgr.parser.separator "COMMANDS"
        @opt_mgr.parser.separator "\tFirst level commands: #{@config_plugin.plugins.keys.map {|x| x.to_s}.join(', ')}"
        @opt_mgr.parser.separator "\tNote that commands can be written shortened (provided it is unique)."
        @opt_mgr.parser.separator ""
        @opt_mgr.parser.separator "OPTIONS"
        @opt_mgr.parser.separator "\tOptions begin with a '-' (minus), and value is provided on command line.\n"
        @opt_mgr.parser.separator "\tSpecial values are supported beginning with special prefix, like: #{ExtendedValue.instance.modifiers.map{|m|"@#{m}:"}.join(' ')}.\n"
        @opt_mgr.parser.separator "\tDates format is 'DD-MM-YY HH:MM:SS', or 'now' or '-<num>h'"
        @opt_mgr.parser.separator ""
        @opt_mgr.parser.separator "ARGS"
        @opt_mgr.parser.separator "\tSome commands require mandatory arguments, e.g. a path.\n"
        @opt_mgr.parser.separator ""
        @opt_mgr.parser.separator "OPTIONS: global"
        @opt_mgr.declare_options_scan_env
        @opt_mgr.set_obj_attr(:table_style,self,:option_table_style)
        @opt_mgr.add_opt_simple(:table_style,"table display style, current=#{@option_table_style}")
        @opt_mgr.add_opt_switch(:help,"Show this message.","-h") { @option_help=true }
        @opt_mgr.add_opt_switch(:show_config, "Display parameters used for the provided action.") { @option_show_config=true }
        @opt_mgr.add_opt_switch(:rest_debug,"-r","more debug for HTTP calls") { Rest.debug=true }
        @opt_mgr.add_opt_switch(:version,"-v","display version") { display_message(:data,self.class.gem_version);Process.exit(0) }
        @opt_mgr.add_opt_list(:display,self.class.display_levels,"output only some information")
        @opt_mgr.set_option(:display,:info)
      end

      def declare_global_options
        # handler must be set before declaration
        @opt_mgr.set_obj_attr(:log_level,Log.instance,:level)
        @opt_mgr.set_obj_attr(:insecure,self,:option_insecure,:no)
        @opt_mgr.set_obj_attr(:flat_hash,self,:option_flat_hash)
        @opt_mgr.set_obj_attr(:logger,Log.instance,:logger_type)
        @opt_mgr.set_obj_attr(:ui,self,:option_ui)
        @opt_mgr.set_obj_attr(:preset,self,:option_preset)
        @opt_mgr.set_obj_attr(:use_product,Fasp::Installation.instance,:activated)

        @opt_mgr.add_opt_list(:ui,OpenApplication.user_interfaces,'method to start browser')
        @opt_mgr.add_opt_list(:log_level,Log.levels,"Log level")
        @opt_mgr.add_opt_list(:logger,Log.logtypes,"log method")
        @opt_mgr.add_opt_list(:format,self.class.display_formats,"output format")
        @opt_mgr.add_opt_simple(:preset,"-PVALUE","load the named option preset from current config file")
        @opt_mgr.add_opt_simple(:fields,"comma separated list of fields, or #{FIELDS_ALL}, or #{FIELDS_DEFAULT}")
        @opt_mgr.add_opt_simple(:select,"select only some items in lists, extended value: hash (colum, value)")
        @opt_mgr.add_opt_simple(:fasp_proxy,"URL of FASP proxy (dnat / dnats)")
        @opt_mgr.add_opt_simple(:http_proxy,"URL of HTTP proxy (for http fallback)")
        @opt_mgr.add_opt_simple(:lock_port,"prevent dual execution of a command, e.g. in cron")
        @opt_mgr.add_opt_simple(:use_product,"which local product to use for ascp, current=#{Fasp::Installation.instance.activated}")
        @opt_mgr.add_opt_simple(:query,"additional filter for API calls (extended value) (some commands)")
        @opt_mgr.add_opt_boolean(:insecure,"do not validate HTTPS certificate")
        @opt_mgr.add_opt_boolean(:flat_hash,"display hash values as additional keys")
        @opt_mgr.add_opt_boolean(:override,"override existing value")
        @opt_mgr.add_opt_boolean(:once_only,"process only new items (some commands)")

        @opt_mgr.set_option(:ui,OpenApplication.default_gui_mode)
        @opt_mgr.set_option(:fields,FIELDS_DEFAULT)
        @opt_mgr.set_option(:format,:table)
        @opt_mgr.set_option(:once_only,:false)
      end

      # loads default parameters of plugin if no -P parameter
      # and if there is a section defined for the plugin in the "default" section
      # try to find: conffile[conffile["default"][plugin_str]]
      # @param plugin_name_sym : symbol for plugin name
      def add_plugin_default_preset(plugin_name_sym)
        default_config_name=@config_plugin.get_plugin_default_config_name(plugin_name_sym)
        Log.log.debug("add_plugin_default_preset:#{plugin_name_sym}:#{default_config_name}")
        @opt_mgr.add_option_preset(@config_plugin.preset_by_name(default_config_name),:unshift) unless default_config_name.nil?
        return nil
      end

      # @return the plugin instance, based on name
      # also loads the plugin options, and default values from conf file
      # @param plugin_name_sym : symbol for plugin name
      def get_plugin_instance_with_options(plugin_name_sym,env=@plugin_env)
        Log.log.debug("get_plugin_instance_with_options -> #{plugin_name_sym} (#{env})")
        require @config_plugin.plugins[plugin_name_sym][:require_stanza]
        command_plugin=Object::const_get(@@PLUGINS_MODULE+'::'+plugin_name_sym.to_s.capitalize).new(env)
        # TODO: check that ancestor is Plugin?
        env[:options].parser.separator "COMMAND: #{plugin_name_sym}"
        env[:options].parser.separator "SUBCOMMANDS: #{command_plugin.action_list.map{ |p| p.to_s}.join(', ')}"
        env[:options].parser.separator "OPTIONS:"
        command_plugin.declare_options
        # load default params only if no param already loaded
        add_plugin_default_preset(plugin_name_sym)
        return command_plugin
      end

      # @param source [Hash] hash to modify
      # @param keep_last [bool]
      def self.flatten_object(source,keep_last)
        newval={}
        flatten_sub_hash_rec(source,keep_last,'',newval)
        source.clear
        source.merge!(newval)
      end

      # recursive function to modify a hash
      # @param source [Hash] to be modified
      # @param keep_last [bool] truer if last level is not
      # @param prefix [String] true if last level is not
      # @param dest [Hash] new hash flattened
      def self.flatten_sub_hash_rec(source,keep_last,prefix,dest)
        #is_simple_hash=source.is_a?(Hash) and source.values.inject(true){|m,v| xxx=!v.respond_to?(:each) and m;puts("->#{xxx}>#{v.respond_to?(:each)} #{v}-");xxx}
        is_simple_hash=false
        Log.log.debug("(#{keep_last})[#{is_simple_hash}] -#{source.values}- \n-#{source}-")
        return source if keep_last and is_simple_hash
        source.each do |k,v|
          if v.is_a?(Hash) and ( !keep_last or !is_simple_hash )
            flatten_sub_hash_rec(v,keep_last,prefix+k.to_s+'.',dest)
          else
            dest[prefix+k.to_s]=v
          end
        end
        return nil
      end

      # special for Aspera on Cloud display node
      # {"param" => [{"name"=>"foo","value"=>"bar"}]} will be expanded to {"param.foo" : "bar"}
      def self.flatten_name_value_list(hash)
        hash.keys.each do |k|
          v=hash[k]
          if v.is_a?(Array) and v.map{|i|i.class}.uniq.eql?([Hash]) and v.map{|i|i.keys}.flatten.sort.uniq.eql?(["name", "value"])
            v.each do |pair|
              hash["#{k}.#{pair["name"]}"]=pair["value"]
            end
            hash.delete(k)
          end
        end
      end

      # expect some list, but nothing to display
      def self.result_empty; return {:type => :empty, :data => :nil }; end

      # nothing expected
      def self.result_nothing; return {:type => :nothing, :data => :nil }; end

      def self.result_status(status); return {:type => :status, :data => status }; end

      def self.result_success; return result_status('complete'); end

      # supported output formats
      def self.display_formats; [:table,:ruby,:json,:jsonpp,:yaml,:csv]; end

      # user output levels
      def self.display_levels; [:info,:data,:error]; end

      # main output method
      def display_message(level,message)
        case level
        when :info
          if @opt_mgr.get_option(:format,:mandatory).eql?(:table) and
          @opt_mgr.get_option(:display,:mandatory).eql?(:info)
            STDOUT.puts(message)
          end
        when :data
          STDOUT.puts(message) unless @opt_mgr.get_option(:display,:mandatory).eql?(:error)
        when :error
          STDERR.puts(message)
        else raise "bad case"
        end
      end

      CSV_RECORD_SEPARATOR="\n"
      CSV_FIELD_SEPARATOR=","

      # this method displays the results, especially the table format
      def display_results(results)
        raise "INTERNAL ERROR, result must be Hash (got: #{results.class}: #{results})" unless results.is_a?(Hash)
        raise "INTERNAL ERROR, result must have type" unless results.has_key?(:type)
        raise "INTERNAL ERROR, result must have data" unless results.has_key?(:data) or [:empty,:nothing].include?(results[:type])

        # comma separated list in string format
        user_asked_fields_list_str=@opt_mgr.get_option(:fields,:mandatory)
        display_format=@opt_mgr.get_option(:format,:mandatory)
        case display_format
        when :ruby
          display_message(:data,PP.pp(results[:data],''))
        when :json
          display_message(:data,JSON.generate(results[:data]))
        when :jsonpp
          display_message(:data,JSON.pretty_generate(results[:data]))
        when :yaml
          display_message(:data,results[:data].to_yaml)
        when :table,:csv
          case results[:type]
          when :object_list # goes to table display
            raise "internal error: unexpected type: #{results[:data].class}, expecting Array" unless results[:data].is_a?(Array)
            # :object_list is an array of hash tables, where key=colum name
            table_rows_hash_val = results[:data]
            final_table_columns=nil
            if @option_flat_hash
              new_table_rows_hash_val=[]
              table_rows_hash_val.each do |obj|
                self.class.flatten_object(obj,results[:option_expand_last])
              end
            end
            case user_asked_fields_list_str
            when FIELDS_DEFAULT
              if results.has_key?(:fields) and !results[:fields].nil?
                final_table_columns=results[:fields]
              else
                if !table_rows_hash_val.empty?
                  final_table_columns=table_rows_hash_val.first.keys
                else
                  final_table_columns=['empty']
                end
              end
            when FIELDS_ALL
              raise "empty" if table_rows_hash_val.empty?
              final_table_columns=table_rows_hash_val.first.keys if table_rows_hash_val.is_a?(Array)
            else
              final_table_columns=user_asked_fields_list_str.split(',')
            end
          when :single_object # goes to table display
            # :single_object is a simple hash table  (can be nested)
            raise "internal error: unexpected type: #{results[:data].class}, expecting Hash" unless results[:data].is_a?(Hash)
            final_table_columns = results[:columns] || ['key','value']
            asked_fields=results[:data].keys
            case user_asked_fields_list_str
            when FIELDS_DEFAULT;asked_fields=results[:fields] if results.has_key?(:fields)
            when FIELDS_ALL;# keep all
            else
              asked_fields=user_asked_fields_list_str.split(',')
            end
            if @option_flat_hash
              self.class.flatten_object(results[:data],results[:option_expand_last])
              self.class.flatten_name_value_list(results[:data])
              # first level keys are potentially changed
              asked_fields=results[:data].keys
            end
            table_rows_hash_val=asked_fields.map { |i| { final_table_columns.first => i, final_table_columns.last => results[:data][i] } }
          when :value_list  # goes to table display
            # :value_list is a simple array of values, name of column provided in the :name
            final_table_columns = [results[:name]]
            table_rows_hash_val=results[:data].map { |i| { results[:name] => i } }
          when :empty # no table
            display_message(:info,'empty')
            return
          when :nothing # no result expected
            Log.log.debug("no result expected")
            return
          when :status # no table
            # :status displays a simple message
            display_message(:info,results[:data])
            return
          when :text # no table
            # :status displays a simple message
            display_message(:data,results[:data])
            return
          when :other_struct # no table
            # :other_struct is any other type of structure
            display_message(:data,PP.pp(results[:data],''))
            return
          else
            raise "unknown data type: #{results[:type]}"
          end
          # here we expect: table_rows_hash_val and final_table_columns
          raise "no field specified" if final_table_columns.nil?
          if table_rows_hash_val.empty?
            display_message(:info,'empty'.gray) unless display_format.eql?(:csv)
            return
          end
          # convert to string with special function. here table_rows_hash_val is an array of hash
          table_rows_hash_val=results[:textify].call(table_rows_hash_val) if results.has_key?(:textify)
          filter=@opt_mgr.get_option(:select,:optional)
          unless filter.nil?
            raise CliBadArgument,"expecting hash for select" unless filter.is_a?(Hash)
            filter.each{|k,v|table_rows_hash_val.select!{|i|i[k].eql?(v)}}
          end

          # convert data to string, and keep only display fields
          final_table_rows=table_rows_hash_val.map { |r| final_table_columns.map { |c| r[c].to_s } }
          # here : final_table_columns : list of column names
          # here: final_table_rows : array of list of value
          case display_format
          when :table
            style=@option_table_style.split('')
            # display the table !
            display_message(:data,Text::Table.new(
            :head => final_table_columns,
            :rows => final_table_rows,
            :horizontal_boundary   => style[0],
            :vertical_boundary     => style[1],
            :boundary_intersection => style[2]))
          when :csv
            display_message(:data,final_table_rows.map{|t| t.join(CSV_FIELD_SEPARATOR)}.join(CSV_RECORD_SEPARATOR))
          end
        end
      end

      def exit_with_usage(all_plugins)
        # display main plugin options
        display_message(:error,@opt_mgr.parser)
        if all_plugins
          # list plugins that have a "require" field, i.e. all but main plugin
          @config_plugin.plugins.keys.each do |plugin_name_sym|
            next if plugin_name_sym.eql?(Plugins::Config.name_sym)
            # override main option parser with a brand new, to avoid having global options
            opt_mgr=Manager.new(self.program_name)
            opt_mgr.parser.banner = ""
            get_plugin_instance_with_options(plugin_name_sym,{:options=>opt_mgr})
            display_message(:error,opt_mgr.parser)
          end
        end
        #display_message(:error,@opt_mgr.parser)
        display_message(:error,"\nDocumentation : #{@config_plugin.help_url}")
        Process.exit(0)
      end

      protected

      # early debug for parser
      # Note: does not accept shortcuts
      def early_debug_setup(argv)
        Log.instance.program_name=self.program_name
        argv.each do |arg|
          case arg
          when '--'
            return
          when /^--log-level=(.*)/
            Log.instance.level = $1.to_sym
          when /^--logger=(.*)/
            Log.instance.logger_type=$1.to_sym
          end
        end
      end

      public
      attr_accessor :transfer_mgr

      def display_status(status)
        display_message(:info,status)
      end

      # plugins shall use this method to start a transfer
      # start transfer and wait for completion of all jobs
      def self.result_transfer(transfer_spec,options)
        # TODO: if not one shot, then wait for status
        statuses=self.instance.transfer_mgr.start(transfer_spec,options)
        raise "at least one transfer session failed" unless TransferAgent.all_session_success(statuses)
        return Main.result_nothing
      end

      def options;@opt_mgr;end

      def program_name;@@PROGRAM_NAME;end

      # this is the main function called by initial script just after constructor
      def process_command_line(argv)
        current_prog_name=File.basename($PROGRAM_NAME)
        unless current_prog_name.eql?(@@PROGRAM_NAME)
          display_message(:error,"#{"WARNING".bg_red.blink.gray} Please use '#{@@PROGRAM_NAME}' instead of '#{current_prog_name}', '#{current_prog_name}' will be removed in a future version")
        end
        exception_info=nil
        begin
          # first thing : manage debug level (allows debugging or option parser)
          early_debug_setup(argv)
          # give command line arguments to option manager (no parsing)
          @opt_mgr.add_cmd_line_options(argv)
          # declare initial options
          init_options
          # declare options for config file location
          @config_plugin.declare_options
          # parse declared options
          @opt_mgr.parse_options!
          # load default config if it was not overriden on command line
          @config_plugin.read_config_file
          # declare general options
          declare_global_options
          @transfer_mgr.declare_transfer_options
          @opt_mgr.parse_options!
          # find plugins, shall be after parse! ?
          @config_plugin.add_plugins_from_lookup_folders
          # declare generic options
          Plugin.declare_entity_options(@opt_mgr)
          # help requested without command ? (plugins must be known here)
          exit_with_usage(true) if @option_help and @opt_mgr.command_or_arg_empty?
          # load global default options and process
          add_plugin_default_preset(Plugins::Config.name_sym)
          @opt_mgr.parse_options!
          # dual execution locking
          lock_port=@opt_mgr.get_option(:lock_port,:optional)
          if !lock_port.nil?
            begin
              # no need to close later, will be freed on process exit
              TCPServer.new('127.0.0.1',lock_port.to_i)
            rescue => e
              raise CliError,"Another instance is already running (lock port=#{lock_port})."
            end
          end
          if @option_show_config and @opt_mgr.command_or_arg_empty?
            command_sym=Plugins::Config.name_sym
          else
            command_sym=@opt_mgr.get_next_command(@config_plugin.plugins.keys.dup.unshift(:help))
          end
          # main plugin is not dynamically instanciated
          case command_sym
          when :help
            exit_with_usage(true)
          when Plugins::Config.name_sym
            command_plugin=@config_plugin
          else
            # get plugin, set options, etc
            command_plugin=get_plugin_instance_with_options(command_sym)
            # parse plugin specific options
            @opt_mgr.parse_options!
          end
          # help requested ?
          exit_with_usage(false) if @option_help
          if @option_show_config
            display_results({:type=>:single_object,:data=>@opt_mgr.declared_options(false)})
            Process.exit(0)
          end
          # execute and display
          display_results(command_plugin.execute_action)
          # finish
          @transfer_mgr.shutdown
          @opt_mgr.fail_if_unprocessed
        rescue CliBadArgument => e;          exception_info=[e,'Argument',:usage]
        rescue CliNoSuchId => e;             exception_info=[e,'Identifier']
        rescue CliError => e;                exception_info=[e,'Tool',:usage]
        rescue Fasp::Error => e;             exception_info=[e,"FASP(ascp]"]
        rescue Asperalm::RestCallError => e; exception_info=[e,"Rest"]
        rescue SocketError => e;             exception_info=[e,"Network"]
        rescue StandardError => e;           exception_info=[e,"Other",:debug]
        rescue Interrupt => e;               exception_info=[e,"Interruption",:debug]
        end
        # cleanup file list files
        TempFileManager.instance.cleanup
        # processing of error condition
        unless exception_info.nil?
          display_message(:error,"ERROR:".bg_red.gray.blink+" "+exception_info[1]+": "+exception_info[0].message)
          display_message(:error,"Use '-h' option to get help.") if exception_info[2].eql?(:usage)
          if Log.instance.level.eql?(:debug)
            # will force to show stack trace
            raise exception_info[0]
          else
            display_message(:error,"Use '--log-level=debug' to get more details.") if exception_info[2].eql?(:debug)
            Process.exit(1)
          end
        end
        return nil
      end # process_command_line
    end # Main
  end # Cli
end # Asperalm
