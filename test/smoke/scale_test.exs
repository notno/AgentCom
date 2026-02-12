defmodule Smoke.ScaleTest do
  @moduledoc """
  TEST-03: Scale distribution validation.

  Verifies that:
  - 4 agents processing 20 tasks achieve even distribution within +/-2 tasks per agent
  - No priority lane starvation when mixing urgent, high, normal, low priorities
  - Assignment order respects priority (urgent before low on average)
  """

  use ExUnit.Case, async: false
  @moduletag :smoke

  setup do
    Smoke.Setup.reset_all()

    agent_ids = for n <- 1..4, do: "smoke-scale-#{n}"
    submitter_id = "smoke-scale-submitter"

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

  @tag timeout: 60_000
  test "TEST-03: 4 agents, 20 tasks, even distribution", ctx do
    # 1. Start 4 AgentSim processes with :complete behavior
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

    # 2. Wait for all 4 to be identified
    for {_id, pid} <- agents do
      Smoke.Assertions.wait_for(fn -> Smoke.AgentSim.identified?(pid) end, timeout: 15_000)
    end

    # 3. Submit 20 tasks with mixed priorities
    priorities = [
      {"urgent", 4},
      {"high", 4},
      {"normal", 8},
      {"low", 4}
    ]

    task_ids_by_priority =
      for {priority, count} <- priorities, n <- 1..count do
        {:ok, body} =
          Smoke.Http.submit_task(
            "Scale test #{priority} #{n}",
            ctx.submitter_token,
            priority: priority
          )

        {body["task_id"], priority}
      end

    task_ids = Enum.map(task_ids_by_priority, fn {id, _p} -> id end)
    assert length(task_ids) == 20

    # 4. Wait for all tasks to complete
    Smoke.Assertions.assert_all_completed(task_ids, timeout: 30_000)

    # 5. Assert all 20 tasks completed
    for task_id <- task_ids do
      {:ok, task} = AgentCom.TaskQueue.get(task_id)
      assert task.status == :completed, "Task #{task_id} expected :completed, got #{task.status}"
    end

    # 6. Check distribution: each agent should complete 3-7 tasks (5 +/- 2)
    for {id, pid} <- agents do
      count = Smoke.AgentSim.completed_count(pid)

      assert count >= 3 and count <= 7,
             "Agent #{id} completed #{count} tasks (expected 3-7 for even distribution)"
    end

    # 7. Assert no starvation: all priority levels had tasks completed
    for {priority, _count} <- priorities do
      # Get task IDs for this priority
      prio_task_ids =
        Enum.filter(task_ids_by_priority, fn {_id, p} -> p == priority end)
        |> Enum.map(fn {id, _p} -> id end)

      for task_id <- prio_task_ids do
        {:ok, task} = AgentCom.TaskQueue.get(task_id)

        assert task.status == :completed,
               "Priority #{priority} task #{task_id} not completed: #{task.status}"
      end
    end

    # 8. Assert assignment order respects priority: urgent mean assigned_at < low mean
    urgent_ids = for {id, p} <- task_ids_by_priority, p == "urgent", do: id
    low_ids = for {id, p} <- task_ids_by_priority, p == "low", do: id

    urgent_assigned_ats =
      for id <- urgent_ids do
        {:ok, task} = AgentCom.TaskQueue.get(id)
        task.assigned_at
      end
      |> Enum.reject(&is_nil/1)

    low_assigned_ats =
      for id <- low_ids do
        {:ok, task} = AgentCom.TaskQueue.get(id)
        task.assigned_at
      end
      |> Enum.reject(&is_nil/1)

    if length(urgent_assigned_ats) > 0 and length(low_assigned_ats) > 0 do
      urgent_mean = Enum.sum(urgent_assigned_ats) / length(urgent_assigned_ats)
      low_mean = Enum.sum(low_assigned_ats) / length(low_assigned_ats)

      assert urgent_mean <= low_mean,
             "Urgent tasks mean assigned_at (#{urgent_mean}) should be <= low tasks (#{low_mean})"
    end

    # Cleanup
    for {_id, pid} <- agents, do: Smoke.AgentSim.stop(pid)
  end

  @tag timeout: 60_000
  test "TEST-03b: no starvation under sequential submission", ctx do
    # 1. Start 4 agents
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

    for {_id, pid} <- agents do
      Smoke.Assertions.wait_for(fn -> Smoke.AgentSim.identified?(pid) end, timeout: 15_000)
    end

    # 2. Submit tasks one at a time with alternating priorities
    task_count = 12
    priorities_cycle = Stream.cycle(["urgent", "low"]) |> Enum.take(task_count)

    task_ids_by_priority =
      Enum.with_index(priorities_cycle, 1)
      |> Enum.map(fn {priority, n} ->
        {:ok, body} =
          Smoke.Http.submit_task(
            "Sequential #{priority} #{n}",
            ctx.submitter_token,
            priority: priority
          )

        {body["task_id"], priority}
      end)

    task_ids = Enum.map(task_ids_by_priority, fn {id, _p} -> id end)

    # 3. Assert all complete
    Smoke.Assertions.assert_all_completed(task_ids, timeout: 30_000)

    # 4. Assert low-priority tasks complete (not stuck in queue forever)
    low_ids = for {id, p} <- task_ids_by_priority, p == "low", do: id

    for task_id <- low_ids do
      {:ok, task} = AgentCom.TaskQueue.get(task_id)

      assert task.status == :completed,
             "Low-priority task #{task_id} not completed: #{task.status} (starvation detected)"
    end

    # Cleanup
    for {_id, pid} <- agents, do: Smoke.AgentSim.stop(pid)
  end
end
