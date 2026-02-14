defmodule AgentCom.Contemplation.ScalabilityAnalyzerTest do
  use ExUnit.Case, async: true

  alias AgentCom.Contemplation.ScalabilityAnalyzer

  @healthy_snapshot %{
    queue_depth: %{current: 2, trend: [1, 1, 2, 2, 2], max_1h: 3, avg_1h: 1.5},
    task_latency: %{window: %{p50: 5000, p90: 10000, p99: 20000, count: 10, min: 1000, max: 25000, mean: 8000}},
    agent_utilization: %{system: %{total_agents: 4, agents_online: 4, agents_idle: 2, agents_working: 2, utilization_pct: 50.0}},
    error_rates: %{window: %{total_tasks: 100, failed: 2, dead_letter: 0, failure_rate_pct: 2.0}}
  }

  @critical_snapshot %{
    queue_depth: %{current: 60, trend: [10, 20, 30, 40, 60], max_1h: 60, avg_1h: 40.0},
    task_latency: %{window: %{p50: 60000, p90: 150000, p99: 300000, count: 50, min: 5000, max: 350000, mean: 80000}},
    agent_utilization: %{system: %{total_agents: 4, agents_online: 4, agents_idle: 0, agents_working: 4, utilization_pct: 95.0}},
    error_rates: %{window: %{total_tasks: 100, failed: 20, dead_letter: 5, failure_rate_pct: 20.0}}
  }

  describe "analyze/1" do
    test "healthy system returns healthy state" do
      result = ScalabilityAnalyzer.analyze(@healthy_snapshot)
      assert result.current_state == :healthy
      assert result.recommendation =~ "healthy"
      assert result.bottleneck_analysis == []
    end

    test "critical system returns critical state with bottlenecks" do
      result = ScalabilityAnalyzer.analyze(@critical_snapshot)
      assert result.current_state == :critical
      assert length(result.bottleneck_analysis) > 0
      bottleneck_types = Enum.map(result.bottleneck_analysis, & &1.type)
      assert :queue_depth in bottleneck_types
      assert :utilization in bottleneck_types
    end

    test "metrics_summary contains expected keys" do
      result = ScalabilityAnalyzer.analyze(@healthy_snapshot)
      summary = result.metrics_summary
      assert Map.has_key?(summary, :queue_depth_current)
      assert Map.has_key?(summary, :utilization_pct)
      assert Map.has_key?(summary, :latency_p90)
      assert Map.has_key?(summary, :error_rate_pct)
    end

    test "nil snapshot uses empty defaults" do
      result = ScalabilityAnalyzer.analyze(nil)
      assert result.current_state == :healthy
    end

    test "warning state detected for elevated utilization" do
      snap = put_in(@healthy_snapshot, [:agent_utilization, :system, :utilization_pct], 75.0)
      result = ScalabilityAnalyzer.analyze(snap)
      assert result.current_state == :warning
      assert result.recommendation =~ "agent"
    end

    test "recommendation distinguishes agents vs machines" do
      # High utilization -> add agents
      agent_snap = put_in(@healthy_snapshot, [:agent_utilization, :system, :utilization_pct], 92.0)
      result = ScalabilityAnalyzer.analyze(agent_snap)
      assert result.recommendation =~ "agent" or result.recommendation =~ "machine"
    end
  end
end
