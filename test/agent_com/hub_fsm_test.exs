defmodule AgentCom.HubFSMTest do
  @moduledoc """
  Integration tests for the HubFSM GenServer.

  Covers lifecycle, transitions, pause/resume, force_transition,
  and history recording. Uses real GoalBacklog and CostLedger GenServers
  with DETS isolation via DetsHelpers.

  NOT async -- uses named GenServers and ETS tables.
  """

  use ExUnit.Case, async: false

  alias AgentCom.HubFSM
  alias AgentCom.HubFSM.History
  alias AgentCom.GoalBacklog
  alias AgentCom.TestHelpers.DetsHelpers

  setup do
    tmp_dir = DetsHelpers.full_test_setup()

    # Stop any existing HubFSM from the supervision tree
    try do
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.HubFSM)
    catch
      :exit, _ -> :ok
    end

    # Clear any leftover history entries
    History.init_table()
    History.clear()

    # Start HubFSM fresh under the supervisor
    {:ok, _pid} = Supervisor.restart_child(AgentCom.Supervisor, AgentCom.HubFSM)

    on_exit(fn ->
      # Stop HubFSM before teardown to prevent interference.
      # Terminating HubFSM destroys the ETS table it owns, so
      # we do NOT call History.clear() after -- the table is gone.
      try do
        Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.HubFSM)
      catch
        :exit, _ -> :ok
      end

      DetsHelpers.full_test_teardown(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # Lifecycle tests
  # ---------------------------------------------------------------------------

  describe "lifecycle" do
    test "starts in :resting state" do
      state = HubFSM.get_state()
      assert state.fsm_state == :resting
    end

    test "get_state/0 returns correct initial state map" do
      state = HubFSM.get_state()

      assert state.fsm_state == :resting
      assert state.paused == false
      assert state.cycle_count == 0
      assert is_integer(state.last_state_change)
      assert is_integer(state.transition_count)
    end

    test "history/0 returns initial transition entry (nil -> :resting)" do
      entries = HubFSM.history()
      assert length(entries) >= 1

      # The initial entry should have from: nil, to: :resting
      initial = List.last(entries)
      assert initial.from == nil
      assert initial.to == :resting
      assert initial.reason == "hub_fsm_started"
    end
  end

  # ---------------------------------------------------------------------------
  # Transition tests
  # ---------------------------------------------------------------------------

  describe "transitions" do
    test "submitting a goal causes transition to :executing on tick" do
      # Verify starting in :resting
      assert HubFSM.get_state().fsm_state == :resting

      # Submit a goal to GoalBacklog
      {:ok, _goal} =
        GoalBacklog.submit(%{
          description: "Test goal for FSM transition",
          success_criteria: "Transition occurs"
        })

      # Wait for tick to evaluate (1s tick interval + margin)
      Process.sleep(2_000)

      state = HubFSM.get_state()
      assert state.fsm_state == :executing
    end

    test "transitions back to :resting when no goals remain" do
      # Submit and wait for transition to :executing
      {:ok, goal} =
        GoalBacklog.submit(%{
          description: "Temporary goal",
          success_criteria: "Will be deleted"
        })

      Process.sleep(2_000)
      assert HubFSM.get_state().fsm_state == :executing

      # Delete the goal so no pending/active goals remain
      GoalBacklog.delete(goal.id)

      # Wait for tick to detect no goals
      Process.sleep(2_000)

      assert HubFSM.get_state().fsm_state == :resting
    end

    test "cycle count increments on resting->executing transition" do
      initial_cycles = HubFSM.get_state().cycle_count

      # Force transition to executing
      :ok = HubFSM.force_transition(:executing, "test cycle count")

      state = HubFSM.get_state()
      assert state.cycle_count == initial_cycles + 1
    end
  end

  # ---------------------------------------------------------------------------
  # Pause/resume tests
  # ---------------------------------------------------------------------------

  describe "pause/resume" do
    test "pause/0 returns :ok and sets paused: true" do
      assert :ok = HubFSM.pause()
      assert HubFSM.get_state().paused == true
    end

    test "pause/0 when already paused returns {:error, :already_paused}" do
      :ok = HubFSM.pause()
      assert {:error, :already_paused} = HubFSM.pause()
    end

    test "resume/0 returns :ok and sets paused: false" do
      :ok = HubFSM.pause()
      assert :ok = HubFSM.resume()
      assert HubFSM.get_state().paused == false
    end

    test "resume/0 when not paused returns {:error, :not_paused}" do
      assert {:error, :not_paused} = HubFSM.resume()
    end

    test "while paused, no transitions occur even with pending goals" do
      # Pause first
      :ok = HubFSM.pause()

      # Submit a goal
      {:ok, _goal} =
        GoalBacklog.submit(%{
          description: "Goal while paused",
          success_criteria: "Should not trigger transition"
        })

      # Wait well past tick interval
      Process.sleep(2_500)

      # Should still be resting (paused prevents evaluation)
      state = HubFSM.get_state()
      assert state.fsm_state == :resting
      assert state.paused == true
    end
  end

  # ---------------------------------------------------------------------------
  # Force transition tests
  # ---------------------------------------------------------------------------

  describe "force_transition/2" do
    test "with valid transition succeeds" do
      assert :ok = HubFSM.force_transition(:executing, "admin override")
      assert HubFSM.get_state().fsm_state == :executing

      assert :ok = HubFSM.force_transition(:resting, "admin reset")
      assert HubFSM.get_state().fsm_state == :resting
    end

    test "with invalid transition returns error" do
      # resting -> resting is not a valid transition
      assert {:error, :invalid_transition} =
               HubFSM.force_transition(:resting, "invalid same-state")
    end
  end

  # ---------------------------------------------------------------------------
  # History tests
  # ---------------------------------------------------------------------------

  describe "history" do
    test "transitions are recorded with correct from/to/reason" do
      # Small delay to ensure forced transition has a later timestamp than init
      Process.sleep(5)
      :ok = HubFSM.force_transition(:executing, "test history")

      entries = HubFSM.history()
      # Should have at least 2: initial (nil->resting) and our forced transition
      assert length(entries) >= 2

      # Most recent entry (highest transition_number) should be our forced transition
      [latest | _rest] = entries
      assert latest.from == :resting
      assert latest.to == :executing
      assert latest.reason == "test history"
    end

    test "history returns entries in newest-first order" do
      # Ensure distinct timestamps between each transition
      Process.sleep(5)
      :ok = HubFSM.force_transition(:executing, "first")
      Process.sleep(5)
      :ok = HubFSM.force_transition(:resting, "second")

      entries = HubFSM.history()
      timestamps = Enum.map(entries, & &1.timestamp)

      # Should be strictly descending by timestamp (newest first)
      assert timestamps == Enum.sort(timestamps, :desc)

      # Most recent entry should be the "second" transition
      [latest | _] = entries
      assert latest.reason == "second"
      assert latest.to == :resting
    end
  end
end
