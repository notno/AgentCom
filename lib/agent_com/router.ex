defmodule AgentCom.Router do
  @moduledoc """
  Routes messages between agents.

  - Direct messages go to a specific agent's WebSocket process
  - Broadcasts go to the "messages" PubSub topic
  - Undeliverable messages are stored for later (TODO: message queue)
  """

  alias AgentCom.{Message, Mailbox}

  @doc "Send a message to its destination."
  def route(%Message{to: "broadcast"} = msg) do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "messages", {:message, msg})
    queue_for_offline(msg)
    {:ok, :broadcast}
  end

  def route(%Message{to: nil} = msg) do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "messages", {:message, msg})
    queue_for_offline(msg)
    {:ok, :broadcast}
  end

  def route(%Message{to: to} = msg) do
    case Registry.lookup(AgentCom.AgentRegistry, to) do
      [{pid, _}] ->
        send(pid, {:message, msg})
        {:ok, :delivered}
      [] ->
        # Agent not connected — queue for polling
        AgentCom.Mailbox.enqueue(to, msg)
        {:ok, :queued}
    end
  end

  # Queue broadcast messages for agents that are registered but currently offline
  defp queue_for_offline(%Message{from: from} = msg) do
    # Get all known agent_ids from Auth, find ones not currently connected
    AgentCom.Auth.list()
    |> Enum.each(fn %{agent_id: agent_id} ->
      if agent_id != from do
        case Registry.lookup(AgentCom.AgentRegistry, agent_id) do
          [] -> Mailbox.enqueue(agent_id, msg)
          _ -> :ok  # online, they got it via PubSub
        end
      end
    end)
  end

  @doc "Send a message and return the routed message."
  def send_message(attrs) do
    msg = Message.new(attrs)
    case route(msg) do
      {:ok, _} = result ->
        # Track analytics
        AgentCom.Analytics.record_message(msg.from, msg.to, msg.type)
        {:ok, msg}
      {:error, _} = err -> err
    end
  end
end
