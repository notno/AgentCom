defmodule AgentCom.TaskRouterTest do
  use ExUnit.Case, async: true

  alias AgentCom.TaskRouter
  alias AgentCom.TaskRouter.TierResolver
  alias AgentCom.TaskRouter.LoadScorer

  # ---------------------------------------------------------------------------
  # Test Helpers
  # ---------------------------------------------------------------------------

  defp make_task(tier, opts \\ []) do
    complexity =
      case tier do
        nil -> nil
        :no_effective_tier -> %{explicit_tier: :standard, inferred: %{}, source: :explicit}
        _ -> %{effective_tier: tier, explicit_tier: nil, inferred: %{tier: tier, confidence: 0.8, signals: %{}}, source: :inferred}
      end

    base = %{
      id: Keyword.get(opts, :id, "task-#{:erlang.unique_integer([:positive])}"),
      complexity: complexity,
      repo: Keyword.get(opts, :repo, nil),
      description: Keyword.get(opts, :description, "test task")
    }

    base
  end

  defp make_endpoint(id, opts \\ []) do
    %{
      id: id,
      host: Keyword.get(opts, :host, String.split(id, ":") |> hd()),
      port: Keyword.get(opts, :port, 11434),
      status: Keyword.get(opts, :status, :healthy),
      models: Keyword.get(opts, :models, ["qwen2.5-coder:7b"]),
      name: Keyword.get(opts, :name, nil)
    }
  end

  defp make_resources(cpu_percent, opts \\ []) do
    %{
      cpu_percent: cpu_percent,
      ram_total_bytes: Keyword.get(opts, :ram_total, 16 * 1024 * 1024 * 1024),
      ram_used_bytes: Keyword.get(opts, :ram_used, 8 * 1024 * 1024 * 1024),
      vram_total_bytes: Keyword.get(opts, :vram_total, nil),
      vram_used_bytes: Keyword.get(opts, :vram_used, nil),
      repo: Keyword.get(opts, :repo, nil)
    }
  end

  # ---------------------------------------------------------------------------
  # TierResolver Tests
  # ---------------------------------------------------------------------------

  describe "TierResolver.resolve/1" do
    test "trivial effective_tier resolves to :trivial" do
      task = make_task(:trivial)
      assert TierResolver.resolve(task) == :trivial
    end

    test "standard effective_tier resolves to :standard" do
      task = make_task(:standard)
      assert TierResolver.resolve(task) == :standard
    end

    test "complex effective_tier resolves to :complex" do
      task = make_task(:complex)
      assert TierResolver.resolve(task) == :complex
    end

    test "unknown effective_tier defaults to :standard" do
      task = make_task(:unknown)
      assert TierResolver.resolve(task) == :standard
    end

    test "nil complexity defaults to :standard" do
      task = make_task(nil)
      assert TierResolver.resolve(task) == :standard
    end

    test "complexity map missing effective_tier defaults to :standard" do
      task = make_task(:no_effective_tier)
      assert TierResolver.resolve(task) == :standard
    end
  end

  describe "TierResolver.fallback_up/1" do
    test "trivial falls back up to :standard" do
      assert TierResolver.fallback_up(:trivial) == :standard
    end

    test "standard falls back up to :complex" do
      assert TierResolver.fallback_up(:standard) == :complex
    end

    test "complex has no further escalation" do
      assert TierResolver.fallback_up(:complex) == nil
    end
  end

  describe "TierResolver.fallback_down/1" do
    test "complex falls back down to :standard" do
      assert TierResolver.fallback_down(:complex) == :standard
    end

    test "standard falls back down to :trivial" do
      assert TierResolver.fallback_down(:standard) == :trivial
    end

    test "trivial has no further de-escalation" do
      assert TierResolver.fallback_down(:trivial) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # LoadScorer Tests
  # ---------------------------------------------------------------------------

  describe "LoadScorer.score_and_rank/3" do
    test "single endpoint with low load scores high" do
      endpoints = [make_endpoint("host1:11434")]
      resources = %{"host1:11434" => make_resources(20.0)}
      task = make_task(:standard)

      [{endpoint_id, score, _details}] = LoadScorer.score_and_rank(endpoints, resources, task)

      assert endpoint_id == "host1:11434"
      assert score > 0.5
    end

    test "single endpoint with high load scores low" do
      endpoints = [make_endpoint("host1:11434")]
      resources = %{"host1:11434" => make_resources(90.0)}
      task = make_task(:standard)

      [{_endpoint_id, score, _details}] = LoadScorer.score_and_rank(endpoints, resources, task)

      assert score < 0.5
    end

    test "two endpoints: less loaded one ranks first" do
      endpoints = [
        make_endpoint("host1:11434"),
        make_endpoint("host2:11434")
      ]

      resources = %{
        "host1:11434" => make_resources(80.0),
        "host2:11434" => make_resources(20.0)
      }

      task = make_task(:standard)
      ranked = LoadScorer.score_and_rank(endpoints, resources, task)

      [{first_id, first_score, _}, {second_id, second_score, _}] = ranked
      assert first_id == "host2:11434"
      assert second_id == "host1:11434"
      assert first_score > second_score
    end

    test "warm model bonus: endpoint with model loaded gets 1.15x multiplier" do
      endpoints = [
        make_endpoint("host1:11434", models: ["qwen2.5-coder:7b"]),
        make_endpoint("host2:11434", models: ["other-model:7b"])
      ]

      # Same load for fair comparison
      resources = %{
        "host1:11434" => make_resources(50.0),
        "host2:11434" => make_resources(50.0)
      }

      # Task that matches the model on host1
      task = make_task(:standard)
      ranked = LoadScorer.score_and_rank(endpoints, resources, task, default_model: "qwen2.5-coder:7b")

      [{first_id, first_score, _}, {second_id, second_score, _}] = ranked
      assert first_id == "host1:11434"
      assert second_id == "host2:11434"

      # The warm model host should have approximately 15% higher score
      ratio = first_score / second_score
      assert_in_delta ratio, 1.15, 0.01
    end

    test "repo affinity gives 5% bonus when load is similar" do
      endpoints = [
        make_endpoint("host1:11434"),
        make_endpoint("host2:11434")
      ]

      # Same load, but host1 has the same repo
      resources = %{
        "host1:11434" => make_resources(50.0, repo: "my-project"),
        "host2:11434" => make_resources(50.0)
      }

      task = make_task(:standard, repo: "my-project")
      ranked = LoadScorer.score_and_rank(endpoints, resources, task)

      [{first_id, first_score, _}, {second_id, second_score, _}] = ranked
      assert first_id == "host1:11434"
      assert second_id == "host2:11434"

      ratio = first_score / second_score
      assert_in_delta ratio, 1.05, 0.01
    end

    test "capacity factor: host with more RAM scores higher" do
      endpoints = [
        make_endpoint("host1:11434"),
        make_endpoint("host2:11434")
      ]

      resources = %{
        "host1:11434" => make_resources(50.0, ram_total: 32 * 1024 * 1024 * 1024),
        "host2:11434" => make_resources(50.0, ram_total: 8 * 1024 * 1024 * 1024)
      }

      task = make_task(:standard)
      ranked = LoadScorer.score_and_rank(endpoints, resources, task)

      [{first_id, _, _}, {second_id, _, _}] = ranked
      assert first_id == "host1:11434"
      assert second_id == "host2:11434"
    end

    test "capacity factor capped at 1.5x" do
      endpoints = [make_endpoint("host1:11434")]

      # 128GB RAM -> would be 8x reference if uncapped
      resources = %{
        "host1:11434" => make_resources(50.0, ram_total: 128 * 1024 * 1024 * 1024)
      }

      task = make_task(:standard)
      [{_, score_big, _}] = LoadScorer.score_and_rank(endpoints, resources, task)

      # Compare with exact 1.5x cap (reference is 16GB)
      resources_ref = %{
        "host1:11434" => make_resources(50.0, ram_total: 24 * 1024 * 1024 * 1024)
      }

      [{_, score_ref, _}] = LoadScorer.score_and_rank(endpoints, resources_ref, task)

      # 128GB should be capped at same 1.5x as 24GB (both hit cap)
      assert_in_delta score_big, score_ref, 0.01
    end

    test "VRAM factor: host with more free VRAM scores higher" do
      endpoints = [
        make_endpoint("host1:11434"),
        make_endpoint("host2:11434")
      ]

      resources = %{
        "host1:11434" => make_resources(50.0, vram_total: 8_000_000_000, vram_used: 1_000_000_000),
        "host2:11434" => make_resources(50.0, vram_total: 8_000_000_000, vram_used: 7_000_000_000)
      }

      task = make_task(:standard)
      ranked = LoadScorer.score_and_rank(endpoints, resources, task)

      [{first_id, _, _}, _] = ranked
      assert first_id == "host1:11434"
    end

    test "missing resource data uses neutral defaults" do
      endpoints = [make_endpoint("host1:11434")]
      resources = %{}
      task = make_task(:standard)

      [{endpoint_id, score, _details}] = LoadScorer.score_and_rank(endpoints, resources, task)

      assert endpoint_id == "host1:11434"
      # Score should be reasonable with defaults, not zero or negative
      assert score > 0.1
    end

    test "empty candidates returns empty list" do
      resources = %{"host1:11434" => make_resources(50.0)}
      task = make_task(:standard)

      assert LoadScorer.score_and_rank([], resources, task) == []
    end

    test "all resource values nil uses neutral defaults" do
      endpoints = [make_endpoint("host1:11434")]

      resources = %{
        "host1:11434" => %{
          cpu_percent: nil,
          ram_total_bytes: nil,
          ram_used_bytes: nil,
          vram_total_bytes: nil,
          vram_used_bytes: nil
        }
      }

      task = make_task(:standard)
      [{_id, score, _}] = LoadScorer.score_and_rank(endpoints, resources, task)

      assert score > 0.1
    end
  end

  # ---------------------------------------------------------------------------
  # TaskRouter Tests
  # ---------------------------------------------------------------------------

  describe "TaskRouter.route/3 - trivial tier" do
    test "trivial task routes to :sidecar target type" do
      task = make_task(:trivial)
      endpoints = [make_endpoint("host1:11434")]
      resources = %{}

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      assert decision.target_type == :sidecar
      assert decision.effective_tier == :trivial
      assert decision.estimated_cost_tier == :free
    end
  end

  describe "TaskRouter.route/3 - standard tier" do
    test "standard task routes to highest-scored healthy Ollama endpoint" do
      task = make_task(:standard)

      endpoints = [
        make_endpoint("host1:11434"),
        make_endpoint("host2:11434")
      ]

      resources = %{
        "host1:11434" => make_resources(80.0),
        "host2:11434" => make_resources(20.0)
      }

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      assert decision.target_type == :ollama
      assert decision.selected_endpoint == "host2:11434"
      assert decision.effective_tier == :standard
      assert decision.estimated_cost_tier == :local
    end

    test "standard task with no healthy endpoints returns fallback signal" do
      task = make_task(:standard)

      endpoints = [
        make_endpoint("host1:11434", status: :unhealthy),
        make_endpoint("host2:11434", status: :unknown)
      ]

      resources = %{}

      {:fallback, tier, reason} = TaskRouter.route(task, endpoints, resources)

      assert tier == :standard
      assert reason == :no_healthy_ollama_endpoints
    end

    test "endpoints with empty models list excluded from standard tier" do
      task = make_task(:standard)

      endpoints = [
        make_endpoint("host1:11434", models: []),
        make_endpoint("host2:11434", models: ["qwen2.5-coder:7b"])
      ]

      resources = %{
        "host1:11434" => make_resources(10.0),
        "host2:11434" => make_resources(50.0)
      }

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      # host2 should be selected despite higher load, because host1 has no models
      assert decision.selected_endpoint == "host2:11434"
    end

    test "only healthy endpoints are considered" do
      task = make_task(:standard)

      endpoints = [
        make_endpoint("host1:11434", status: :unhealthy),
        make_endpoint("host2:11434", status: :healthy)
      ]

      resources = %{
        "host1:11434" => make_resources(10.0),
        "host2:11434" => make_resources(90.0)
      }

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      # host2 selected even with high load because host1 is unhealthy
      assert decision.selected_endpoint == "host2:11434"
    end
  end

  describe "TaskRouter.route/3 - complex tier" do
    test "complex task routes to :claude target type" do
      task = make_task(:complex)
      endpoints = [make_endpoint("host1:11434")]
      resources = %{}

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      assert decision.target_type == :claude
      assert decision.effective_tier == :complex
      assert decision.estimated_cost_tier == :api
    end
  end

  describe "TaskRouter.route/3 - unknown tier" do
    test "unknown tier routes as :standard" do
      task = make_task(:unknown)

      endpoints = [make_endpoint("host1:11434")]
      resources = %{"host1:11434" => make_resources(30.0)}

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      assert decision.target_type == :ollama
      assert decision.effective_tier == :standard
    end
  end

  describe "TaskRouter.route/3 - routing decision fields" do
    test "routing decision includes all required fields" do
      task = make_task(:standard, id: "task-123")

      endpoints = [make_endpoint("host1:11434")]
      resources = %{"host1:11434" => make_resources(30.0)}

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      assert Map.has_key?(decision, :effective_tier)
      assert Map.has_key?(decision, :target_type)
      assert Map.has_key?(decision, :selected_endpoint)
      assert Map.has_key?(decision, :selected_model)
      assert Map.has_key?(decision, :fallback_used)
      assert Map.has_key?(decision, :fallback_from_tier)
      assert Map.has_key?(decision, :fallback_reason)
      assert Map.has_key?(decision, :candidate_count)
      assert Map.has_key?(decision, :classification_reason)
      assert Map.has_key?(decision, :estimated_cost_tier)
      assert Map.has_key?(decision, :decided_at)
    end

    test "decided_at is a recent timestamp" do
      task = make_task(:trivial)

      before = System.system_time(:millisecond)
      {:ok, decision} = TaskRouter.route(task, [], %{})
      after_time = System.system_time(:millisecond)

      assert decision.decided_at >= before
      assert decision.decided_at <= after_time
    end

    test "classification_reason includes source and tier info" do
      task = make_task(:standard)

      endpoints = [make_endpoint("host1:11434")]
      resources = %{"host1:11434" => make_resources(30.0)}

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      assert is_binary(decision.classification_reason)
      assert String.contains?(decision.classification_reason, "standard")
    end

    test "non-fallback decision has fallback_used false" do
      task = make_task(:standard)

      endpoints = [make_endpoint("host1:11434")]
      resources = %{"host1:11434" => make_resources(30.0)}

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      assert decision.fallback_used == false
      assert decision.fallback_from_tier == nil
      assert decision.fallback_reason == nil
    end

    test "candidate_count reflects number of viable endpoints" do
      task = make_task(:standard)

      endpoints = [
        make_endpoint("host1:11434"),
        make_endpoint("host2:11434"),
        make_endpoint("host3:11434", status: :unhealthy)
      ]

      resources = %{
        "host1:11434" => make_resources(30.0),
        "host2:11434" => make_resources(40.0)
      }

      {:ok, decision} = TaskRouter.route(task, endpoints, resources)

      assert decision.candidate_count == 2
    end
  end
end
