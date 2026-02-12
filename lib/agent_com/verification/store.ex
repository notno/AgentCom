defmodule AgentCom.Verification.Store do
  @moduledoc """
  GenServer managing DETS-backed persistence for verification reports.

  Reports are keyed by `{task_id, run_number}` to support multi-run history
  (Phase 22 retries). A configurable retention cap prevents unbounded DETS
  growth by pruning the oldest reports (by `started_at` timestamp) when the
  total count exceeds `@max_reports`.

  ## Public API

  - `save/2` -- persist a report, enforce retention cap
  - `get/2` -- retrieve by `{task_id, run_number}` key
  - `get_latest/2` -- latest report (highest run_number) for a task
  - `list_for_task/2` -- all reports for a task, sorted by run_number
  - `count/1` -- total number of stored reports

  ## DETS Isolation

  Accepts `dets_path` option in `start_link/1` for test isolation. In
  production, defaults to `data_dir/verification_reports.dets`.
  """

  use GenServer
  require Logger

  @max_reports 1000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Persist a verification report. Key is `{task_id, run_number}`.

  Returns `:ok`.
  """
  def save(pid, report) do
    GenServer.call(pid, {:save, report})
  end

  @doc """
  Retrieve a report by `{task_id, run_number}`.

  Returns `{:ok, report}` or `{:error, :not_found}`.
  """
  def get(pid, key) do
    GenServer.call(pid, {:get, key})
  end

  @doc """
  Get the latest report (highest run_number) for a task_id.

  Returns `{:ok, report}` or `{:error, :not_found}`.
  """
  def get_latest(pid, task_id) do
    GenServer.call(pid, {:get_latest, task_id})
  end

  @doc """
  List all reports for a task_id, ordered by run_number ascending.
  """
  def list_for_task(pid, task_id) do
    GenServer.call(pid, {:list_for_task, task_id})
  end

  @doc """
  Return total number of stored reports.
  """
  def count(pid) do
    GenServer.call(pid, :count)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Logger.metadata(module: __MODULE__)

    dets_path = Keyword.get(opts, :dets_path)
    max_reports = Keyword.get(opts, :max_reports, @max_reports)

    path =
      if dets_path do
        dets_path
      else
        Path.join(data_dir(), "verification_reports.dets")
      end

    File.mkdir_p!(Path.dirname(path))
    charlist_path = String.to_charlist(path)

    # Use a unique atom for the DETS table name to avoid conflicts in tests
    table_name = :"verification_reports_#{:erlang.unique_integer([:positive])}"

    {:ok, ^table_name} =
      :dets.open_file(table_name, file: charlist_path, type: :set, auto_save: 5_000)

    Logger.info("verification_store_started", dets_path: path)

    {:ok, %{table: table_name, max_reports: max_reports, dets_path: path}}
  end

  @impl true
  def handle_call({:save, report}, _from, state) do
    key = {report.task_id, report.run_number}
    :dets.insert(state.table, {key, report})
    :dets.sync(state.table)

    enforce_retention(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    result =
      case :dets.lookup(state.table, key) do
        [{^key, report}] -> {:ok, report}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_latest, task_id}, _from, state) do
    reports = match_task_reports(state.table, task_id)

    result =
      case reports do
        [] ->
          {:error, :not_found}

        _ ->
          latest = Enum.max_by(reports, fn r -> r.run_number end)
          {:ok, latest}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_for_task, task_id}, _from, state) do
    reports =
      match_task_reports(state.table, task_id)
      |> Enum.sort_by(fn r -> r.run_number end)

    {:reply, reports, state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    count = :dets.info(state.table, :size)
    {:reply, count, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp match_task_reports(table, task_id) do
    :dets.foldl(
      fn {{tid, _run}, report}, acc ->
        if tid == task_id, do: [report | acc], else: acc
      end,
      [],
      table
    )
  end

  defp enforce_retention(state) do
    count = :dets.info(state.table, :size)

    if count > state.max_reports do
      # Collect all records with their started_at timestamps
      all_records =
        :dets.foldl(
          fn {key, report}, acc ->
            [{key, Map.get(report, :started_at, 0)} | acc]
          end,
          [],
          state.table
        )

      # Sort by started_at ascending (oldest first)
      sorted = Enum.sort_by(all_records, fn {_key, started_at} -> started_at end)

      # Delete oldest until we are at max_reports
      to_delete = Enum.take(sorted, count - state.max_reports)

      Enum.each(to_delete, fn {key, _started_at} ->
        :dets.delete(state.table, key)
      end)

      :dets.sync(state.table)
    end
  end

  defp data_dir do
    dir =
      Application.get_env(
        :agent_com,
        :verification_store_data_dir,
        Path.join([System.get_env("HOME") || ".", ".agentcom", "data"])
      )

    File.mkdir_p!(dir)
    dir
  end
end
