defmodule AgentCom.Integration.FailurePathsTest do
  @moduledoc """
  Integration tests for task failure paths.

  Tests retry logic, dead-letter escalation, acceptance timeout,
  and agent crash (WebSocket disconnect) during task execution.

  Uses real Scheduler, TaskQueue, AgentFSM -- no mocks.
  DETS isolation via DetsHelpers ensures test independence.

  Note: TestFactory creates agents with a dummy ws_pid (not a real Socket
  process), so the Scheduler's push_task message goes to a dummy process that
  doesn't call AgentFSM.assign_task. Where FSM state matters (acceptance
  timeout, crash tests), we explicitly call AgentFSM.assign_task after
  TaskQueue assignment to keep the FSM in sync.
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

  describe "retry and dead-letter" do
    test "failed task retries and eventually reaches dead-letter" do
      # 1. Create an idle agent
      agent = TestFactory.create_agent(capabilities: [])

      # 2. Submit task with max_retries=2 (first fail retries, second fail dead-letters)
      {:ok, task} = TestFactory.submit_task(
        description: "retry dead-letter test",
        max_retries: 2
      )

      # 3. Wait for Scheduler to assign via polling
      wait_for_status(task.id, :assigned, 5_000)

      # 4. Get the assigned task to read generation
      {:ok, assigned_task} = TaskQueue.get(task.id)
      assert assigned_task.status == :assigned
      gen1 = assigned_task.generation

      # 5. Fail the task with correct generation -> should retry
      {:ok, :retried, retried_task} = TaskQueue.fail_task(task.id, gen1, "first failure")
      assert retried_task.status == :queued
      assert retried_task.retry_count == 1

      # 6. Wait for Scheduler to re-assign
      #    The FSM stays in :idle (no Socket to call assign_task), so the
      #    Scheduler finds the agent idle and re-assigns.
      wait_for_status(task.id, :assigned, 5_000)

      # 7. Get the re-assigned task to read new generation
      {:ok, reassigned_task} = TaskQueue.get(task.id)
      assert reassigned_task.status == :assigned
      gen2 = reassigned_task.generation
      assert gen2 > gen1

      # 8. Fail again -> should dead-letter (retry_count 2 >= max_retries 2)
      {:ok, :dead_letter, dead_task} = TaskQueue.fail_task(task.id, gen2, "second failure")
      assert dead_task.status == :dead_letter
      assert dead_task.retry_count == 2

      # 9. Verify task is in dead-letter list
      dead_letters = TaskQueue.list_dead_letter()
      assert Enum.any?(dead_letters, fn t -> t.id == task.id end)

      # 10. Verify get returns dead-letter task (checks both tables)
      {:ok, found} = TaskQueue.get(task.id)
      assert found.status == :dead_letter

      # 11. Clean up
      TestFactory.cleanup_agent(agent)
    end
  end

  describe "acceptance timeout" do
    test "acceptance timeout causes task to be re-queued" do
      # 1. Create an idle agent
      agent = TestFactory.create_agent(capabilities: [])

      # 2. Submit a task
      {:ok, task} = TestFactory.submit_task(description: "timeout test")

      # 3. Wait for Scheduler to assign (via TaskQueue)
      wait_for_status(task.id, :assigned, 5_000)

      # 4. Verify task is assigned and record generation
      {:ok, assigned_task} = TaskQueue.get(task.id)
      assert assigned_task.status == :assigned
      original_generation = assigned_task.generation

      # 5. Explicitly transition FSM to :assigned so acceptance timeout works.
      AgentCom.AgentFSM.assign_task(agent.agent_id, task.id)
      Process.sleep(50)

      # 6. Send acceptance timeout directly to FSM, then immediately kill agent
      #    so Scheduler cannot re-assign before we verify.
      {:ok, fsm_pid} = find_fsm_pid(agent.agent_id)
      send(fsm_pid, {:acceptance_timeout, task.id})

      # Use get_state as a synchronization barrier -- this call returns
      # only after the FSM has processed all preceding messages (casts and
      # sends). Since acceptance_timeout is a send (info), and the FSM
      # processes messages sequentially, get_state will execute after it.
      {:ok, fsm_after} = AgentCom.AgentFSM.get_state(agent.agent_id)

      # 7. Verify FSM processed the timeout: now idle with unresponsive flag
      assert fsm_after.fsm_state == :idle
      assert :unresponsive in fsm_after.flags

      # 8. Kill agent to prevent Scheduler from re-assigning
      Process.exit(agent.ws_pid, :kill)
      Process.sleep(100)

      # 9. Verify the task was reclaimed: generation increased and history shows it
      {:ok, after_task} = TaskQueue.get(task.id)
      assert after_task.generation > original_generation

      assert Enum.any?(after_task.history, fn
        {:reclaimed, _ts, _reason} -> true
        _ -> false
      end)

      # Clean up -- agent is already gone, just revoke token
      AgentCom.Auth.revoke(agent.agent_id)
    end
  end

  describe "agent crash" do
    test "agent crash (ws_pid dies) during task execution causes task reclaim" do
      # 1. Create agent, submit task, wait for assignment
      agent = TestFactory.create_agent(capabilities: [])

      {:ok, task} = TestFactory.submit_task(description: "crash test")

      wait_for_status(task.id, :assigned, 5_000)

      # 2. Verify task is assigned and record generation
      {:ok, assigned_task} = TaskQueue.get(task.id)
      assert assigned_task.status == :assigned
      original_generation = assigned_task.generation

      # 3. Transition FSM to :assigned so it has a current_task_id for reclaim
      AgentCom.AgentFSM.assign_task(agent.agent_id, task.id)
      Process.sleep(50)

      # 4. Kill the agent's ws_pid to simulate WebSocket disconnect
      #    FSM monitors ws_pid and will handle :DOWN -> reclaim task -> stop
      Process.exit(agent.ws_pid, :kill)

      # 5. Wait for FSM to fully terminate
      wait_for_fsm_gone(agent.agent_id, 5_000)

      # 6. Verify task was reclaimed: generation increased, history shows :reclaimed
      {:ok, after_task} = TaskQueue.get(task.id)
      assert after_task.generation > original_generation

      assert Enum.any?(after_task.history, fn
        {:reclaimed, _ts, _reason} -> true
        _ -> false
      end)

      # 7. Verify the FSM is gone (it stopped after :DOWN)
      assert AgentCom.AgentFSM.get_state(agent.agent_id) == {:error, :not_found}

      # Clean up -- agent is already gone, just revoke token
      AgentCom.Auth.revoke(agent.agent_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_fsm_pid(agent_id) do
    case Registry.lookup(AgentCom.AgentFSMRegistry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp wait_for_status(task_id, expected_status, timeout) do
    deadline = System.system_time(:millisecond) + timeout
    do_poll_status(task_id, expected_status, deadline)
  end

  defp do_poll_status(task_id, expected_status, deadline) do
    if System.system_time(:millisecond) > deadline do
      {:ok, task} = TaskQueue.get(task_id)

      raise "Timeout waiting for task #{task_id} to reach status :#{expected_status}, " <>
              "current status: :#{task.status}"
    end

    case TaskQueue.get(task_id) do
      {:ok, %{status: ^expected_status}} ->
        :ok

      _ ->
        Process.sleep(50)
        do_poll_status(task_id, expected_status, deadline)
    end
  end

  defp wait_for_fsm_gone(agent_id, timeout) do
    deadline = System.system_time(:millisecond) + timeout
    do_poll_fsm_gone(agent_id, deadline)
  end

  defp do_poll_fsm_gone(agent_id, deadline) do
    if System.system_time(:millisecond) > deadline do
      raise "Timeout waiting for FSM #{agent_id} to terminate"
    end

    try do
      case AgentCom.AgentFSM.get_state(agent_id) do
        {:error, :not_found} ->
          :ok

        {:ok, _} ->
          Process.sleep(50)
          do_poll_fsm_gone(agent_id, deadline)
      end
    catch
      :exit, _ ->
        # FSM terminated mid-call — that means it's gone, which is success
        :ok
    end
  end
end
