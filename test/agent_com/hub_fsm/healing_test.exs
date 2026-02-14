defmodule AgentCom.HubFSM.HealingTest do
  @moduledoc """
  Unit tests for the Healing remediation module.

  Tests healing cycle execution, remediation action structure,
  and error handling when services are unavailable.
  """

  use ExUnit.Case, async: false

  alias AgentCom.HubFSM.Healing

  describe "run_healing_cycle/0" do
    test "returns correct summary structure" do
      summary = Healing.run_healing_cycle()

      assert Map.has_key?(summary, :issues_found)
      assert Map.has_key?(summary, :actions_taken)
      assert Map.has_key?(summary, :results)
      assert Map.has_key?(summary, :timestamp)
      assert is_integer(summary.issues_found)
      assert is_integer(summary.actions_taken)
      assert is_list(summary.results)
      assert is_integer(summary.timestamp)
    end

    test "actions_taken matches results length" do
      summary = Healing.run_healing_cycle()

      assert summary.actions_taken == length(summary.results)
    end

    test "does not crash when services are unavailable" do
      # Healing cycle should handle all failures gracefully
      summary = Healing.run_healing_cycle()

      assert is_map(summary)
      assert summary.issues_found >= 0
    end

    test "results are tuples of category and action map" do
      summary = Healing.run_healing_cycle()

      Enum.each(summary.results, fn {category, result} ->
        assert is_atom(category)
        assert is_map(result)
        assert Map.has_key?(result, :action)
      end)
    end
  end
end
