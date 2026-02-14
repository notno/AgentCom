defmodule AgentCom.SelfImprovement.LlmScanner do
  @moduledoc """
  LLM-assisted code review scanner via git diff analysis.

  Generates a diff of recent commits (up to 5) for a repository, caps the
  output to 50KB, and sends it to `AgentCom.ClaudeClient.identify_improvements/2`
  for analysis. Results are mapped to Finding structs with `scanner: :llm`.

  Budget is checked via `AgentCom.CostLedger.check_budget(:improving)` before
  making any API calls. If the budget is exhausted, returns an empty list
  without calling the LLM.
  """

  alias AgentCom.SelfImprovement.Finding

  require Logger

  @max_diff_bytes 50_000

  @doc """
  Scan a repository using LLM-assisted diff analysis.

  Returns `{:ok, [Finding.t()]}` or `{:error, term()}`.
  Returns `{:ok, []}` if budget is exhausted or no diff is available.
  """
  @spec scan(String.t(), String.t()) :: {:ok, [Finding.t()]} | {:error, term()}
  def scan(repo_path, repo_name) do
    Logger.debug("LlmScanner: starting scan of #{repo_name} at #{repo_path}")

    case AgentCom.CostLedger.check_budget(:improving) do
      :budget_exhausted ->
        Logger.debug("LlmScanner: budget exhausted, skipping LLM scan")
        {:ok, []}

      :ok ->
        do_scan(repo_path, repo_name)
    end
  rescue
    e ->
      Logger.warning("LlmScanner: unexpected error: #{inspect(e)}")
      {:error, {:unexpected, e}}
  catch
    :exit, reason ->
      Logger.warning("LlmScanner: exit caught: #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_scan(repo_path, repo_name) do
    case get_diff(repo_path) do
      {:ok, ""} ->
        Logger.debug("LlmScanner: no diff available for #{repo_name}")
        {:ok, []}

      {:ok, diff_text} ->
        capped_diff = String.slice(diff_text, 0, @max_diff_bytes)

        case AgentCom.ClaudeClient.identify_improvements(repo_name, capped_diff) do
          {:ok, improvements} when is_list(improvements) ->
            findings = Enum.map(improvements, &improvement_to_finding/1)
            Logger.debug("LlmScanner: found #{length(findings)} improvements for #{repo_name}")
            {:ok, findings}

          {:ok, _} ->
            {:ok, []}

          {:error, reason} ->
            Logger.warning("LlmScanner: ClaudeClient error: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("LlmScanner: diff error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_diff(repo_path) do
    try do
      # Try HEAD~5..HEAD first
      case System.cmd("git", ["diff", "HEAD~5..HEAD", "--stat"], cd: repo_path, stderr_to_stdout: true) do
        {_output, 0} ->
          # --stat succeeded, get the full diff
          {full_diff, _} = System.cmd("git", ["diff", "HEAD~5..HEAD"], cd: repo_path, stderr_to_stdout: true)
          {:ok, full_diff}

        _ ->
          # Less than 5 commits, try HEAD~1..HEAD
          try_shorter_diff(repo_path)
      end
    rescue
      e in ErlangError ->
        Logger.debug("LlmScanner: git command failed: #{inspect(e)}")
        {:error, :git_unavailable}
    end
  end

  defp try_shorter_diff(repo_path) do
    try do
      case System.cmd("git", ["diff", "HEAD~1..HEAD", "--stat"], cd: repo_path, stderr_to_stdout: true) do
        {_output, 0} ->
          {full_diff, _} = System.cmd("git", ["diff", "HEAD~1..HEAD"], cd: repo_path, stderr_to_stdout: true)
          {:ok, full_diff}

        _ ->
          {:ok, ""}
      end
    rescue
      _ -> {:ok, ""}
    end
  end

  defp improvement_to_finding(improvement) when is_map(improvement) do
    file_path =
      case improvement["files"] do
        [first | _] when is_binary(first) -> first
        _ -> "unknown"
      end

    category = improvement["category"] || "suggestion"
    title = improvement["title"] || ""
    description = improvement["description"] || ""

    %Finding{
      file_path: file_path,
      line_number: 0,
      scan_type: "llm_" <> category,
      description: title <> ": " <> description,
      severity: "low",
      suggested_action: description,
      effort: improvement["effort"] || "medium",
      scanner: :llm
    }
  end

  defp improvement_to_finding(_), do: nil
end
