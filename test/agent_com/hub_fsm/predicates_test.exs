defmodule AgentCom.HubFSM.PredicatesTest do
  @moduledoc """
  Unit tests for pure HubFSM.Predicates transition evaluation.

  Tests all 3-state (resting/executing/improving) transition paths including
  budget gating, goal queue depth, active goal tracking, and improving state.

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
    test "stays when budget ok (improvement cycle continues)" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: false}
      assert :stay = Predicates.evaluate(:improving, system_state)
    end

    test "stays when budget ok and goals exist (goals don't affect improving)" do
      system_state = %{pending_goals: 5, active_goals: 2, budget_exhausted: false}
      assert :stay = Predicates.evaluate(:improving, system_state)
    end

    test "transitions to :resting when budget exhausted" do
      system_state = %{pending_goals: 0, active_goals: 0, budget_exhausted: true}
      assert {:transition, :resting, reason} = Predicates.evaluate(:improving, system_state)
      assert reason =~ "budget"
    end

    test "transitions to :resting when budget exhausted even with pending goals" do
      system_state = %{pending_goals: 5, active_goals: 3, budget_exhausted: true}
      assert {:transition, :resting, _reason} = Predicates.evaluate(:improving, system_state)
    end
  end
end
