defmodule AgentCom.HealthAggregatorTest do
  @moduledoc """
  Unit tests for the HealthAggregator module.

  Tests health signal aggregation from Alerter, MetricsCollector, LlmRegistry,
  and AgentFSM. Since HealthAggregator wraps all calls in try/catch, tests
  verify graceful degradation when sources are unavailable.
  """

  use ExUnit.Case, async: false

  alias AgentCom.HealthAggregator

  describe "assess/0" do
    test "returns healthy report when no issues detected" do
      # With no real services running, all safe_calls return defaults
      # which means no issues detected
      report = HealthAggregator.assess()

      assert report.healthy == true
      assert report.issues == []
      assert report.critical_count == 0
      assert is_integer(report.timestamp)
    end

    test "returns correct structure" do
      report = HealthAggregator.assess()

      assert Map.has_key?(report, :healthy)
      assert Map.has_key?(report, :issues)
      assert Map.has_key?(report, :critical_count)
      assert Map.has_key?(report, :timestamp)
    end

    test "handles graceful degradation when sources are unavailable" do
      # HealthAggregator wraps all calls in try/catch
      # When services are down, it returns safe defaults
      report = HealthAggregator.assess()

      # Should not crash, should return healthy (no issues detectable)
      assert report.healthy == true
      assert report.issues == []
    end

    test "timestamp is a recent millisecond value" do
      before = System.system_time(:millisecond)
      report = HealthAggregator.assess()
      after_ts = System.system_time(:millisecond)

      assert report.timestamp >= before
      assert report.timestamp <= after_ts
    end
  end
end
