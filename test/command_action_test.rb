require 'test_helper'

module Proxy::RemoteExecution::Ssh
  class CommandActionTest < MiniTest::Spec
    include ::Dynflow::Testing

    let :connection_options do
      { :retry_count    => 2,
        :retry_interval => 10,
        :timeout        => 0.25 }
    end

    let :command_input do
      { :task_id            => '123',
        :hostname           => 'test.example.com',
        :effective_user     => 'guest',
        :script             => 'echo "Hello world"',
        :connection_options => connection_options }
    end

    let :dispatcher do
      mock('Dispatcher')
    end

    before do
      Proxy::RemoteExecution::Ssh.stubs(:dispatcher).returns dispatcher
    end

    it 'sends to command to dispatcher' do
      action = create_and_plan_action CommandAction, command_input
      dispatcher.expects(:tell).with do |(method, command)|
        method.must_equal :initialize_command
        command.id.must_equal command_input[:task_id]
        command.host.must_equal command_input[:hostname]
        command.ssh_user.must_equal 'root'
        command.effective_user.must_equal command_input[:effective_user]
        command.script.must_equal command_input[:script]
        command.suspended_action.must_be_kind_of ::Dynflow::Action::Suspended
        command.connection_options.must_equal connection_options
      end
      run_action action
    end

    it 'saves the command update to the output' do
      action = create_and_plan_action CommandAction, command_input
      command_update = Dispatcher::CommandUpdate.new([Connector::StdoutData.new('Hello world')], nil)
      dispatcher.expects(:tell)
      action = run_action action

      action = run_action action, command_update
      action.state.must_equal :suspended
      action.output['result'].size.must_equal 1
      result_item  = action.output['result'].first
      result_item[:output_type].must_equal :stdout
      result_item[:output].must_equal "Hello world"
      result_item[:timestamp].must_be_kind_of Numeric

      command_update = Dispatcher::CommandUpdate.new([Connector::StderrData.new('Finished')], 1)
      action = run_action action, command_update
      action.output['result'].size.must_equal 2
      result_item  = action.output['result'].last
      result_item[:output_type].must_equal :stderr
      result_item[:output].must_equal "Finished"
      result_item[:timestamp].must_be_kind_of Numeric

      action.output[:exit_status].must_equal 1
      action.state.must_equal :success

      action = finalize_action(action)
      action.state.must_equal :error
      action.error.message.must_match 'Script execution failed'
    end

    it 'kills the command on cancel' do
      action = create_and_plan_action CommandAction, command_input
      dispatcher.expects(:tell)
      action = run_action action

      dispatcher.expects(:tell).with do |(method, command)|
        method.must_equal :kill
        command.id.must_equal command_input[:task_id]
      end
      run_action action, Dynflow::Action::Cancellable::Cancel
    end

    it 'allows skipping the action' do
      action = create_and_plan_action CommandAction, command_input
      dispatcher.expects(:tell)
      action = run_action action
      action.state.must_equal :suspended

      action = run_action action, Dynflow::Action::Skip
      action.state.must_equal :success
    end

    it 'raises the connection error after ' do
      event = ->(num) { Dispatcher::ConnectionTimeout.new(num, Errno::ECONNREFUSED.new('error')) }
      action = create_and_plan_action CommandAction, command_input
      dispatcher.expects(:tell)
      action = run_action action
      action.input.key?(:remaining_retries).must_equal false
      action.world.clock.expects(:ping).twice
      action = run_action action, event.call(0)
      action.state.must_equal :suspended
      action.input[:remaining_retries].must_equal 2
      action = run_action action, event.call(1)
      action.state.must_equal :suspended
      action.input[:remaining_retries].must_equal 1
      proc { action = run_action action, event.call(2) }.must_raise Errno::ECONNREFUSED
      action.state.must_equal :error
      action.input[:remaining_retries].must_equal 0
    end
  end
end
