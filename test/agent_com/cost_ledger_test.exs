defmodule AgentCom.CostLedgerTest do
  @moduledoc """
  Comprehensive TDD test suite for CostLedger GenServer.

  Covers: check_budget/1, record_invocation/2, stats/0, history/1,
  rolling window expiration, restart recovery, per-state budget isolation,
  budget configuration, and telemetry emission.

  Uses DetsHelpers.full_test_setup for DETS isolation.
  """

  use ExUnit.Case, async: false

  alias AgentCom.CostLedger

  setup do
    tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()

    on_exit(fn ->
      AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # check_budget/1
  # ---------------------------------------------------------------------------

  describe "check_budget/1" do
    test "returns :ok when no invocations recorded" do
      assert :ok = CostLedger.check_budget(:executing)
    end

    test "returns :ok when invocations below hourly limit" do
      # Default executing limit is 20/hr -- record 5
      for _ <- 1..5 do
        CostLedger.record_invocation(:executing, %{duration_ms: 100})
      end

      assert :ok = CostLedger.check_budget(:executing)
    end

    test "returns :budget_exhausted when hourly limit reached" do
      # Default executing hourly limit is 20
      for _ <- 1..20 do
        CostLedger.record_invocation(:executing, %{duration_ms: 100})
      end

      assert :budget_exhausted = CostLedger.check_budget(:executing)
    end

    test "returns :budget_exhausted when daily limit reached" do
      # Use :contemplating which has lowest limits: 5/hr, 15/day
      # Set custom budget to make hourly high but daily low for this test
      AgentCom.Config.put(:hub_invocation_budgets, %{
        contemplating: %{max_per_hour: 100, max_per_day: 3}
      })

      for _ <- 1..3 do
        CostLedger.record_invocation(:contemplating, %{duration_ms: 50})
      end

      assert :budget_exhausted = CostLedger.check_budget(:contemplating)

      # Clean up
      AgentCom.Config.put(:hub_invocation_budgets, nil)
    end

    test "per-state isolation: exhausting :executing does not affect :improving" do
      # Exhaust :executing budget (20/hr default)
      for _ <- 1..20 do
        CostLedger.record_invocation(:executing, %{duration_ms: 100})
      end

      assert :budget_exhausted = CostLedger.check_budget(:executing)
      assert :ok = CostLedger.check_budget(:improving)
    end

    test "per-state isolation: exhausting :improving does not affect :contemplating" do
      # Exhaust :improving budget (10/hr default)
      for _ <- 1..10 do
        CostLedger.record_invocation(:improving, %{duration_ms: 100})
      end

      assert :budget_exhausted = CostLedger.check_budget(:improving)
      assert :ok = CostLedger.check_budget(:contemplating)
    end

    test "per-state isolation: each state tracks independently" do
      # Record some invocations for each state, but don't exhaust any
      for _ <- 1..3 do
        CostLedger.record_invocation(:executing, %{})
        CostLedger.record_invocation(:improving, %{})
        CostLedger.record_invocation(:contemplating, %{})
      end

      # All should still be :ok (well below limits)
      assert :ok = CostLedger.check_budget(:executing)
      assert :ok = CostLedger.check_budget(:improving)
      assert :ok = CostLedger.check_budget(:contemplating)
    end
  end

  # ---------------------------------------------------------------------------
  # record_invocation/2
  # ---------------------------------------------------------------------------

  describe "record_invocation/2" do
    test "returns :ok" do
      assert :ok = CostLedger.record_invocation(:executing, %{duration_ms: 5000, prompt_type: :decompose})
    end

    test "increments ETS counters verified via stats/0" do
      CostLedger.record_invocation(:executing, %{duration_ms: 100})
      CostLedger.record_invocation(:executing, %{duration_ms: 200})

      stats = CostLedger.stats()
      assert stats.hourly.executing == 2
      assert stats.daily.executing == 2
      assert stats.session.executing == 2
    end

    test "persists to DETS verified via history/1" do
      CostLedger.record_invocation(:improving, %{duration_ms: 300, prompt_type: :review})

      records = CostLedger.history(state: :improving)
      assert length(records) == 1

      [record] = records
      assert record.hub_state == :improving
      assert record.duration_ms == 300
      assert record.prompt_type == :review
    end

    test "multiple invocations accumulate correctly" do
      for i <- 1..7 do
        CostLedger.record_invocation(:executing, %{duration_ms: i * 100})
      end

      stats = CostLedger.stats()
      assert stats.hourly.executing == 7
      assert stats.daily.executing == 7
      assert stats.session.executing == 7

      records = CostLedger.history(state: :executing)
      assert length(records) == 7
    end

    test "records default metadata when not provided" do
      CostLedger.record_invocation(:executing)

      [record] = CostLedger.history(state: :executing)
      assert record.duration_ms == 0
      assert record.prompt_type == :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # stats/0
  # ---------------------------------------------------------------------------

  describe "stats/0" do
    test "returns map with :hourly, :daily, :session, :budgets keys" do
      stats = CostLedger.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :hourly)
      assert Map.has_key?(stats, :daily)
      assert Map.has_key?(stats, :session)
      assert Map.has_key?(stats, :budgets)
    end

    test "hourly/daily/session each have per-state counts and :total" do
      CostLedger.record_invocation(:executing, %{})
      CostLedger.record_invocation(:improving, %{})

      stats = CostLedger.stats()

      # Hourly
      assert is_integer(stats.hourly.executing)
      assert is_integer(stats.hourly.improving)
      assert is_integer(stats.hourly.contemplating)
      assert stats.hourly.total == stats.hourly.executing + stats.hourly.improving + stats.hourly.contemplating

      # Daily
      assert is_integer(stats.daily.executing)
      assert is_integer(stats.daily.improving)
      assert is_integer(stats.daily.contemplating)
      assert stats.daily.total == stats.daily.executing + stats.daily.improving + stats.daily.contemplating

      # Session
      assert is_integer(stats.session.executing)
      assert is_integer(stats.session.improving)
      assert is_integer(stats.session.contemplating)
      assert stats.session.total == stats.session.executing + stats.session.improving + stats.session.contemplating
    end

    test "budgets reflect default values" do
      stats = CostLedger.stats()

      assert stats.budgets.executing.hourly_limit == 20
      assert stats.budgets.executing.daily_limit == 100
      assert stats.budgets.improving.hourly_limit == 10
      assert stats.budgets.improving.daily_limit == 40
      assert stats.budgets.contemplating.hourly_limit == 5
      assert stats.budgets.contemplating.daily_limit == 15
    end

    test "stats accurately reflect recorded invocations" do
      CostLedger.record_invocation(:executing, %{})
      CostLedger.record_invocation(:executing, %{})
      CostLedger.record_invocation(:improving, %{})

      stats = CostLedger.stats()

      assert stats.hourly.executing == 2
      assert stats.hourly.improving == 1
      assert stats.hourly.contemplating == 0
      assert stats.hourly.total == 3
    end
  end

  # ---------------------------------------------------------------------------
  # history/1
  # ---------------------------------------------------------------------------

  describe "history/1" do
    test "returns list of record maps sorted by timestamp descending" do
      CostLedger.record_invocation(:executing, %{duration_ms: 100})
      Process.sleep(10)
      CostLedger.record_invocation(:executing, %{duration_ms: 200})
      Process.sleep(10)
      CostLedger.record_invocation(:executing, %{duration_ms: 300})

      records = CostLedger.history()
      timestamps = Enum.map(records, & &1.timestamp)

      # Should be descending
      assert timestamps == Enum.sort(timestamps, :desc)
      assert length(records) == 3
    end

    test "filters by state" do
      CostLedger.record_invocation(:executing, %{})
      CostLedger.record_invocation(:improving, %{})
      CostLedger.record_invocation(:executing, %{})

      exec_records = CostLedger.history(state: :executing)
      assert length(exec_records) == 2
      assert Enum.all?(exec_records, &(&1.hub_state == :executing))

      imp_records = CostLedger.history(state: :improving)
      assert length(imp_records) == 1
      assert Enum.all?(imp_records, &(&1.hub_state == :improving))
    end

    test "limits results with :limit option" do
      for _ <- 1..10 do
        CostLedger.record_invocation(:executing, %{})
      end

      records = CostLedger.history(limit: 5)
      assert length(records) == 5
    end

    test "filters by :since timestamp" do
      CostLedger.record_invocation(:executing, %{})
      Process.sleep(50)

      since_ts = System.system_time(:millisecond)
      Process.sleep(50)

      CostLedger.record_invocation(:executing, %{})
      CostLedger.record_invocation(:executing, %{})

      records = CostLedger.history(since: since_ts)
      assert length(records) == 2
      assert Enum.all?(records, &(&1.timestamp >= since_ts))
    end

    test "returns empty list when no records exist" do
      records = CostLedger.history()
      assert records == []
    end

    test "combined filters work together" do
      CostLedger.record_invocation(:executing, %{})
      CostLedger.record_invocation(:improving, %{})
      Process.sleep(50)

      since_ts = System.system_time(:millisecond)
      Process.sleep(50)

      for _ <- 1..5 do
        CostLedger.record_invocation(:executing, %{})
      end

      CostLedger.record_invocation(:improving, %{})

      records = CostLedger.history(state: :executing, since: since_ts, limit: 3)
      assert length(records) == 3
      assert Enum.all?(records, &(&1.hub_state == :executing))
      assert Enum.all?(records, &(&1.timestamp >= since_ts))
    end
  end

  # ---------------------------------------------------------------------------
  # Rolling window
  # ---------------------------------------------------------------------------

  describe "rolling window" do
    test "records older than 1 hour do not count toward hourly budget" do
      # Insert a backdated record directly into DETS (simulating old records)
      old_timestamp = System.system_time(:millisecond) - 3_700_000  # 1hr + 100s ago
      old_record = %{
        id: 999_001,
        hub_state: :executing,
        timestamp: old_timestamp,
        duration_ms: 100,
        prompt_type: :unknown
      }
      :dets.insert(:cost_ledger, {999_001, old_record})
      :dets.sync(:cost_ledger)

      # Restart CostLedger to rebuild ETS from DETS
      restart_cost_ledger()

      stats = CostLedger.stats()
      # The old record should NOT count toward hourly
      assert stats.hourly.executing == 0
      # But SHOULD count toward daily (it's within 24hrs)
      assert stats.daily.executing == 1
    end

    test "records older than 24 hours do not count toward daily budget" do
      # Insert a record from >24 hours ago
      old_timestamp = System.system_time(:millisecond) - 90_000_000  # ~25 hours ago
      old_record = %{
        id: 999_002,
        hub_state: :improving,
        timestamp: old_timestamp,
        duration_ms: 200,
        prompt_type: :unknown
      }
      :dets.insert(:cost_ledger, {999_002, old_record})
      :dets.sync(:cost_ledger)

      # Restart to rebuild ETS
      restart_cost_ledger()

      stats = CostLedger.stats()
      assert stats.hourly.improving == 0
      assert stats.daily.improving == 0
      # But session count should include it (cold start counts all)
      assert stats.session.improving == 1
    end

    test "session count includes all records since GenServer start" do
      # Insert records at various ages
      now = System.system_time(:millisecond)

      records = [
        {999_010, %{id: 999_010, hub_state: :executing, timestamp: now - 100_000_000, duration_ms: 0, prompt_type: :unknown}},
        {999_011, %{id: 999_011, hub_state: :executing, timestamp: now - 50_000_000, duration_ms: 0, prompt_type: :unknown}},
        {999_012, %{id: 999_012, hub_state: :executing, timestamp: now - 1_000, duration_ms: 0, prompt_type: :unknown}}
      ]

      for {id, record} <- records do
        :dets.insert(:cost_ledger, {id, record})
      end
      :dets.sync(:cost_ledger)

      # Restart to rebuild
      restart_cost_ledger()

      stats = CostLedger.stats()
      # All 3 should count toward session (cold start includes all)
      assert stats.session.executing == 3
    end

    test "fresh records count toward both hourly and daily" do
      CostLedger.record_invocation(:executing, %{duration_ms: 100})

      stats = CostLedger.stats()
      assert stats.hourly.executing == 1
      assert stats.daily.executing == 1
      assert stats.session.executing == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Restart recovery
  # ---------------------------------------------------------------------------

  describe "restart recovery" do
    test "ETS counters are rebuilt from DETS after restart" do
      # Record some invocations
      CostLedger.record_invocation(:executing, %{duration_ms: 100})
      CostLedger.record_invocation(:executing, %{duration_ms: 200})
      CostLedger.record_invocation(:improving, %{duration_ms: 300})

      # Verify they exist before restart
      stats_before = CostLedger.stats()
      assert stats_before.hourly.executing == 2
      assert stats_before.hourly.improving == 1

      # Restart CostLedger
      restart_cost_ledger()

      # Verify counters are rebuilt
      stats_after = CostLedger.stats()
      assert stats_after.hourly.executing == 2
      assert stats_after.hourly.improving == 1
    end

    test "invocations recorded before restart still count toward budget" do
      # Set a low custom budget for testing
      AgentCom.Config.put(:hub_invocation_budgets, %{
        executing: %{max_per_hour: 3, max_per_day: 10}
      })

      CostLedger.record_invocation(:executing, %{})
      CostLedger.record_invocation(:executing, %{})
      CostLedger.record_invocation(:executing, %{})

      # Should be exhausted
      assert :budget_exhausted = CostLedger.check_budget(:executing)

      # Restart
      restart_cost_ledger()

      # Still exhausted after restart
      assert :budget_exhausted = CostLedger.check_budget(:executing)

      # Clean up
      AgentCom.Config.put(:hub_invocation_budgets, nil)
    end

    test "history survives restart" do
      CostLedger.record_invocation(:contemplating, %{duration_ms: 500, prompt_type: :reflect})

      records_before = CostLedger.history(state: :contemplating)
      assert length(records_before) == 1

      restart_cost_ledger()

      records_after = CostLedger.history(state: :contemplating)
      assert length(records_after) == 1
      assert hd(records_after).duration_ms == 500
      assert hd(records_after).prompt_type == :reflect
    end
  end

  # ---------------------------------------------------------------------------
  # Budget configuration
  # ---------------------------------------------------------------------------

  describe "budget configuration" do
    test "budget limits read from Config when set" do
      AgentCom.Config.put(:hub_invocation_budgets, %{
        executing: %{max_per_hour: 50, max_per_day: 200}
      })

      stats = CostLedger.stats()
      assert stats.budgets.executing.hourly_limit == 50
      assert stats.budgets.executing.daily_limit == 200

      # Clean up
      AgentCom.Config.put(:hub_invocation_budgets, nil)
    end

    test "default budgets used when Config returns nil" do
      AgentCom.Config.put(:hub_invocation_budgets, nil)

      stats = CostLedger.stats()
      assert stats.budgets.executing.hourly_limit == 20
      assert stats.budgets.executing.daily_limit == 100
    end

    test "budget changes via Config take effect on next check_budget call" do
      # Set very low budget
      AgentCom.Config.put(:hub_invocation_budgets, %{
        executing: %{max_per_hour: 2, max_per_day: 5}
      })

      CostLedger.record_invocation(:executing, %{})
      CostLedger.record_invocation(:executing, %{})

      assert :budget_exhausted = CostLedger.check_budget(:executing)

      # Raise the limit
      AgentCom.Config.put(:hub_invocation_budgets, %{
        executing: %{max_per_hour: 50, max_per_day: 200}
      })

      # Same count, but now within budget
      assert :ok = CostLedger.check_budget(:executing)

      # Clean up
      AgentCom.Config.put(:hub_invocation_budgets, nil)
    end

    test "partial Config override merges with defaults" do
      # Only override hourly, daily should come from defaults
      AgentCom.Config.put(:hub_invocation_budgets, %{
        executing: %{max_per_hour: 99}
      })

      stats = CostLedger.stats()
      assert stats.budgets.executing.hourly_limit == 99
      # Daily should remain the default 100
      assert stats.budgets.executing.daily_limit == 100

      # Clean up
      AgentCom.Config.put(:hub_invocation_budgets, nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  describe "telemetry" do
    test "record_invocation emits [:agent_com, :hub, :claude_call] event" do
      test_pid = self()
      ref = make_ref()

      handler_id = "test-claude-call-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:agent_com, :hub, :claude_call],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, ref, event_name, measurements, metadata})
        end,
        nil
      )

      CostLedger.record_invocation(:executing, %{duration_ms: 1500, prompt_type: :decompose})

      assert_receive {:telemetry_event, ^ref, [:agent_com, :hub, :claude_call], measurements, metadata}, 1000

      assert measurements.duration_ms == 1500
      assert measurements.count == 1
      assert metadata.hub_state == :executing
      assert metadata.prompt_type == :decompose

      :telemetry.detach(handler_id)
    end

    test "check_budget emits [:agent_com, :hub, :budget_exhausted] when budget exhausted" do
      test_pid = self()
      ref = make_ref()

      handler_id = "test-budget-exhausted-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:agent_com, :hub, :budget_exhausted],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, ref, event_name, measurements, metadata})
        end,
        nil
      )

      # Exhaust budget
      for _ <- 1..20 do
        CostLedger.record_invocation(:executing, %{})
      end

      CostLedger.check_budget(:executing)

      assert_receive {:telemetry_event, ^ref, [:agent_com, :hub, :budget_exhausted], _measurements, metadata}, 1000

      assert metadata.hub_state == :executing
      assert is_integer(metadata.hourly_count)
      assert is_integer(metadata.daily_count)

      :telemetry.detach(handler_id)
    end

    test "check_budget does NOT emit budget_exhausted when budget is ok" do
      test_pid = self()
      ref = make_ref()

      handler_id = "test-no-exhaustion-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:agent_com, :hub, :budget_exhausted],
        fn _event_name, _measurements, _metadata, _config ->
          send(test_pid, {:unexpected_exhaustion, ref})
        end,
        nil
      )

      CostLedger.check_budget(:executing)

      refute_receive {:unexpected_exhaustion, ^ref}, 200

      :telemetry.detach(handler_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp restart_cost_ledger do
    # Stop CostLedger
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.CostLedger)
    # Force close the DETS table so restart can reopen with correct path
    :dets.close(:cost_ledger)
    # Restart CostLedger
    Supervisor.restart_child(AgentCom.Supervisor, AgentCom.CostLedger)
    # Small delay to let init complete
    Process.sleep(50)
  end
end
