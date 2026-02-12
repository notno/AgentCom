defmodule AgentCom.TaskQueueTest do
  @moduledoc """
  Deep unit tests for the TaskQueue GenServer.

  Covers: submit, get, assign, complete, fail (retry + dead-letter),
  list, list_dead_letter, sweep_overdue, stats, reclaim, and edge cases.

  The Scheduler is stopped during setup to prevent it from reacting to
  PubSub :task_submitted events and auto-assigning tasks.
  """

  use ExUnit.Case, async: false

  alias AgentCom.TaskQueue

  setup do
    # full_test_setup restarts all DETS servers (including Scheduler) with fresh data.
    # Then we stop Scheduler so it doesn't react to PubSub task events during tests.
    tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.Scheduler)

    on_exit(fn ->
      # Restart Scheduler so the next test's full_test_setup finds it running
      Supervisor.restart_child(AgentCom.Supervisor, AgentCom.Scheduler)
      AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # Submit
  # ---------------------------------------------------------------------------

  describe "submit/1" do
    test "creates a task with :queued status and default priority 2 (normal)" do
      {:ok, task} = TaskQueue.submit(%{description: "unit test task"})

      assert task.status == :queued
      assert task.priority == 2
      assert task.description == "unit test task"
    end

    test "with 'high' priority sets priority to 1" do
      {:ok, task} = TaskQueue.submit(%{description: "high priority", priority: "high"})

      assert task.priority == 1
    end

    test "with 'low' priority sets priority to 3" do
      {:ok, task} = TaskQueue.submit(%{description: "low priority", priority: "low"})

      assert task.priority == 3
    end

    test "with 'urgent' priority sets priority to 0" do
      {:ok, task} = TaskQueue.submit(%{description: "urgent", priority: "urgent"})

      assert task.priority == 0
    end

    test "generates a unique task_id matching pattern task-[a-f0-9]+" do
      {:ok, task} = TaskQueue.submit(%{description: "id test"})

      assert task.id =~ ~r/^task-[a-f0-9]+$/
    end

    test "stores submitted_by, description, max_retries, needed_capabilities" do
      {:ok, task} =
        TaskQueue.submit(%{
          description: "full params task",
          submitted_by: "user-42",
          max_retries: 5,
          needed_capabilities: ["code", "review"]
        })

      assert task.submitted_by == "user-42"
      assert task.description == "full params task"
      assert task.max_retries == 5
      assert task.needed_capabilities == ["code", "review"]
    end

    test "defaults submitted_by to 'unknown' when not provided" do
      {:ok, task} = TaskQueue.submit(%{description: "default submitter"})

      assert task.submitted_by == "unknown"
    end

    test "defaults max_retries to 3 when not provided" do
      {:ok, task} = TaskQueue.submit(%{description: "default retries"})

      assert task.max_retries == 3
    end

    test "initializes generation to 0" do
      {:ok, task} = TaskQueue.submit(%{description: "generation test"})

      assert task.generation == 0
    end

    test "initializes retry_count to 0" do
      {:ok, task} = TaskQueue.submit(%{description: "retry count test"})

      assert task.retry_count == 0
    end

    test "sets created_at and updated_at timestamps" do
      before = System.system_time(:millisecond)
      {:ok, task} = TaskQueue.submit(%{description: "timestamp test"})
      after_ts = System.system_time(:millisecond)

      assert task.created_at >= before
      assert task.created_at <= after_ts
      assert task.updated_at == task.created_at
    end

    test "creates history with initial :queued entry" do
      {:ok, task} = TaskQueue.submit(%{description: "history test"})

      assert [{:queued, _ts, "submitted"}] = task.history
    end

    test "submit with minimal params (only description)" do
      {:ok, task} = TaskQueue.submit(%{description: "minimal"})

      assert task.status == :queued
      assert task.priority == 2
      assert task.needed_capabilities == []
      assert task.metadata == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Get
  # ---------------------------------------------------------------------------

  describe "get/1" do
    test "returns {:ok, task} for existing task" do
      {:ok, submitted} = TaskQueue.submit(%{description: "get test"})
      {:ok, fetched} = TaskQueue.get(submitted.id)

      assert fetched.id == submitted.id
      assert fetched.description == "get test"
    end

    test "returns {:error, :not_found} for nonexistent task_id" do
      assert {:error, :not_found} = TaskQueue.get("task-nonexistent")
    end
  end

  # ---------------------------------------------------------------------------
  # Assign
  # ---------------------------------------------------------------------------

  describe "assign_task/3" do
    test "transitions :queued -> :assigned with assigned_to and generation=1" do
      {:ok, task} = TaskQueue.submit(%{description: "assign test"})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")

      assert assigned.status == :assigned
      assert assigned.assigned_to == "agent-1"
      assert assigned.generation == 1
      assert assigned.assigned_at != nil
    end

    test "on already-assigned task returns {:error, {:invalid_state, :assigned}}" do
      {:ok, task} = TaskQueue.submit(%{description: "double assign"})
      {:ok, _assigned} = TaskQueue.assign_task(task.id, "agent-1")

      assert {:error, {:invalid_state, :assigned}} = TaskQueue.assign_task(task.id, "agent-2")
    end

    test "returns {:error, :not_found} for nonexistent task" do
      assert {:error, :not_found} = TaskQueue.assign_task("task-fake", "agent-1")
    end

    test "removes task from priority index after assignment" do
      {:ok, task} = TaskQueue.submit(%{description: "index test"})
      {:ok, _assigned} = TaskQueue.assign_task(task.id, "agent-1")

      # dequeue_next should not return the assigned task
      result = TaskQueue.dequeue_next()
      assert result == {:error, :empty}
    end
  end

  # ---------------------------------------------------------------------------
  # Complete
  # ---------------------------------------------------------------------------

  describe "complete_task/3" do
    test "with correct generation transitions :assigned -> :completed" do
      {:ok, task} = TaskQueue.submit(%{description: "complete test"})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")

      {:ok, completed} =
        TaskQueue.complete_task(task.id, assigned.generation, %{result: "done!"})

      assert completed.status == :completed
      assert completed.result == "done!"
    end

    test "with wrong generation returns {:error, :stale_generation}" do
      {:ok, task} = TaskQueue.submit(%{description: "stale gen test"})
      {:ok, _assigned} = TaskQueue.assign_task(task.id, "agent-1")

      assert {:error, :stale_generation} =
               TaskQueue.complete_task(task.id, 999, %{result: "stale"})
    end

    test "stores tokens_used from result_params" do
      {:ok, task} = TaskQueue.submit(%{description: "tokens test"})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")

      {:ok, completed} =
        TaskQueue.complete_task(task.id, assigned.generation, %{
          result: "with tokens",
          tokens_used: 150
        })

      assert completed.tokens_used == 150
    end

    test "on non-assigned task returns {:error, :invalid_state}" do
      {:ok, task} = TaskQueue.submit(%{description: "complete queued"})

      assert {:error, :invalid_state} =
               TaskQueue.complete_task(task.id, 0, %{result: "nope"})
    end
  end

  # ---------------------------------------------------------------------------
  # Fail
  # ---------------------------------------------------------------------------

  describe "fail_task/3" do
    test "with retries remaining transitions to :queued with incremented retry_count" do
      {:ok, task} = TaskQueue.submit(%{description: "retry test", max_retries: 3})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")

      {:ok, :retried, retried} =
        TaskQueue.fail_task(task.id, assigned.generation, "transient error")

      assert retried.status == :queued
      assert retried.retry_count == 1
      assert retried.assigned_to == nil
      assert retried.last_error == "transient error"
    end

    test "with retries exhausted moves task to dead-letter" do
      {:ok, task} = TaskQueue.submit(%{description: "dead letter test", max_retries: 1})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")

      {:ok, :dead_letter, dead} =
        TaskQueue.fail_task(task.id, assigned.generation, "fatal error")

      assert dead.status == :dead_letter
      assert dead.retry_count == 1
      assert dead.last_error == "fatal error"

      # Task should no longer be in main table
      assert {:error, :not_found} = lookup_in_main_table(task.id)

      # But should be found via get (which checks both tables)
      {:ok, found} = TaskQueue.get(task.id)
      assert found.status == :dead_letter
    end

    test "with wrong generation returns {:error, :stale_generation}" do
      {:ok, task} = TaskQueue.submit(%{description: "stale fail"})
      {:ok, _assigned} = TaskQueue.assign_task(task.id, "agent-1")

      assert {:error, :stale_generation} = TaskQueue.fail_task(task.id, 999, "error")
    end

    test "retry bumps generation" do
      {:ok, task} = TaskQueue.submit(%{description: "gen bump test", max_retries: 3})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")
      gen_after_assign = assigned.generation

      {:ok, :retried, retried} =
        TaskQueue.fail_task(task.id, gen_after_assign, "error")

      assert retried.generation == gen_after_assign + 1
    end
  end

  # ---------------------------------------------------------------------------
  # List
  # ---------------------------------------------------------------------------

  describe "list/1" do
    test "returns submitted tasks" do
      {:ok, _t1} = TaskQueue.submit(%{description: "list test 1"})
      {:ok, _t2} = TaskQueue.submit(%{description: "list test 2"})

      tasks = TaskQueue.list()
      descriptions = Enum.map(tasks, & &1.description)

      assert "list test 1" in descriptions
      assert "list test 2" in descriptions
    end

    test "filters by status" do
      {:ok, task} = TaskQueue.submit(%{description: "filter assigned"})
      {:ok, _assigned} = TaskQueue.assign_task(task.id, "agent-1")
      {:ok, _queued} = TaskQueue.submit(%{description: "filter queued"})

      assigned_tasks = TaskQueue.list(status: :assigned)
      queued_tasks = TaskQueue.list(status: :queued)

      assert Enum.all?(assigned_tasks, &(&1.status == :assigned))
      assert Enum.all?(queued_tasks, &(&1.status == :queued))
    end
  end

  describe "list_dead_letter/0" do
    test "returns dead-lettered tasks" do
      {:ok, task} = TaskQueue.submit(%{description: "dl list", max_retries: 1})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")
      {:ok, :dead_letter, _dead} = TaskQueue.fail_task(task.id, assigned.generation, "fatal")

      dead_letters = TaskQueue.list_dead_letter()
      assert length(dead_letters) >= 1
      assert Enum.any?(dead_letters, &(&1.id == task.id))
    end
  end

  # ---------------------------------------------------------------------------
  # Sweep overdue
  # ---------------------------------------------------------------------------

  describe ":sweep_overdue" do
    test "reclaims assigned tasks past their complete_by deadline" do
      {:ok, task} = TaskQueue.submit(%{description: "overdue sweep test"})

      # Assign with a complete_by in the past
      past_ms = System.system_time(:millisecond) - 1000
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1", complete_by: past_ms)
      assert assigned.status == :assigned

      # Trigger sweep directly
      send(GenServer.whereis(AgentCom.TaskQueue), :sweep_overdue)
      # Give the GenServer a moment to process
      Process.sleep(100)

      # Task should be reclaimed back to :queued
      {:ok, reclaimed} = TaskQueue.get(task.id)
      assert reclaimed.status == :queued
      assert reclaimed.assigned_to == nil
      assert reclaimed.generation == assigned.generation + 1
    end

    test "does not reclaim tasks without complete_by" do
      {:ok, task} = TaskQueue.submit(%{description: "no deadline"})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")

      send(GenServer.whereis(AgentCom.TaskQueue), :sweep_overdue)
      Process.sleep(100)

      {:ok, still_assigned} = TaskQueue.get(task.id)
      assert still_assigned.status == :assigned
      assert still_assigned.generation == assigned.generation
    end
  end

  # ---------------------------------------------------------------------------
  # Stats
  # ---------------------------------------------------------------------------

  describe "stats/0" do
    test "returns counts by status, priority, and dead_letter count" do
      {:ok, _t1} = TaskQueue.submit(%{description: "stats 1", priority: "high"})
      {:ok, t2} = TaskQueue.submit(%{description: "stats 2", priority: "low"})
      {:ok, _assigned} = TaskQueue.assign_task(t2.id, "agent-stats")

      stats = TaskQueue.stats()

      assert is_map(stats.by_status)
      assert is_map(stats.by_priority)
      assert is_integer(stats.dead_letter)
      assert is_integer(stats.queued_index_size)
    end
  end

  # ---------------------------------------------------------------------------
  # Reclaim
  # ---------------------------------------------------------------------------

  describe "reclaim_task/1" do
    test "reclaims an assigned task back to :queued" do
      {:ok, task} = TaskQueue.submit(%{description: "reclaim test"})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")

      {:ok, reclaimed} = TaskQueue.reclaim_task(task.id)

      assert reclaimed.status == :queued
      assert reclaimed.assigned_to == nil
      assert reclaimed.generation == assigned.generation + 1
    end

    test "returns {:error, :not_assigned} for queued task" do
      {:ok, task} = TaskQueue.submit(%{description: "reclaim queued"})

      assert {:error, :not_assigned} = TaskQueue.reclaim_task(task.id)
    end

    test "returns {:error, :not_found} for nonexistent task" do
      assert {:error, :not_found} = TaskQueue.reclaim_task("task-nope")
    end
  end

  # ---------------------------------------------------------------------------
  # Dequeue next
  # ---------------------------------------------------------------------------

  describe "dequeue_next/0" do
    test "returns highest-priority queued task" do
      {:ok, _low} = TaskQueue.submit(%{description: "low", priority: "low"})
      {:ok, high} = TaskQueue.submit(%{description: "high", priority: "high"})

      {:ok, next} = TaskQueue.dequeue_next()
      assert next.id == high.id
    end

    test "returns {:error, :empty} when no queued tasks" do
      assert {:error, :empty} = TaskQueue.dequeue_next()
    end
  end

  # ---------------------------------------------------------------------------
  # Retry dead letter
  # ---------------------------------------------------------------------------

  describe "retry_dead_letter/1" do
    test "moves dead-letter task back to queue with reset retry_count" do
      {:ok, task} = TaskQueue.submit(%{description: "retry dl", max_retries: 1})
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")
      {:ok, :dead_letter, _dead} = TaskQueue.fail_task(task.id, assigned.generation, "error")

      {:ok, retried} = TaskQueue.retry_dead_letter(task.id)

      assert retried.status == :queued
      assert retried.retry_count == 0
      assert retried.assigned_to == nil
    end

    test "returns {:error, :not_found} for nonexistent task" do
      assert {:error, :not_found} = TaskQueue.retry_dead_letter("task-nope")
    end
  end

  # ---------------------------------------------------------------------------
  # Helper
  # ---------------------------------------------------------------------------

  # Direct DETS lookup to verify task is not in the main table
  defp lookup_in_main_table(task_id) do
    case :dets.lookup(:task_queue, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end
end
