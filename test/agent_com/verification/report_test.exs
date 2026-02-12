defmodule AgentCom.Verification.ReportTest do
  use ExUnit.Case, async: true

  alias AgentCom.Verification.Report

  describe "build/3" do
    test "all checks pass -> status :pass" do
      checks = [
        %{type: "file_exists", target: "lib/foo.ex", description: "File exists", status: :pass, output: "", duration_ms: 2},
        %{type: "git_clean", target: ".", description: "Clean repo", status: :pass, output: "", duration_ms: 50}
      ]

      report = Report.build("task-001", 1, checks)

      assert report.task_id == "task-001"
      assert report.run_number == 1
      assert report.status == :pass
      assert length(report.checks) == 2
      assert is_integer(report.started_at)
      assert report.timeout_ms == 120_000
    end

    test "one check fails -> status :fail" do
      checks = [
        %{type: "file_exists", target: "lib/foo.ex", description: "File exists", status: :pass, output: "", duration_ms: 2},
        %{type: "test_passes", target: "mix test", description: "Tests pass", status: :fail, output: "1 failure", duration_ms: 3000}
      ]

      report = Report.build("task-002", 1, checks)

      assert report.status == :fail
    end

    test "one check errors -> status :error (error > fail priority)" do
      checks = [
        %{type: "file_exists", target: "lib/foo.ex", description: nil, status: :fail, output: "not found", duration_ms: 1},
        %{type: "command_succeeds", target: "echo hi", description: nil, status: :error, output: "exec error", duration_ms: 10}
      ]

      report = Report.build("task-003", 2, checks)

      assert report.status == :error
    end

    test "error takes priority over fail and timeout" do
      checks = [
        %{type: "file_exists", target: "a", description: nil, status: :fail, output: "", duration_ms: 1},
        %{type: "git_clean", target: ".", description: nil, status: :timeout, output: "", duration_ms: 5000},
        %{type: "command_succeeds", target: "x", description: nil, status: :error, output: "boom", duration_ms: 1}
      ]

      report = Report.build("task-004", 1, checks)

      assert report.status == :error
    end

    test "timeout takes priority over fail but not error" do
      checks = [
        %{type: "file_exists", target: "a", description: nil, status: :fail, output: "", duration_ms: 1},
        %{type: "git_clean", target: ".", description: nil, status: :timeout, output: "", duration_ms: 5000}
      ]

      report = Report.build("task-005", 1, checks)

      assert report.status == :timeout
    end

    test "summary counts match check statuses" do
      checks = [
        %{type: "file_exists", target: "a", description: nil, status: :pass, output: "", duration_ms: 1},
        %{type: "file_exists", target: "b", description: nil, status: :pass, output: "", duration_ms: 1},
        %{type: "test_passes", target: "mix test", description: nil, status: :fail, output: "fail", duration_ms: 100},
        %{type: "command_succeeds", target: "x", description: nil, status: :error, output: "err", duration_ms: 5},
        %{type: "git_clean", target: ".", description: nil, status: :timeout, output: "", duration_ms: 5000}
      ]

      report = Report.build("task-006", 1, checks)

      assert report.summary == %{total: 5, passed: 2, failed: 1, errors: 1, timed_out: 1}
    end

    test "accepts custom timeout_ms via opts" do
      checks = [
        %{type: "file_exists", target: "a", description: nil, status: :pass, output: "", duration_ms: 1}
      ]

      report = Report.build("task-007", 1, checks, timeout_ms: 60_000)

      assert report.timeout_ms == 60_000
    end

    test "includes duration_ms when provided via opts" do
      checks = [
        %{type: "file_exists", target: "a", description: nil, status: :pass, output: "", duration_ms: 1}
      ]

      report = Report.build("task-008", 1, checks, duration_ms: 4523)

      assert report.duration_ms == 4523
    end
  end

  describe "build_skipped/1" do
    test "returns report with status :skip and empty checks" do
      report = Report.build_skipped("task-skip-001")

      assert report.task_id == "task-skip-001"
      assert report.status == :skip
      assert report.checks == []
      assert report.run_number == 0
      assert is_integer(report.started_at)
      assert report.summary == %{total: 0, passed: 0, failed: 0, errors: 0, timed_out: 0}
    end
  end

  describe "build_auto_pass/1" do
    test "returns report with status :auto_pass and empty checks" do
      report = Report.build_auto_pass("task-auto-001")

      assert report.task_id == "task-auto-001"
      assert report.status == :auto_pass
      assert report.checks == []
      assert report.run_number == 0
      assert is_integer(report.started_at)
      assert report.summary == %{total: 0, passed: 0, failed: 0, errors: 0, timed_out: 0}
    end
  end

  describe "build_timeout/1" do
    test "returns report with status :timeout and empty checks" do
      report = Report.build_timeout("task-timeout-001")

      assert report.task_id == "task-timeout-001"
      assert report.status == :timeout
      assert report.checks == []
      assert report.run_number == 0
      assert is_integer(report.started_at)
      assert report.summary == %{total: 0, passed: 0, failed: 0, errors: 0, timed_out: 0}
    end
  end
end
