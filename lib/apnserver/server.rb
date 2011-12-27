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
      elsif File.exist?(log)
        @flog = File.open(log, File::WRONLY | File::APPEND)
        Config.logger = Logger.new(@flog, 'daily')
      else
        FileUtils.mkdir_p(File.dirname(log))
	      @flog = File.open(log, File::WRONLY | File::APPEND | File::CREAT)
        Config.logger = Logger.new(@flog, 'daily')
      end
      @last_conn_time = Time.now
    end

    def start!
      EventMachine::run do
        Config.logger.info "#{Time.now} Starting APN Server on #{bind_address}:#{port}"

        EM.start_server(bind_address, port, ApnServer::ServerConnection) do |s|
          s.queue = @queue
        end
        
        EM::Synchrony.add_periodic_timer(5) { @flog.flush if @flog }

        EventMachine::PeriodicTimer.new(0.01) do
          unless @queue.empty?
            size = @queue.size
            size.times do
              @queue.pop do |notification|
                retries = 2
                begin
                  if @client.connected? && (@last_conn_time + 1000) < Time.now
                    Config.logger.error 'Disconnecting connection to APN'
		                @client.disconnect!
                    @last_conn_time = Time.now
                  end
                  unless @client.connected?
                    Config.logger.info "Reconnecting to APN servers"
		                @client.connect!
		              end
                  Config.logger.debug 'Sending notification to APN'
		              @client.write(notification)
		              Config.logger.debug 'Notif sent'
                rescue Errno::EPIPE, OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::ETIMEDOUT
                  if retries > 1
                    Config.logger.error "Connection to APN servers idle for too long. Trying to reconnect"
                    @client.disconnect!
                    @last_conn_time = Time.now
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
