defmodule Mix.Tasks.AgentCom.GenToken do
  @moduledoc """
  Generate an auth token for an agent.

  ## Usage

      mix agent_com.gen_token --agent-id my-agent
  """
  use Mix.Task

  @shortdoc "Generate an auth token for an agent"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [agent_id: :string])

    agent_id = opts[:agent_id] || raise "Usage: mix agent_com.gen_token --agent-id <agent_id>"

    # Start the app so Auth GenServer is running
    Mix.Task.run("app.start")

    {:ok, token} = AgentCom.Auth.generate(agent_id)

    Mix.shell().info("""

    Token generated for #{agent_id}:

      #{token}

    Add this to your OpenClaw config or agent connection settings.
    Store it safely — it won't be shown again (only the prefix is stored for display).
    """)
  end
end
