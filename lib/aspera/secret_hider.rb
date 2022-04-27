# frozen_string_literal: true

require 'logger'

module Aspera
  # remove secret from logs and output
  class SecretHider
    # display string for hidden secrets
    HIDDEN_PASSWORD = '🔑'
    # keys in hash that contain secrets
    SECRET_KEYWORDS = %w[password secret private_key passphrase].freeze
    # regex that define namec captures :begin and :end
    REGEX_LOG_REPLACES=[
      # replace values in logs with rendered JSON
      /(?<begin>["':][^"]*(#{SECRET_KEYWORDS.join('|')})[^"]*["']?[=>: ]+")[^"]+(?<end>")/,
      # option "secret"
      /(?<begin>"[^"]*(secret)[^"]*"=>{)[^}]+(?<end>})/,
      # option "secrets"
      /(?<begin>(secrets)={)[^}]+(?<end>})/,
      # private key values
      /(?<begin>--+BEGIN .+ KEY--+)[[:ascii:]]+?(?<end>--+?END .+ KEY--+)/
    ].freeze
    private_constant :HIDDEN_PASSWORD,:SECRET_KEYWORDS
    @log_secrets = false
    class << self
      attr_accessor :log_secrets
      def log_formatter(original_formatter)
        original_formatter ||= Logger::Formatter.new
        # note that @log_secrets may be set AFTER this init is done, so it's done at runtime
        return lambda do |severity, datetime, progname, msg|
          if msg.is_a?(String) && !@log_secrets
            REGEX_LOG_REPLACES.each do |regx|
              msg = msg.gsub(regx){"#{Regexp.last_match(:begin)}#{HIDDEN_PASSWORD}#{Regexp.last_match(:end)}"}
            end
          end
          original_formatter.call(severity, datetime, progname, msg)
        end
      end

      def secret?(keyword,value)
        keyword=keyword.to_s if keyword.is_a?(Symbol)
        # only Strings can be secrets, not booleans, or hash, arrays
        keyword.is_a?(String) && SECRET_KEYWORDS.any?{|kw|keyword.include?(kw)} && value.is_a?(String)
      end

      def deep_remove_secret(obj,is_name_value: false)
        case obj
        when Array
          if is_name_value
            obj.each do |i|
              i['value']=HIDDEN_PASSWORD if secret?(i['parameter'],i['value'])
            end
          else
            obj.each{|i|deep_remove_secret(i)}
          end
        when Hash
          obj.each do |k,v|
            if secret?(k,v)
              obj[k] = HIDDEN_PASSWORD
            elsif obj[k].is_a?(Hash)
              deep_remove_secret(obj[k])
            end
          end
        end
      end
    end
  end
end