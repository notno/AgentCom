defmodule AgentCom.SelfImprovement.CredoScanner do
  @moduledoc """
  Improvement scanner that integrates with Credo for Elixir code quality analysis.

  Runs `mix credo --format json --all` on a target repository and parses the
  structured JSON output into Finding structs. Checks for `:credo` dependency
  in the target repo's mix.exs before attempting to run.

  Credo returns exit code 1 when issues are found, which is normal operation.
  All errors are handled gracefully -- the scanner never raises and returns
  an empty list on any failure.
  """

  alias AgentCom.SelfImprovement.Finding

  require Logger

  @doc """
  Scan a repository using Credo and return a list of Finding structs.

  Returns `[]` if Credo is not available, the repo doesn't exist,
  or any error occurs during scanning.
  """
  @spec scan(String.t()) :: [Finding.t()]
  def scan(repo_path) do
    Logger.debug("CredoScanner: starting scan of #{repo_path}")

    findings =
      if has_credo?(repo_path) do
        run_credo(repo_path)
      else
        []
      end

    Logger.debug("CredoScanner: finished scan of #{repo_path}, found #{length(findings)} issues")
    findings
  end

  @doc false
  defp has_credo?(repo_path) do
    mix_exs = Path.join(repo_path, "mix.exs")

    case File.read(mix_exs) do
      {:ok, content} -> String.contains?(content, ":credo")
      _ -> false
    end
  end

  defp run_credo(repo_path) do
    try do
      case System.cmd("mix", ["credo", "--format", "json", "--all"],
             cd: repo_path,
             stderr_to_stdout: true,
             env: [{"MIX_ENV", "dev"}]
           ) do
        {output, _exit_code} ->
          parse_credo_json(output)
      end
    rescue
      e in ErlangError ->
        Logger.debug("CredoScanner: System.cmd failed: #{inspect(e)}")
        []
    end
  end

  defp parse_credo_json(output) do
    case Jason.decode(output) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        Enum.map(issues, &issue_to_finding/1)

      _ ->
        []
    end
  end

  defp issue_to_finding(issue) do
    %Finding{
      file_path: issue["filename"] || "unknown",
      line_number: issue["line_no"] || 0,
      scan_type: "credo_" <> (issue["category"] || "unknown"),
      description: issue["message"] || "No description",
      severity: credo_priority_to_severity(issue["priority"]),
      suggested_action: issue["message"] || "Review Credo finding",
      effort: "small",
      scanner: :credo
    }
  end

  defp credo_priority_to_severity(priority) when is_number(priority) and priority >= 10, do: "high"
  defp credo_priority_to_severity(priority) when is_number(priority) and priority >= 1, do: "medium"
  defp credo_priority_to_severity(_), do: "low"
end
