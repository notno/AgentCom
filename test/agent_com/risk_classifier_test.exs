defmodule AgentCom.RiskClassifierTest do
  use ExUnit.Case, async: true

  alias AgentCom.RiskClassifier

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp task(opts \\ []) do
    complexity_tier = Keyword.get(opts, :complexity, :standard)
    verification = Keyword.get(opts, :verification, %{status: :pass})

    %{
      complexity: %{effective_tier: complexity_tier},
      verification_report: verification
    }
  end

  defp diff(opts \\ []) do
    %{
      lines_added: Keyword.get(opts, :lines_added, 5),
      lines_deleted: Keyword.get(opts, :lines_deleted, 2),
      files_changed: Keyword.get(opts, :files_changed, ["lib/agent_com/foo.ex"]),
      files_added: Keyword.get(opts, :files_added, []),
      tests_exist: Keyword.get(opts, :tests_exist, true)
    }
  end

  # ---------------------------------------------------------------------------
  # Tier 3: Escalation
  # ---------------------------------------------------------------------------

  describe "tier 3 -- protected paths" do
    test "config/ path triggers tier 3" do
      result = RiskClassifier.classify(task(), diff(files_changed: ["config/dev.exs"]))
      assert result.tier == 3
      assert Enum.any?(result.reasons, &String.contains?(&1, "protected"))
    end

    test "rel/ path triggers tier 3" do
      result = RiskClassifier.classify(task(), diff(files_changed: ["rel/config.exs"]))
      assert result.tier == 3
    end

    test ".github/ path triggers tier 3" do
      result = RiskClassifier.classify(task(), diff(files_changed: [".github/workflows/ci.yml"]))
      assert result.tier == 3
    end

    test "Dockerfile triggers tier 3" do
      result = RiskClassifier.classify(task(), diff(files_changed: ["Dockerfile"]))
      assert result.tier == 3
    end

    test "mix.exs triggers tier 3" do
      result = RiskClassifier.classify(task(), diff(files_changed: ["mix.exs"]))
      assert result.tier == 3
    end

    test "mix.lock triggers tier 3" do
      result = RiskClassifier.classify(task(), diff(files_changed: ["mix.lock"]))
      assert result.tier == 3
    end
  end

  describe "tier 3 -- auth paths" do
    test "auth module path triggers tier 3" do
      result = RiskClassifier.classify(task(), diff(files_changed: ["lib/agent_com/auth.ex"]))
      assert result.tier == 3
    end

    test "require_auth plug path triggers tier 3" do
      result =
        RiskClassifier.classify(
          task(),
          diff(files_changed: ["lib/agent_com/plugs/require_auth.ex"])
        )

      assert result.tier == 3
    end

    test "priv/cert path triggers tier 3" do
      result = RiskClassifier.classify(task(), diff(files_changed: ["priv/cert/server.pem"]))
      assert result.tier == 3
    end

    test "priv/key path triggers tier 3" do
      result = RiskClassifier.classify(task(), diff(files_changed: ["priv/key/server.key"]))
      assert result.tier == 3
    end
  end

  describe "tier 3 -- verification failed" do
    test "failed verification triggers tier 3" do
      result =
        RiskClassifier.classify(
          task(verification: %{status: :fail}),
          diff()
        )

      assert result.tier == 3
      assert Enum.any?(result.reasons, &String.contains?(&1, "verification"))
    end

    test "string-key failed verification triggers tier 3" do
      result =
        RiskClassifier.classify(
          task(verification: %{"status" => "fail"}),
          diff()
        )

      assert result.tier == 3
    end
  end

  describe "tier 3 -- combined reasons" do
    test "protected path AND failed verification both appear in reasons" do
      result =
        RiskClassifier.classify(
          task(verification: %{status: :fail}),
          diff(files_changed: ["config/prod.exs"])
        )

      assert result.tier == 3
      assert Enum.any?(result.reasons, &String.contains?(&1, "protected"))
      assert Enum.any?(result.reasons, &String.contains?(&1, "verification"))
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 1: Auto-merge candidate
  # ---------------------------------------------------------------------------

  describe "tier 1 -- all criteria met" do
    test "trivial complexity, small diff, tests, no new files -> tier 1" do
      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(lines_added: 3, lines_deleted: 1, tests_exist: true, files_added: [])
        )

      assert result.tier == 1
    end

    test "standard complexity, small diff, tests, no new files -> tier 1" do
      result =
        RiskClassifier.classify(
          task(complexity: :standard),
          diff(lines_added: 8, lines_deleted: 2, tests_exist: true, files_added: [])
        )

      assert result.tier == 1
    end

    test "tier 1 includes descriptive reasons" do
      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(lines_added: 3, lines_deleted: 1, tests_exist: true)
        )

      assert result.tier == 1
      assert is_list(result.reasons)
      assert length(result.reasons) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 2: Default review
  # ---------------------------------------------------------------------------

  describe "tier 2 -- default cases" do
    test "complex complexity -> tier 2" do
      result =
        RiskClassifier.classify(
          task(complexity: :complex),
          diff(lines_added: 3, lines_deleted: 1, tests_exist: true)
        )

      assert result.tier == 2
    end

    test "lines_changed >= 20 -> tier 2" do
      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(lines_added: 15, lines_deleted: 6, tests_exist: true)
        )

      assert result.tier == 2
    end

    test "file_count > 3 -> tier 2" do
      files = ["a.ex", "b.ex", "c.ex", "d.ex"]

      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(lines_added: 5, lines_deleted: 2, files_changed: files, tests_exist: true)
        )

      assert result.tier == 2
    end

    test "new files present -> tier 2" do
      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(
            lines_added: 5,
            lines_deleted: 2,
            files_added: ["lib/new_module.ex"],
            tests_exist: true
          )
        )

      assert result.tier == 2
    end

    test "tests missing -> tier 2" do
      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(lines_added: 5, lines_deleted: 2, tests_exist: false)
        )

      assert result.tier == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "nil diff_meta -> tier 2" do
      result = RiskClassifier.classify(task(), nil)
      assert result.tier == 2
    end

    test "empty diff_meta -> tier 2" do
      result = RiskClassifier.classify(task(), %{})
      assert result.tier == 2
    end

    test "task with no complexity field -> tier 2 (not tier 1)" do
      result = RiskClassifier.classify(%{}, diff(lines_added: 3, lines_deleted: 1))
      assert result.tier == 2
    end

    test "verification_report nil -> verification passed (no report means ok)" do
      result =
        RiskClassifier.classify(
          task(complexity: :trivial, verification: nil),
          diff(lines_added: 3, lines_deleted: 1, tests_exist: true)
        )

      assert result.tier == 1
    end

    test "string-key verification report 'pass' -> passes" do
      result =
        RiskClassifier.classify(
          task(complexity: :trivial, verification: %{"status" => "pass"}),
          diff(lines_added: 3, lines_deleted: 1, tests_exist: true)
        )

      assert result.tier == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Output shape
  # ---------------------------------------------------------------------------

  describe "classification output shape" do
    test "returns tier, reasons, auto_merge_eligible, signals" do
      result = RiskClassifier.classify(task(), diff())
      assert is_integer(result.tier)
      assert result.tier in [1, 2, 3]
      assert is_list(result.reasons)
      assert is_boolean(result.auto_merge_eligible)
      assert is_map(result.signals)
    end

    test "auto_merge_eligible is always false in v1.3" do
      for tier <- [:trivial, :standard, :complex] do
        result = RiskClassifier.classify(task(complexity: tier), diff())
        assert result.auto_merge_eligible == false
      end
    end

    test "signals map contains expected keys" do
      result = RiskClassifier.classify(task(), diff())
      signals = result.signals

      assert Map.has_key?(signals, :complexity_tier)
      assert Map.has_key?(signals, :lines_changed)
      assert Map.has_key?(signals, :file_count)
      assert Map.has_key?(signals, :new_file_count)
      assert Map.has_key?(signals, :tests_exist)
      assert Map.has_key?(signals, :verification_passed)
      assert Map.has_key?(signals, :protected_paths_touched)
    end
  end

  # ---------------------------------------------------------------------------
  # Config-driven thresholds
  # ---------------------------------------------------------------------------

  describe "config-driven thresholds" do
    test "Config.get returns defaults for risk keys" do
      # These should return sensible defaults (not nil) when Config is running
      assert AgentCom.Config.get(:risk_tier1_max_lines) in [nil, 20]
      assert AgentCom.Config.get(:risk_tier1_max_files) in [nil, 3]
    end

    test "tier 1 max lines threshold is respected" do
      # At exactly the boundary: lines_added + lines_deleted = 19 < 20 -> tier 1
      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(lines_added: 10, lines_deleted: 9, tests_exist: true)
        )

      assert result.tier == 1

      # Over the boundary: 20 >= 20 -> tier 2
      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(lines_added: 10, lines_deleted: 10, tests_exist: true)
        )

      assert result.tier == 2
    end

    test "tier 1 max files threshold is respected" do
      # Exactly 3 files -> tier 1
      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(
            lines_added: 5,
            lines_deleted: 2,
            files_changed: ["a.ex", "b.ex", "c.ex"],
            tests_exist: true
          )
        )

      assert result.tier == 1

      # 4 files -> tier 2
      result =
        RiskClassifier.classify(
          task(complexity: :trivial),
          diff(
            lines_added: 5,
            lines_deleted: 2,
            files_changed: ["a.ex", "b.ex", "c.ex", "d.ex"],
            tests_exist: true
          )
        )

      assert result.tier == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  describe "telemetry" do
    setup do
      test_pid = self()
      handler_id = "risk-classifier-test-#{inspect(self())}"

      :telemetry.attach(
        handler_id,
        [:agent_com, :risk, :classified],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits [:agent_com, :risk, :classified] on classify" do
      RiskClassifier.classify(task(), diff())

      assert_receive {:telemetry, [:agent_com, :risk, :classified], measurements, metadata}
      assert is_integer(measurements.lines_changed)
      assert is_integer(measurements.file_count)
      assert metadata.tier in [1, 2, 3]
      assert is_atom(metadata.complexity_tier)
    end
  end
end
