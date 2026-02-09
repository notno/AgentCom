defmodule AgentCom.Router do
  @moduledoc """
  Routes messages between agents.

  - Direct messages go to a specific agent's WebSocket process
  - Broadcasts go to the "messages" PubSub topic
  - Undeliverable messages are stored for later (TODO: message queue)
  """

  alias AgentCom.{Message, Presence}

  @doc "Send a message to its destination."
  def route(%Message{to: "broadcast"} = msg) do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "messages", {:message, msg})
    {:ok, :broadcast}
  end

  def route(%Message{to: nil} = msg) do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "messages", {:message, msg})
    {:ok, :broadcast}
  end

  def route(%Message{to: to} = msg) do
    case Registry.lookup(AgentCom.AgentRegistry, to) do
      [{pid, _}] ->
        send(pid, {:message, msg})
        {:ok, :delivered}
      [] ->
        # Agent not connected — for now, drop with error
        # TODO: queue for later delivery
        {:error, :agent_offline}
    end
  end

  @doc "Send a message and return the routed message."
  def send_message(attrs) do
    msg = Message.new(attrs)
    case route(msg) do
      {:ok, _} -> {:ok, msg}
      {:error, _} = err -> err
    end
  end
end
