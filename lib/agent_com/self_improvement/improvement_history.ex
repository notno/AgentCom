defmodule AgentCom.SelfImprovement.ImprovementHistory do
  @moduledoc """
  DETS-backed improvement history with cooldown and oscillation detection.

  Provides anti-Sisyphus protections for the improvement scanning pipeline:

  - **File cooldowns:** Block re-scanning files improved within a configurable
    window (default 24 hours). Prevents re-scanning files with pending improvement goals.
  - **Oscillation detection:** Flag files with 3+ consecutive improvements whose
    descriptions contain inverse patterns (e.g., "add"/"remove", "extract"/"inline").
    Prevents infinite improvement loops from conflicting scanner recommendations.

  Records are stored in a DETS `:set` table keyed by `{repo_name, file_path}` tuple.
  Each record stores a list of up to 10 most recent entries with scan_type, description,
  and timestamp.

  This is a library module (not a GenServer). The DETS table is opened via `init/0`
  and persists across calls. DetsBackup handles backup/recovery.
  """

  require Logger

  @dets_table :improvement_history
  @default_cooldown_ms 24 * 60 * 60 * 1000
  @max_entries_per_file 10

  @inverse_pairs [
    {"add", "remove"},
    {"extract", "inline"},
    {"increase", "decrease"},
    {"enable", "disable"},
    {"split", "merge"},
    {"expand", "collapse"}
  ]

  @doc """
  Open the DETS file, creating the data directory if needed.

  Returns `:ok` on success or `{:error, term()}` on failure.
  """
  @spec init() :: :ok | {:error, term()}
  def init do
    dir = data_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "improvement_history.dets") |> String.to_charlist()

    case :dets.open_file(@dets_table, file: path, type: :set, auto_save: 5_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Close the DETS table.
  """
  @spec close() :: :ok | {:error, term()}
  def close do
    :dets.close(@dets_table)
  end

  @doc """
  Record an improvement for a file. Prepends a new entry, keeps last #{@max_entries_per_file},
  and syncs to disk.
  """
  @spec record_improvement(String.t(), String.t(), atom() | String.t(), String.t()) :: :ok | {:error, term()}
  def record_improvement(repo, file_path, scan_type, description) do
    key = {repo, file_path}
    now = System.system_time(:millisecond)
    entry = %{scan_type: scan_type, description: description, timestamp: now}

    existing =
      case :dets.lookup(@dets_table, key) do
        [{^key, records}] -> records
        _ -> []
      end

    updated = [entry | existing] |> Enum.take(@max_entries_per_file)
    :dets.insert(@dets_table, {key, updated})
    :dets.sync(@dets_table)
  end

  @doc """
  Returns true if the file was improved within the cooldown window.

  Cooldown is read from `AgentCom.Config.get(:improvement_cooldown_ms)` with
  a fallback to the default (#{@default_cooldown_ms}ms / 24 hours) if Config
  is not available (fail-open pattern).
  """
  @spec cooled_down?(String.t(), String.t(), non_neg_integer()) :: boolean()
  def cooled_down?(repo, file_path, cooldown_ms \\ nil) do
    cooldown = cooldown_ms || effective_cooldown_ms()
    key = {repo, file_path}
    now = System.system_time(:millisecond)

    case :dets.lookup(@dets_table, key) do
      [{^key, [latest | _]}] -> (now - latest.timestamp) < cooldown
      _ -> false
    end
  end

  @doc """
  Returns true if the file has 3+ records and consecutive descriptions
  contain inverse patterns (e.g., "add"/"remove", "extract"/"inline").
  """
  @spec oscillating?(String.t(), String.t()) :: boolean()
  def oscillating?(repo, file_path) do
    key = {repo, file_path}

    case :dets.lookup(@dets_table, key) do
      [{^key, records}] when length(records) >= 3 ->
        detect_oscillation(records)

      _ ->
        false
    end
  end

  @doc """
  Filter out findings for files that are within the cooldown window.
  """
  @spec filter_cooled_down([AgentCom.SelfImprovement.Finding.t()], String.t()) :: [AgentCom.SelfImprovement.Finding.t()]
  def filter_cooled_down(findings, repo_name) do
    Enum.reject(findings, fn finding ->
      cooled_down?(repo_name, finding.file_path)
    end)
  end

  @doc """
  Filter out findings for files that show oscillation patterns.
  """
  @spec filter_oscillating([AgentCom.SelfImprovement.Finding.t()], String.t()) :: [AgentCom.SelfImprovement.Finding.t()]
  def filter_oscillating(findings, repo_name) do
    Enum.reject(findings, fn finding ->
      oscillating?(repo_name, finding.file_path)
    end)
  end

  @doc """
  Delete all records. For testing.
  """
  @spec clear() :: :ok | {:error, term()}
  def clear do
    :dets.delete_all_objects(@dets_table)
    :dets.sync(@dets_table)
  end

  @doc """
  Dump all records. For testing and debugging.
  """
  @spec all_records() :: [{term(), [map()]}]
  def all_records do
    :dets.foldl(fn record, acc -> [record | acc] end, [], @dets_table)
  end

  # --- Private ---

  defp data_dir do
    Application.get_env(:agent_com, :improvement_history_data_dir, "priv/data/improvement_history")
  end

  defp effective_cooldown_ms do
    try do
      case AgentCom.Config.get(:improvement_cooldown_ms) do
        nil -> @default_cooldown_ms
        val when is_integer(val) -> val
        _ -> @default_cooldown_ms
      end
    catch
      :exit, _ -> @default_cooldown_ms
    end
  end

  defp detect_oscillation(records) when length(records) >= 3 do
    # Take the last 3 improvements for this file (most recent first)
    [r1, r2, r3 | _] = records

    descs =
      [r1.description, r2.description, r3.description]
      |> Enum.map(&String.downcase/1)

    # Check if any two consecutive descriptions contain terms from an inverse pair
    Enum.any?(@inverse_pairs, fn {a, b} ->
      has_term = fn desc, term -> String.contains?(desc, term) end

      (has_term.(Enum.at(descs, 0), a) and has_term.(Enum.at(descs, 1), b)) or
        (has_term.(Enum.at(descs, 0), b) and has_term.(Enum.at(descs, 1), a)) or
        (has_term.(Enum.at(descs, 1), a) and has_term.(Enum.at(descs, 2), b)) or
        (has_term.(Enum.at(descs, 1), b) and has_term.(Enum.at(descs, 2), a))
    end)
  end

  defp detect_oscillation(_), do: false
end
