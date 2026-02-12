defmodule Smoke.FailureTest do
  @moduledoc """
  TEST-02: Failure recovery validation.

  Verifies that when an agent is killed mid-task:
  - The task is reclaimed via AgentFSM :DOWN handler
  - The surviving agent picks up and completes the task
  - No duplicate completions occur
  - No tasks are lost
  """

  use ExUnit.Case, async: false
  @moduletag :smoke

  setup do
    # Clean slate
    Smoke.Setup.reset_all()

    agent_ids = ["smoke-victim", "smoke-survivor"]
    submitter_id = "smoke-failure-submitter"

    agent_tokens = Smoke.Setup.create_test_tokens(agent_ids)
    submitter_tokens = Smoke.Setup.create_test_tokens([submitter_id])
    submitter_token = submitter_tokens[submitter_id]

    on_exit(fn ->
      Smoke.Setup.cleanup_agents(agent_ids ++ [submitter_id])
    end)

    %{
      agent_ids: agent_ids,
      agent_tokens: agent_tokens,
      submitter_token: submitter_token
    }
  end

  @tag timeout: 120_000
  test "TEST-02: killed agent's task reclaimed and completed by survivor", ctx do
    # 1. Start agent1 (victim) with delay behavior -- accepts but delays completion
    {:ok, agent1} =
      Smoke.AgentSim.start_link(
        agent_id: "smoke-victim",
        token: ctx.agent_tokens["smoke-victim"],
        on_task_assign: {:delay, 10_000}
      )

    # 2. Start agent2 (survivor) with immediate complete behavior
    {:ok, agent2} =
      Smoke.AgentSim.start_link(
        agent_id: "smoke-survivor",
        token: ctx.agent_tokens["smoke-survivor"],
        on_task_assign: :complete
      )

    # 3. Wait for both identified
    Smoke.Assertions.wait_for(fn -> Smoke.AgentSim.identified?(agent1) end, timeout: 15_000)
    Smoke.Assertions.wait_for(fn -> Smoke.AgentSim.identified?(agent2) end, timeout: 15_000)

    # 4. Submit 1 task via HTTP
    {:ok, body} = Smoke.Http.submit_task("Failure recovery test task", ctx.submitter_token)
    task_id = body["task_id"]
    assert task_id, "Expected task_id in response"

    # 5. Wait for agent1 to receive the task
    Smoke.Assertions.wait_for(
      fn -> length(Smoke.AgentSim.received_tasks(agent1)) > 0 end,
      timeout: 15_000
    )

    # 6. Kill agent1's connection abruptly (no clean close frame)
    Smoke.AgentSim.kill_connection(agent1)

    # 7. Wait for the task to complete via agent2
    #    AgentFSM :DOWN -> reclaim_task -> task_reclaimed PubSub -> Scheduler reassigns
    #    Use 60s timeout to account for monitor detection + reassignment
    Smoke.Assertions.assert_task_completed(task_id, timeout: 60_000)

    # 8. Verify task completed exactly once
    {:ok, task} = AgentCom.TaskQueue.get(task_id)
    assert task.status == :completed, "Task expected :completed, got #{task.status}"

    # 9. Verify no duplicates: count completion events in history
    completion_events =
      task.history
      |> Enum.filter(fn
        {:completed, _ts, _details} -> true
        _ -> false
      end)

    assert length(completion_events) == 1,
           "Expected exactly 1 completion event, got #{length(completion_events)}"

    # 10. Verify agent2 was the completer
    assert Smoke.AgentSim.completed_count(agent2) == 1,
           "Survivor agent should have completed exactly 1 task"

    # Cleanup
    Smoke.AgentSim.stop(agent2)
    safe_stop(agent1)
  end

  @tag timeout: 120_000
  test "TEST-02b: multiple tasks, one agent killed, all complete", ctx do
    task_count = 5

    # 1. Start 2 agents
    {:ok, agent1} =
      Smoke.AgentSim.start_link(
        agent_id: "smoke-victim",
        token: ctx.agent_tokens["smoke-victim"],
        on_task_assign: {:delay, 5_000}
      )

    {:ok, agent2} =
      Smoke.AgentSim.start_link(
        agent_id: "smoke-survivor",
        token: ctx.agent_tokens["smoke-survivor"],
        on_task_assign: :complete
      )

    Smoke.Assertions.wait_for(fn -> Smoke.AgentSim.identified?(agent1) end, timeout: 15_000)
    Smoke.Assertions.wait_for(fn -> Smoke.AgentSim.identified?(agent2) end, timeout: 15_000)

    # 2. Submit 5 tasks
    task_ids =
      for n <- 1..task_count do
        {:ok, body} = Smoke.Http.submit_task("Multi-failure test #{n}", ctx.submitter_token)
        body["task_id"]
      end

    # 3. Wait for at least 1 task to be assigned to agent1
    Smoke.Assertions.wait_for(
      fn -> length(Smoke.AgentSim.received_tasks(agent1)) > 0 end,
      timeout: 15_000
    )

    # 4. Kill agent1
    Smoke.AgentSim.kill_connection(agent1)

    # 5. Assert all 5 tasks complete (some via agent1 before kill, rest via agent2 after recovery)
    Smoke.Assertions.assert_all_completed(task_ids, timeout: 60_000)

    # 6. Assert no duplicate completions -- each task completed exactly once
    for task_id <- task_ids do
      {:ok, task} = AgentCom.TaskQueue.get(task_id)
      assert task.status == :completed, "Task #{task_id} not completed: #{task.status}"

      completion_events =
        task.history
        |> Enum.filter(fn
          {:completed, _ts, _details} -> true
          _ -> false
        end)

      assert length(completion_events) == 1,
             "Task #{task_id} has #{length(completion_events)} completion events (expected 1)"
    end

    # 7. Verify total completed across both agents equals task count
    agent1_completed = Smoke.AgentSim.completed_count(agent1)
    agent2_completed = Smoke.AgentSim.completed_count(agent2)

    assert agent1_completed + agent2_completed == task_count,
           "Total completed (#{agent1_completed} + #{agent2_completed}) should equal #{task_count}"

    # Cleanup
    Smoke.AgentSim.stop(agent2)
    safe_stop(agent1)
  end

  # Safely stop an agent sim that may have a dead connection
  defp safe_stop(pid) do
    try do
      Smoke.AgentSim.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end
end
