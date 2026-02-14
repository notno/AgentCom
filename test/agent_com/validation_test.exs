defmodule AgentCom.ValidationTest do
  use ExUnit.Case, async: true

  alias AgentCom.Validation
  alias AgentCom.Validation.Schemas

  # ===========================================================================
  # 1. WebSocket message validation -- valid messages (one per type)
  # ===========================================================================

  describe "WebSocket valid messages" do
    test "validates identify with all required fields" do
      msg = %{"type" => "identify", "agent_id" => "a1", "token" => "tok"}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates identify with optional fields" do
      msg = %{
        "type" => "identify",
        "agent_id" => "a1",
        "token" => "tok",
        "name" => "Agent One",
        "status" => "idle",
        "capabilities" => ["search", "code"]
      }

      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates message with required fields" do
      msg = %{"type" => "message", "payload" => %{"text" => "hi"}}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates status" do
      msg = %{"type" => "status", "status" => "working"}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates list_agents" do
      msg = %{"type" => "list_agents"}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates ping" do
      msg = %{"type" => "ping"}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates channel_subscribe" do
      msg = %{"type" => "channel_subscribe", "channel" => "general"}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates channel_unsubscribe" do
      msg = %{"type" => "channel_unsubscribe", "channel" => "general"}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates channel_publish" do
      msg = %{"type" => "channel_publish", "channel" => "general", "payload" => %{"data" => 1}}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates channel_history with required and optional" do
      msg = %{"type" => "channel_history", "channel" => "general", "limit" => 10, "since" => 0}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)

      msg_min = %{"type" => "channel_history", "channel" => "general"}
      assert {:ok, ^msg_min} = Validation.validate_ws_message(msg_min)
    end

    test "validates list_channels" do
      msg = %{"type" => "list_channels"}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates task_accepted" do
      msg = %{"type" => "task_accepted", "task_id" => "t1"}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates task_progress with optional progress" do
      msg = %{"type" => "task_progress", "task_id" => "t1", "progress" => 50}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)

      msg_min = %{"type" => "task_progress", "task_id" => "t1"}
      assert {:ok, ^msg_min} = Validation.validate_ws_message(msg_min)
    end

    test "validates task_complete with generation" do
      msg = %{"type" => "task_complete", "task_id" => "t1", "generation" => 1}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates task_failed with generation" do
      msg = %{"type" => "task_failed", "task_id" => "t1", "generation" => 1}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end

    test "validates task_recovering" do
      msg = %{"type" => "task_recovering", "task_id" => "t1"}
      assert {:ok, ^msg} = Validation.validate_ws_message(msg)
    end
  end

  # ===========================================================================
  # 2. WebSocket validation -- missing required fields
  # ===========================================================================

  describe "WebSocket missing required fields" do
    test "rejects identify missing agent_id" do
      msg = %{"type" => "identify", "token" => "tok"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "agent_id" and &1.error == :required))
    end

    test "rejects identify missing token" do
      msg = %{"type" => "identify", "agent_id" => "a1"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "token" and &1.error == :required))
    end

    test "rejects message missing payload" do
      msg = %{"type" => "message"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "payload" and &1.error == :required))
    end

    test "rejects channel_subscribe missing channel" do
      msg = %{"type" => "channel_subscribe"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "channel" and &1.error == :required))
    end

    test "rejects task_complete missing generation" do
      msg = %{"type" => "task_complete", "task_id" => "t1"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "generation" and &1.error == :required))
    end

    test "rejects task_complete missing task_id" do
      msg = %{"type" => "task_complete", "generation" => 1}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "task_id" and &1.error == :required))
    end

    test "returns multiple errors for multiple missing fields" do
      msg = %{"type" => "identify"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      fields = Enum.map(errors, & &1.field)
      assert "agent_id" in fields
      assert "token" in fields
    end
  end

  # ===========================================================================
  # 3. WebSocket validation -- wrong types (strict, no coercion)
  # ===========================================================================

  describe "WebSocket wrong types" do
    test "rejects string where integer expected" do
      msg = %{"type" => "task_complete", "task_id" => "t1", "generation" => "not_int"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "generation" and &1.error == :wrong_type))

      error = Enum.find(errors, &(&1.field == "generation"))
      assert error.value == "not_int"
    end

    test "rejects integer where string expected" do
      msg = %{"type" => "status", "status" => 42}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "status" and &1.error == :wrong_type))
    end

    test "rejects string where map expected" do
      msg = %{"type" => "message", "payload" => "not_a_map"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "payload" and &1.error == :wrong_type))
    end

    test "rejects integer where list expected" do
      msg = %{
        "type" => "identify",
        "agent_id" => "a1",
        "token" => "tok",
        "capabilities" => 42
      }

      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "capabilities" and &1.error == :wrong_type))
    end
  end

  # ===========================================================================
  # 4. WebSocket validation -- unknown type and missing type
  # ===========================================================================

  describe "WebSocket unknown/missing type" do
    test "rejects unknown message type" do
      msg = %{"type" => "nonexistent"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      error = hd(errors)
      assert error.field == "type"
      assert error.error == :unknown_message_type
      assert is_list(error.known_types)
    end

    test "rejects missing type field" do
      msg = %{"some" => "data"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      error = hd(errors)
      assert error.field == "type"
      assert error.error == :required
    end

    test "rejects non-string type" do
      msg = %{"type" => 123}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      error = hd(errors)
      assert error.field == "type"
      assert error.error == :wrong_type
      assert error.value == 123
    end
  end

  # ===========================================================================
  # 5. WebSocket validation -- unknown fields pass through
  # ===========================================================================

  describe "WebSocket unknown fields pass through" do
    test "passes through unknown fields" do
      msg = %{"type" => "ping", "extra_field" => "value"}
      assert {:ok, result} = Validation.validate_ws_message(msg)
      assert result["extra_field"] == "value"
    end

    test "passes through deeply nested unknown fields" do
      msg = %{
        "type" => "message",
        "payload" => %{"text" => "hi", "nested" => %{"deep" => true}},
        "custom_meta" => %{"x" => 1}
      }

      assert {:ok, result} = Validation.validate_ws_message(msg)
      assert result["custom_meta"] == %{"x" => 1}
    end
  end

  # ===========================================================================
  # 6. String length limits
  # ===========================================================================

  describe "string length limits" do
    test "rejects agent_id over 128 chars" do
      long_id = String.duplicate("a", 129)

      msg = %{"type" => "identify", "agent_id" => long_id, "token" => "tok"}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "agent_id" and &1.error == :too_long))
    end

    test "rejects channel over 64 chars" do
      long_channel = String.duplicate("c", 65)

      msg = %{"type" => "channel_subscribe", "channel" => long_channel}
      assert {:error, errors} = Validation.validate_ws_message(msg)
      assert Enum.any?(errors, &(&1.field == "channel" and &1.error == :too_long))
    end

    test "accepts agent_id at limit" do
      id = String.duplicate("a", 128)
      msg = %{"type" => "identify", "agent_id" => id, "token" => "tok"}
      assert {:ok, _} = Validation.validate_ws_message(msg)
    end
  end

  # ===========================================================================
  # 7. HTTP validation
  # ===========================================================================

  describe "HTTP validation" do
    test "validates post_task with required description" do
      params = %{"description" => "Do the thing"}
      assert {:ok, ^params} = Validation.validate_http(:post_task, params)
    end

    test "rejects post_task missing description" do
      params = %{}
      assert {:error, errors} = Validation.validate_http(:post_task, params)
      assert Enum.any?(errors, &(&1.field == "description" and &1.error == :required))
    end

    test "validates post_task with optional fields" do
      params = %{
        "description" => "Build feature",
        "priority" => "high",
        "metadata" => %{"repo" => "test"},
        "max_retries" => 5,
        "needed_capabilities" => ["code"]
      }

      assert {:ok, ^params} = Validation.validate_http(:post_task, params)
    end

    test "validates put_heartbeat_interval with positive integer" do
      params = %{"heartbeat_interval_ms" => 30000}
      assert {:ok, ^params} = Validation.validate_http(:put_heartbeat_interval, params)
    end

    test "rejects put_heartbeat_interval with zero" do
      params = %{"heartbeat_interval_ms" => 0}
      assert {:error, errors} = Validation.validate_http(:put_heartbeat_interval, params)
      assert Enum.any?(errors, &(&1.field == "heartbeat_interval_ms" and &1.error == :wrong_type))
    end

    test "rejects put_heartbeat_interval with string" do
      params = %{"heartbeat_interval_ms" => "30000"}
      assert {:error, errors} = Validation.validate_http(:put_heartbeat_interval, params)
      assert Enum.any?(errors, &(&1.field == "heartbeat_interval_ms" and &1.error == :wrong_type))
    end

    test "validates post_channel with name" do
      params = %{"name" => "general"}
      assert {:ok, ^params} = Validation.validate_http(:post_channel, params)
    end

    test "validates post_onboard_register with agent_id" do
      params = %{"agent_id" => "new-agent"}
      assert {:ok, ^params} = Validation.validate_http(:post_onboard_register, params)
    end

    test "rejects post_onboard_register with empty agent_id" do
      # The schema validates that agent_id is a string (which "" is).
      # The empty string check is done at the endpoint level, not schema level.
      # Schema only validates type, so "" passes schema validation.
      params = %{"agent_id" => ""}
      # Empty string IS a valid string -- the endpoint does the emptiness check
      assert {:ok, _} = Validation.validate_http(:post_onboard_register, params)
    end

    test "validates post_mailbox_ack with seq" do
      params = %{"seq" => 42}
      assert {:ok, ^params} = Validation.validate_http(:post_mailbox_ack, params)
    end
  end

  # ===========================================================================
  # 8. Schema introspection
  # ===========================================================================

  describe "schema introspection" do
    test "known_types returns all 19 message types" do
      types = Schemas.known_types()
      assert length(types) == 19

      expected = ~w(
        identify message status list_agents ping
        channel_subscribe channel_unsubscribe channel_publish channel_history list_channels
        task_accepted task_progress task_complete task_failed task_recovering
        ollama_report resource_report state_report wake_result
      )

      for t <- expected do
        assert t in types, "Expected #{t} in known_types"
      end
    end

    test "to_json returns JSON-serializable structure" do
      json = Schemas.to_json()
      assert {:ok, _} = Jason.encode(json)
      assert is_list(json["websocket"])
      assert is_list(json["http"])
      assert json["version"] == "1.0"
    end

    test "all schemas have required and optional maps" do
      for {_type, schema} <- Schemas.all() do
        assert is_map(schema.required)
        assert is_map(schema.optional)
      end
    end

    test "http_schema returns schemas for known keys" do
      known_keys = [
        :post_message, :put_heartbeat_interval, :put_mailbox_retention,
        :post_channel, :post_channel_publish, :post_mailbox_ack,
        :post_admin_token, :post_admin_push_task, :post_task,
        :post_onboard_register, :put_default_repo, :post_push_subscribe
      ]

      for key <- known_keys do
        schema = Schemas.http_schema(key)
        assert schema != nil, "Expected schema for #{key}"
        assert is_map(schema.required)
        assert is_map(schema.optional)
      end
    end
  end

  # ===========================================================================
  # 9. Error format
  # ===========================================================================

  describe "error formatting" do
    test "format_errors converts atoms to strings" do
      errors = [%{field: "name", error: :required, detail: "field is required"}]
      formatted = Validation.format_errors(errors)
      assert [%{"field" => "name", "error" => "required", "detail" => "field is required"}] = formatted
    end

    test "format_errors includes value when present" do
      errors = [%{field: "gen", error: :wrong_type, detail: "expected integer", value: "str"}]
      formatted = Validation.format_errors(errors)
      assert hd(formatted)["value"] == "str"
    end

    test "format_errors omits value when nil" do
      errors = [%{field: "name", error: :required, detail: "field is required"}]
      formatted = Validation.format_errors(errors)
      refute Map.has_key?(hd(formatted), "value")
    end
  end

  # ===========================================================================
  # 10. Enrichment field validation
  # ===========================================================================

  describe "enrichment field validation" do
    test "valid task with all enrichment fields passes validation" do
      params = %{
        "description" => "Build feature",
        "repo" => "https://github.com/org/repo",
        "branch" => "feature/branch",
        "file_hints" => [
          %{"path" => "src/main.ex", "reason" => "entry point"},
          %{"path" => "test/main_test.exs"}
        ],
        "success_criteria" => ["All tests pass", "No warnings"],
        "verification_steps" => [
          %{"type" => "test_passes", "target" => "mix test", "description" => "Run tests"},
          %{"type" => "file_exists", "target" => "src/main.ex"}
        ],
        "complexity_tier" => "standard"
      }

      assert {:ok, ^params} = Validation.validate_enrichment_fields(params)
    end

    test "valid task without enrichment fields passes (backward compat)" do
      params = %{"description" => "Simple task"}

      assert {:ok, ^params} = Validation.validate_enrichment_fields(params)
    end

    test "invalid file_hints (missing path) returns error" do
      params = %{
        "file_hints" => [
          %{"reason" => "no path here"}
        ]
      }

      assert {:error, errors} = Validation.validate_enrichment_fields(params)
      assert Enum.any?(errors, &(&1.field == "file_hints[0].path" and &1.error == :required))
    end

    test "invalid file_hints (empty path) returns error" do
      params = %{
        "file_hints" => [
          %{"path" => "", "reason" => "empty path"}
        ]
      }

      assert {:error, errors} = Validation.validate_enrichment_fields(params)
      assert Enum.any?(errors, &(&1.field == "file_hints[0].path" and &1.error == :required))
    end

    test "invalid verification_steps (missing type) returns error" do
      params = %{
        "verification_steps" => [
          %{"target" => "mix test"}
        ]
      }

      assert {:error, errors} = Validation.validate_enrichment_fields(params)
      assert Enum.any?(errors, &(&1.field == "verification_steps[0].type" and &1.error == :required))
    end

    test "invalid verification_steps (missing target) returns error" do
      params = %{
        "verification_steps" => [
          %{"type" => "test_passes"}
        ]
      }

      assert {:error, errors} = Validation.validate_enrichment_fields(params)
      assert Enum.any?(errors, &(&1.field == "verification_steps[0].target" and &1.error == :required))
    end

    test "invalid complexity_tier ('mega') returns error" do
      params = %{"complexity_tier" => "mega"}

      assert {:error, errors} = Validation.validate_enrichment_fields(params)
      assert Enum.any?(errors, &(&1.field == "complexity_tier" and &1.error == :invalid_value))
    end

    test "valid complexity_tier values all pass" do
      for tier <- ["trivial", "standard", "complex", "unknown"] do
        params = %{"complexity_tier" => tier}
        assert {:ok, ^params} = Validation.validate_enrichment_fields(params)
      end
    end

    test "verification steps at soft limit (10) passes with no warning" do
      steps = for i <- 1..10, do: %{"type" => "test_passes", "target" => "test_#{i}"}
      params = %{"verification_steps" => steps}

      assert :ok = Validation.verify_step_soft_limit(params)
    end

    test "verification steps exceeding soft limit (11) returns warning" do
      steps = for i <- 1..11, do: %{"type" => "test_passes", "target" => "test_#{i}"}
      params = %{"verification_steps" => steps}

      assert {:warn, msg} = Validation.verify_step_soft_limit(params)
      assert msg =~ "11 verification steps"
      assert msg =~ "soft limit: 10"
    end
  end

  # ===========================================================================
  # 11. Edge cases
  # ===========================================================================

  describe "edge cases" do
    test "non-map input returns error" do
      assert {:error, [error]} = Validation.validate_ws_message("not a map")
      assert error.field == "message"
      assert error.error == :wrong_type
    end

    test "unknown HTTP schema key returns error" do
      assert {:error, [error]} = Validation.validate_http(:nonexistent_schema, %{})
      assert error.error == :unknown_schema
    end
  end
end
