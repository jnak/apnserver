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
      @loggr = Logger.new(log)
    end

    def start!
      EventMachine::run do
        @loggr.info "#{Time.now} Starting APN Server on #{bind_address}:#{port}"

        EM.start_server(bind_address, port, ApnServer::ServerConnection) do |s|
          s.queue = @queue
        end

        EventMachine::PeriodicTimer.new(1) do
          unless @queue.empty?
            size = @queue.size
            size.times do
              @queue.pop do |notification|
                begin
                  @client.connect! unless @client.connected?
                  @client.write(notification)
                rescue Errno::EPIPE, OpenSSL::SSL::SSLError
                  @loggr.error "Caught Error, closing connecting and adding notification back to queue"
                  @client.disconnect!
                  @queue.push(notification)
                rescue RuntimeError => e
                  @loggr.error "Unable to handle: #{e}"
                end
              end
            end
          end
        end
      end
    end
  end
end
