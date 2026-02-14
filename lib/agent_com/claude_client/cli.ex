defmodule AgentCom.ClaudeClient.Cli do
  @moduledoc """
  Low-level System.cmd wrapper for Claude Code CLI invocations.

  Handles the mechanics of spawning `claude -p` with the correct arguments,
  writing prompts to temp files (to avoid the stdin >7000 char bug), and
  cleaning up after each invocation.

  ## Temp File Strategy

  All prompts are written to a temporary `.md` file and referenced in the
  CLI query argument. This avoids the known Claude Code CLI bug where stdin
  input exceeding ~7000 characters produces empty output (exit code 0).

  ## CLAUDECODE Environment Variable

  The `CLAUDECODE` env var is explicitly unset (`nil`) when spawning the
  CLI process. Claude Code refuses to run inside another Claude Code session,
  and if the hub was started from within a Claude Code context (e.g., during
  development), environment inheritance would cause "cannot be launched inside
  another Claude Code session" errors.
  """
  require Logger

  @doc """
  Execute a Claude Code CLI invocation for the given prompt type and params.

  Builds the prompt, writes it to a temp file, spawns `claude -p`, parses
  the response, and cleans up the temp file. Returns the parsed result or
  an error tuple.
  """
  @spec invoke(atom(), map(), map()) :: {:ok, term()} | {:error, term()}
  def invoke(prompt_type, params, state) do
    prompt = AgentCom.ClaudeClient.Prompt.build(prompt_type, params)
    tmp_path = write_temp_prompt(prompt)

    try do
      args = [
        "-p", "Read and follow the instructions in #{tmp_path}",
        "--output-format", "json",
        "--model", state.model,
        "--no-session-persistence"
      ]

      Logger.info("claude_cli_invoke",
        prompt_type: prompt_type,
        cli_path: state.cli_path,
        model: state.model
      )

      {output, exit_code} =
        System.cmd(state.cli_path, args,
          env: [{"CLAUDECODE", nil}],
          stderr_to_stdout: true
        )

      Logger.info("claude_cli_complete",
        prompt_type: prompt_type,
        exit_code: exit_code,
        output_bytes: byte_size(output)
      )

      AgentCom.ClaudeClient.Response.parse(output, exit_code, prompt_type)
    rescue
      e in ErlangError ->
        Logger.error("claude_cli_error", error: inspect(e), cli_path: state.cli_path)
        {:error, {:cli_error, e.original}}

      e ->
        Logger.error("claude_cli_error", error: inspect(e), cli_path: state.cli_path)
        {:error, {:cli_error, Exception.message(e)}}
    after
      File.rm(tmp_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp write_temp_prompt(prompt) do
    tmp_dir = System.tmp_dir!()
    path = Path.join(tmp_dir, "claude_prompt_#{System.unique_integer([:positive])}.md")
    File.write!(path, prompt)
    path
  end
end
