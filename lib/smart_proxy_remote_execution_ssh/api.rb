require 'net/ssh'
require 'forwardable'

# When hijacking the socket of a TLS connection, we get a
# OpenSSL::SSL::SSLSocket or Puma::MiniSSL::Socket, which don't behave
# the same as real IO::Sockets.  We need to add recv and send for the
# benefit of the Net::SSH::BufferedIo mixin, and closed? for our own
# convenience.


module Proxy::RemoteExecution
  module Ssh
    class BufferedSocket
      include Net::SSH::BufferedIo
      extend Forwardable

      # The list of methods taken from OpenSSL::SSL::SocketForwarder for the object to act like a socket
      def_delegators(:@socket, :to_io, :addr, :peeraddr, :setsockopt, :getsockopt, :fcntl, :close, :closed?, :do_not_reverse_lookup=)

      def initialize(socket)
        @socket = socket
        initialize_buffered_io
      end

      def resv
        raise NotImplementedError
      end

      def send
        raise NotImplementedError
      end

      def self.applies_for?(socket)
        raise NotImplementedError
      end

      def self.build(socket)
        klass = [PumaBufferedSocket, OpenSSLBufferedSocket, StandardBufferedSocket].find do |potential_class|
          potential_class.applies_for?(socket)
        end
        raise "No suitable implementation of buffered socket available for #{socket.inspect}" unless klass
        klass.new(socket)
      end
    end

    class StandardBufferedSocket < BufferedSocket
      def_delegators(:@socket, :send, :recv)

      def self.applies_for?(socket)
        socket.respond_to?(:send) && socket.respond_to?(:recv)
      end
    end

    class OpenSSLBufferedSocket < BufferedSocket
      def self.applies_for?(socket)
        socket.is_a? ::OpenSSL::SSL::SSLSocket
      end
      def_delegators(:@socket, :read_nonblock, :write_nonblock, :close)

      def recv(n)
        res = ""
        begin
          # To drain a SSLSocket before we can go back to the event
          # loop, we need to repeatedly call read_nonblock; a single
          # call is not enough.
          while true
            res += @socket.read_nonblock(n)
          end
        rescue IO::WaitReadable
          # Sometimes there is no payload after reading everything
          # from the underlying socket, but a empty string is treated
          # as EOF by Net::SSH. So we block a bit until we have
          # something to return.
          if res == ""
            IO.select([@socket.to_io])
            retry
          else
            res
          end
        rescue IO::WaitWritable
          # A renegotiation is happening, let it proceed.
          IO.select(nil, [@socket.to_io])
          retry
        end
      end

      def send(mesg, flags)
        begin
          @socket.write_nonblock(mesg)
        rescue IO::WaitWritable
          0
        rescue IO::WaitReadable
          IO.select([@socket.to_io])
          retry
        end
      end
    end

    class PumaBufferedSocket < BufferedSocket
      def self.applies_for?(socket)
        return false unless defined? Puma::MiniSSL::Socket
        socket.is_a? ::Puma::MiniSSL::Socket
      end

      def recv(n)
        @socket.readpartial(n)
      end

      def send(mesg, flags)
        @socket.write(mesg)
      end
    end

    class Api < ::Sinatra::Base
      include Sinatra::Authorization::Helpers

      get "/pubkey" do
        File.read(Ssh.public_key_file)
      end

      post "/session" do
        do_authorize_any
        if env["HTTP_CONNECTION"] != "upgrade" or env["HTTP_UPGRADE"] != "raw"
          return [ 400, "Invalid request: /ssh/session requires connection upgrade to 'raw'" ]
        end

        params = MultiJson.load(env["rack.input"].read)
        key_file = Proxy::RemoteExecution::Ssh.private_key_file

        methods = %w(publickey)
        methods.unshift('password') if params["ssh_password"]

        ssh_options = { }
        ssh_options[:port] = params["ssh_port"] if params["ssh_port"]
        ssh_options[:keys] = [ key_file ] if key_file
        ssh_options[:password] = params["ssh_password"] if params["ssh_password"]
        ssh_options[:passphrase] = params[:ssh_key_passphrase] if params[:ssh_key_passphrase]
        ssh_options[:keys_only] = true
        ssh_options[:auth_methods] = methods
        ssh_options[:verify_host_key] = true
        ssh_options[:number_of_password_prompts] = 1

        socket = nil
        if env['WEBRICK_SOCKET']
          socket = env['WEBRICK_SOCKET']
        elsif env['rack.hijack?']
          begin
            env['rack.hijack'].call
          rescue NotImplementedError
          end
          socket = env['rack.hijack_io']
        end
        if !socket
          return [ 501, "Internal error: request hijacking not available" ]
        end

        ssh_on_socket(socket, params["command"], params["ssh_user"], params["hostname"], ssh_options)
        101
      end

      def ssh_on_socket(socket, command, ssh_user, host, ssh_options)
        started = false
        err_buf = ""
        socket = BufferedSocket.build(socket)

        send_start = -> {
          if !started
            started = true
            socket.enqueue("Status: 101\r\n")
            socket.enqueue("Connection: upgrade\r\n")
            socket.enqueue("Upgrade: raw\r\n")
            socket.enqueue("\r\n")
          end
        }

        send_error = -> (code, msg) {
          socket.enqueue("Status: #{code}\r\n")
          socket.enqueue("Connection: close\r\n")
          socket.enqueue("\r\n")
          socket.enqueue(msg)
        }

        begin
          Net::SSH.start(host, ssh_user, ssh_options) do |ssh|
            channel = ssh.open_channel do |ch|
              ch.exec(command) do |ch, success|
                raise "could not execute command" unless success

                ssh.listen_to(socket)

                ch.on_process do
                  if socket.available > 0
                    ch.send_data(socket.read_available)
                  end
                  if socket.closed?
                    ch.close
                  end
                end

                ch.on_data do |ch2, data|
                  send_start.call
                  socket.enqueue(data)
                end

                ch.on_request('exit-status') do |ch, data|
                  code = data.read_long
                  if code == 0
                    send_start.call
                  end
                  err_buf += "Process exited with code #{code}.\r\n"
                  ch.close
                end

                channel.on_request('exit-signal') do |ch, data|
                  err_buf += "Process was terminated with signal #{data.read_string}.\r\n"
                  ch.close
                end

                ch.on_extended_data do |ch2, type, data|
                  err_buf += data
                end
              end
            end

            channel.wait
            if !started
              send_error.call(400, err_buf)
            end
          end
        rescue Net::SSH::AuthenticationFailed => e
          send_error.call(401, e.message)
        rescue Errno::EHOSTUNREACH
          send_error.call(400, "No route to #{host}")
        rescue SystemCallError => e
          send_error.call(400, e.message)
        rescue SocketError => e
          send_error.call(400, e.message)
        rescue Exception => e
          logger.error e.message
          e.backtrace.each { |line| logger.debug line }
          send_error.call(500, "Internal error") unless started
        end
        if not socket.closed?
          socket.wait_for_pending_sends
          socket.close
        end
      end

    end
  end
end
