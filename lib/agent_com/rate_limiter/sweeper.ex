defmodule AgentCom.RateLimiter.Sweeper do
  @moduledoc """
  Periodic cleanup of stale rate limit bucket entries.

  Removes ETS entries for agents that are no longer connected.
  Runs every 5 minutes. Follows the Reaper pattern.
  """
  use GenServer
  require Logger

  @sweep_interval_ms 300_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)
    schedule_sweep()
    Logger.info("started", sweep_interval_ms: @sweep_interval_ms)
    {:ok, %{sweeps: 0, last_swept: 0}}
  end

  @impl true
  def handle_info(:sweep, state) do
    swept = sweep_stale_buckets()
    schedule_sweep()
    new_state = %{state | sweeps: state.sweeps + 1, last_swept: swept}

    if swept > 0 do
      Logger.info("sweep_complete", swept: swept, total_sweeps: new_state.sweeps)
    end

    {:noreply, new_state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep_stale_buckets do
    # Get currently connected agent_ids
    connected =
      AgentCom.Presence.list()
      |> Enum.map(fn a -> a.agent_id end)
      |> MapSet.new()

    # Scan bucket table for agents not in connected set
    # Entries are either:
    #   {{agent_id, channel, tier}, tokens, last_refill, capacity, refill_rate}  -- 5-element tuple
    #   {{agent_id, :violations}, count, window_start, consecutive}              -- 4-element tuple
    :ets.foldl(
      fn
        {{agent_id, _channel, _tier} = key, _, _, _, _}, acc when is_binary(agent_id) ->
          if MapSet.member?(connected, agent_id) do
            acc
          else
            :ets.delete(:rate_limit_buckets, key)
            acc + 1
          end

        {{agent_id, :violations} = key, _, _, _}, acc when is_binary(agent_id) ->
          if MapSet.member?(connected, agent_id) do
            acc
          else
            :ets.delete(:rate_limit_buckets, key)
            acc + 1
          end

        _, acc ->
          acc
      end,
      0,
      :rate_limit_buckets
    )
  end
end
