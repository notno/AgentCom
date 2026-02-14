defmodule AgentCom.ClaudeClient.ResponseTest do
  @moduledoc """
  Unit tests for Response.parse/3 with all error and success paths.

  Covers: empty response, non-zero exit code, JSON wrapper parsing,
  XML extraction, markdown fence stripping, plain text fallback,
  and per-type parsing (:decompose, :verify, :identify_improvements).

  Stateless -- async: true.
  """

  use ExUnit.Case, async: true

  alias AgentCom.ClaudeClient.Response

  # ---------------------------------------------------------------------------
  # Error paths
  # ---------------------------------------------------------------------------

  describe "parse/3 error paths" do
    test "empty string returns {:error, :empty_response}" do
      assert {:error, :empty_response} = Response.parse("", 0, :decompose)
    end

    test "nil output returns {:error, :empty_response}" do
      assert {:error, :empty_response} = Response.parse(nil, 0, :decompose)
    end

    test "whitespace-only output returns {:error, :empty_response}" do
      assert {:error, :empty_response} = Response.parse("   \n  \t  ", 0, :decompose)
    end

    test "non-zero exit code returns {:error, {:exit_code, N}}" do
      assert {:error, {:exit_code, 1}} = Response.parse("some output", 1, :decompose)
      assert {:error, {:exit_code, 127}} = Response.parse("", 127, :verify)
    end

    test "valid JSON without expected XML tags returns {:error, {:parse_error, _}}" do
      json = Jason.encode!(%{"result" => "Hello, this is just text with no XML tags."})
      assert {:error, {:parse_error, _msg}} = Response.parse(json, 0, :decompose)
    end

    test "valid JSON with unexpected format returns {:error, {:unexpected_format, _}}" do
      json = Jason.encode!(%{"something_else" => "no result key"})
      assert {:error, {:unexpected_format, _}} = Response.parse(json, 0, :decompose)
    end

    test "unknown prompt type returns {:error, {:parse_error, _}}" do
      xml = "<unknown_root><data>hello</data></unknown_root>"
      json = Jason.encode!(%{"result" => xml})
      assert {:error, {:parse_error, _}} = Response.parse(json, 0, :unknown_type)
    end
  end

  # ---------------------------------------------------------------------------
  # :decompose success paths
  # ---------------------------------------------------------------------------

  describe "parse/3 :decompose success" do
    test "parses JSON-wrapped tasks XML into list of task maps" do
      tasks_xml = """
      <tasks>
        <task>
          <title>Create schema</title>
          <description>Add User schema with name and email.</description>
          <success-criteria>Schema compiles and has correct fields.</success-criteria>
          <depends-on></depends-on>
        </task>
        <task>
          <title>Add API endpoint</title>
          <description>Create GET /users endpoint.</description>
          <success-criteria>Returns 200 with JSON array.</success-criteria>
          <depends-on>1</depends-on>
        </task>
      </tasks>
      """

      json = Jason.encode!(%{"result" => tasks_xml})
      assert {:ok, tasks} = Response.parse(json, 0, :decompose)
      assert length(tasks) == 2

      [task1, task2] = tasks
      assert task1.title == "Create schema"
      assert task1.description =~ "User schema"
      assert task1.success_criteria =~ "compiles"
      assert task1.depends_on == []

      assert task2.title == "Add API endpoint"
      assert task2.depends_on == [1]
    end

    test "handles nested content JSON structure" do
      tasks_xml = """
      <tasks>
        <task>
          <title>Only task</title>
          <description>Test nested JSON.</description>
          <success-criteria>Works.</success-criteria>
          <depends-on></depends-on>
        </task>
      </tasks>
      """

      json =
        Jason.encode!(%{
          "result" => %{
            "content" => [%{"text" => tasks_xml, "type" => "text"}]
          }
        })

      assert {:ok, [task]} = Response.parse(json, 0, :decompose)
      assert task.title == "Only task"
    end

    test "strips markdown fences around XML" do
      tasks_xml = """
      ```xml
      <tasks>
        <task>
          <title>Fenced task</title>
          <description>Inside markdown fence.</description>
          <success-criteria>Extracted correctly.</success-criteria>
          <depends-on></depends-on>
        </task>
      </tasks>
      ```
      """

      json = Jason.encode!(%{"result" => tasks_xml})
      assert {:ok, [task]} = Response.parse(json, 0, :decompose)
      assert task.title == "Fenced task"
    end

    test "falls back to plain text parsing when JSON decode fails" do
      plain_xml = """
      <tasks>
        <task>
          <title>Plain text task</title>
          <description>No JSON wrapper.</description>
          <success-criteria>Still parsed.</success-criteria>
          <depends-on></depends-on>
        </task>
      </tasks>
      """

      assert {:ok, [task]} = Response.parse(plain_xml, 0, :decompose)
      assert task.title == "Plain text task"
    end

    test "parses multiple depends-on values" do
      tasks_xml = """
      <tasks>
        <task>
          <title>Dependent task</title>
          <description>Depends on 1 and 2.</description>
          <success-criteria>Has deps.</success-criteria>
          <depends-on>1, 2, 3</depends-on>
        </task>
      </tasks>
      """

      json = Jason.encode!(%{"result" => tasks_xml})
      assert {:ok, [task]} = Response.parse(json, 0, :decompose)
      assert task.depends_on == [1, 2, 3]
    end
  end

  # ---------------------------------------------------------------------------
  # :verify success paths
  # ---------------------------------------------------------------------------

  describe "parse/3 :verify success" do
    test "parses verification with pass verdict" do
      verify_xml = """
      <verification>
        <verdict>pass</verdict>
        <reasoning>All criteria met successfully.</reasoning>
        <gaps></gaps>
      </verification>
      """

      json = Jason.encode!(%{"result" => verify_xml})
      assert {:ok, result} = Response.parse(json, 0, :verify)
      assert result.verdict == :pass
      assert result.reasoning =~ "All criteria met"
      assert result.gaps == []
    end

    test "parses verification with fail verdict and gaps" do
      verify_xml = """
      <verification>
        <verdict>fail</verdict>
        <reasoning>Missing test coverage.</reasoning>
        <gaps>
          <gap>
            <description>No unit tests for user endpoint.</description>
            <severity>critical</severity>
          </gap>
          <gap>
            <description>Missing docs for public functions.</description>
            <severity>minor</severity>
          </gap>
        </gaps>
      </verification>
      """

      json = Jason.encode!(%{"result" => verify_xml})
      assert {:ok, result} = Response.parse(json, 0, :verify)
      assert result.verdict == :fail
      assert result.reasoning =~ "Missing test coverage"
      assert length(result.gaps) == 2

      [gap1, gap2] = result.gaps
      assert gap1.description =~ "unit tests"
      assert gap1.severity == "critical"
      assert gap2.severity == "minor"
    end

    test "parses verification from plain text (no JSON wrapper)" do
      verify_xml = """
      <verification>
        <verdict>pass</verdict>
        <reasoning>Everything looks good.</reasoning>
        <gaps></gaps>
      </verification>
      """

      assert {:ok, result} = Response.parse(verify_xml, 0, :verify)
      assert result.verdict == :pass
    end
  end

  # ---------------------------------------------------------------------------
  # :identify_improvements success paths
  # ---------------------------------------------------------------------------

  describe "parse/3 :identify_improvements success" do
    test "parses improvements XML into list of improvement maps" do
      imp_xml = """
      <improvements>
        <improvement>
          <title>Extract validation logic</title>
          <description>Validation is duplicated in two controllers.</description>
          <category>refactor</category>
          <effort>small</effort>
          <files>lib/controllers/user.ex, lib/controllers/admin.ex</files>
        </improvement>
        <improvement>
          <title>Add test coverage</title>
          <description>Missing tests for edge cases.</description>
          <category>test</category>
          <effort>medium</effort>
          <files>test/user_test.exs</files>
        </improvement>
      </improvements>
      """

      json = Jason.encode!(%{"result" => imp_xml})
      assert {:ok, improvements} = Response.parse(json, 0, :identify_improvements)
      assert length(improvements) == 2

      [imp1, imp2] = improvements
      assert imp1.title == "Extract validation logic"
      assert imp1.category == "refactor"
      assert imp1.effort == "small"
      assert length(imp1.files) == 2
      assert "lib/controllers/user.ex" in imp1.files

      assert imp2.title == "Add test coverage"
      assert imp2.category == "test"
      assert imp2.files == ["test/user_test.exs"]
    end

    test "handles empty improvements list" do
      imp_xml = "<improvements></improvements>"
      json = Jason.encode!(%{"result" => imp_xml})
      assert {:ok, []} = Response.parse(json, 0, :identify_improvements)
    end

    test "parses improvements with markdown fences" do
      imp_xml = """
      ```xml
      <improvements>
        <improvement>
          <title>Fenced improvement</title>
          <description>Inside fences.</description>
          <category>docs</category>
          <effort>small</effort>
          <files>README.md</files>
        </improvement>
      </improvements>
      ```
      """

      json = Jason.encode!(%{"result" => imp_xml})
      assert {:ok, [imp]} = Response.parse(json, 0, :identify_improvements)
      assert imp.title == "Fenced improvement"
    end
  end
end
