defmodule AgentCom.TestFactory do
  @moduledoc """
  Factory functions for creating test agents, tasks, and cleaning up.

  Provides convenience functions that wrap the multi-step processes of
  agent registration and task submission, reducing boilerplate in tests.

  ## Usage

      agent = AgentCom.TestFactory.create_agent(capabilities: ["code"])
      {:ok, task} = AgentCom.TestFactory.submit_task(description: "do work")

      # ... test assertions ...

      AgentCom.TestFactory.cleanup_agent(agent)
  """

  @doc """
  Create and register a test agent.

  Generates a token, spawns a dummy ws_pid, starts an AgentFSM, and
  registers in Presence.

  ## Options

    - `:agent_id` - Agent ID string (default: auto-generated unique ID)
    - `:capabilities` - List of capability strings (default: [])
    - `:name` - Display name (default: "test-<agent_id>")

  Returns `%{agent_id: id, token: token, ws_pid: pid, fsm_pid: pid}`.
  """
  def create_agent(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "test-agent-#{:erlang.unique_integer([:positive])}")
    capabilities = Keyword.get(opts, :capabilities, [])
    name = Keyword.get(opts, :name, "test-#{agent_id}")

    # Generate auth token
    {:ok, token} = AgentCom.Auth.generate(agent_id)

    # Spawn a dummy process to act as the WebSocket pid (AgentFSM monitors this)
    ws_pid = spawn(fn -> Process.sleep(:infinity) end)

    # Start AgentFSM via the DynamicSupervisor
    {:ok, fsm_pid} = AgentCom.AgentSupervisor.start_agent(
      agent_id: agent_id,
      ws_pid: ws_pid,
      name: name,
      capabilities: capabilities
    )

    # Register in AgentRegistry and Presence (mirroring socket.ex do_identify)
    Registry.register(AgentCom.AgentRegistry, agent_id, %{pid: ws_pid})
    AgentCom.Presence.register(agent_id, %{
      name: name,
      status: "idle",
      capabilities: capabilities
    })

    %{agent_id: agent_id, token: token, ws_pid: ws_pid, fsm_pid: fsm_pid}
  end

  @doc """
  Submit a task to the TaskQueue.

  ## Options

    - `:description` - Task description (default: "test task")
    - `:priority` - Priority string (default: "normal")
    - `:submitted_by` - Submitter ID (default: "test-submitter")
    - `:max_retries` - Max retries (default: 3)
    - `:needed_capabilities` - Required capabilities list (default: [])

  Returns `{:ok, task}`.
  """
  def submit_task(opts \\ []) do
    params = %{
      description: Keyword.get(opts, :description, "test task"),
      priority: Keyword.get(opts, :priority, "normal"),
      submitted_by: Keyword.get(opts, :submitted_by, "test-submitter"),
      max_retries: Keyword.get(opts, :max_retries, 3),
      needed_capabilities: Keyword.get(opts, :needed_capabilities, [])
    }

    AgentCom.TaskQueue.submit(params)
  end

  @doc """
  Clean up a single agent created by `create_agent/1`.

  Kills the dummy ws_pid, revokes the token, and waits briefly for
  the FSM to process the :DOWN message.
  """
  def cleanup_agent(%{agent_id: agent_id, ws_pid: ws_pid}) do
    # Kill the dummy ws_pid -- AgentFSM will receive :DOWN
    Process.exit(ws_pid, :kill)

    # Revoke the auth token
    AgentCom.Auth.revoke(agent_id)

    # Unregister from presence and agent registry
    AgentCom.Presence.unregister(agent_id)

    # Brief sleep to let FSM process the :DOWN message
    Process.sleep(50)
  end

  @doc """
  Clean up a list of agents created by `create_agent/1`.
  """
  def cleanup_all_agents(agents) when is_list(agents) do
    Enum.each(agents, &cleanup_agent/1)
  end
end
