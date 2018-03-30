require 'asperalm/cli/main'
require 'asperalm/cli/basic_auth_plugin'
require "base64"

module Asperalm
  module Cli
    module Plugins
      class Xnode < BasicAuthPlugin
        alias super_declare_options declare_options
        def declare_options
          super_declare_options
          Main.tool.options.add_opt_simple(:filter_transfer,"Ruby expression for filter at transfer level (cleanup)")
          Main.tool.options.add_opt_simple(:filter_file,"Ruby expression for filter at file level (cleanup)")
        end

        def action_list; [ :postprocess, :cleanup, :forward ];end

        def execute_action
          api_node=Rest.new(Main.tool.options.get_option(:url,:mandatory),{:auth=>{:type=>:basic,:username=>Main.tool.options.get_option(:username,:mandatory), :password=>Main.tool.options.get_option(:password,:mandatory)}})
          command=Main.tool.options.get_next_argument('command',action_list)
          case command
          when :cleanup
            transfers=self.class.get_transfers_iteration(api_node,{:active_only=>false})
            filter_transfer=Main.tool.options.get_option(:filter_transfer,:mandatory)
            filter_file=Main.tool.options.get_option(:filter_file,:mandatory)
            Log.log.debug("filter_transfer: #{filter_transfer}")
            Log.log.debug("filter_file: #{filter_file}")
            # build list of files to delete: non zero files, downloads, for specified user
            paths_to_delete=[]
            transfers.each do |t|
              if eval(filter_transfer)
                t['files'].each do |f|
                  if eval(filter_file)
                    if !paths_to_delete.include?(f['path'])
                      paths_to_delete.push(f['path'])
                      Log.log.info("to delete: #{f['path']}")
                    end
                  end
                end
              end
            end
            # delete files, if any
            if paths_to_delete.length != 0
              Log.log.info("deletion")
              return self.delete_files(api_node,paths_to_delete,nil)
            else
              Log.log.info("nothing to delete")
            end
            return Main.result_none
          when :forward
            # detect transfer sessions since last call
            transfers=self.class.get_transfers_iteration(api_node,{:active_only=>false})
            # build list of all files received in all sessions
            filelist=[]
            transfers.select { |t| t['status'].eql?('completed') and t['start_spec']['direction'].eql?('receive') }.each do |t|
              t['files'].each { |f| filelist.push(f['path']) }
            end
            if filelist.empty?
              Log.log.debug("NO TRANSFER".red)
              return Main.result_none
            end
            Log.log.debug("file list=#{filelist}")
            # get download transfer spec on destination node
            transfer_params={ :transfer_requests => [ { :transfer_request => { :paths => filelist.map {|i| {:source=>i} } } } ] }
            send_result=api_node.call({:operation=>'POST',:subpath=>'files/download_setup',:json_params=>transfer_params})
            raise "expecting one session exactly" if send_result[:data]['transfer_specs'].length != 1
            transfer_data=send_result[:data]['transfer_specs'].first
            raise Fasp::Error,transfer_data['error']['user_message'] if transfer_data.has_key?('error')
            transfer_spec=transfer_data['transfer_spec']
            # execute transfer
            return Main.tool.start_transfer(transfer_spec)
          when :postprocess
            transfers=self.class.get_transfers_iteration(api_node,{:view=>'summary',:direction=>'receive',:active_only=>false})
            return { :type=>:hash_array,:data => transfers }
          end # case command
          raise "ERROR: shall not reach this line"
        end # execute_action
      end # Main
    end # Plugin
  end # Cli
end # Asperalm
