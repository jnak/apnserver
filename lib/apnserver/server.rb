require 'eventmachine'
require 'apnserver/server_connection'
require 'logger'

module ApnServer
  class Server
    attr_accessor :client, :bind_address, :port

    def initialize(pem, bind_address = '0.0.0.0', port = 22195, log = '/apnserverd.log')
      @queue = EM::Queue.new
      @client = ApnServer::Client.new(pem)
      @bind_address, @port = bind_address, port
      if log == STDOUT
        Config.logger = Logger.new STDOUT
      else
        f = File.open(log, File::WRONLY | File::APPEND)
        Config.logger = Logger.new(f, 'daily')
      end
    end

    def start!
      EventMachine::run do
        Config.logger.info "#{Time.now} Starting APN Server on #{bind_address}:#{port}"

        EM.start_server(bind_address, port, ApnServer::ServerConnection) do |s|
          s.queue = @queue
        end

        EventMachine::PeriodicTimer.new(0.01) do
          unless @queue.empty?
            size = @queue.size
            size.times do
              @queue.pop do |notification|
                retries = 2
                begin
                  @client.connect! unless @client.connected?
                  @client.write(notification)
                rescue Errno::EPIPE, OpenSSL::SSL::SSLError, Errno::ECONNRESET
                  if retries == 2
                    Config.logger.error "Connection to APN servers idle for too long. Trying to reconnect"
                    @client.disconnect!
                    retries -= 1
                    retry
                  else
                    Config.logger.error "Can't reconnect to APN Servers! Pushing notifications back to queue"
                    @client.disconnect! 
                    @queue.push(notification)
                  end
                rescue RuntimeError => e
                  Config.logger.error "Unable to handle: #{e}"
                end
              end
            end
          end
        end
      end
    end
  end
end
