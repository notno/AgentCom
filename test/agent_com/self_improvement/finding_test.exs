defmodule AgentCom.SelfImprovement.FindingTest do
  use ExUnit.Case, async: true

  alias AgentCom.SelfImprovement.Finding

  describe "struct creation" do
    test "creates finding with all required fields" do
      finding = %Finding{
        file_path: "lib/my_app/example.ex",
        line_number: 42,
        scan_type: "test_gap",
        description: "Module has no corresponding test file",
        severity: "medium",
        suggested_action: "Create test/my_app/example_test.exs",
        effort: "medium",
        scanner: :deterministic
      }

      assert finding.file_path == "lib/my_app/example.ex"
      assert finding.scan_type == "test_gap"
      assert finding.scanner == :deterministic
    end

    test "finding has correct field types" do
      finding = %Finding{
        file_path: "lib/example.ex",
        line_number: 10,
        scan_type: "doc_gap",
        description: "Missing @moduledoc",
        severity: "low",
        suggested_action: "Add @moduledoc",
        effort: "small",
        scanner: :credo
      }

      assert is_binary(finding.file_path)
      assert is_integer(finding.line_number)
      assert is_binary(finding.scan_type)
      assert is_binary(finding.description)
      assert is_binary(finding.severity)
      assert is_binary(finding.suggested_action)
      assert is_binary(finding.effort)
      assert is_atom(finding.scanner)
    end

    test "finding fields are accessible" do
      finding = %Finding{
        file_path: "mix.exs",
        line_number: 1,
        scan_type: "dead_dep",
        description: "Dependency :foo may be unused",
        severity: "low",
        suggested_action: "Verify if :foo is still needed",
        effort: "small",
        scanner: :deterministic
      }

      assert finding.line_number == 1
      assert finding.severity == "low"
      assert finding.effort == "small"
      assert finding.description =~ "foo"
      assert finding.suggested_action =~ "Verify"
    end

    test "enforces all required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Finding, %{file_path: "test.ex"})
      end
    end
  end
end
