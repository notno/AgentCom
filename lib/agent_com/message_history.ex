defmodule AgentCom.MessageHistory do
  @moduledoc """
  Global message history for all routed messages.

  Stores every message that passes through the Router, queryable by
  sender, recipient, channel, and time range with cursor pagination.

  Backed by DETS for persistence across restarts.
  """
  use GenServer
  require Logger

  @table :message_history
  @max_messages 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    path = dets_path() |> String.to_charlist()
    File.mkdir_p!(Path.dirname(dets_path()))

    {:ok, @table} = :dets.open_file(@table, file: path, type: :set, auto_save: 5_000)

    seq = recover_seq()
    {:ok, %{seq: seq}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  # --- Public API ---

  @doc "Store a message in history. Called by Router after routing."
  def store(%AgentCom.Message{} = msg) do
    GenServer.call(__MODULE__, {:store, msg})
  end

  @doc """
  Query message history with filters and cursor pagination.

  Options:
  - `:from` — filter by sender agent_id
  - `:to` — filter by recipient agent_id
  - `:channel` — filter by channel name (from payload)
  - `:start_time` — minimum timestamp (unix ms, inclusive)
  - `:end_time` — maximum timestamp (unix ms, inclusive)
  - `:cursor` — seq to start after (exclusive)
  - `:limit` — max results (default 50)
  """
  def query(opts \\ []) do
    GenServer.call(__MODULE__, {:query, opts})
  end

  # --- Server Callbacks ---

  @impl true
  def handle_call({:store, msg}, _from, state) do
    seq = state.seq + 1

    entry = %{
      seq: seq,
      message: AgentCom.Message.to_json(msg),
      stored_at: System.system_time(:millisecond)
    }

    case :dets.insert(@table, {seq, entry}) do
      :ok ->
        trim_history()
        {:reply, {:ok, seq}, %{state | seq: seq}}

      {:error, reason} ->
        Logger.error("dets_corruption_detected", table: @table, reason: inspect(reason))
        GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @table, reason})
        {:reply, {:error, :table_corrupted}, state}
    end
  end

  @impl true
  def handle_call(:compact, _from, state) do
    path = :dets.info(@table, :filename)
    :ok = :dets.close(@table)

    case :dets.open_file(@table, file: path, type: :set, auto_save: 5_000, repair: :force) do
      {:ok, @table} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:query, opts}, _from, state) do
    from_filter = Keyword.get(opts, :from)
    to_filter = Keyword.get(opts, :to)
    channel_filter = Keyword.get(opts, :channel)
    start_time = Keyword.get(opts, :start_time, 0)
    end_time = Keyword.get(opts, :end_time, :infinity)
    cursor = Keyword.get(opts, :cursor, 0)
    limit = Keyword.get(opts, :limit, 50) |> min(200)

    # Select all entries after cursor
    entries =
      :dets.select(@table, [
        {{:"$1", :"$2"}, [{:>, :"$1", cursor}], [:"$2"]}
      ])
      |> Enum.sort_by(& &1.seq)
      |> Enum.filter(fn entry ->
        msg = entry.message
        ts = msg["timestamp"] || entry.stored_at

        (from_filter == nil or msg["from"] == from_filter) and
        (to_filter == nil or msg["to"] == to_filter) and
        (channel_filter == nil or get_in(msg, ["payload", "channel"]) == channel_filter) and
        ts >= start_time and
        (end_time == :infinity or ts <= end_time)
      end)
      |> Enum.take(limit)

    next_cursor = case List.last(entries) do
      nil -> cursor
      e -> e.seq
    end

    messages = Enum.map(entries, fn e ->
      Map.put(e.message, "seq", e.seq)
    end)

    {:reply, %{messages: messages, cursor: next_cursor, count: length(messages)}, state}
  end

  # --- Helpers ---

  defp recover_seq do
    case :dets.select(@table, [{{:"$1", :_}, [], [:"$1"]}]) do
      [] -> 0
      seqs -> Enum.max(seqs)
    end
  end

  defp trim_history do
    keys = :dets.select(@table, [{{:"$1", :_}, [], [:"$1"]}]) |> Enum.sort()
    overflow = length(keys) - @max_messages
    if overflow > 0 do
      keys
      |> Enum.take(overflow)
      |> Enum.each(fn seq -> :dets.delete(@table, seq) end)
    end
  end

  defp dets_path do
    Application.get_env(:agent_com, :message_history_path, "priv/message_history.dets")
  end
end
