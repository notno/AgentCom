defmodule AgentCom.Analytics do
  @moduledoc """
  Tracks agent activity metrics for the analytics dashboard.

  Collects:
  - Messages sent/received per agent (hourly buckets)
  - Connection time per agent
  - Last seen timestamps
  - Active vs idle classification

  Backed by ETS for fast reads (no persistence needed — metrics reset on restart).
  Historical data is approximated from presence and message flow.
  """
  use GenServer

  @table :agent_analytics
  @bucket_duration_ms 3_600_000  # 1 hour in ms

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  # --- Public API ---

  @doc "Record a message sent by an agent."
  def record_message(from, to, type \\ "chat") do
    bucket = current_bucket()
    # Increment sent count for sender
    increment(from, {:sent, bucket})
    # Increment received count for recipient (if not broadcast)
    if to && to != "broadcast" do
      increment(to, {:received, bucket})
    end
    # Update last active
    :ets.insert(@table, {{from, :last_active}, System.system_time(:millisecond)})
  end

  @doc "Record an agent connection."
  def record_connect(agent_id) do
    now = System.system_time(:millisecond)
    :ets.insert(@table, {{agent_id, :connected_at}, now})
    :ets.insert(@table, {{agent_id, :last_active}, now})
    increment(agent_id, :total_connections)
  end

  @doc "Record an agent disconnection."
  def record_disconnect(agent_id) do
    now = System.system_time(:millisecond)
    case :ets.lookup(@table, {agent_id, :connected_at}) do
      [{{_, :connected_at}, connected_at}] ->
        duration = now - connected_at
        increment(agent_id, {:connection_time_ms, current_bucket()}, duration)
        :ets.delete(@table, {agent_id, :connected_at})
      _ -> :ok
    end
    :ets.insert(@table, {{agent_id, :last_seen}, now})
  end

  @doc "Get stats for all known agents."
  def stats do
    agents = known_agents()
    now = System.system_time(:millisecond)
    bucket = current_bucket()
    # Last 24 hours = 24 buckets
    buckets = for i <- 0..23, do: bucket - i * @bucket_duration_ms

    Enum.map(agents, fn agent_id ->
      sent_total = Enum.sum(for b <- buckets, do: get_count(agent_id, {:sent, b}))
      received_total = Enum.sum(for b <- buckets, do: get_count(agent_id, {:received, b}))
      sent_current_hour = get_count(agent_id, {:sent, bucket})
      connection_time = Enum.sum(for b <- buckets, do: get_count(agent_id, {:connection_time_ms, b}))

      last_active = case :ets.lookup(@table, {agent_id, :last_active}) do
        [{{_, :last_active}, ts}] -> ts
        _ -> nil
      end

      last_seen = case :ets.lookup(@table, {agent_id, :last_seen}) do
        [{{_, :last_seen}, ts}] -> ts
        _ -> nil
      end

      connected_at = case :ets.lookup(@table, {agent_id, :connected_at}) do
        [{{_, :connected_at}, ts}] -> ts
        _ -> nil
      end

      is_connected = connected_at != nil
      idle_ms = if last_active, do: now - last_active, else: nil

      %{
        agent_id: agent_id,
        connected: is_connected,
        idle_ms: idle_ms,
        status: classify_status(is_connected, idle_ms),
        messages_sent_24h: sent_total,
        messages_received_24h: received_total,
        messages_sent_this_hour: sent_current_hour,
        connection_time_24h_ms: connection_time,
        last_active: last_active,
        last_seen: last_seen,
        total_connections: get_count(agent_id, :total_connections)
      }
    end)
    |> Enum.sort_by(& &1.agent_id)
  end

  @doc "Get hourly message breakdown for an agent (last 24h)."
  def hourly(agent_id) do
    bucket = current_bucket()
    for i <- 23..0 do
      b = bucket - i * @bucket_duration_ms
      %{
        bucket: b,
        hour: DateTime.from_unix!(div(b, 1000)) |> Calendar.strftime("%H:%M"),
        sent: get_count(agent_id, {:sent, b}),
        received: get_count(agent_id, {:received, b})
      }
    end
  end

  @doc "Summary stats for the hub."
  def summary do
    agent_stats = stats()
    now = System.system_time(:millisecond)
    %{
      total_agents: length(agent_stats),
      agents_connected: Enum.count(agent_stats, & &1.connected),
      agents_active: Enum.count(agent_stats, &(&1.status == "active")),
      agents_idle: Enum.count(agent_stats, &(&1.status == "idle")),
      agents_offline: Enum.count(agent_stats, &(&1.status == "offline")),
      total_messages_24h: Enum.sum(Enum.map(agent_stats, & &1.messages_sent_24h)),
      timestamp: now
    }
  end

  # --- Helpers ---

  defp current_bucket do
    now = System.system_time(:millisecond)
    div(now, @bucket_duration_ms) * @bucket_duration_ms
  end

  defp increment(agent_id, key, amount \\ 1) do
    try do
      :ets.update_counter(@table, {agent_id, key}, {2, amount})
    rescue
      ArgumentError ->
        :ets.insert(@table, {{agent_id, key}, amount})
    end
    # Track known agents
    :ets.insert(@table, {{agent_id, :known}, true})
  end

  defp get_count(agent_id, key) do
    case :ets.lookup(@table, {agent_id, key}) do
      [{{_, _}, count}] when is_integer(count) -> count
      _ -> 0
    end
  end

  defp known_agents do
    :ets.match(@table, {{:"$1", :known}, true})
    |> List.flatten()
    |> Enum.uniq()
  end

  defp classify_status(true, idle_ms) when is_integer(idle_ms) and idle_ms < 300_000, do: "active"
  defp classify_status(true, _), do: "idle"
  defp classify_status(false, _), do: "offline"
end
