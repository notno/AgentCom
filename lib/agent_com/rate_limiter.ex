defmodule AgentCom.RateLimiter do
  @moduledoc """
  Per-agent token bucket rate limiter backed by ETS.

  NOT a GenServer -- provides pure functions called from Socket and Plug processes.
  Follows the same architecture as AgentCom.Validation.ViolationTracker.

  ## Bucket Structure

  Each agent gets independent buckets keyed by `{agent_id, channel, tier}` where:
  - `channel` is `:ws` or `:http`
  - `tier` is `:light`, `:normal`, or `:heavy`

  Tokens are stored in internal units (real_tokens * 1000) for integer precision.
  Lazy refill: tokens are not refilled on a timer. On each check, elapsed time
  since last access is used to compute refilled tokens.

  ## ETS Tables

  - `:rate_limit_buckets` -- bucket entries and violation tracking
  - `:rate_limit_overrides` -- per-agent override limits and whitelist
  """

  alias AgentCom.RateLimiter.Config

  @bucket_table :rate_limit_buckets
  @override_table :rate_limit_overrides
  @token_cost 1000
  @warn_threshold 0.2
  @quiet_period_ms 60_000

  # Progressive backoff curve: consecutive_violations -> retry_after_ms
  @backoff_curve %{1 => 1000, 2 => 2000, 3 => 5000, 4 => 10_000}
  @backoff_max 30_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Check if an action is allowed for an agent on a channel/tier.

  Returns:
  - `{:allow, remaining}` -- action permitted, `remaining` tokens left (in real units)
  - `{:warn, remaining}` -- action permitted but 80% of capacity used
  - `{:deny, retry_after_ms}` -- action denied, retry after `retry_after_ms` milliseconds
  - `{:allow, :exempt}` -- agent is whitelisted, no rate limiting applied
  """
  @spec check(String.t(), :ws | :http, :light | :normal | :heavy) ::
          {:allow, non_neg_integer() | :exempt} | {:warn, non_neg_integer()} | {:deny, non_neg_integer()}
  def check(agent_id, channel, tier) do
    ensure_config_loaded()

    if exempt?(agent_id) do
      emit_telemetry(agent_id, channel, tier, :allow, :exempt)
      {:allow, :exempt}
    else
      do_check(agent_id, channel, tier)
    end
  end

  @doc """
  Record a rate limit violation for an agent. Increments consecutive violation
  count and returns the progressive `retry_after_ms`.

  Progressive backoff: 1st=1s, 2nd=2s, 3rd=5s, 4th=10s, 5th+=30s.
  After 60s quiet period with no violations, consecutive count resets.
  """
  @spec record_violation(String.t()) :: non_neg_integer()
  def record_violation(agent_id) do
    key = {agent_id, :violations}
    now = System.monotonic_time(:millisecond)

    {consecutive, retry_ms} =
      case :ets.lookup(@bucket_table, key) do
        [{^key, count, window_start, consecutive}] ->
          elapsed = now - window_start

          if elapsed > @quiet_period_ms do
            # Quiet period elapsed -- reset consecutive count
            new_consecutive = 1
            :ets.insert(@bucket_table, {key, 1, now, new_consecutive})
            {new_consecutive, backoff_ms(new_consecutive)}
          else
            new_count = count + 1
            new_consecutive = consecutive + 1
            :ets.insert(@bucket_table, {key, new_count, window_start, new_consecutive})
            {new_consecutive, backoff_ms(new_consecutive)}
          end

        [] ->
          :ets.insert(@bucket_table, {key, 1, now, 1})
          {1, backoff_ms(1)}
      end

    :telemetry.execute(
      [:agent_com, :rate_limit, :violation],
      %{retry_after_ms: retry_ms, consecutive: consecutive},
      %{agent_id: agent_id}
    )

    retry_ms
  end

  @doc """
  Check if an agent has active violations (consecutive_violations > 0
  and within the quiet period window).
  """
  @spec rate_limited?(String.t()) :: boolean()
  def rate_limited?(agent_id) do
    key = {agent_id, :violations}

    case :ets.lookup(@bucket_table, key) do
      [{^key, _count, window_start, consecutive}] when consecutive > 0 ->
        now = System.monotonic_time(:millisecond)
        now - window_start <= @quiet_period_ms

      _ ->
        false
    end
  end

  @doc """
  Clear all violation state for an agent. For admin use.
  """
  @spec reset_violations(String.t()) :: :ok
  def reset_violations(agent_id) do
    :ets.delete(@bucket_table, {agent_id, :violations})
    :ok
  end

  @doc """
  Check if an agent is whitelisted (exempt from rate limiting).
  """
  @spec exempt?(String.t()) :: boolean()
  def exempt?(agent_id) do
    case :ets.lookup(@override_table, :whitelist) do
      [{:whitelist, list}] -> agent_id in list
      [] -> false
    end
  end

  @doc """
  Return the capacity (in real token units) for display purposes.
  Used in warning frames to show agents their limit.
  """
  @spec capacity(String.t(), :ws | :http, :light | :normal | :heavy) :: non_neg_integer()
  def capacity(agent_id, channel, tier) do
    {cap, _rate} = get_limits(agent_id, channel, tier)
    div(cap, 1000)
  end

  @doc """
  Get the limits (capacity, refill_rate) for an agent/channel/tier combination.
  Checks for per-agent overrides first, falls back to Config defaults.
  """
  @spec get_limits(String.t(), :ws | :http, :light | :normal | :heavy) ::
          {non_neg_integer(), float()}
  def get_limits(agent_id, _channel, tier) do
    case :ets.lookup(@override_table, {agent_id, tier}) do
      [{_, cap, rate}] -> {cap, rate}
      [] -> Config.defaults(tier)
    end
  end

  @doc """
  Delete all bucket entries for an agent. Used when overrides change
  so the next request creates buckets with the new limits.
  """
  @spec delete_agent_buckets(String.t()) :: :ok
  def delete_agent_buckets(agent_id) do
    :ets.match_delete(@bucket_table, {{agent_id, :_, :_}, :_, :_, :_, :_})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Override Management
  # ---------------------------------------------------------------------------

  @doc """
  Set per-agent rate limit overrides.

  `overrides_map` is a map like `%{light: %{capacity: 200_000, refill_rate: 3.33}, ...}`
  where values are in internal units (real tokens * 1000).

  Writes to both ETS (runtime) and Config DETS (persistence). Resets the agent's
  existing buckets so new limits take effect immediately.
  """
  @spec set_override(String.t(), map()) :: :ok
  def set_override(agent_id, overrides_map) do
    # Write each tier to ETS
    Enum.each(overrides_map, fn {tier, %{capacity: cap, refill_rate: rate}} ->
      :ets.insert(@override_table, {{agent_id, tier}, cap, rate})
    end)

    # Persist: merge into the full overrides map in Config DETS
    all_overrides = get_overrides_from_dets()
    updated = Map.put(all_overrides, agent_id, overrides_map)
    AgentCom.Config.put(:rate_limit_overrides, updated)

    # Reset buckets so new limits take effect immediately
    delete_agent_buckets(agent_id)
    :ok
  end

  @doc """
  Remove per-agent override, reverting the agent to default limits.

  Removes from both ETS and Config DETS. Resets existing buckets.
  """
  @spec remove_override(String.t()) :: :ok
  def remove_override(agent_id) do
    # Delete all ETS entries for this agent's overrides
    :ets.match_delete(@override_table, {{agent_id, :_}, :_, :_})

    # Persist: remove from the full overrides map in Config DETS
    all_overrides = get_overrides_from_dets()
    updated = Map.delete(all_overrides, agent_id)
    AgentCom.Config.put(:rate_limit_overrides, updated)

    # Reset buckets
    delete_agent_buckets(agent_id)
    :ok
  end

  @doc """
  Return all current per-agent overrides as a map.

  Returns `%{agent_id => %{tier => %{capacity: cap, refill_rate: rate}}}`.
  Reads from ETS for speed; reconstructs the map from ETS entries.
  """
  @spec get_overrides() :: map()
  def get_overrides do
    ensure_config_loaded()

    # Match all {agent_id, tier} entries (skip special keys like :whitelist, :_loaded)
    :ets.foldl(
      fn
        {{agent_id, tier}, cap, rate}, acc when is_binary(agent_id) and is_atom(tier) ->
          tier_data = %{capacity: cap, refill_rate: rate}
          agent_map = Map.get(acc, agent_id, %{})
          Map.put(acc, agent_id, Map.put(agent_map, tier, tier_data))

        _other, acc ->
          acc
      end,
      %{},
      @override_table
    )
  end

  @doc """
  Return the default rate limits for display purposes.

  Returns a map with human-readable token counts (internal / 1000) and
  rates expressed as tokens per minute.
  """
  @spec get_defaults() :: map()
  def get_defaults do
    for tier <- [:light, :normal, :heavy], into: %{} do
      {cap, rate} = Config.defaults(tier)
      {tier, %{
        capacity: div(cap, 1000),
        refill_rate_per_min: Float.round(rate * 60_000 / 1000, 1)
      }}
    end
  end

  # ---------------------------------------------------------------------------
  # Whitelist Management
  # ---------------------------------------------------------------------------

  @doc """
  Return current whitelist as a list of agent_id strings.
  """
  @spec get_whitelist() :: [String.t()]
  def get_whitelist do
    ensure_config_loaded()

    case :ets.lookup(@override_table, :whitelist) do
      [{:whitelist, list}] -> list
      [] -> []
    end
  end

  @doc """
  Replace the entire whitelist with the given list of agent_id strings.

  Writes to both ETS and Config DETS.
  """
  @spec update_whitelist([String.t()]) :: :ok
  def update_whitelist(agent_ids) when is_list(agent_ids) do
    :ets.insert(@override_table, {:whitelist, agent_ids})
    AgentCom.Config.put(:rate_limit_whitelist, agent_ids)
    :ok
  end

  @doc """
  Add a single agent to the whitelist if not already present.

  Writes to both ETS and Config DETS.
  """
  @spec add_to_whitelist(String.t()) :: :ok
  def add_to_whitelist(agent_id) do
    current = get_whitelist()

    unless agent_id in current do
      updated = [agent_id | current]
      :ets.insert(@override_table, {:whitelist, updated})
      AgentCom.Config.put(:rate_limit_whitelist, updated)
    end

    :ok
  end

  @doc """
  Remove a single agent from the whitelist.

  Writes to both ETS and Config DETS.
  """
  @spec remove_from_whitelist(String.t()) :: :ok
  def remove_from_whitelist(agent_id) do
    current = get_whitelist()
    updated = List.delete(current, agent_id)
    :ets.insert(@override_table, {:whitelist, updated})
    AgentCom.Config.put(:rate_limit_whitelist, updated)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Lazy DETS -> ETS Loading
  # ---------------------------------------------------------------------------

  @doc """
  Load persisted overrides and whitelist from Config DETS into ETS.

  Called lazily on first `check/3`. Uses an ETS flag `:_loaded` to avoid
  re-reading DETS on every call -- the ETS lookup is O(1) and essentially free.
  """
  @spec load_persisted_config() :: :ok
  def load_persisted_config do
    # Load whitelist
    case AgentCom.Config.get(:rate_limit_whitelist) do
      nil -> :ok
      list when is_list(list) -> :ets.insert(@override_table, {:whitelist, list})
      _ -> :ok
    end

    # Load per-agent overrides
    case AgentCom.Config.get(:rate_limit_overrides) do
      nil ->
        :ok

      overrides when is_map(overrides) ->
        Enum.each(overrides, fn {agent_id, tiers} ->
          Enum.each(tiers, fn {tier, %{capacity: cap, refill_rate: rate}} ->
            tier_atom = if is_binary(tier), do: String.to_existing_atom(tier), else: tier
            :ets.insert(@override_table, {{agent_id, tier_atom}, cap, rate})
          end)
        end)

      _ ->
        :ok
    end

    :ets.insert(@override_table, {:_loaded, true})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_check(agent_id, channel, tier) do
    key = {agent_id, channel, tier}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@bucket_table, key) do
      [{^key, tokens, last_refill, capacity, refill_rate}] ->
        elapsed = max(now - last_refill, 0)
        refilled = min(tokens + trunc(elapsed * refill_rate), capacity)

        if refilled >= @token_cost do
          remaining = refilled - @token_cost
          :ets.insert(@bucket_table, {key, remaining, now, capacity, refill_rate})

          if remaining < trunc(capacity * @warn_threshold) do
            emit_telemetry(agent_id, channel, tier, :warn, div(remaining, 1000))
            {:warn, div(remaining, 1000)}
          else
            emit_telemetry(agent_id, channel, tier, :allow, div(remaining, 1000))
            {:allow, div(remaining, 1000)}
          end
        else
          tokens_needed = @token_cost - refilled
          retry_ms = if refill_rate > 0, do: ceil(tokens_needed / refill_rate), else: 60_000
          # Round up to nearest second
          retry_ms = div(retry_ms + 999, 1000) * 1000
          :ets.insert(@bucket_table, {key, refilled, now, capacity, refill_rate})
          emit_telemetry(agent_id, channel, tier, :deny, retry_ms)
          {:deny, retry_ms}
        end

      [] ->
        # First request -- initialize bucket at full capacity minus cost
        {capacity, refill_rate} = get_limits(agent_id, channel, tier)
        remaining = capacity - @token_cost
        :ets.insert(@bucket_table, {key, remaining, now, capacity, refill_rate})

        if remaining < trunc(capacity * @warn_threshold) do
          emit_telemetry(agent_id, channel, tier, :warn, div(remaining, 1000))
          {:warn, div(remaining, 1000)}
        else
          emit_telemetry(agent_id, channel, tier, :allow, div(remaining, 1000))
          {:allow, div(remaining, 1000)}
        end
    end
  end

  defp backoff_ms(consecutive) when consecutive >= 5, do: @backoff_max
  defp backoff_ms(consecutive), do: Map.get(@backoff_curve, consecutive, @backoff_max)

  defp emit_telemetry(agent_id, channel, tier, result, remaining) do
    :telemetry.execute(
      [:agent_com, :rate_limit, :check],
      %{tokens_remaining: remaining},
      %{agent_id: agent_id, channel: channel, tier: tier, result: result}
    )
  end

  defp ensure_config_loaded do
    case :ets.lookup(@override_table, :_loaded) do
      [{:_loaded, true}] -> :ok
      [] -> load_persisted_config()
    end
  end

  defp get_overrides_from_dets do
    case AgentCom.Config.get(:rate_limit_overrides) do
      nil -> %{}
      overrides when is_map(overrides) -> overrides
      _ -> %{}
    end
  end
end
