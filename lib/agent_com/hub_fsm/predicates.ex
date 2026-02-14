defmodule AgentCom.HubFSM.Predicates do
  @moduledoc """
  Pure transition predicate functions for the HubFSM 4-state core.

  Evaluates the current FSM state against gathered system state (goal queue
  depth, active goal count, budget status) and returns either a transition
  directive or `:stay`.

  The four states are:
  - `:resting` -- idle, waiting for goals or webhook events
  - `:executing` -- actively processing goals from the backlog
  - `:improving` -- processing improvement cycle triggered by webhook
  - `:contemplating` -- generating feature proposals and scalability analysis

  All functions are pure -- no side effects, no process calls. System state
  is gathered by the caller and passed in as a map.
  """

  @doc """
  Evaluate whether the FSM should transition given its current state and
  the latest system snapshot.

  ## Parameters

  - `current_state` -- `:resting`, `:executing`, `:improving`, or `:contemplating`
  - `system_state` -- map with keys:
    - `:pending_goals` -- integer count of submitted goals in backlog
    - `:active_goals` -- integer count of goals in decomposing/executing/verifying
    - `:budget_exhausted` -- boolean, true if CostLedger reports budget exceeded
    - `:improving_budget_available` -- boolean, true if improving budget has capacity
    - `:contemplating_budget_available` -- boolean, true if contemplating budget has capacity

  ## Returns

  - `{:transition, new_state, reason}` -- FSM should transition
  - `:stay` -- no transition needed
  """
  @spec evaluate(atom(), map()) :: {:transition, atom(), String.t()} | :stay
  def evaluate(:resting, %{budget_exhausted: true}), do: :stay

  def evaluate(:resting, %{pending_goals: pending}) when pending > 0 do
    {:transition, :executing, "pending goals in backlog"}
  end

  # Resting -> improving: no pending goals, no active goals, but improving budget available
  def evaluate(:resting, %{pending_goals: 0, active_goals: 0, improving_budget_available: true}) do
    {:transition, :improving, "no goals, improving budget available"}
  end

  def evaluate(:resting, _system_state), do: :stay

  def evaluate(:executing, %{budget_exhausted: true}) do
    {:transition, :resting, "budget exhausted"}
  end

  def evaluate(:executing, %{pending_goals: 0, active_goals: 0}) do
    {:transition, :resting, "no pending or active goals"}
  end

  def evaluate(:executing, _system_state), do: :stay

  # Improving -> executing: goals submitted (new work to do)
  def evaluate(:improving, %{pending_goals: pending}) when pending > 0 do
    {:transition, :executing, "goals submitted while improving"}
  end

  # :improving transitions to :resting when budget exhausted
  def evaluate(:improving, %{budget_exhausted: true}) do
    {:transition, :resting, "budget exhausted while improving"}
  end

  # Improving: stay (scan in progress)
  def evaluate(:improving, _system_state), do: :stay

  # Contemplating -> executing: goals submitted (new work to do)
  def evaluate(:contemplating, %{pending_goals: pending}) when pending > 0 do
    {:transition, :executing, "goals submitted while contemplating"}
  end

  # Contemplating -> resting: budget exhausted
  def evaluate(:contemplating, %{budget_exhausted: true}) do
    {:transition, :resting, "budget exhausted while contemplating"}
  end

  # Contemplating: stay (cycle in progress)
  def evaluate(:contemplating, _system_state), do: :stay

  # Unknown state: stay (defensive)
  def evaluate(_unknown, _system_state), do: :stay
end
