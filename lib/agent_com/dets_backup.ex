defmodule AgentCom.DetsBackup do
  @moduledoc """
  GenServer for automated DETS table backups, retention cleanup, health metrics,
  and compaction orchestration.

  Handles:
  - Daily automatic backup of all 13 DETS tables via Process.send_after timer
  - Manual backup trigger via backup_all/0 (synchronous, returns results)
  - Retention cleanup: keeps only last 3 backups per table
  - Health metrics: record count, file size, fragmentation ratio per table
  - PubSub broadcast on "backups" topic after each backup run
  - Scheduled compaction of all 13 DETS tables every 6 hours (configurable)
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
    :thread_replies,
    :repo_registry,
    :cost_ledger,
    :goal_backlog,
    :improvement_history
  ]

  # Library-owned tables (not GenServers) -- compaction uses :dets.sync directly
  @library_tables [:improvement_history]

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
  Return health metrics for all 13 DETS tables.

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

  @doc "Compact a single DETS table. Returns {:ok, result} or {:error, reason}."
  def compact_one(table_atom) when table_atom in @tables do
    GenServer.call(__MODULE__, {:compact_one, table_atom}, 60_000)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    backup_dir = Application.get_env(:agent_com, :backup_dir, "priv/backups")
    File.mkdir_p!(backup_dir)

    Process.send_after(self(), :daily_backup, @daily_interval_ms)
    Process.send_after(self(), :scheduled_compaction, @compaction_interval_ms)

    Logger.info("dets_backup_started",
      backup_dir: backup_dir,
      compaction_interval_hours: div(@compaction_interval_ms, 3_600_000)
    )

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
      compaction_history: normalize_compaction_history(state.compaction_history)
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
    {:reply, normalize_compaction_history(state.compaction_history), state}
  end

  @impl true
  def handle_call({:compact_one, table_atom}, _from, state) do
    result = compact_table(table_atom)
    now = System.system_time(:millisecond)

    formatted = case result do
      {:compacted, duration} ->
        %{table: table_atom, status: :compacted, duration_ms: duration}

      {:skipped, reason, _} ->
        %{table: table_atom, status: :skipped, reason: reason}

      {:error, _reason, duration} ->
        # Retry once
        case compact_table(table_atom) do
          {:compacted, retry_duration} ->
            %{table: table_atom, status: :compacted, duration_ms: duration + retry_duration, retried: true}

          {:error, retry_reason, retry_duration} ->
            %{table: table_atom, status: :error, reason: retry_reason, duration_ms: duration + retry_duration}

          {:skipped, skip_reason, _} ->
            %{table: table_atom, status: :skipped, reason: skip_reason}
        end
    end

    # Record in compaction history
    entry = %{timestamp: now, results: [formatted]}
    history = [entry | state.compaction_history] |> Enum.take(20)

    {:reply, {:ok, formatted}, %{state | compaction_history: history, last_compaction_at: now}}
  end

  @impl true
  def handle_call({:restore_table, table_atom}, _from, state) do
    result = do_restore_table(table_atom, state.backup_dir)
    now = System.system_time(:millisecond)

    case result do
      {:ok, info} ->
        Phoenix.PubSub.broadcast(AgentCom.PubSub, "backups", {:recovery_complete, %{
          timestamp: now,
          table: table_atom,
          backup_used: info[:backup_used],
          record_count: get_in(info, [:integrity, :record_count]) || 0,
          trigger: :manual
        }})
        {:reply, {:ok, info}, state}

      {:error, reason} ->
        Phoenix.PubSub.broadcast(AgentCom.PubSub, "backups", {:recovery_failed, %{
          timestamp: now,
          table: table_atom,
          reason: reason,
          trigger: :manual
        }})
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:corruption_detected, table_atom, reason}, state) do
    Logger.error("dets_corruption_detected",
      table: table_atom,
      reason: inspect(reason),
      action: :auto_restore
    )
    now = System.system_time(:millisecond)

    result = do_restore_table(table_atom, state.backup_dir)

    case result do
      {:ok, info} ->
        Logger.warning("dets_auto_restore_complete",
          table: table_atom,
          backup_used: info[:backup_used]
        )
        Phoenix.PubSub.broadcast(AgentCom.PubSub, "backups", {:recovery_complete, %{
          timestamp: now,
          table: table_atom,
          backup_used: info[:backup_used],
          record_count: get_in(info, [:integrity, :record_count]) || 0,
          trigger: :auto
        }})

      {:error, err} ->
        Logger.critical("dets_auto_restore_failed",
          table: table_atom,
          error: inspect(err)
        )
        Phoenix.PubSub.broadcast(AgentCom.PubSub, "backups", {:recovery_failed, %{
          timestamp: now,
          table: table_atom,
          reason: err,
          trigger: :auto
        }})
    end

    {:noreply, state}
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

  @doc """
  Restore a specific table from its latest backup.
  Per locked decision: operators can force-restore a table at any time.
  Returns {:ok, restore_info} or {:error, reason}.
  """
  def restore_table(table_atom) when table_atom in @tables do
    GenServer.call(__MODULE__, {:restore_table, table_atom}, 60_000)
  end

  @doc "Find the most recent backup file for a table."
  def find_latest_backup(table_atom, backup_dir) do
    prefix = "#{table_atom}_"

    case File.ls(backup_dir) do
      {:ok, files} ->
        case files
             |> Enum.filter(fn f -> String.starts_with?(f, prefix) and String.ends_with?(f, ".dets") end)
             |> Enum.sort()
             |> List.last() do
          nil -> {:error, :no_backup_found}
          filename -> {:ok, Path.join(backup_dir, filename)}
        end

      {:error, reason} ->
        {:error, {:backup_dir_unreadable, reason}}
    end
  end

  # --- Compaction Private Functions ---

  defp table_owner(:agent_mailbox), do: AgentCom.Mailbox
  defp table_owner(:message_history), do: AgentCom.MessageHistory
  defp table_owner(:agent_channels), do: AgentCom.Channels
  defp table_owner(:channel_history), do: AgentCom.Channels
  defp table_owner(:agentcom_config), do: AgentCom.Config
  defp table_owner(:thread_messages), do: AgentCom.Threads
  defp table_owner(:thread_replies), do: AgentCom.Threads
  defp table_owner(:repo_registry), do: AgentCom.RepoRegistry
  defp table_owner(:cost_ledger), do: AgentCom.CostLedger
  defp table_owner(:goal_backlog), do: AgentCom.GoalBacklog
  defp table_owner(:task_queue), do: AgentCom.TaskQueue
  defp table_owner(:task_dead_letter), do: AgentCom.TaskQueue
  defp table_owner(:improvement_history), do: AgentCom.SelfImprovement.ImprovementHistory

  defp compact_table(table_atom) do
    start_time = System.system_time(:millisecond)

    # Check fragmentation threshold first
    metrics = table_metrics(table_atom)
    if metrics.status == :ok and metrics.fragmentation_ratio < @compaction_threshold do
      {:skipped, :below_threshold, 0}
    else
      if table_atom in @library_tables do
        # Library-owned tables: sync directly, no GenServer compaction needed
        result = try do
          :dets.sync(table_atom)
        catch
          :exit, reason -> {:error, reason}
        end

        duration_ms = System.system_time(:millisecond) - start_time

        case result do
          :ok -> {:compacted, duration_ms}
          {:error, reason} -> {:error, reason, duration_ms}
        end
      else
        owner = table_owner(table_atom)

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
  end

  defp do_compact_all do
    Enum.map(@tables, fn table ->
      result = :telemetry.span(
        [:agent_com, :dets, :compaction],
        %{table: table},
        fn ->
          case compact_table(table) do
            {:compacted, duration} ->
              formatted = %{table: table, status: :compacted, duration_ms: duration}
              {formatted, %{table: table, status: :compacted}}

            {:skipped, reason, _duration} ->
              formatted = %{table: table, status: :skipped, reason: reason}
              {formatted, %{table: table, status: :skipped}}

            {:error, reason, duration} ->
              # Retry once
              Logger.warning("dets_compaction_failed",
                table: table,
                reason: inspect(reason),
                action: :retry
              )
              case compact_table(table) do
                {:compacted, retry_duration} ->
                  formatted = %{table: table, status: :compacted, duration_ms: duration + retry_duration, retried: true}
                  {formatted, %{table: table, status: :compacted, retried: true}}

                {:error, retry_reason, retry_duration} ->
                  Logger.error("dets_compaction_retry_failed",
                    table: table,
                    reason: inspect(retry_reason)
                  )
                  formatted = %{table: table, status: :error, reason: retry_reason, duration_ms: duration + retry_duration}
                  {formatted, %{table: table, status: :error}}

                {:skipped, skip_reason, _} ->
                  formatted = %{table: table, status: :skipped, reason: skip_reason}
                  {formatted, %{table: table, status: :skipped}}
              end
          end
        end
      )

      result
    end)
  end

  # --- Recovery Private Functions ---

  defp get_table_path(table_atom) do
    case table_atom do
      :repo_registry ->
        dir = Application.get_env(:agent_com, :repo_registry_data_dir,
          Path.join([System.get_env("HOME") || ".", ".agentcom", "data"]))
        Path.join(dir, "repo_registry.dets")

      :agent_mailbox ->
        Application.get_env(:agent_com, :mailbox_path, "priv/mailbox.dets")

      :message_history ->
        Application.get_env(:agent_com, :message_history_path, "priv/message_history.dets")

      :agent_channels ->
        dir = Application.get_env(:agent_com, :channels_path, "priv")
        Path.join(dir, "channels.dets")

      :channel_history ->
        dir = Application.get_env(:agent_com, :channels_path, "priv")
        Path.join(dir, "channel_history.dets")

      :agentcom_config ->
        dir = Application.get_env(:agent_com, :config_data_dir,
          Path.join([System.get_env("HOME") || ".", ".agentcom", "data"]))
        Path.join(dir, "config.dets")

      :thread_messages ->
        dir = Application.get_env(:agent_com, :threads_data_dir,
          Path.join([System.get_env("HOME") || ".", ".agentcom", "data"]))
        Path.join(dir, "thread_messages.dets")

      :thread_replies ->
        dir = Application.get_env(:agent_com, :threads_data_dir,
          Path.join([System.get_env("HOME") || ".", ".agentcom", "data"]))
        Path.join(dir, "thread_replies.dets")

      :task_queue ->
        dir = Application.get_env(:agent_com, :task_queue_path, "priv")
        Path.join(dir, "task_queue.dets")

      :task_dead_letter ->
        dir = Application.get_env(:agent_com, :task_queue_path, "priv")
        Path.join(dir, "task_dead_letter.dets")

      :cost_ledger ->
        dir = Application.get_env(:agent_com, :cost_ledger_data_dir, "priv/data/cost_ledger")
        Path.join(dir, "cost_ledger.dets")

      :goal_backlog ->
        dir = Application.get_env(:agent_com, :goal_backlog_data_dir, "priv/data/goal_backlog")
        Path.join(dir, "goal_backlog.dets")

      :improvement_history ->
        dir = Application.get_env(:agent_com, :improvement_history_data_dir, "priv/data/improvement_history")
        Path.join(dir, "improvement_history.dets")
    end
  end

  defp verify_table_integrity(table_atom) do
    case :dets.info(table_atom, :type) do
      :undefined ->
        {:error, :table_not_open}

      _ ->
        record_count = :dets.info(table_atom, :no_objects)
        file_size = :dets.info(table_atom, :file_size)

        # Attempt a fold to verify data readability
        traversal_ok =
          try do
            :dets.foldl(fn _record, acc -> acc + 1 end, 0, table_atom)
            true
          catch
            _, _ -> false
          end

        if traversal_ok do
          {:ok, %{record_count: record_count, file_size: file_size}}
        else
          {:error, :data_unreadable}
        end
    end
  end

  defp do_restore_table(table_atom, backup_dir) do
    :telemetry.span(
      [:agent_com, :dets, :restore],
      %{table: table_atom, trigger: :restore},
      fn ->
        result = perform_restore(table_atom, backup_dir)
        case result do
          {:ok, info} ->
            {result, %{table: table_atom, backup_used: info[:backup_used], record_count: get_in(info, [:integrity, :record_count]) || 0}}
          {:error, _reason} ->
            {result, %{table: table_atom, status: :error}}
        end
      end
    )
  end

  defp perform_restore(table_atom, backup_dir) do
    owner = table_owner(table_atom)
    original_path = get_table_path(table_atom)

    case find_latest_backup(table_atom, backup_dir) do
      {:ok, backup_path} ->
        if table_atom in @library_tables do
          # Library-owned tables: close DETS directly, copy backup, reopen via init
          try do
            :dets.close(table_atom)
            File.cp!(backup_path, original_path)
            AgentCom.SelfImprovement.ImprovementHistory.init()

            case verify_table_integrity(table_atom) do
              {:ok, integrity_info} ->
                backup_filename = Path.basename(backup_path)
                {:ok, %{table: table_atom, backup_used: backup_filename, integrity: integrity_info}}

              {:error, reason} ->
                Logger.error("dets_integrity_failed",
                  table: table_atom,
                  reason: inspect(reason),
                  phase: :post_restore
                )
                {:error, {:integrity_failed, reason}}
            end
          rescue
            e ->
              Logger.critical("dets_restore_exception",
                table: table_atom,
                error: inspect(e)
              )
              # Try to reopen the table even if copy failed
              try do
                AgentCom.SelfImprovement.ImprovementHistory.init()
              catch
                _, _ -> :ok
              end
              {:error, {:restore_failed, e}}
          end
        else
          try do
            # Step 1: Stop owner GenServer (terminate/2 closes DETS tables)
            :ok = Supervisor.terminate_child(AgentCom.Supervisor, owner)

            # Step 2: Replace corrupted file with backup
            File.cp!(backup_path, original_path)

            # Step 3: Restart owner GenServer (init/1 opens the restored file)
            case Supervisor.restart_child(AgentCom.Supervisor, owner) do
              {:ok, _pid} ->
                # Step 4: Verify integrity (per locked decision)
                case verify_table_integrity(table_atom) do
                  {:ok, integrity_info} ->
                    backup_filename = Path.basename(backup_path)
                    {:ok, %{table: table_atom, backup_used: backup_filename, integrity: integrity_info}}

                  {:error, reason} ->
                    Logger.error("dets_integrity_failed",
                      table: table_atom,
                      reason: inspect(reason),
                      phase: :post_restore
                    )
                    {:error, {:integrity_failed, reason}}
                end

              {:error, restart_reason} ->
                Logger.critical("dets_restart_failed",
                  table: table_atom,
                  owner: inspect(owner),
                  reason: inspect(restart_reason),
                  phase: :post_restore
                )
                handle_restart_failure(table_atom, owner, original_path)
            end
          rescue
            e ->
              Logger.critical("dets_restore_exception",
                table: table_atom,
                error: inspect(e)
              )
              # Try to restart the owner even if copy failed
              try do
                Supervisor.restart_child(AgentCom.Supervisor, owner)
              catch
                _, _ -> :ok
              end
              {:error, {:restore_failed, e}}
          end
        end

      {:error, :no_backup_found} ->
        Logger.critical("dets_no_backup",
          table: table_atom,
          action: :degraded_mode
        )
        handle_no_backup(table_atom, owner, original_path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_restart_failure(table_atom, owner, original_path) do
    Logger.critical("dets_degraded_mode",
      table: table_atom,
      reason: :both_corrupted,
      data_lost: true
    )
    # Delete corrupted file, let init/1 create fresh empty table
    File.rm(original_path)

    case Supervisor.restart_child(AgentCom.Supervisor, owner) do
      {:ok, _pid} ->
        {:ok, %{table: table_atom, status: :degraded, data_lost: true}}

      {:error, reason} ->
        {:error, {:degraded_mode_failed, reason}}
    end
  end

  defp handle_no_backup(table_atom, owner, original_path) do
    # Same as restart failure -- enter degraded mode
    handle_restart_failure(table_atom, owner, original_path)
  end

  # --- Backup Private Functions ---

  defp do_backup_all(state) do
    :telemetry.span(
      [:agent_com, :dets, :backup],
      %{table_count: length(@tables)},
      fn ->
        result = perform_backup_all(state)
        {result, %{status: :ok, table_count: length(@tables)}}
      end
    )
  end

  defp perform_backup_all(state) do
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

    Logger.notice("dets_backup_complete",
      success_count: success_count,
      total_tables: length(@tables)
    )

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
            Logger.warning("dets_sync_failed",
              table: table_atom,
              reason: inspect(reason),
              action: :continue_with_copy
            )
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
            Logger.debug(fn -> "dets_cleanup_old_backup: #{path}" end)
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

  defp normalize_compaction_history(history) when is_list(history) do
    Enum.map(history, fn entry ->
      %{
        timestamp: entry.timestamp,
        results: Enum.map(entry.results, &normalize_compaction_result/1)
      }
    end)
  end

  defp normalize_compaction_history(_), do: []

  defp normalize_compaction_result(r) when is_map(r) do
    base = %{
      table: to_string(r.table),
      status: to_string(r.status)
    }

    base = if Map.has_key?(r, :duration_ms), do: Map.put(base, :duration_ms, r.duration_ms), else: base
    base = if Map.has_key?(r, :retried), do: Map.put(base, :retried, r.retried), else: base
    base = if Map.has_key?(r, :reason), do: Map.put(base, :reason, safe_to_string(r.reason)), else: base
    base
  end

  defp safe_to_string(val) when is_atom(val), do: to_string(val)
  defp safe_to_string(val) when is_binary(val), do: val
  defp safe_to_string(val), do: inspect(val)

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
