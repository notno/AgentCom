defmodule AgentCom.GoalOrchestrator do
  @moduledoc """
  Central orchestration GenServer tying the autonomous inner loop together.

  Drives the goal lifecycle: dequeue submitted goals, trigger LLM decomposition,
  monitor task completion via PubSub, and trigger LLM verification -- all without
  blocking the HubFSM tick.

  ## Tick-Based Execution

  `tick/0` is called by HubFSM on every `:executing` state tick (1s interval).
  Each tick performs at most ONE async operation (decomposition or verification)
  to respect ClaudeClient's serial GenServer queue.

  ## Priority Order

  Verification before decomposition: verification unlocks completed goals,
  decomposition creates new work.

  ## State

  - `active_goals` -- goal_id => phase tracking for in-flight goals
  - `verification_retries` -- retry counts per goal_id
  - `pending_async` -- tracks one in-flight Task.async at a time
  """

  use GenServer
  require Logger

  alias AgentCom.GoalOrchestrator.{Decomposer, Verifier}

  defstruct active_goals: %{},
            verification_retries: %{},
            pending_async: nil

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Drive one tick of goal orchestration. Fire-and-forget cast."
  def tick do
    GenServer.cast(__MODULE__, :tick)
  end

  @doc "Return the count of active goals."
  def active_goal_count do
    GenServer.call(__MODULE__, :active_goal_count)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")

    Logger.info("goal_orchestrator_started")

    {:ok, %__MODULE__{}}
  end

  # -- active_goal_count -----------------------------------------------------

  @impl true
  def handle_call(:active_goal_count, _from, state) do
    {:reply, map_size(state.active_goals), state}
  end

  # -- tick ------------------------------------------------------------------

  @impl true
  def handle_cast(:tick, state) do
    new_state = do_tick(state)
    {:noreply, new_state}
  end

  # -- Task.async result messages --------------------------------------------

  @impl true
  def handle_info({ref, result}, %{pending_async: {ref, goal_id, :decompose}} = state)
      when is_reference(ref) do
    # Flush the DOWN message
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, task_ids} ->
        Logger.info("goal_decomposed", goal_id: goal_id, task_count: length(task_ids))

        # Transition goal to :executing via GoalBacklog
        try do
          AgentCom.GoalBacklog.transition(goal_id, :executing, child_task_ids: task_ids)
        catch
          :exit, _ -> :ok
        end

        :telemetry.execute(
          [:agent_com, :goal, :decomposed],
          %{task_count: length(task_ids)},
          %{goal_id: goal_id}
        )

        updated_goals = Map.put(state.active_goals, goal_id, %{phase: :executing})
        {:noreply, %{state | active_goals: updated_goals, pending_async: nil}}

      {:error, reason} ->
        Logger.error("goal_decomposition_failed", goal_id: goal_id, reason: inspect(reason))

        try do
          AgentCom.GoalBacklog.transition(goal_id, :failed, reason: inspect(reason))
        catch
          :exit, _ -> :ok
        end

        updated_goals = Map.delete(state.active_goals, goal_id)
        {:noreply, %{state | active_goals: updated_goals, pending_async: nil}}
    end
  end

  def handle_info({ref, result}, %{pending_async: {ref, goal_id, :verify}} = state)
      when is_reference(ref) do
    # Flush the DOWN message
    Process.demonitor(ref, [:flush])

    new_state = handle_verification_result(result, goal_id, state)
    {:noreply, new_state}
  end

  # DOWN messages from Task.async (process exited abnormally)
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_async: {ref, goal_id, op}} = state)
      when is_reference(ref) do
    Logger.error("async_task_crashed",
      goal_id: goal_id,
      operation: op,
      reason: inspect(reason)
    )

    # Clear pending_async so next tick can proceed; leave goal in current state for retry
    {:noreply, %{state | pending_async: nil}}
  end

  # -- PubSub task events ----------------------------------------------------

  def handle_info({:task_event, %{event: event, task: task}}, state)
      when event in [:task_completed, :task_dead_letter] do
    goal_id = Map.get(task, :goal_id)

    if goal_id && Map.has_key?(state.active_goals, goal_id) do
      new_state = check_goal_task_progress(goal_id, state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # Catch-all for other PubSub events
  def handle_info({:task_event, _}, state), do: {:noreply, state}
  def handle_info({:goal_event, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private: Tick Logic
  # ---------------------------------------------------------------------------

  defp do_tick(%{pending_async: pending} = state) when pending != nil do
    # Already have an in-flight async task; skip this tick
    state
  end

  defp do_tick(state) do
    # Priority 1: Check for goals needing verification
    case find_goal_ready_to_verify(state) do
      {:ok, goal_id} ->
        start_verification(goal_id, state)

      :none ->
        # Priority 2: Dequeue a new goal for decomposition
        try do
          case AgentCom.GoalBacklog.dequeue() do
            {:ok, goal} ->
              start_decomposition(goal, state)

            {:error, :empty} ->
              state
          end
        catch
          :exit, _ -> state
        end
    end
  end

  defp find_goal_ready_to_verify(state) do
    result =
      Enum.find(state.active_goals, fn {_id, info} ->
        info.phase == :ready_to_verify
      end)

    case result do
      {goal_id, _info} -> {:ok, goal_id}
      nil -> :none
    end
  end

  defp start_verification(goal_id, state) do
    retries = Map.get(state.verification_retries, goal_id, 0)

    case safe_get_goal(goal_id) do
      {:ok, goal} ->
        # Transition to :verifying in GoalBacklog
        try do
          AgentCom.GoalBacklog.transition(goal_id, :verifying)
        catch
          :exit, _ -> :ok
        end

        task = Task.async(fn -> Verifier.verify(goal, retries) end)

        updated_goals = Map.put(state.active_goals, goal_id, %{phase: :verifying})

        %{state |
          active_goals: updated_goals,
          pending_async: {task.ref, goal_id, :verify}
        }

      {:error, _} ->
        # Goal not found, remove from active
        updated_goals = Map.delete(state.active_goals, goal_id)
        %{state | active_goals: updated_goals}
    end
  end

  defp start_decomposition(goal, state) do
    goal_id = goal.id

    task = Task.async(fn -> Decomposer.decompose(goal) end)

    updated_goals = Map.put(state.active_goals, goal_id, %{phase: :decomposing})

    %{state |
      active_goals: updated_goals,
      pending_async: {task.ref, goal_id, :decompose}
    }
  end

  # ---------------------------------------------------------------------------
  # Private: Verification Result Handling
  # ---------------------------------------------------------------------------

  defp handle_verification_result({:ok, :pass}, goal_id, state) do
    Logger.info("goal_verified", goal_id: goal_id)

    try do
      AgentCom.GoalBacklog.transition(goal_id, :complete)
    catch
      :exit, _ -> :ok
    end

    :telemetry.execute(
      [:agent_com, :goal, :verified],
      %{},
      %{goal_id: goal_id}
    )

    %{state |
      active_goals: Map.delete(state.active_goals, goal_id),
      verification_retries: Map.delete(state.verification_retries, goal_id),
      pending_async: nil
    }
  end

  defp handle_verification_result({:ok, :needs_human_review}, goal_id, state) do
    Logger.warning("goal_needs_human_review", goal_id: goal_id)

    try do
      AgentCom.GoalBacklog.transition(goal_id, :failed,
        reason: "needs_human_review: max verification retries exceeded")
    catch
      :exit, _ -> :ok
    end

    %{state |
      active_goals: Map.delete(state.active_goals, goal_id),
      verification_retries: Map.delete(state.verification_retries, goal_id),
      pending_async: nil
    }
  end

  defp handle_verification_result({:ok, :fail, gaps}, goal_id, state) do
    Logger.info("goal_verification_failed_with_gaps",
      goal_id: goal_id,
      gap_count: length(gaps)
    )

    # Create follow-up tasks for the gaps
    case safe_get_goal(goal_id) do
      {:ok, goal} ->
        Verifier.create_followup_tasks(goal, gaps)
      {:error, _} ->
        :ok
    end

    # Increment retry count
    new_retries = Map.update(state.verification_retries, goal_id, 1, &(&1 + 1))

    # Transition goal back to :executing
    try do
      AgentCom.GoalBacklog.transition(goal_id, :executing)
    catch
      :exit, _ -> :ok
    end

    updated_goals = Map.put(state.active_goals, goal_id, %{phase: :executing})

    %{state |
      active_goals: updated_goals,
      verification_retries: new_retries,
      pending_async: nil
    }
  end

  defp handle_verification_result({:error, reason}, goal_id, state) do
    Logger.error("goal_verification_error",
      goal_id: goal_id,
      reason: inspect(reason)
    )

    # Keep goal in current state, clear pending_async (will retry on next tick)
    %{state | pending_async: nil}
  end

  # ---------------------------------------------------------------------------
  # Private: Task Progress Monitoring
  # ---------------------------------------------------------------------------

  defp check_goal_task_progress(goal_id, state) do
    progress =
      try do
        AgentCom.TaskQueue.goal_progress(goal_id)
      catch
        :exit, _ -> nil
      end

    case progress do
      %{pending: 0, failed: 0} ->
        # All tasks completed successfully
        Logger.info("all_tasks_complete_for_goal", goal_id: goal_id)
        updated_goals = Map.put(state.active_goals, goal_id, %{phase: :ready_to_verify})
        %{state | active_goals: updated_goals}

      %{pending: 0, failed: failed} when failed > 0 ->
        # Some failed, none pending -- still verify (verifier will see failures)
        Logger.info("all_tasks_done_some_failed",
          goal_id: goal_id,
          failed: failed
        )
        updated_goals = Map.put(state.active_goals, goal_id, %{phase: :ready_to_verify})
        %{state | active_goals: updated_goals}

      _ ->
        # Tasks still pending
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Helpers
  # ---------------------------------------------------------------------------

  defp safe_get_goal(goal_id) do
    try do
      AgentCom.GoalBacklog.get(goal_id)
    catch
      :exit, _ -> {:error, :not_available}
    end
  end
end
