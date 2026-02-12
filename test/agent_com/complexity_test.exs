defmodule AgentCom.ComplexityTest do
  use ExUnit.Case, async: true

  alias AgentCom.Complexity

  describe "build/1 with explicit tier" do
    test "explicit 'standard' returns effective_tier :standard with source :explicit" do
      result = Complexity.build(%{"complexity_tier" => "standard"})

      assert result.effective_tier == :standard
      assert result.explicit_tier == :standard
      assert result.source == :explicit
      assert is_map(result.inferred)
    end

    test "explicit 'trivial' returns effective_tier :trivial with source :explicit" do
      result = Complexity.build(%{"complexity_tier" => "trivial"})

      assert result.effective_tier == :trivial
      assert result.explicit_tier == :trivial
      assert result.source == :explicit
    end

    test "explicit 'complex' returns effective_tier :complex with source :explicit" do
      result = Complexity.build(%{"complexity_tier" => "complex"})

      assert result.effective_tier == :complex
      assert result.explicit_tier == :complex
      assert result.source == :explicit
    end

    test "explicit 'unknown' is a valid tier" do
      result = Complexity.build(%{"complexity_tier" => "unknown"})

      assert result.effective_tier == :unknown
      assert result.explicit_tier == :unknown
      assert result.source == :explicit
    end

    test "explicit tier wins even when heuristic disagrees" do
      # Submit as trivial but description looks complex
      result =
        Complexity.build(%{
          "complexity_tier" => "trivial",
          "description" =>
            "Refactor the entire authentication system to support OAuth2 with multiple providers, migrate existing user tokens, and update all API endpoints"
        })

      assert result.effective_tier == :trivial
      assert result.source == :explicit
      # Heuristic still ran and inferred something different
      assert result.inferred.tier != :trivial
    end

    test "heuristic always runs alongside explicit tier" do
      result = Complexity.build(%{"complexity_tier" => "standard"})

      assert is_map(result.inferred)
      assert Map.has_key?(result.inferred, :tier)
      assert Map.has_key?(result.inferred, :confidence)
      assert Map.has_key?(result.inferred, :signals)
    end

    test "invalid explicit tier string is ignored (nil)" do
      result = Complexity.build(%{"complexity_tier" => "mega_hard"})

      assert result.explicit_tier == nil
      assert result.source == :inferred
    end
  end

  describe "build/1 with inferred tier" do
    test "short trivial description infers :trivial" do
      result = Complexity.build(%{"description" => "fix typo in readme"})

      assert result.effective_tier == :trivial
      assert result.explicit_tier == nil
      assert result.source == :inferred
      assert result.inferred.tier == :trivial
    end

    test "complex description with many file hints infers :complex" do
      result =
        Complexity.build(%{
          "description" =>
            "Refactor the entire authentication system to support OAuth2 with multiple providers, migrate existing user tokens, and update all API endpoints",
          "file_hints" => [
            %{"path" => "a.ex"},
            %{"path" => "b.ex"},
            %{"path" => "c.ex"},
            %{"path" => "d.ex"},
            %{"path" => "e.ex"}
          ]
        })

      assert result.effective_tier == :complex
      assert result.source == :inferred
    end

    test "medium description infers :standard" do
      result =
        Complexity.build(%{
          "description" => "Add a new optional field to the user settings page for notification preferences",
          "file_hints" => [%{"path" => "settings.ex"}, %{"path" => "settings_test.exs"}]
        })

      assert result.effective_tier == :standard
      assert result.source == :inferred
    end

    test "empty params returns :unknown with 0.0 confidence" do
      result = Complexity.build(%{})

      assert result.effective_tier == :unknown
      assert result.explicit_tier == nil
      assert result.source == :inferred
      assert result.inferred.tier == :unknown
      assert result.inferred.confidence == 0.0
    end
  end

  describe "build/1 with atom keys" do
    test "handles atom key for complexity_tier" do
      result = Complexity.build(%{complexity_tier: "standard"})

      assert result.effective_tier == :standard
      assert result.source == :explicit
    end

    test "handles atom key for description" do
      result = Complexity.build(%{description: "fix typo"})

      assert result.effective_tier == :trivial
      assert result.source == :inferred
    end
  end

  describe "infer/1" do
    test "returns map with tier, confidence, and signals" do
      result = Complexity.infer(%{"description" => "fix a bug"})

      assert is_atom(result.tier)
      assert is_float(result.confidence) or result.confidence == 0.0
      assert is_map(result.signals)
    end

    test "confidence is clamped to [0.0, 1.0]" do
      result = Complexity.infer(%{"description" => "fix typo"})

      assert result.confidence >= 0.0
      assert result.confidence <= 1.0
    end

    test "signals include word_count, file_count, verification_count, keywords" do
      result =
        Complexity.infer(%{
          "description" => "do something",
          "file_hints" => [%{"path" => "a.ex"}],
          "verification_steps" => [%{"type" => "test_passes", "target" => "mix test"}]
        })

      assert Map.has_key?(result.signals, :word_count)
      assert Map.has_key?(result.signals, :file_count)
      assert Map.has_key?(result.signals, :verification_count)
      assert Map.has_key?(result.signals, :keywords)
    end
  end

  describe "signal-based classification" do
    test "trivial keywords boost trivial classification" do
      result = Complexity.infer(%{"description" => "fix typo in readme"})

      assert result.tier == :trivial
      assert result.signals.keywords.trivial == true
    end

    test "complex keywords boost complex classification" do
      result =
        Complexity.infer(%{
          "description" => "refactor the authentication architecture and migrate the database"
        })

      assert result.tier == :complex
      assert result.signals.keywords.complex == true
    end

    test "many file hints signal complexity" do
      result =
        Complexity.infer(%{
          "description" =>
            "Update the validation layer across all endpoint handlers to support the new enrichment field format",
          "file_hints" => Enum.map(1..6, fn i -> %{"path" => "file_#{i}.ex"} end)
        })

      # Many files + medium description should push toward complex or standard
      assert result.tier in [:complex, :standard]
    end

    test "many verification steps signal complexity" do
      steps = Enum.map(1..5, fn i -> %{"type" => "test_passes", "target" => "test_#{i}"} end)

      result =
        Complexity.infer(%{
          "description" =>
            "Implement the new feature with all necessary validation checks and test coverage across modules",
          "verification_steps" => steps
        })

      assert result.tier in [:complex, :standard]
    end

    test "word count thresholds: short description" do
      result = Complexity.infer(%{"description" => "bump version"})
      assert result.signals.word_count < 10
    end

    test "word count thresholds: long description" do
      long_desc = Enum.map_join(1..60, " ", fn i -> "word#{i}" end)
      result = Complexity.infer(%{"description" => long_desc})
      assert result.signals.word_count > 50
    end
  end

  describe "telemetry on disagreement" do
    setup do
      test_pid = self()
      handler_id = "complexity-test-#{inspect(self())}"

      :telemetry.attach_many(
        handler_id,
        [[:agent_com, :complexity, :disagreement]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits telemetry when explicit and inferred disagree" do
      # Explicit trivial but description looks complex
      Complexity.build(%{
        "complexity_tier" => "trivial",
        "description" =>
          "Refactor the entire authentication system to support OAuth2 with multiple providers, migrate tokens, redesign auth"
      })

      assert_receive {:telemetry_event, [:agent_com, :complexity, :disagreement], %{}, metadata}
      assert metadata.explicit == :trivial
      assert metadata.inferred_tier != :trivial
    end

    test "does not emit telemetry when explicit and inferred agree" do
      # Explicit trivial and description is trivial
      Complexity.build(%{
        "complexity_tier" => "trivial",
        "description" => "fix typo"
      })

      refute_receive {:telemetry_event, [:agent_com, :complexity, :disagreement], _, _}, 100
    end
  end
end
