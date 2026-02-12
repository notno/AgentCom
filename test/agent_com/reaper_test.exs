defmodule AgentCom.ReaperTest do
  use ExUnit.Case, async: false

  alias AgentCom.{Reaper, Presence}
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

  describe "start_link/1" do
    test "starts without errors" do
      # Reaper is already started by the application supervisor
      # Verify it's alive
      assert Process.whereis(AgentCom.Reaper) != nil
    end
  end

  describe "sweep" do
    test "sending :sweep does not crash on empty presence list" do
      # Manually trigger a sweep by sending the message
      pid = Process.whereis(AgentCom.Reaper)
      send(pid, :sweep)
      # Give it time to process
      Process.sleep(100)
      # Reaper should still be alive
      assert Process.alive?(pid)
    end

    test "does not evict agents with recent last_seen" do
      # Register an agent with fresh timestamps (should NOT be reaped)
      Presence.register("reaper-fresh", %{name: "Fresh", status: "idle", capabilities: []})

      pid = Process.whereis(AgentCom.Reaper)
      send(pid, :sweep)
      Process.sleep(100)

      # Agent should still be in presence (it was just registered, so last_seen is recent)
      info = Presence.get("reaper-fresh")
      assert info != nil
    end
  end
end
