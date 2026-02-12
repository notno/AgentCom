defmodule AgentCom.Integration.TaskLifecycleTest do
  @moduledoc """
  Integration tests for the full task pipeline happy path.

  Tests that tasks flow correctly through:
  submit -> schedule -> assign -> accept -> complete

  Uses real Scheduler, TaskQueue, AgentFSM, and Presence -- no mocks.
  DETS isolation via DetsHelpers ensures test independence.
  """

  use ExUnit.Case, async: false

  alias AgentCom.TestFactory
  alias AgentCom.TaskQueue

  setup do
    tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()

    on_exit(fn ->
      AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "full lifecycle" do
    test "submit -> schedule -> assign -> accept -> complete" do
      # 1. Create an idle agent with capabilities
      agent = TestFactory.create_agent(capabilities: ["code"])

      # 2. Subscribe to PubSub "tasks" topic BEFORE submitting (Pitfall #7)
      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      # 3. Submit a task
      {:ok, task} = TestFactory.submit_task(
        description: "lifecycle integration test",
        needed_capabilities: []
      )

      # 4. Wait for Scheduler to assign -- it reacts to :task_submitted PubSub event
      #    The Scheduler calls try_schedule_all which finds idle agents and assigns
      assert_receive {:task_event, %{event: :task_assigned, task_id: task_id}}, 5_000
      assert task_id == task.id

      # 5. Verify task status is now :assigned via TaskQueue.get
      {:ok, assigned_task} = TaskQueue.get(task.id)
      assert assigned_task.status == :assigned

      # 6. Verify task is assigned to the correct agent
      assert assigned_task.assigned_to == agent.agent_id

      # 7. Complete the task via TaskQueue.complete_task with correct generation
      {:ok, completed_task} = TaskQueue.complete_task(
        task.id,
        assigned_task.generation,
        %{result: %{"status" => "success"}}
      )

      # 8. Verify task status is :completed
      assert completed_task.status == :completed

      # 9. Verify via a fresh get
      {:ok, final_task} = TaskQueue.get(task.id)
      assert final_task.status == :completed
      assert final_task.result == %{"status" => "success"}

      # 10. Clean up
      TestFactory.cleanup_agent(agent)
    end

    test "task with capabilities matches only capable agents" do
      # 1. Create agent-a with capabilities=["code"]
      agent_a = TestFactory.create_agent(
        agent_id: "cap-agent-code",
        capabilities: ["code"]
      )

      # 2. Create agent-b with capabilities=["review"]
      agent_b = TestFactory.create_agent(
        agent_id: "cap-agent-review",
        capabilities: ["review"]
      )

      # 3. Subscribe to task events
      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

      # 4. Submit task with needed_capabilities=["code"]
      {:ok, task} = TestFactory.submit_task(
        description: "capability matching test",
        needed_capabilities: ["code"]
      )

      # 5. Wait for assignment
      assert_receive {:task_event, %{event: :task_assigned, task_id: task_id}}, 5_000
      assert task_id == task.id

      # 6. Verify task assigned to agent-a (not agent-b)
      {:ok, assigned_task} = TaskQueue.get(task.id)
      assert assigned_task.assigned_to == "cap-agent-code"

      # 7. Clean up both agents
      TestFactory.cleanup_agent(agent_a)
      TestFactory.cleanup_agent(agent_b)
    end
  end
end
