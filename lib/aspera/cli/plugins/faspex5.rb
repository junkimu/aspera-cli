# frozen_string_literal: true

# spellchecker: ignore workgroups,mypackages

require 'aspera/cli/basic_auth_plugin'
require 'aspera/persistency_action_once'
require 'aspera/id_generator'
require 'aspera/nagios'
require 'aspera/environment'
require 'securerandom'
require 'ruby-progressbar'
require 'tty-spinner'

module Aspera
  module Cli
    module Plugins
      class Faspex5 < Aspera::Cli::BasicAuthPlugin
        RECIPIENT_TYPES = %w[user workgroup external_user distribution_list shared_inbox].freeze
        PACKAGE_TERMINATED = %w[completed failed].freeze
        API_DETECT = 'api/v5/configuration/ping'
        # list of supported mailbox types
        API_MAILBOXES = %w[inbox inbox_history inbox_all inbox_all_history outbox outbox_history pending pending_history all].freeze
        PACKAGE_TYPE_RECEIVED = 'received'
        PACKAGE_ALL_INIT = 'INIT'
        PACKAGE_SEND_FROM_REMOTE_SOURCE = 'remote_source'
        private_constant(*%i[RECIPIENT_TYPES PACKAGE_TERMINATED API_DETECT API_MAILBOXES PACKAGE_TYPE_RECEIVED PACKAGE_SEND_FROM_REMOTE_SOURCE])
        class << self
          def detect(base_url)
            api = Rest.new(base_url: base_url, redirect_max: 1)
            result = api.read(API_DETECT)
            if result[:http].code.start_with?('2') && result[:http].body.strip.empty?
              suffix_length = -2 - API_DETECT.length
              return {
                version: result[:http]['x-ibm-aspera'] || '5',
                url:     result[:http].uri.to_s[0..suffix_length],
                name:    'Faspex 5'
              }
            end
            return nil
          end
        end

        TRANSFER_CONNECT = 'connect'

        def initialize(env)
          super(env)
          options.add_opt_simple(:client_id, 'OAuth client identifier')
          options.add_opt_simple(:client_secret, 'OAuth client secret')
          options.add_opt_simple(:redirect_uri, 'OAuth redirect URI for web authentication')
          options.add_opt_list(:auth, %i[boot link].concat(Oauth::STD_AUTH_TYPES), 'OAuth type of authentication')
          options.add_opt_simple(:box, "Package inbox, either shared inbox name or one of #{API_MAILBOXES}")
          options.add_opt_simple(:private_key, 'OAuth JWT RSA private key PEM value (prefix file path with @file:)')
          options.add_opt_simple(:passphrase, 'RSA private key passphrase')
          options.add_opt_simple(:shared_folder, 'Shared folder source for package files')
          options.add_opt_simple(:link, 'public link for specific operation')
          options.set_option(:auth, :jwt)
          options.set_option(:box, 'inbox')
          options.parse_options!
        end

        def set_api
          public_link = options.get_option(:link)
          unless public_link.nil?
            @faspex5_api_base_url = public_link.gsub(%r{/public/.*}, '').gsub(/\?.*/, '')
            options.set_option(:auth, :link)
          end
          @faspex5_api_base_url ||= options.get_option(:url, is_type: :mandatory).gsub(%r{/+$}, '')
          @faspex5_api_auth_url = "#{@faspex5_api_base_url}/auth"
          faspex5_api_v5_url = "#{@faspex5_api_base_url}/api/v5"
          case options.get_option(:auth, is_type: :mandatory)
          when :link
            uri = URI.parse(public_link)
            args = URI.decode_www_form(uri.query).each_with_object({}){|v, h|h[v.first] = v.last; }
            Log.dump(:args, args)
            context = args['context']
            raise 'missing context' if context.nil?
            @pub_link_context = JSON.parse(Base64.decode64(context))
            Log.dump(:@pub_link_context, @pub_link_context)
            @api_v5 = Rest.new({
              base_url: faspex5_api_v5_url,
              headers:  {'Passcode' => @pub_link_context['passcode']}
            })
          when :boot
            # the password here is the token copied directly from browser in developer mode
            @api_v5 = Rest.new({
              base_url: faspex5_api_v5_url,
              headers:  {'Authorization' => options.get_option(:password, is_type: :mandatory)}
            })
          when :web
            # opens a browser and ask user to auth using web
            @api_v5 = Rest.new({
              base_url: faspex5_api_v5_url,
              auth:     {
                type:         :oauth2,
                base_url:     @faspex5_api_auth_url,
                grant_method: :web,
                client_id:    options.get_option(:client_id, is_type: :mandatory),
                web:          {redirect_uri: options.get_option(:redirect_uri, is_type: :mandatory)}
              }})
          when :jwt
            app_client_id = options.get_option(:client_id, is_type: :mandatory)
            @api_v5 = Rest.new({
              base_url: faspex5_api_v5_url,
              auth:     {
                type:         :oauth2,
                base_url:     @faspex5_api_auth_url,
                grant_method: :jwt,
                client_id:    app_client_id,
                jwt:          {
                  payload:         {
                    iss: app_client_id,    # issuer
                    aud: app_client_id,    # audience (this field is not clear...)
                    sub: "user:#{options.get_option(:username, is_type: :mandatory)}" # subject is a user
                  },
                  private_key_obj: OpenSSL::PKey::RSA.new(options.get_option(:private_key, is_type: :mandatory), options.get_option(:passphrase)),
                  headers:         {typ: 'JWT'}
                }
              }})
          else raise 'Unexpected case for option: auth'
          end
        end

        # if recipient is just an email, then convert to expected API hash : name and type
        def normalize_recipients(parameters)
          return unless parameters.key?('recipients')
          raise 'Field recipients must be an Array' unless parameters['recipients'].is_a?(Array)
          recipient_types = RECIPIENT_TYPES
          if parameters.key?('recipient_types')
            recipient_types = parameters['recipient_types']
            parameters.delete('recipient_types')
            recipient_types = [recipient_types] unless recipient_types.is_a?(Array)
          end
          parameters['recipients'].map! do |recipient_data|
            # if just a string, assume it is the name
            if recipient_data.is_a?(String)
              matched = @api_v5.lookup_by_name('contacts', recipient_data, {context: 'packages', type: Rest.array_params(recipient_types)})
              recipient_data = {
                name:           matched['name'],
                recipient_type: matched['type']
              }
            end
            # result for mapping
            recipient_data
          end
        end

        # wait for package status to be in provided list
        def wait_package_status(id, status_list=PACKAGE_TERMINATED)
          parameters = options.get_option(:value)
          spinner = nil
          progress = nil
          while true
            status = @api_v5.read("packages/#{id}/upload_details")[:data]
            # user asked to not follow
            break unless parameters
            if status['upload_status'].eql?('submitted')
              if spinner.nil?
                spinner = TTY::Spinner.new('[:spinner] :title', format: :classic)
                spinner.start
              end
              spinner.update(title: status['upload_status'])
              spinner.spin
            elsif progress.nil?
              progress = ProgressBar.create(
                format:     '%a %B %p%% %r Mbps %e',
                rate_scale: lambda{|rate|rate / Environment::BYTES_PER_MEBIBIT},
                title:      'progress',
                total:      status['bytes_total'].to_i)
            else
              progress.progress = status['bytes_written'].to_i
            end
            break if status_list.include?(status['upload_status'])
            sleep(0.5)
          end
          status['id'] = id
          return status
        end

        # get a list of all entities of a given type
        # @param entity_type [String] the type of entity to list
        # @param query [Hash] additional query parameters
        # @param prefix [String] optional prefix to add to the path (nil or empty string: no prefix)
        def list_entities(entity_type, query: {}, prefix: nil)
          path = entity_type
          path = "#{prefix}/#{path}" unless prefix.nil? || prefix.empty?
          result = []
          offset = 0
          max_items = query.delete(MAX_ITEMS)
          remain_pages = query.delete(MAX_PAGES)
          # merge default parameters, by default 100 per page
          query = {'limit'=> 100}.merge(query)
          loop do
            query['offset'] = offset
            page = @api_v5.read(path, query)[:data]
            result.concat(page[entity_type])
            # reach the limit set by user ?
            if !max_items.nil? && (result.length >= max_items)
              result = result.slice(0, max_items)
              break
            end
            break if result.length >= page['total_count']
            remain_pages -= 1 unless remain_pages.nil?
            break if remain_pages == 0
            offset += page[entity_type].length
          end
          return result
        end

        # lookup an entity id from its name
        def lookup_name_to_id(entity_type, name)
          found = list_entities(entity_type, query: {'q'=> name}).select{|i|i['name'].eql?(name)}
          case found.length
          when 0 then raise "No #{entity_type} with name = #{name}"
          when 1 then return found.first['id']
          else raise "Multiple #{entity_type} with name = #{name}"
          end
        end

        # translate box name to API prefix (with ending slash)
        def box_to_prefix(box)
          return \
          case box
          when VAL_ALL then ''
          when *API_MAILBOXES then box
          else "shared_inboxes/#{lookup_name_to_id('shared_inboxes', box)}"
          end
        end

        # list all packages with optional filter
        def list_packages
          parameters = options.get_option(:value) || {}
          return list_entities('packages', query: parameters, prefix: box_to_prefix(options.get_option(:box)))
        end

        def package_action
          command = options.get_next_command(%i[list show browse status delete send receive])
          case command
          when :list
            return {
              type:   :object_list,
              data:   list_packages,
              fields: %w[id title release_date total_bytes total_files created_time state]
            }
          when :show
            id = @pub_link_context['package_id'] if @pub_link_context&.key?('package_id')
            id ||= instance_identifier
            return {type: :single_object, data: @api_v5.read("packages/#{id}")[:data]}
          when :browse
            id = @pub_link_context['package_id'] if @pub_link_context&.key?('package_id')
            id ||= instance_identifier
            path = options.get_next_argument('path', expected: :single, mandatory: false) || '/'
            # TODO: support multi-page listing ?
            params = {
              # recipient_user_id: 25,
              # offset:            0,
              # limit:             25
            }
            result = @api_v5.call({
              operation:   'POST',
              subpath:     "packages/#{id}/files/received",
              headers:     {'Accept' => 'application/json'},
              url_params:  params,
              json_params: {'path' => path, 'filters' => {'basenames'=>[]}}})[:data]
            formatter.display_item_count(result['item_count'], result['total_count'])
            return {type: :object_list, data: result['items']}
          when :status
            status = wait_package_status(instance_identifier)
            return {type: :single_object, data: status}
          when :delete
            ids = instance_identifier
            ids = [ids] unless ids.is_a?(Array)
            raise 'Package identifier must be a single id or an Array' unless ids.is_a?(Array) && ids.all?(String)
            # API returns 204, empty on success
            @api_v5.call({operation: 'DELETE', subpath: 'packages', headers: {'Accept' => 'application/json'}, json_params: {ids: ids}})
            return Main.result_status('Package(s) deleted')
          when :send
            parameters = options.get_option(:value, is_type: :mandatory)
            raise CliBadArgument, 'Value must be Hash, refer to API' unless parameters.is_a?(Hash)
            normalize_recipients(parameters)
            package = @api_v5.create('packages', parameters)[:data]
            shared_folder = options.get_option(:shared_folder)
            if shared_folder.nil?
              # TODO: option to send from remote source or httpgw
              transfer_spec = @api_v5.call(
                operation:   'POST',
                subpath:     "packages/#{package['id']}/transfer_spec/upload",
                headers:     {'Accept' => 'application/json'},
                url_params:  {transfer_type: TRANSFER_CONNECT},
                json_params: {paths: transfer.source_list}
              )[:data]
              # well, we asked a TS for connect, but we actually want a generic one
              transfer_spec.delete('authentication')
              return Main.result_transfer(transfer.start(transfer_spec))
            else
              if (m = shared_folder.match(REGEX_LOOKUP_ID_BY_FIELD))
                shared_folder = lookup_name_to_id('shared_folders', m[2])
              end
              transfer_request = {shared_folder_id: shared_folder, paths: transfer.source_list}
              # start remote transfer and get first status
              result = @api_v5.create("packages/#{package['id']}/remote_transfer", transfer_request)[:data]
              result['id'] = package['id']
              unless result['status'].eql?('completed')
                formatter.display_status("Package #{package['id']}")
                result = wait_package_status(package['id'])
              end
              return {type: :single_object, data: result}
            end
          when :receive
            # prepare persistency if needed
            skip_ids_persistency = nil
            if options.get_option(:once_only, is_type: :mandatory)
              # read ids from persistency
              skip_ids_persistency = PersistencyActionOnce.new(
                manager: @agents[:persistency],
                data:    [],
                id:      IdGenerator.from_list([
                  'faspex_recv',
                  options.get_option(:url, is_type: :mandatory),
                  options.get_option(:username, is_type: :mandatory),
                  PACKAGE_TYPE_RECEIVED]))
            end
            # one or several packages
            package_ids = @pub_link_context['package_id'] if @pub_link_context&.key?('package_id')
            package_ids ||= instance_identifier
            case package_ids
            when PACKAGE_ALL_INIT
              raise 'Only with option once_only' unless skip_ids_persistency
              skip_ids_persistency.data.clear.concat(list_packages.map{|p|p['id']})
              skip_ids_persistency.save
              return Main.result_status("Initialized skip for #{skip_ids_persistency.data.count} package(s)")
            when VAL_ALL
              # TODO: if packages have same name, they will overwrite ?
              package_ids = list_packages.map{|p|p['id']}
              Log.dump(:package_ids, package_ids)
              Log.dump(:package_ids, skip_ids_persistency.data)
              package_ids.reject!{|i|skip_ids_persistency.data.include?(i)} if skip_ids_persistency
              Log.dump(:package_ids, package_ids)
            end
            # a single id was provided
            # TODO: check package_ids is a list of strings
            package_ids = [package_ids] if package_ids.is_a?(String)
            result_transfer = []
            package_ids.each do |pkg_id|
              formatter.display_status("Receiving package #{pkg_id}")
              param_file_list = {}
              begin
                param_file_list['paths'] = transfer.source_list.map{|source|{'path'=>source}}
              rescue Aspera::Cli::CliBadArgument
                # paths is optional
              end
              # TODO: allow from sent as well ?
              transfer_spec = @api_v5.call(
                operation:   'POST',
                subpath:     "packages/#{pkg_id}/transfer_spec/download",
                headers:     {'Accept' => 'application/json'},
                url_params:  {transfer_type: TRANSFER_CONNECT, type: PACKAGE_TYPE_RECEIVED},
                json_params: param_file_list
              )[:data]
              # delete flag for Connect Client
              transfer_spec.delete('authentication')
              statuses = transfer.start(transfer_spec)
              result_transfer.push({'package' => pkg_id, Main::STATUS_FIELD => statuses})
              # skip only if all sessions completed
              if TransferAgent.session_status(statuses).eql?(:success) && skip_ids_persistency
                skip_ids_persistency.data.push(pkg_id)
                skip_ids_persistency.save
              end
            end
            return Main.result_transfer_multiple(result_transfer)
          end # case package
        end

        ACTIONS = %i[health version user bearer_token packages shared_folders admin gateway postprocessing].freeze

        def execute_action
          command = options.get_next_command(ACTIONS)
          set_api unless command.eql?(:postprocessing)
          case command
          when :version
            return { type: :single_object, data: @api_v5.read('version')[:data] }
          when :health
            nagios = Nagios.new
            begin
              result = Rest.new(base_url: @faspex5_api_base_url).read('health')[:data]
              result.each do |k, v|
                nagios.add_ok(k, v.to_s)
              end
            rescue StandardError => e
              nagios.add_critical('faspex api', e.to_s)
            end
            return nagios.result
          when :user
            case options.get_next_command(%i[profile])
            when :profile
              case options.get_next_command(%i[show modify])
              when :show
                return { type: :single_object, data: @api_v5.read('account/preferences')[:data] }
              when :modify
                @api_v5.update('account/preferences', options.get_next_argument('modified parameters', type: Hash))
                return Main.result_status('modified')
              end
            end
          when :bearer_token
            return {type: :text, data: @api_v5.oauth_token}
          when :packages
            return package_action
          when :shared_folders
            all_shared_folders = @api_v5.read('shared_folders')[:data]['shared_folders']
            case options.get_next_command(%i[list browse])
            when :list
              return {type: :object_list, data: all_shared_folders}
            when :browse
              shared_folder_id = instance_identifier do |field, value|
                matches = all_shared_folders.select{|i|i[field].eql?(value)}
                raise "no match for #{field} = #{value}" if matches.empty?
                raise "multiple matches for #{field} = #{value}" if matches.length > 1
                matches.first['id']
              end
              path = options.get_next_argument('folder path', mandatory: false) || '/'
              node = all_shared_folders.find{|i|i['id'].eql?(shared_folder_id)}
              raise "No such shared folder id #{shared_folder_id}" if node.nil?
              result = @api_v5.call({
                operation:   'POST',
                subpath:     "nodes/#{node['node_id']}/shared_folders/#{shared_folder_id}/browse",
                headers:     {'Accept' => 'application/json', 'Content-Type' => 'application/json'},
                json_params: {'path': path, 'filters': {'basenames': []}},
                url_params:  {offset: 0, limit: 100}
              })[:data]
              if result.key?('items')
                return {type: :object_list, data: result['items']}
              else
                return {type: :single_object, data: result['self']}
              end
            end
          when :admin
            case options.get_next_command(%i[resource smtp])
            when :resource
              res_type = options.get_next_command(%i[accounts contacts jobs workgroups shared_inboxes nodes oauth_clients registrations saml_configs metadata_profiles
                                                     email_notifications])
              res_path = list_key = res_type.to_s
              id_as_arg = false
              case res_type
              when :metadata_profiles
                res_path = 'configuration/metadata_profiles'
                list_key = 'profiles'
              when :email_notifications
                list_key = false
                id_as_arg = 'type'
              end
              display_fields =
                case res_type
                when :accounts then [:all_but, 'user_profile_data_attributes']
                when :oauth_clients then [:all_but, 'public_key']
                end
              adm_api = @api_v5
              if res_type.eql?(:oauth_clients)
                adm_api = Rest.new(@api_v5.params.merge({base_url: @faspex5_api_auth_url}))
              end
              return entity_action(adm_api, res_path, item_list_key: list_key, display_fields: display_fields, id_as_arg: id_as_arg)
            when :smtp
              smtp_path = 'configuration/smtp'
              case options.get_next_command(%i[show create modify delete test])
              when :show
                return { type: :single_object, data: @api_v5.read(smtp_path)[:data] }
              when :create
                return { type: :single_object, data: @api_v5.create(smtp_path, options.get_option(:value, is_type: :mandatory))[:data] }
              when :modify
                return { type: :single_object, data: @api_v5.modify(smtp_path, options.get_option(:value, is_type: :mandatory))[:data] }
              when :delete
                return { type: :single_object, data: @api_v5.delete(smtp_path)[:data] }
              when :test
                test_data = options.get_next_argument('Email or test data, see API')
                test_data = {test_email_recipient: test_data} if test_data.is_a?(String)
                return { type: :single_object, data: @api_v5.create(File.join(smtp_path, 'test'), test_data)[:data] }
              end
            end
          when :gateway
            require 'aspera/faspex_gw'
            url = options.get_option(:value, is_type: :mandatory)
            uri = URI.parse(url)
            server = WebServerSimple.new(uri)
            server.mount(uri.path, Faspex4GWServlet, @api_v5, nil)
            trap('INT') { server.shutdown }
            formatter.display_status("Faspex 4 gateway listening on #{url}")
            Log.log.info("Listening on #{url}")
            # this is blocking until server exits
            server.start
            return Main.result_status('Gateway terminated')
          when :postprocessing
            require 'aspera/faspex_postproc'
            parameters = options.get_option(:value, is_type: :mandatory)
            raise 'parameters must be Hash' unless parameters.is_a?(Hash)
            parameters = parameters.symbolize_keys
            raise 'Missing key: url' unless parameters.key?(:url)
            uri = URI.parse(parameters[:url])
            parameters[:processing] ||= {}
            parameters[:processing][:root] = uri.path
            server = WebServerSimple.new(uri, certificate: parameters[:certificate])
            server.mount(uri.path, Faspex4PostProcServlet, parameters[:processing])
            trap('INT') { server.shutdown }
            formatter.display_status("Faspex 4 post processing listening on #{uri.port}")
            Log.log.info("Listening on #{uri.port}")
            # this is blocking until server exits
            server.start
            return Main.result_status('Gateway terminated')
          end # case command
        end # action

        def wizard(params)
          if params[:prepare]
            # if not defined by user, generate unique name
            params[:preset_name] ||= [params[:plugin_sym]].concat(URI.parse(params[:instance_url]).host.gsub(/[^a-z0-9.]/, '').split('.')).join('_')
            params[:need_private_key] = true
            return
          end
          formatter.display_status('Ask the ascli client id and secret to your Administrator, or ask them to go to:'.red)
          OpenApplication.instance.uri(params[:instance_url])
          formatter.display_status('Then: 𓃑  → Admin → Configurations → API clients')
          formatter.display_status('Create an API client with:')
          formatter.display_status('- name: ascli')
          formatter.display_status('- JWT: enabled')
          formatter.display_status('Then, logged in as user go to your profile:')
          formatter.display_status('👤 → Account Settings → Preferences -> Public Key in PEM:')
          formatter.display_status(params[:pub_key_pem])
          formatter.display_status('Once set, fill in the parameters:')
          return {
            preset_value: {
              url:           params[:instance_url],
              username:      options.get_option(:username, is_type: :mandatory),
              auth:          :jwt.to_s,
              private_key:   '@file:' + params[:private_key_path],
              client_id:     options.get_option(:client_id, is_type: :mandatory),
              client_secret: options.get_option(:client_secret, is_type: :mandatory)
            },
            test_args:    "#{params[:plugin_sym]} user profile show"
          }
        end
      end # Faspex5
    end # Plugins
  end # Cli
end # Aspera
