defmodule AgentCom.SelfImprovement.CredoScannerTest do
  use ExUnit.Case, async: true

  alias AgentCom.SelfImprovement.CredoScanner

  describe "scan/1" do
    test "returns empty for repo without credo" do
      test_dir =
        Path.join(
          System.tmp_dir!(),
          "test_credo_scanner_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(test_dir)

      # mix.exs without :credo dependency
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

      findings = CredoScanner.scan(test_dir)
      assert findings == []

      File.rm_rf!(test_dir)
    end

    test "returns empty for non-existent repo" do
      findings = CredoScanner.scan("/tmp/nonexistent_credo_repo_#{:erlang.unique_integer([:positive])}")
      assert findings == []
    end

    test "returns empty for repo without mix.exs" do
      test_dir =
        Path.join(
          System.tmp_dir!(),
          "test_credo_nomix_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(test_dir)

      findings = CredoScanner.scan(test_dir)
      assert findings == []

      File.rm_rf!(test_dir)
    end
  end
end
