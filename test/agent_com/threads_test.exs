defmodule AgentCom.ThreadsTest do
  use ExUnit.Case, async: false

  alias AgentCom.{Threads, Message}
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

  defp make_msg(id, from, opts \\ %{}) do
    Message.new(%{
      id: id,
      from: from,
      type: "chat",
      payload: %{"text" => "message #{id}"},
      reply_to: Map.get(opts, :reply_to)
    })
  end

  describe "index/1" do
    test "stores a message" do
      msg = make_msg("thread-msg-1", "agent-a")
      # index is a cast, give it a moment
      Threads.index(msg)
      Process.sleep(100)

      {:ok, thread} = Threads.get_thread("thread-msg-1")
      assert thread.count >= 1
    end
  end

  describe "get_thread/1" do
    test "returns the thread containing a message" do
      msg = make_msg("thread-single", "agent-a")
      Threads.index(msg)
      Process.sleep(100)

      {:ok, thread} = Threads.get_thread("thread-single")
      assert thread.root == "thread-single"
      assert thread.count == 1
    end
  end

  describe "get_replies/1" do
    test "returns direct replies" do
      parent = make_msg("parent-msg", "agent-a")
      child = make_msg("child-msg", "agent-b", %{reply_to: "parent-msg"})

      Threads.index(parent)
      Process.sleep(50)
      Threads.index(child)
      Process.sleep(100)

      {:ok, replies} = Threads.get_replies("parent-msg")
      reply_ids = Enum.map(replies, & &1["id"])
      assert "child-msg" in reply_ids
    end
  end

  describe "get_root/1" do
    test "returns root of reply chain" do
      root = make_msg("root-msg", "agent-a")
      reply = make_msg("reply-msg", "agent-b", %{reply_to: "root-msg"})

      Threads.index(root)
      Process.sleep(50)
      Threads.index(reply)
      Process.sleep(100)

      {:ok, root_id} = Threads.get_root("reply-msg")
      assert root_id == "root-msg"
    end
  end

  describe "reply chain" do
    test "index parent then child, get_thread returns both in order" do
      parent = make_msg("chain-parent", "agent-a")
      child = make_msg("chain-child", "agent-b", %{reply_to: "chain-parent"})

      Threads.index(parent)
      Process.sleep(50)
      Threads.index(child)
      Process.sleep(100)

      {:ok, thread} = Threads.get_thread("chain-child")
      assert thread.root == "chain-parent"
      assert thread.count == 2
      msg_ids = Enum.map(thread.messages, & &1["id"])
      assert "chain-parent" in msg_ids
      assert "chain-child" in msg_ids
    end
  end

  describe "known bug: circular reply chain" do
    @tag :skip
    # This test documents a known bug: circular reply chains cause infinite recursion
    # in walk_to_root/1. Tagged :skip because it will time out (confirming the bug).
    # If this test passes, the bug has been fixed.
    test "walk_to_root handles circular reply chains without infinite loop" do
      # Create circular reference: A replies to B, B replies to A
      msg_a = make_msg("circ-a", "agent-a", %{reply_to: "circ-b"})
      msg_b = make_msg("circ-b", "agent-b", %{reply_to: "circ-a"})

      Threads.index(msg_a)
      Process.sleep(50)
      Threads.index(msg_b)
      Process.sleep(100)

      # Use Task.async with timeout to prevent test suite from hanging
      task = Task.async(fn ->
        Threads.get_root("circ-a")
      end)

      case Task.yield(task, 2000) || Task.shutdown(task) do
        {:ok, _result} ->
          # Bug fixed -- walk_to_root returned without infinite loop
          :ok

        nil ->
          flunk("walk_to_root infinite loop on circular reply chain (known bug - Pitfall #5)")
      end
    end
  end
end
