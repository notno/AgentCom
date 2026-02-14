defmodule AgentCom.Contemplation do
  @moduledoc """
  Top-level module orchestrating proposal generation and scalability analysis.

  Stateless library module (not a GenServer) following the RepoScanner pattern.
  Called by HubFSM when entering the `:contemplating` state.

  ## Orchestration Flow

  1. Call `ClaudeClient.generate_proposals/1` with codebase context
  2. Convert LLM proposals to `Proposal` structs
  3. Write proposals via `ProposalWriter`
  4. Run `ScalabilityAnalyzer`
  5. Return combined report

  ## Report Shape

      %{
        proposals: [Proposal.t()],
        proposal_paths: [String.t()],
        scalability: map(),
        generated_at: integer()
      }
  """

  alias AgentCom.Contemplation.{ProposalWriter, ScalabilityAnalyzer}
  alias AgentCom.XML.Schemas.Proposal

  require Logger

  @max_proposals 3

  @doc """
  Run a full contemplation cycle.

  Options:
  - `:context` -- map with codebase context for proposal generation
  - `:skip_llm` -- if true, skip LLM proposal generation (default false)

  Returns `{:ok, report}` or `{:error, reason}`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    context = Keyword.get(opts, :context, default_context())
    skip_llm = Keyword.get(opts, :skip_llm, false)

    Logger.info("contemplation_started")

    # Step 1-3: Generate and write proposals
    {proposals, proposal_paths} =
      if skip_llm do
        {[], []}
      else
        generate_and_write_proposals(context)
      end

    # Step 4: Run scalability analysis
    scalability = ScalabilityAnalyzer.analyze()

    report = %{
      proposals: proposals,
      proposal_paths: proposal_paths,
      scalability: scalability,
      generated_at: System.system_time(:millisecond)
    }

    Logger.info("contemplation_complete",
      proposals: length(proposals),
      scalability_state: scalability.current_state
    )

    {:ok, report}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp generate_and_write_proposals(context) do
    case generate_proposals(context) do
      {:ok, proposal_maps} ->
        proposals =
          proposal_maps
          |> Enum.take(@max_proposals)
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {map, idx} ->
            case to_proposal_struct(map, idx) do
              {:ok, proposal} -> [proposal]
              {:error, _} -> []
            end
          end)

        case ProposalWriter.write_proposals(proposals) do
          {:ok, paths} -> {proposals, paths}
        end

      {:error, reason} ->
        Logger.warning("contemplation_proposal_generation_failed", reason: inspect(reason))
        {[], []}
    end
  end

  defp generate_proposals(context) do
    try do
      AgentCom.ClaudeClient.generate_proposals(context)
    catch
      :exit, reason ->
        {:error, {:client_unavailable, reason}}
    end
  end

  defp to_proposal_struct(map, idx) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Proposal.new(%{
      id: "prop-#{System.system_time(:millisecond)}-#{idx}",
      title: Map.get(map, :title, ""),
      problem: Map.get(map, :problem),
      solution: Map.get(map, :solution),
      description: Map.get(map, :description, ""),
      rationale: Map.get(map, :rationale),
      why_now: Map.get(map, :why_now),
      why_not: Map.get(map, :why_not),
      impact: Map.get(map, :impact, "medium"),
      effort: Map.get(map, :effort, "medium"),
      repo: "AgentCom",
      related_files: Map.get(map, :related_files, []),
      dependencies: Map.get(map, :dependencies, []),
      proposed_at: now
    })
  end

  defp default_context do
    fsm_history =
      try do
        AgentCom.HubFSM.history(limit: 20)
        |> Enum.map(fn entry ->
          "#{entry.from} -> #{entry.to}: #{entry.reason}"
        end)
        |> Enum.join("\n")
      catch
        :exit, _ -> ""
      end

    out_of_scope = read_project_out_of_scope()

    # Add scalability summary from analyzer
    scalability = ScalabilityAnalyzer.analyze()
    scalability_summary = scalability.recommendation

    %{
      tech_stack: "Elixir/Phoenix/OTP",
      codebase_summary: "AgentCom autonomous hub with FSM-driven goal execution, self-improvement scanning, and multi-agent task scheduling.",
      fsm_history: fsm_history,
      out_of_scope: out_of_scope,
      scalability_summary: scalability_summary,
      error_summary: ""
    }
  end

  defp read_project_out_of_scope do
    path = Path.join([File.cwd!(), ".planning", "PROJECT.md"])

    case File.read(path) do
      {:ok, content} ->
        case Regex.run(~r/## Out of Scope\s*\n(.*?)(?=\n## |\z)/s, content) do
          [_, section] -> String.trim(section)
          nil -> ""
        end

      {:error, _} ->
        ""
    end
  end
end
