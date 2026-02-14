defmodule AgentCom.HubFSM.Predicates do
  @moduledoc """
  Pure transition predicate functions for the HubFSM 5-state core.

  Evaluates the current FSM state against gathered system state (goal queue
  depth, active goal count, budget status, health signals) and returns either
  a transition directive or `:stay`.

  The five states are:
  - `:resting` -- idle, waiting for goals or webhook events
  - `:executing` -- actively processing goals from the backlog
  - `:improving` -- processing improvement cycle triggered by webhook
  - `:contemplating` -- generating feature proposals and scalability analysis
  - `:healing` -- remediating infrastructure issues (highest priority)

  All functions are pure -- no side effects, no process calls. System state
  is gathered by the caller and passed in as a map.
  """

  @doc """
  Evaluate whether the FSM should transition given its current state and
  the latest system snapshot.

  ## Parameters

  - `current_state` -- `:resting`, `:executing`, `:improving`, `:contemplating`, or `:healing`
  - `system_state` -- map with keys:
    - `:pending_goals` -- integer count of submitted goals in backlog
    - `:active_goals` -- integer count of goals in decomposing/executing/verifying
    - `:budget_exhausted` -- boolean, true if CostLedger reports budget exceeded
    - `:improving_budget_available` -- boolean, true if improving budget has capacity
    - `:contemplating_budget_available` -- boolean, true if contemplating budget has capacity
    - `:health_report` -- map with `:critical_count` from HealthAggregator
    - `:healing_cooldown_active` -- boolean, true if healing cooldown has not expired
    - `:healing_attempts_exhausted` -- boolean, true if 3+ attempts in 10-min window

  ## Returns

  - `{:transition, new_state, reason}` -- FSM should transition
  - `:stay` -- no transition needed
  """
  @spec evaluate(atom(), map()) :: {:transition, atom(), String.t()} | :stay

  # Healing evaluation: stay in :healing (cycle in progress)
  def evaluate(:healing, _system_state), do: :stay

  # Healing preemption: any non-healing state transitions to :healing when critical issues exist
  # and cooldown has expired and attempts not exhausted
  def evaluate(current_state, %{health_report: %{critical_count: critical}} = sys)
      when current_state != :healing and critical > 0
      and not is_map_key(sys, :__struct__) do
    cooldown_active = Map.get(sys, :healing_cooldown_active, false)
    attempts_exhausted = Map.get(sys, :healing_attempts_exhausted, false)

    if not cooldown_active and not attempts_exhausted do
      {:transition, :healing, "critical health issues detected (#{critical} critical)"}
    else
      evaluate_normal(current_state, sys)
    end
  end

  def evaluate(current_state, system_state) do
    evaluate_normal(current_state, system_state)
  end

  # Normal evaluation (non-healing transitions)
  defp evaluate_normal(:resting, %{budget_exhausted: true}), do: :stay

  defp evaluate_normal(:resting, %{pending_goals: pending}) when pending > 0 do
    {:transition, :executing, "pending goals in backlog"}
  end

  # Resting -> improving: no pending goals, no active goals, but improving budget available
  defp evaluate_normal(:resting, %{pending_goals: 0, active_goals: 0, improving_budget_available: true}) do
    {:transition, :improving, "no goals, improving budget available"}
  end

  defp evaluate_normal(:resting, _system_state), do: :stay

  defp evaluate_normal(:executing, %{budget_exhausted: true}) do
    {:transition, :resting, "budget exhausted"}
  end

  defp evaluate_normal(:executing, %{pending_goals: 0, active_goals: 0}) do
    {:transition, :resting, "no pending or active goals"}
  end

  defp evaluate_normal(:executing, _system_state), do: :stay

  # Improving -> executing: goals submitted (new work to do)
  defp evaluate_normal(:improving, %{pending_goals: pending}) when pending > 0 do
    {:transition, :executing, "goals submitted while improving"}
  end

  # :improving transitions to :resting when budget exhausted
  defp evaluate_normal(:improving, %{budget_exhausted: true}) do
    {:transition, :resting, "budget exhausted while improving"}
  end

  # Improving: stay (scan in progress)
  defp evaluate_normal(:improving, _system_state), do: :stay

  # Contemplating -> executing: goals submitted (new work to do)
  defp evaluate_normal(:contemplating, %{pending_goals: pending}) when pending > 0 do
    {:transition, :executing, "goals submitted while contemplating"}
  end

  # Contemplating -> resting: budget exhausted
  defp evaluate_normal(:contemplating, %{budget_exhausted: true}) do
    {:transition, :resting, "budget exhausted while contemplating"}
  end

  # Contemplating: stay (cycle in progress)
  defp evaluate_normal(:contemplating, _system_state), do: :stay

  # Unknown state: stay (defensive)
  defp evaluate_normal(_unknown, _system_state), do: :stay
end
