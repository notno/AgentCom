defmodule AgentCom.DashboardState do
  @moduledoc """
  State aggregation GenServer for the real-time dashboard.

  Subscribes to PubSub topics "tasks" and "presence" and maintains in-memory
  metrics: recent completions ring buffer, hourly throughput stats, queue growth
  checks, and known agent tracking. The `snapshot/0` function returns a
  pre-computed map of all dashboard state, pulling live data from AgentFSM and
  TaskQueue while combining it with locally tracked metrics.

  Health heuristics compute :ok / :warning / :critical status based on:
  - Agent Offline (WARNING): agent was recently known but absent from FSM list
  - Queue Growing (WARNING): 3 consecutive queue depth increases
  - High Failure Rate (CRITICAL): >50% failure rate in the last hour
  - Stuck Tasks (WARNING): any assigned task with no update for >5 minutes
  """

  use GenServer
  require Logger

  @name __MODULE__
  @ring_buffer_cap 100
  @stuck_task_threshold_ms 300_000
  @queue_check_interval_ms 60_000
  @hourly_reset_interval_ms 3_600_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Return a snapshot of the full dashboard state.

  Pulls live data from AgentFSM and TaskQueue, combines with locally tracked
  metrics (recent completions, throughput, health heuristics).
  """
  def snapshot do
    GenServer.call(@name, :snapshot)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")

    Process.send_after(self(), :check_queue_growth, @queue_check_interval_ms)
    Process.send_after(self(), :reset_hourly, @hourly_reset_interval_ms)

    state = %{
      started_at: System.system_time(:millisecond),
      recent_completions: [],
      hourly_stats: %{completed: 0, failed: 0, total_tokens: 0, completion_times: []},
      queue_growth_checks: [],
      last_known_agents: MapSet.new()
    }

    Logger.info("DashboardState: started, subscribed to tasks and presence topics")

    {:ok, state}
  end

  # -- snapshot ----------------------------------------------------------------

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = System.system_time(:millisecond)

    # Pull live data from other GenServers
    agents = AgentCom.AgentFSM.list_all()
    queue_stats = AgentCom.TaskQueue.stats()
    dead_letter_tasks = AgentCom.TaskQueue.list_dead_letter()

    # Compute health
    health = compute_health(state, agents, now)

    # Compute throughput
    throughput = compute_throughput(state)

    # Format agents for the snapshot
    formatted_agents =
      Enum.map(agents, fn a ->
        %{
          agent_id: a.agent_id,
          name: a.name,
          fsm_state: a.fsm_state,
          current_task_id: a.current_task_id,
          capabilities: a.capabilities,
          connected_at: a.connected_at,
          last_state_change: a.last_state_change
        }
      end)

    # Format dead-letter tasks
    formatted_dead_letter =
      Enum.map(dead_letter_tasks, fn t ->
        %{
          id: t.id,
          description: t.description,
          last_error: Map.get(t, :last_error),
          retry_count: t.retry_count,
          created_at: t.created_at
        }
      end)

    # Format queue stats
    by_status = Map.get(queue_stats, :by_status, %{})
    by_priority = Map.get(queue_stats, :by_priority, %{})

    queue = %{
      by_status: %{
        queued: Map.get(by_status, :queued, 0),
        assigned: Map.get(by_status, :assigned, 0),
        completed: Map.get(by_status, :completed, 0)
      },
      by_priority: %{
        0 => Map.get(by_priority, 0, 0),
        1 => Map.get(by_priority, 1, 0),
        2 => Map.get(by_priority, 2, 0),
        3 => Map.get(by_priority, 3, 0)
      },
      dead_letter: Map.get(queue_stats, :dead_letter, 0)
    }

    snapshot = %{
      uptime_ms: now - state.started_at,
      timestamp: now,
      health: health,
      agents: formatted_agents,
      queue: queue,
      dead_letter_tasks: formatted_dead_letter,
      recent_completions: state.recent_completions,
      throughput: throughput
    }

    {:reply, snapshot, state}
  end

  # -- PubSub: task events -----------------------------------------------------

  @impl true
  def handle_info({:task_event, %{event: event} = info}, state) do
    # event may be a string (from Socket broadcasts) or atom (from TaskQueue broadcasts)
    normalized_event = if is_atom(event), do: to_string(event), else: event
    state = handle_task_event(normalized_event, info, state)
    {:noreply, state}
  end

  # -- PubSub: presence events -------------------------------------------------

  def handle_info({:agent_joined, info}, state) do
    agent_id = info[:agent_id] || info.agent_id
    new_agents = MapSet.put(state.last_known_agents, agent_id)
    {:noreply, %{state | last_known_agents: new_agents}}
  end

  def handle_info({:agent_left, _agent_id}, state) do
    # Don't remove immediately -- the "offline" heuristic checks FSM list
    # against last_known_agents, handling the transient window
    {:noreply, state}
  end

  # -- Periodic timers ---------------------------------------------------------

  def handle_info(:check_queue_growth, state) do
    queue_stats = AgentCom.TaskQueue.stats()
    queued_count = get_in(queue_stats, [:by_status, :queued]) || 0

    checks =
      (state.queue_growth_checks ++ [queued_count])
      |> Enum.take(-3)

    Process.send_after(self(), :check_queue_growth, @queue_check_interval_ms)
    {:noreply, %{state | queue_growth_checks: checks}}
  end

  def handle_info(:reset_hourly, state) do
    Process.send_after(self(), :reset_hourly, @hourly_reset_interval_ms)

    {:noreply, %{state | hourly_stats: %{
      completed: 0,
      failed: 0,
      total_tokens: 0,
      completion_times: []
    }}}
  end

  # Catch-all for unhandled PubSub messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp handle_task_event(event, info, state) when event in ["task_complete", "task_completed"] do
    now = System.system_time(:millisecond)

    # Extract completion details
    task = Map.get(info, :task, %{})
    task_id = Map.get(info, :task_id, Map.get(task, :id))
    agent_id = Map.get(info, :agent_id, Map.get(task, :assigned_to))
    tokens_used = Map.get(task, :tokens_used, 0) || 0
    description = Map.get(task, :description, "")

    # Compute duration from task history if available
    duration_ms =
      case Map.get(task, :assigned_at) do
        nil -> 0
        assigned_at -> now - assigned_at
      end

    entry = %{
      task_id: task_id,
      agent_id: agent_id,
      description: description,
      duration_ms: duration_ms,
      tokens_used: tokens_used,
      completed_at: now
    }

    # Ring buffer: prepend and cap at @ring_buffer_cap
    recent = [entry | state.recent_completions] |> Enum.take(@ring_buffer_cap)

    # Update hourly stats
    hourly = state.hourly_stats
    hourly = %{hourly |
      completed: hourly.completed + 1,
      total_tokens: hourly.total_tokens + (tokens_used || 0),
      completion_times: [duration_ms | hourly.completion_times]
    }

    %{state | recent_completions: recent, hourly_stats: hourly}
  end

  defp handle_task_event(event, _info, state) when event in ["task_failed", "task_dead_letter"] do
    hourly = state.hourly_stats
    hourly = %{hourly | failed: hourly.failed + 1}
    %{state | hourly_stats: hourly}
  end

  defp handle_task_event(_event, _info, state), do: state

  defp compute_health(state, agents, now) do
    conditions = []

    # 1. Agent Offline: agent was in last_known_agents but not in current FSM list
    current_agent_ids = MapSet.new(Enum.map(agents, & &1.agent_id))

    offline_agents =
      state.last_known_agents
      |> MapSet.difference(current_agent_ids)
      |> MapSet.to_list()

    conditions =
      if length(offline_agents) > 0 do
        ["Agent offline: #{Enum.join(offline_agents, ", ")}" | conditions]
      else
        conditions
      end

    # 2. Queue Growing: 3 consecutive strictly increasing checks
    conditions =
      case state.queue_growth_checks do
        [a, b, c] when a < b and b < c ->
          ["Queue growing: #{a} -> #{b} -> #{c}" | conditions]
        _ ->
          conditions
      end

    # 3. High Failure Rate: >50% failures when total > 0
    total = state.hourly_stats.completed + state.hourly_stats.failed

    {conditions, has_critical} =
      if total > 0 and state.hourly_stats.failed / total > 0.5 do
        {["High failure rate: #{state.hourly_stats.failed}/#{total} tasks failed this hour" | conditions], true}
      else
        {conditions, false}
      end

    # 4. Stuck Tasks: assigned tasks with updated_at > 5 minutes ago
    assigned_tasks =
      try do
        AgentCom.TaskQueue.list(status: :assigned)
      rescue
        _ -> []
      end

    stuck_tasks =
      Enum.filter(assigned_tasks, fn t ->
        updated_at = Map.get(t, :updated_at, 0)
        now - updated_at > @stuck_task_threshold_ms
      end)

    conditions =
      if length(stuck_tasks) > 0 do
        ids = Enum.map(stuck_tasks, & &1.id) |> Enum.join(", ")
        ["Stuck tasks: #{ids}" | conditions]
      else
        conditions
      end

    # Determine status
    status =
      cond do
        has_critical -> :critical
        length(conditions) > 0 -> :warning
        true -> :ok
      end

    %{status: status, conditions: Enum.reverse(conditions)}
  end

  defp compute_throughput(state) do
    hourly = state.hourly_stats
    times = hourly.completion_times

    avg_completion_ms =
      case times do
        [] -> 0
        _ -> div(Enum.sum(times), length(times))
      end

    %{
      completed_last_hour: hourly.completed,
      avg_completion_ms: avg_completion_ms,
      total_tokens_hour: hourly.total_tokens
    }
  end
end
