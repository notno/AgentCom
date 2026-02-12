defmodule AgentCom.Reaper do
  @moduledoc """
  Periodically sweeps the agent registry for stale connections.

  An agent is considered stale if no ping has been received within
  the configured TTL (default: 60 seconds). Stale agents are
  unregistered from Presence and their WebSocket process is terminated.

  Sweep interval defaults to 30 seconds.
  """
  use GenServer

  require Logger

  @default_sweep_interval_ms 30_000
  @default_ttl_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    Logger.metadata(module: __MODULE__)

    sweep_interval = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    schedule_sweep(sweep_interval)

    {:ok, %{sweep_interval: sweep_interval, ttl: ttl}}
  end

  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    cutoff = now - state.ttl

    stale_agents =
      AgentCom.Presence.list()
      |> Enum.filter(fn agent ->
        last_seen = agent[:last_seen] || agent[:connected_at] || 0
        last_seen < cutoff
      end)

    for agent <- stale_agents do
      agent_id = agent[:agent_id] || agent.agent_id
      last_seen = agent[:last_seen] || agent[:connected_at] || 0
      stale_ms = now - last_seen

      :telemetry.execute(
        [:agent_com, :agent, :evict],
        %{stale_ms: stale_ms},
        %{agent_id: agent_id}
      )

      Logger.warning("reaper_evict_stale",
        agent_id: agent_id,
        stale_ms: stale_ms,
        ttl_ms: state.ttl
      )

      # Terminate the WebSocket process if still registered
      case Registry.lookup(AgentCom.AgentRegistry, agent_id) do
        [{pid, _}] ->
          Process.exit(pid, :stale_connection)
        [] ->
          # Already gone, just clean up presence
          AgentCom.Presence.unregister(agent_id)
      end
    end

    schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
