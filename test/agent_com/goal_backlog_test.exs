defmodule AgentCom.GoalBacklogTest do
  use ExUnit.Case, async: false

  alias AgentCom.GoalBacklog
  alias AgentCom.TestHelpers.DetsHelpers

  setup do
    tmp_dir = DetsHelpers.full_test_setup()
    on_exit(fn -> DetsHelpers.full_test_teardown(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # Submit
  # ---------------------------------------------------------------------------

  test "submit creates goal with generated ID and required fields" do
    {:ok, goal} =
      GoalBacklog.submit(%{
        description: "Implement feature X",
        success_criteria: "All tests pass"
      })

    assert String.starts_with?(goal.id, "goal-")
    assert goal.status == :submitted
    assert goal.description == "Implement feature X"
    assert goal.success_criteria == "All tests pass"
    assert is_integer(goal.created_at)
    assert is_integer(goal.updated_at)
    assert goal.created_at == goal.updated_at
    assert length(goal.history) == 1
  end

  test "submit defaults priority to normal (2)" do
    {:ok, goal} = GoalBacklog.submit(%{description: "A goal", success_criteria: "Done"})
    assert goal.priority == 2
  end

  test "submit with explicit priority" do
    {:ok, goal} =
      GoalBacklog.submit(%{
        description: "Urgent goal",
        success_criteria: "ASAP",
        priority: "urgent"
      })

    assert goal.priority == 0
  end

  # ---------------------------------------------------------------------------
  # Get
  # ---------------------------------------------------------------------------

  test "get returns submitted goal" do
    {:ok, submitted} = GoalBacklog.submit(%{description: "Find me", success_criteria: "Found"})
    {:ok, found} = GoalBacklog.get(submitted.id)
    assert found.id == submitted.id
    assert found.description == "Find me"
  end

  test "get returns error for unknown ID" do
    assert {:error, :not_found} = GoalBacklog.get("nonexistent")
  end

  # ---------------------------------------------------------------------------
  # Transition lifecycle
  # ---------------------------------------------------------------------------

  test "transition follows valid lifecycle" do
    {:ok, goal} = GoalBacklog.submit(%{description: "Lifecycle", success_criteria: "OK"})
    {:ok, updated} = GoalBacklog.transition(goal.id, :decomposing)
    assert updated.status == :decomposing
    assert length(updated.history) == 2
  end

  test "transition rejects invalid state change" do
    {:ok, goal} = GoalBacklog.submit(%{description: "Invalid", success_criteria: "Nope"})
    assert {:error, {:invalid_transition, :submitted, :complete}} =
             GoalBacklog.transition(goal.id, :complete)
  end

  test "transition to failed from any active state" do
    # decomposing -> failed
    {:ok, g1} = GoalBacklog.submit(%{description: "G1", success_criteria: "SC"})
    {:ok, g1} = GoalBacklog.transition(g1.id, :decomposing)
    {:ok, g1} = GoalBacklog.transition(g1.id, :failed, reason: "broke")
    assert g1.status == :failed

    # executing -> failed
    {:ok, g2} = GoalBacklog.submit(%{description: "G2", success_criteria: "SC"})
    {:ok, g2} = GoalBacklog.transition(g2.id, :decomposing)
    {:ok, g2} = GoalBacklog.transition(g2.id, :executing)
    {:ok, g2} = GoalBacklog.transition(g2.id, :failed)
    assert g2.status == :failed

    # verifying -> failed
    {:ok, g3} = GoalBacklog.submit(%{description: "G3", success_criteria: "SC"})
    {:ok, g3} = GoalBacklog.transition(g3.id, :decomposing)
    {:ok, g3} = GoalBacklog.transition(g3.id, :executing)
    {:ok, g3} = GoalBacklog.transition(g3.id, :verifying)
    {:ok, g3} = GoalBacklog.transition(g3.id, :failed)
    assert g3.status == :failed
  end

  # ---------------------------------------------------------------------------
  # Dequeue
  # ---------------------------------------------------------------------------

  test "dequeue returns highest priority goal" do
    {:ok, _low} = GoalBacklog.submit(%{description: "Low", success_criteria: "SC", priority: "low"})
    {:ok, urgent} = GoalBacklog.submit(%{description: "Urgent", success_criteria: "SC", priority: "urgent"})
    {:ok, _normal} = GoalBacklog.submit(%{description: "Normal", success_criteria: "SC", priority: "normal"})

    {:ok, dequeued} = GoalBacklog.dequeue()
    assert dequeued.id == urgent.id
    assert dequeued.status == :decomposing
  end

  test "dequeue returns error when empty" do
    assert {:error, :empty} = GoalBacklog.dequeue()
  end

  # ---------------------------------------------------------------------------
  # List
  # ---------------------------------------------------------------------------

  test "list returns all goals" do
    GoalBacklog.submit(%{description: "G1", success_criteria: "SC"})
    GoalBacklog.submit(%{description: "G2", success_criteria: "SC"})
    GoalBacklog.submit(%{description: "G3", success_criteria: "SC"})

    goals = GoalBacklog.list()
    assert length(goals) == 3
  end

  test "list filters by status" do
    {:ok, g1} = GoalBacklog.submit(%{description: "G1", success_criteria: "SC"})
    {:ok, _g2} = GoalBacklog.submit(%{description: "G2", success_criteria: "SC"})
    GoalBacklog.transition(g1.id, :decomposing)

    submitted = GoalBacklog.list(%{status: :submitted})
    assert length(submitted) == 1

    decomposing = GoalBacklog.list(%{status: :decomposing})
    assert length(decomposing) == 1
  end

  # ---------------------------------------------------------------------------
  # Stats
  # ---------------------------------------------------------------------------

  test "stats returns counts by status and priority" do
    GoalBacklog.submit(%{description: "U1", success_criteria: "SC", priority: "urgent"})
    GoalBacklog.submit(%{description: "N1", success_criteria: "SC", priority: "normal"})
    GoalBacklog.submit(%{description: "N2", success_criteria: "SC", priority: "normal"})

    stats = GoalBacklog.stats()
    assert stats.by_status == %{submitted: 3}
    assert stats.by_priority == %{0 => 1, 2 => 2}
    assert stats.total == 3
  end

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  test "delete removes goal" do
    {:ok, goal} = GoalBacklog.submit(%{description: "Delete me", success_criteria: "SC"})
    assert :ok = GoalBacklog.delete(goal.id)
    assert {:error, :not_found} = GoalBacklog.get(goal.id)
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  test "PubSub events broadcast on submit and transition" do
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")

    {:ok, goal} = GoalBacklog.submit(%{description: "PubSub test", success_criteria: "SC"})

    assert_receive {:goal_event, %{event: :goal_submitted, goal_id: goal_id}}, 1000
    assert goal_id == goal.id

    {:ok, _updated} = GoalBacklog.transition(goal.id, :decomposing)

    assert_receive {:goal_event, %{event: :goal_decomposing, goal_id: ^goal_id}}, 1000
  end

  # ---------------------------------------------------------------------------
  # Persistence across restart
  # ---------------------------------------------------------------------------

  test "goals persist across GenServer restart" do
    {:ok, goal} = GoalBacklog.submit(%{description: "Persist me", success_criteria: "SC"})

    # Stop and restart the GenServer via supervisor
    :ok = Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.GoalBacklog)
    # Force-close DETS so init/1 can reopen with the same name
    :dets.close(:goal_backlog)
    {:ok, _pid} = Supervisor.restart_child(AgentCom.Supervisor, AgentCom.GoalBacklog)

    {:ok, found} = GoalBacklog.get(goal.id)
    assert found.id == goal.id
    assert found.description == "Persist me"
    assert found.status == :submitted
  end
end
