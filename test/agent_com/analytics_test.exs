defmodule AgentCom.AnalyticsTest do
  use ExUnit.Case, async: false

  alias AgentCom.Analytics
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

  describe "record_message/3" do
    test "increments sent counter for sender" do
      Analytics.record_message("analytics-sender", "analytics-receiver", "chat")

      agent_stats = Analytics.stats()
      sender = Enum.find(agent_stats, &(&1.agent_id == "analytics-sender"))
      assert sender != nil
      assert sender.messages_sent_24h >= 1
    end

    test "increments received counter for recipient" do
      Analytics.record_message("sender-2", "receiver-2", "chat")

      agent_stats = Analytics.stats()
      receiver = Enum.find(agent_stats, &(&1.agent_id == "receiver-2"))
      assert receiver != nil
      assert receiver.messages_received_24h >= 1
    end
  end

  describe "stats/0" do
    test "returns stats for known agents" do
      Analytics.record_message("stats-agent", nil, "chat")
      stats = Analytics.stats()
      assert is_list(stats)
      agent = Enum.find(stats, &(&1.agent_id == "stats-agent"))
      assert agent != nil
      assert Map.has_key?(agent, :messages_sent_24h)
      assert Map.has_key?(agent, :connected)
      assert Map.has_key?(agent, :status)
    end
  end

  describe "record_connect/1 and record_disconnect/1" do
    test "tracks connection state" do
      Analytics.record_connect("connect-agent")

      stats = Analytics.stats()
      agent = Enum.find(stats, &(&1.agent_id == "connect-agent"))
      assert agent.connected == true
      assert agent.total_connections >= 1

      Analytics.record_disconnect("connect-agent")
      stats = Analytics.stats()
      agent = Enum.find(stats, &(&1.agent_id == "connect-agent"))
      assert agent.connected == false
    end
  end
end
