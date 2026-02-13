defmodule AgentCom.XML.Schemas.GoalTest do
  use ExUnit.Case, async: true

  alias AgentCom.XML.Schemas.Goal

  describe "new/1 with keyword list" do
    test "creates goal with required fields from keyword list" do
      {:ok, goal} = Goal.new(id: "g-001", title: "Test Goal")
      assert goal.id == "g-001"
      assert goal.title == "Test Goal"
      assert goal.priority == "normal"
      assert goal.success_criteria == []
    end

    test "creates goal with all fields from keyword list" do
      {:ok, goal} =
        Goal.new(
          id: "g-001",
          title: "Test",
          description: "Desc",
          priority: "urgent",
          success_criteria: ["A", "B"],
          source: "api",
          repo: "AgentCom",
          created_at: "2026-01-01T00:00:00Z",
          metadata: "meta"
        )

      assert goal.priority == "urgent"
      assert goal.success_criteria == ["A", "B"]
      assert goal.source == "api"
      assert goal.metadata == "meta"
    end
  end

  describe "new/1 with map" do
    test "creates goal with required fields from map" do
      {:ok, goal} = Goal.new(%{id: "g-002", title: "Map Goal"})
      assert goal.id == "g-002"
      assert goal.title == "Map Goal"
    end
  end

  describe "new/1 validation errors" do
    test "returns error when id is missing" do
      assert {:error, "goal id is required"} = Goal.new(%{title: "No ID"})
    end

    test "returns error when id is empty string" do
      assert {:error, "goal id is required"} = Goal.new(%{id: "", title: "Empty ID"})
    end

    test "returns error when title is missing" do
      assert {:error, "goal title is required"} = Goal.new(%{id: "g-001"})
    end

    test "returns error when title is empty string" do
      assert {:error, "goal title is required"} = Goal.new(%{id: "g-001", title: ""})
    end

    test "returns error for invalid priority" do
      assert {:error, msg} = Goal.new(%{id: "g-001", title: "Test", priority: "invalid"})
      assert msg =~ "priority"
    end

    test "returns error for invalid source" do
      assert {:error, msg} = Goal.new(%{id: "g-001", title: "Test", source: "invalid"})
      assert msg =~ "source"
    end
  end

  describe "default values" do
    test "priority defaults to normal" do
      {:ok, goal} = Goal.new(%{id: "g-def", title: "Defaults"})
      assert goal.priority == "normal"
    end

    test "success_criteria defaults to empty list" do
      {:ok, goal} = Goal.new(%{id: "g-def", title: "Defaults"})
      assert goal.success_criteria == []
    end
  end

  describe "from_simple_form/1" do
    test "parses goal from SimpleForm tuple" do
      simple_form =
        {"goal", [{"id", "g-sf"}, {"priority", "high"}], [
          {"title", [], ["SimpleForm Goal"]},
          {"description", [], ["Parsed from SimpleForm"]}
        ]}

      {:ok, goal} = Goal.from_simple_form(simple_form)
      assert goal.id == "g-sf"
      assert goal.title == "SimpleForm Goal"
      assert goal.description == "Parsed from SimpleForm"
      assert goal.priority == "high"
    end

    test "parses success_criteria list" do
      simple_form =
        {"goal", [{"id", "g-list"}], [
          {"title", [], ["List Goal"]},
          {"success-criteria", [], [
            {"criterion", [], ["First"]},
            {"criterion", [], ["Second"]}
          ]}
        ]}

      {:ok, goal} = Goal.from_simple_form(simple_form)
      assert goal.success_criteria == ["First", "Second"]
    end

    test "returns error for wrong root element" do
      {:error, msg} = Goal.from_simple_form({"proposal", [], []})
      assert msg =~ "expected <goal>"
    end
  end

  describe "Saxy.Builder protocol" do
    test "builds SimpleForm that can be encoded by Saxy" do
      goal = %Goal{id: "g-build", title: "Builder Test", priority: "normal"}
      simple_form = Saxy.Builder.build(goal)
      assert is_tuple(simple_form)

      # Should be encodable without error
      xml = Saxy.encode!(simple_form, version: "1.0")
      assert is_binary(xml)
      assert String.contains?(xml, "g-build")
    end
  end
end
