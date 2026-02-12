defmodule AgentCom.MetricsCollector do
  @moduledoc """
  ETS-backed telemetry aggregation GenServer for system metrics.

  Attaches to telemetry events emitted throughout AgentCom and aggregates them
  into rolling-window metrics stored in an ETS table (`:agent_metrics`). The ETS
  table is `:public` with `read_concurrency: true` because telemetry handlers
  execute in the emitting process, not in MetricsCollector's process.

  ## Periodic Tasks

  - `:broadcast_snapshot` every 10 seconds -- computes a fresh snapshot, caches
    it in ETS, and broadcasts on PubSub "metrics" topic.
  - `:cleanup_window` every 5 minutes -- prunes data points older than 1 hour
    and enforces entry caps.
  - `:check_handlers` every 60 seconds -- verifies telemetry handlers are still
    attached and reattaches if detached.

  ## Public API

  - `snapshot/0` -- returns the cached metrics snapshot from ETS (zero-cost read).
  - `start_link/1` -- standard GenServer start.

  ## Snapshot Shape

  ```
  %{
    timestamp: ms,
    window_ms: 3_600_000,
    queue_depth: %{current: N, trend: [...], max_1h: N, avg_1h: N.N},
    task_latency: %{
      window: %{p50: N, p90: N, p99: N, count: N, min: N, max: N, mean: N},
      cumulative: %{p50: N, p90: N, p99: N, count: N}
    },
    agent_utilization: %{
      system: %{total_agents: N, agents_online: N, agents_idle: N, agents_working: N, utilization_pct: N.N},
      per_agent: [...]
    },
    error_rates: %{
      window: %{total_tasks: N, failed: N, dead_letter: N, failure_rate_pct: N.N},
      cumulative: %{total_tasks: N, failed: N, dead_letter: N, failure_rate_pct: N.N}
    },
    dets_health: map
  }
  ```
  """

  use GenServer
  require Logger

  @name __MODULE__
  @table :agent_metrics
  @window_ms 3_600_000
  @broadcast_interval_ms 10_000
  @cleanup_interval_ms 300_000
  @check_handlers_interval_ms 60_000
  @max_durations 10_000
  @max_transitions_per_agent 1_000
  @max_queue_depth_trend 60

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Return the current metrics snapshot.

  Reads from the ETS snapshot cache for zero-cost reads. Falls back to
  computing a fresh snapshot if the cache is not yet populated or the ETS
  table does not exist.
  """
  def snapshot do
    try do
      case :ets.lookup(@table, {:snapshot_cache}) do
        [{{:snapshot_cache}, cached}] -> cached
        [] -> compute_snapshot()
      end
    rescue
      ArgumentError -> empty_snapshot()
    end
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    # Create ETS table: named, :set, :public, read_concurrency for cross-process writes
    :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])

    # Initialize counters and gauges
    init_counters()

    # Attach telemetry handlers
    attach_handlers()

    # Schedule periodic tasks
    Process.send_after(self(), :broadcast_snapshot, @broadcast_interval_ms)
    Process.send_after(self(), :cleanup_window, @cleanup_interval_ms)
    Process.send_after(self(), :check_handlers, @check_handlers_interval_ms)

    Logger.info("metrics_collector_started",
      broadcast_interval_ms: @broadcast_interval_ms,
      window_ms: @window_ms
    )

    {:ok, %{}}
  end

  # -- Periodic: broadcast snapshot -------------------------------------------

  @impl true
  def handle_info(:broadcast_snapshot, state) do
    snap = compute_snapshot()

    try do
      :ets.insert(@table, {{:snapshot_cache}, snap})
    rescue
      ArgumentError -> :ok
    end

    Phoenix.PubSub.broadcast(AgentCom.PubSub, "metrics", {:metrics_snapshot, snap})

    Process.send_after(self(), :broadcast_snapshot, @broadcast_interval_ms)
    {:noreply, state}
  end

  # -- Periodic: cleanup old data points --------------------------------------

  def handle_info(:cleanup_window, state) do
    now_ms = System.system_time(:millisecond)
    cutoff = now_ms - @window_ms

    prune_durations({:durations, :task_wait}, cutoff)
    prune_durations({:durations, :task_duration}, cutoff)

    # Prune per-agent transitions
    try do
      :ets.foldl(
        fn
          {{:transitions, _agent_id} = key, entries}, _acc ->
            pruned =
              entries
              |> Enum.filter(fn {ts, _from, _to} -> ts >= cutoff end)
              |> Enum.take(@max_transitions_per_agent)

            :ets.insert(@table, {key, pruned})
            :ok

          _, acc ->
            acc
        end,
        :ok,
        @table
      )
    rescue
      ArgumentError -> :ok
    end

    Process.send_after(self(), :cleanup_window, @cleanup_interval_ms)
    {:noreply, state}
  end

  # -- Periodic: check handler attachment -------------------------------------

  def handle_info(:check_handlers, state) do
    handler_ids = [
      "metrics-collector-tasks",
      "metrics-collector-agents",
      "metrics-collector-fsm",
      "metrics-collector-scheduler"
    ]

    all_handlers =
      try do
        :telemetry.list_handlers([:agent_com])
      rescue
        _ -> []
      end

    attached_ids = Enum.map(all_handlers, fn handler -> handler.id end)

    Enum.each(handler_ids, fn id ->
      unless id in attached_ids do
        Logger.warning("metrics_collector_handler_detached", handler_id: id, action: :reattach)
        reattach_handler(id)
      end
    end)

    Process.send_after(self(), :check_handlers, @check_handlers_interval_ms)
    {:noreply, state}
  end

  # Catch-all for unknown messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- GenServer.cast for appending duration data points ----------------------

  @impl true
  def handle_cast({:record_duration, key, timestamp_ms, value_ms}, state) do
    try do
      existing =
        case :ets.lookup(@table, {:durations, key}) do
          [{{:durations, ^key}, entries}] -> entries
          [] -> []
        end

      updated = [{timestamp_ms, value_ms} | existing] |> Enum.take(@max_durations)
      :ets.insert(@table, {{:durations, key}, updated})
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:record_transition, agent_id, timestamp_ms, from_state, to_state}, state) do
    try do
      existing =
        case :ets.lookup(@table, {:transitions, agent_id}) do
          [{{:transitions, ^agent_id}, entries}] -> entries
          [] -> []
        end

      updated =
        [{timestamp_ms, from_state, to_state} | existing]
        |> Enum.take(@max_transitions_per_agent)

      :ets.insert(@table, {{:transitions, agent_id}, updated})
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Telemetry handler callbacks (run in emitting process, NOT this GenServer)
  # ---------------------------------------------------------------------------

  @doc false
  def handle_task_event([:agent_com, :task, action], measurements, metadata, _config) do
    try do
      case action do
        :submit ->
          :ets.update_counter(@table, {:counter, :tasks_submitted}, 1, {{:counter, :tasks_submitted}, 0})
          :ets.update_counter(@table, {:cumulative, :tasks_submitted}, 1, {{:cumulative, :tasks_submitted}, 0})

        :assign ->
          wait_ms = Map.get(measurements, :wait_ms, 0)
          now_ms = System.system_time(:millisecond)
          GenServer.cast(@name, {:record_duration, :task_wait, now_ms, wait_ms})

        :complete ->
          duration_ms = Map.get(measurements, :duration_ms, 0)
          now_ms = System.system_time(:millisecond)
          GenServer.cast(@name, {:record_duration, :task_duration, now_ms, duration_ms})
          :ets.update_counter(@table, {:counter, :tasks_completed}, 1, {{:counter, :tasks_completed}, 0})
          :ets.update_counter(@table, {:cumulative, :tasks_completed}, 1, {{:cumulative, :tasks_completed}, 0})

        :fail ->
          :ets.update_counter(@table, {:counter, :tasks_failed}, 1, {{:counter, :tasks_failed}, 0})
          :ets.update_counter(@table, {:cumulative, :tasks_failed}, 1, {{:cumulative, :tasks_failed}, 0})

        :dead_letter ->
          :ets.update_counter(@table, {:counter, :tasks_dead_letter}, 1, {{:counter, :tasks_dead_letter}, 0})
          :ets.update_counter(@table, {:cumulative, :tasks_dead_letter}, 1, {{:cumulative, :tasks_dead_letter}, 0})

        :reclaim ->
          :ets.update_counter(@table, {:counter, :tasks_reclaimed}, 1, {{:counter, :tasks_reclaimed}, 0})

        :retry ->
          :ets.update_counter(@table, {:counter, :tasks_retried}, 1, {{:counter, :tasks_retried}, 0})

        _ ->
          :ok
      end
    rescue
      e ->
        Logger.error("metrics_collector_task_handler_crash", error: inspect(e), action: action, metadata: inspect(metadata))
    end
  end

  @doc false
  def handle_agent_event([:agent_com, :agent, action], _measurements, metadata, _config) do
    try do
      agent_id = Map.get(metadata, :agent_id, "unknown")

      case action do
        :connect ->
          existing =
            case :ets.lookup(@table, {:agents_online}) do
              [{{:agents_online}, set}] -> set
              [] -> MapSet.new()
            end

          :ets.insert(@table, {{:agents_online}, MapSet.put(existing, agent_id)})

        :disconnect ->
          existing =
            case :ets.lookup(@table, {:agents_online}) do
              [{{:agents_online}, set}] -> set
              [] -> MapSet.new()
            end

          :ets.insert(@table, {{:agents_online}, MapSet.delete(existing, agent_id)})

        _ ->
          :ok
      end
    rescue
      e ->
        Logger.error("metrics_collector_agent_handler_crash", error: inspect(e), action: action, metadata: inspect(metadata))
    end
  end

  @doc false
  def handle_fsm_event([:agent_com, :fsm, :transition], _measurements, metadata, _config) do
    try do
      agent_id = Map.get(metadata, :agent_id, "unknown")
      from_state = Map.get(metadata, :from_state)
      to_state = Map.get(metadata, :to_state)
      now_ms = System.system_time(:millisecond)

      GenServer.cast(@name, {:record_transition, agent_id, now_ms, from_state, to_state})
    rescue
      e ->
        Logger.error("metrics_collector_fsm_handler_crash", error: inspect(e), metadata: inspect(metadata))
    end
  end

  @doc false
  def handle_scheduler_event([:agent_com, :scheduler, :attempt], measurements, _metadata, _config) do
    try do
      queued_tasks = Map.get(measurements, :queued_tasks, 0)
      :ets.insert(@table, {{:gauge, :queue_depth}, queued_tasks})

      # Update queue depth trend
      existing_trend =
        case :ets.lookup(@table, {:trend, :queue_depth}) do
          [{{:trend, :queue_depth}, trend}] -> trend
          [] -> []
        end

      updated_trend = (existing_trend ++ [queued_tasks]) |> Enum.take(-@max_queue_depth_trend)
      :ets.insert(@table, {{:trend, :queue_depth}, updated_trend})
    rescue
      e ->
        Logger.error("metrics_collector_scheduler_handler_crash", error: inspect(e))
    end
  end

  # ---------------------------------------------------------------------------
  # Private: telemetry attachment
  # ---------------------------------------------------------------------------

  defp attach_handlers do
    # Task events
    :telemetry.attach_many(
      "metrics-collector-tasks",
      [
        [:agent_com, :task, :submit],
        [:agent_com, :task, :assign],
        [:agent_com, :task, :complete],
        [:agent_com, :task, :fail],
        [:agent_com, :task, :dead_letter],
        [:agent_com, :task, :reclaim],
        [:agent_com, :task, :retry]
      ],
      &__MODULE__.handle_task_event/4,
      %{}
    )

    # Agent events
    :telemetry.attach_many(
      "metrics-collector-agents",
      [
        [:agent_com, :agent, :connect],
        [:agent_com, :agent, :disconnect]
      ],
      &__MODULE__.handle_agent_event/4,
      %{}
    )

    # FSM transition (single event)
    :telemetry.attach(
      "metrics-collector-fsm",
      [:agent_com, :fsm, :transition],
      &__MODULE__.handle_fsm_event/4,
      %{}
    )

    # Scheduler attempt (single event)
    :telemetry.attach(
      "metrics-collector-scheduler",
      [:agent_com, :scheduler, :attempt],
      &__MODULE__.handle_scheduler_event/4,
      %{}
    )
  end

  defp reattach_handler("metrics-collector-tasks") do
    try do
      :telemetry.attach_many(
        "metrics-collector-tasks",
        [
          [:agent_com, :task, :submit],
          [:agent_com, :task, :assign],
          [:agent_com, :task, :complete],
          [:agent_com, :task, :fail],
          [:agent_com, :task, :dead_letter],
          [:agent_com, :task, :reclaim],
          [:agent_com, :task, :retry]
        ],
        &__MODULE__.handle_task_event/4,
        %{}
      )
    rescue
      _ -> :ok
    end
  end

  defp reattach_handler("metrics-collector-agents") do
    try do
      :telemetry.attach_many(
        "metrics-collector-agents",
        [
          [:agent_com, :agent, :connect],
          [:agent_com, :agent, :disconnect]
        ],
        &__MODULE__.handle_agent_event/4,
        %{}
      )
    rescue
      _ -> :ok
    end
  end

  defp reattach_handler("metrics-collector-fsm") do
    try do
      :telemetry.attach(
        "metrics-collector-fsm",
        [:agent_com, :fsm, :transition],
        &__MODULE__.handle_fsm_event/4,
        %{}
      )
    rescue
      _ -> :ok
    end
  end

  defp reattach_handler("metrics-collector-scheduler") do
    try do
      :telemetry.attach(
        "metrics-collector-scheduler",
        [:agent_com, :scheduler, :attempt],
        &__MODULE__.handle_scheduler_event/4,
        %{}
      )
    rescue
      _ -> :ok
    end
  end

  defp reattach_handler(_), do: :ok

  # ---------------------------------------------------------------------------
  # Private: ETS initialization
  # ---------------------------------------------------------------------------

  defp init_counters do
    # Window counters
    Enum.each(
      [:tasks_submitted, :tasks_completed, :tasks_failed, :tasks_dead_letter, :tasks_reclaimed, :tasks_retried],
      fn key ->
        :ets.insert(@table, {{:counter, key}, 0})
      end
    )

    # Cumulative counters
    Enum.each(
      [:tasks_submitted, :tasks_completed, :tasks_failed, :tasks_dead_letter],
      fn key ->
        :ets.insert(@table, {{:cumulative, key}, 0})
      end
    )

    # Gauges
    :ets.insert(@table, {{:gauge, :queue_depth}, 0})

    # Duration lists
    :ets.insert(@table, {{:durations, :task_wait}, []})
    :ets.insert(@table, {{:durations, :task_duration}, []})

    # Agent online set
    :ets.insert(@table, {{:agents_online}, MapSet.new()})

    # Queue depth trend
    :ets.insert(@table, {{:trend, :queue_depth}, []})
  end

  # ---------------------------------------------------------------------------
  # Private: snapshot computation
  # ---------------------------------------------------------------------------

  defp compute_snapshot do
    try do
      now = System.system_time(:millisecond)
      cutoff = now - @window_ms

      # Queue depth
      queue_depth = read_gauge(:queue_depth)
      trend = read_trend(:queue_depth)

      {max_1h, avg_1h} =
        case trend do
          [] -> {0, 0.0}
          list -> {Enum.max(list), Float.round(Enum.sum(list) / length(list), 1)}
        end

      # Task latency (window)
      window_durations = read_durations(:task_duration, cutoff)
      window_values = Enum.map(window_durations, fn {_ts, val} -> val end)

      window_latency = %{
        p50: percentile(window_values, 0.50),
        p90: percentile(window_values, 0.90),
        p99: percentile(window_values, 0.99),
        count: length(window_values),
        min: safe_min(window_values),
        max: safe_max(window_values),
        mean: safe_mean(window_values)
      }

      # Task latency (cumulative -- all durations including outside window)
      all_durations = read_durations_all(:task_duration)
      all_values = Enum.map(all_durations, fn {_ts, val} -> val end)

      cumulative_latency = %{
        p50: percentile(all_values, 0.50),
        p90: percentile(all_values, 0.90),
        p99: percentile(all_values, 0.99),
        count: length(all_values)
      }

      # Agent utilization
      agents =
        try do
          AgentCom.AgentFSM.list_all()
        rescue
          _ -> []
        end

      agents_online_set = read_agents_online()
      agents_online_count = MapSet.size(agents_online_set)

      agents_idle =
        Enum.count(agents, fn a -> a.fsm_state == :idle end)

      agents_working =
        Enum.count(agents, fn a -> a.fsm_state in [:assigned, :working] end)

      total_agents = length(agents)

      utilization_pct =
        if total_agents > 0 do
          Float.round(agents_working / total_agents * 100.0, 1)
        else
          0.0
        end

      per_agent = compute_per_agent_utilization(agents, cutoff, now)

      # Error rates (window)
      _window_submitted = read_counter(:tasks_submitted)
      window_completed = read_counter(:tasks_completed)
      window_failed = read_counter(:tasks_failed)
      window_dead_letter = read_counter(:tasks_dead_letter)
      window_total = window_completed + window_failed + window_dead_letter

      window_failure_rate =
        if window_total > 0 do
          Float.round((window_failed + window_dead_letter) / window_total * 100.0, 1)
        else
          0.0
        end

      # Error rates (cumulative)
      _cum_submitted = read_cumulative(:tasks_submitted)
      cum_completed = read_cumulative(:tasks_completed)
      cum_failed = read_cumulative(:tasks_failed)
      cum_dead_letter = read_cumulative(:tasks_dead_letter)
      cum_total = cum_completed + cum_failed + cum_dead_letter

      cum_failure_rate =
        if cum_total > 0 do
          Float.round((cum_failed + cum_dead_letter) / cum_total * 100.0, 1)
        else
          0.0
        end

      # DETS health
      dets_health =
        try do
          AgentCom.DetsBackup.health_metrics()
        rescue
          _ -> nil
        end

      %{
        timestamp: now,
        window_ms: @window_ms,
        queue_depth: %{
          current: queue_depth,
          trend: trend,
          max_1h: max_1h,
          avg_1h: avg_1h
        },
        task_latency: %{
          window: window_latency,
          cumulative: cumulative_latency
        },
        agent_utilization: %{
          system: %{
            total_agents: total_agents,
            agents_online: agents_online_count,
            agents_idle: agents_idle,
            agents_working: agents_working,
            utilization_pct: utilization_pct
          },
          per_agent: per_agent
        },
        error_rates: %{
          window: %{
            total_tasks: window_total,
            failed: window_failed,
            dead_letter: window_dead_letter,
            failure_rate_pct: window_failure_rate
          },
          cumulative: %{
            total_tasks: cum_total,
            failed: cum_failed,
            dead_letter: cum_dead_letter,
            failure_rate_pct: cum_failure_rate
          }
        },
        dets_health: dets_health
      }
    rescue
      _ -> empty_snapshot()
    end
  end

  defp empty_snapshot do
    %{
      timestamp: System.system_time(:millisecond),
      window_ms: @window_ms,
      queue_depth: %{current: 0, trend: [], max_1h: 0, avg_1h: 0.0},
      task_latency: %{
        window: %{p50: 0, p90: 0, p99: 0, count: 0, min: 0, max: 0, mean: 0},
        cumulative: %{p50: 0, p90: 0, p99: 0, count: 0}
      },
      agent_utilization: %{
        system: %{total_agents: 0, agents_online: 0, agents_idle: 0, agents_working: 0, utilization_pct: 0.0},
        per_agent: []
      },
      error_rates: %{
        window: %{total_tasks: 0, failed: 0, dead_letter: 0, failure_rate_pct: 0.0},
        cumulative: %{total_tasks: 0, failed: 0, dead_letter: 0, failure_rate_pct: 0.0}
      },
      dets_health: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Private: ETS readers
  # ---------------------------------------------------------------------------

  defp read_counter(key) do
    case :ets.lookup(@table, {:counter, key}) do
      [{{:counter, ^key}, val}] -> val
      [] -> 0
    end
  end

  defp read_cumulative(key) do
    case :ets.lookup(@table, {:cumulative, key}) do
      [{{:cumulative, ^key}, val}] -> val
      [] -> 0
    end
  end

  defp read_gauge(key) do
    case :ets.lookup(@table, {:gauge, key}) do
      [{{:gauge, ^key}, val}] -> val
      [] -> 0
    end
  end

  defp read_trend(key) do
    case :ets.lookup(@table, {:trend, key}) do
      [{{:trend, ^key}, val}] -> val
      [] -> []
    end
  end

  defp read_durations(key, cutoff) do
    case :ets.lookup(@table, {:durations, key}) do
      [{{:durations, ^key}, entries}] ->
        Enum.filter(entries, fn {ts, _val} -> ts >= cutoff end)

      [] ->
        []
    end
  end

  defp read_durations_all(key) do
    case :ets.lookup(@table, {:durations, key}) do
      [{{:durations, ^key}, entries}] -> entries
      [] -> []
    end
  end

  defp read_agents_online do
    case :ets.lookup(@table, {:agents_online}) do
      [{{:agents_online}, set}] -> set
      [] -> MapSet.new()
    end
  end

  # ---------------------------------------------------------------------------
  # Private: per-agent utilization from FSM transitions
  # ---------------------------------------------------------------------------

  defp compute_per_agent_utilization(agents, cutoff, now) do
    Enum.map(agents, fn agent ->
      agent_id = agent.agent_id
      transitions = read_agent_transitions(agent_id, cutoff)

      # Compute time in each state category
      {idle_ms, working_ms, blocked_ms} = compute_state_times(transitions, agent.fsm_state, cutoff, now)
      total_ms = idle_ms + working_ms + blocked_ms

      idle_pct = if total_ms > 0, do: Float.round(idle_ms / total_ms * 100.0, 1), else: 0.0
      working_pct = if total_ms > 0, do: Float.round(working_ms / total_ms * 100.0, 1), else: 0.0
      blocked_pct = if total_ms > 0, do: Float.round(blocked_ms / total_ms * 100.0, 1), else: 0.0

      # Count completed tasks in window (from transitions where to_state == :idle after :working)
      tasks_completed_1h =
        transitions
        |> Enum.count(fn {_ts, from, to} -> from in [:working] and to == :idle end)

      # Average task duration from window durations for this agent
      # (We don't have per-agent duration data in ETS, so use global average)
      window_durations = read_durations(:task_duration, cutoff)

      avg_task_duration_ms =
        case window_durations do
          [] -> 0
          list ->
            vals = Enum.map(list, fn {_ts, val} -> val end)
            div(Enum.sum(vals), length(vals))
        end

      %{
        agent_id: agent_id,
        state: agent.fsm_state,
        idle_pct_1h: idle_pct,
        working_pct_1h: working_pct,
        blocked_pct_1h: blocked_pct,
        tasks_completed_1h: tasks_completed_1h,
        avg_task_duration_ms: avg_task_duration_ms
      }
    end)
  end

  defp read_agent_transitions(agent_id, cutoff) do
    try do
      case :ets.lookup(@table, {:transitions, agent_id}) do
        [{{:transitions, ^agent_id}, entries}] ->
          entries
          |> Enum.filter(fn {ts, _from, _to} -> ts >= cutoff end)
          |> Enum.sort_by(fn {ts, _from, _to} -> ts end)

        [] ->
          []
      end
    rescue
      ArgumentError -> []
    end
  end

  defp compute_state_times([], current_state, cutoff, now) do
    # No transitions in window -- agent has been in current state the whole time
    duration = now - cutoff
    categorize_state_duration(current_state, duration)
  end

  defp compute_state_times(transitions, _current_state, cutoff, now) do
    # Walk transitions to compute time in each state
    # Infer the state at cutoff from the first transition's from_state
    initial_state =
      case transitions do
        [{_ts, from, _to} | _] -> from
        _ -> :idle
      end

    # Build time segments
    segments = build_segments(transitions, cutoff, now, initial_state)

    Enum.reduce(segments, {0, 0, 0}, fn {state, duration_ms}, {idle, working, blocked} ->
      {di, dw, db} = categorize_state_duration(state, duration_ms)
      {idle + di, working + dw, blocked + db}
    end)
  end

  defp build_segments(transitions, cutoff, now, initial_state) do
    # First segment: cutoff to first transition
    [{first_ts, _, _} | _] = transitions
    first_segment = {initial_state, first_ts - cutoff}

    # Middle segments: between transitions
    middle =
      transitions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{ts1, _from1, to1}, {ts2, _from2, _to2}] ->
        {to1, ts2 - ts1}
      end)

    # Last segment: last transition to now
    {last_ts, _last_from, last_to} = List.last(transitions)
    last_segment = {last_to, now - last_ts}

    [first_segment | middle] ++ [last_segment]
  end

  defp categorize_state_duration(state, duration_ms) when duration_ms < 0, do: categorize_state_duration(state, 0)

  defp categorize_state_duration(state, duration_ms) do
    case state do
      s when s in [:idle, :offline] -> {duration_ms, 0, 0}
      s when s in [:assigned, :working] -> {0, duration_ms, 0}
      :blocked -> {0, 0, duration_ms}
      _ -> {duration_ms, 0, 0}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: percentile calculation
  # ---------------------------------------------------------------------------

  defp percentile([], _p), do: 0

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    count = length(sorted)
    index = floor(p * (count - 1))
    Enum.at(sorted, index, 0)
  end

  defp safe_min([]), do: 0
  defp safe_min(values), do: Enum.min(values)

  defp safe_max([]), do: 0
  defp safe_max(values), do: Enum.max(values)

  defp safe_mean([]), do: 0
  defp safe_mean(values), do: div(Enum.sum(values), length(values))

  # ---------------------------------------------------------------------------
  # Private: duration pruning
  # ---------------------------------------------------------------------------

  defp prune_durations(key, cutoff) do
    try do
      case :ets.lookup(@table, key) do
        [{^key, entries}] ->
          pruned =
            entries
            |> Enum.filter(fn {ts, _val} -> ts >= cutoff end)
            |> Enum.take(@max_durations)

          :ets.insert(@table, {key, pruned})

        [] ->
          :ok
      end
    rescue
      ArgumentError -> :ok
    end
  end
end
