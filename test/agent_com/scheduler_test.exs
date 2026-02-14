defmodule AgentCom.SchedulerTest do
  @moduledoc """
  Unit tests for the Scheduler GenServer.

  Covers: idle agent matching, capability filtering, no-idle-agents handling,
  empty-queue handling, multiple agents, and PubSub event verification.

  Unlike TaskQueue and AgentFSM tests, the Scheduler MUST be running here
  since we're testing its event-driven matching behavior.

  NOTE: Each test uses unique agent IDs and subscribes to PubSub BEFORE
  submitting tasks to avoid stale message leakage between tests.
  The setup drains the test process mailbox to eliminate any leftover
  PubSub messages from prior tests.
  """

  use ExUnit.Case, async: false

  alias AgentCom.{AgentFSM, TaskQueue, TestFactory}

  setup do
    # full_test_setup restarts all servers (including Scheduler) with fresh DETS data
    tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()

    # Kill any leftover FSM processes from prior tests
    DynamicSupervisor.which_children(AgentCom.AgentSupervisor)
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(AgentCom.AgentSupervisor, pid)
    end)

    # Drain any stale PubSub messages from the test process mailbox
    drain_mailbox()

    on_exit(fn ->
      AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Matching: idle agent + queued task
  # ---------------------------------------------------------------------------

  describe "idle agent matching" do
    test "submitting a task with an idle agent causes the Scheduler to assign it" do
      agent = TestFactory.create_agent(capabilities: ["code"])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      {:ok, task} = TestFactory.submit_task(description: "schedule me")

      assert_receive {:task_event, %{event: :task_assigned, task_id: task_id}}, 5_000
      assert task_id == task.id

      {:ok, assigned} = TaskQueue.get(task.id)
      assert assigned.status == :assigned
      assert assigned.assigned_to == agent.agent_id

      TestFactory.cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Capability filtering
  # ---------------------------------------------------------------------------

  describe "capability filtering" do
    test "assigns task to agent with matching capabilities" do
      agent_with_code = TestFactory.create_agent(capabilities: ["code"])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      {:ok, task} =
        TestFactory.submit_task(
          description: "needs code capability",
          needed_capabilities: ["code"]
        )

      assert_receive {:task_event, %{event: :task_assigned, task_id: task_id}}, 5_000
      assert task_id == task.id

      {:ok, assigned} = TaskQueue.get(task.id)
      assert assigned.assigned_to == agent_with_code.agent_id

      TestFactory.cleanup_agent(agent_with_code)
    end

    test "does not assign task to agent without required capabilities" do
      agent_without = TestFactory.create_agent(capabilities: ["review"])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      {:ok, task} =
        TestFactory.submit_task(
          description: "needs code, agent has review",
          needed_capabilities: ["code"]
        )

      # Wait for task_submitted, then verify no assignment follows
      assert_receive {:task_event, %{event: :task_submitted}}, 5_000
      refute_receive {:task_event, %{event: :task_assigned}}, 1_000

      {:ok, still_queued} = TaskQueue.get(task.id)
      assert still_queued.status == :queued

      TestFactory.cleanup_agent(agent_without)
    end

    test "task with empty needed_capabilities matches any agent" do
      agent = TestFactory.create_agent(capabilities: ["anything"])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      {:ok, task} =
        TestFactory.submit_task(
          description: "no caps needed",
          needed_capabilities: []
        )

      assert_receive {:task_event, %{event: :task_assigned, task_id: task_id}}, 5_000
      assert task_id == task.id

      TestFactory.cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # No idle agents
  # ---------------------------------------------------------------------------

  describe "no idle agents" do
    test "task stays :queued when no agents are registered" do
      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      {:ok, task} = TestFactory.submit_task(description: "no agents available")

      assert_receive {:task_event, %{event: :task_submitted}}, 5_000
      refute_receive {:task_event, %{event: :task_assigned}}, 1_000

      {:ok, still_queued} = TaskQueue.get(task.id)
      assert still_queued.status == :queued
    end
  end

  # ---------------------------------------------------------------------------
  # Empty queue
  # ---------------------------------------------------------------------------

  describe "empty queue" do
    test "registering agent with no tasks does not cause errors" do
      agent = TestFactory.create_agent(capabilities: ["code"])

      # Give Scheduler time to potentially react to :agent_joined
      Process.sleep(200)

      {:ok, state} = AgentFSM.get_state(agent.agent_id)
      assert state.fsm_state == :idle

      TestFactory.cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple agents
  # ---------------------------------------------------------------------------

  describe "multiple agents" do
    test "task is assigned to one of the available idle agents" do
      agent1 = TestFactory.create_agent(capabilities: ["code"])
      agent2 = TestFactory.create_agent(capabilities: ["code"])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      {:ok, task} = TestFactory.submit_task(description: "multi-agent test")

      assert_receive {:task_event, %{event: :task_assigned, task_id: task_id}}, 5_000
      assert task_id == task.id

      {:ok, assigned} = TaskQueue.get(task.id)
      assert assigned.assigned_to in [agent1.agent_id, agent2.agent_id]

      TestFactory.cleanup_agent(agent1)
      TestFactory.cleanup_agent(agent2)
    end

    test "two tasks are assigned to two different agents when FSM tracks assignment" do
      agent1 = TestFactory.create_agent(capabilities: ["code"])
      agent2 = TestFactory.create_agent(capabilities: ["code"])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      # Submit first task -- Scheduler will assign to one of the agents
      {:ok, task1} = TestFactory.submit_task(description: "task for first agent")
      assert_receive {:task_event, %{event: :task_assigned, task: assigned1}}, 5_000

      # Simulate the agent accepting the task (FSM moves to :assigned then :working)
      # This ensures the Scheduler sees the agent as non-idle on the next round
      AgentFSM.assign_task(assigned1.assigned_to, task1.id)
      Process.sleep(50)
      AgentFSM.task_accepted(assigned1.assigned_to, task1.id)
      Process.sleep(50)

      # Submit second task -- Scheduler should assign to the OTHER agent (the one still idle)
      {:ok, task2} = TestFactory.submit_task(description: "task for second agent")
      assert_receive {:task_event, %{event: :task_assigned, task: assigned2}}, 5_000

      # Verify both tasks are assigned to different agents
      assert assigned1.assigned_to != assigned2.assigned_to

      {:ok, t1} = TaskQueue.get(task1.id)
      {:ok, t2} = TaskQueue.get(task2.id)
      assert t1.status == :assigned
      assert t2.status == :assigned

      TestFactory.cleanup_agent(agent1)
      TestFactory.cleanup_agent(agent2)
    end
  end

  # ---------------------------------------------------------------------------
  # Routing decision (Phase 19)
  # ---------------------------------------------------------------------------

  describe "routing decision" do
    test "routing decision is stored on assigned task" do
      agent = TestFactory.create_agent(capabilities: ["code"])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      {:ok, task} = TestFactory.submit_task(description: "route me")

      assert_receive {:task_event, %{event: :task_assigned, task_id: task_id}}, 5_000
      assert task_id == task.id

      {:ok, assigned} = TaskQueue.get(task.id)
      assert assigned.status == :assigned
      assert assigned.routing_decision != nil
      assert is_map(assigned.routing_decision)
      assert Map.has_key?(assigned.routing_decision, :effective_tier)
      assert Map.has_key?(assigned.routing_decision, :target_type)
      assert Map.has_key?(assigned.routing_decision, :fallback_used)
      assert Map.has_key?(assigned.routing_decision, :classification_reason)
      assert Map.has_key?(assigned.routing_decision, :estimated_cost_tier)

      TestFactory.cleanup_agent(agent)
    end

    test "routing decision indicates fallback when no LLM endpoints are registered for standard task" do
      agent = TestFactory.create_agent(capabilities: ["code"])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      # Force :standard tier via explicit complexity_tier param
      # Standard tier requires Ollama endpoints; with none registered,
      # TaskRouter returns fallback and the scheduler uses capability matching
      {:ok, task} = TaskQueue.submit(%{
        description: "standard tier fallback test",
        priority: "normal",
        submitted_by: "test-submitter",
        complexity_tier: "standard"
      })

      assert_receive {:task_event, %{event: :task_assigned, task_id: task_id}}, 5_000
      assert task_id == task.id

      {:ok, assigned} = TaskQueue.get(task.id)
      # Without any LLM endpoints registered, the router returns a fallback signal
      # for :standard tier and the scheduler falls back to capability matching
      assert assigned.routing_decision.fallback_used == true

      TestFactory.cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Dependency filtering (Phase 28)
  # ---------------------------------------------------------------------------

  describe "dependency filtering (Phase 28)" do
    test "3-task dependency chain: only tasks with completed deps get scheduled" do
      agent = TestFactory.create_agent(capabilities: [])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      # Submit A (no deps), B depends on A, C depends on B
      {:ok, task_a} = TestFactory.submit_task(description: "chain task A")

      # Wait for A to be assigned (it has no deps, so scheduler should pick it up)
      assert_receive {:task_event, %{event: :task_assigned, task_id: tid_a}}, 5_000
      assert tid_a == task_a.id

      # A is now assigned. Submit B (depends on A) and C (depends on B)
      {:ok, task_b} = TestFactory.submit_task(description: "chain task B", depends_on: [task_a.id])

      # B should NOT be assigned (A not completed yet)
      assert_receive {:task_event, %{event: :task_submitted}}, 5_000
      refute_receive {:task_event, %{event: :task_assigned, task_id: ^task_b}}, 1_000

      # Complete A
      {:ok, assigned_a} = TaskQueue.get(task_a.id)
      {:ok, _completed_a} = TaskQueue.complete_task(task_a.id, assigned_a.generation, %{result: "done A"})

      # After completing A, agent becomes idle again and B's dep is satisfied
      # Simulate agent becoming idle (FSM would normally do this)
      AgentFSM.assign_task(agent.agent_id, task_a.id)
      Process.sleep(50)
      AgentFSM.task_accepted(agent.agent_id, task_a.id)
      Process.sleep(50)
      AgentFSM.task_completed(agent.agent_id)
      Process.sleep(200)

      # B should now be assigned
      assert_receive {:task_event, %{event: :task_assigned, task_id: tid_b}}, 5_000
      assert tid_b == task_b.id

      TestFactory.cleanup_agent(agent)
    end

    test "independent tasks (no depends_on) are both schedulable immediately" do
      agent1 = TestFactory.create_agent(capabilities: [])
      agent2 = TestFactory.create_agent(capabilities: [])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      {:ok, task_x} = TestFactory.submit_task(description: "independent X")
      assert_receive {:task_event, %{event: :task_assigned, task_id: tid_x}}, 5_000
      assert tid_x == task_x.id

      # Simulate first agent accepting to free up for second assignment
      {:ok, assigned_x} = TaskQueue.get(task_x.id)
      AgentFSM.assign_task(assigned_x.assigned_to, task_x.id)
      Process.sleep(50)
      AgentFSM.task_accepted(assigned_x.assigned_to, task_x.id)
      Process.sleep(50)

      {:ok, task_y} = TestFactory.submit_task(description: "independent Y")
      assert_receive {:task_event, %{event: :task_assigned, task_id: tid_y}}, 5_000
      assert tid_y == task_y.id

      TestFactory.cleanup_agent(agent1)
      TestFactory.cleanup_agent(agent2)
    end

    test "mixed independent and dependent: independent scheduled, dependent blocked" do
      agent = TestFactory.create_agent(capabilities: [])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      # Submit A (no deps) -- will be assigned immediately
      {:ok, task_a} = TestFactory.submit_task(description: "mixed task A (no deps)")
      assert_receive {:task_event, %{event: :task_assigned, task_id: tid_a}}, 5_000
      assert tid_a == task_a.id

      # Complete A so agent is free, then submit B (depends on A) and C (no deps) at once
      {:ok, assigned_a} = TaskQueue.get(task_a.id)
      {:ok, _} = TaskQueue.complete_task(task_a.id, assigned_a.generation, %{result: "done"})
      AgentFSM.assign_task(agent.agent_id, task_a.id)
      Process.sleep(50)
      AgentFSM.task_accepted(agent.agent_id, task_a.id)
      Process.sleep(50)
      AgentFSM.task_completed(agent.agent_id)
      Process.sleep(200)

      # Now submit B (dep on A, which is completed -- should be schedulable) and C (no deps)
      {:ok, task_b} = TestFactory.submit_task(description: "mixed B deps on A", depends_on: [task_a.id])

      # B should be assigned since A is completed
      assert_receive {:task_event, %{event: :task_assigned, task_id: tid_b}}, 5_000
      assert tid_b == task_b.id

      TestFactory.cleanup_agent(agent)
    end

    test "dead-lettered dependency blocks dependent task" do
      agent = TestFactory.create_agent(capabilities: [])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      # Submit task A (will be dead-lettered)
      {:ok, task_a} = TestFactory.submit_task(description: "will fail", max_retries: 1)
      assert_receive {:task_event, %{event: :task_assigned, task_id: tid_a}}, 5_000
      assert tid_a == task_a.id

      # Fail A past max retries to dead-letter it
      {:ok, assigned_a} = TaskQueue.get(task_a.id)
      {:ok, :dead_letter, _dead} = TaskQueue.fail_task(task_a.id, assigned_a.generation, "fatal")

      # Agent goes back to idle after the task is dead-lettered
      AgentFSM.assign_task(agent.agent_id, task_a.id)
      Process.sleep(50)
      AgentFSM.task_accepted(agent.agent_id, task_a.id)
      Process.sleep(50)
      AgentFSM.task_failed(agent.agent_id)
      Process.sleep(200)

      # Submit B which depends on A
      {:ok, task_b} = TestFactory.submit_task(description: "depends on dead A", depends_on: [task_a.id])

      # B should NOT be scheduled (A is dead_letter, not completed)
      assert_receive {:task_event, %{event: :task_submitted}}, 5_000
      refute_receive {:task_event, %{event: :task_assigned, task_id: _}}, 2_000

      {:ok, still_queued} = TaskQueue.get(task_b.id)
      assert still_queued.status == :queued

      TestFactory.cleanup_agent(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub event verification
  # ---------------------------------------------------------------------------

  describe "PubSub events" do
    test "task_assigned event is broadcast when Scheduler assigns" do
      agent = TestFactory.create_agent(capabilities: [])

      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      {:ok, task} = TestFactory.submit_task(description: "pubsub verification")

      assert_receive {:task_event, %{event: :task_assigned, task_id: tid, task: assigned_task}},
                     5_000

      assert tid == task.id
      assert assigned_task.assigned_to == agent.agent_id

      TestFactory.cleanup_agent(agent)
    end
  end
end
