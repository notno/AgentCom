defmodule AgentCom.DetsBackupTest do
  use ExUnit.Case, async: false

  setup do
    tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()

    on_exit(fn ->
      AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "health_metrics returns data for all 9 tables" do
    metrics = AgentCom.DetsBackup.health_metrics()
    assert is_map(metrics)
    assert is_list(metrics.tables)
    assert length(metrics.tables) == 9

    Enum.each(metrics.tables, fn t ->
      assert Map.has_key?(t, :table)
      assert Map.has_key?(t, :record_count)
      assert Map.has_key?(t, :file_size_bytes)
      assert Map.has_key?(t, :fragmentation_ratio)
      assert Map.has_key?(t, :status)
      assert t.status == :ok
    end)
  end

  test "backup_all creates backup files and returns results" do
    {:ok, results} = AgentCom.DetsBackup.backup_all()
    assert is_list(results)
    assert length(results) == 9

    Enum.each(results, fn result ->
      assert {:ok, info} = result
      assert is_atom(info.table)
      assert is_binary(info.path)
      assert is_integer(info.size)
      assert File.exists?(info.path)
    end)
  end

  test "health_metrics returns Jason-serializable data after backup" do
    # Run a backup so last_backup_results is populated (not nil)
    {:ok, _results} = AgentCom.DetsBackup.backup_all()

    metrics = AgentCom.DetsBackup.health_metrics()

    # This is the exact operation that was crashing DashboardSocket (Jason.Encoder not implemented for Tuple)
    json = Jason.encode!(metrics)
    decoded = Jason.decode!(json)

    # last_backup_results should be a list (not nil, since we just ran a backup)
    assert is_list(decoded["last_backup_results"])
    assert length(decoded["last_backup_results"]) == 9

    # Each entry should have a "status" key that is either "ok" or "error"
    Enum.each(decoded["last_backup_results"], fn entry ->
      assert entry["status"] in ["ok", "error"],
             "Expected status 'ok' or 'error', got: #{inspect(entry["status"])}"
    end)
  end

  test "backup retention keeps only last 3 per table" do
    # Run backup 4 times with different timestamps
    {:ok, _} = AgentCom.DetsBackup.backup_all()
    Process.sleep(1100)
    {:ok, _} = AgentCom.DetsBackup.backup_all()
    Process.sleep(1100)
    {:ok, _} = AgentCom.DetsBackup.backup_all()
    Process.sleep(1100)
    {:ok, _} = AgentCom.DetsBackup.backup_all()

    backup_dir = Application.get_env(:agent_com, :backup_dir, "tmp/test/backups")
    {:ok, files} = File.ls(backup_dir)

    table_atoms = [:task_queue, :task_dead_letter, :agent_mailbox, :message_history,
                   :agent_channels, :channel_history, :agentcom_config, :thread_messages, :thread_replies]

    Enum.each(table_atoms, fn table ->
      prefix = "#{table}_"
      matching = Enum.filter(files, fn f -> String.starts_with?(f, prefix) end)
      assert length(matching) <= 3, "Table #{table} has #{length(matching)} backups, expected <= 3"
    end)
  end
end
