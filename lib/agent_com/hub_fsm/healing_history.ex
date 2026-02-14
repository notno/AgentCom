defmodule AgentCom.HubFSM.HealingHistory do
  @moduledoc """
  ETS-backed audit log for healing actions.

  Records every remediation action with timestamp, category, severity,
  action taken, and outcome. Capped at 500 entries.

  Follows the same pattern as `HubFSM.History` -- ETS-backed, public,
  ordered_set with negated timestamps for newest-first ordering.
  """

  @table :hub_healing_history
  @max_entries 500

  @doc """
  Initialize the ETS healing history table.

  Creates a public ordered_set with read_concurrency enabled.
  Safe to call multiple times -- skips creation if the table already exists.
  """
  @spec init_table() :: :ok
  def init_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :ordered_set,
          {:read_concurrency, true}
        ])

        :ok

      _ref ->
        :ok
    end
  end

  @doc """
  Record a healing action in the audit log.

  ## Parameters

  - `category` -- issue category atom (e.g., :stuck_tasks, :watchdog_timeout)
  - `action` -- map describing the action taken
  - `outcome` -- map describing the result
  """
  @spec record(atom(), map(), map()) :: :ok
  def record(category, action, outcome) do
    timestamp = System.system_time(:millisecond)

    entry = %{
      category: category,
      action: action,
      outcome: outcome,
      timestamp: timestamp
    }

    :ets.insert(@table, {{-timestamp, :erlang.unique_integer()}, entry})
    trim()
    :ok
  end

  @doc """
  List healing history entries, newest first.

  ## Options

  - `:limit` -- maximum entries to return (default 50)
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    case :ets.whereis(@table) do
      :undefined ->
        []

      _ref ->
        @table
        |> :ets.tab2list()
        |> Enum.sort()
        |> Enum.take(limit)
        |> Enum.map(fn {_key, entry} -> entry end)
    end
  end

  @doc """
  Delete all history entries. Used for testing.
  """
  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ref ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp trim do
    size = :ets.info(@table, :size)

    if size > @max_entries do
      to_delete = size - @max_entries

      @table
      |> :ets.tab2list()
      |> Enum.sort()
      |> Enum.reverse()
      |> Enum.take(to_delete)
      |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)
    end
  end
end
