defmodule AgentCom.GoalOrchestrator.DecomposerTest do
  use ExUnit.Case, async: true

  alias AgentCom.GoalOrchestrator.Decomposer

  # ---------------------------------------------------------------------------
  # build_context/2
  # ---------------------------------------------------------------------------

  describe "build_context/2" do
    test "returns map with repo, files, and constraints keys" do
      goal = %{id: "goal-1", repo: "https://github.com/user/repo", description: "test"}
      file_tree = ["lib/app.ex", "test/app_test.exs"]

      context = Decomposer.build_context(goal, file_tree)

      assert context.repo == "https://github.com/user/repo"
      assert context.files == ["lib/app.ex", "test/app_test.exs"]
      assert is_binary(context.constraints)
      assert context.constraints =~ "ONLY files that exist"
      assert context.constraints =~ "3-8 tasks"
      assert context.constraints =~ "DAG"
    end

    test "handles goal with nil repo" do
      goal = %{id: "goal-2", description: "test"}
      context = Decomposer.build_context(goal, [])

      assert context.repo == nil
      assert context.files == []
    end

    test "includes depends-on instruction in constraints" do
      goal = %{id: "goal-3"}
      context = Decomposer.build_context(goal, ["lib/foo.ex"])

      assert context.constraints =~ "depends-on indices (1-based)"
      assert context.constraints =~ "no cycles"
    end
  end

  # ---------------------------------------------------------------------------
  # validate_task_count/2
  # ---------------------------------------------------------------------------

  describe "validate_task_count/2" do
    test "0 tasks returns single task wrapping goal description" do
      goal = %{id: "goal-1", description: "Do the thing", success_criteria: "It works"}

      result = Decomposer.validate_task_count([], goal)

      assert length(result) == 1
      [task] = result
      assert task.description == "Do the thing"
      assert task.success_criteria == "It works"
      assert task.depends_on == []
    end

    test "1 task returns the task unchanged" do
      goal = %{id: "goal-1"}
      tasks = [%{title: "Only task", description: "do it", depends_on: []}]

      result = Decomposer.validate_task_count(tasks, goal)

      assert result == tasks
    end

    test "5 tasks in normal range pass through unchanged" do
      goal = %{id: "goal-1"}
      tasks = Enum.map(1..5, fn i -> %{title: "Task #{i}", depends_on: []} end)

      result = Decomposer.validate_task_count(tasks, goal)

      assert result == tasks
      assert length(result) == 5
    end

    test "11 tasks pass through with warning (not blocking)" do
      goal = %{id: "goal-1"}
      tasks = Enum.map(1..11, fn i -> %{title: "Task #{i}", depends_on: []} end)

      result = Decomposer.validate_task_count(tasks, goal)

      assert result == tasks
      assert length(result) == 11
    end

    test "2 tasks (lower boundary) pass through" do
      goal = %{id: "goal-1"}
      tasks = [%{title: "A", depends_on: []}, %{title: "B", depends_on: []}]

      assert Decomposer.validate_task_count(tasks, goal) == tasks
    end

    test "10 tasks (upper boundary) pass through" do
      goal = %{id: "goal-1"}
      tasks = Enum.map(1..10, fn i -> %{title: "Task #{i}", depends_on: []} end)

      assert Decomposer.validate_task_count(tasks, goal) == tasks
    end
  end

  # ---------------------------------------------------------------------------
  # build_submit_params/3
  # ---------------------------------------------------------------------------

  describe "build_submit_params/3" do
    test "builds params with resolved dependencies" do
      task = %{
        description: "Update lib/app.ex to add feature",
        success_criteria: "Feature works; Tests pass",
        depends_on: [1, 2]
      }

      goal = %{id: "goal-42", repo: "https://github.com/user/repo", priority: 1}
      index_map = %{1 => "task-aaa", 2 => "task-bbb"}

      params = Decomposer.build_submit_params(task, goal, index_map)

      assert params.description == "Update lib/app.ex to add feature"
      assert params.goal_id == "goal-42"
      assert params.depends_on == ["task-aaa", "task-bbb"]
      assert params.repo == "https://github.com/user/repo"
      assert "lib/app.ex" in params.file_hints
      assert params.priority == "high"
      assert is_list(params.success_criteria)
      assert "Feature works" in params.success_criteria
      assert "Tests pass" in params.success_criteria
    end

    test "skips unresolved dependency indices" do
      task = %{description: "Do something", depends_on: [1, 3]}
      goal = %{id: "goal-1", priority: 2}
      index_map = %{1 => "task-aaa"}

      params = Decomposer.build_submit_params(task, goal, index_map)

      # Index 3 is not in the map, so only index 1 resolves
      assert params.depends_on == ["task-aaa"]
    end

    test "empty depends_on produces empty list" do
      task = %{description: "Independent task", depends_on: []}
      goal = %{id: "goal-1", priority: 0}

      params = Decomposer.build_submit_params(task, goal, %{})

      assert params.depends_on == []
    end

    test "extracts file hints from description" do
      task = %{
        description: "Modify lib/agent_com/foo.ex and test/agent_com/foo_test.exs",
        depends_on: []
      }

      goal = %{id: "goal-1", priority: 2}

      params = Decomposer.build_submit_params(task, goal, %{})

      assert "lib/agent_com/foo.ex" in params.file_hints
      assert "test/agent_com/foo_test.exs" in params.file_hints
    end

    test "uses default priority when goal has no priority" do
      task = %{description: "task", depends_on: []}
      goal = %{id: "goal-1"}

      params = Decomposer.build_submit_params(task, goal, %{})

      assert params.priority == "normal"
    end
  end

  # ---------------------------------------------------------------------------
  # priority_to_string/1
  # ---------------------------------------------------------------------------

  describe "priority_to_string/1" do
    test "maps 0 to urgent" do
      assert Decomposer.priority_to_string(0) == "urgent"
    end

    test "maps 1 to high" do
      assert Decomposer.priority_to_string(1) == "high"
    end

    test "maps 2 to normal" do
      assert Decomposer.priority_to_string(2) == "normal"
    end

    test "maps 3 to low" do
      assert Decomposer.priority_to_string(3) == "low"
    end

    test "unknown integer defaults to normal" do
      assert Decomposer.priority_to_string(99) == "normal"
      assert Decomposer.priority_to_string(-1) == "normal"
    end

    test "non-integer defaults to normal" do
      assert Decomposer.priority_to_string("high") == "normal"
      assert Decomposer.priority_to_string(nil) == "normal"
    end
  end
end
