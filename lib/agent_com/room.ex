defmodule AgentCom.Room do
  @moduledoc """
  Shared chat room for agents and humans. Stores message history in-memory
  with a ring buffer. Broadcasts new messages via PubSub "room" topic.
  """
  use GenServer
  require Logger

  @name __MODULE__
  @max_messages 500

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def send_message(from, text, opts \\ []) do
    GenServer.call(@name, {:send_message, from, text, opts})
  end

  def messages(opts \\ []) do
    GenServer.call(@name, {:messages, opts})
  end

  def participants do
    GenServer.call(@name, :participants)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)
    Logger.info("Room started")

    {:ok, %{messages: [], seq: 0, participants: MapSet.new()}}
  end

  @impl true
  def handle_call({:send_message, from, text, opts}, _from_pid, state) do
    type = Keyword.get(opts, :type, "chat")
    seq = state.seq + 1

    message = %{
      seq: seq,
      from: from,
      text: text,
      type: type,
      timestamp: System.system_time(:millisecond)
    }

    messages =
      [message | state.messages]
      |> Enum.take(@max_messages)

    new_state = %{
      state
      | messages: messages,
        seq: seq,
        participants: MapSet.put(state.participants, from)
    }

    Phoenix.PubSub.broadcast(AgentCom.PubSub, "room", {:room_message, message})

    {:reply, {:ok, message}, new_state}
  end

  @impl true
  def handle_call({:messages, opts}, _from_pid, state) do
    since = Keyword.get(opts, :since, 0)
    limit = Keyword.get(opts, :limit, 50)

    filtered =
      state.messages
      |> Enum.filter(fn m -> m.seq > since end)
      |> Enum.take(limit)
      |> Enum.reverse()

    {:reply, {filtered, state.seq}, state}
  end

  @impl true
  def handle_call(:participants, _from_pid, state) do
    {:reply, MapSet.to_list(state.participants), state}
  end
end
