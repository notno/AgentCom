defmodule AgentCom.DetsBackup do
  @moduledoc """
  GenServer for automated DETS table backups, retention cleanup, health metrics,
  and compaction orchestration.

  Handles:
  - Daily automatic backup of all 9 DETS tables via Process.send_after timer
  - Manual backup trigger via backup_all/0 (synchronous, returns results)
  - Retention cleanup: keeps only last 3 backups per table
  - Health metrics: record count, file size, fragmentation ratio per table
  - PubSub broadcast on "backups" topic after each backup run
  - Scheduled compaction of all 9 DETS tables every 6 hours (configurable)
  - Fragmentation threshold skip (default 10%) to avoid unnecessary compaction
  - Retry-once on compaction failure, then wait for next scheduled run
  - Compaction history tracking (last 20 runs)
  """
  use GenServer
  require Logger

  @tables [
    :task_queue,
    :task_dead_letter,
    :agent_mailbox,
    :message_history,
    :agent_channels,
    :channel_history,
    :agentcom_config,
    :thread_messages,
    :thread_replies
  ]

  @daily_interval_ms 24 * 60 * 60 * 1000
  @max_backups_per_table 3
  @compaction_interval_ms Application.compile_env(:agent_com, :compaction_interval_ms, 6 * 60 * 60 * 1000)
  @compaction_threshold Application.compile_env(:agent_com, :compaction_threshold, 0.1)

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger a backup of all DETS tables synchronously.

  Returns `{:ok, results}` where results is a list of per-table outcome maps:
  `{:ok, %{table: atom, path: string, size: integer}}` or
  `{:error, %{table: atom, reason: term}}`.
  """
  def backup_all do
    GenServer.call(__MODULE__, :backup_all, 30_000)
  end

  @doc """
  Return health metrics for all 9 DETS tables.

  Returns a map with:
  - `:tables` - list of per-table metric maps (record_count, file_size_bytes, fragmentation_ratio, status)
  - `:last_backup_at` - epoch milliseconds of last backup, or nil
  - `:last_backup_results` - results from last backup run, or nil
  - `:last_compaction_at` - epoch milliseconds of last compaction, or nil
  - `:compaction_history` - list of recent compaction run results
  """
  def health_metrics do
    GenServer.call(__MODULE__, :health_metrics)
  end

  @doc """
  Compact all DETS tables synchronously. Skips tables below fragmentation threshold.
  Returns {:ok, results} with per-table compaction outcomes.
  """
  def compact_all do
    GenServer.call(__MODULE__, :compact_all, 120_000)
  end

  @doc "Return the compaction history log (recent events with time, table, result, duration)."
  def compaction_history do
    GenServer.call(__MODULE__, :compaction_history)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    backup_dir = Application.get_env(:agent_com, :backup_dir, "priv/backups")
    File.mkdir_p!(backup_dir)

    Process.send_after(self(), :daily_backup, @daily_interval_ms)
    Process.send_after(self(), :scheduled_compaction, @compaction_interval_ms)

    Logger.info("DetsBackup: started, backup_dir=#{backup_dir}, daily interval=24h, compaction interval=#{div(@compaction_interval_ms, 3_600_000)}h")

    {:ok, %{
      backup_dir: backup_dir,
      last_backup_at: nil,
      last_backup_results: nil,
      compaction_history: [],
      last_compaction_at: nil
    }}
  end

  @impl true
  def handle_call(:backup_all, _from, state) do
    {results, updated_state} = do_backup_all(state)
    {:reply, {:ok, results}, updated_state}
  end

  @impl true
  def handle_call(:health_metrics, _from, state) do
    table_metrics = Enum.map(@tables, &table_metrics/1)

    metrics = %{
      tables: table_metrics,
      last_backup_at: state.last_backup_at,
      last_backup_results: normalize_backup_results(state.last_backup_results),
      last_compaction_at: state.last_compaction_at,
      compaction_history: state.compaction_history
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:compact_all, _from, state) do
    results = do_compact_all()
    now = System.system_time(:millisecond)

    Phoenix.PubSub.broadcast(AgentCom.PubSub, "backups", {:compaction_complete, %{
      timestamp: now,
      results: results
    }})

    entry = %{timestamp: now, results: results}
    history = [entry | state.compaction_history] |> Enum.take(20)

    updated_state = %{state | compaction_history: history, last_compaction_at: now}
    {:reply, {:ok, results}, updated_state}
  end

  @impl true
  def handle_call(:compaction_history, _from, state) do
    {:reply, state.compaction_history, state}
  end

  @impl true
  def handle_info(:daily_backup, state) do
    {_results, updated_state} = do_backup_all(state)
    Process.send_after(self(), :daily_backup, @daily_interval_ms)
    {:noreply, updated_state}
  end

  @impl true
  def handle_info(:scheduled_compaction, state) do
    results = do_compact_all()
    now = System.system_time(:millisecond)

    # Broadcast compaction_complete for dashboard history
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "backups", {:compaction_complete, %{
      timestamp: now,
      results: results
    }})

    # Additionally broadcast failures for push notifications
    failures = Enum.filter(results, fn r -> r.status == :error end)
    if length(failures) > 0 do
      Phoenix.PubSub.broadcast(AgentCom.PubSub, "backups", {:compaction_failed, %{
        timestamp: now,
        failures: failures
      }})
    end

    entry = %{timestamp: now, results: results}
    history = [entry | state.compaction_history] |> Enum.take(20)

    Process.send_after(self(), :scheduled_compaction, @compaction_interval_ms)
    {:noreply, %{state | compaction_history: history, last_compaction_at: now}}
  end

  # --- Compaction Private Functions ---

  defp table_owner(:agent_mailbox), do: AgentCom.Mailbox
  defp table_owner(:message_history), do: AgentCom.MessageHistory
  defp table_owner(:agent_channels), do: AgentCom.Channels
  defp table_owner(:channel_history), do: AgentCom.Channels
  defp table_owner(:agentcom_config), do: AgentCom.Config
  defp table_owner(:thread_messages), do: AgentCom.Threads
  defp table_owner(:thread_replies), do: AgentCom.Threads
  defp table_owner(:task_queue), do: AgentCom.TaskQueue
  defp table_owner(:task_dead_letter), do: AgentCom.TaskQueue

  defp compact_table(table_atom) do
    owner = table_owner(table_atom)
    start_time = System.system_time(:millisecond)

    # Check fragmentation threshold first
    metrics = table_metrics(table_atom)
    if metrics.status == :ok and metrics.fragmentation_ratio < @compaction_threshold do
      {:skipped, :below_threshold, 0}
    else
      # For single-table GenServers, send :compact
      # For multi-table GenServers, send {:compact, table_atom}
      msg = if owner in [AgentCom.Channels, AgentCom.TaskQueue, AgentCom.Threads] do
        {:compact, table_atom}
      else
        :compact
      end

      result = try do
        GenServer.call(owner, msg, 30_000)
      catch
        :exit, reason -> {:error, reason}
      end

      duration_ms = System.system_time(:millisecond) - start_time

      case result do
        :ok -> {:compacted, duration_ms}
        {:error, reason} -> {:error, reason, duration_ms}
      end
    end
  end

  defp do_compact_all do
    Enum.map(@tables, fn table ->
      case compact_table(table) do
        {:compacted, duration} ->
          %{table: table, status: :compacted, duration_ms: duration}

        {:skipped, reason, _duration} ->
          %{table: table, status: :skipped, reason: reason}

        {:error, reason, duration} ->
          # Retry once
          Logger.warning("DetsBackup: compaction failed for #{table}: #{inspect(reason)}, retrying once")
          case compact_table(table) do
            {:compacted, retry_duration} ->
              %{table: table, status: :compacted, duration_ms: duration + retry_duration, retried: true}

            {:error, retry_reason, retry_duration} ->
              Logger.error("DetsBackup: compaction retry failed for #{table}: #{inspect(retry_reason)}")
              %{table: table, status: :error, reason: retry_reason, duration_ms: duration + retry_duration}

            {:skipped, skip_reason, _} ->
              %{table: table, status: :skipped, reason: skip_reason}
          end
      end
    end)
  end

  # --- Backup Private Functions ---

  defp do_backup_all(state) do
    timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.to_string()
      |> String.replace(":", "-")
      |> String.replace(" ", "T")
      |> String.slice(0, 19)

    File.mkdir_p!(state.backup_dir)

    results = Enum.map(@tables, fn table ->
      backup_table(table, state.backup_dir, timestamp)
    end)

    # Run retention cleanup for each table
    Enum.each(@tables, fn table ->
      cleanup_old_backups(table, state.backup_dir)
    end)

    success_tables =
      results
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, info} -> info.table end)

    success_count = length(success_tables)

    Logger.info("DetsBackup: backup complete, #{success_count}/#{length(@tables)} tables backed up")

    Phoenix.PubSub.broadcast(AgentCom.PubSub, "backups", {:backup_complete, %{
      timestamp: System.system_time(:millisecond),
      tables_backed_up: success_tables,
      backup_dir: state.backup_dir
    }})

    now = System.system_time(:millisecond)

    updated_state = %{state |
      last_backup_at: now,
      last_backup_results: results
    }

    {results, updated_state}
  end

  defp backup_table(table_atom, backup_dir, timestamp) do
    case :dets.info(table_atom, :type) do
      :undefined ->
        {:error, %{table: table_atom, reason: :table_not_open}}

      _ ->
        source_path = :dets.info(table_atom, :filename) |> to_string()
        backup_path = Path.join(backup_dir, "#{table_atom}_#{timestamp}.dets")

        # Sync ensures in-memory buffers are flushed to disk
        case :dets.sync(table_atom) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("DetsBackup: sync failed for #{table_atom}: #{inspect(reason)}, continuing with copy")
        end

        case File.cp(source_path, backup_path) do
          :ok ->
            {:ok, %{table: table_atom, path: backup_path, size: File.stat!(backup_path).size}}

          {:error, reason} ->
            {:error, %{table: table_atom, reason: reason}}
        end
    end
  end

  defp cleanup_old_backups(table_atom, backup_dir) do
    prefix = "#{table_atom}_"

    case File.ls(backup_dir) do
      {:ok, files} ->
        matching =
          files
          |> Enum.filter(fn f -> String.starts_with?(f, prefix) and String.ends_with?(f, ".dets") end)
          |> Enum.sort()

        if length(matching) > @max_backups_per_table do
          to_delete = Enum.take(matching, length(matching) - @max_backups_per_table)

          Enum.each(to_delete, fn file ->
            path = Path.join(backup_dir, file)
            Logger.debug("DetsBackup: removing old backup #{path}")
            File.rm(path)
          end)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp normalize_backup_results(nil), do: nil

  defp normalize_backup_results(results) when is_list(results) do
    Enum.map(results, fn
      {:ok, info} ->
        %{status: "ok", table: to_string(info.table), path: info.path, size: info.size}

      {:error, info} ->
        %{status: "error", table: to_string(info.table), reason: inspect(info.reason)}
    end)
  end

  defp table_metrics(table_atom) do
    case :dets.info(table_atom, :type) do
      :undefined ->
        %{
          table: table_atom,
          status: :unavailable,
          record_count: 0,
          file_size_bytes: 0,
          fragmentation_ratio: 0.0
        }

      _ ->
        file_size = :dets.info(table_atom, :file_size)
        no_objects = :dets.info(table_atom, :no_objects)
        {_min, used, max} = :dets.info(table_atom, :no_slots)

        fragmentation =
          if max > 0 do
            Float.round(1.0 - (used / max), 3)
          else
            0.0
          end

        %{
          table: table_atom,
          status: :ok,
          record_count: no_objects,
          file_size_bytes: file_size,
          fragmentation_ratio: fragmentation
        }
    end
  end
end
