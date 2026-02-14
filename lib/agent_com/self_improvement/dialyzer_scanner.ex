defmodule AgentCom.SelfImprovement.DialyzerScanner do
  @moduledoc """
  Improvement scanner that integrates with Dialyzer for Elixir type analysis.

  Runs `mix dialyzer --format short --quiet` on a target repository and parses
  the short-format output (file:line:warning_type message) into Finding structs.

  Checks for `:dialyxir` dependency in mix.exs and for an existing PLT before
  running. Skips repos without Dialyxir or without a pre-built PLT to avoid
  triggering a 5-30 minute PLT build during scan cycles.

  All errors are handled gracefully -- the scanner never raises and returns
  an empty list on any failure.
  """

  alias AgentCom.SelfImprovement.Finding

  require Logger

  @high_severity_types ~w(pattern_match no_return)

  @line_pattern ~r/^(.+):(\d+):(\w+)\s+(.+)$/

  @doc """
  Scan a repository using Dialyzer and return a list of Finding structs.

  Returns `[]` if Dialyxir is not available, no PLT exists, the repo
  doesn't exist, or any error occurs during scanning.
  """
  @spec scan(String.t()) :: [Finding.t()]
  def scan(repo_path) do
    Logger.debug("DialyzerScanner: starting scan of #{repo_path}")

    findings =
      cond do
        not has_dialyxir?(repo_path) ->
          Logger.debug("DialyzerScanner: no :dialyxir dependency in #{repo_path}")
          []

        not has_plt?(repo_path) ->
          Logger.debug("DialyzerScanner: no PLT found in #{repo_path}, skipping")
          []

        true ->
          run_dialyzer(repo_path)
      end

    Logger.debug("DialyzerScanner: finished scan of #{repo_path}, found #{length(findings)} warnings")
    findings
  end

  @doc false
  defp has_dialyxir?(repo_path) do
    mix_exs = Path.join(repo_path, "mix.exs")

    case File.read(mix_exs) do
      {:ok, content} -> String.contains?(content, ":dialyxir")
      _ -> false
    end
  end

  defp has_plt?(repo_path) do
    # Check for PLT files in common locations
    plt_patterns = [
      Path.join([repo_path, "_build", "dev", "dialyxir_erlang-*.plt"]),
      Path.join([repo_path, "_build", "dev", "dialyzer", "*.plt"])
    ]

    Enum.any?(plt_patterns, fn pattern ->
      Path.wildcard(pattern) != []
    end)
  end

  defp run_dialyzer(repo_path) do
    try do
      case System.cmd("mix", ["dialyzer", "--format", "short", "--quiet"],
             cd: repo_path,
             stderr_to_stdout: true,
             env: [{"MIX_ENV", "dev"}]
           ) do
        {_output, 0} ->
          # Exit 0 = no warnings
          []

        {output, 2} ->
          # Exit 2 = warnings found
          parse_dialyzer_short(output)

        {_output, _other} ->
          # Other exit codes = error
          []
      end
    rescue
      e in ErlangError ->
        Logger.debug("DialyzerScanner: System.cmd failed: #{inspect(e)}")
        []
    end
  end

  defp parse_dialyzer_short(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(@line_pattern, line) do
        [_, file, line_no, warning_type, message] ->
          [warning_to_finding(file, line_no, warning_type, message)]

        _ ->
          []
      end
    end)
  end

  defp warning_to_finding(file, line_no, warning_type, message) do
    %Finding{
      file_path: file,
      line_number: String.to_integer(line_no),
      scan_type: "dialyzer_#{warning_type}",
      description: message,
      severity: dialyzer_severity(warning_type),
      suggested_action: "Fix Dialyzer warning: #{message}",
      effort: "medium",
      scanner: :dialyzer
    }
  end

  defp dialyzer_severity(warning_type) when warning_type in @high_severity_types, do: "high"
  defp dialyzer_severity(_), do: "medium"
end
