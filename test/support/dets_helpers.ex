defmodule AgentCom.TestHelpers.DetsHelpers do
  @moduledoc """
  DETS isolation helpers for tests.

  Provides per-test temporary directory setup, Application.put_env overrides
  for all DETS-backed GenServers, and GenServer restart/cleanup utilities.

  ## Usage

      setup do
        tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()
        on_exit(fn -> AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir) end)
        {:ok, tmp_dir: tmp_dir}
      end
  """

  @doc """
  Create a fresh temp directory and override all DETS path configs to point there.

  Returns the tmp_dir path for later cleanup.
  """
  def setup_test_dets do
    tmp_dir = Path.join(System.tmp_dir!(), "agentcom_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Override all 7 DETS path configs to use subdirectories of the temp dir
    Application.put_env(:agent_com, :task_queue_path, Path.join(tmp_dir, "task_queue"))
    Application.put_env(:agent_com, :tokens_path, Path.join(tmp_dir, "tokens.json"))
    Application.put_env(:agent_com, :mailbox_path, Path.join(tmp_dir, "mailbox.dets"))
    Application.put_env(:agent_com, :message_history_path, Path.join(tmp_dir, "message_history.dets"))
    Application.put_env(:agent_com, :channels_path, Path.join(tmp_dir, "channels"))
    Application.put_env(:agent_com, :config_data_dir, Path.join(tmp_dir, "config"))
    Application.put_env(:agent_com, :threads_data_dir, Path.join(tmp_dir, "threads"))
    Application.put_env(:agent_com, :llm_registry_data_dir, Path.join(tmp_dir, "llm_registry"))
    Application.put_env(:agent_com, :repo_registry_data_dir, Path.join(tmp_dir, "repo_registry"))
    Application.put_env(:agent_com, :backup_dir, Path.join(tmp_dir, "backups"))

    # Ensure subdirectories exist
    File.mkdir_p!(Path.join(tmp_dir, "task_queue"))
    File.mkdir_p!(Path.join(tmp_dir, "channels"))
    File.mkdir_p!(Path.join(tmp_dir, "config"))
    File.mkdir_p!(Path.join(tmp_dir, "threads"))
    File.mkdir_p!(Path.join(tmp_dir, "llm_registry"))
    File.mkdir_p!(Path.join(tmp_dir, "repo_registry"))
    File.mkdir_p!(Path.join(tmp_dir, "backups"))

    tmp_dir
  end

  @doc """
  Stop and restart all DETS-backed GenServers so they pick up the new paths.

  Stop order: downstream first (Scheduler -> TaskQueue -> MessageHistory ->
  Mailbox -> Channels -> Threads -> Config -> Auth).
  Restart order: reverse (upstream first).
  """
  def restart_dets_servers do
    # Stop order: downstream consumers first, then data stores
    stop_order = [
      AgentCom.Scheduler,
      AgentCom.DetsBackup,
      AgentCom.TaskQueue,
      AgentCom.MessageHistory,
      AgentCom.Mailbox,
      AgentCom.Channels,
      AgentCom.Threads,
      AgentCom.Config,
      AgentCom.Auth,
      AgentCom.LlmRegistry,
      AgentCom.RepoRegistry
    ]

    for child <- stop_order do
      try do
        Supervisor.terminate_child(AgentCom.Supervisor, child)
      catch
        :exit, _ -> :ok
      end
    end

    # Force-close any DETS tables that might still be registered.
    # This handles the case where a previous test's on_exit deleted
    # the backing files while tables were still open. Erlang DETS
    # ignores the file: arg in open_file if the name is already
    # registered, so stale entries must be cleared before restart.
    dets_tables = [
      :task_queue, :task_dead_letter, :agent_mailbox, :message_history,
      :agent_channels, :channel_history, :agentcom_config, :thread_messages,
      :thread_replies, :repo_registry
    ]

    for table <- dets_tables do
      :dets.close(table)
    end

    # Restart in reverse order: data stores first, then consumers
    for child <- Enum.reverse(stop_order) do
      try do
        Supervisor.restart_child(AgentCom.Supervisor, child)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Remove the temporary directory and all its contents.
  """
  def cleanup_dets(tmp_dir) do
    File.rm_rf!(tmp_dir)
  end

  @doc """
  Convenience: setup_test_dets + restart_dets_servers. Returns tmp_dir.

  Use in ExUnit `setup` blocks.
  """
  def full_test_setup do
    tmp_dir = setup_test_dets()
    restart_dets_servers()
    tmp_dir
  end

  @doc """
  Convenience: cleanup_dets. For `on_exit` blocks.
  """
  def full_test_teardown(tmp_dir) do
    cleanup_dets(tmp_dir)
  end
end
