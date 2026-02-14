defmodule AgentCom.Contemplation.ScalabilityAnalyzer do
  @moduledoc """
  Pure function module that analyzes MetricsCollector snapshots and produces
  structured scalability reports.

  No LLM calls — all analysis is based on metric thresholds and trend detection.
  Reads `MetricsCollector.snapshot/0` and returns an Elixir map suitable for
  JSON serialization (consumed by dashboard).

  ## Report Shape

      %{
        current_state: :healthy | :warning | :critical,
        metrics_summary: map(),
        bottleneck_analysis: [map()],
        recommendation: String.t()
      }
  """

  @warning_queue_depth 10
  @critical_queue_depth 50
  @warning_utilization 70.0
  @critical_utilization 90.0
  @warning_error_rate 5.0
  @critical_error_rate 15.0
  @warning_latency_p90 30_000
  @critical_latency_p90 120_000

  @doc """
  Analyze the current system metrics and produce a scalability report.

  Accepts an optional snapshot map. If not provided, reads from
  `MetricsCollector.snapshot/0`.
  """
  @spec analyze(map() | nil) :: map()
  def analyze(snapshot \\ nil) do
    snap = snapshot || fetch_snapshot()

    metrics_summary = summarize_metrics(snap)
    bottlenecks = detect_bottlenecks(snap)
    state = determine_state(bottlenecks)
    recommendation = build_recommendation(state, bottlenecks, snap)

    %{
      current_state: state,
      metrics_summary: metrics_summary,
      bottleneck_analysis: bottlenecks,
      recommendation: recommendation
    }
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_snapshot do
    try do
      AgentCom.MetricsCollector.snapshot()
    catch
      :exit, _ -> empty_snapshot()
    end
  end

  defp summarize_metrics(snap) do
    queue = Map.get(snap, :queue_depth, %{})
    latency = get_in(snap, [:task_latency, :window]) || %{}
    utilization = get_in(snap, [:agent_utilization, :system]) || %{}
    errors = get_in(snap, [:error_rates, :window]) || %{}

    %{
      queue_depth_current: Map.get(queue, :current, 0),
      queue_depth_avg_1h: Map.get(queue, :avg_1h, 0.0),
      queue_depth_max_1h: Map.get(queue, :max_1h, 0),
      latency_p50: Map.get(latency, :p50, 0),
      latency_p90: Map.get(latency, :p90, 0),
      latency_p99: Map.get(latency, :p99, 0),
      utilization_pct: Map.get(utilization, :utilization_pct, 0.0),
      total_agents: Map.get(utilization, :total_agents, 0),
      agents_working: Map.get(utilization, :agents_working, 0),
      error_rate_pct: Map.get(errors, :failure_rate_pct, 0.0)
    }
  end

  defp detect_bottlenecks(snap) do
    bottlenecks = []

    bottlenecks = check_queue_depth(snap, bottlenecks)
    bottlenecks = check_utilization(snap, bottlenecks)
    bottlenecks = check_error_rate(snap, bottlenecks)
    bottlenecks = check_latency(snap, bottlenecks)
    bottlenecks = check_queue_trend(snap, bottlenecks)

    bottlenecks
  end

  defp check_queue_depth(snap, acc) do
    current = get_in(snap, [:queue_depth, :current]) || 0

    cond do
      current >= @critical_queue_depth ->
        [%{type: :queue_depth, severity: :critical, value: current,
           message: "Queue depth at #{current} — tasks are accumulating faster than agents can process"} | acc]

      current >= @warning_queue_depth ->
        [%{type: :queue_depth, severity: :warning, value: current,
           message: "Queue depth at #{current} — approaching capacity"} | acc]

      true ->
        acc
    end
  end

  defp check_utilization(snap, acc) do
    pct = get_in(snap, [:agent_utilization, :system, :utilization_pct]) || 0.0

    cond do
      pct >= @critical_utilization ->
        [%{type: :utilization, severity: :critical, value: pct,
           message: "Agent utilization at #{pct}% — system is at capacity"} | acc]

      pct >= @warning_utilization ->
        [%{type: :utilization, severity: :warning, value: pct,
           message: "Agent utilization at #{pct}% — consider adding agents"} | acc]

      true ->
        acc
    end
  end

  defp check_error_rate(snap, acc) do
    rate = get_in(snap, [:error_rates, :window, :failure_rate_pct]) || 0.0

    cond do
      rate >= @critical_error_rate ->
        [%{type: :error_rate, severity: :critical, value: rate,
           message: "Error rate at #{rate}% — systemic failures detected"} | acc]

      rate >= @warning_error_rate ->
        [%{type: :error_rate, severity: :warning, value: rate,
           message: "Error rate at #{rate}% — elevated failure rate"} | acc]

      true ->
        acc
    end
  end

  defp check_latency(snap, acc) do
    p90 = get_in(snap, [:task_latency, :window, :p90]) || 0

    cond do
      p90 >= @critical_latency_p90 ->
        [%{type: :latency, severity: :critical, value: p90,
           message: "P90 latency at #{p90}ms — tasks taking excessively long"} | acc]

      p90 >= @warning_latency_p90 ->
        [%{type: :latency, severity: :warning, value: p90,
           message: "P90 latency at #{p90}ms — task processing slowing down"} | acc]

      true ->
        acc
    end
  end

  defp check_queue_trend(snap, acc) do
    trend = get_in(snap, [:queue_depth, :trend]) || []

    if length(trend) >= 5 do
      recent = Enum.take(trend, -5)
      first = List.first(recent)
      last = List.last(recent)

      if first > 0 and last > first * 2 do
        [%{type: :queue_trend, severity: :warning, value: recent,
           message: "Queue depth trend is increasing — demand may be outpacing capacity"} | acc]
      else
        acc
      end
    else
      acc
    end
  end

  defp determine_state(bottlenecks) do
    cond do
      Enum.any?(bottlenecks, fn b -> b.severity == :critical end) -> :critical
      Enum.any?(bottlenecks, fn b -> b.severity == :warning end) -> :warning
      true -> :healthy
    end
  end

  defp build_recommendation(:healthy, _bottlenecks, _snap) do
    "System is healthy. No scaling action needed."
  end

  defp build_recommendation(:warning, bottlenecks, snap) do
    total_agents = get_in(snap, [:agent_utilization, :system, :total_agents]) || 0
    types = bottlenecks |> Enum.map(& &1.type) |> Enum.uniq()

    cond do
      :utilization in types and total_agents > 0 ->
        "Consider adding 1-2 agents to reduce utilization pressure. Current: #{total_agents} agents."

      :queue_depth in types ->
        "Queue is growing. Consider adding agents or reducing goal submission rate."

      :latency in types ->
        "Task latency is elevated. Check for resource contention or complex goals."

      true ->
        "Minor bottlenecks detected. Monitor trends before scaling."
    end
  end

  defp build_recommendation(:critical, bottlenecks, snap) do
    total_agents = get_in(snap, [:agent_utilization, :system, :total_agents]) || 0
    types = bottlenecks |> Enum.map(& &1.type) |> Enum.uniq()

    cond do
      :error_rate in types ->
        "Critical error rate. Investigate failures before scaling — adding capacity won't fix broken tasks."

      :utilization in types or :queue_depth in types ->
        suggested = max(2, div(total_agents, 2))
        "System at capacity. Add #{suggested}+ agents or deploy additional machines. Current: #{total_agents} agents."

      true ->
        "Critical bottlenecks detected. Immediate investigation required."
    end
  end

  defp empty_snapshot do
    %{
      queue_depth: %{current: 0, trend: [], max_1h: 0, avg_1h: 0.0},
      task_latency: %{
        window: %{p50: 0, p90: 0, p99: 0, count: 0, min: 0, max: 0, mean: 0}
      },
      agent_utilization: %{
        system: %{total_agents: 0, agents_online: 0, agents_idle: 0, agents_working: 0, utilization_pct: 0.0}
      },
      error_rates: %{
        window: %{total_tasks: 0, failed: 0, dead_letter: 0, failure_rate_pct: 0.0}
      }
    }
  end
end
