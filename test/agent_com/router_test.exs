defmodule AgentCom.RouterTest do
  use ExUnit.Case, async: false

  alias AgentCom.{Router, Message, Mailbox}
  alias AgentCom.TestHelpers.DetsHelpers

  setup do
    tmp_dir = DetsHelpers.full_test_setup()
    # Stop Scheduler to prevent interference
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.Scheduler)
    on_exit(fn ->
      Supervisor.restart_child(AgentCom.Supervisor, AgentCom.Scheduler)
      DetsHelpers.full_test_teardown(tmp_dir)
    end)
    {:ok, tmp_dir: tmp_dir}
  end

  defp make_msg(from, to, text \\ "hello") do
    Message.new(%{from: from, to: to, type: "chat", payload: %{"text" => text}})
  end

  describe "route/1 with direct message" do
    test "to online agent delivers via send" do
      # Register a process in AgentRegistry to simulate online agent
      agent_id = "router-online-agent"
      test_pid = self()

      spawn(fn ->
        Registry.register(AgentCom.AgentRegistry, agent_id, %{pid: self()})
        # Forward received messages to test process
        receive do
          {:message, msg} -> send(test_pid, {:forwarded, msg})
        after
          5000 -> :timeout
        end
      end)

      # Give registry time to register
      Process.sleep(50)

      msg = make_msg("sender", agent_id)
      assert {:ok, :delivered} = Router.route(msg)

      # Verify the message was delivered
      assert_receive {:forwarded, received_msg}, 1000
      assert received_msg.from == "sender"
    end

    test "to offline agent queues to mailbox" do
      msg = make_msg("sender", "offline-agent", "queued")
      assert {:ok, :queued} = Router.route(msg)

      # Verify message is in mailbox
      {messages, _seq} = Mailbox.poll("offline-agent", 0)
      assert length(messages) >= 1
    end
  end

  describe "route/1 with broadcast message" do
    test "broadcasts message with to=nil" do
      msg = Message.new(%{from: "broadcaster", type: "chat", payload: %{"text" => "all"}})
      assert {:ok, :broadcast} = Router.route(msg)
    end

    test "broadcasts message with to=broadcast" do
      msg = make_msg("broadcaster", "broadcast", "all")
      assert {:ok, :broadcast} = Router.route(msg)
    end
  end
end
