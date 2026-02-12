defmodule AgentCom.Validation.ViolationTrackerTest do
  use ExUnit.Case, async: false

  alias AgentCom.Validation.ViolationTracker

  setup do
    # Use unique agent_id per test to avoid cross-test interference
    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Ensure ETS table exists (created in application.ex, but guard for test env)
    try do
      :ets.new(:validation_backoff, [:named_table, :public, :set])
    catch
      :error, :badarg -> :ok
    end

    on_exit(fn ->
      ViolationTracker.clear_backoff(agent_id)
    end)

    {:ok, agent_id: agent_id}
  end

  # ===========================================================================
  # 1. Per-connection violation tracking
  # ===========================================================================

  describe "per-connection violation tracking" do
    test "track_violation increments count" do
      state = %{violation_count: 0, violation_window_start: nil}
      new_state = ViolationTracker.track_violation(state)
      assert new_state.violation_count == 1
      assert is_integer(new_state.violation_window_start)
    end

    test "track_violation resets after window expires" do
      # Set window_start to > 60s ago
      old_time = System.system_time(:millisecond) - 61_000

      state = %{violation_count: 5, violation_window_start: old_time}
      new_state = ViolationTracker.track_violation(state)

      # Should reset to 1, not increment from 5
      assert new_state.violation_count == 1
      assert new_state.violation_window_start > old_time
    end

    test "should_disconnect? returns false under threshold" do
      state = %{violation_count: 9}
      refute ViolationTracker.should_disconnect?(state)
    end

    test "should_disconnect? returns true at threshold" do
      state = %{violation_count: 10}
      assert ViolationTracker.should_disconnect?(state)
    end

    test "should_disconnect? returns true above threshold" do
      state = %{violation_count: 15}
      assert ViolationTracker.should_disconnect?(state)
    end
  end

  # ===========================================================================
  # 2. Cross-connection backoff (ETS)
  # ===========================================================================

  describe "cross-connection backoff" do
    test "check_backoff returns :ok for unknown agent", %{agent_id: agent_id} do
      assert :ok = ViolationTracker.check_backoff(agent_id)
    end

    test "record_disconnect creates entry", %{agent_id: agent_id} do
      assert :ok = ViolationTracker.record_disconnect(agent_id)

      # Entry should exist in ETS
      assert [{^agent_id, 1, _ts}] = :ets.lookup(:validation_backoff, agent_id)
    end

    test "check_backoff returns cooldown after disconnect", %{agent_id: agent_id} do
      ViolationTracker.record_disconnect(agent_id)

      # Should be in cooldown (30s for first disconnect)
      assert {:cooldown, remaining} = ViolationTracker.check_backoff(agent_id)
      assert remaining > 0
      assert remaining <= 31
    end

    test "backoff escalates on repeated disconnects", %{agent_id: agent_id} do
      # 1st disconnect = 30s cooldown
      ViolationTracker.record_disconnect(agent_id)
      assert {:cooldown, r1} = ViolationTracker.check_backoff(agent_id)
      assert r1 <= 31

      # 2nd disconnect = 60s cooldown
      ViolationTracker.record_disconnect(agent_id)
      assert {:cooldown, r2} = ViolationTracker.check_backoff(agent_id)
      assert r2 > 31
      assert r2 <= 61

      # 3rd disconnect = 300s cooldown (5 min)
      ViolationTracker.record_disconnect(agent_id)
      assert {:cooldown, r3} = ViolationTracker.check_backoff(agent_id)
      assert r3 > 61
      assert r3 <= 301
    end

    test "clear_backoff removes entry", %{agent_id: agent_id} do
      ViolationTracker.record_disconnect(agent_id)
      assert {:cooldown, _} = ViolationTracker.check_backoff(agent_id)

      ViolationTracker.clear_backoff(agent_id)
      assert :ok = ViolationTracker.check_backoff(agent_id)
    end

    test "backoff_remaining returns 0 for unknown agent", %{agent_id: agent_id} do
      assert 0 == ViolationTracker.backoff_remaining(agent_id)
    end

    test "backoff_remaining returns seconds for agent in cooldown", %{agent_id: agent_id} do
      ViolationTracker.record_disconnect(agent_id)
      remaining = ViolationTracker.backoff_remaining(agent_id)
      assert remaining > 0
    end
  end
end
