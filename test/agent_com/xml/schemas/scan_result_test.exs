defmodule AgentCom.XML.Schemas.ScanResultTest do
  use ExUnit.Case, async: true

  alias AgentCom.XML.Schemas.ScanResult

  describe "new/1 with keyword list" do
    test "creates scan_result with required fields from keyword list" do
      {:ok, sr} = ScanResult.new(id: "sr-001", repo: "AgentCom", description: "Test gap found")
      assert sr.id == "sr-001"
      assert sr.repo == "AgentCom"
      assert sr.description == "Test gap found"
      assert sr.severity == "medium"
    end

    test "creates scan_result with all fields" do
      {:ok, sr} =
        ScanResult.new(
          id: "sr-002",
          repo: "AgentCom",
          scan_type: "test_gap",
          file_path: "lib/foo.ex",
          description: "No tests",
          severity: "high",
          suggested_action: "Add tests",
          scanned_at: "2026-01-01T00:00:00Z",
          metadata: "meta"
        )

      assert sr.scan_type == "test_gap"
      assert sr.severity == "high"
      assert sr.file_path == "lib/foo.ex"
    end
  end

  describe "new/1 with map" do
    test "creates scan_result from map" do
      {:ok, sr} = ScanResult.new(%{id: "sr-003", repo: "Test", description: "Map form"})
      assert sr.id == "sr-003"
    end
  end

  describe "new/1 validation errors" do
    test "returns error when id is missing" do
      assert {:error, "scan_result id is required"} =
               ScanResult.new(%{repo: "R", description: "D"})
    end

    test "returns error when repo is missing" do
      assert {:error, "scan_result repo is required"} =
               ScanResult.new(%{id: "sr-001", description: "D"})
    end

    test "returns error when description is missing" do
      assert {:error, "scan_result description is required"} =
               ScanResult.new(%{id: "sr-001", repo: "R"})
    end

    test "returns error for invalid scan_type" do
      assert {:error, msg} =
               ScanResult.new(%{id: "sr-001", repo: "R", description: "D", scan_type: "invalid"})

      assert msg =~ "scan_type"
    end

    test "returns error for invalid severity" do
      assert {:error, msg} =
               ScanResult.new(%{id: "sr-001", repo: "R", description: "D", severity: "invalid"})

      assert msg =~ "severity"
    end
  end

  describe "default values" do
    test "severity defaults to medium" do
      {:ok, sr} = ScanResult.new(%{id: "sr-def", repo: "R", description: "D"})
      assert sr.severity == "medium"
    end
  end

  describe "from_simple_form/1" do
    test "parses scan_result from SimpleForm tuple" do
      simple_form =
        {"scan-result", [{"id", "sr-sf"}, {"repo", "Test"}, {"severity", "high"}], [
          {"description", [], ["SimpleForm scan result"]}
        ]}

      {:ok, sr} = ScanResult.from_simple_form(simple_form)
      assert sr.id == "sr-sf"
      assert sr.repo == "Test"
      assert sr.description == "SimpleForm scan result"
      assert sr.severity == "high"
    end

    test "returns error for wrong root element" do
      {:error, msg} = ScanResult.from_simple_form({"goal", [], []})
      assert msg =~ "expected <scan-result>"
    end
  end
end
