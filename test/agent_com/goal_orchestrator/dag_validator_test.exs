defmodule AgentCom.GoalOrchestrator.DagValidatorTest do
  use ExUnit.Case, async: true

  alias AgentCom.GoalOrchestrator.DagValidator

  describe "validate/1" do
    test "accepts valid linear chain" do
      tasks = [
        %{depends_on: []},
        %{depends_on: [1]},
        %{depends_on: [2]}
      ]

      assert :ok = DagValidator.validate(tasks)
    end

    test "accepts valid diamond dependency" do
      tasks = [
        %{depends_on: []},
        %{depends_on: [1]},
        %{depends_on: [1]},
        %{depends_on: [2, 3]}
      ]

      assert :ok = DagValidator.validate(tasks)
    end

    test "accepts fully independent tasks" do
      tasks = [
        %{depends_on: []},
        %{depends_on: []},
        %{depends_on: []}
      ]

      assert :ok = DagValidator.validate(tasks)
    end

    test "rejects cycle (also violates forward-only)" do
      # Task 1 depends on 2, task 2 depends on 1
      tasks = [
        %{depends_on: [2]},
        %{depends_on: [1]}
      ]

      assert {:error, _reason} = DagValidator.validate(tasks)
    end

    test "rejects out-of-range index" do
      tasks = [
        %{depends_on: []},
        %{depends_on: [5]}
      ]

      assert {:error, {:invalid_indices, [{2, 5}]}} = DagValidator.validate(tasks)
    end

    test "rejects self-dependency" do
      tasks = [
        %{depends_on: []},
        %{depends_on: [2]}
      ]

      assert {:error, {:invalid_indices, [{2, 2}]}} = DagValidator.validate(tasks)
    end

    test "rejects empty task list" do
      assert {:error, :empty_tasks} = DagValidator.validate([])
    end

    test "rejects forward reference (task depends on later task)" do
      tasks = [
        %{depends_on: [2]},
        %{depends_on: []},
        %{depends_on: [1]}
      ]

      assert {:error, {:invalid_indices, [{1, 2}]}} = DagValidator.validate(tasks)
    end

    test "rejects zero index" do
      tasks = [
        %{depends_on: [0]}
      ]

      assert {:error, {:invalid_indices, [{1, 0}]}} = DagValidator.validate(tasks)
    end
  end

  describe "topological_order/1" do
    test "returns independent tasks before dependent ones" do
      tasks = [
        %{depends_on: []},
        %{depends_on: [1]},
        %{depends_on: [1]},
        %{depends_on: [2, 3]}
      ]

      assert {:ok, order} = DagValidator.topological_order(tasks)

      # Task 1 must come before 2, 3; both 2 and 3 must come before 4
      pos = Enum.with_index(order) |> Map.new()
      assert pos[1] < pos[2]
      assert pos[1] < pos[3]
      assert pos[2] < pos[4]
      assert pos[3] < pos[4]
    end

    test "returns error for empty list" do
      assert {:error, :empty_tasks} = DagValidator.topological_order([])
    end

    test "handles fully independent tasks" do
      tasks = [
        %{depends_on: []},
        %{depends_on: []},
        %{depends_on: []}
      ]

      assert {:ok, order} = DagValidator.topological_order(tasks)
      assert Enum.sort(order) == [1, 2, 3]
    end
  end

  describe "resolve_indices_to_ids/2" do
    test "correctly maps indices to IDs" do
      tasks = [
        %{description: "first", depends_on: []},
        %{description: "second", depends_on: [1]},
        %{description: "third", depends_on: [1, 2]}
      ]

      index_id_pairs = [{1, "task-aaa"}, {2, "task-bbb"}, {3, "task-ccc"}]

      result = DagValidator.resolve_indices_to_ids(index_id_pairs, tasks)

      assert Enum.at(result, 0).depends_on == []
      assert Enum.at(result, 1).depends_on == ["task-aaa"]
      assert Enum.at(result, 2).depends_on == ["task-aaa", "task-bbb"]
    end

    test "preserves other task fields" do
      tasks = [%{description: "do stuff", priority: :high, depends_on: []}]
      index_id_pairs = [{1, "id-1"}]

      [result] = DagValidator.resolve_indices_to_ids(index_id_pairs, tasks)

      assert result.description == "do stuff"
      assert result.priority == :high
      assert result.depends_on == []
    end
  end
end
