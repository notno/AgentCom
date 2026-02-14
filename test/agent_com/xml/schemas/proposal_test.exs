defmodule AgentCom.XML.Schemas.ProposalTest do
  use ExUnit.Case, async: true

  alias AgentCom.XML.Schemas.Proposal

  describe "new/1" do
    test "creates proposal with all enriched fields" do
      attrs = %{
        id: "prop-test-1",
        title: "Test Proposal",
        problem: "Things break under load",
        solution: "Add circuit breaker",
        description: "Implement circuit breaker pattern",
        rationale: "3 failures in 24 hours",
        why_now: "Approaching production scale",
        why_not: "Adds complexity",
        impact: "high",
        effort: "medium",
        repo: "AgentCom",
        related_files: ["lib/agent_com/claude_client.ex"],
        dependencies: ["ClaudeClient refactor"],
        proposed_at: "2026-02-13T00:00:00Z"
      }

      assert {:ok, proposal} = Proposal.new(attrs)
      assert proposal.problem == "Things break under load"
      assert proposal.solution == "Add circuit breaker"
      assert proposal.why_now == "Approaching production scale"
      assert proposal.why_not == "Adds complexity"
      assert proposal.dependencies == ["ClaudeClient refactor"]
      assert proposal.related_files == ["lib/agent_com/claude_client.ex"]
    end

    test "creates proposal with minimal required fields" do
      attrs = %{id: "p1", title: "Title", description: "Desc"}
      assert {:ok, proposal} = Proposal.new(attrs)
      assert proposal.problem == nil
      assert proposal.why_now == nil
      assert proposal.dependencies == []
    end

    test "rejects missing id" do
      assert {:error, _} = Proposal.new(%{title: "T", description: "D"})
    end

    test "rejects missing title" do
      assert {:error, _} = Proposal.new(%{id: "1", description: "D"})
    end

    test "rejects invalid impact" do
      attrs = %{id: "1", title: "T", description: "D", impact: "extreme"}
      assert {:error, msg} = Proposal.new(attrs)
      assert msg =~ "impact"
    end
  end

  describe "XML round-trip" do
    test "encode and decode preserves enriched fields" do
      {:ok, proposal} = Proposal.new(%{
        id: "rt-1",
        title: "Round Trip",
        problem: "Test problem",
        solution: "Test solution",
        description: "Test desc",
        rationale: "Test rationale",
        why_now: "Test why now",
        why_not: "Test why not",
        impact: "high",
        effort: "small",
        repo: "AgentCom",
        related_files: ["lib/foo.ex", "lib/bar.ex"],
        dependencies: ["dep-a", "dep-b"],
        proposed_at: "2026-02-13T00:00:00Z"
      })

      assert {:ok, xml} = AgentCom.XML.encode(proposal)
      assert is_binary(xml)
      assert xml =~ "why-now"
      assert xml =~ "why-not"
      assert xml =~ "dependencies"

      # Decode back
      assert {:ok, decoded} = AgentCom.XML.decode(xml, :proposal)
      assert decoded.id == "rt-1"
      assert decoded.problem == "Test problem"
      assert decoded.solution == "Test solution"
      assert decoded.why_now == "Test why now"
      assert decoded.why_not == "Test why not"
      assert decoded.dependencies == ["dep-a", "dep-b"]
      assert decoded.related_files == ["lib/foo.ex", "lib/bar.ex"]
    end

    test "encode and decode with nil optional fields" do
      {:ok, proposal} = Proposal.new(%{
        id: "rt-2",
        title: "Minimal",
        description: "Minimal desc"
      })

      assert {:ok, xml} = AgentCom.XML.encode(proposal)
      assert {:ok, decoded} = AgentCom.XML.decode(xml, :proposal)
      assert decoded.id == "rt-2"
      assert decoded.problem == nil
      assert decoded.dependencies == []
    end
  end
end
