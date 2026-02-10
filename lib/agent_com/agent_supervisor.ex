defmodule AgentCom.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor for per-agent AgentFSM processes.

  Each connected agent gets a dedicated AgentFSM GenServer process, started
  dynamically under this supervisor. Agent processes use `restart: :temporary`
  (set via AgentFSM.child_spec/1) so they are not restarted on crash -- the
  agent must reconnect to get a new FSM process.
  """
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start a new AgentFSM process for a connected agent."
  def start_agent(args) do
    DynamicSupervisor.start_child(__MODULE__, {AgentCom.AgentFSM, args})
  end

  @doc "Stop an AgentFSM process (e.g., on explicit disconnect)."
  def stop_agent(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
