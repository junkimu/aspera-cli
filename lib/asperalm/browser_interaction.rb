# Laurent/Aspera
# a code listener will listen on a tcp port, redirect the user to a login page
# and wait for the browser to send the request with code on local port

# on mac
# brew install chromedriver
# gem install watir-webdriver

require 'socket'
require 'logger'
require 'pp'

module Asperalm
  class BrowserInteraction
    def self.getter_types
      [ :tty, :watir, :osbrowser ]
    end

    # uitype: :watir, or :tty, or :osbrowser
    def initialize(logger,redirect_uri,uitype)
      @logger=logger
      @redirect_uri=redirect_uri
      @login_type=uitype
      @browser=nil
      @creds=nil
      @code=nil
      @mutex = Mutex.new
      @is_logged_in=false
    end

    def redirect_uri
      return @redirect_uri
    end

    def terminate
      if !@browser.nil? then
        @browser.close
      end
    end

    def set_creds(username,password)
      @creds={:user=>username,:password=>password}
    end

    def start_listener
      Thread.new {
        @mutex.synchronize {
          port=URI.parse(redirect_uri).port
          @logger.info "listening on port #{port}"
          TCPServer.open('127.0.0.1', port) { |webserver|
            @logger.info "server=#{webserver}"
            websession = webserver.accept
            line = websession.gets.chomp
            @logger.info "line=#{line}"
            if ! line.start_with?('GET /?') then
              raise "unexpected request"
            end
            request = line.partition('?').last.partition(' ').first
            data=URI.decode_www_form(request)
            @logger.info "data=#{PP.pp(data,'').chomp}"
            code=data[0][1]
            @logger.info "code=#{PP.pp(code,'').chomp}"
            websession.print "HTTP/1.1 200/OK\r\nContent-type:text/html\r\n\r\n<html><body><h1>received answer (code)</h1><code>#{code}</code></body></html>"
            websession.close
            @code=code
          }
        }
      }
    end

    def get_code
      @mutex.synchronize {
        return @code
      }
    end

    def goto_page_and_get_code(the_url)
      @logger.info "the_url=#{the_url}".bg_red().gray()
      start_listener()
      case @login_type
      when :watir
        if @browser.nil? then
          require 'watir-webdriver'
          @browser = Watir::Browser.new(:chrome)
          #@browser.window.move_to(0,0)
        end
        @browser.goto the_url.to_s
        if !@creds.nil? then
          begin
            if ! @is_logged_in then
              @browser.text_field(name: 'login').set(@creds[:user])
              @browser.text_field(name: 'password').set(@creds[:password])
              @browser.button(name: 'commit').click
              @is_logged_in=true
            end
            @browser.link(:text =>"Allow").when_present.click
            @browser.link(:text =>"Continue").when_present.click
          rescue => e
            @logger.info "ignoring browser error: "+e.message
          end
        end
      when :osbrowser
        #TODO: only on mac...
        system("open '#{the_url.to_s}'")
      when :tty
        puts "USER ACTION: please enter this url in a browser:\n"+the_url.to_s.red()+"\n"
      else
        raise 'choose open method'
      end
      code=get_code()
      return code
    end

  end
end # Asperalm
