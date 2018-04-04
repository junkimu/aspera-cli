require 'asperalm/cli/main'
require 'asperalm/cli/basic_auth_plugin'
require "base64"

class ::Hash
  def deep_merge!(second)
    merger = proc { |key, v1, v2| v1.is_a?(Hash) and v2.is_a?(Hash) ? v1.merge!(v2, &merger) : v2 }
    self.merge!(second, &merger)
  end
end

module Asperalm
  module Cli
    module Plugins
      class Node < BasicAuthPlugin
        alias super_declare_options declare_options
        def declare_options
          super_declare_options
          Main.tool.options.add_opt_simple(:value,"extended value for create, update, list filter")
          Main.tool.options.add_opt_simple(:validator,"identifier of validator")
          #Main.tool.options.set_option(:value,'@json:{"active_only":false}')
        end

        def self.textify_browse(table_data)
          return table_data.map {|i| i['permissions']=i['permissions'].map { |x| x['name'] }.join(','); i }
        end

        def self.textify_transfer_list(table_data)
          return table_data.map {|i| ['remote_user','remote_host'].each { |field| i[field]=i['start_spec'][field] }; i }
        end

        def self.hash_to_flat(result,name,value,prefix='')
          if value.is_a?(Hash)
            value.each do |k,v|
              hash_to_flat(result,k,v,prefix+name+':')
            end
          else
            result.push({'key'=>prefix+name,'value'=>value})
          end
        end

        # key/value is defined in main in hash_table
        def self.textify_bool_list_result(list,name_list)
          list.each_index do |i|
            if name_list.include?(list[i]['key'])
              list[i]['value'].each do |item|
                list.push({'key'=>item['name'],'value'=>item['value']})
              end
              list.delete_at(i)
              # continue at same index because we delete current one
              redo
            end
          end
        end

        # reduce the path from a result on given named column
        def self.result_remove_prefix_path(result,column,path_prefix)
          if !path_prefix.nil?
            result[:data].each do |r|
              r[column].replace(r[column][path_prefix.length..-1]) if r[column].start_with?(path_prefix)
            end
          end
          return result
        end

        # translates paths results into CLI result, and removes prefix
        def self.result_translate_rem_prefix(resp,type,success_msg,path_prefix)
          resres={:data=>[],:type=>:hash_array,:fields=>[type,'result']}
          JSON.parse(resp[:http].body)['paths'].each do |p|
            result=success_msg
            if p.has_key?('error')
              Log.log.error("#{p['error']['user_message']} : #{p['path']}")
              result="ERROR: "+p['error']['user_message']
            end
            resres[:data].push({type=>p['path'],'result'=>result})
          end
          return result_remove_prefix_path(resres,type,path_prefix)
        end

        def self.delete_files(api_node,paths_to_delete,prefix_path)
          resp=api_node.create('files/delete',{:paths=>paths_to_delete.map{|i| {'path'=>i.start_with?('/') ? i : '/'+i} }})
          return result_translate_rem_prefix(resp,'file','deleted',prefix_path)
        end

        # get path arguments from command line, and add prefix
        def self.get_next_arg_add_prefix(path_prefix,name,number=:single)
          thepath=Main.tool.options.get_next_argument(name,number)
          return thepath if path_prefix.nil?
          return File.join(path_prefix,thepath) if thepath.is_a?(String)
          return thepath.map {|p| File.join(path_prefix,p)} if thepath.is_a?(Array)
          raise StandardError,"expect: nil, String or Array"
        end

        def self.simple_actions; [:events, :space, :info, :mkdir, :mklink, :mkfile, :rename, :delete ];end

        def self.common_actions; simple_actions.clone.concat([:browse, :upload, :download ]);end

        # common API to node and Shares
        # prefix_path is used to list remote sources in Faspex
        def self.execute_common(command,api_node,prefix_path=nil)
          case command
          when :events
            events=api_node.read('events')[:data]
            return { :type=>:hash_array, :data => events}
          when :info
            node_info=api_node.read('info')[:data]
            return { :type=>:key_val_list, :data => node_info, :textify => lambda { |table_data| textify_bool_list_result(table_data,['capabilities','settings'])}}
          when :delete
            paths_to_delete = get_next_arg_add_prefix(prefix_path,"file list",:multiple)
            return delete_files(api_node,paths_to_delete,prefix_path)
          when :space
            # TODO: could be a list of path
            path_list=get_next_arg_add_prefix(prefix_path,"folder path or ext.val. list")
            path_list=[path_list] unless path_list.is_a?(Array)
            resp=api_node.create('space',{ "paths" => path_list.map {|i| {:path=>i} } } )
            result={:data=>resp[:data]['paths'],:type=>:hash_array}
            #return result_translate_rem_prefix(resp,'folder','created',prefix_path)
            return result_remove_prefix_path(result,'path',prefix_path)
          when :mkdir
            path_list=get_next_arg_add_prefix(prefix_path,"folder path or ext.val. list")
            path_list=[path_list] unless path_list.is_a?(Array)
            #TODO
            #resp=api_node.create('space',{ "paths" => path_list.map {|i| {:type=>:directory,:path=>i} } } )
            resp=api_node.create('files/create',{ "paths" => [{ :type => :directory, :path => path_list } ] } )
            return result_translate_rem_prefix(resp,'folder','created',prefix_path)
          when :mklink
            target=get_next_arg_add_prefix(prefix_path,"target")
            path_list=get_next_arg_add_prefix(prefix_path,"link path")
            resp=api_node.create('files/create',{ "paths" => [{ :type => :symbolic_link, :path => path_list, :target => {:path => target} } ] } )
            return result_translate_rem_prefix(resp,'folder','created',prefix_path)
          when :mkfile
            path_list=get_next_arg_add_prefix(prefix_path,"file path")
            contents64=Base64.strict_encode64(Main.tool.options.get_next_argument("contents"))
            resp=api_node.create('files/create',{ "paths" => [{ :type => :file, :path => path_list, :contents => contents64 } ] } )
            return result_translate_rem_prefix(resp,'folder','created',prefix_path)
          when :rename
            path_base=get_next_arg_add_prefix(prefix_path,"path_base")
            path_src=get_next_arg_add_prefix(prefix_path,"path_src")
            path_dst=get_next_arg_add_prefix(prefix_path,"path_dst")
            resp=api_node.create('files/rename',{ "paths" => [{ "path" => path_base, "source" => path_src, "destination" => path_dst } ] } )
            return result_translate_rem_prefix(resp,'entry','moved',prefix_path)
          when :browse
            thepath=get_next_arg_add_prefix(prefix_path,"path")
            send_result=api_node.create('files/browse',{ :path => thepath} )
            #send_result={:data=>{'items'=>[{'file'=>"filename1","permissions"=>[{'name'=>'read'},{'name'=>'write'}]}]}}
            return Main.result_none if !send_result[:data].has_key?('items')
            result={ :data => send_result[:data]['items'] , :type => :hash_array, :textify => lambda { |table_data| Node.textify_browse(table_data) } }
            #display_prefix=thepath
            #display_prefix=File.join(prefix_path,display_prefix) if !prefix_path.nil?
            #puts display_prefix.red
            return result_remove_prefix_path(result,'path',prefix_path)
          when :upload
            filelist = Main.tool.options.get_next_argument("source file list",:multiple)
            Log.log.debug("file list=#{filelist}")
            destination=Main.tool.destination_folder('send')
            send_result=api_node.create('files/upload_setup',{ :transfer_requests => [ { :transfer_request => { :paths => [ { :destination => destination } ] } } ] } )
            raise send_result[:data]['error']['user_message'] if send_result[:data].has_key?('error')
            raise send_result[:data]['transfer_specs'][0]['error']['user_message'] if send_result[:data]['transfer_specs'][0].has_key?('error')
            raise "expecting one session exactly" if send_result[:data]['transfer_specs'].length != 1
            transfer_spec=send_result[:data]['transfer_specs'].first['transfer_spec']
            transfer_spec['paths']=filelist.map { |i| {'source'=>i} }
            # do not use default destination in transfer spec, because can be different on destination (e.g. shares)
            return Main.tool.start_transfer(transfer_spec,false)
          when :download
            filelist = get_next_arg_add_prefix(prefix_path,"source file list",:multiple)
            Log.log.debug("file list=#{filelist}")
            send_result=api_node.create('files/download_setup',{ :transfer_requests => [ { :transfer_request => { :paths => filelist.map {|i| {:source=>i}; } } } ] } )
            raise send_result[:data]['transfer_specs'][0]['error']['user_message'] if send_result[:data]['transfer_specs'][0].has_key?('error')
            raise "expecting one session exactly" if send_result[:data]['transfer_specs'].length != 1
            transfer_spec=send_result[:data]['transfer_specs'].first['transfer_spec']
            return Main.tool.start_transfer(transfer_spec)
          end
        end

        def generic_operations; [:create,:list,:id];end

        # implement generic rest operations on given resource path
        def resource_action(api_node,res_class_path,display_fields)
          res_name=res_class_path.gsub(%r{.*/},'').gsub(%r{^s$},'').gsub('_',' ')
          command=Main.tool.options.get_next_argument('command',[ :list, :create, :id ])
          case command
          when :create
            return {:type => :other_struct, :data=>api_node.create(res_class_path,Main.tool.options.get_option(:value,:mandatory))[:data], :fields=>display_fields}
          when :list
            return {:type => :hash_array, :data=>api_node.read(res_class_path)[:data], :fields=>display_fields}
          when :id
            one_res_id=Main.tool.options.get_next_argument("#{res_name} id")
            one_res_path="#{res_class_path}/#{one_res_id}"
            command=Main.tool.options.get_next_argument('command',[ :delete, :show, :modify ])
            case command
            when :modify
              api_node.update(one_res_path,Main.tool.options.get_option(:value,:mandatory))
              return Main.result_status('modified')
            when :delete
              api_node.delete(one_res_path)
              return {:type => :empty}
            when :show
              return {:type => :key_val_list, :data=>api_node.read(one_res_path)[:data], :fields=>display_fields}
            end
          end
        end

        def action_list; self.class.common_actions.clone.concat([ :postprocess,:stream, :transfer, :cleanup, :forward, :access_key, :watch_folder, :service, :async, :central ]);end

        def execute_action
          api_node=Rest.new(Main.tool.options.get_option(:url,:mandatory),{:auth=>{:type=>:basic,:username=>Main.tool.options.get_option(:username,:mandatory), :password=>Main.tool.options.get_option(:password,:mandatory)}})
          command=Main.tool.options.get_next_argument('command',action_list)
          case command
          when *self.class.common_actions; return self.class.execute_common(command,api_node)
          when :async
            command=Main.tool.options.get_next_argument('command',[ :list, :id ])
            case command
            when :list
              resp=api_node.read('async/list')[:data]['sync_ids']
              return { :type => :value_list, :data => resp, :name=>'id'  }
            when :id
              asyncid=Main.tool.options.get_next_argument("async id")
              command=Main.tool.options.get_next_argument('command',[ :delete,:summary,:counters ])
              case command
              when :summary
                resp=api_node.create('async/summary',{"syncs"=>[asyncid]})[:data]["sync_summaries"].first
                return Main.result_none if resp.nil?
                return { :type => :key_val_list, :data => resp }
              when :delete
                # delete POST /async/delete '{"syncs":["4"]}'
                raise "not implemented"
              when :counters
                resp=api_node.create('async/counters',{"syncs"=>[asyncid]})[:data]["sync_counters"].first[asyncid].last
                return Main.result_none if resp.nil?
                return { :type => :key_val_list, :data => resp }
              end
            end
          when :stream
            command=Main.tool.options.get_next_argument('command',[ :list, :create, :show, :modify, :cancel ])
            case command
            when :list
              resp=api_node.read('ops/transfers',Main.tool.options.get_option(:value,:optional))
              return { :type => :hash_array, :data => resp[:data], :fields=>['id','status']  } # TODO
            when :create
              resp=api_node.create('streams',Main.tool.options.get_option(:value,:mandatory))
              return { :type => :key_val_list, :data => resp[:data] }
            when :show
              trid=Main.tool.options.get_next_argument("transfer id")
              resp=api_node.read('ops/transfers/'+trid)
              return { :type=>:other_struct, :data => resp[:data] }
            when :modify
              trid=Main.tool.options.get_next_argument("transfer id")
              resp=api_node.update('streams/'+trid,Main.tool.options.get_option(:value,:mandatory))
              return { :type=>:other_struct, :data => resp[:data] }
            when :cancel
              trid=Main.tool.options.get_next_argument("transfer id")
              resp=api_node.cancel('streams/'+trid)
              return { :type=>:other_struct, :data => resp[:data] }
            else
              raise "error"
            end
          when :transfer
            command=Main.tool.options.get_next_argument('command',[ :list, :cancel, :show ])
            case command
            when :list
              # could use ? :subpath=>'transfers'
              resp=api_node.read('ops/transfers',Main.tool.options.get_option(:value,:optional))
              return { :type => :hash_array, :data => resp[:data], :fields=>['id','status','remote_user','remote_host'], :textify => lambda { |table_data| Node.textify_transfer_list(table_data) } } # TODO
            when :cancel
              trid=Main.tool.options.get_next_argument("transfer id")
              resp=api_node.cancel('ops/transfers/'+trid)
              return { :type=>:other_struct, :data => resp[:data] }
            when :show
              trid=Main.tool.options.get_next_argument("transfer id")
              resp=api_node.read('ops/transfers/'+trid)
              return { :type=>:other_struct, :data => resp[:data] }
            else
              raise "error"
            end
          when :access_key
            return resource_action(api_node,'access_keys',['id','root_file_id','storage','license'])
          when :service
            command=Main.tool.options.get_next_argument('command',[ :list, :create, :id])
            case command
            when :list
              resp=api_node.read('rund/services')
              #  :fields=>['id','root_file_id','storage','license']
              return { :type=>:hash_array, :data => resp[:data]["services"] }
            when :create
              # @json:'{"type":"WATCHFOLDERD","run_as":{"user":"user1"}}'
              params=Main.tool.options.get_next_argument("Run creation data (structure)")
              resp=api_node.create('rund/services',params)
              return Main.result_status("#{resp[:data]['id']} created")
            when :id
              svcid=Main.tool.options.get_next_argument("service id")
              command=Main.tool.options.get_next_argument('command',[ :delete, :modify ])
              case command
              when :delete
                resp=api_node.delete("rund/services/#{svcid}")
                return Main.result_status("#{svcid} deleted")
              else
                raise "error"
              end
            else
              raise "error"
            end
          when :watch_folder
            res_class_path='v3/watchfolders'
            #return resource_action(api_node,'v3/watchfolders',nil)
            command=Main.tool.options.get_next_argument('command',[ :list, :create, :id])
            case command
            when :create
              resp=api_node.create(res_class_path,Main.tool.options.get_option(:value,:mandatory))
              return Main.result_status("#{resp[:data]['id']} created")
            when :list
              resp=api_node.read(res_class_path,Main.tool.options.get_option(:value,:optional))
              #  :fields=>['id','root_file_id','storage','license']
              return { :type=>:value_list, :data => resp[:data]['ids'], :name=>'id' }
            when :id
              one_res_id=Main.tool.options.get_next_argument("watch folder id")
              one_res_path="#{res_class_path}/#{one_res_id}"
              command=Main.tool.options.get_next_argument('command',[ :delete, :show, :update, :state ])
              case command
              when :show
                return {:type=>:key_val_list, :data=>api_node.read(one_res_path)[:data]}
              when :update
                api_node.update(one_res_path,Main.tool.options.get_option(:value,:mandatory))
                return Main.result_status("#{one_res_id} updated")
              when :delete
                api_node.delete(one_res_path)
                return Main.result_status("#{one_res_id} deleted")
              when :state
                return { :type=>:key_val_list, :data => api_node.read("#{one_res_path}/state")[:data] }
              end
            end
          when :central
            command=Main.tool.options.get_next_argument('command',[ :session,:file])
            validator_id=Main.tool.options.get_option(:validator)
            validation={"validator_id"=>validator_id} unless validator_id.nil?
            request_data=Main.tool.options.get_option(:value,:optional)
            request_data||={}
            case command
            when :session
              command=Main.tool.options.get_next_argument('command',[ :list])
              case command
              when :list
                request_data.deep_merge!({"validation"=>validation}) unless validation.nil?
                resp=api_node.create('services/rest/transfers/v1/sessions',request_data)
                return {:type=>:hash_array,:data=>resp[:data]["session_info_result"]["session_info"],:fields=>["session_uuid","status","transport","direction","bytes_transferred"]}
              end
            when :file
              command=Main.tool.options.get_next_argument('command',[ :list, :update])
              case command
              when :list
                request_data.deep_merge!({"validation"=>validation}) unless validation.nil?
                resp=api_node.create('services/rest/transfers/v1/files',request_data)
                return {:type=>:hash_array,:data=>resp[:data]["file_transfer_info_result"]["file_transfer_info"],:fields=>["session_uuid","file_id","status","path"]}
              when :update
                request_data.deep_merge!(validation) unless validation.nil?
                api_node.update('services/rest/transfers/v1/files',request_data)
                return Main.result_status('updated')
              end
            end
          end # case command
          raise "ERROR: shall not reach this line"
        end # execute_action
      end # Main
    end # Plugin
  end # Cli
end # Asperalm
