defmodule AgentCom.MessageTest do
  use ExUnit.Case, async: true

  alias AgentCom.Message

  describe "new/1" do
    test "creates struct with id, timestamp, and defaults" do
      msg = Message.new(%{from: "agent-a", type: "chat", payload: %{"text" => "hi"}})

      assert is_binary(msg.id)
      assert String.length(msg.id) == 16  # 8 bytes hex-encoded
      assert msg.from == "agent-a"
      assert msg.type == "chat"
      assert msg.payload == %{"text" => "hi"}
      assert is_integer(msg.timestamp)
      assert msg.reply_to == nil
      assert msg.to == nil
    end

    test "accepts optional fields" do
      msg = Message.new(%{
        id: "custom-id",
        from: "agent-a",
        to: "agent-b",
        type: "request",
        payload: %{"action" => "fetch"},
        reply_to: "parent-msg"
      })

      assert msg.id == "custom-id"
      assert msg.to == "agent-b"
      assert msg.reply_to == "parent-msg"
    end

    test "defaults type to chat when not provided" do
      msg = Message.new(%{from: "agent-a", payload: %{}})
      assert msg.type == "chat"
    end
  end

  describe "to_json/1" do
    test "converts to string-keyed map" do
      msg = Message.new(%{from: "agent-a", to: "agent-b", type: "chat", payload: %{"x" => 1}})
      json = Message.to_json(msg)

      assert is_map(json)
      assert json["from"] == "agent-a"
      assert json["to"] == "agent-b"
      assert json["type"] == "chat"
      assert json["payload"] == %{"x" => 1}
      assert json["id"] == msg.id
      assert json["timestamp"] == msg.timestamp
      assert json["reply_to"] == nil
    end
  end

  describe "from_json/1" do
    test "converts from string-keyed map back to struct" do
      json = %{
        "id" => "test-id",
        "from" => "agent-a",
        "to" => "agent-b",
        "type" => "response",
        "payload" => %{"result" => "ok"},
        "reply_to" => "parent-id"
      }

      msg = Message.from_json(json)
      assert %Message{} = msg
      assert msg.id == "test-id"
      assert msg.from == "agent-a"
      assert msg.to == "agent-b"
      assert msg.type == "response"
      assert msg.payload == %{"result" => "ok"}
      assert msg.reply_to == "parent-id"
    end
  end

  describe "round-trip" do
    test "new -> to_json -> from_json preserves data" do
      original = Message.new(%{
        from: "agent-a",
        to: "agent-b",
        type: "chat",
        payload: %{"text" => "round trip"},
        reply_to: "parent-msg"
      })

      reconstructed = original |> Message.to_json() |> Message.from_json()

      assert reconstructed.id == original.id
      assert reconstructed.from == original.from
      assert reconstructed.to == original.to
      assert reconstructed.type == original.type
      assert reconstructed.payload == original.payload
      assert reconstructed.reply_to == original.reply_to
      # Timestamp may differ slightly since from_json calls new which sets a new timestamp
      # But the id, from, to, type, payload, reply_to should be preserved
    end
  end
end
