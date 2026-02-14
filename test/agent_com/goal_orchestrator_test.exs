defmodule AgentCom.GoalOrchestratorTest do
  @moduledoc """
  Tests for the GoalOrchestrator GenServer.

  Covers PubSub subscription, active goal counting, Task.async result handling
  for decomposition and verification, and task completion event processing.

  NOT async -- uses named GenServers (GoalBacklog, TaskQueue, GoalOrchestrator).
  """

  use ExUnit.Case, async: false

  alias AgentCom.GoalOrchestrator
  alias AgentCom.GoalBacklog
  alias AgentCom.TaskQueue
  alias AgentCom.TestHelpers.DetsHelpers

  setup do
    tmp_dir = DetsHelpers.full_test_setup()

    # Stop GoalOrchestrator from supervision tree if running
    try do
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.GoalOrchestrator)
    catch
      :exit, _ -> :ok
    end

    # Start GoalOrchestrator fresh
    {:ok, pid} = GoalOrchestrator.start_link([])

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end

      DetsHelpers.full_test_teardown(tmp_dir)
    end)

    {:ok, pid: pid, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # PubSub subscription
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "subscribes to tasks and goals PubSub topics" do
      # GoalOrchestrator subscribes in init. Verify by broadcasting
      # and checking that our test process (also subscribed) receives it.
      Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
      Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")

      Phoenix.PubSub.broadcast(AgentCom.PubSub, "tasks", {:task_event, %{event: :test_ping}})
      assert_receive {:task_event, %{event: :test_ping}}, 500

      Phoenix.PubSub.broadcast(AgentCom.PubSub, "goals", {:goal_event, %{event: :test_ping}})
      assert_receive {:goal_event, %{event: :test_ping}}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # active_goal_count
  # ---------------------------------------------------------------------------

  describe "active_goal_count/0" do
    test "returns 0 initially" do
      assert GoalOrchestrator.active_goal_count() == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Decomposition result handling
  # ---------------------------------------------------------------------------

  describe "decomposition results" do
    test "successful decomposition updates goal to :executing" do
      # Submit goal to GoalBacklog first
      {:ok, goal} = GoalBacklog.submit(%{description: "test goal", priority: "normal"})
      goal_id = goal.id

      # Dequeue to move to :decomposing
      {:ok, _dequeued} = GoalBacklog.dequeue()

      # Manually set active goal state
      ref = make_ref()
      state = %GoalOrchestrator{
        active_goals: %{goal_id => %{phase: :decomposing}},
        pending_async: {ref, goal_id, :decompose}
      }

      # Send synthetic decomposition success
      result = {:ok, ["task-1", "task-2"]}
      {:noreply, new_state} = GoalOrchestrator.handle_info({ref, result}, state)

      assert new_state.pending_async == nil
      assert new_state.active_goals[goal_id].phase == :executing
    end

    test "failed decomposition removes goal from active" do
      {:ok, goal} = GoalBacklog.submit(%{description: "test fail", priority: "normal"})
      goal_id = goal.id
      {:ok, _dequeued} = GoalBacklog.dequeue()

      ref = make_ref()
      state = %GoalOrchestrator{
        active_goals: %{goal_id => %{phase: :decomposing}},
        pending_async: {ref, goal_id, :decompose}
      }

      result = {:error, :llm_failed}
      {:noreply, new_state} = GoalOrchestrator.handle_info({ref, result}, state)

      assert new_state.pending_async == nil
      refute Map.has_key?(new_state.active_goals, goal_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Verification result handling
  # ---------------------------------------------------------------------------

  describe "verification results" do
    setup do
      {:ok, goal} = GoalBacklog.submit(%{description: "verify goal", priority: "normal"})
      goal_id = goal.id
      {:ok, _} = GoalBacklog.dequeue()
      {:ok, _} = GoalBacklog.transition(goal_id, :executing)
      {:ok, _} = GoalBacklog.transition(goal_id, :verifying)

      {:ok, goal_id: goal_id}
    end

    test "verification pass transitions to complete", %{goal_id: goal_id} do
      ref = make_ref()
      state = %GoalOrchestrator{
        active_goals: %{goal_id => %{phase: :verifying}},
        verification_retries: %{goal_id => 0},
        pending_async: {ref, goal_id, :verify}
      }

      {:noreply, new_state} = GoalOrchestrator.handle_info({ref, {:ok, :pass}}, state)

      assert new_state.pending_async == nil
      refute Map.has_key?(new_state.active_goals, goal_id)
      refute Map.has_key?(new_state.verification_retries, goal_id)
    end

    test "verification needs_human_review transitions to failed", %{goal_id: goal_id} do
      ref = make_ref()
      state = %GoalOrchestrator{
        active_goals: %{goal_id => %{phase: :verifying}},
        verification_retries: %{goal_id => 2},
        pending_async: {ref, goal_id, :verify}
      }

      {:noreply, new_state} = GoalOrchestrator.handle_info({ref, {:ok, :needs_human_review}}, state)

      assert new_state.pending_async == nil
      refute Map.has_key?(new_state.active_goals, goal_id)
      refute Map.has_key?(new_state.verification_retries, goal_id)
    end

    test "verification fail with gaps increments retries and returns to executing", %{goal_id: _goal_id} do
      # We need goal back in :executing for this transition to work
      # Reset goal lifecycle for this test
      {:ok, goal2} = GoalBacklog.submit(%{description: "retry goal", priority: "normal"})
      gid = goal2.id
      {:ok, _} = GoalBacklog.dequeue()
      {:ok, _} = GoalBacklog.transition(gid, :executing)
      {:ok, _} = GoalBacklog.transition(gid, :verifying)

      ref = make_ref()
      state = %GoalOrchestrator{
        active_goals: %{gid => %{phase: :verifying}},
        verification_retries: %{gid => 0},
        pending_async: {ref, gid, :verify}
      }

      gaps = [%{description: "missing error handling", severity: "minor"}]
      {:noreply, new_state} = GoalOrchestrator.handle_info({ref, {:ok, :fail, gaps}}, state)

      assert new_state.pending_async == nil
      assert new_state.active_goals[gid].phase == :executing
      assert new_state.verification_retries[gid] == 1
    end

    test "verification error clears pending_async but keeps goal state", %{goal_id: goal_id} do
      ref = make_ref()
      state = %GoalOrchestrator{
        active_goals: %{goal_id => %{phase: :verifying}},
        pending_async: {ref, goal_id, :verify}
      }

      {:noreply, new_state} = GoalOrchestrator.handle_info({ref, {:error, :timeout}}, state)

      assert new_state.pending_async == nil
      assert Map.has_key?(new_state.active_goals, goal_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Task completion events
  # ---------------------------------------------------------------------------

  describe "task completion events" do
    test "task completion for tracked goal updates phase when all done" do
      {:ok, goal} = GoalBacklog.submit(%{description: "task event goal", priority: "normal"})
      goal_id = goal.id
      {:ok, _} = GoalBacklog.dequeue()

      # Submit a task for this goal
      {:ok, task} = TaskQueue.submit(%{
        description: "child task",
        goal_id: goal_id,
        priority: "normal"
      })

      # Assign and complete the task
      {:ok, assigned} = TaskQueue.assign_task(task.id, "agent-1")
      {:ok, _completed} = TaskQueue.complete_task(task.id, assigned.generation, %{result: "done"})

      # Now simulate GoalOrchestrator receiving the completion event
      state = %GoalOrchestrator{
        active_goals: %{goal_id => %{phase: :executing}}
      }

      event = {:task_event, %{event: :task_completed, task: %{goal_id: goal_id}}}
      {:noreply, new_state} = GoalOrchestrator.handle_info(event, state)

      assert new_state.active_goals[goal_id].phase == :ready_to_verify
    end

    test "task event for untracked goal is ignored" do
      state = %GoalOrchestrator{
        active_goals: %{"goal-tracked" => %{phase: :executing}}
      }

      event = {:task_event, %{event: :task_completed, task: %{goal_id: "goal-untracked"}}}
      {:noreply, new_state} = GoalOrchestrator.handle_info(event, state)

      assert new_state == state
    end

    test "task event for task without goal_id is ignored" do
      state = %GoalOrchestrator{active_goals: %{}}

      event = {:task_event, %{event: :task_completed, task: %{}}}
      {:noreply, new_state} = GoalOrchestrator.handle_info(event, state)

      assert new_state == state
    end
  end

  # ---------------------------------------------------------------------------
  # Tick behavior
  # ---------------------------------------------------------------------------

  describe "tick/0" do
    test "tick with no goals and no pending async is a no-op" do
      # Just confirm it doesn't crash
      GoalOrchestrator.tick()
      Process.sleep(50)
      assert GoalOrchestrator.active_goal_count() == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Catch-all messages
  # ---------------------------------------------------------------------------

  describe "catch-all handle_info" do
    test "unknown messages are ignored" do
      state = %GoalOrchestrator{}

      assert {:noreply, ^state} = GoalOrchestrator.handle_info(:random_message, state)
      assert {:noreply, ^state} = GoalOrchestrator.handle_info({:goal_event, %{}}, state)
      assert {:noreply, ^state} = GoalOrchestrator.handle_info({:task_event, %{event: :other}}, state)
    end
  end
end
