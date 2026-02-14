defmodule AgentCom.ContemplationTest do
  @moduledoc """
  Tests for the Contemplation orchestrator module.

  Uses skip_llm: true to avoid ClaudeClient dependency.
  async: false because it accesses GenServers (HubFSM, MetricsCollector) via catch blocks.
  """

  use ExUnit.Case, async: false

  alias AgentCom.Contemplation

  describe "run/1" do
    test "returns ok with report structure when skip_llm" do
      assert {:ok, report} = Contemplation.run(skip_llm: true)
      assert Map.has_key?(report, :proposals)
      assert Map.has_key?(report, :proposal_paths)
      assert Map.has_key?(report, :scalability)
      assert Map.has_key?(report, :generated_at)
      assert report.proposals == []
      assert report.proposal_paths == []
    end

    test "scalability analysis always runs even with skip_llm" do
      assert {:ok, report} = Contemplation.run(skip_llm: true)
      assert is_map(report.scalability)
      assert Map.has_key?(report.scalability, :current_state)
      assert Map.has_key?(report.scalability, :recommendation)
    end

    test "respects custom context" do
      context = %{
        tech_stack: "Test Stack",
        codebase_summary: "Test summary",
        fsm_history: "",
        out_of_scope: "everything"
      }

      # skip_llm so context is accepted but not used for LLM call
      assert {:ok, report} = Contemplation.run(context: context, skip_llm: true)
      assert report.proposals == []
    end

    test "generated_at is a recent millisecond timestamp" do
      assert {:ok, report} = Contemplation.run(skip_llm: true)
      now = System.system_time(:millisecond)
      # Should be within last 5 seconds
      assert report.generated_at > now - 5_000
      assert report.generated_at <= now
    end
  end
end
