defmodule AgentCom.Verification.StoreTest do
  use ExUnit.Case, async: false

  alias AgentCom.Verification.Store
  alias AgentCom.Verification.Report

  @moduletag :verification_store

  setup do
    # Unique temp path per test for DETS isolation
    tmp_dir = Path.join(System.tmp_dir!(), "verification_store_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    dets_path = Path.join(tmp_dir, "verification_reports_test.dets")

    # Use a unique registered name per test to avoid conflicts with default __MODULE__ name
    test_name = :"store_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Store.start_link(dets_path: dets_path, max_reports: 5, name: test_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
      File.rm_rf!(tmp_dir)
    end)

    %{pid: pid, dets_path: dets_path, tmp_dir: tmp_dir}
  end

  describe "save/2 and get/1" do
    test "persists report and retrieves by {task_id, run_number}", %{pid: pid} do
      report = Report.build("task-001", 1, [
        %{type: "file_exists", target: "a.ex", description: nil, status: :pass, output: "", duration_ms: 1}
      ])

      assert :ok = Store.save(pid, report)
      assert {:ok, saved} = Store.get(pid, {"task-001", 1})
      assert saved.task_id == "task-001"
      assert saved.run_number == 1
      assert saved.status == :pass
    end

    test "returns {:error, :not_found} for missing key", %{pid: pid} do
      assert {:error, :not_found} = Store.get(pid, {"nonexistent", 1})
    end
  end

  describe "get_latest/1" do
    test "returns report with highest run_number for a task", %{pid: pid} do
      r1 = Report.build("task-002", 1, [
        %{type: "file_exists", target: "a.ex", description: nil, status: :fail, output: "not found", duration_ms: 1}
      ])
      r2 = Report.build("task-002", 2, [
        %{type: "file_exists", target: "a.ex", description: nil, status: :pass, output: "", duration_ms: 1}
      ])
      r3 = Report.build("task-002", 3, [
        %{type: "file_exists", target: "a.ex", description: nil, status: :pass, output: "", duration_ms: 1}
      ])

      :ok = Store.save(pid, r1)
      :ok = Store.save(pid, r2)
      :ok = Store.save(pid, r3)

      assert {:ok, latest} = Store.get_latest(pid, "task-002")
      assert latest.run_number == 3
    end

    test "returns {:error, :not_found} when no reports exist for task", %{pid: pid} do
      assert {:error, :not_found} = Store.get_latest(pid, "nonexistent")
    end
  end

  describe "list_for_task/1" do
    test "returns all reports sorted by run_number ascending", %{pid: pid} do
      r1 = Report.build("task-003", 1, [
        %{type: "file_exists", target: "a.ex", description: nil, status: :fail, output: "", duration_ms: 1}
      ])
      r2 = Report.build("task-003", 2, [
        %{type: "file_exists", target: "a.ex", description: nil, status: :pass, output: "", duration_ms: 1}
      ])

      :ok = Store.save(pid, r1)
      :ok = Store.save(pid, r2)

      reports = Store.list_for_task(pid, "task-003")
      assert length(reports) == 2
      assert [first, second] = reports
      assert first.run_number == 1
      assert second.run_number == 2
    end

    test "returns empty list when no reports exist for task", %{pid: pid} do
      assert [] = Store.list_for_task(pid, "nonexistent")
    end
  end

  describe "retention enforcement" do
    test "prunes oldest reports when exceeding max_reports", %{pid: pid} do
      # max_reports is 5 in setup
      for i <- 1..7 do
        report = Report.build("task-ret-#{i}", 1, [
          %{type: "file_exists", target: "a.ex", description: nil, status: :pass, output: "", duration_ms: 1}
        ])
        :ok = Store.save(pid, report)
      end

      # After saving 7, only 5 should remain (oldest 2 pruned)
      count = Store.count(pid)
      assert count <= 5
    end
  end

  describe "persistence across restart" do
    test "reports survive GenServer stop/restart", %{pid: pid, dets_path: dets_path} do
      report = Report.build("task-persist", 1, [
        %{type: "file_exists", target: "a.ex", description: nil, status: :pass, output: "", duration_ms: 1}
      ])

      :ok = Store.save(pid, report)

      # Stop the GenServer
      GenServer.stop(pid, :normal)

      # Restart with same DETS path (unique name to avoid conflicts)
      restart_name = :"store_restart_#{:erlang.unique_integer([:positive])}"
      {:ok, new_pid} = Store.start_link(dets_path: dets_path, max_reports: 5, name: restart_name)

      # Data should still be there
      assert {:ok, saved} = Store.get(new_pid, {"task-persist", 1})
      assert saved.task_id == "task-persist"
      assert saved.status == :pass

      GenServer.stop(new_pid, :normal)
    end
  end
end
