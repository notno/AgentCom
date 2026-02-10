defmodule Smoke.BasicTest do
  @moduledoc """
  TEST-01: Basic pipeline validation.

  Verifies that 10 trivial tasks complete across 2 simulated agents with:
  - 10/10 success rate
  - Assignment latency under 5 seconds per task
  - Token overhead under 500 per task
  - Both agents participate in task completion
  """

  use ExUnit.Case, async: false

  @task_count 10

  setup do
    # Clean slate: reset DETS, scheduler, task queue
    Smoke.Setup.reset_all()

    # Create tokens for 2 agents + 1 submitter
    agent_ids = ["smoke-basic-1", "smoke-basic-2"]
    submitter_id = "smoke-basic-submitter"

    agent_tokens = Smoke.Setup.create_test_tokens(agent_ids)
    submitter_tokens = Smoke.Setup.create_test_tokens([submitter_id])
    submitter_token = submitter_tokens[submitter_id]

    on_exit(fn ->
      # Stop any lingering agent sims
      Smoke.Setup.cleanup_agents(agent_ids ++ [submitter_id])
    end)

    %{
      agent_ids: agent_ids,
      agent_tokens: agent_tokens,
      submitter_token: submitter_token
    }
  end

  @tag timeout: 60_000
  test "TEST-01: 10 tasks complete across 2 agents", ctx do
    # 1. Start 2 AgentSim processes with :complete behavior
    agents =
      Enum.map(ctx.agent_ids, fn id ->
        {:ok, pid} =
          Smoke.AgentSim.start_link(
            agent_id: id,
            token: ctx.agent_tokens[id],
            on_task_assign: :complete
          )

        {id, pid}
      end)

    # 2. Wait for both agents to be identified
    for {_id, pid} <- agents do
      Smoke.Assertions.wait_for(fn -> Smoke.AgentSim.identified?(pid) end, timeout: 15_000)
    end

    # 3. Submit 10 tasks via HTTP
    task_ids =
      for n <- 1..@task_count do
        {:ok, body} =
          Smoke.Http.submit_task("Write number #{n} to file", ctx.submitter_token)

        body["task_id"]
      end

    assert length(task_ids) == @task_count, "Expected #{@task_count} task IDs, got #{length(task_ids)}"

    # 4. Wait for all tasks to complete
    Smoke.Assertions.assert_all_completed(task_ids, timeout: 30_000)

    # 5. Assert all 10 tasks are :completed
    for task_id <- task_ids do
      {:ok, task} = AgentCom.TaskQueue.get(task_id)
      assert task.status == :completed, "Task #{task_id} expected :completed, got #{task.status}"
    end

    # 6. Assert assignment latency < 5s for each task
    for task_id <- task_ids do
      {:ok, task} = AgentCom.TaskQueue.get(task_id)

      if task.assigned_at && task.created_at do
        latency_ms = task.assigned_at - task.created_at
        assert latency_ms < 5_000, "Task #{task_id} latency #{latency_ms}ms exceeds 5000ms"
      end
    end

    # 7. Assert token overhead < 500 per task
    for task_id <- task_ids do
      {:ok, task} = AgentCom.TaskQueue.get(task_id)
      tokens = task.tokens_used || 0
      assert tokens < 500, "Task #{task_id} used #{tokens} tokens, exceeds 500 limit"
    end

    # 8. Assert both agents did work
    for {_id, pid} <- agents do
      count = Smoke.AgentSim.completed_count(pid)
      assert count > 0, "Agent expected to complete at least 1 task, completed #{count}"
    end

    # 9. Stop both agents
    for {_id, pid} <- agents do
      Smoke.AgentSim.stop(pid)
    end
  end
end
