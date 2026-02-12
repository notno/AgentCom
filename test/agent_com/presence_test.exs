defmodule AgentCom.PresenceTest do
  use ExUnit.Case, async: false

  alias AgentCom.Presence
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

  describe "register/2" do
    test "adds agent to presence list" do
      :ok = Presence.register("pres-agent-1", %{name: "Agent One", status: "idle", capabilities: []})
      agents = Presence.list()
      agent_ids = Enum.map(agents, & &1.agent_id)
      assert "pres-agent-1" in agent_ids
    end
  end

  describe "list/0" do
    test "returns all registered agents" do
      Presence.register("pres-list-1", %{name: "A1", status: "idle", capabilities: []})
      Presence.register("pres-list-2", %{name: "A2", status: "idle", capabilities: []})

      agents = Presence.list()
      agent_ids = Enum.map(agents, & &1.agent_id)
      assert "pres-list-1" in agent_ids
      assert "pres-list-2" in agent_ids
    end
  end

  describe "unregister/1" do
    test "removes agent from presence" do
      Presence.register("pres-unreg", %{name: "Gone", status: "idle", capabilities: []})
      assert Presence.get("pres-unreg") != nil

      Presence.unregister("pres-unreg")
      # unregister is a cast, give it a moment
      Process.sleep(50)
      assert Presence.get("pres-unreg") == nil
    end
  end

  describe "update_status/2" do
    test "changes agent status" do
      Presence.register("pres-status", %{name: "Status", status: "idle", capabilities: []})
      Presence.update_status("pres-status", "working on task X")
      # update_status is a cast, give it a moment
      Process.sleep(50)
      info = Presence.get("pres-status")
      assert info.status == "working on task X"
    end
  end

  describe "get/1" do
    test "returns agent info for registered agent" do
      Presence.register("pres-get", %{name: "GetMe", status: "idle", capabilities: ["code"]})
      info = Presence.get("pres-get")
      assert info != nil
      assert info.agent_id == "pres-get"
      assert info.name == "GetMe"
      assert info[:connected_at] != nil
    end

    test "returns nil for unregistered agent" do
      assert Presence.get("nonexistent-agent") == nil
    end
  end
end
