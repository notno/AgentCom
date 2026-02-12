defmodule AgentCom.Scheduler do
  @moduledoc """
  Event-driven task-to-agent scheduler GenServer.

  The Scheduler subscribes to PubSub "tasks" and "presence" topics and reacts
  to scheduling-opportunity events by running a greedy matching loop that pairs
  queued tasks with idle, capable agents.

  ## Design (SCHED-04)

  PubSub events are the primary scheduling trigger. A 30-second stuck-assignment
  sweep provides a safety net for edge cases where events are missed or agents
  silently disappear.

  ## Scheduling triggers (SCHED-01)

  - `:task_submitted` -- new task queued
  - `:task_reclaimed` -- stuck/failed task returned to queue
  - `:task_retried` -- dead-letter task requeued
  - `:task_completed` -- agent finished work, now idle
  - `:agent_joined` -- new agent connected

  Events that are explicitly NOT scheduling triggers:
  - `:task_assigned` -- would cause feedback loop
  - `:task_dead_letter` -- task exhausted retries, no scheduling needed

  ## Capability matching (SCHED-02)

  Exact string match with subset semantics. A task's `needed_capabilities` must
  be a subset of the agent's declared capabilities. Empty `needed_capabilities`
  means any agent qualifies.

  ## Stuck sweep (SCHED-03)

  Every 30 seconds, the scheduler scans assigned tasks for ones whose
  `updated_at` timestamp is older than 5 minutes. These are reclaimed via
  `TaskQueue.reclaim_task/1`, which broadcasts `:task_reclaimed` and triggers
  a new scheduling attempt.

  ## Stateless design

  The Scheduler holds no cached state. It queries TaskQueue and AgentFSM for
  current data on every scheduling attempt. This eliminates stale-state bugs
  at the cost of slightly more work per event (acceptable at expected scale).
  """

  use GenServer
  require Logger

  @stuck_sweep_interval_ms 30_000
  @stuck_threshold_ms 300_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")

    Process.send_after(self(), :sweep_stuck, @stuck_sweep_interval_ms)

    Logger.info("scheduler_started", subscriptions: ["tasks", "presence"])

    {:ok, %{}}
  end

  # -- Scheduling triggers: events that mean "there might be a match to make" --

  @impl true
  def handle_info({:task_event, %{event: :task_submitted}}, state) do
    try_schedule_all(:task_submitted)
    {:noreply, state}
  end

  def handle_info({:task_event, %{event: :task_reclaimed}}, state) do
    try_schedule_all(:task_reclaimed)
    {:noreply, state}
  end

  def handle_info({:task_event, %{event: :task_retried}}, state) do
    try_schedule_all(:task_retried)
    {:noreply, state}
  end

  def handle_info({:task_event, %{event: :task_completed}}, state) do
    try_schedule_all(:task_completed)
    {:noreply, state}
  end

  def handle_info({:agent_joined, _info}, state) do
    try_schedule_all(:agent_joined)
    {:noreply, state}
  end

  def handle_info({:agent_idle, _info}, state) do
    try_schedule_all(:agent_idle)
    {:noreply, state}
  end

  # -- Non-scheduling events: explicitly ignored --

  def handle_info({:task_event, %{event: _other}}, state) do
    {:noreply, state}
  end

  def handle_info({:agent_left, _}, state) do
    {:noreply, state}
  end

  def handle_info({:status_changed, _}, state) do
    {:noreply, state}
  end

  # -- Stuck assignment sweep (SCHED-03) --

  def handle_info(:sweep_stuck, state) do
    now = System.system_time(:millisecond)
    threshold = now - @stuck_threshold_ms

    assigned_tasks = AgentCom.TaskQueue.list(status: :assigned)

    Enum.each(assigned_tasks, fn task ->
      if task.updated_at < threshold do
        staleness_ms = now - task.updated_at
        staleness_min = Float.round(staleness_ms / 60_000, 1)

        Logger.warning("scheduler_reclaim_stuck",
          task_id: task.id,
          assigned_to: task.assigned_to,
          stale_minutes: staleness_min
        )

        AgentCom.TaskQueue.reclaim_task(task.id)
      end
    end)

    Process.send_after(self(), :sweep_stuck, @stuck_sweep_interval_ms)
    {:noreply, state}
  end

  # -- Catch-all for unexpected messages --

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private: scheduling logic
  # ---------------------------------------------------------------------------

  defp try_schedule_all(trigger) do
    idle_agents =
      AgentCom.AgentFSM.list_all()
      |> Enum.filter(fn a -> a.fsm_state == :idle end)

    case idle_agents do
      [] ->
        queued_tasks = AgentCom.TaskQueue.list(status: :queued)

        :telemetry.execute(
          [:agent_com, :scheduler, :attempt],
          %{idle_agents: 0, queued_tasks: length(queued_tasks)},
          %{trigger: trigger}
        )

        :ok

      agents ->
        queued_tasks = AgentCom.TaskQueue.list(status: :queued)

        :telemetry.execute(
          [:agent_com, :scheduler, :attempt],
          %{idle_agents: length(agents), queued_tasks: length(queued_tasks)},
          %{trigger: trigger}
        )

        do_match_loop(queued_tasks, agents)
    end
  end

  defp do_match_loop([], _agents), do: :ok
  defp do_match_loop(_tasks, []), do: :ok

  defp do_match_loop([task | rest_tasks], agents) do
    case Enum.find(agents, fn agent -> agent_matches_task?(agent, task) end) do
      nil ->
        # No matching agent for this task, try next task
        do_match_loop(rest_tasks, agents)

      matched_agent ->
        do_assign(task, matched_agent)
        remaining_agents = Enum.reject(agents, fn a -> a.agent_id == matched_agent.agent_id end)
        do_match_loop(rest_tasks, remaining_agents)
    end
  end

  defp agent_matches_task?(agent, task) do
    needed = Map.get(task, :needed_capabilities, [])

    if needed == [] do
      true
    else
      agent_cap_names =
        (agent.capabilities || [])
        |> Enum.map(fn
          %{name: name} -> name
          cap when is_binary(cap) -> cap
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      Enum.all?(needed, fn cap -> cap in agent_cap_names end)
    end
  end

  defp do_assign(task, agent) do
    case AgentCom.TaskQueue.assign_task(task.id, agent.agent_id) do
      {:ok, assigned_task} ->
        task_data = %{
          task_id: assigned_task.id,
          description: assigned_task.description,
          metadata: assigned_task.metadata,
          generation: assigned_task.generation
        }

        :telemetry.execute(
          [:agent_com, :scheduler, :match],
          %{},
          %{task_id: task.id, agent_id: agent.agent_id}
        )

        case Registry.lookup(AgentCom.AgentRegistry, agent.agent_id) do
          [{pid, _meta}] ->
            send(pid, {:push_task, task_data})

            Logger.info("scheduler_assigned",
              task_id: task.id,
              agent_id: agent.agent_id
            )

          [] ->
            Logger.warning("scheduler_ws_not_found",
              task_id: task.id,
              agent_id: agent.agent_id
            )
        end

      {:error, reason} ->
        Logger.warning("scheduler_assign_failed",
          task_id: task.id,
          agent_id: agent.agent_id,
          reason: inspect(reason)
        )
    end
  end
end
