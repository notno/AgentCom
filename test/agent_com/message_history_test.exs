defmodule AgentCom.MessageHistoryTest do
  use ExUnit.Case, async: false

  alias AgentCom.{MessageHistory, Message}
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

  defp make_msg(from, to \\ nil) do
    Message.new(%{from: from, to: to, type: "chat", payload: %{"text" => "hello from #{from}"}})
  end

  describe "store/1" do
    test "saves a message and returns {:ok, seq}" do
      msg = make_msg("history-sender", "history-receiver")
      assert {:ok, seq} = MessageHistory.store(msg)
      assert is_integer(seq) and seq > 0
    end
  end

  describe "query/1" do
    test "returns stored messages" do
      msg1 = make_msg("query-a", "query-b")
      msg2 = make_msg("query-c", "query-d")
      {:ok, _} = MessageHistory.store(msg1)
      {:ok, _} = MessageHistory.store(msg2)

      result = MessageHistory.query()
      assert is_map(result)
      assert Map.has_key?(result, :messages)
      assert Map.has_key?(result, :cursor)
      assert Map.has_key?(result, :count)
      assert result.count >= 2
    end

    test "filters by from" do
      msg1 = make_msg("filter-sender", "someone")
      msg2 = make_msg("other-sender", "someone")
      {:ok, _} = MessageHistory.store(msg1)
      {:ok, _} = MessageHistory.store(msg2)

      result = MessageHistory.query(from: "filter-sender")
      assert result.count >= 1
      Enum.each(result.messages, fn msg ->
        assert msg["from"] == "filter-sender"
      end)
    end

    test "respects limit" do
      for i <- 1..5 do
        msg = make_msg("limit-sender-#{i}")
        MessageHistory.store(msg)
      end

      result = MessageHistory.query(limit: 2)
      assert result.count <= 2
    end
  end
end
