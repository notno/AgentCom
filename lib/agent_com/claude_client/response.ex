defmodule AgentCom.ClaudeClient.Response do
  @moduledoc "Response parser. Implemented in Plan 26-02."

  # TODO: Plan 26-02 provides real implementation
  @spec parse(String.t(), non_neg_integer(), atom()) :: {:ok, map()} | {:error, term()}
  def parse(raw_output, _exit_code, _prompt_type), do: {:ok, %{raw: raw_output}}
end
