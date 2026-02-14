defmodule AgentCom.ClaudeClient.Prompt do
  @moduledoc "Prompt template builder. Implemented in Plan 26-02."

  # TODO: Plan 26-02 provides real implementation
  @spec build(atom(), map()) :: String.t()
  def build(_prompt_type, _params), do: "placeholder prompt"
end
