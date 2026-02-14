defmodule AgentCom.SelfImprovementTest do
  use ExUnit.Case, async: false

  alias AgentCom.SelfImprovement
  alias AgentCom.SelfImprovement.{Finding, ImprovementHistory}

  setup do
    # Setup ImprovementHistory with temp dir
    history_dir =
      Path.join(
        System.tmp_dir!(),
        "test_self_improvement_#{:erlang.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(history_dir)
    Application.put_env(:agent_com, :improvement_history_data_dir, history_dir)
    ImprovementHistory.init()

    # Create fixture repo
    repo_dir =
      Path.join(
        System.tmp_dir!(),
        "test_repo_#{:erlang.unique_integer([:positive])}"
      )
      |> Path.expand()

    lib_dir = Path.join([repo_dir, "lib", "my_app"])
    test_dir = Path.join([repo_dir, "test", "my_app"])
    File.mkdir_p!(lib_dir)
    File.mkdir_p!(test_dir)

    # Create a module without test file (will be detected as test_gap)
    File.write!(Path.join(lib_dir, "untested.ex"), """
    defmodule MyApp.Untested do
      @moduledoc "An untested module"
      def hello, do: :world
    end
    """)

    # Create a module without @moduledoc (will be detected as doc_gap)
    File.write!(Path.join(lib_dir, "undocumented.ex"), """
    defmodule MyApp.Undocumented do
      def hello, do: :world
    end
    """)

    # Create a module WITH test file (should NOT be flagged)
    File.write!(Path.join(lib_dir, "tested.ex"), """
    defmodule MyApp.Tested do
      @moduledoc "Has a test"
      def run, do: :ok
    end
    """)

    File.write!(Path.join(test_dir, "tested_test.exs"), """
    defmodule MyApp.TestedTest do
      use ExUnit.Case
      test "works", do: assert true
    end
    """)

    # Create mix.exs with an unused dep
    File.write!(Path.join(repo_dir, "mix.exs"), """
    defmodule MyApp.MixProject do
      use Mix.Project
      def project, do: [app: :my_app, version: "0.1.0", deps: deps()]
      defp deps, do: [{:unused_thing, "~> 0.1"}]
    end
    """)

    on_exit(fn ->
      ImprovementHistory.close()
      File.rm_rf!(history_dir)
      File.rm_rf!(repo_dir)
      Application.delete_env(:agent_com, :improvement_history_data_dir)
    end)

    {:ok, repo_dir: repo_dir, history_dir: history_dir}
  end

  describe "scan_repo/2" do
    test "scan_repo returns findings from deterministic scanner", %{repo_dir: repo_dir} do
      {:ok, findings} = SelfImprovement.scan_repo(repo_dir, repo_name: "test_repo")

      assert length(findings) > 0

      scan_types = Enum.map(findings, & &1.scan_type) |> Enum.uniq()
      # Should find at least test_gap and doc_gap from our fixtures
      assert "test_gap" in scan_types or "doc_gap" in scan_types or "dead_dep" in scan_types
    end

    test "scan_repo respects max_findings budget", %{repo_dir: repo_dir} do
      {:ok, findings} = SelfImprovement.scan_repo(repo_dir, max_findings: 1, repo_name: "test_repo")

      assert length(findings) <= 1
    end

    test "scan_repo filters cooled-down files", %{repo_dir: repo_dir} do
      # First scan to get findings
      {:ok, initial_findings} = SelfImprovement.scan_repo(repo_dir, repo_name: "test_repo")

      # Record improvement for each found file (cool them down)
      for finding <- initial_findings do
        ImprovementHistory.record_improvement(
          "test_repo",
          finding.file_path,
          finding.scan_type,
          finding.description
        )
      end

      # Second scan should have fewer findings (cooled-down files filtered out)
      {:ok, filtered_findings} = SelfImprovement.scan_repo(repo_dir, repo_name: "test_repo")

      # All previously found files should be cooled down now
      initial_files = Enum.map(initial_findings, & &1.file_path) |> MapSet.new()
      filtered_files = Enum.map(filtered_findings, & &1.file_path) |> MapSet.new()

      # No overlap between initial files and filtered results
      overlap = MapSet.intersection(initial_files, filtered_files)
      assert MapSet.size(overlap) == 0
    end
  end

  describe "submit_findings_as_goals/2" do
    test "submit_findings_as_goals creates goals with correct attributes" do
      # Setup GoalBacklog with test DETS
      tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()

      findings = [
        %Finding{
          file_path: "lib/example.ex",
          line_number: 1,
          scan_type: "test_gap",
          description: "Module has no test file",
          severity: "medium",
          suggested_action: "Create test file",
          effort: "medium",
          scanner: :deterministic
        }
      ]

      results = SelfImprovement.submit_findings_as_goals(findings, "test_repo")

      assert length(results) == 1
      assert match?([{:ok, _}], results)

      [{:ok, goal}] = results
      # GoalBacklog normalizes "low" to integer 3
      assert goal.priority == 3
      assert goal.source == "self_improvement"

      AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir)
    end
  end
end
