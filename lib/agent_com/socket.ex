defmodule AgentCom.Socket do
  @moduledoc """
  WebSocket handler for agent connections.

  ## Protocol

  ### Identify (required first message)

      -> {"type": "identify", "agent_id": "my-agent", "token": "abc123...", "name": "My Agent", "status": "idle", "capabilities": ["search", "code"]}
      <- {"type": "identified", "agent_id": "my-agent"}
      <- {"type": "error", "error": "invalid_token"}  (if token is wrong)
      <- {"type": "error", "error": "token_agent_mismatch"}  (if token belongs to a different agent)

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

  ## Sidecar Task Protocol

  ### Task lifecycle (sidecar -> hub)

      -> {"type": "task_accepted", "task_id": "task-abc123"}
      <- {"type": "task_ack", "task_id": "task-abc123", "status": "accepted"}

      -> {"type": "task_progress", "task_id": "task-abc123", "progress": 50}
      (no reply — fire and forget, updates TaskQueue timestamp to prevent overdue sweep)

      -> {"type": "task_complete", "task_id": "task-abc123", "generation": 1, "result": {...}, "tokens_used": 150}
      <- {"type": "task_ack", "task_id": "task-abc123", "status": "complete"}

      -> {"type": "task_failed", "task_id": "task-abc123", "generation": 1, "error": "..."}
      <- {"type": "task_ack", "task_id": "task-abc123", "status": "failed"}
      <- {"type": "task_ack", "task_id": "task-abc123", "status": "retried"}
      <- {"type": "task_ack", "task_id": "task-abc123", "status": "dead_letter"}

      -> {"type": "task_recovering", "task_id": "task-abc123"}
      <- {"type": "task_continue", "task_id": "task-abc123", "generation": 1}  (still assigned)
      <- {"type": "task_reassign", "task_id": "task-abc123"}                    (not assigned)

  ### Task assignment (hub -> sidecar, pushed via WebSocket)

      <- {"type": "task_assign", "task_id": "task-abc123", "description": "...", "metadata": {...}, "generation": 1, "assigned_at": 1234567890}
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

  def handle_info({:channel_message, channel, %AgentCom.Message{} = msg}, state) do
    # Don't echo own messages back via WebSocket (sender already got the publish ack)
    if msg.from != state.agent_id do
      push = %{
        "type" => "channel_message",
        "channel" => channel,
        "id" => msg.id,
        "from" => msg.from,
        "message_type" => msg.type,
        "payload" => msg.payload,
        "reply_to" => msg.reply_to,
        "timestamp" => msg.timestamp
      }
      {:push, {:text, Jason.encode!(push)}, state}
    else
      {:ok, state}
    end
  end

  def handle_info({:channel_subscribed, channel, agent_id}, state) do
    if agent_id != state.agent_id do
      push = %{"type" => "channel_agent_joined", "channel" => channel, "agent_id" => agent_id}
      {:push, {:text, Jason.encode!(push)}, state}
    else
      {:ok, state}
    end
  end

  def handle_info({:status_changed, info}, state) do
    push = %{"type" => "status_changed", "agent" => stringify_agent(info)}
    {:push, {:text, Jason.encode!(push)}, state}
  end

  def handle_info({:push_task, task}, state) do
    push = %{
      "type" => "task_assign",
      "task_id" => task["task_id"] || task[:task_id],
      "description" => task["description"] || task[:description] || "",
      "metadata" => task["metadata"] || task[:metadata] || %{},
      "generation" => task["generation"] || task[:generation] || 0,
      "assigned_at" => System.system_time(:millisecond)
    }
    {:push, {:text, Jason.encode!(push)}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    if state.agent_id do
      Registry.unregister(AgentCom.AgentRegistry, state.agent_id)
      Presence.unregister(state.agent_id)
      AgentCom.Analytics.record_disconnect(state.agent_id)
    end
    :ok
  end

  # — Message handlers —

  # Identify (must be first, requires valid token)
  defp handle_msg(%{"type" => "identify", "agent_id" => agent_id} = msg, state) do
    token = Map.get(msg, "token")

    case AgentCom.Auth.verify(token) do
      {:ok, ^agent_id} ->
        do_identify(agent_id, msg, state)
      {:ok, _other} ->
        reply_error("token_agent_mismatch", state)
      :error ->
        reply_error("invalid_token", state)
    end
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

  # --- Channel operations ---

  defp handle_msg(%{"type" => "channel_subscribe", "channel" => channel}, state) do
    case AgentCom.Channels.subscribe(channel, state.agent_id) do
      :ok ->
        Phoenix.PubSub.subscribe(AgentCom.PubSub, "channel:#{AgentCom.Channels.normalize_name(channel)}")
        reply = Jason.encode!(%{"type" => "channel_subscribed", "channel" => channel})
        {:push, {:text, reply}, state}
      {:ok, :already_subscribed} ->
        reply = Jason.encode!(%{"type" => "channel_subscribed", "channel" => channel, "note" => "already_subscribed"})
        {:push, {:text, reply}, state}
      {:error, :not_found} ->
        reply_error("channel_not_found", state)
    end
  end

  defp handle_msg(%{"type" => "channel_unsubscribe", "channel" => channel}, state) do
    case AgentCom.Channels.unsubscribe(channel, state.agent_id) do
      :ok ->
        Phoenix.PubSub.unsubscribe(AgentCom.PubSub, "channel:#{AgentCom.Channels.normalize_name(channel)}")
        reply = Jason.encode!(%{"type" => "channel_unsubscribed", "channel" => channel})
        {:push, {:text, reply}, state}
      {:error, :not_found} ->
        reply_error("channel_not_found", state)
    end
  end

  defp handle_msg(%{"type" => "channel_publish", "channel" => channel, "payload" => payload} = msg, state) do
    message = AgentCom.Message.new(%{
      from: state.agent_id,
      to: nil,
      type: msg["message_type"] || "chat",
      payload: payload,
      reply_to: msg["reply_to"]
    })
    case AgentCom.Channels.publish(channel, message) do
      {:ok, seq} ->
        reply = Jason.encode!(%{"type" => "channel_published", "channel" => channel, "seq" => seq, "id" => message.id})
        {:push, {:text, reply}, state}
      {:error, :not_found} ->
        reply_error("channel_not_found", state)
    end
  end

  defp handle_msg(%{"type" => "channel_history", "channel" => channel} = msg, state) do
    limit = msg["limit"] || 50
    since = msg["since"] || 0
    messages = AgentCom.Channels.history(channel, limit: limit, since: since)
    reply = Jason.encode!(%{"type" => "channel_history", "channel" => channel, "messages" => messages})
    {:push, {:text, reply}, state}
  end

  defp handle_msg(%{"type" => "list_channels"}, state) do
    channels = AgentCom.Channels.list()
    reply = Jason.encode!(%{"type" => "channels", "channels" => channels})
    {:push, {:text, reply}, state}
  end

  defp handle_msg(%{"type" => "ping"}, state) do
    Presence.touch(state.agent_id)
    reply = Jason.encode!(%{"type" => "pong", "timestamp" => System.system_time(:millisecond)})
    {:push, {:text, reply}, state}
  end

  # --- Sidecar task lifecycle messages ---

  defp handle_msg(%{"type" => "task_accepted", "task_id" => task_id} = msg, state) do
    log_task_event(state.agent_id, "task_accepted", task_id, msg)
    # Update timestamp to signal the task is actively being worked on
    AgentCom.TaskQueue.update_progress(task_id)
    reply = Jason.encode!(%{"type" => "task_ack", "task_id" => task_id, "status" => "accepted"})
    {:push, {:text, reply}, state}
  end

  defp handle_msg(%{"type" => "task_progress", "task_id" => task_id} = msg, state) do
    log_task_event(state.agent_id, "task_progress", task_id, msg)
    # Update timestamp to prevent overdue sweep reclamation
    AgentCom.TaskQueue.update_progress(task_id)
    {:ok, state}
  end

  defp handle_msg(%{"type" => "task_complete", "task_id" => task_id} = msg, state) do
    log_task_event(state.agent_id, "task_complete", task_id, msg)
    generation = msg["generation"] || 0
    result = msg["result"] || %{}
    tokens_used = msg["tokens_used"] || result["tokens_used"]

    case AgentCom.TaskQueue.complete_task(task_id, generation, %{
      result: result,
      tokens_used: tokens_used
    }) do
      {:ok, _task} ->
        reply = Jason.encode!(%{"type" => "task_ack", "task_id" => task_id, "status" => "complete"})
        {:push, {:text, reply}, state}
      {:error, reason} ->
        reply_error("task_complete_failed: #{reason}", state)
    end
  end

  defp handle_msg(%{"type" => "task_failed", "task_id" => task_id} = msg, state) do
    log_task_event(state.agent_id, "task_failed", task_id, msg)
    generation = msg["generation"] || 0
    error = msg["error"] || msg["reason"] || "unknown"

    case AgentCom.TaskQueue.fail_task(task_id, generation, error) do
      {:ok, :retried, _task} ->
        reply = Jason.encode!(%{"type" => "task_ack", "task_id" => task_id, "status" => "retried"})
        {:push, {:text, reply}, state}
      {:ok, :dead_letter, _task} ->
        reply = Jason.encode!(%{"type" => "task_ack", "task_id" => task_id, "status" => "dead_letter"})
        {:push, {:text, reply}, state}
      {:error, reason} ->
        reply_error("task_fail_failed: #{reason}", state)
    end
  end

  defp handle_msg(%{"type" => "task_recovering", "task_id" => task_id} = msg, state) do
    log_task_event(state.agent_id, "task_recovering", task_id, msg)

    case AgentCom.TaskQueue.recover_task(task_id) do
      {:ok, :continue, task} ->
        # Task is still assigned to this agent -- tell sidecar to continue
        reply = Jason.encode!(%{
          "type" => "task_continue",
          "task_id" => task_id,
          "generation" => task.generation
        })
        {:push, {:text, reply}, state}
      {:ok, :reassign} ->
        reply = Jason.encode!(%{"type" => "task_reassign", "task_id" => task_id})
        {:push, {:text, reply}, state}
      {:error, :not_found} ->
        reply = Jason.encode!(%{"type" => "task_reassign", "task_id" => task_id})
        {:push, {:text, reply}, state}
    end
  end

  defp handle_msg(_unknown, state) do
    reply_error("unknown_message_type", state)
  end

  # — Identity —

  defp do_identify(agent_id, msg, state) do
    name = Map.get(msg, "name", agent_id)
    status = Map.get(msg, "status", "connected")
    capabilities = Map.get(msg, "capabilities", [])

    Registry.register(AgentCom.AgentRegistry, agent_id, %{pid: self()})
    Presence.register(agent_id, %{name: name, status: status, capabilities: capabilities})

    # Subscribe to broadcasts and presence
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "messages")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")

    # Subscribe to any channels this agent is already in
    AgentCom.Channels.subscriptions(agent_id)
    |> Enum.each(fn ch ->
      Phoenix.PubSub.subscribe(AgentCom.PubSub, "channel:#{ch}")
    end)

    # Track analytics
    AgentCom.Analytics.record_connect(agent_id)

    new_state = %{state | agent_id: agent_id, identified: true}
    reply = Jason.encode!(%{"type" => "identified", "agent_id" => agent_id})
    {:push, {:text, reply}, new_state}
  end

  # — Helpers —

  defp log_task_event(agent_id, event, task_id, msg) do
    require Logger
    Logger.info("Task event: #{event} from #{agent_id} for task #{task_id}")
    # Broadcast to PubSub for future dashboard/monitoring consumption
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "tasks", {:task_event, %{
      agent_id: agent_id,
      event: event,
      task_id: task_id,
      payload: msg,
      timestamp: System.system_time(:millisecond)
    }})
  end

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
