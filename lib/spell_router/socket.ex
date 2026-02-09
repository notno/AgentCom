defmodule SpellRouter.Socket do
  @moduledoc """
  WebSocket handler for operator agents.
  
  Protocol:
  
  ## Agent Registration
  
      -> {"type": "register", "agent_id": "hush_operator", "capabilities": ["transform"]}
      <- {"type": "registered", "agent_id": "hush_operator"}
  
  ## Receiving Transform Requests
  
      <- {"type": "transform", "request_id": "abc123", "signal": {...}}
      -> {"type": "transform_result", "request_id": "abc123", "signal": {...}}
  
  ## Subscribing to Pipeline Events
  
      -> {"type": "subscribe", "topic": "pipeline:*"}
      <- {"type": "subscribed", "topic": "pipeline:*"}
      <- {"type": "event", "topic": "pipeline:xyz", "event": "step_complete", "data": {...}}
  
  ## Submitting Pipelines
  
      -> {"type": "run_pipeline", "request_id": "def456", "steps": [...]}
      <- {"type": "pipeline_result", "request_id": "def456", "status": "completed", "signal": {...}}
  """

  @behaviour WebSock

  alias SpellRouter.Signal

  defstruct [:agent_id, :capabilities, :subscriptions, :pending_requests]

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      agent_id: nil,
      capabilities: [],
      subscriptions: [],
      pending_requests: %{}
    }
    {:ok, state}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, message} ->
        handle_message(message, state)
      {:error, _} ->
        reply = Jason.encode!(%{type: "error", error: "invalid_json"})
        {:push, {:text, reply}, state}
    end
  end

  @impl true
  def handle_info({:transform_request, request_id, signal}, state) do
    msg = %{
      type: "transform",
      request_id: request_id,
      signal: Signal.to_json(signal)
    }
    {:push, {:text, Jason.encode!(msg)}, state}
  end

  def handle_info({:pipeline_event, topic, event, data}, state) do
    msg = %{
      type: "event",
      topic: topic,
      event: event,
      data: data
    }
    {:push, {:text, Jason.encode!(msg)}, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.agent_id do
      Registry.unregister(SpellRouter.OperatorRegistry, state.agent_id)
    end
    :ok
  end

  # Message Handlers

  defp handle_message(%{"type" => "register", "agent_id" => agent_id} = msg, state) do
    capabilities = Map.get(msg, "capabilities", [])
    
    # Register in the operator registry
    Registry.register(SpellRouter.OperatorRegistry, agent_id, %{
      capabilities: capabilities,
      pid: self()
    })

    new_state = %{state | agent_id: agent_id, capabilities: capabilities}
    reply = Jason.encode!(%{type: "registered", agent_id: agent_id})
    
    {:push, {:text, reply}, new_state}
  end

  defp handle_message(%{"type" => "transform_result", "request_id" => req_id, "signal" => signal_json}, state) do
    signal = Signal.from_json(signal_json)
    
    # Notify waiting process
    case Map.get(state.pending_requests, req_id) do
      nil -> :ok
      from -> send(from, {:transform_result, req_id, {:ok, signal}})
    end

    new_state = %{state | pending_requests: Map.delete(state.pending_requests, req_id)}
    {:ok, new_state}
  end

  defp handle_message(%{"type" => "subscribe", "topic" => topic}, state) do
    Phoenix.PubSub.subscribe(SpellRouter.PubSub, topic)
    
    new_state = %{state | subscriptions: [topic | state.subscriptions]}
    reply = Jason.encode!(%{type: "subscribed", topic: topic})
    
    {:push, {:text, reply}, new_state}
  end

  defp handle_message(%{"type" => "run_pipeline", "request_id" => req_id, "steps" => steps}, state) do
    # Parse and run pipeline
    parsed_steps = Enum.map(steps, &parse_step/1)
    pipeline = SpellRouter.Pipeline.new(parsed_steps)
    
    result = case SpellRouter.Pipeline.run(pipeline) do
      {:ok, completed} ->
        %{
          type: "pipeline_result",
          request_id: req_id,
          status: "completed",
          signal: Signal.to_json(completed.signal)
        }
      {:error, failed} ->
        %{
          type: "pipeline_result",
          request_id: req_id,
          status: "failed",
          error: inspect(failed.error)
        }
    end

    {:push, {:text, Jason.encode!(result)}, state}
  end

  defp handle_message(%{"type" => "ping"}, state) do
    reply = Jason.encode!(%{type: "pong", timestamp: System.system_time(:millisecond)})
    {:push, {:text, reply}, state}
  end

  defp handle_message(_unknown, state) do
    reply = Jason.encode!(%{type: "error", error: "unknown_message_type"})
    {:push, {:text, reply}, state}
  end

  # Step parsing (simplified)
  defp parse_step(%{"type" => "source", "name" => name} = s) do
    pattern = Map.get(s, "pattern", %{})
    {:builtin, :source, %{name: name, pattern: pattern}}
  end
  defp parse_step(%{"type" => "bash", "script" => script}), do: {:bash, script}
  defp parse_step(%{"type" => "remote", "agent" => agent}), do: {:remote, agent}
  defp parse_step(%{"type" => "commit"}), do: {:builtin, :commit}
  defp parse_step(%{"type" => "emit"}), do: {:builtin, :emit}
  defp parse_step(other), do: {:unknown, other}
end
