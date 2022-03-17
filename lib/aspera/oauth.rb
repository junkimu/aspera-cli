# frozen_string_literal: true
require 'aspera/open_application'
require 'aspera/web_auth'
require 'aspera/id_generator'
require 'base64'
require 'date'
require 'socket'
require 'securerandom'

module Aspera
  # Implement OAuth 2 for the REST client and generate a bearer token
  # call get_authorization() to get a token.
  # bearer tokens are kept in memory and also in a file cache for later re-use
  # if a token is expired (api returns 4xx), call again get_authorization({refresh: true})
  # https://tools.ietf.org/html/rfc6749
  class Oauth
    DEFAULT_CREATE_PARAMS={
      token_field:    'access_token', # field with token in result
      path_token:     'token', # default endpoint for /token to generate token
      web:            {path_authorize: 'authorize'} # default endpoint for /authorize, used for code exchange
    }.freeze

    # OAuth methods supported by default
    STD_AUTH_TYPES=[:web, :jwt].freeze

    # remove 5 minutes to account for time offset (TODO: configurable?)
    JWT_NOTBEFORE_OFFSET_SEC=300
    # one hour validity (TODO: configurable?)
    JWT_EXPIRY_OFFSET_SEC=3600
    # tokens older than 30 minutes will be discarded from cache
    TOKEN_CACHE_EXPIRY_SEC=1800
    # a prefix for persistency of tokens (garbage collect)
    PERSIST_CATEGORY_TOKEN='token'
    TOKEN_EXPIRATION_GUARD_SEC=120

    private_constant :JWT_NOTBEFORE_OFFSET_SEC,:JWT_EXPIRY_OFFSET_SEC,:TOKEN_CACHE_EXPIRY_SEC,:PERSIST_CATEGORY_TOKEN,:TOKEN_EXPIRATION_GUARD_SEC

    # persistency manager
    @persist=nil
    # token creation methods
    @handlers={}
    # token unique identifiers from oauth parameters
    @id_elements=[
      [:scope],
      [:crtype],
      [:auth,:username],
      [:jwt,:payload,:sub],
      [:generic,:grant_type],
      [:generic,:apikey],
      [:generic,:response_type],
      [:aoc_pub_link,:json,:url_token]
      ]

    class << self
      def persist_mgr=(manager)
        @persist=manager
        # cleanup expired tokens
        @persist.garbage_collect(PERSIST_CATEGORY_TOKEN,TOKEN_CACHE_EXPIRY_SEC)
      end

      def persist_mgr
        if @persist.nil?
          Log.log.debug('Not using persistency') # (use Aspera::Oauth.persist_mgr=Aspera::PersistencyFolder.new)
          # create NULL persistency class
          @persist=Class.new do
            def get(_x);nil;end;def delete(_x);nil;end;def put(_x,_y);nil;end;def garbage_collect(_x,_y);nil;end # rubocop:disable Layout/EmptyLineBetweenDefs
          end.new
        end
        return @persist
      end

      # delete all existing tokens
      def flush_tokens
        persist_mgr.garbage_collect(PERSIST_CATEGORY_TOKEN,nil)
      end

      def register_decoder(method)
        @decoders||=[]
        @decoders.push(method)
      end

      def decode_token(token)
        @decoders.each do |decoder|
          result=decoder.call(token) rescue nil
          return result unless result.nil?
        end
        return nil
      end

      def register_token_creator(id, method)
        raise 'error' unless id.is_a?(Symbol) && method.is_a?(Proc)
        @handlers[id]=method
      end

      def token_creator(id)
        raise "token create type unknown: #{id}/#{id.class}" unless @handlers.has_key?(id)
        @handlers[id]
      end
      
      def id_elements
        return @id_elements
      end
    end # self

    # seems to be quite standard token encoding (RFC?)
    register_decoder lambda { |token| parts=token.split('.'); raise 'not aoc token' unless parts.length.eql?(3); JSON.parse(Base64.decode64(parts[1]))}

    attr_reader :params, :token_auth_api

    private

    # [M]=mandatory [D]=has default value [0]=accept nil
    # :base_url            [M]
    # :auth
    # :crtype              [M]  :generic, :web, :jwt, custom
    # :client_id           [0]
    # :client_secret       [0]
    # :scope               [0]
    # :path_token          [D]
    # :token_field         [D]
    # :jwt:private_key_obj [M] for type :jwt
    # :jwt:payload         [M] for type :jwt
    # :jwt:headers         [0] for type :jwt
    # :web:redirect_uri    [M] for type :web
    # :web:path_authorize  [D] for type :web
    def initialize(a_params)
      Log.log.debug("auth=#{a_params}")
      # replace default values
      @params=DEFAULT_CREATE_PARAMS.clone.deep_merge(a_params)
      rest_params={base_url: @params[:base_url]}
      rest_params[:auth]=a_params[:auth] if a_params.has_key?(:auth)
      @token_auth_api=Rest.new(rest_params)
      if @params.has_key?(:redirect_uri)
        uri=URI.parse(@params[:web][:redirect_uri])
        raise 'redirect_uri scheme must be http or https' unless ['http','https'].include?(uri.scheme)
        raise 'redirect_uri must have a port' if uri.port.nil?
        # we could check that host is localhost or local address
      end
    end

    def create_token(www_params)
      return @token_auth_api.call({
        operation:       'POST',
        subpath:         @params[:path_token],
        headers:         {'Accept'=>'application/json'},
        www_body_params: www_params})
    end

    def create_token_generic
      return create_token(@params[:generic])
    end

    # Web browser based Auth
    def create_token_web
      callback_verif=SecureRandom.uuid # used to check later
      login_page_url=Rest.build_uri("#{@params[:base_url]}/#{@params[:web][:path_authorize]}",optional_scope_client_id({response_type: 'code', redirect_uri:  @params[:web][:redirect_uri], state: callback_verif}))
      # here, we need a human to authorize on a web page
      Log.log.info("login_page_url=#{login_page_url}".bg_red.gray)
      # start a web server to receive request code
      webserver=WebAuth.new(@params[:web][:redirect_uri])
      # start browser on login page
      OpenApplication.instance.uri(login_page_url)
      # wait for code in request
      received_params=webserver.received_request
      raise 'state does not match' if !callback_verif.eql?(received_params['state'])
      # exchange code for token
      return create_token(optional_scope_client_id({grant_type: 'authorization_code', code: received_params['code'], redirect_uri: @params[:web][:redirect_uri]},add_secret: true))
    end

    # private key based Auth
    def create_token_jwt
      # https://tools.ietf.org/html/rfc7523
      # https://tools.ietf.org/html/rfc7519
      require 'jwt'
      seconds_since_epoch=Time.new.to_i
      Log.log.info("seconds=#{seconds_since_epoch}")
      raise "missing jwt payload" unless @params[:jwt][:payload].is_a?(Hash)
      jwt_payload = {
        exp: seconds_since_epoch+JWT_EXPIRY_OFFSET_SEC, # expiration time
        nbf: seconds_since_epoch-JWT_NOTBEFORE_OFFSET_SEC, # not before
        iat: seconds_since_epoch, # issued at
        jti: SecureRandom.uuid # JWT id
      }.merge(@params[:jwt][:payload])
      Log.log.debug("JWT jwt_payload=[#{jwt_payload}]")
      rsa_private=@params[:jwt][:private_key_obj] # type: OpenSSL::PKey::RSA
      Log.log.debug("private=[#{rsa_private}]")
      assertion = JWT.encode(jwt_payload, rsa_private, 'RS256', @params[:jwt][:headers]||{})
      Log.log.debug("assertion=[#{assertion}]")
      return create_token(optional_scope_client_id({grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion:  assertion}))
    end

    # @return unique identifier of token
    # TODO: external handlers shall provide unique identifiers
    def token_cache_id
      oauth_uri=URI.parse(@params[:base_url])
      parts=[PERSIST_CATEGORY_TOKEN,oauth_uri.host,oauth_uri.path]
      # add some of the parameters that uniquely identify the token
      self.class.id_elements.each do |p|
        identifier=@params.dig(*p)
        identifier=identifier.split(':').last if identifier.is_a?(String) && p.last.eql?(:grant_type)
        parts.push(identifier) unless identifier.nil?
      end
      return IdGenerator.from_list(parts)
    end

    public

    # used to change parameter, such as scope
    attr_reader :params

    def optional_scope_client_id(call_params, add_secret: false)
      call_params[:scope] = @params[:scope] unless @params[:scope].nil?
      call_params[:client_id] = @params[:client_id] unless @params[:client_id].nil?
      call_params[:client_secret] = @params[:client_secret] if add_secret && !@params[:client_id].nil?
      return call_params
    end

    # Oauth v2 token generation
    # @param use_refresh_token set to true to force refresh or re-generation (if previous failed)
    def get_authorization(use_refresh_token: false)
      # generate token unique identifier for persistency (memory/disk cache)
      token_id=token_cache_id

      # get token_data from cache (or nil), token_data is what is returned by /token
      token_data=self.class.persist_mgr.get(token_id)
      token_data=JSON.parse(token_data) unless token_data.nil?
      # Optional optimization: check if node token is expired  basd on decoded content then force refresh if close enough
      # might help in case the transfer agent cannot refresh himself
      # `direct` agent is equipped with refresh code
      if !use_refresh_token && !token_data.nil?
        decoded_token = self.class.decode_token(token_data[@params[:token_field]])
        Log.dump('decoded_token',decoded_token) unless decoded_token.nil?
        if decoded_token.is_a?(Hash)
          expires_at_sec=
          if    decoded_token['expires_at'].is_a?(String) then DateTime.parse(decoded_token['expires_at']).to_time
          elsif decoded_token['exp'].is_a?(Integer)       then Time.at(decoded_token['exp'])
          else  nil
          end
          use_refresh_token=true if expires_at_sec.is_a?(Time) && (expires_at_sec-Time.now) < TOKEN_EXPIRATION_GUARD_SEC
          Log.log.debug("Expiration: #{expires_at_sec} / #{use_refresh_token}")
        end
      end

      # an API was already called, but failed, we need to regenerate or refresh
      if use_refresh_token
        if token_data.is_a?(Hash) && token_data.has_key?('refresh_token')
          # save possible refresh token, before deleting the cache
          refresh_token=token_data['refresh_token']
        end
        # delete cache
        self.class.persist_mgr.delete(token_id)
        token_data=nil
        # lets try the existing refresh token
        if !refresh_token.nil?
          Log.log.info("refresh=[#{refresh_token}]".bg_green)
          # try to refresh
          # note: AoC admin token has no refresh, and lives by default 1800secs
          resp=create_token(optional_scope_client_id({grant_type: 'refresh_token',refresh_token: refresh_token}))
          if resp[:http].code.start_with?('2')
            # save only if success
            json_data=resp[:http].body
            token_data=JSON.parse(json_data)
            self.class.persist_mgr.put(token_id,json_data)
          else
            Log.log.debug("refresh failed: #{resp[:http].body}".bg_red)
          end
        end
      end

      # no cache
      if token_data.nil?
        resp=
        case @params[:crtype]
        when :generic then create_token_generic
        when :web then     create_token_web
        when :jwt then     create_token_jwt
        else               self.class.token_creator(@params[:crtype]).call(self)
        end
        # TODO: test return code ?
        json_data=resp[:http].body
        token_data=JSON.parse(json_data)
        self.class.persist_mgr.put(token_id,json_data)
      end # if ! in_cache
      raise "API error: No such field in answer: #{@params[:token_field]}" unless token_data.has_key?(@params[:token_field])
      # ok we shall have a token here
      return 'Bearer '+token_data[@params[:token_field]]
    end
  end # OAuth
end # Aspera
