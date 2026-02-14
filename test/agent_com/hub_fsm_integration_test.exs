defmodule AgentCom.HubFSMIntegrationTest do
  @moduledoc """
  Integration tests for HubFSM covering all 5 states, full cycles,
  healing behavior, cooldown, and watchdog timeout.

  NOT async -- uses named GenServers and ETS tables.

  Note: force_transition to :improving, :healing, or :contemplating spawns
  async Tasks (SelfImprovement, Healing, Contemplation) that make HTTP calls.
  These Tasks run independently and may take seconds to complete. To avoid
  GenServer mailbox interference, we use a longer call timeout and explicit
  waits where needed.
  """

  use ExUnit.Case, async: false

  alias AgentCom.HubFSM
  alias AgentCom.HubFSM.{History, Predicates, HealingHistory}
  alias AgentCom.GoalBacklog
  alias AgentCom.TestHelpers.DetsHelpers

  # Longer timeout for GenServer calls since transitions may trigger
  # async tasks that interact with other GenServers
  @call_timeout 15_000

  setup do
    tmp_dir = DetsHelpers.full_test_setup()

    # Stop any existing HubFSM from the supervision tree
    try do
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.HubFSM)
    catch
      :exit, _ -> :ok
    end

    # Wait for any lingering async tasks from prior tests to settle
    Process.sleep(500)

    # Clear any leftover history entries
    History.init_table()
    History.clear()
    HealingHistory.init_table()
    HealingHistory.clear()

    # Start HubFSM fresh under the supervisor
    {:ok, _pid} = Supervisor.restart_child(AgentCom.Supervisor, AgentCom.HubFSM)

    # Verify HubFSM is responsive
    _ = HubFSM.get_state()

    on_exit(fn ->
      try do
        Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.HubFSM)
      catch
        :exit, _ -> :ok
      end

      DetsHelpers.full_test_teardown(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # Helper: force_transition with longer timeout
  defp force_transition!(new_state, reason) do
    :ok = GenServer.call(HubFSM, {:force_transition, new_state, reason}, @call_timeout)
  end

  # ---------------------------------------------------------------------------
  # FSM full cycle tests
  # ---------------------------------------------------------------------------

  describe "FSM full cycles" do
    test "resting -> executing -> resting cycle with goal submission" do
      pid = Process.whereis(HubFSM)
      assert HubFSM.get_state().fsm_state == :resting
      initial_cycles = HubFSM.get_state().cycle_count

      # Submit a goal to trigger executing transition
      {:ok, goal} =
        GoalBacklog.submit(%{
          description: "Integration test goal",
          success_criteria: "FSM transitions to executing"
        })

      send(pid, :tick)
      Process.sleep(100)

      state = HubFSM.get_state()
      assert state.fsm_state == :executing
      assert state.cycle_count == initial_cycles + 1

      # Delete goal so no pending/active goals remain
      GoalBacklog.delete(goal.id)

      send(pid, :tick)
      Process.sleep(100)

      assert HubFSM.get_state().fsm_state == :resting

      # Verify history recorded both transitions
      entries = HubFSM.history()
      reasons = Enum.map(entries, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "pending goals"))
      assert Enum.any?(reasons, &String.contains?(&1, "no pending"))
    end

    test "resting -> improving -> contemplating -> resting via messages" do
      pid = Process.whereis(HubFSM)
      initial_cycles = HubFSM.get_state().cycle_count

      # Force into improving state (spawns SelfImprovement task)
      force_transition!(:improving, "test improvement cycle")
      state = HubFSM.get_state()
      assert state.fsm_state == :improving
      assert state.cycle_count == initial_cycles + 1

      # Simulate improvement cycle completing with no findings
      # With no findings and contemplating budget available (fresh DETS = :ok),
      # should transition to :contemplating
      send(pid, {:improvement_cycle_complete, {:ok, %{findings: 0}}})
      Process.sleep(200)

      state = HubFSM.get_state()
      # If contemplating budget is available, should be :contemplating
      if state.fsm_state == :contemplating do
        # Complete the contemplation cycle
        send(pid, {:contemplation_cycle_complete, %{}})
        Process.sleep(200)
        assert HubFSM.get_state().fsm_state == :resting
      else
        assert state.fsm_state == :resting
      end
    end

    test "resting -> improving -> executing when goals arrive during improvement" do
      pid = Process.whereis(HubFSM)

      # Force into improving state
      force_transition!(:improving, "test goal arrival")
      assert HubFSM.get_state().fsm_state == :improving

      # Submit a goal while improving
      {:ok, goal} =
        GoalBacklog.submit(%{
          description: "Urgent goal during improvement",
          success_criteria: "Forces transition to executing"
        })

      # Improvement completes -- should detect pending goals and go to executing
      send(pid, {:improvement_cycle_complete, {:ok, %{findings: 1}}})
      Process.sleep(200)

      assert HubFSM.get_state().fsm_state == :executing

      # Cleanup: delete goal and return to resting
      GoalBacklog.delete(goal.id)
      send(pid, :tick)
      Process.sleep(100)
      assert HubFSM.get_state().fsm_state == :resting
    end

    test "transition_count increments on every transition" do
      initial = HubFSM.get_state().transition_count

      # Use executing (no async task spawned) for simple counting
      force_transition!(:executing, "count test 1")
      assert HubFSM.get_state().transition_count == initial + 1

      force_transition!(:resting, "count test 2")
      assert HubFSM.get_state().transition_count == initial + 2
    end

    test "history records all transitions with correct from/to/reason" do
      Process.sleep(5)
      force_transition!(:executing, "history test exec")
      Process.sleep(5)
      force_transition!(:resting, "history test rest")

      entries = HubFSM.history()
      assert length(entries) >= 3

      # Most recent is resting
      [latest | _] = entries
      assert latest.from == :executing
      assert latest.to == :resting
      assert latest.reason == "history test rest"

      # Second most recent is executing
      exec_entry = Enum.find(entries, fn e -> e.reason == "history test exec" end)
      assert exec_entry.from == :resting
      assert exec_entry.to == :executing
    end
  end

  # ---------------------------------------------------------------------------
  # Healing state tests
  # ---------------------------------------------------------------------------

  describe "healing state" do
    test "force_transition to healing and exit via healing_cycle_complete" do
      pid = Process.whereis(HubFSM)

      force_transition!(:healing, "test healing entry")
      assert HubFSM.get_state().fsm_state == :healing

      # Simulate healing completion
      send(pid, {:healing_cycle_complete, %{issues_found: 1, actions_taken: 1}})
      Process.sleep(200)

      assert HubFSM.get_state().fsm_state == :resting

      # Verify history recorded both transitions
      entries = HubFSM.history()
      healing_entry = Enum.find(entries, fn e -> e.to == :healing end)
      assert healing_entry != nil
      assert healing_entry.reason == "test healing entry"
    end

    test "healing cooldown prevents re-entry via predicates" do
      # Build system state with critical issues but cooldown active
      system_state = %{
        pending_goals: 0,
        active_goals: 0,
        budget_exhausted: false,
        improving_budget_available: false,
        contemplating_budget_available: false,
        health_report: %{critical_count: 5},
        healing_cooldown_active: true,
        healing_attempts_exhausted: false
      }

      # With cooldown active, should stay (not transition to healing)
      assert Predicates.evaluate(:resting, system_state) == :stay

      # With cooldown expired, should transition to healing
      system_state_no_cooldown = %{system_state | healing_cooldown_active: false}

      assert {:transition, :healing, _reason} =
               Predicates.evaluate(:resting, system_state_no_cooldown)
    end

    test "healing attempts exhaustion prevents re-entry via predicates" do
      system_state = %{
        pending_goals: 0,
        active_goals: 0,
        budget_exhausted: false,
        improving_budget_available: false,
        contemplating_budget_available: false,
        health_report: %{critical_count: 5},
        healing_cooldown_active: false,
        healing_attempts_exhausted: true
      }

      # With attempts exhausted, should stay
      assert Predicates.evaluate(:resting, system_state) == :stay
    end

    test "healing watchdog forces transition to resting" do
      pid = Process.whereis(HubFSM)

      force_transition!(:healing, "test watchdog")
      assert HubFSM.get_state().fsm_state == :healing

      # Send healing watchdog message directly (don't wait 5 minutes)
      send(pid, :healing_watchdog)
      Process.sleep(200)

      assert HubFSM.get_state().fsm_state == :resting

      # Verify healing history has watchdog_timeout entry
      healing_entries = HealingHistory.list()
      watchdog_entry = Enum.find(healing_entries, fn e -> e.category == :watchdog_timeout end)
      assert watchdog_entry != nil
    end

    test "healing transition from any non-healing state via predicates" do
      system_state = %{
        pending_goals: 0,
        active_goals: 0,
        budget_exhausted: false,
        improving_budget_available: false,
        contemplating_budget_available: false,
        health_report: %{critical_count: 3},
        healing_cooldown_active: false,
        healing_attempts_exhausted: false
      }

      # All non-healing states should transition to :healing with critical issues
      for state <- [:resting, :executing, :improving, :contemplating] do
        assert {:transition, :healing, _reason} = Predicates.evaluate(state, system_state),
               "Expected #{state} to transition to :healing"
      end

      # Already in healing should stay
      assert Predicates.evaluate(:healing, system_state) == :stay
    end
  end
end
