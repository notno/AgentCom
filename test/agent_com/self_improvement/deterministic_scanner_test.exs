defmodule AgentCom.SelfImprovement.DeterministicScannerTest do
  use ExUnit.Case, async: true

  alias AgentCom.SelfImprovement.DeterministicScanner
  alias AgentCom.SelfImprovement.Finding

  setup do
    test_dir =
      Path.join(
        System.tmp_dir!(),
        "test_det_scanner_#{:erlang.unique_integer([:positive])}"
      )
      |> Path.expand()

    # Create fixture repo structure
    lib_dir = Path.join([test_dir, "lib", "my_app"])
    test_path = Path.join([test_dir, "test", "my_app"])
    File.mkdir_p!(lib_dir)
    File.mkdir_p!(test_path)

    # lib/my_app.ex -- has defmodule and @moduledoc
    File.write!(Path.join([test_dir, "lib", "my_app.ex"]), """
    defmodule MyApp do
      @moduledoc "Top-level module"

      def hello, do: :world
    end
    """)

    # lib/my_app/no_doc.ex -- has defmodule, NO @moduledoc
    File.write!(Path.join(lib_dir, "no_doc.ex"), """
    defmodule MyApp.NoDoc do
      def hello, do: :world
    end
    """)

    # lib/my_app/with_test.ex -- has defmodule and @moduledoc
    File.write!(Path.join(lib_dir, "with_test.ex"), """
    defmodule MyApp.WithTest do
      @moduledoc "Has a test file"

      def run, do: :ok
    end
    """)

    # test/my_app/with_test_test.exs -- test file exists
    File.write!(Path.join(test_path, "with_test_test.exs"), """
    defmodule MyApp.WithTestTest do
      use ExUnit.Case
      test "works" do
        assert MyApp.WithTest.run() == :ok
      end
    end
    """)

    # mix.exs with deps including an unused one
    File.write!(Path.join(test_dir, "mix.exs"), """
    defmodule MyApp.MixProject do
      use Mix.Project

      def project do
        [app: :my_app, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [
          {:jason, "~> 1.4"},
          {:unused_dep, "~> 0.1"}
        ]
      end
    end
    """)

    # Add a reference to Jason in source so it's not flagged as dead
    File.write!(Path.join(lib_dir, "encoder.ex"), """
    defmodule MyApp.Encoder do
      @moduledoc "Uses Jason"

      def encode(data), do: Jason.encode(data)
    end
    """)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    {:ok, repo_path: test_dir}
  end

  describe "test gap detection" do
    test "detects test gap for module without test file", %{repo_path: repo_path} do
      findings = DeterministicScanner.scan(repo_path)
      test_gaps = Enum.filter(findings, &(&1.scan_type == "test_gap"))

      # my_app.ex, no_doc.ex, and encoder.ex have no test files
      gap_files = Enum.map(test_gaps, & &1.file_path)
      assert Enum.any?(gap_files, &String.contains?(&1, "no_doc.ex"))
      assert Enum.any?(gap_files, &String.contains?(&1, "my_app.ex"))
    end

    test "does not flag module with existing test file", %{repo_path: repo_path} do
      findings = DeterministicScanner.scan(repo_path)
      test_gaps = Enum.filter(findings, &(&1.scan_type == "test_gap"))
      gap_files = Enum.map(test_gaps, & &1.file_path)

      refute Enum.any?(gap_files, &String.contains?(&1, "with_test.ex"))
    end
  end

  describe "doc gap detection" do
    test "detects doc gap for module without @moduledoc", %{repo_path: repo_path} do
      findings = DeterministicScanner.scan(repo_path)
      doc_gaps = Enum.filter(findings, &(&1.scan_type == "doc_gap"))
      gap_files = Enum.map(doc_gaps, & &1.file_path)

      assert Enum.any?(gap_files, &String.contains?(&1, "no_doc.ex"))
    end

    test "does not flag module with @moduledoc", %{repo_path: repo_path} do
      findings = DeterministicScanner.scan(repo_path)
      doc_gaps = Enum.filter(findings, &(&1.scan_type == "doc_gap"))
      gap_files = Enum.map(doc_gaps, & &1.file_path)

      refute Enum.any?(gap_files, &String.contains?(&1, "my_app.ex"))
      refute Enum.any?(gap_files, &String.contains?(&1, "with_test.ex"))
      refute Enum.any?(gap_files, &String.contains?(&1, "encoder.ex"))
    end
  end

  describe "dead dependency detection" do
    test "detects dead dependency", %{repo_path: repo_path} do
      findings = DeterministicScanner.scan(repo_path)
      dead_deps = Enum.filter(findings, &(&1.scan_type == "dead_dep"))

      assert Enum.any?(dead_deps, fn f -> String.contains?(f.description, "unused_dep") end)
    end

    test "does not flag used dependency", %{repo_path: repo_path} do
      findings = DeterministicScanner.scan(repo_path)
      dead_deps = Enum.filter(findings, &(&1.scan_type == "dead_dep"))

      refute Enum.any?(dead_deps, fn f -> String.contains?(f.description, ":jason") end)
    end
  end

  describe "edge cases" do
    test "returns empty for non-existent repo" do
      findings = DeterministicScanner.scan("/tmp/nonexistent_repo_#{:erlang.unique_integer([:positive])}")
      assert findings == []
    end
  end

  describe "finding struct shape" do
    test "all findings are Finding structs with correct scanner", %{repo_path: repo_path} do
      findings = DeterministicScanner.scan(repo_path)

      assert length(findings) > 0

      for finding <- findings do
        assert %Finding{} = finding
        assert finding.scanner == :deterministic
        assert is_binary(finding.file_path)
        assert is_integer(finding.line_number)
        assert is_binary(finding.severity)
        assert is_binary(finding.effort)
      end
    end
  end
end
