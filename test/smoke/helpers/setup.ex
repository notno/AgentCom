defmodule Smoke.Setup do
  @moduledoc """
  Test setup helpers for smoke tests.

  Provides DETS cleanup, auth token generation, and agent cleanup
  to ensure a clean state between test runs.
  """

  require Logger

  @doc """
  Reset the task queue to a clean state.

  Stops the TaskQueue GenServer, deletes DETS files, and restarts it.
  Also restarts the Scheduler since it depends on TaskQueue.
  """
  def reset_task_queue do
    # Use Supervisor to terminate and restart children properly.
    # GenServer.stop causes the Supervisor to auto-restart (restart: :permanent),
    # creating a race with manual start_link calls. Supervisor.terminate_child +
    # restart_child avoids this.

    # Stop Scheduler first (depends on TaskQueue)
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.Scheduler)

    # Stop TaskQueue
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.TaskQueue)

    # Delete DETS files while processes are stopped
    File.rm("priv/task_queue.dets")
    File.rm("priv/task_dead_letter.dets")

    # Restart TaskQueue (will create fresh DETS)
    Supervisor.restart_child(AgentCom.Supervisor, AgentCom.TaskQueue)

    # Restart Scheduler
    Supervisor.restart_child(AgentCom.Supervisor, AgentCom.Scheduler)

    :ok
  end

  @doc """
  Generate fresh auth tokens for a list of agent IDs.

  Returns a map of `%{agent_id => token}`.
  """
  def create_test_tokens(agent_ids) when is_list(agent_ids) do
    for id <- agent_ids, into: %{} do
      {:ok, token} = AgentCom.Auth.generate(id)
      {id, token}
    end
  end

  @doc """
  Clean up test agents by revoking tokens and stopping any lingering FSM processes.
  """
  def cleanup_agents(agent_ids) when is_list(agent_ids) do
    for id <- agent_ids do
      # Revoke tokens
      AgentCom.Auth.revoke(id)

      # Stop any lingering AgentFSM processes
      case Registry.lookup(AgentCom.AgentFSMRegistry, id) do
        [{pid, _}] ->
          AgentCom.AgentSupervisor.stop_agent(pid)
        [] ->
          :ok
      end

      # Unregister from presence and agent registry
      Registry.unregister(AgentCom.AgentRegistry, id)
      AgentCom.Presence.unregister(id)
    end

    :ok
  end

  @doc """
  Reset all state for a clean test run.
  Convenience function that calls reset_task_queue/0.
  """
  def reset_all do
    reset_task_queue()
  end
end
