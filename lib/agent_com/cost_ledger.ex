defmodule AgentCom.CostLedger do
  @moduledoc """
  GenServer tracking hub-side Claude Code CLI invocations with hard budget caps.

  Enforces per-state (Executing, Improving, Contemplating) invocation limits
  using a dual-layer store:

  - **DETS** (`:cost_ledger`) -- durable invocation records surviving restarts
  - **ETS** (`:cost_budget`) -- hot-path rolling window counters for O(1) budget checks

  `check_budget/1` reads directly from ETS (no GenServer.call) for zero-latency
  budget gating on the hot path. `record_invocation/2` writes to both layers
  via GenServer.call for consistency.

  Budget limits are read from `AgentCom.Config` at runtime, falling back to
  conservative defaults. Seven-day retention with daily cleanup.

  ## Default Budgets

  | State          | Max/Hour | Max/Day |
  |----------------|----------|---------|
  | Executing      | 20       | 100     |
  | Improving      | 10       | 40      |
  | Contemplating  | 5        | 15      |
  """
  use GenServer
  require Logger

  @dets_table :cost_ledger
  @ets_table :cost_budget
  @hourly_window_ms 3_600_000
  @daily_window_ms 86_400_000
  @retention_ms 7 * 24 * 60 * 60 * 1000
  @cleanup_interval_ms 24 * 60 * 60 * 1000
  @hub_states [:executing, :improving, :contemplating]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronous budget gate. Reads directly from ETS (no GenServer.call).

  Returns `:ok` if the hub_state has remaining budget, or `:budget_exhausted`
  if the hourly or daily limit has been reached.

  Fails open (returns `:ok`) if ETS table doesn't exist or Config is unavailable,
  to avoid blocking during startup or transient failures.
  """
  @spec check_budget(atom()) :: :ok | :budget_exhausted
  def check_budget(hub_state) when hub_state in @hub_states do
    try do
      hourly_count = ets_lookup_count({:hourly, hub_state})
      daily_count = ets_lookup_count({:daily, hub_state})

      limits = read_budget_limits(hub_state)
      hourly_limit = limits.max_per_hour
      daily_limit = limits.max_per_day

      if hourly_count >= hourly_limit or daily_count >= daily_limit do
        :budget_exhausted
      else
        :ok
      end
    rescue
      ArgumentError ->
        # ETS table doesn't exist yet -- fail open
        :ok
    end
  end

  @doc """
  Record an invocation for a hub_state. Persists to DETS and updates ETS counters.

  `metadata` map may include `:duration_ms` and `:prompt_type`.

  Returns `:ok`.
  """
  @spec record_invocation(atom(), map()) :: :ok
  def record_invocation(hub_state, metadata \\ %{}) when hub_state in @hub_states do
    GenServer.call(__MODULE__, {:record_invocation, hub_state, metadata})
  end

  @doc """
  Return per-state budget statistics.

  Returns a map with hourly, daily, and session breakdowns plus current budget limits.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Return invocation history records.

  Options:
  - `:state` -- filter by hub_state atom
  - `:since` -- minimum timestamp (milliseconds)
  - `:limit` -- max records to return (default 100)

  Returns list of record maps sorted by timestamp descending.
  """
  @spec history(keyword()) :: [map()]
  def history(opts \\ []) do
    GenServer.call(__MODULE__, {:history, opts})
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    data_dir = data_dir()
    File.mkdir_p!(data_dir)

    dets_path = Path.join(data_dir, "cost_ledger.dets") |> String.to_charlist()

    {:ok, @dets_table} =
      :dets.open_file(@dets_table, file: dets_path, type: :set, auto_save: 5_000)

    @ets_table =
      :ets.new(@ets_table, [:named_table, :public, :set, {:read_concurrency, true}])

    rebuild_ets_from_history()

    Process.send_after(self(), :cleanup, @cleanup_interval_ms)

    session_start = System.system_time(:millisecond)

    Logger.info("cost_ledger_started", session_start: session_start)

    {:ok, %{session_start: session_start}}
  end

  @impl true
  def handle_call({:record_invocation, hub_state, metadata}, _from, state) do
    id = generate_id()
    now = System.system_time(:millisecond)

    record = %{
      id: id,
      hub_state: hub_state,
      timestamp: now,
      duration_ms: Map.get(metadata, :duration_ms, 0),
      prompt_type: Map.get(metadata, :prompt_type, :unknown)
    }

    :dets.insert(@dets_table, {id, record})
    :dets.sync(@dets_table)

    recalculate_window_counts(hub_state)

    # Update session counter
    session_key = {:session, hub_state}
    try do
      :ets.update_counter(@ets_table, session_key, 1, {session_key, 0})
    rescue
      ArgumentError -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      %{
        hourly: build_state_counts(:hourly),
        daily: build_state_counts(:daily),
        session: build_state_counts(:session),
        budgets: build_budget_info()
      }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:history, opts}, _from, state) do
    filter_state = Keyword.get(opts, :state)
    since = Keyword.get(opts, :since, 0)
    limit = Keyword.get(opts, :limit, 100)

    records =
      :dets.foldl(
        fn {_id, record}, acc ->
          cond do
            filter_state != nil and record.hub_state != filter_state -> acc
            record.timestamp < since -> acc
            true -> [record | acc]
          end
        end,
        [],
        @dets_table
      )
      |> Enum.sort_by(& &1.timestamp, :desc)
      |> Enum.take(limit)

    {:reply, records, state}
  end

  @impl true
  def handle_call(:compact, _from, state) do
    path = :dets.info(@dets_table, :filename)
    :ok = :dets.close(@dets_table)

    case :dets.open_file(@dets_table, file: path, type: :set, repair: :force) do
      {:ok, @dets_table} ->
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("cost_ledger_compaction_failed", reason: inspect(reason))
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)
    cutoff = now - @retention_ms

    # Delete records older than retention period
    to_delete =
      :dets.foldl(
        fn {id, record}, acc ->
          if record.timestamp < cutoff, do: [id | acc], else: acc
        end,
        [],
        @dets_table
      )

    Enum.each(to_delete, fn id -> :dets.delete(@dets_table, id) end)

    if length(to_delete) > 0 do
      :dets.sync(@dets_table)
      Logger.info("cost_ledger_cleanup", deleted_records: length(to_delete))
    end

    # Rebuild ETS counters after cleanup
    rebuild_ets_from_history()

    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@dets_table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  defp rebuild_ets_from_history do
    now = System.system_time(:millisecond)
    hourly_cutoff = now - @hourly_window_ms
    daily_cutoff = now - @daily_window_ms

    # Initialize all counters to zero
    Enum.each(@hub_states, fn hub_state ->
      :ets.insert(@ets_table, {{:hourly, hub_state}, 0})
      :ets.insert(@ets_table, {{:daily, hub_state}, 0})
      :ets.insert(@ets_table, {{:session, hub_state}, 0})
    end)

    # Scan DETS and count
    :dets.foldl(
      fn {_id, record}, _acc ->
        hub_state = record.hub_state
        ts = record.timestamp

        if ts >= hourly_cutoff do
          :ets.update_counter(@ets_table, {:hourly, hub_state}, 1, {{:hourly, hub_state}, 0})
        end

        if ts >= daily_cutoff do
          :ets.update_counter(@ets_table, {:daily, hub_state}, 1, {{:daily, hub_state}, 0})
        end

        # On cold start, count all records as session records
        :ets.update_counter(@ets_table, {:session, hub_state}, 1, {{:session, hub_state}, 0})

        :ok
      end,
      :ok,
      @dets_table
    )

    :ok
  end

  defp recalculate_window_counts(hub_state) do
    now = System.system_time(:millisecond)
    hourly_cutoff = now - @hourly_window_ms
    daily_cutoff = now - @daily_window_ms

    {hourly, daily} =
      :dets.foldl(
        fn {_id, record}, {h, d} ->
          if record.hub_state == hub_state do
            h = if record.timestamp >= hourly_cutoff, do: h + 1, else: h
            d = if record.timestamp >= daily_cutoff, do: d + 1, else: d
            {h, d}
          else
            {h, d}
          end
        end,
        {0, 0},
        @dets_table
      )

    :ets.insert(@ets_table, {{:hourly, hub_state}, hourly})
    :ets.insert(@ets_table, {{:daily, hub_state}, daily})
  end

  defp read_budget_limits(hub_state) do
    budgets =
      try do
        AgentCom.Config.get(:hub_invocation_budgets)
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    defaults = default_budgets()

    case budgets do
      nil ->
        Map.get(defaults, hub_state, %{max_per_hour: 5, max_per_day: 15})

      budgets when is_map(budgets) ->
        default_for_state = Map.get(defaults, hub_state, %{max_per_hour: 5, max_per_day: 15})
        Map.merge(default_for_state, Map.get(budgets, hub_state, %{}))

      _ ->
        Map.get(defaults, hub_state, %{max_per_hour: 5, max_per_day: 15})
    end
  end

  defp default_budgets do
    %{
      executing: %{max_per_hour: 20, max_per_day: 100},
      improving: %{max_per_hour: 10, max_per_day: 40},
      contemplating: %{max_per_hour: 5, max_per_day: 15}
    }
  end

  defp build_state_counts(window) do
    counts =
      Enum.into(@hub_states, %{}, fn hub_state ->
        {hub_state, ets_lookup_count({window, hub_state})}
      end)

    total = counts |> Map.values() |> Enum.sum()
    Map.put(counts, :total, total)
  end

  defp build_budget_info do
    Enum.into(@hub_states, %{}, fn hub_state ->
      limits = read_budget_limits(hub_state)
      {hub_state, %{hourly_limit: limits.max_per_hour, daily_limit: limits.max_per_day}}
    end)
  end

  defp ets_lookup_count(key) do
    case :ets.lookup(@ets_table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  defp generate_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp data_dir do
    Application.get_env(
      :agent_com,
      :cost_ledger_data_dir,
      "priv/data/cost_ledger"
    )
  end
end
