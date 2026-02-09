defmodule AgentCom.Message do
  @moduledoc """
  A message between agents.

  Messages have:
  - `id` — unique message id
  - `from` — sender agent_id
  - `to` — recipient agent_id (or "broadcast" for all)
  - `type` — message type: "chat", "request", "response", "status", "ping"
  - `payload` — freeform map (the actual content)
  - `timestamp` — when it was created
  - `reply_to` — optional, id of message being replied to
  """

  @enforce_keys [:from, :type, :payload]
  defstruct [
    :id,
    :from,
    :to,
    :type,
    :payload,
    :reply_to,
    :timestamp
  ]

  def new(attrs) do
    %__MODULE__{
      id: attrs[:id] || generate_id(),
      from: attrs[:from] || attrs["from"],
      to: attrs[:to] || attrs["to"],
      type: attrs[:type] || attrs["type"] || "chat",
      payload: attrs[:payload] || attrs["payload"] || %{},
      reply_to: attrs[:reply_to] || attrs["reply_to"],
      timestamp: System.system_time(:millisecond)
    }
  end

  def from_json(map) when is_map(map) do
    new(%{
      id: map["id"],
      from: map["from"],
      to: map["to"],
      type: map["type"],
      payload: map["payload"],
      reply_to: map["reply_to"]
    })
  end

  def to_json(%__MODULE__{} = msg) do
    %{
      "id" => msg.id,
      "from" => msg.from,
      "to" => msg.to,
      "type" => msg.type,
      "payload" => msg.payload,
      "reply_to" => msg.reply_to,
      "timestamp" => msg.timestamp
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
