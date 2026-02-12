defmodule AgentCom.AgentFSMTest do
  @moduledoc """
  Deep unit tests for the AgentFSM GenServer.

  Covers: init state, get_state, task assignment, acceptance, completion,
  failure, ws_pid DOWN cleanup, acceptance timeout, blocked/unblocked,
  and invalid transitions.

  The Scheduler is stopped during setup to prevent interference.
  A dummy ws_pid is spawned for each agent to satisfy the process monitor requirement.
  """

  use ExUnit.Case, async: false

  alias AgentCom.{AgentFSM, AgentSupervisor, TaskQueue, TestFactory}

  setup do
    tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.Scheduler)

    on_exit(fn ->
      Supervisor.restart_child(AgentCom.Supervisor, AgentCom.Scheduler)
      AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  # Helper to create a simple agent without going through full TestFactory
  # (TestFactory registers in Presence and AgentRegistry, which we may not always want)
  defp start_agent(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "fsm-test-#{:erlang.unique_integer([:positive])}")
    capabilities = Keyword.get(opts, :capabilities, [])
    ws_pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, fsm_pid} =
      AgentSupervisor.start_agent(
        agent_id: agent_id,
        ws_pid: ws_pid,
        name: "test-#{agent_id}",
        capabilities: capabilities
      )

    %{agent_id: agent_id, ws_pid: ws_pid, fsm_pid: fsm_pid}
  end

  defp cleanup_agent(%{ws_pid: ws_pid}) do
    if Process.alive?(ws_pid), do: Process.exit(ws_pid, :kill)
    Process.sleep(100)
  end

  # ---------------------------------------------------------------------------
  # Init
  # ---------------------------------------------------------------------------

  describe "init" do
    test "FSM starts in :idle state with correct capabilities" do
      agent = start_agent(capabilities: ["code", "review"])

      {:ok, state} = AgentFSM.get_state(agent.agent_id)

      assert state.fsm_state == :idle
      assert state.capabilities == [%{name: "code"}, %{name: "review"}]
      assert state.current_task_id == nil
      assert state.agent_id == agent.agent_id

      cleanup_agent(agent)
    end

    test "FSM starts with empty capabilities by default" do
      agent = start_agent()

      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      assert state.capabilities == []

      cleanup_agent(agent)
    end

    test "FSM sets connected_at and last_state_change timestamps" do
      before = System.system_time(:millisecond)
      agent = start_agent()
      {:ok, state} = AgentFSM.get_state(agent.agent_id)

      assert state.connected_at >= before
      assert state.last_state_change >= before

      cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Get state
  # ---------------------------------------------------------------------------

  describe "get_state/1" do
    test "returns {:ok, map} with expected fields" do
      agent = start_agent(capabilities: ["test"])

      {:ok, state} = AgentFSM.get_state(agent.agent_id)

      assert Map.has_key?(state, :agent_id)
      assert Map.has_key?(state, :fsm_state)
      assert Map.has_key?(state, :current_task_id)
      assert Map.has_key?(state, :capabilities)
      assert Map.has_key?(state, :flags)
      assert Map.has_key?(state, :connected_at)
      assert Map.has_key?(state, :last_state_change)

      cleanup_agent(agent)
    end

    test "returns {:error, :not_found} for nonexistent agent" do
      assert {:error, :not_found} = AgentFSM.get_state("no-such-agent")
    end
  end

  # ---------------------------------------------------------------------------
  # Task assignment (idle -> assigned)
  # ---------------------------------------------------------------------------

  describe "assign_task/2" do
    test "transitions idle -> assigned" do
      agent = start_agent()

      # assign_task is a cast, so we need to wait for it to process
      AgentFSM.assign_task(agent.agent_id, "task-123")
      Process.sleep(50)

      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      assert state.fsm_state == :assigned
      assert state.current_task_id == "task-123"

      cleanup_agent(agent)
    end

    test "returns {:error, :not_found} for nonexistent agent" do
      assert {:error, :not_found} = AgentFSM.assign_task("no-agent", "task-1")
    end
  end

  # ---------------------------------------------------------------------------
  # Task acceptance (assigned -> working)
  # ---------------------------------------------------------------------------

  describe "task_accepted/2" do
    test "transitions assigned -> working" do
      agent = start_agent()

      AgentFSM.assign_task(agent.agent_id, "task-456")
      Process.sleep(50)

      AgentFSM.task_accepted(agent.agent_id, "task-456")
      Process.sleep(50)

      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      assert state.fsm_state == :working
      assert state.current_task_id == "task-456"

      cleanup_agent(agent)
    end

    test "ignores acceptance for wrong task_id" do
      agent = start_agent()

      AgentFSM.assign_task(agent.agent_id, "task-right")
      Process.sleep(50)

      AgentFSM.task_accepted(agent.agent_id, "task-wrong")
      Process.sleep(50)

      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      # Should still be :assigned, not :working
      assert state.fsm_state == :assigned

      cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Task completion (working -> idle)
  # ---------------------------------------------------------------------------

  describe "task_completed/1" do
    test "transitions working -> idle and clears current_task_id" do
      agent = start_agent()

      AgentFSM.assign_task(agent.agent_id, "task-comp")
      Process.sleep(50)
      AgentFSM.task_accepted(agent.agent_id, "task-comp")
      Process.sleep(50)
      AgentFSM.task_completed(agent.agent_id)
      Process.sleep(50)

      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      assert state.fsm_state == :idle
      assert state.current_task_id == nil

      cleanup_agent(agent)
    end

    test "ignores completion when not in :working state" do
      agent = start_agent()

      # Agent is :idle, task_completed should be ignored
      AgentFSM.task_completed(agent.agent_id)
      Process.sleep(50)

      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      assert state.fsm_state == :idle

      cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Task failure (working -> idle)
  # ---------------------------------------------------------------------------

  describe "task_failed/1" do
    test "transitions working -> idle and clears current_task_id" do
      agent = start_agent()

      AgentFSM.assign_task(agent.agent_id, "task-fail")
      Process.sleep(50)
      AgentFSM.task_accepted(agent.agent_id, "task-fail")
      Process.sleep(50)
      AgentFSM.task_failed(agent.agent_id)
      Process.sleep(50)

      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      assert state.fsm_state == :idle
      assert state.current_task_id == nil

      cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Blocked / Unblocked
  # ---------------------------------------------------------------------------

  describe "task_blocked/1 and task_unblocked/1" do
    test "transitions working -> blocked -> working" do
      agent = start_agent()

      # Move to working
      AgentFSM.assign_task(agent.agent_id, "task-block")
      Process.sleep(50)
      AgentFSM.task_accepted(agent.agent_id, "task-block")
      Process.sleep(50)

      # Block
      AgentFSM.task_blocked(agent.agent_id)
      Process.sleep(50)
      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      assert state.fsm_state == :blocked

      # Unblock
      AgentFSM.task_unblocked(agent.agent_id)
      Process.sleep(50)
      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      assert state.fsm_state == :working

      cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # WebSocket disconnect (:DOWN handler)
  # ---------------------------------------------------------------------------

  describe "ws_pid DOWN" do
    test "killing ws_pid causes FSM to stop (transition to :offline)" do
      agent = start_agent()

      # Verify FSM is alive
      assert {:ok, _state} = AgentFSM.get_state(agent.agent_id)

      # Kill the ws_pid
      Process.exit(agent.ws_pid, :kill)
      Process.sleep(200)

      # FSM should be gone (stopped with :normal)
      assert {:error, :not_found} = AgentFSM.get_state(agent.agent_id)
    end

    test "ws_pid DOWN reclaims assigned task back to queue" do
      agent = start_agent()

      # Submit and assign a real task through TaskQueue
      {:ok, task} = TaskQueue.submit(%{description: "reclaim on disconnect"})
      {:ok, assigned} = TaskQueue.assign_task(task.id, agent.agent_id)
      assert assigned.status == :assigned

      # Tell FSM about the assignment
      AgentFSM.assign_task(agent.agent_id, task.id)
      Process.sleep(50)

      # Kill ws_pid to trigger :DOWN
      Process.exit(agent.ws_pid, :kill)
      Process.sleep(200)

      # Task should be reclaimed back to :queued
      {:ok, reclaimed} = TaskQueue.get(task.id)
      assert reclaimed.status == :queued
      assert reclaimed.assigned_to == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance timeout
  # ---------------------------------------------------------------------------

  describe "acceptance timeout" do
    test "timeout reclaims task and sets :unresponsive flag" do
      agent = start_agent()

      # Submit and assign a real task
      {:ok, task} = TaskQueue.submit(%{description: "timeout test"})
      {:ok, _assigned} = TaskQueue.assign_task(task.id, agent.agent_id)

      # Assign via FSM (starts the acceptance timer)
      AgentFSM.assign_task(agent.agent_id, task.id)
      Process.sleep(50)

      {:ok, state_before} = AgentFSM.get_state(agent.agent_id)
      assert state_before.fsm_state == :assigned

      # Send acceptance_timeout directly (don't wait 60s)
      [{fsm_pid, _}] = Registry.lookup(AgentCom.AgentFSMRegistry, agent.agent_id)
      send(fsm_pid, {:acceptance_timeout, task.id})
      Process.sleep(100)

      # FSM should transition back to :idle with :unresponsive flag
      {:ok, state_after} = AgentFSM.get_state(agent.agent_id)
      assert state_after.fsm_state == :idle
      assert state_after.current_task_id == nil
      assert :unresponsive in state_after.flags

      # Task should be reclaimed
      {:ok, reclaimed} = TaskQueue.get(task.id)
      assert reclaimed.status == :queued

      cleanup_agent(agent)
    end

    test "stale acceptance_timeout (wrong task_id) is ignored" do
      agent = start_agent()

      AgentFSM.assign_task(agent.agent_id, "task-current")
      Process.sleep(50)

      [{fsm_pid, _}] = Registry.lookup(AgentCom.AgentFSMRegistry, agent.agent_id)
      send(fsm_pid, {:acceptance_timeout, "task-stale"})
      Process.sleep(50)

      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      # Should still be assigned (timeout was for wrong task)
      assert state.fsm_state == :assigned
      assert state.current_task_id == "task-current"

      cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # List all
  # ---------------------------------------------------------------------------

  describe "list_all/0" do
    test "returns all active FSM states" do
      agent1 = start_agent(agent_id: "list-1")
      agent2 = start_agent(agent_id: "list-2")

      all = AgentFSM.list_all()
      ids = Enum.map(all, & &1.agent_id)

      assert "list-1" in ids
      assert "list-2" in ids

      cleanup_agent(agent1)
      cleanup_agent(agent2)
    end
  end

  # ---------------------------------------------------------------------------
  # Capabilities
  # ---------------------------------------------------------------------------

  describe "get_capabilities/1" do
    test "returns normalized capabilities" do
      agent = start_agent(capabilities: ["code", "review"])

      {:ok, caps} = AgentFSM.get_capabilities(agent.agent_id)
      assert caps == [%{name: "code"}, %{name: "review"}]

      cleanup_agent(agent)
    end

    test "returns {:error, :not_found} for nonexistent agent" do
      assert {:error, :not_found} = AgentFSM.get_capabilities("no-agent")
    end
  end
end
