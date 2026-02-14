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
    Logger.metadata(module: __MODULE__)

    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "backups")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "validation")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "alerts")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "rate_limits")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "llm_registry")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "repo_registry")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")

    Process.send_after(self(), :check_queue_growth, @queue_check_interval_ms)
    Process.send_after(self(), :reset_hourly, @hourly_reset_interval_ms)
    Process.send_after(self(), :reset_rate_limit_counts, 300_000)

    state = %{
      started_at: System.system_time(:millisecond),
      recent_completions: [],
      hourly_stats: %{completed: 0, failed: 0, total_tokens: 0, completion_times: []},
      queue_growth_checks: [],
      last_known_agents: MapSet.new(),
      validation_failures: [],
      validation_failure_counts: %{},
      validation_disconnects: [],
      rate_limit_violations: [],
      rate_limit_violation_counts: %{}
    }

    Logger.info("started",
      topics: [
        "tasks",
        "presence",
        "backups",
        "validation",
        "alerts",
        "rate_limits",
        "llm_registry",
        "repo_registry",
        "goals"
      ]
    )

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
    queued_tasks = AgentCom.TaskQueue.list(status: :queued)

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

    # Format queued tasks for the task list
    formatted_queued_tasks =
      Enum.map(queued_tasks, fn t ->
        complexity = Map.get(t, :complexity)

        %{
          id: t.id,
          description: t.description,
          priority: t.priority,
          submitted_by: Map.get(t, :submitted_by),
          created_at: t.created_at,
          complexity_tier:
            if(complexity, do: to_string(Map.get(complexity, :effective_tier)), else: nil)
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

    dets_health =
      try do
        AgentCom.DetsBackup.health_metrics()
      rescue
        _ -> nil
      end

    compaction_history =
      try do
        AgentCom.DetsBackup.compaction_history()
      rescue
        _ -> []
      end

    validation = %{
      recent_failures: state.validation_failures,
      failure_counts_by_agent: state.validation_failure_counts,
      recent_disconnects: state.validation_disconnects,
      total_failures_this_hour: state.validation_failure_counts |> Map.values() |> Enum.sum()
    }

    active_alerts =
      try do
        AgentCom.Alerter.active_alerts()
      rescue
        _ -> []
      end

    rate_limits =
      try do
        %{
          summary: AgentCom.RateLimiter.system_rate_summary(),
          per_agent:
            Enum.map(agents, fn a ->
              {a.agent_id, AgentCom.RateLimiter.agent_rate_status(a.agent_id)}
            end)
            |> Enum.into(%{})
        }
      rescue
        _ -> %{summary: %{}, per_agent: %{}}
      end

    llm_registry =
      try do
        AgentCom.LlmRegistry.snapshot()
      rescue
        _ -> %{endpoints: [], resources: %{}, fleet_models: %{}}
      end

    repo_registry =
      try do
        AgentCom.RepoRegistry.snapshot()
      rescue
        _ -> %{repos: []}
      end

    # Compute routing stats from tasks with routing decisions
    all_tasks =
      try do
        AgentCom.TaskQueue.list([])
      rescue
        _ -> []
      end

    routing_stats = compute_routing_stats(all_tasks)

    hub_fsm =
      try do
        AgentCom.HubFSM.get_state()
      catch
        :exit, _ -> %{fsm_state: :unknown, paused: false, cycle_count: 0, transition_count: 0}
      end

    goal_stats =
      try do
        AgentCom.GoalBacklog.stats()
      catch
        :exit, _ -> %{by_status: %{}, by_priority: %{}, total: 0}
      end

    # Only fetch active goals (decomposing/executing/verifying) for progress display
    active_goals =
      try do
        [:decomposing, :executing, :verifying]
        |> Enum.flat_map(fn status ->
          AgentCom.GoalBacklog.list(%{status: status})
        end)
        |> Enum.take(10)
        |> Enum.map(fn goal ->
          progress = AgentCom.TaskQueue.goal_progress(goal.id)

          %{
            id: goal.id,
            description: String.slice(to_string(goal.description), 0, 100),
            status: goal.status,
            priority: goal.priority,
            tasks_total: progress.total,
            tasks_complete: progress.completed,
            tasks_failed: progress.failed,
            created_at: goal.created_at,
            updated_at: goal.updated_at
          }
        end)
      catch
        :exit, _ -> []
      end

    cost_stats =
      try do
        AgentCom.CostLedger.stats()
      catch
        :exit, _ ->
          %{
            hourly: %{executing: 0, improving: 0, contemplating: 0, total: 0},
            daily: %{executing: 0, improving: 0, contemplating: 0, total: 0},
            session: %{executing: 0, improving: 0, contemplating: 0, total: 0},
            budgets: %{}
          }
      end

    snapshot = %{
      uptime_ms: now - state.started_at,
      timestamp: now,
      health: health,
      agents: formatted_agents,
      queue: queue,
      dead_letter_tasks: formatted_dead_letter,
      queued_tasks: formatted_queued_tasks,
      recent_completions: state.recent_completions,
      throughput: throughput,
      dets_health: dets_health,
      compaction_history: compaction_history,
      validation: validation,
      active_alerts: active_alerts,
      rate_limits: rate_limits,
      llm_registry: llm_registry,
      repo_registry: repo_registry,
      routing_stats: routing_stats,
      hub_fsm: hub_fsm,
      goal_stats: goal_stats,
      active_goals: active_goals,
      cost_stats: cost_stats
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

    {:noreply,
     %{
       state
       | hourly_stats: %{
           completed: 0,
           failed: 0,
           total_tokens: 0,
           completion_times: []
         },
         validation_failure_counts: %{}
     }}
  end

  # -- PubSub: compaction/recovery events --------------------------------------

  def handle_info({:compaction_complete, _info}, state) do
    # Compaction complete triggers no state change -- compaction_history is fetched live from DetsBackup
    {:noreply, state}
  end

  def handle_info({:compaction_failed, info}, state) do
    Logger.warning("compaction_failures_detected",
      failures: inspect(info[:failures] || info.failures)
    )

    {:noreply, state}
  end

  def handle_info({:recovery_complete, info}, state) do
    trigger = info[:trigger] || :unknown
    table = info[:table] || :unknown
    Logger.info("recovery_complete", table: table, trigger: trigger)
    {:noreply, state}
  end

  def handle_info({:recovery_failed, info}, state) do
    table = info[:table] || :unknown
    Logger.error("recovery_failed", table: table, reason: inspect(info[:reason]))
    {:noreply, state}
  end

  # -- PubSub: validation events -----------------------------------------------

  def handle_info({:validation_failure, info}, state) do
    entry = %{
      agent_id: info.agent_id,
      message_type: info.message_type,
      error_count: info.error_count,
      timestamp: info.timestamp
    }

    failures = [entry | state.validation_failures] |> Enum.take(50)

    agent_id = info.agent_id || "unknown"
    counts = Map.update(state.validation_failure_counts, agent_id, 1, &(&1 + 1))

    {:noreply, %{state | validation_failures: failures, validation_failure_counts: counts}}
  end

  def handle_info({:validation_disconnect, info}, state) do
    entry = %{agent_id: info.agent_id, timestamp: info.timestamp}
    disconnects = [entry | state.validation_disconnects] |> Enum.take(20)
    {:noreply, %{state | validation_disconnects: disconnects}}
  end

  # -- PubSub: alert events (snapshot stays current when alerts change) ---------

  def handle_info({:alert_fired, _alert}, state) do
    # Alert fired triggers snapshot refresh so next snapshot/0 call includes it.
    # The actual alert data is fetched live from Alerter.active_alerts/0 in snapshot.
    {:noreply, state}
  end

  def handle_info({:alert_cleared, _rule_id}, state) do
    {:noreply, state}
  end

  def handle_info({:alert_acknowledged, _rule_id}, state) do
    {:noreply, state}
  end

  # -- PubSub: rate limit events ------------------------------------------------

  def handle_info({:rate_limit_violation, %{agent_id: agent_id} = event}, state) do
    # Add to ring buffer (capped at 100 like validation_failures)
    violations = Enum.take([event | state.rate_limit_violations], @ring_buffer_cap)

    # Track per-agent count for notification threshold
    counts = Map.update(state.rate_limit_violation_counts, agent_id, 1, &(&1 + 1))

    new_state = %{state | rate_limit_violations: violations, rate_limit_violation_counts: counts}

    # Send push notification every 10th violation per agent
    agent_count = Map.get(counts, agent_id, 0)

    if rem(agent_count, 10) == 0 do
      AgentCom.DashboardNotifier.notify(%{
        title: "Rate Limit Alert",
        body: "Agent #{agent_id} has #{agent_count} rate limit violations",
        tag: "rate-limit-#{agent_id}"
      })
    end

    {:noreply, new_state}
  end

  # -- Periodic: reset rate limit violation counts (every 5 minutes) -----------

  def handle_info(:reset_rate_limit_counts, state) do
    Process.send_after(self(), :reset_rate_limit_counts, 300_000)
    {:noreply, %{state | rate_limit_violation_counts: %{}}}
  end

  # -- PubSub: llm_registry events (data fetched live in snapshot) ------------

  def handle_info({:llm_registry_update, _detail}, state) do
    {:noreply, state}
  end

  # -- PubSub: repo_registry events (data fetched live in snapshot) ----------

  def handle_info({:repo_registry_update, _detail}, state) do
    {:noreply, state}
  end

  # -- PubSub: goal events (data fetched live in snapshot) ------------------

  def handle_info({:goal_event, _payload}, state) do
    {:noreply, state}
  end

  # Catch-all for unhandled PubSub messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Skip socket log_task_event broadcasts that lack a :task map.
  # The authoritative completion broadcast from TaskQueue always includes :task.
  defp handle_task_event(event, info, state)
       when event in ["task_complete", "task_completed"] and not is_map_key(info, :task) do
    state
  end

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

    verification_report = Map.get(task, :verification_report)
    routing_decision = Map.get(task, :routing_decision)

    # Extract execution metadata from result map (Phase 20: cost tracking)
    result = Map.get(task, :result) || %{}
    execution_meta = extract_execution_meta(result)

    entry = %{
      task_id: task_id,
      agent_id: agent_id,
      description: description,
      duration_ms: duration_ms,
      tokens_used: tokens_used,
      completed_at: now,
      verification_report: verification_report,
      routing_decision: format_routing_decision_for_dashboard(routing_decision),
      execution_meta: execution_meta
    }

    # Ring buffer: prepend and cap at @ring_buffer_cap
    recent = [entry | state.recent_completions] |> Enum.take(@ring_buffer_cap)

    # Update hourly stats
    hourly = state.hourly_stats

    hourly = %{
      hourly
      | completed: hourly.completed + 1,
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
        {[
           "High failure rate: #{state.hourly_stats.failed}/#{total} tasks failed this hour"
           | conditions
         ], true}
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

    # 5. Stale DETS Backup
    dets_metrics =
      try do
        AgentCom.DetsBackup.health_metrics()
      rescue
        _ -> nil
      end

    conditions =
      if dets_metrics do
        now_ms = now

        case dets_metrics.last_backup_at do
          nil ->
            ["DETS backup: never run" | conditions]

          ts when now_ms - ts > 48 * 60 * 60 * 1000 ->
            hours_ago = div(now_ms - ts, 3_600_000)
            ["DETS backup stale: last backup #{hours_ago}h ago" | conditions]

          _ ->
            conditions
        end
      else
        conditions
      end

    # 6. High DETS Fragmentation
    conditions =
      if dets_metrics do
        high_frag_tables =
          dets_metrics.tables
          |> Enum.filter(fn t -> t.status == :ok and t.fragmentation_ratio > 0.5 end)
          |> Enum.map(fn t -> to_string(t.table) end)

        if length(high_frag_tables) > 0 do
          ["DETS fragmentation >50%: #{Enum.join(high_frag_tables, ", ")}" | conditions]
        else
          conditions
        end
      else
        conditions
      end

    # 7. High validation failure rate
    total_val_failures = state.validation_failure_counts |> Map.values() |> Enum.sum()

    conditions =
      if total_val_failures > 50 do
        ["High validation failures: #{total_val_failures} this hour" | conditions]
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

  defp format_routing_decision_for_dashboard(nil), do: nil

  defp format_routing_decision_for_dashboard(rd) when is_map(rd) do
    %{
      effective_tier: to_string(Map.get(rd, :effective_tier)),
      target_type: to_string(Map.get(rd, :target_type)),
      selected_endpoint: safe_to_string_or_nil(Map.get(rd, :selected_endpoint)),
      selected_model: safe_to_string_or_nil(Map.get(rd, :selected_model)),
      fallback_used: Map.get(rd, :fallback_used, false),
      fallback_from_tier: safe_to_string_or_nil(Map.get(rd, :fallback_from_tier)),
      fallback_reason: safe_to_string_or_nil(Map.get(rd, :fallback_reason)),
      candidate_count: Map.get(rd, :candidate_count),
      classification_reason: safe_to_string_or_nil(Map.get(rd, :classification_reason)),
      estimated_cost_tier: safe_to_string_or_nil(Map.get(rd, :estimated_cost_tier)),
      decided_at: Map.get(rd, :decided_at)
    }
  end

  defp safe_to_string_or_nil(nil), do: nil
  defp safe_to_string_or_nil(val) when is_atom(val), do: to_string(val)
  defp safe_to_string_or_nil(val) when is_binary(val), do: val
  defp safe_to_string_or_nil(val), do: inspect(val)

  # Extract execution metadata from the task result map.
  # The dispatcher stores model_used, tokens_in, tokens_out, estimated_cost_usd,
  # equivalent_claude_cost_usd, and execution_ms in the result map.
  # Keys may be strings (from JSON) or atoms.
  defp extract_execution_meta(result) when is_map(result) do
    get = fn key ->
      Map.get(result, key) || Map.get(result, to_string(key))
    end

    model_used = get.(:model_used)
    tokens_in = get.(:tokens_in)
    tokens_out = get.(:tokens_out)
    estimated_cost_usd = get.(:estimated_cost_usd)
    equivalent_claude_cost_usd = get.(:equivalent_claude_cost_usd)
    execution_ms = get.(:execution_ms)

    # Only include if any execution metadata is present
    if model_used || tokens_in || tokens_out || estimated_cost_usd do
      %{
        model_used: model_used,
        tokens_in: tokens_in,
        tokens_out: tokens_out,
        estimated_cost_usd: estimated_cost_usd,
        equivalent_claude_cost_usd: equivalent_claude_cost_usd,
        execution_ms: execution_ms
      }
    else
      nil
    end
  end

  defp extract_execution_meta(_), do: nil

  defp compute_routing_stats(tasks) do
    routed_tasks =
      Enum.filter(tasks, fn t ->
        Map.get(t, :routing_decision) != nil
      end)

    total_routed = length(routed_tasks)

    by_tier =
      Enum.reduce(routed_tasks, %{}, fn t, acc ->
        tier = get_in(t, [:routing_decision, :effective_tier]) |> to_string()
        Map.update(acc, tier, 1, &(&1 + 1))
      end)

    by_target =
      Enum.reduce(routed_tasks, %{}, fn t, acc ->
        target = get_in(t, [:routing_decision, :target_type]) |> to_string()
        Map.update(acc, target, 1, &(&1 + 1))
      end)

    fallback_count =
      Enum.count(routed_tasks, fn t ->
        get_in(t, [:routing_decision, :fallback_used]) == true
      end)

    %{
      total_routed: total_routed,
      by_tier: by_tier,
      by_target: by_target,
      fallback_count: fallback_count
    }
  end
end
