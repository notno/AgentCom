defmodule AgentCom.Presence do
  @moduledoc """
  Tracks connected agents and their current status.

  Each agent has:
  - `agent_id` — unique identifier (e.g. "gcu-conditions-permitting")
  - `name` — display name
  - `status` — freeform status text (what they're working on)
  - `capabilities` — list of things they can help with
  - `connected_at` — timestamp
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @doc "Register an agent. Called when a WebSocket agent connects."
  def register(agent_id, info) do
    GenServer.call(__MODULE__, {:register, agent_id, info})
  end

  @doc "Unregister an agent. Called on disconnect."
  def unregister(agent_id) do
    GenServer.cast(__MODULE__, {:unregister, agent_id})
  end

  @doc "Update an agent's status."
  def update_status(agent_id, status) do
    GenServer.cast(__MODULE__, {:update_status, agent_id, status})
  end

  @doc "List all connected agents."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Get info for a specific agent."
  def get(agent_id) do
    GenServer.call(__MODULE__, {:get, agent_id})
  end

  # Server callbacks

  @impl true
  def handle_call({:register, agent_id, info}, _from, state) do
    entry = Map.merge(info, %{
      agent_id: agent_id,
      connected_at: System.system_time(:millisecond)
    })
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "presence", {:agent_joined, entry})
    {:reply, :ok, Map.put(state, agent_id, entry)}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state), state}
  end

  def handle_call({:get, agent_id}, _from, state) do
    {:reply, Map.get(state, agent_id), state}
  end

  @impl true
  def handle_cast({:unregister, agent_id}, state) do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "presence", {:agent_left, agent_id})
    {:noreply, Map.delete(state, agent_id)}
  end

  def handle_cast({:update_status, agent_id, status}, state) do
    case Map.get(state, agent_id) do
      nil -> {:noreply, state}
      entry ->
        updated = Map.put(entry, :status, status)
        Phoenix.PubSub.broadcast(AgentCom.PubSub, "presence", {:status_changed, updated})
        {:noreply, Map.put(state, agent_id, updated)}
    end
  end
end
