defmodule AgentCom.RateLimiterTest do
  use ExUnit.Case, async: false

  alias AgentCom.RateLimiter
  alias AgentCom.RateLimiter.Config

  setup do
    # Tables already created by Application.start. Clear all entries for test isolation.
    # If tables don't exist (e.g., running tests in isolation), create them.
    for table <- [:rate_limit_buckets, :rate_limit_overrides] do
      case :ets.whereis(table) do
        :undefined -> :ets.new(table, [:named_table, :public, :set])
        _ref -> :ets.delete_all_objects(table)
      end
    end

    on_exit(fn ->
      for table <- [:rate_limit_buckets, :rate_limit_overrides] do
        case :ets.whereis(table) do
          :undefined -> :ok
          _ref -> :ets.delete_all_objects(table)
        end
      end
    end)

    :ok
  end

  # ===========================================================================
  # 1. RateLimiter.Config -- WS tier classification
  # ===========================================================================

  describe "Config.ws_tier/1" do
    test "classifies light WS message types" do
      for type <- ["ping", "list_agents", "list_channels", "status", "channel_history"] do
        assert Config.ws_tier(type) == :light, "Expected #{type} to be :light"
      end
    end

    test "classifies normal WS message types" do
      normal_types = [
        "message", "channel_publish", "channel_subscribe", "channel_unsubscribe",
        "task_accepted", "task_progress", "task_complete", "task_failed", "task_recovering"
      ]

      for type <- normal_types do
        assert Config.ws_tier(type) == :normal, "Expected #{type} to be :normal"
      end
    end

    test "classifies heavy WS message types" do
      assert Config.ws_tier("identify") == :heavy
    end

    test "defaults unknown types to :normal" do
      assert Config.ws_tier("unknown_type") == :normal
      assert Config.ws_tier("future_message") == :normal
    end
  end

  # ===========================================================================
  # 2. RateLimiter.Config -- HTTP tier classification
  # ===========================================================================

  describe "Config.http_tier/1" do
    test "classifies light HTTP actions" do
      light_actions = [:get_agents, :get_channels, :get_tasks, :get_metrics, :get_health,
                       :get_mailbox, :get_schemas, :get_dashboard_state]

      for action <- light_actions do
        assert Config.http_tier(action) == :light, "Expected #{action} to be :light"
      end
    end

    test "classifies normal HTTP actions" do
      normal_actions = [:post_message, :post_channel_publish, :post_mailbox_ack,
                        :get_messages, :get_task_detail, :get_channel_info]

      for action <- normal_actions do
        assert Config.http_tier(action) == :normal, "Expected #{action} to be :normal"
      end
    end

    test "classifies heavy HTTP actions" do
      heavy_actions = [:post_task, :post_channel, :post_admin_push_task, :post_onboard_register]

      for action <- heavy_actions do
        assert Config.http_tier(action) == :heavy, "Expected #{action} to be :heavy"
      end
    end

    test "defaults unknown HTTP actions to :normal" do
      assert Config.http_tier(:unknown_action) == :normal
    end
  end

  # ===========================================================================
  # 3. RateLimiter.Config -- defaults/1
  # ===========================================================================

  describe "Config.defaults/1" do
    test "returns correct capacity and refill_rate for :light tier" do
      {capacity, refill_rate} = Config.defaults(:light)
      assert capacity == 120_000
      assert is_float(refill_rate)
      assert refill_rate > 0
    end

    test "returns correct capacity and refill_rate for :normal tier" do
      {capacity, refill_rate} = Config.defaults(:normal)
      assert capacity == 60_000
      assert is_float(refill_rate)
      assert refill_rate > 0
    end

    test "returns correct capacity and refill_rate for :heavy tier" do
      {capacity, refill_rate} = Config.defaults(:heavy)
      assert capacity == 10_000
      assert is_float(refill_rate)
      assert refill_rate > 0
    end
  end

  # ===========================================================================
  # 4. RateLimiter core -- token bucket basics
  # ===========================================================================

  describe "RateLimiter.check/3 basic behavior" do
    test "first request initializes bucket and returns {:allow, remaining}" do
      assert {:allow, remaining} = RateLimiter.check("agent-1", :ws, :normal)
      # capacity 60_000 internal units - 1000 cost = 59_000 internal, div by 1000 = 59
      assert remaining == 59
    end

    test "repeated requests decrement tokens" do
      {:allow, r1} = RateLimiter.check("agent-2", :ws, :normal)
      {:allow, r2} = RateLimiter.check("agent-2", :ws, :normal)
      {:allow, r3} = RateLimiter.check("agent-2", :ws, :normal)

      assert r1 > r2
      assert r2 > r3
    end

    test "after capacity requests, returns {:deny, retry_after_ms}" do
      # Use heavy tier for small capacity (10 tokens)
      # Exhaust all tokens
      for _ <- 1..10 do
        result = RateLimiter.check("agent-exhaust", :ws, :heavy)
        assert elem(result, 0) in [:allow, :warn]
      end

      # 11th request should be denied
      assert {:deny, retry_after_ms} = RateLimiter.check("agent-exhaust", :ws, :heavy)
      assert is_integer(retry_after_ms)
      assert retry_after_ms > 0
    end

    test "retry_after_ms is rounded to nearest 1000ms (whole seconds)" do
      # Exhaust all tokens on heavy tier
      for _ <- 1..10 do
        RateLimiter.check("agent-round", :ws, :heavy)
      end

      {:deny, retry_after_ms} = RateLimiter.check("agent-round", :ws, :heavy)
      assert rem(retry_after_ms, 1000) == 0, "retry_after_ms should be a multiple of 1000"
    end
  end

  # ===========================================================================
  # 5. RateLimiter -- lazy refill (time passage)
  # ===========================================================================

  describe "RateLimiter.check/3 lazy refill" do
    test "tokens refill over time via lazy refill" do
      # Use heavy tier (10 tokens, refills over 60s)
      # Exhaust all tokens
      for _ <- 1..10 do
        RateLimiter.check("agent-refill", :ws, :heavy)
      end

      assert {:deny, _} = RateLimiter.check("agent-refill", :ws, :heavy)

      # Simulate time passage by directly modifying ETS entry timestamp
      # Set last_refill to 10 seconds ago (should refill ~1.67 tokens for heavy tier)
      key = {"agent-refill", :ws, :heavy}
      [{^key, tokens, _last_refill, capacity, refill_rate}] = :ets.lookup(:rate_limit_buckets, key)
      past = System.monotonic_time(:millisecond) - 10_000
      :ets.insert(:rate_limit_buckets, {key, tokens, past, capacity, refill_rate})

      # After 10 seconds, should have regained some tokens
      result = RateLimiter.check("agent-refill", :ws, :heavy)
      assert elem(result, 0) in [:allow, :warn]
    end
  end

  # ===========================================================================
  # 6. RateLimiter -- 80% warn threshold
  # ===========================================================================

  describe "RateLimiter.check/3 warn threshold" do
    test "returns {:warn, remaining} when usage crosses 80% threshold" do
      # Use heavy tier (10 tokens). 80% used = 2 remaining (20% of 10).
      # Consume 8 tokens to get to 2 remaining
      for _ <- 1..8 do
        result = RateLimiter.check("agent-warn", :ws, :heavy)
        assert elem(result, 0) in [:allow, :warn]
      end

      # The 9th request should put us at 1 remaining (10% of capacity)
      # which is below 20% threshold -> :warn
      assert {:warn, remaining} = RateLimiter.check("agent-warn", :ws, :heavy)
      assert remaining < 2
    end
  end

  # ===========================================================================
  # 7. RateLimiter -- bucket isolation
  # ===========================================================================

  describe "RateLimiter.check/3 bucket isolation" do
    test "independent buckets per agent" do
      # Exhaust agent A's heavy tier
      for _ <- 1..10 do
        RateLimiter.check("agent-A", :ws, :heavy)
      end

      assert {:deny, _} = RateLimiter.check("agent-A", :ws, :heavy)

      # Agent B should be unaffected
      assert {:allow, _} = RateLimiter.check("agent-B", :ws, :heavy)
    end

    test "independent buckets per channel (WS vs HTTP)" do
      # Exhaust WS heavy tier
      for _ <- 1..10 do
        RateLimiter.check("agent-chan", :ws, :heavy)
      end

      assert {:deny, _} = RateLimiter.check("agent-chan", :ws, :heavy)

      # HTTP heavy tier should be unaffected
      assert {:allow, _} = RateLimiter.check("agent-chan", :http, :heavy)
    end

    test "independent buckets per tier" do
      # Exhaust :heavy tier
      for _ <- 1..10 do
        RateLimiter.check("agent-tier", :ws, :heavy)
      end

      assert {:deny, _} = RateLimiter.check("agent-tier", :ws, :heavy)

      # :normal tier should be unaffected
      assert {:allow, _} = RateLimiter.check("agent-tier", :ws, :normal)
    end
  end

  # ===========================================================================
  # 8. Exemption tests
  # ===========================================================================

  describe "RateLimiter exempt agents" do
    test "exempt agent always gets {:allow, :exempt}" do
      :ets.insert(:rate_limit_overrides, {:whitelist, ["exempt-agent"]})

      assert {:allow, :exempt} = RateLimiter.check("exempt-agent", :ws, :normal)
      assert {:allow, :exempt} = RateLimiter.check("exempt-agent", :ws, :heavy)
      assert {:allow, :exempt} = RateLimiter.check("exempt-agent", :http, :light)

      # Still exempt after many calls
      for _ <- 1..100 do
        assert {:allow, :exempt} = RateLimiter.check("exempt-agent", :ws, :heavy)
      end
    end

    test "non-exempt agent gets normal rate limiting" do
      :ets.insert(:rate_limit_overrides, {:whitelist, ["exempt-agent"]})

      # Non-exempt agent should NOT get :exempt
      {:allow, remaining} = RateLimiter.check("normal-agent", :ws, :normal)
      assert is_integer(remaining)
    end
  end

  # ===========================================================================
  # 9. Progressive backoff tests
  # ===========================================================================

  describe "RateLimiter.record_violation/1" do
    test "increments consecutive violations" do
      ms1 = RateLimiter.record_violation("agent-v1")
      ms2 = RateLimiter.record_violation("agent-v1")

      assert ms1 < ms2
    end

    test "1st violation returns retry_after_ms = 1000" do
      assert RateLimiter.record_violation("agent-v2") == 1000
    end

    test "2nd violation returns retry_after_ms = 2000" do
      RateLimiter.record_violation("agent-v3")
      assert RateLimiter.record_violation("agent-v3") == 2000
    end

    test "3rd violation returns retry_after_ms = 5000" do
      RateLimiter.record_violation("agent-v4")
      RateLimiter.record_violation("agent-v4")
      assert RateLimiter.record_violation("agent-v4") == 5000
    end

    test "4th violation returns retry_after_ms = 10000" do
      for _ <- 1..3, do: RateLimiter.record_violation("agent-v5")
      assert RateLimiter.record_violation("agent-v5") == 10_000
    end

    test "5th+ violation returns retry_after_ms = 30000" do
      for _ <- 1..4, do: RateLimiter.record_violation("agent-v6")
      assert RateLimiter.record_violation("agent-v6") == 30_000

      # 6th also 30000
      assert RateLimiter.record_violation("agent-v6") == 30_000
    end
  end

  describe "violation quiet period reset" do
    test "violation count resets after 60s quiet period" do
      # Record some violations
      RateLimiter.record_violation("agent-quiet")
      RateLimiter.record_violation("agent-quiet")
      RateLimiter.record_violation("agent-quiet")

      # Simulate 61 seconds of quiet by modifying ETS entry
      key = {"agent-quiet", :violations}

      case :ets.lookup(:rate_limit_buckets, key) do
        [{^key, count, _window_start, consecutive}] ->
          past = System.monotonic_time(:millisecond) - 61_000
          :ets.insert(:rate_limit_buckets, {key, count, past, consecutive})

        _ ->
          :ok
      end

      # Next violation should start fresh at 1000ms (1st violation)
      assert RateLimiter.record_violation("agent-quiet") == 1000
    end
  end

  describe "RateLimiter.rate_limited?/1" do
    test "returns true when agent has active violations" do
      RateLimiter.record_violation("agent-limited")
      assert RateLimiter.rate_limited?("agent-limited") == true
    end

    test "returns false when agent has no violations" do
      assert RateLimiter.rate_limited?("agent-clean") == false
    end
  end
end
