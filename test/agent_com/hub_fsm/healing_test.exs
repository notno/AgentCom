defmodule AgentCom.HubFSM.HealingTest do
  @moduledoc """
  Unit tests for the Healing remediation module.

  Tests healing cycle execution, remediation action structure,
  and error handling when services are unavailable.
  """

  use ExUnit.Case, async: false

  alias AgentCom.HubFSM.Healing

  describe "run_healing_cycle/0" do
    test "returns summary with 0 actions when no issues detected" do
      # With no real services running, HealthAggregator returns healthy
      summary = Healing.run_healing_cycle()

      assert summary.issues_found == 0
      assert summary.actions_taken == 0
      assert summary.results == []
      assert is_integer(summary.timestamp)
    end

    test "returns correct summary structure" do
      summary = Healing.run_healing_cycle()

      assert Map.has_key?(summary, :issues_found)
      assert Map.has_key?(summary, :actions_taken)
      assert Map.has_key?(summary, :results)
      assert Map.has_key?(summary, :timestamp)
    end

    test "does not crash when services are unavailable" do
      # Healing cycle should handle all failures gracefully
      summary = Healing.run_healing_cycle()

      assert is_map(summary)
      assert summary.issues_found >= 0
    end
  end
end
