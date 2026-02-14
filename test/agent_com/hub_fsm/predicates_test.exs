defmodule AgentCom.HubFSM.PredicatesTest do
  @moduledoc """
  Unit tests for pure HubFSM.Predicates transition evaluation.

  Tests all 4-state (resting/executing/improving/contemplating) transition paths
  including budget gating, goal queue depth, active goal tracking, improving
  state, and contemplating state safety-net predicates.

  async: true because all functions are pure with no shared state.
  """

  use ExUnit.Case, async: true

  alias AgentCom.HubFSM.Predicates

  # ---------------------------------------------------------------------------
  # :resting state predicates
  # ---------------------------------------------------------------------------

  describe "evaluate/2 when :resting" do
    test "transitions to :executing when pending goals exist and budget ok" do
      system_state = %{pending_goals: 3, active_goals: 0, budget_exhausted: false}
      assert {:transition, :executing, _reason} = Predicates.evaluate(:resting, system_state)
    end

    test "stays when no pending goals and budget ok" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: false}
      assert :stay = Predicates.evaluate(:resting, system_state)
    end

    test "stays when budget exhausted (already resting)" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: true}
      assert :stay = Predicates.evaluate(:resting, system_state)
    end

    test "stays when pending goals exist but budget exhausted (budget overrides)" do
      system_state = %{pending_goals: 5, active_goals: 0, budget_exhausted: true}
      assert :stay = Predicates.evaluate(:resting, system_state)
    end
  end

  # ---------------------------------------------------------------------------
  # :executing state predicates
  # ---------------------------------------------------------------------------

  describe "evaluate/2 when :executing" do
    test "transitions to :resting when no pending and no active goals" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: false}
      assert {:transition, :resting, _reason} = Predicates.evaluate(:executing, system_state)
    end

    test "stays when pending goals exist and no active goals" do
      system_state = %{pending_goals: 2, active_goals: 0, budget_exhausted: false}
      assert :stay = Predicates.evaluate(:executing, system_state)
    end

    test "stays when no pending goals but active goals exist" do
      system_state = %{pending_goals: 0, active_goals: 3, budget_exhausted: false}
      assert :stay = Predicates.evaluate(:executing, system_state)
    end

    test "transitions to :resting when budget exhausted (budget takes priority)" do
      system_state = %{pending_goals: 5, active_goals: 3, budget_exhausted: true}
      assert {:transition, :resting, _reason} = Predicates.evaluate(:executing, system_state)
    end

    test "stays when both pending and active goals exist and budget ok" do
      system_state = %{pending_goals: 2, active_goals: 1, budget_exhausted: false}
      assert :stay = Predicates.evaluate(:executing, system_state)
    end
  end

  # ---------------------------------------------------------------------------
  # :improving state predicates
  # ---------------------------------------------------------------------------

  describe "evaluate/2 when :improving" do
    test "stays when budget ok and no pending goals (improvement cycle continues)" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: false}
      assert :stay = Predicates.evaluate(:improving, system_state)
    end

    test "transitions to :executing when goals submitted while improving" do
      system_state = %{pending_goals: 5, active_goals: 2, budget_exhausted: false}
      assert {:transition, :executing, reason} = Predicates.evaluate(:improving, system_state)
      assert reason =~ "goals"
    end

    test "transitions to :resting when budget exhausted" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: true}
      assert {:transition, :resting, reason} = Predicates.evaluate(:improving, system_state)
      assert reason =~ "budget"
    end

    test "goals take priority over budget when both present" do
      system_state = %{pending_goals: 5, active_goals: 3, budget_exhausted: true}
      assert {:transition, :executing, _reason} = Predicates.evaluate(:improving, system_state)
    end
  end

  # ---------------------------------------------------------------------------
  # :contemplating state predicates
  # ---------------------------------------------------------------------------

  describe "evaluate/2 when :contemplating" do
    test "stays when no pending goals and budget ok (cycle in progress)" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: false}
      assert :stay = Predicates.evaluate(:contemplating, system_state)
    end

    test "transitions to :executing when pending goals exist" do
      system_state = %{pending_goals: 3, active_goals: 0, budget_exhausted: false}
      assert {:transition, :executing, reason} = Predicates.evaluate(:contemplating, system_state)
      assert reason =~ "goals"
    end

    test "transitions to :resting when budget exhausted" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: true}
      assert {:transition, :resting, reason} = Predicates.evaluate(:contemplating, system_state)
      assert reason =~ "budget"
    end

    test "goals take priority over budget when both present" do
      # When goals are submitted and budget is exhausted, goals submitted check fires first
      system_state = %{pending_goals: 2, active_goals: 0, budget_exhausted: true}
      result = Predicates.evaluate(:contemplating, system_state)
      # Should transition to :executing (goals submitted check is first clause)
      assert {:transition, :executing, _reason} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown state (defensive catch-all)
  # ---------------------------------------------------------------------------

  describe "evaluate/2 with unknown state" do
    test "returns :stay for unknown state (defensive catch-all)" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: false}
      assert :stay = Predicates.evaluate(:unknown_state, system_state)
    end
  end
end
