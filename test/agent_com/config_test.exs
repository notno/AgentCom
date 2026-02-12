defmodule AgentCom.ConfigTest do
  use ExUnit.Case, async: false

  alias AgentCom.Config
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

  describe "get/1" do
    test "returns default value for unset key" do
      # heartbeat_interval_ms has a default of 900_000
      assert Config.get(:heartbeat_interval_ms) == 900_000
    end

    test "returns nil for unknown key with no default" do
      assert Config.get(:nonexistent_key) == nil
    end
  end

  describe "put/2" do
    test "stores a value, get retrieves it" do
      :ok = Config.put(:test_key, "test_value")
      assert Config.get(:test_key) == "test_value"
    end

    test "overwrites previous value" do
      :ok = Config.put(:overwrite_key, "first")
      assert Config.get(:overwrite_key) == "first"

      :ok = Config.put(:overwrite_key, "second")
      assert Config.get(:overwrite_key) == "second"
    end
  end

  describe "persistence" do
    test "value survives Config GenServer restart" do
      :ok = Config.put(:persist_key, 42)
      assert Config.get(:persist_key) == 42

      # Terminate and restart Config GenServer
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.Config)
      {:ok, _pid} = Supervisor.restart_child(AgentCom.Supervisor, AgentCom.Config)

      assert Config.get(:persist_key) == 42
    end
  end
end
