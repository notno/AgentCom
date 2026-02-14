defmodule AgentCom.SelfImprovement.ImprovementHistoryTest do
  use ExUnit.Case, async: false

  alias AgentCom.SelfImprovement.ImprovementHistory
  alias AgentCom.SelfImprovement.Finding

  setup do
    test_dir =
      Path.join(
        System.tmp_dir!(),
        "test_improvement_history_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_dir)
    Application.put_env(:agent_com, :improvement_history_data_dir, test_dir)

    ImprovementHistory.init()

    on_exit(fn ->
      ImprovementHistory.close()
      File.rm_rf!(test_dir)
      Application.delete_env(:agent_com, :improvement_history_data_dir)
    end)

    :ok
  end

  describe "init/0" do
    test "init creates DETS table" do
      # init already called in setup, verify it returns :ok on re-init
      assert :ok = ImprovementHistory.init()
    end
  end

  describe "record_improvement/4" do
    test "record_improvement stores entry" do
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Add tests")

      records = ImprovementHistory.all_records()
      assert length(records) == 1

      [{key, entries}] = records
      assert key == {"repo", "lib/foo.ex"}
      assert length(entries) == 1
      assert hd(entries).description == "Add tests"
      assert hd(entries).scan_type == :deterministic
    end

    test "record_improvement keeps last 10 entries" do
      for i <- 1..12 do
        ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Change #{i}")
      end

      records = ImprovementHistory.all_records()
      [{_key, entries}] = records
      assert length(entries) == 10

      # Most recent should be first
      assert hd(entries).description == "Change 12"
    end
  end

  describe "cooled_down?/3" do
    test "cooled_down? returns true within cooldown window" do
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Fix")

      # Just recorded, so should be within cooldown
      assert ImprovementHistory.cooled_down?("repo", "lib/foo.ex") == true
    end

    test "cooled_down? returns false after cooldown expires" do
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Fix")

      # Use a very short cooldown (1ms) and wait
      Process.sleep(5)
      assert ImprovementHistory.cooled_down?("repo", "lib/foo.ex", 1) == false
    end

    test "cooled_down? returns false for unknown file" do
      assert ImprovementHistory.cooled_down?("repo", "lib/unknown.ex") == false
    end
  end

  describe "oscillating?/2" do
    test "oscillating? returns false with fewer than 3 records" do
      assert ImprovementHistory.oscillating?("repo", "lib/foo.ex") == false

      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Add function")
      assert ImprovementHistory.oscillating?("repo", "lib/foo.ex") == false

      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Remove function")
      assert ImprovementHistory.oscillating?("repo", "lib/foo.ex") == false
    end

    test "oscillating? detects add/remove inverse pattern" do
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Add function foo")
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Remove function foo")
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Add function foo")

      assert ImprovementHistory.oscillating?("repo", "lib/foo.ex") == true
    end

    test "oscillating? detects extract/inline inverse pattern" do
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Extract helper")
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Inline helper")
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Extract helper")

      assert ImprovementHistory.oscillating?("repo", "lib/foo.ex") == true
    end

    test "oscillating? returns false for non-inverse descriptions" do
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Fix typo")
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Add test")
      ImprovementHistory.record_improvement("repo", "lib/foo.ex", :deterministic, "Update docs")

      assert ImprovementHistory.oscillating?("repo", "lib/foo.ex") == false
    end
  end

  describe "filter_cooled_down/2" do
    test "filter_cooled_down removes cooled-down findings" do
      # Record improvement for one file
      ImprovementHistory.record_improvement("repo", "lib/cool.ex", :deterministic, "Fixed")

      findings = [
        %Finding{
          file_path: "lib/cool.ex",
          line_number: 1,
          scan_type: "test_gap",
          description: "No test",
          severity: "medium",
          suggested_action: "Add test",
          effort: "medium",
          scanner: :deterministic
        },
        %Finding{
          file_path: "lib/fresh.ex",
          line_number: 1,
          scan_type: "test_gap",
          description: "No test",
          severity: "medium",
          suggested_action: "Add test",
          effort: "medium",
          scanner: :deterministic
        }
      ]

      filtered = ImprovementHistory.filter_cooled_down(findings, "repo")

      assert length(filtered) == 1
      assert hd(filtered).file_path == "lib/fresh.ex"
    end
  end

  describe "filter_oscillating/2" do
    test "filter_oscillating removes oscillating findings" do
      # Create oscillation pattern for one file
      ImprovementHistory.record_improvement("repo", "lib/osc.ex", :deterministic, "Add function")
      ImprovementHistory.record_improvement("repo", "lib/osc.ex", :deterministic, "Remove function")
      ImprovementHistory.record_improvement("repo", "lib/osc.ex", :deterministic, "Add function")

      findings = [
        %Finding{
          file_path: "lib/osc.ex",
          line_number: 1,
          scan_type: "test_gap",
          description: "No test",
          severity: "medium",
          suggested_action: "Add test",
          effort: "medium",
          scanner: :deterministic
        },
        %Finding{
          file_path: "lib/stable.ex",
          line_number: 1,
          scan_type: "test_gap",
          description: "No test",
          severity: "medium",
          suggested_action: "Add test",
          effort: "medium",
          scanner: :deterministic
        }
      ]

      filtered = ImprovementHistory.filter_oscillating(findings, "repo")

      assert length(filtered) == 1
      assert hd(filtered).file_path == "lib/stable.ex"
    end
  end

  describe "clear/0" do
    test "clear removes all records" do
      ImprovementHistory.record_improvement("repo", "lib/a.ex", :deterministic, "Fix a")
      ImprovementHistory.record_improvement("repo", "lib/b.ex", :deterministic, "Fix b")

      assert length(ImprovementHistory.all_records()) == 2

      ImprovementHistory.clear()

      assert ImprovementHistory.all_records() == []
    end
  end
end
