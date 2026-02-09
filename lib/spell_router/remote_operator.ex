defmodule SpellRouter.RemoteOperator do
  @moduledoc """
  Call a remote operator agent via WebSocket.
  
  Remote operators register themselves with an agent_id.
  When a pipeline includes a {:remote, agent_id} step,
  this module routes the signal to that agent and waits for the result.
  """

  alias SpellRouter.Signal

  @timeout 30_000

  @doc """
  Call a remote operator and wait for the result.
  
  Returns {:ok, signal} or {:error, reason}
  """
  def call(agent_id, %Signal{} = signal, opts \\ []) do
    timeout = opts[:timeout] || @timeout

    case lookup_agent(agent_id) do
      {:ok, %{pid: pid}} ->
        request_id = generate_request_id()
        
        # Send transform request to the agent's socket process
        send(pid, {:transform_request, request_id, signal})

        # Wait for response
        receive do
          {:transform_result, ^request_id, result} ->
            result
        after
          timeout ->
            {:error, {:timeout, agent_id}}
        end

      {:error, :not_found} ->
        {:error, {:agent_not_found, agent_id}}
    end
  end

  @doc "List all registered operators"
  def list_agents do
    Registry.select(SpellRouter.OperatorRegistry, [{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {id, meta} -> Map.put(meta, :agent_id, id) end)
  end

  @doc "Check if an agent is online"
  def online?(agent_id) do
    case lookup_agent(agent_id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp lookup_agent(agent_id) do
    case Registry.lookup(SpellRouter.OperatorRegistry, agent_id) do
      [{_pid, meta}] -> {:ok, meta}
      [] -> {:error, :not_found}
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
