defmodule AgentCom.SelfImprovement.DialyzerScannerTest do
  use ExUnit.Case, async: true

  alias AgentCom.SelfImprovement.DialyzerScanner

  describe "scan/1" do
    test "returns empty for repo without dialyxir" do
      test_dir =
        Path.join(
          System.tmp_dir!(),
          "test_dialyzer_scanner_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(test_dir)

      # mix.exs without :dialyxir dependency
      File.write!(Path.join(test_dir, "mix.exs"), """
      defmodule MyApp.MixProject do
        use Mix.Project

        def project do
          [app: :my_app, version: "0.1.0", deps: deps()]
        end

        defp deps do
          [{:jason, "~> 1.4"}]
        end
      end
      """)

      findings = DialyzerScanner.scan(test_dir)
      assert findings == []

      File.rm_rf!(test_dir)
    end

    test "returns empty for non-existent repo" do
      findings = DialyzerScanner.scan("/tmp/nonexistent_dialyzer_repo_#{:erlang.unique_integer([:positive])}")
      assert findings == []
    end

    test "returns empty for repo without mix.exs" do
      test_dir =
        Path.join(
          System.tmp_dir!(),
          "test_dialyzer_nomix_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(test_dir)

      findings = DialyzerScanner.scan(test_dir)
      assert findings == []

      File.rm_rf!(test_dir)
    end
  end
end
