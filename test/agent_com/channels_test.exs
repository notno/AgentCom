defmodule AgentCom.ChannelsTest do
  use ExUnit.Case, async: false

  alias AgentCom.{Channels, Message}
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

  defp make_msg(from, text \\ "hello") do
    Message.new(%{from: from, type: "chat", payload: %{"text" => text}})
  end

  describe "create/1" do
    test "creates a new channel" do
      assert :ok = Channels.create("test-channel")
    end

    test "returns {:error, :exists} for duplicate channel" do
      :ok = Channels.create("dup-channel")
      assert {:error, :exists} = Channels.create("dup-channel")
    end
  end

  describe "subscribe/2" do
    test "adds agent to channel" do
      :ok = Channels.create("sub-channel")
      assert :ok = Channels.subscribe("sub-channel", "agent-sub")

      {:ok, info} = Channels.info("sub-channel")
      assert "agent-sub" in info.subscribers
    end

    test "returns {:error, :not_found} for nonexistent channel" do
      assert {:error, :not_found} = Channels.subscribe("no-such-channel", "agent-x")
    end
  end

  describe "unsubscribe/2" do
    test "removes agent from channel" do
      :ok = Channels.create("unsub-channel")
      :ok = Channels.subscribe("unsub-channel", "agent-unsub")
      :ok = Channels.unsubscribe("unsub-channel", "agent-unsub")

      {:ok, info} = Channels.info("unsub-channel")
      refute "agent-unsub" in info.subscribers
    end
  end

  describe "publish/2" do
    test "stores message in channel history" do
      :ok = Channels.create("pub-channel")
      :ok = Channels.subscribe("pub-channel", "subscriber-1")

      msg = make_msg("publisher", "channel msg")
      assert {:ok, seq} = Channels.publish("pub-channel", msg)
      assert is_integer(seq)

      history = Channels.history("pub-channel")
      assert length(history) >= 1
    end

    test "returns {:error, :not_found} for nonexistent channel" do
      msg = make_msg("publisher", "test")
      assert {:error, :not_found} = Channels.publish("no-channel", msg)
    end
  end

  describe "history/1" do
    test "returns published messages in order" do
      :ok = Channels.create("hist-channel")

      msg1 = make_msg("a", "first")
      msg2 = make_msg("b", "second")
      {:ok, _} = Channels.publish("hist-channel", msg1)
      {:ok, _} = Channels.publish("hist-channel", msg2)

      history = Channels.history("hist-channel")
      assert length(history) == 2
      seqs = Enum.map(history, & &1.seq)
      assert seqs == Enum.sort(seqs)
    end
  end

  describe "list/0" do
    test "returns all channels" do
      :ok = Channels.create("list-chan-1")
      :ok = Channels.create("list-chan-2")

      channels = Channels.list()
      channel_names = Enum.map(channels, & &1.name)
      assert "list-chan-1" in channel_names
      assert "list-chan-2" in channel_names
    end
  end
end
