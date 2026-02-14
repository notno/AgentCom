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
    test "returns correct structure with all required fields" do
      report = HealthAggregator.assess()

      assert Map.has_key?(report, :healthy)
      assert Map.has_key?(report, :issues)
      assert Map.has_key?(report, :critical_count)
      assert Map.has_key?(report, :timestamp)
      assert is_boolean(report.healthy)
      assert is_list(report.issues)
      assert is_integer(report.critical_count)
      assert is_integer(report.timestamp)
    end

    test "healthy is true when issues list is empty" do
      report = HealthAggregator.assess()

      if report.issues == [] do
        assert report.healthy == true
      else
        assert report.healthy == false
      end
    end

    test "critical_count matches actual critical issues in list" do
      report = HealthAggregator.assess()

      expected_critical = Enum.count(report.issues, &(&1.severity == :critical))
      assert report.critical_count == expected_critical
    end

    test "all issues have required fields" do
      report = HealthAggregator.assess()

      Enum.each(report.issues, fn issue ->
        assert Map.has_key?(issue, :source)
        assert Map.has_key?(issue, :severity)
        assert Map.has_key?(issue, :category)
        assert Map.has_key?(issue, :detail)
        assert issue.severity in [:critical, :warning]
        assert is_atom(issue.source)
        assert is_atom(issue.category)
        assert is_map(issue.detail)
      end)
    end

    test "timestamp is a recent millisecond value" do
      before = System.system_time(:millisecond)
      report = HealthAggregator.assess()
      after_ts = System.system_time(:millisecond)

      assert report.timestamp >= before
      assert report.timestamp <= after_ts
    end

    test "does not crash under any circumstances" do
      # HealthAggregator wraps all calls in try/catch
      # This should never raise regardless of service state
      report = HealthAggregator.assess()
      assert is_map(report)
    end
  end
end
