defmodule AgentCom.HubFSM.Predicates do
  @moduledoc """
  Pure transition predicate functions for the HubFSM 2-state core.

  Evaluates the current FSM state against gathered system state (goal queue
  depth, active goal count, budget status) and returns either a transition
  directive or `:stay`.

  All functions are pure -- no side effects, no process calls. System state
  is gathered by the caller and passed in as a map.
  """

  @doc """
  Evaluate whether the FSM should transition given its current state and
  the latest system snapshot.

  ## Parameters

  - `current_state` -- `:resting` or `:executing`
  - `system_state` -- map with keys:
    - `:pending_goals` -- integer count of submitted goals in backlog
    - `:active_goals` -- integer count of goals in decomposing/executing/verifying
    - `:budget_exhausted` -- boolean, true if CostLedger reports budget exceeded

  ## Returns

  - `{:transition, new_state, reason}` -- FSM should transition
  - `:stay` -- no transition needed
  """
  @spec evaluate(atom(), map()) :: {:transition, atom(), String.t()} | :stay
  def evaluate(:resting, %{budget_exhausted: true}), do: :stay

  def evaluate(:resting, %{pending_goals: pending}) when pending > 0 do
    {:transition, :executing, "pending goals in backlog"}
  end

  def evaluate(:resting, _system_state), do: :stay

  def evaluate(:executing, %{budget_exhausted: true}) do
    {:transition, :resting, "budget exhausted"}
  end

  def evaluate(:executing, %{pending_goals: 0, active_goals: 0}) do
    {:transition, :resting, "no pending or active goals"}
  end

  def evaluate(:executing, _system_state), do: :stay
end
