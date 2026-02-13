defmodule AgentCom.Alerter do
  @moduledoc """
  Configurable alert rule evaluator with cooldown and acknowledgment state.

  Periodically evaluates 7 alert rules against metrics from
  `AgentCom.MetricsCollector.snapshot/0`, manages alert lifecycle
  (inactive -> active -> acknowledged -> cleared), and broadcasts
  state changes on PubSub "alerts" topic.

  ## Alert Rules

  1. **queue_growing** (WARNING) -- Queue depth increasing for N consecutive checks.
  2. **high_failure_rate** (WARNING) -- Failure rate exceeds threshold percentage.
  3. **stuck_tasks** (CRITICAL) -- Tasks assigned longer than threshold without progress.
  4. **no_agents_online** (CRITICAL) -- All previously registered agents disconnected.
  5. **high_error_rate** (WARNING) -- Error count in window exceeds threshold.
  6. **tier_down** (WARNING) -- All Ollama endpoints unhealthy beyond configurable threshold.
  7. **hub_invocation_rate** (WARNING) -- Hub Claude Code invocation rate exceeds threshold per hour.

  ## Cooldown Behavior

  - CRITICAL alerts always fire immediately (bypass cooldown).
  - WARNING alerts respect per-rule cooldown periods.
  - Acknowledged alerts are suppressed until condition clears and returns.

  ## Configuration

  Thresholds are read from `AgentCom.Config.get(:alert_thresholds)` on EVERY
  check cycle. Changes via PUT /api/config/alert-thresholds take effect on the
  next cycle without restart.

  ## PubSub Broadcasts (on "alerts" topic)

  - `{:alert_fired, %{rule_id: atom, severity: atom, message: string, details: map, fired_at: integer}}`
  - `{:alert_cleared, rule_id}`
  - `{:alert_acknowledged, rule_id}`

  ## Public API

  - `start_link/1` -- Standard GenServer.
  - `active_alerts/0` -- Returns list of active alert maps.
  - `acknowledge/1` -- Acknowledge an alert by rule_id atom or string.
  - `default_thresholds/0` -- Returns default thresholds map.
  - `check_now/0` -- Triggers an immediate check cycle (for testing/manual use).
  """

  use GenServer
  require Logger

  @name __MODULE__
  @startup_delay_ms 30_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Returns list of active alerts as maps."
  def active_alerts do
    GenServer.call(@name, :active_alerts)
  end

  @doc """
  Acknowledge an alert by rule_id (atom or string).
  Returns :ok or {:error, :not_found}.
  """
  def acknowledge(rule_id) when is_binary(rule_id) do
    atom_id = safe_to_existing_atom(rule_id)

    if atom_id do
      acknowledge(atom_id)
    else
      {:error, :not_found}
    end
  end

  def acknowledge(rule_id) when is_atom(rule_id) do
    GenServer.call(@name, {:acknowledge, rule_id})
  end

  @doc "Returns the default thresholds map."
  def default_thresholds do
    %{
      queue_growing_checks: 3,
      failure_rate_pct: 50,
      stuck_task_ms: 300_000,
      error_count_hour: 10,
      hub_invocations_per_hour_warn: 50,
      check_interval_ms: 30_000,
      cooldowns: %{
        queue_growing: 300_000,
        high_failure_rate: 600_000,
        stuck_tasks: 0,
        no_agents_online: 0,
        high_error_rate: 300_000,
        tier_down: 300_000,
        hub_invocation_rate: 300_000
      }
    }
  end

  @doc "Triggers an immediate check cycle. Returns :ok."
  def check_now do
    GenServer.call(@name, :check_now)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    # Schedule first check with startup delay to prevent false positives
    # on fresh start before agents reconnect.
    Process.send_after(self(), :check, @startup_delay_ms)

    Logger.info("alerter_started",
      startup_delay_ms: @startup_delay_ms,
      default_check_interval_ms: default_thresholds().check_interval_ms
    )

    {:ok,
     %{
       active_alerts: %{},
       cooldown_state: %{},
       consecutive_checks: %{},
       tier_down_since: nil
     }}
  end

  # -- active_alerts -----------------------------------------------------------

  @impl true
  def handle_call(:active_alerts, _from, state) do
    alerts =
      state.active_alerts
      |> Enum.map(fn {rule_id, alert} ->
        Map.put(alert, :rule_id, rule_id)
      end)

    {:reply, alerts, state}
  end

  # -- acknowledge -------------------------------------------------------------

  @impl true
  def handle_call({:acknowledge, rule_id}, _from, state) do
    case Map.get(state.active_alerts, rule_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      alert ->
        updated_alert = Map.put(alert, :acknowledged, true)
        new_active = Map.put(state.active_alerts, rule_id, updated_alert)

        Phoenix.PubSub.broadcast(
          AgentCom.PubSub,
          "alerts",
          {:alert_acknowledged, rule_id}
        )

        Logger.info("alert_acknowledged", rule_id: rule_id)
        {:reply, :ok, %{state | active_alerts: new_active}}
    end
  end

  # -- check_now ---------------------------------------------------------------

  @impl true
  def handle_call(:check_now, _from, state) do
    new_state = run_check_cycle(state)
    {:reply, :ok, new_state}
  end

  # -- Periodic check cycle ----------------------------------------------------

  @impl true
  def handle_info(:check, state) do
    new_state = run_check_cycle(state)

    thresholds = load_thresholds()
    interval = Map.get(thresholds, :check_interval_ms, 30_000)
    Process.send_after(self(), :check, interval)

    {:noreply, new_state}
  end

  # Catch-all for unknown messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private: Check cycle logic
  # ---------------------------------------------------------------------------

  defp run_check_cycle(state) do
    thresholds = load_thresholds()
    metrics = safe_snapshot()
    now = System.system_time(:millisecond)

    # Evaluate tier_down rule (updates tier_down_since state)
    {tier_down_result, new_tier_down_since} = evaluate_tier_down(state.tier_down_since, now)

    # Evaluate each rule
    rules = [
      {:queue_growing, evaluate_queue_growing(metrics, thresholds, state.consecutive_checks)},
      {:high_failure_rate, evaluate_high_failure_rate(metrics, thresholds)},
      {:stuck_tasks, evaluate_stuck_tasks(thresholds)},
      {:no_agents_online, evaluate_no_agents_online(metrics)},
      {:high_error_rate, evaluate_high_error_rate(metrics, thresholds)},
      {:tier_down, tier_down_result},
      {:hub_invocation_rate, evaluate_hub_invocation_rate(thresholds)}
    ]

    # Process each rule result, then update tier_down_since
    state = %{state | tier_down_since: new_tier_down_since}

    Enum.reduce(rules, state, fn {rule_id, result}, acc ->
      process_rule_result(rule_id, result, acc, thresholds, now)
    end)
  end

  defp process_rule_result(rule_id, {:triggered, severity, message, details}, state, thresholds, now) do
    current_alert = Map.get(state.active_alerts, rule_id)

    # Update consecutive checks for queue_growing hysteresis
    new_consecutive =
      if rule_id == :queue_growing do
        count = Map.get(details, :consecutive_increases, 0)
        Map.put(state.consecutive_checks, :queue_growing_increases, count)
      else
        state.consecutive_checks
      end

    cond do
      # Rule inactive -> fire new alert
      is_nil(current_alert) ->
        alert = %{
          severity: severity,
          message: message,
          details: details,
          fired_at: now,
          acknowledged: false
        }

        new_active = Map.put(state.active_alerts, rule_id, alert)
        new_cooldown = Map.put(state.cooldown_state, rule_id, now)

        broadcast_alert_fired(rule_id, alert)
        Logger.warning("alert_fired", rule_id: rule_id, severity: severity, message: message)

        %{state |
          active_alerts: new_active,
          cooldown_state: new_cooldown,
          consecutive_checks: new_consecutive
        }

      # Rule active and acknowledged -> suppressed
      current_alert.acknowledged ->
        %{state | consecutive_checks: new_consecutive}

      # Rule active, not acknowledged -> check cooldown for re-fire
      should_fire?(rule_id, severity, state.cooldown_state, thresholds, now) ->
        new_cooldown = Map.put(state.cooldown_state, rule_id, now)

        # Update the alert details
        updated_alert = %{current_alert | message: message, details: details}
        new_active = Map.put(state.active_alerts, rule_id, updated_alert)

        broadcast_alert_fired(rule_id, updated_alert)
        Logger.warning("alert_re_fired", rule_id: rule_id, severity: severity)

        %{state |
          active_alerts: new_active,
          cooldown_state: new_cooldown,
          consecutive_checks: new_consecutive
        }

      # Cooldown not expired -> skip
      true ->
        %{state | consecutive_checks: new_consecutive}
    end
  end

  defp process_rule_result(rule_id, :ok, state, _thresholds, _now) do
    current_alert = Map.get(state.active_alerts, rule_id)

    # Update consecutive checks for queue_growing hysteresis
    new_consecutive =
      if rule_id == :queue_growing do
        # Track consecutive stable/decreasing checks
        stable_count = Map.get(state.consecutive_checks, :queue_stable, 0) + 1
        state.consecutive_checks
        |> Map.put(:queue_stable, stable_count)
        |> Map.put(:queue_growing_increases, 0)
      else
        state.consecutive_checks
      end

    # Only clear if condition is truly resolved (for queue_growing, need 3 stable checks)
    should_clear =
      if rule_id == :queue_growing and not is_nil(current_alert) do
        stable_count = Map.get(new_consecutive, :queue_stable, 0)
        stable_count >= 3
      else
        not is_nil(current_alert)
      end

    if should_clear do
      new_active = Map.delete(state.active_alerts, rule_id)
      new_cooldown = Map.delete(state.cooldown_state, rule_id)

      # Reset stable counter on clear
      cleared_consecutive =
        if rule_id == :queue_growing do
          Map.put(new_consecutive, :queue_stable, 0)
        else
          new_consecutive
        end

      Phoenix.PubSub.broadcast(AgentCom.PubSub, "alerts", {:alert_cleared, rule_id})
      Logger.info("alert_cleared", rule_id: rule_id)

      %{state |
        active_alerts: new_active,
        cooldown_state: new_cooldown,
        consecutive_checks: cleared_consecutive
      }
    else
      %{state | consecutive_checks: new_consecutive}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Alert rule evaluators
  # ---------------------------------------------------------------------------

  # Rule 1: Queue growing
  defp evaluate_queue_growing(metrics, thresholds, consecutive_checks) do
    trend = get_in(metrics, [:queue_depth, :trend]) || []
    threshold = Map.get(thresholds, :queue_growing_checks, 3)
    current_depth = get_in(metrics, [:queue_depth, :current]) || 0

    consecutive_increases = count_consecutive_increases(trend)

    # Use stored count if trend is short but we have been tracking
    effective_count =
      max(
        consecutive_increases,
        Map.get(consecutive_checks, :queue_growing_increases, 0)
      )

    if effective_count >= threshold do
      {:triggered, :warning,
       "Queue growing: depth increased for #{effective_count} consecutive checks (current: #{current_depth})",
       %{consecutive_increases: effective_count, current_depth: current_depth}}
    else
      :ok
    end
  end

  # Rule 2: High failure rate (percentage)
  defp evaluate_high_failure_rate(metrics, thresholds) do
    failure_rate = get_in(metrics, [:error_rates, :window, :failure_rate_pct]) || 0.0
    total_tasks = get_in(metrics, [:error_rates, :window, :total_tasks]) || 0
    failed = get_in(metrics, [:error_rates, :window, :failed]) || 0
    threshold = Map.get(thresholds, :failure_rate_pct, 50)

    if failure_rate > threshold and total_tasks > 0 do
      {:triggered, :warning,
       "High failure rate: #{failure_rate}% (#{failed}/#{total_tasks} tasks failed in last hour)",
       %{failure_rate_pct: failure_rate, failed: failed, total_tasks: total_tasks}}
    else
      :ok
    end
  end

  # Rule 3: Stuck tasks
  defp evaluate_stuck_tasks(thresholds) do
    threshold_ms = Map.get(thresholds, :stuck_task_ms, 300_000)
    now = System.system_time(:millisecond)

    assigned_tasks =
      try do
        AgentCom.TaskQueue.list(status: :assigned)
      rescue
        _ -> []
      end

    stuck_tasks =
      Enum.filter(assigned_tasks, fn task ->
        updated_at = task.updated_at || task.assigned_at || 0
        now - updated_at > threshold_ms
      end)

    if stuck_tasks != [] do
      task_ids = Enum.map(stuck_tasks, & &1.id)
      max_duration = Enum.map(stuck_tasks, fn t ->
        updated_at = t.updated_at || t.assigned_at || 0
        now - updated_at
      end) |> Enum.max(fn -> 0 end)

      threshold_min = div(threshold_ms, 60_000)

      {:triggered, :critical,
       "#{length(stuck_tasks)} tasks stuck: #{Enum.join(Enum.take(task_ids, 5), ", ")} (>#{threshold_min} min without progress)",
       %{task_ids: task_ids, stuck_duration_ms: max_duration}}
    else
      :ok
    end
  end

  # Rule 4: No agents online
  defp evaluate_no_agents_online(metrics) do
    agents_online = get_in(metrics, [:agent_utilization, :system, :agents_online]) || 0
    total_agents = get_in(metrics, [:agent_utilization, :system, :total_agents]) || 0

    # Only fire if we had agents before (don't fire on fresh start with no agents)
    if agents_online == 0 and total_agents > 0 do
      {:triggered, :critical,
       "No agents online (#{total_agents} previously registered)",
       %{total_agents: total_agents}}
    else
      :ok
    end
  end

  # Rule 5: High error rate (count)
  defp evaluate_high_error_rate(metrics, thresholds) do
    failed = get_in(metrics, [:error_rates, :window, :failed]) || 0
    threshold = Map.get(thresholds, :error_count_hour, 10)

    if failed > threshold do
      {:triggered, :warning,
       "High error count: #{failed} failures in the last hour (threshold: #{threshold})",
       %{failed: failed, threshold: threshold}}
    else
      :ok
    end
  end

  # Rule 6: Tier down (Ollama endpoints all unhealthy beyond threshold)
  defp evaluate_tier_down(tier_down_since, now) do
    threshold_ms =
      try do
        AgentCom.Config.get(:tier_down_alert_threshold_ms) || 60_000
      rescue
        _ -> 60_000
      end

    endpoints =
      try do
        AgentCom.LlmRegistry.list_endpoints()
      rescue
        _ -> []
      end

    any_healthy = Enum.any?(endpoints, fn ep -> ep.status == :healthy end)
    has_endpoints = endpoints != []

    cond do
      # No endpoints registered at all -- not a "tier down" condition
      not has_endpoints ->
        {:ok, nil}

      # At least one healthy endpoint -- clear condition
      any_healthy ->
        {:ok, nil}

      # All endpoints unhealthy -- track or fire
      true ->
        since = tier_down_since || now
        duration_ms = now - since

        if duration_ms >= threshold_ms do
          duration_s = div(duration_ms, 1_000)
          unhealthy_ids = Enum.map(endpoints, & &1.id)

          result =
            {:triggered, :warning,
             "Ollama tier down: no healthy endpoints for #{duration_s}s",
             %{unhealthy_endpoints: unhealthy_ids, duration_ms: duration_ms}}

          {result, since}
        else
          # Below threshold -- tracking but not yet triggered
          {:ok, since}
        end
    end
  end

  # Rule 7: Hub invocation rate (Claude Code CLI calls per hour)
  defp evaluate_hub_invocation_rate(thresholds) do
    hourly_threshold = Map.get(thresholds, :hub_invocations_per_hour_warn, 50)

    total_hourly =
      try do
        stats = AgentCom.CostLedger.stats()
        get_in(stats, [:hourly, :total]) || 0
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    if total_hourly > hourly_threshold do
      {:triggered, :warning,
       "Hub invocation rate high: #{total_hourly} calls this hour (threshold: #{hourly_threshold})",
       %{hourly_invocations: total_hourly, threshold: hourly_threshold}}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Cooldown logic
  # ---------------------------------------------------------------------------

  defp should_fire?(rule_id, severity, cooldown_state, thresholds, now) do
    # CRITICAL alerts always fire immediately
    if severity == :critical do
      true
    else
      case Map.get(cooldown_state, rule_id) do
        nil ->
          # First fire
          true

        last_fired_at ->
          cooldown_ms = get_in(thresholds, [:cooldowns, rule_id]) || 0

          if cooldown_ms == 0 do
            true
          else
            now - last_fired_at >= cooldown_ms
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Helper functions
  # ---------------------------------------------------------------------------

  defp load_thresholds do
    try do
      case AgentCom.Config.get(:alert_thresholds) do
        nil -> default_thresholds()
        thresholds when is_map(thresholds) -> merge_with_defaults(thresholds)
        _ -> default_thresholds()
      end
    rescue
      _ -> default_thresholds()
    end
  end

  defp merge_with_defaults(custom) do
    defaults = default_thresholds()

    # Merge top-level keys, but also merge cooldowns map
    merged = Map.merge(defaults, custom)

    cooldowns =
      Map.merge(
        defaults.cooldowns,
        Map.get(custom, :cooldowns, Map.get(custom, "cooldowns", %{}))
      )

    Map.put(merged, :cooldowns, cooldowns)
  end

  defp safe_snapshot do
    try do
      AgentCom.MetricsCollector.snapshot()
    rescue
      _ -> %{}
    end
  end

  defp count_consecutive_increases(trend) when length(trend) < 2, do: 0

  defp count_consecutive_increases(trend) do
    # Compare adjacent pairs from the end of the trend list
    trend
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reverse()
    |> Enum.reduce_while(0, fn [a, b], count ->
      if b > a do
        {:cont, count + 1}
      else
        {:halt, count}
      end
    end)
  end

  defp broadcast_alert_fired(rule_id, alert) do
    Phoenix.PubSub.broadcast(
      AgentCom.PubSub,
      "alerts",
      {:alert_fired,
       %{
         rule_id: rule_id,
         severity: alert.severity,
         message: alert.message,
         details: alert.details,
         fired_at: alert.fired_at
       }}
    )
  end

  defp safe_to_existing_atom(string) do
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError -> nil
    end
  end
end
