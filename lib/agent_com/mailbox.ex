defmodule AgentCom.Mailbox do
  @moduledoc """
  Message queue for offline or polling agents.

  Messages are stored per-agent and retrieved via HTTP poll.
  Each message gets a monotonic sequence number for cursor-based pagination.

  Backed by DETS (disk-based ETS) for persistence across restarts.
  Stored at `priv/mailbox.dets` by default.
  """
  use GenServer

  @max_messages_per_agent 100
  @table :agent_mailbox
  @default_ttl_ms 7 * 24 * 60 * 60 * 1000  # 7 days
  @eviction_interval_ms 60 * 60 * 1000      # run eviction every hour

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    path = dets_path() |> String.to_charlist()
    File.mkdir_p!(Path.dirname(dets_path()))
    {:ok, @table} = :dets.open_file(@table, [
      file: path,
      type: :set,
      auto_save: 5_000
    ])

    # Recover sequence counter from existing data
    seq = recover_seq()

    # Schedule periodic TTL eviction
    Process.send_after(self(), :evict_expired, @eviction_interval_ms)

    {:ok, %{seq: seq}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  @doc """
  Store a message for an agent. Called by Router when the target
  agent is offline or has opted into polling mode.
  """
  def enqueue(agent_id, %AgentCom.Message{} = msg) do
    GenServer.call(__MODULE__, {:enqueue, agent_id, msg})
  end

  @doc """
  Retrieve messages for an agent since a given sequence number.
  Returns {messages, last_seq} where last_seq is the cursor for next poll.
  """
  def poll(agent_id, since_seq \\ 0) do
    GenServer.call(__MODULE__, {:poll, agent_id, since_seq})
  end

  @doc """
  Acknowledge messages up to a sequence number, removing them.
  """
  def ack(agent_id, up_to_seq) do
    GenServer.cast(__MODULE__, {:ack, agent_id, up_to_seq})
  end

  @doc """
  Get mailbox stats for an agent.
  """
  def count(agent_id) do
    GenServer.call(__MODULE__, {:count, agent_id})
  end

  # Server callbacks

  @impl true
  def handle_call({:enqueue, agent_id, msg}, _from, state) do
    seq = state.seq + 1
    entry = %{
      seq: seq,
      agent_id: agent_id,
      message: AgentCom.Message.to_json(msg),
      stored_at: System.system_time(:millisecond)
    }
    :dets.insert(@table, {{agent_id, seq}, entry})

    # Trim old messages if over limit
    trim_mailbox(agent_id)

    {:reply, {:ok, seq}, %{state | seq: seq}}
  end

  @impl true
  def handle_call({:poll, agent_id, since_seq}, _from, state) do
    messages =
      :dets.select(@table, [
        {{{agent_id, :"$1"}, :"$2"},
         [{:>, :"$1", since_seq}],
         [:"$2"]}
      ])
      |> Enum.sort_by(& &1.seq)

    last_seq = case List.last(messages) do
      nil -> since_seq
      msg -> msg.seq
    end

    {:reply, {messages, last_seq}, state}
  end

  @impl true
  def handle_call({:count, agent_id}, _from, state) do
    count =
      :dets.select(@table, [
        {{{agent_id, :_}, :_}, [], [true]}
      ])
      |> length()

    {:reply, count, state}
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

  @impl true
  def handle_cast({:ack, agent_id, up_to_seq}, state) do
    keys_to_delete =
      :dets.select(@table, [
        {{{agent_id, :"$1"}, :_},
         [{:"=<", :"$1", up_to_seq}],
         [{{agent_id, :"$1"}}]}
      ])

    Enum.each(keys_to_delete, fn key -> :dets.delete(@table, key) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:evict_expired, state) do
    do_evict_expired()
    {:noreply, state}
  end

  @doc "Manually trigger TTL-based eviction of expired messages."
  def evict_expired do
    GenServer.cast(__MODULE__, :evict_expired)
  end

  @doc "Get or set the retention TTL in milliseconds. Persisted via AgentCom.Config."
  def get_ttl do
    AgentCom.Config.get(:mailbox_ttl_ms) || @default_ttl_ms
  end

  def set_ttl(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    AgentCom.Config.put(:mailbox_ttl_ms, ttl_ms)
  end

  @impl true
  def handle_info(:evict_expired, state) do
    do_evict_expired()
    Process.send_after(self(), :evict_expired, @eviction_interval_ms)
    {:noreply, state}
  end

  defp do_evict_expired do
    ttl = get_ttl()
    cutoff = System.system_time(:millisecond) - ttl

    # Select all entries with stored_at before cutoff
    expired_keys =
      :dets.select(@table, [
        {{:"$1", %{stored_at: :"$2"}},
         [{:<, :"$2", cutoff}],
         [:"$1"]}
      ])

    Enum.each(expired_keys, fn key -> :dets.delete(@table, key) end)

    if length(expired_keys) > 0 do
      :dets.sync(@table)
    end
  end

  # Helpers

  defp dets_path do
    Application.get_env(:agent_com, :mailbox_path, "priv/mailbox.dets")
  end

  defp recover_seq do
    case :dets.select(@table, [{{:_, :"$1"}, [], [:"$1"]}]) do
      [] -> 0
      entries -> entries |> Enum.map(& &1.seq) |> Enum.max()
    end
  end

  defp trim_mailbox(agent_id) do
    keys =
      :dets.select(@table, [
        {{{agent_id, :"$1"}, :_}, [], [:"$1"]}
      ])
      |> Enum.sort()

    overflow = length(keys) - @max_messages_per_agent
    if overflow > 0 do
      keys
      |> Enum.take(overflow)
      |> Enum.each(fn seq -> :dets.delete(@table, {agent_id, seq}) end)
    end
  end
end
