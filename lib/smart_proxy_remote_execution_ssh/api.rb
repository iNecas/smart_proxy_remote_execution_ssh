module Proxy::RemoteExecution
  module Ssh
    class Api < ::Sinatra::Base
      get "/pubkey" do
        File.read(Ssh.public_key_file)
      end
      post "/session" do
        if env["HTTP_CONNECTION"] != "upgrade" or env["HTTP_UPGRADE"] != "raw"
          return [ 401, "Invalid request: /ssh/session requires connection upgrade to 'raw'" ]
        end
        socket = nil
        if env['rack.hijack?']
          env['rack.hijack'].call
          socket = env['rack.hijack_io']
        end
        if !socket
          return [ 501, "Internal error: request hijacking not available" ]
        end

        params = MultiJson.load(env["rack.input"].read)
        key_file = ForemanRemoteExecutionCore.settings.fetch(:ssh_identity_key_file)

        methods = %w(publickey)
        methods.unshift('password') if params["ssh_password"]

        ssh_options = { }
        ssh_options[:port] = params["ssh_port"] if params["ssh_port"]
        ssh_options[:keys] = [ key_file ] if key_file
        ssh_options[:password] = params["ssh_password"] if params["ssh_password"]
        ssh_options[:passphrase] = params[:ssh_key_passphrase] if params[:ssh_key_passphrase]
        ssh_options[:keys_only] = true
        ssh_options[:auth_methods] = methods
        ssh_options[:verify_host_key] = :accept_new_or_local_tunnel
        ssh_options[:number_of_password_prompts] = 1

        ssh_on_socket(socket, params["command"], params["ssh_user"], params["hostname"], ssh_options)
        101
      end

      def ssh_on_socket(socket, command, ssh_user, host, ssh_options)
        started = false
        err_buf = ""
        begin
          Net::SSH.start(host, ssh_user, ssh_options) do |ssh|
            channel = ssh.open_channel do |ch|
              ch.exec(command) do |ch, success|
                raise "could not execute command" unless success

                socket.extend(Net::SSH::BufferedIo)
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
                  if !started
                    started = true
                    socket.enqueue("Status: 101\r\n")
                    socket.enqueue("Connection: upgrade\r\n")
                    socket.enqueue("Upgrade: raw\r\n")
                    socket.enqueue("\r\n")
                  end
                  socket.enqueue(data)
                end

                ch.on_request('exit-status') do |ch, data|
                  ch.close
                end

                channel.on_request('exit-signal') do |ch, data|
                  ch.close
                end

                ch.on_extended_data do |ch2, type, data|
                  err_buf += data
                end
              end
            end

            channel.wait
            if !started
              socket.enqueue("Status: 400\r\n")
              socket.enqueue("Connection: close\r\n")
              socket.enqueue("\r\n")
              socket.enqueue(err_buf)
              socket.wait_for_pending_sends
              socket.close
            end
          end
        end
      end

    end
  end
end
