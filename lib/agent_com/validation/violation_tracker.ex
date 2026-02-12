defmodule AgentCom.Validation.ViolationTracker do
  @moduledoc """
  Per-agent validation violation tracking with escalating disconnect and backoff.

  This is NOT a GenServer -- it provides pure functions for per-connection tracking
  (called from Socket process state) and ETS-backed functions for cross-connection
  backoff persistence.

  ## Per-connection tracking

  The Socket process state holds `violation_count` and `violation_window_start`.
  `track_violation/1` updates these fields using a 1-minute sliding window.
  `should_disconnect?/1` checks if the count has reached the threshold (10).

  ## Cross-connection backoff (ETS-backed)

  The `:validation_backoff` ETS table (created in Application.start/2) persists
  disconnect counts across WebSocket reconnections. Each entry is:
  `{agent_id, disconnect_count, last_disconnect_at}`.

  Backoff durations (LOCKED user decision):
  - 1st disconnect: 30 seconds
  - 2nd disconnect: 60 seconds
  - 3rd+ disconnect: 300 seconds (5 minutes)
  """

  @violation_threshold 10
  @violation_window_ms 60_000

  # Backoff durations in milliseconds
  @backoff_30s 30_000
  @backoff_60s 60_000
  @backoff_5m 300_000

  # --- Per-connection tracking (pure functions, called from Socket) ---

  @doc """
  Track a validation violation in the Socket process state.

  Takes a map with `violation_count` and `violation_window_start` fields.
  Returns the updated map with new count and window_start.

  Uses a 1-minute sliding window: if the window has expired, resets to count 1.
  """
  @spec track_violation(map()) :: map()
  def track_violation(state) do
    now = System.system_time(:millisecond)
    window_start = Map.get(state, :violation_window_start)

    if is_nil(window_start) or now - window_start > @violation_window_ms do
      # Reset window
      state
      |> Map.put(:violation_count, 1)
      |> Map.put(:violation_window_start, now)
    else
      # Increment count within window
      count = Map.get(state, :violation_count, 0) + 1

      state
      |> Map.put(:violation_count, count)
    end
  end

  @doc """
  Check if the agent should be disconnected for too many violations.

  Returns true if `violation_count >= 10`, false otherwise.
  """
  @spec should_disconnect?(map()) :: boolean()
  def should_disconnect?(state) do
    Map.get(state, :violation_count, 0) >= @violation_threshold
  end

  # --- Cross-connection backoff (ETS-backed) ---

  @doc """
  Record a disconnect for an agent in the backoff ETS table.

  Increments the disconnect count and updates the timestamp.
  If no entry exists, creates one with count 1.
  """
  @spec record_disconnect(String.t()) :: :ok
  def record_disconnect(agent_id) do
    now = System.system_time(:millisecond)

    case :ets.lookup(:validation_backoff, agent_id) do
      [{^agent_id, count, _last_at}] ->
        :ets.insert(:validation_backoff, {agent_id, count + 1, now})

      [] ->
        :ets.insert(:validation_backoff, {agent_id, 1, now})
    end

    :ok
  end

  @doc """
  Check if an agent is in a cooldown period.

  Returns `:ok` if no cooldown active, or `{:cooldown, remaining_seconds}` if
  the agent must wait before reconnecting.
  """
  @spec check_backoff(String.t()) :: :ok | {:cooldown, non_neg_integer()}
  def check_backoff(agent_id) do
    case :ets.lookup(:validation_backoff, agent_id) do
      [{^agent_id, count, last_disconnect_at}] ->
        cooldown_ms = backoff_duration(count)
        elapsed = System.system_time(:millisecond) - last_disconnect_at

        if elapsed < cooldown_ms do
          remaining_s = div(cooldown_ms - elapsed, 1000) + 1
          {:cooldown, remaining_s}
        else
          :ok
        end

      [] ->
        :ok
    end
  end

  @doc """
  Get the remaining cooldown in seconds for an agent.

  Returns 0 if no cooldown active.
  """
  @spec backoff_remaining(String.t()) :: non_neg_integer()
  def backoff_remaining(agent_id) do
    case check_backoff(agent_id) do
      :ok -> 0
      {:cooldown, seconds} -> seconds
    end
  end

  @doc """
  Clear backoff state for an agent. For admin use and testing.
  """
  @spec clear_backoff(String.t()) :: :ok
  def clear_backoff(agent_id) do
    :ets.delete(:validation_backoff, agent_id)
    :ok
  end

  @doc """
  Remove expired entries from the backoff ETS table.

  Entries older than `max_age_ms` (default 10 minutes) are removed.
  Can be called periodically by the Reaper or a timer.
  """
  @spec sweep_expired(non_neg_integer()) :: non_neg_integer()
  def sweep_expired(max_age_ms \\ 600_000) do
    now = System.system_time(:millisecond)
    cutoff = now - max_age_ms

    # Fold over ETS, delete old entries, count deletions
    :ets.foldl(
      fn {agent_id, _count, last_at}, acc ->
        if last_at < cutoff do
          :ets.delete(:validation_backoff, agent_id)
          acc + 1
        else
          acc
        end
      end,
      0,
      :validation_backoff
    )
  end

  # --- Private helpers ---

  defp backoff_duration(1), do: @backoff_30s
  defp backoff_duration(2), do: @backoff_60s
  defp backoff_duration(n) when n >= 3, do: @backoff_5m
  defp backoff_duration(_), do: 0
end
