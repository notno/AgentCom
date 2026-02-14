defmodule AgentCom.SelfImprovement do
  @moduledoc """
  Stateless library module for autonomous codebase improvement scanning.

  Called by HubFSM during the Improving state. Orchestrates three scanning layers:

  1. **Elixir tools** -- Credo (code quality) and Dialyzer (type analysis)
  2. **Deterministic analysis** -- test gaps, doc gaps, dead dependencies
  3. **LLM-assisted review** -- git diff analysis via ClaudeClient

  Findings are filtered through ImprovementHistory cooldowns and oscillation
  detection before being submitted as low-priority goals to GoalBacklog.
  A max-findings budget prevents goal flooding.
  """

  alias AgentCom.SelfImprovement.{
    CredoScanner,
    DeterministicScanner,
    DialyzerScanner,
    Finding,
    ImprovementHistory,
    LlmScanner
  }

  require Logger

  @default_max_findings 5

  @severity_order %{"high" => 0, "medium" => 1, "low" => 2}

  @doc """
  Scan a single repository across all scanning layers.

  Options:
  - `:max_findings` -- maximum findings to return (default #{@default_max_findings})
  - `:repo_name` -- repository name for history (default `Path.basename(repo_path)`)

  Returns `{:ok, [Finding.t()]}`.
  """
  @spec scan_repo(String.t(), keyword()) :: {:ok, [Finding.t()]}
  def scan_repo(repo_path, opts \\ []) do
    max_findings = Keyword.get(opts, :max_findings, @default_max_findings)
    repo_name = Keyword.get(opts, :repo_name, Path.basename(repo_path))

    Logger.debug("SelfImprovement: scanning #{repo_name} at #{repo_path}, max=#{max_findings}")

    # Initialize ImprovementHistory (safe re-init)
    ImprovementHistory.init()

    # Layer 1: Elixir tools
    credo_findings = CredoScanner.scan(repo_path)
    dialyzer_findings = DialyzerScanner.scan(repo_path)

    # Layer 2: Deterministic analysis
    deterministic_findings = DeterministicScanner.scan(repo_path)

    # Combine all deterministic findings
    all_deterministic = credo_findings ++ dialyzer_findings ++ deterministic_findings

    # Filter through ImprovementHistory
    filtered =
      all_deterministic
      |> ImprovementHistory.filter_cooled_down(repo_name)
      |> ImprovementHistory.filter_oscillating(repo_name)

    # Sort by severity (high > medium > low)
    sorted = Enum.sort_by(filtered, fn f -> Map.get(@severity_order, f.severity, 3) end)

    # Take up to max_findings from deterministic
    deterministic_take = Enum.take(sorted, max_findings)
    remaining_budget = max_findings - length(deterministic_take)

    # Layer 3: LLM scan (only if budget remains)
    llm_findings =
      if remaining_budget > 0 do
        case LlmScanner.scan(repo_path, repo_name) do
          {:ok, findings} ->
            findings
            |> Enum.reject(&is_nil/1)
            |> ImprovementHistory.filter_cooled_down(repo_name)
            |> ImprovementHistory.filter_oscillating(repo_name)
            |> Enum.take(remaining_budget)

          {:error, _} ->
            []
        end
      else
        []
      end

    combined = deterministic_take ++ llm_findings

    Logger.debug("SelfImprovement: #{repo_name} scan complete, #{length(combined)} findings (#{length(deterministic_take)} deterministic, #{length(llm_findings)} llm)")

    {:ok, combined}
  end

  @doc """
  Scan all repositories in the RepoRegistry.

  Options:
  - `:base_dir` -- base directory for repo checkouts (default from config or ".")
  - `:max_findings` -- total max findings across all repos (default #{@default_max_findings})

  Returns `{:ok, [Finding.t()]}`.
  """
  @spec scan_all(keyword()) :: {:ok, [Finding.t()]}
  def scan_all(opts \\ []) do
    max_findings = Keyword.get(opts, :max_findings, @default_max_findings)

    base_dir =
      Keyword.get(opts, :base_dir) ||
        Application.get_env(:agent_com, :repos_base_dir, ".")

    repos =
      try do
        AgentCom.RepoRegistry.list_repos()
      catch
        :exit, _ -> []
      end

    Logger.debug("SelfImprovement: scanning #{length(repos)} repos from registry")

    {all_findings, _remaining} =
      Enum.reduce(repos, {[], max_findings}, fn repo, {acc, budget} ->
        if budget <= 0 do
          {acc, 0}
        else
          repo_name = repo_name_from_entry(repo)
          local_path = Path.join(base_dir, repo_name)

          if File.dir?(local_path) do
            case scan_repo(local_path, max_findings: budget, repo_name: repo_name) do
              {:ok, findings} ->
                {acc ++ findings, budget - length(findings)}
            end
          else
            Logger.debug("SelfImprovement: skipping #{repo_name}, path #{local_path} not found")
            {acc, budget}
          end
        end
      end)

    {:ok, all_findings}
  end

  @doc """
  Submit findings as low-priority goals to GoalBacklog.

  For each finding, creates a goal with priority "low" and source "self_improvement".
  Records submitted findings in ImprovementHistory.

  Returns a list of `{:ok, goal}` or `{:error, term()}` results.
  """
  @spec submit_findings_as_goals([Finding.t()], String.t()) :: [{:ok, map()} | {:error, term()}]
  def submit_findings_as_goals(findings, repo_name) do
    Enum.map(findings, fn finding ->
      result =
        try do
          AgentCom.GoalBacklog.submit(%{
            description: finding.description,
            success_criteria: finding.suggested_action,
            priority: "low",
            source: "self_improvement",
            tags: [finding.scan_type, "auto-scan"],
            repo: repo_name
          })
        catch
          :exit, reason ->
            Logger.warning("SelfImprovement: GoalBacklog.submit failed: #{inspect(reason)}")
            {:error, {:exit, reason}}
        end

      case result do
        {:ok, _goal} ->
          ImprovementHistory.record_improvement(
            repo_name,
            finding.file_path,
            finding.scan_type,
            finding.description
          )

        _ ->
          :ok
      end

      result
    end)
  end

  @doc """
  Run a full improvement cycle: scan all repos, submit findings as goals.

  Returns `{:ok, %{findings: integer, goals_submitted: integer}}`.
  """
  @spec run_improvement_cycle(keyword()) :: {:ok, %{findings: integer(), goals_submitted: integer()}}
  def run_improvement_cycle(opts \\ []) do
    Logger.info("SelfImprovement: starting improvement cycle")

    case scan_all(opts) do
      {:ok, findings} ->
        results =
          if length(findings) > 0 do
            submit_findings_as_goals(findings, "agentcom")
          else
            []
          end

        goals_submitted = Enum.count(results, fn r -> match?({:ok, _}, r) end)

        Logger.info("SelfImprovement: cycle complete, #{length(findings)} findings, #{goals_submitted} goals submitted")

        {:ok, %{findings: length(findings), goals_submitted: goals_submitted}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp repo_name_from_entry(repo) do
    # RepoRegistry entries have :url and :name fields
    # Derive local directory name from URL
    cond do
      is_map(repo) and Map.has_key?(repo, :name) ->
        repo.name

      is_map(repo) and Map.has_key?(repo, :url) ->
        repo.url
        |> String.split("/")
        |> List.last()
        |> String.replace(".git", "")

      true ->
        "unknown"
    end
  end
end
