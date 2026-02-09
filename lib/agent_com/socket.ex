defmodule AgentCom.Socket do
  @moduledoc """
  WebSocket handler for agent connections.

  ## Protocol

  ### Identify (required first message)

      -> {"type": "identify", "agent_id": "my-agent", "name": "My Agent", "status": "idle", "capabilities": ["search", "code"]}
      <- {"type": "identified", "agent_id": "my-agent"}

  ### Send a message

      -> {"type": "message", "to": "other-agent", "payload": {"text": "hello"}}
      <- {"type": "message_sent", "id": "abc123"}

  ### Broadcast

      -> {"type": "message", "payload": {"text": "anyone know about X?"}}
      <- {"type": "message_sent", "id": "abc123"}

  ### Receive messages

      <- {"type": "message", "id": "abc123", "from": "other-agent", "payload": {"text": "hello"}, "timestamp": 1234567890}

  ### Update status

      -> {"type": "status", "status": "working on deploy scripts"}
      <- {"type": "status_updated"}

  ### List agents

      -> {"type": "list_agents"}
      <- {"type": "agents", "agents": [...]}

  ### Presence events (auto-subscribed)

      <- {"type": "agent_joined", "agent": {...}}
      <- {"type": "agent_left", "agent_id": "some-agent"}

  ### Ping/Pong

      -> {"type": "ping"}
      <- {"type": "pong", "timestamp": 1234567890}
  """

  @behaviour WebSock

  alias AgentCom.{Message, Presence, Router}

  defstruct [:agent_id, :identified]

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{agent_id: nil, identified: false}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, msg} -> handle_msg(msg, state)
      {:error, _} -> reply_error("invalid_json", state)
    end
  end

  @impl true
  def handle_info({:message, %Message{} = msg}, state) do
    push = %{
      "type" => "message",
      "id" => msg.id,
      "from" => msg.from,
      "message_type" => msg.type,
      "payload" => msg.payload,
      "reply_to" => msg.reply_to,
      "timestamp" => msg.timestamp
    }
    {:push, {:text, Jason.encode!(push)}, state}
  end

  def handle_info({:agent_joined, info}, state) do
    # Don't echo own join
    if info.agent_id != state.agent_id do
      push = %{"type" => "agent_joined", "agent" => stringify_agent(info)}
      {:push, {:text, Jason.encode!(push)}, state}
    else
      {:ok, state}
    end
  end

  def handle_info({:agent_left, agent_id}, state) do
    push = %{"type" => "agent_left", "agent_id" => agent_id}
    {:push, {:text, Jason.encode!(push)}, state}
  end

  def handle_info({:status_changed, info}, state) do
    push = %{"type" => "status_changed", "agent" => stringify_agent(info)}
    {:push, {:text, Jason.encode!(push)}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    if state.agent_id do
      Registry.unregister(AgentCom.AgentRegistry, state.agent_id)
      Presence.unregister(state.agent_id)
    end
    :ok
  end

  # — Message handlers —

  # Identify (must be first)
  defp handle_msg(%{"type" => "identify", "agent_id" => agent_id} = msg, state) do
    name = Map.get(msg, "name", agent_id)
    status = Map.get(msg, "status", "connected")
    capabilities = Map.get(msg, "capabilities", [])

    Registry.register(AgentCom.AgentRegistry, agent_id, %{pid: self()})
    Presence.register(agent_id, %{name: name, status: status, capabilities: capabilities})

    # Subscribe to broadcasts and presence
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "messages")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")

    new_state = %{state | agent_id: agent_id, identified: true}
    reply = Jason.encode!(%{"type" => "identified", "agent_id" => agent_id})
    {:push, {:text, reply}, new_state}
  end

  # All other messages require identification
  defp handle_msg(_msg, %{identified: false} = state) do
    reply_error("not_identified", state)
  end

  defp handle_msg(%{"type" => "message"} = msg, state) do
    message = Message.new(%{
      from: state.agent_id,
      to: msg["to"],
      type: msg["message_type"] || "chat",
      payload: msg["payload"] || %{},
      reply_to: msg["reply_to"]
    })

    case Router.route(message) do
      {:ok, _} ->
        reply = Jason.encode!(%{"type" => "message_sent", "id" => message.id})
        {:push, {:text, reply}, state}
      {:error, reason} ->
        reply_error(to_string(reason), state)
    end
  end

  defp handle_msg(%{"type" => "status", "status" => status}, state) do
    Presence.update_status(state.agent_id, status)
    reply = Jason.encode!(%{"type" => "status_updated"})
    {:push, {:text, reply}, state}
  end

  defp handle_msg(%{"type" => "list_agents"}, state) do
    agents = Presence.list() |> Enum.map(&stringify_agent/1)
    reply = Jason.encode!(%{"type" => "agents", "agents" => agents})
    {:push, {:text, reply}, state}
  end

  defp handle_msg(%{"type" => "ping"}, state) do
    reply = Jason.encode!(%{"type" => "pong", "timestamp" => System.system_time(:millisecond)})
    {:push, {:text, reply}, state}
  end

  defp handle_msg(_unknown, state) do
    reply_error("unknown_message_type", state)
  end

  # — Helpers —

  defp reply_error(reason, state) do
    reply = Jason.encode!(%{"type" => "error", "error" => reason})
    {:push, {:text, reply}, state}
  end

  defp stringify_agent(info) do
    %{
      "agent_id" => info[:agent_id] || info.agent_id,
      "name" => info[:name] || Map.get(info, :name),
      "status" => info[:status] || Map.get(info, :status),
      "capabilities" => info[:capabilities] || Map.get(info, :capabilities, []),
      "connected_at" => info[:connected_at] || Map.get(info, :connected_at)
    }
  end
end
