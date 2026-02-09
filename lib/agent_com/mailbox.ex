defmodule AgentCom.Mailbox do
  @moduledoc """
  Message queue for offline or polling agents.

  Messages are stored per-agent and retrieved via HTTP poll.
  Each message gets a monotonic sequence number for cursor-based pagination.

  Messages are kept in memory (ETS) for now. Future: optional persistence.
  """
  use GenServer

  @max_messages_per_agent 100
  @table :agent_mailbox

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :ordered_set, :public])
    {:ok, %{seq: 0}}
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
    :ets.insert(@table, {{agent_id, seq}, entry})

    # Trim old messages if over limit
    trim_mailbox(agent_id)

    {:reply, {:ok, seq}, %{state | seq: seq}}
  end

  def handle_call({:poll, agent_id, since_seq}, _from, state) do
    messages =
      :ets.select(@table, [
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

  def handle_call({:count, agent_id}, _from, state) do
    count = :ets.select_count(@table, [
      {{{agent_id, :_}, :_}, [], [true]}
    ])
    {:reply, count, state}
  end

  @impl true
  def handle_cast({:ack, agent_id, up_to_seq}, state) do
    :ets.select_delete(@table, [
      {{{agent_id, :"$1"}, :_},
       [{:"=<", :"$1", up_to_seq}],
       [true]}
    ])
    {:noreply, state}
  end

  defp trim_mailbox(agent_id) do
    keys = :ets.select(@table, [
      {{{agent_id, :"$1"}, :_}, [], [:"$1"]}
    ]) |> Enum.sort()

    overflow = length(keys) - @max_messages_per_agent
    if overflow > 0 do
      keys
      |> Enum.take(overflow)
      |> Enum.each(fn seq -> :ets.delete(@table, {agent_id, seq}) end)
    end
  end
end
