defmodule AgentCom.OllamaClientTest do
  use ExUnit.Case, async: true

  alias AgentCom.OllamaClient

  describe "parse_response/1" do
    test "extracts content and token counts from valid response" do
      response = %{
        "message" => %{"role" => "assistant", "content" => "hello"},
        "prompt_eval_count" => 10,
        "eval_count" => 20,
        "total_duration" => 5_000_000
      }

      assert {:ok, parsed} = OllamaClient.parse_response(response)
      assert parsed.content == "hello"
      assert parsed.prompt_tokens == 10
      assert parsed.eval_tokens == 20
      assert parsed.total_duration_ns == 5_000_000
    end

    test "strips thinking blocks from content" do
      response = %{
        "message" => %{
          "role" => "assistant",
          "content" => "<think>reasoning here</think>\nactual answer"
        },
        "prompt_eval_count" => 5,
        "eval_count" => 15,
        "total_duration" => 3_000_000
      }

      assert {:ok, parsed} = OllamaClient.parse_response(response)
      assert parsed.content == "actual answer"
    end

    test "handles missing token counts with defaults of 0" do
      response = %{
        "message" => %{"role" => "assistant", "content" => "hi"}
      }

      assert {:ok, parsed} = OllamaClient.parse_response(response)
      assert parsed.content == "hi"
      assert parsed.prompt_tokens == 0
      assert parsed.eval_tokens == 0
      assert parsed.total_duration_ns == 0
    end

    test "returns error for unexpected format" do
      response = %{"error" => "model not found"}

      assert {:error, {:unexpected_format, ^response}} =
               OllamaClient.parse_response(response)
    end
  end

  describe "chat/2" do
    test "returns connection error when Ollama not running" do
      assert {:error, {:connection_error, _}} =
               OllamaClient.chat("hello", host: "localhost", port: 19999, timeout: 1_000)
    end
  end

  describe "build_messages/2" do
    test "creates system + user messages when system provided" do
      messages = OllamaClient.build_messages("Be helpful", "What is 2+2?")

      assert [
               %{"role" => "system", "content" => "Be helpful"},
               %{"role" => "user", "content" => "What is 2+2?"}
             ] = messages
    end

    test "creates only user message when system is nil" do
      messages = OllamaClient.build_messages(nil, "What is 2+2?")

      assert [%{"role" => "user", "content" => "What is 2+2?"}] = messages
    end

    test "creates only user message when system is empty string" do
      messages = OllamaClient.build_messages("", "What is 2+2?")

      assert [%{"role" => "user", "content" => "What is 2+2?"}] = messages
    end
  end

  describe "build_body/3" do
    test "includes tools only when provided" do
      messages = [%{"role" => "user", "content" => "hi"}]

      body_without = OllamaClient.build_body("qwen3:8b", messages, nil)
      refute Map.has_key?(body_without, "tools")

      body_with_empty = OllamaClient.build_body("qwen3:8b", messages, [])
      refute Map.has_key?(body_with_empty, "tools")

      tools = [%{"type" => "function", "function" => %{"name" => "read_file"}}]
      body_with = OllamaClient.build_body("qwen3:8b", messages, tools)
      assert Map.has_key?(body_with, "tools")
      assert body_with["tools"] == tools
    end

    test "sets stream to false and default options" do
      messages = [%{"role" => "user", "content" => "hi"}]
      body = OllamaClient.build_body("qwen3:8b", messages, nil)

      assert body["stream"] == false
      assert body["model"] == "qwen3:8b"
      assert body["options"]["temperature"] == 0.3
      assert body["options"]["num_ctx"] == 8192
    end
  end

  describe "strip_thinking/1" do
    test "removes thinking blocks" do
      assert OllamaClient.strip_thinking("<think>foo</think>bar") == "bar"
    end

    test "handles content with no thinking blocks" do
      assert OllamaClient.strip_thinking("just plain text") == "just plain text"
    end

    test "handles multiple thinking blocks" do
      input = "<think>first</think>hello <think>second</think>world"
      assert OllamaClient.strip_thinking(input) == "hello world"
    end
  end
end
