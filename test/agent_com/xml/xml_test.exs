defmodule AgentCom.XMLTest do
  use ExUnit.Case, async: true

  alias AgentCom.XML
  alias AgentCom.XML.Schemas.{Goal, ScanResult, FsmSnapshot, Improvement, Proposal}

  # ---------------------------------------------------------------------------
  # Round-trip encode/decode tests for all 5 schema types
  # ---------------------------------------------------------------------------

  describe "round-trip encode/decode" do
    test "Goal with all fields round-trips correctly" do
      goal = %Goal{
        id: "g-001",
        title: "Implement rate limiting",
        description: "Add rate limiting to webhook endpoint",
        priority: "high",
        success_criteria: ["Returns 429 after 100 req/min", "Configurable via Config"],
        source: "api",
        repo: "AgentCom",
        created_at: "2026-01-01T00:00:00Z",
        metadata: "extra info"
      }

      {:ok, xml} = XML.encode(goal)
      {:ok, decoded} = XML.decode(xml, :goal)

      assert decoded.id == goal.id
      assert decoded.title == goal.title
      assert decoded.description == goal.description
      assert decoded.priority == goal.priority
      assert decoded.success_criteria == goal.success_criteria
      assert decoded.source == goal.source
      assert decoded.repo == goal.repo
      assert decoded.created_at == goal.created_at
      assert decoded.metadata == goal.metadata
    end

    test "ScanResult with all fields round-trips correctly" do
      scan_result = %ScanResult{
        id: "sr-001",
        repo: "AgentCom",
        scan_type: "test_gap",
        file_path: "lib/agent_com/scheduler.ex",
        description: "Module has no corresponding test file",
        severity: "high",
        suggested_action: "Create test/agent_com/scheduler_test.exs",
        scanned_at: "2026-01-01T00:00:00Z",
        metadata: "scan metadata"
      }

      {:ok, xml} = XML.encode(scan_result)
      {:ok, decoded} = XML.decode(xml, :scan_result)

      assert decoded.id == scan_result.id
      assert decoded.repo == scan_result.repo
      assert decoded.scan_type == scan_result.scan_type
      assert decoded.file_path == scan_result.file_path
      assert decoded.description == scan_result.description
      assert decoded.severity == scan_result.severity
      assert decoded.suggested_action == scan_result.suggested_action
      assert decoded.scanned_at == scan_result.scanned_at
      assert decoded.metadata == scan_result.metadata
    end

    test "FsmSnapshot with transition_history round-trips correctly" do
      snapshot = %FsmSnapshot{
        state: "executing",
        since: "2026-01-01T00:00:00Z",
        cycle_count: "42",
        current_goal_id: "g-001",
        queue_depth: "3",
        budget_remaining: "0.50",
        snapshot_at: "2026-01-01T01:00:00Z",
        transition_history: [
          %{"from" => "resting", "to" => "executing", "at" => "2026-01-01T00:00:00Z"},
          %{"from" => "executing", "to" => "improving", "at" => "2026-01-01T00:30:00Z"}
        ]
      }

      {:ok, xml} = XML.encode(snapshot)
      {:ok, decoded} = XML.decode(xml, :fsm_snapshot)

      assert decoded.state == snapshot.state
      assert decoded.since == snapshot.since
      assert decoded.cycle_count == snapshot.cycle_count
      assert decoded.current_goal_id == snapshot.current_goal_id
      assert decoded.queue_depth == snapshot.queue_depth
      assert decoded.budget_remaining == snapshot.budget_remaining
      assert decoded.snapshot_at == snapshot.snapshot_at
      assert decoded.transition_history == snapshot.transition_history
    end

    test "Improvement with all fields round-trips correctly" do
      improvement = %Improvement{
        id: "imp-001",
        repo: "AgentCom",
        file_path: "lib/agent_com/scheduler.ex",
        improvement_type: "test",
        description: "Add unit tests for scheduler module",
        status: "identified",
        scan_result_id: "sr-001",
        attempted_at: "2026-01-01T00:00:00Z",
        completed_at: "2026-01-01T01:00:00Z",
        metadata: "improvement metadata"
      }

      {:ok, xml} = XML.encode(improvement)
      {:ok, decoded} = XML.decode(xml, :improvement)

      assert decoded.id == improvement.id
      assert decoded.repo == improvement.repo
      assert decoded.file_path == improvement.file_path
      assert decoded.improvement_type == improvement.improvement_type
      assert decoded.description == improvement.description
      assert decoded.status == improvement.status
      assert decoded.scan_result_id == improvement.scan_result_id
      assert decoded.attempted_at == improvement.attempted_at
      assert decoded.completed_at == improvement.completed_at
      assert decoded.metadata == improvement.metadata
    end

    test "Proposal with related_files round-trips correctly" do
      proposal = %Proposal{
        id: "prop-001",
        title: "Add circuit breaker",
        description: "Implement circuit breaker pattern for external API calls",
        rationale: "Three failures in last 24 hours suggest instability",
        impact: "high",
        effort: "medium",
        repo: "AgentCom",
        related_files: ["lib/agent_com/config.ex", "lib/agent_com/scheduler.ex"],
        proposed_at: "2026-01-01T00:00:00Z",
        metadata: "proposal metadata"
      }

      {:ok, xml} = XML.encode(proposal)
      {:ok, decoded} = XML.decode(xml, :proposal)

      assert decoded.id == proposal.id
      assert decoded.title == proposal.title
      assert decoded.description == proposal.description
      assert decoded.rationale == proposal.rationale
      assert decoded.impact == proposal.impact
      assert decoded.effort == proposal.effort
      assert decoded.repo == proposal.repo
      assert decoded.related_files == proposal.related_files
      assert decoded.proposed_at == proposal.proposed_at
      assert decoded.metadata == proposal.metadata
    end
  end

  # ---------------------------------------------------------------------------
  # Nil optional field tests
  # ---------------------------------------------------------------------------

  describe "nil optional fields" do
    test "Goal with only required fields round-trips, nil fields stay nil" do
      goal = %Goal{id: "g-min", title: "Minimal goal", priority: "normal"}

      {:ok, xml} = XML.encode(goal)
      {:ok, decoded} = XML.decode(xml, :goal)

      assert decoded.id == "g-min"
      assert decoded.title == "Minimal goal"
      assert decoded.priority == "normal"
      assert decoded.description == nil
      assert decoded.source == nil
      assert decoded.repo == nil
      assert decoded.created_at == nil
      assert decoded.metadata == nil
      assert decoded.success_criteria == []
    end

    test "ScanResult with only required fields round-trips" do
      sr = %ScanResult{id: "sr-min", repo: "Test", description: "Minimal", severity: "medium"}

      {:ok, xml} = XML.encode(sr)
      {:ok, decoded} = XML.decode(xml, :scan_result)

      assert decoded.id == "sr-min"
      assert decoded.repo == "Test"
      assert decoded.description == "Minimal"
      assert decoded.file_path == nil
      assert decoded.suggested_action == nil
      assert decoded.metadata == nil
    end
  end

  # ---------------------------------------------------------------------------
  # List field preservation tests
  # ---------------------------------------------------------------------------

  describe "list field preservation" do
    test "Goal success_criteria list survives encode/decode" do
      goal = %Goal{
        id: "g-list",
        title: "List test",
        success_criteria: ["Alpha", "Beta", "Gamma"]
      }

      {:ok, xml} = XML.encode(goal)
      {:ok, decoded} = XML.decode(xml, :goal)

      assert decoded.success_criteria == ["Alpha", "Beta", "Gamma"]
      assert length(decoded.success_criteria) == 3
    end

    test "Proposal related_files list survives encode/decode" do
      proposal = %Proposal{
        id: "prop-list",
        title: "List test",
        description: "Test related_files",
        related_files: ["file1.ex", "file2.ex", "file3.ex"]
      }

      {:ok, xml} = XML.encode(proposal)
      {:ok, decoded} = XML.decode(xml, :proposal)

      assert decoded.related_files == ["file1.ex", "file2.ex", "file3.ex"]
      assert length(decoded.related_files) == 3
    end

    test "FsmSnapshot transition_history survives encode/decode" do
      snapshot = %FsmSnapshot{
        state: "resting",
        since: "2026-01-01T00:00:00Z",
        snapshot_at: "2026-01-01T01:00:00Z",
        transition_history: [
          %{"from" => "resting", "to" => "executing", "at" => "2026-01-01T00:00:00Z"}
        ]
      }

      {:ok, xml} = XML.encode(snapshot)
      {:ok, decoded} = XML.decode(xml, :fsm_snapshot)

      assert length(decoded.transition_history) == 1
      [transition] = decoded.transition_history
      assert transition["from"] == "resting"
      assert transition["to"] == "executing"
      assert transition["at"] == "2026-01-01T00:00:00Z"
    end

    test "empty list fields survive encode/decode" do
      goal = %Goal{id: "g-empty", title: "Empty list", success_criteria: []}

      {:ok, xml} = XML.encode(goal)
      {:ok, decoded} = XML.decode(xml, :goal)

      assert decoded.success_criteria == []
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling tests
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "decode/2 with empty string returns error tuple" do
      result = XML.decode("", :goal)
      assert {:error, _reason} = result
    end

    test "decode/2 with malformed XML returns error tuple" do
      result = XML.decode("<goal><broken", :goal)
      assert {:error, _reason} = result
    end

    test "decode/2 with unknown schema type returns error" do
      result = XML.decode("<foo/>", :nonexistent)
      assert {:error, _reason} = result
    end

    test "encode/1 with non-struct argument returns error tuple" do
      assert {:error, _reason} = XML.encode("not a struct")
      assert {:error, _reason} = XML.encode(%{just: "a map"})
      assert {:error, _reason} = XML.encode(42)
    end

    test "decode/2 with non-binary first argument returns error" do
      result = XML.decode(42, :goal)
      assert {:error, _reason} = result
    end
  end

  # ---------------------------------------------------------------------------
  # schema_types/0 and to_map/1 tests
  # ---------------------------------------------------------------------------

  describe "schema_types/0" do
    test "returns all 5 schema types" do
      types = XML.schema_types()
      assert :goal in types
      assert :scan_result in types
      assert :fsm_snapshot in types
      assert :improvement in types
      assert :proposal in types
      assert length(types) == 5
    end
  end

  describe "to_map/1" do
    test "converts struct to string-keyed map, omitting nil values" do
      goal = %Goal{id: "g-map", title: "Map test", priority: "normal"}
      map = XML.to_map(goal)

      assert map["id"] == "g-map"
      assert map["title"] == "Map test"
      assert map["priority"] == "normal"
      refute Map.has_key?(map, "description")
      refute Map.has_key?(map, "source")
    end
  end

  # ---------------------------------------------------------------------------
  # Bang function tests
  # ---------------------------------------------------------------------------

  describe "encode!/1 and decode!/2" do
    test "encode!/1 returns XML string directly" do
      goal = %Goal{id: "g-bang", title: "Bang test"}
      xml = XML.encode!(goal)
      assert is_binary(xml)
      assert String.contains?(xml, "g-bang")
    end

    test "encode!/1 raises on invalid input" do
      assert_raise ArgumentError, fn ->
        XML.encode!("not a struct")
      end
    end

    test "decode!/2 returns struct directly" do
      goal = %Goal{id: "g-bang", title: "Bang test"}
      {:ok, xml} = XML.encode(goal)
      decoded = XML.decode!(xml, :goal)
      assert decoded.id == "g-bang"
    end

    test "decode!/2 raises on malformed XML" do
      assert_raise ArgumentError, fn ->
        XML.decode!("<broken", :goal)
      end
    end
  end
end
