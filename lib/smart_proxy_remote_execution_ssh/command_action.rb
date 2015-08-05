module Proxy::RemoteExecution::Ssh
  class CommandAction < ::Dynflow::Action
    include Dynflow::Action::Cancellable
    include ::Proxy::Dynflow::Callback::PlanHelper

    def plan(input)
      if callback = input['callback']
        input[:task_id] = callback['task_id']
      else
        input[:task_id] ||= SecureRandom.uuid
      end
      plan_with_callback(input)
    end

    def run(event = nil)
      case event
      when nil
        init_run
      when Dispatcher::CommandUpdate
        update = event
        output[:result].concat(update.buffer_to_hash)
        if update.exit_status
          finish_run(update)
        else
          suspend
        end
      when Dynflow::Action::Cancellable::Cancel
        kill_run
      when Dispatcher::ConnectionTimeout
        handle_timeout event
      when Dynflow::Action::Skip
        # do nothing
      else
        raise "Unexpected event #{event.inspect}"
      end
    end

    def finalize
      # To mark the task as a whole as failed
      error! "Script execution failed" if failed_run?
    end

    def rescue_strategy
      Dynflow::Action::Rescue::Skip
    end

    def command
      # TODO: Insert sane defaults here
      default_connection_options = { :retry_count => 3, :retry_interval => 10, :timeout => 0.1 }
      connection_options = default_connection_options.merge(input.fetch(:connection_options, {}).symbolize_keys)
      @command ||= Dispatcher::Command.new(:id                 => input[:task_id],
                                           :host               => input[:hostname],
                                           :ssh_user           => 'root',
                                           :effective_user     => input[:effective_user],
                                           :script             => input[:script],
                                           :host_public_key    => input[:host_public_key],
                                           :verify_host        => input[:verify_host],
                                           :suspended_action   => suspended_action,
                                           :connection_options => connection_options)
    end

    def handle_timeout(event)
      input[:remaining_retries] = command.connection_options[:retry_count] - event.retry_number
      if event.retry_number < command.connection_options[:retry_count]
        world.clock.ping(Proxy::RemoteExecution::Ssh.dispatcher,
                         Time.now + command.connection_options[:retry_interval],
                         [:initialize_command, command, event.retry_number + 1])
        suspend
      else
        raise event.exception
      end
    end

    def init_run
      output[:result] = []
      Proxy::RemoteExecution::Ssh.dispatcher.tell([:initialize_command, command])
      suspend
    end

    def kill_run
      Proxy::RemoteExecution::Ssh.dispatcher.tell([:kill, command])
      suspend
    end

    def finish_run(update)
      output[:exit_status] = update.exit_status
    end

    def failed_run?
      output[:exit_status] != 0
    end
  end
end
