defmodule AgentCom.HubFSM.History do
  @moduledoc """
  ETS-backed transition history for the HubFSM.

  Records every state transition with timestamp, reason, and transition number.
  Provides fast reads for dashboard queries without requiring a GenServer.call
  through the HubFSM process.

  The ETS table uses an ordered_set with negated timestamps as keys so that
  newest entries sort first naturally. History is capped at 200 entries.
  """

  @table :hub_fsm_history
  @max_entries 200

  @doc """
  Initialize the ETS history table.

  Creates a public ordered_set with read_concurrency enabled.
  Safe to call multiple times -- skips creation if the table already exists.

  Returns `:ok`.
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
  Record a state transition in history.

  ## Parameters

  - `from_state` -- previous FSM state (atom or nil for initial)
  - `to_state` -- new FSM state atom
  - `reason` -- human-readable reason string
  - `transition_number` -- monotonic integer counter from the GenServer

  Automatically trims history to #{@max_entries} entries after insert.
  """
  @spec record(atom() | nil, atom(), String.t(), non_neg_integer()) :: :ok
  def record(from_state, to_state, reason, transition_number) do
    timestamp = System.system_time(:millisecond)

    entry = %{
      from: from_state,
      to: to_state,
      reason: reason,
      timestamp: timestamp,
      transition_number: transition_number
    }

    :ets.insert(@table, {{-timestamp, transition_number}, entry})
    trim()
    :ok
  end

  @doc """
  List transition history entries, newest first.

  ## Options

  - `:limit` -- maximum number of entries to return (default 50)

  Returns a list of history entry maps.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    @table
    |> :ets.tab2list()
    |> Enum.sort()
    |> Enum.take(limit)
    |> Enum.map(fn {_key, entry} -> entry end)
  end

  @doc """
  Return the most recent `to` state from history, or nil if empty.

  Reads directly from ETS for fast dashboard access without GenServer.call.
  """
  @spec current_state() :: atom() | nil
  def current_state do
    case :ets.first(@table) do
      :"$end_of_table" ->
        nil

      key ->
        case :ets.lookup(@table, key) do
          [{_key, entry}] -> entry.to
          [] -> nil
        end
    end
  end

  @doc """
  Delete all history entries. Used for testing.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp trim do
    size = :ets.info(@table, :size)

    if size > @max_entries do
      # Keys are {-timestamp, transition_number}, ordered_set sorts ascending.
      # Largest keys (most positive = oldest timestamps due to negation) are last.
      # Delete from the end (oldest entries).
      to_delete = size - @max_entries

      @table
      |> :ets.tab2list()
      |> Enum.sort()
      |> Enum.reverse()
      |> Enum.take(to_delete)
      |> Enum.each(fn {key, _entry} -> :ets.delete(@table, key) end)
    end
  end
end
