defmodule AgentCom.TaskRouter do
  @moduledoc """
  Routes tasks to execution tiers based on complexity and endpoint availability.

  Pure-function routing decision engine (no GenServer state, no side effects).
  The Scheduler (Plan 02) calls `TaskRouter.route/3` and gets back a routing
  decision or fallback signal.

  ## Routing Flow

  1. Resolve tier from task complexity via `TierResolver.resolve/1`
  2. Find target for the resolved tier:
     - `:trivial` -> always succeeds with `:sidecar` target
     - `:standard` -> filter healthy endpoints with models, score and rank, pick best
     - `:complex` -> always succeeds with `:claude` target
  3. Build routing decision map with all required fields
  4. Return `{:ok, decision}` or `{:fallback, original_tier, reason}`

  ## Routing Decision Map

  Every routing decision includes:
  - `effective_tier` - the resolved tier
  - `target_type` - `:sidecar` | `:ollama` | `:claude`
  - `selected_endpoint` - the chosen endpoint ID or nil
  - `selected_model` - the model name or nil
  - `fallback_used` - whether fallback was applied
  - `fallback_from_tier` - original tier if fallback
  - `fallback_reason` - why fallback was needed
  - `candidate_count` - number of viable endpoints considered
  - `classification_reason` - human-readable routing explanation
  - `estimated_cost_tier` - `:free` | `:local` | `:api`
  - `decided_at` - millisecond timestamp
  """

  alias AgentCom.TaskRouter.TierResolver
  alias AgentCom.TaskRouter.LoadScorer

  @doc """
  Route a task to an execution target based on complexity and endpoint availability.

  Returns `{:ok, decision}` with a complete routing decision map, or
  `{:fallback, tier, reason}` when the preferred tier has no viable endpoints.

  ## Parameters

  - `task` - task map with `:complexity` field (from `AgentCom.Complexity.build/1`)
  - `endpoints` - list of endpoint maps from `LlmRegistry.list_endpoints/0`
  - `endpoint_resources` - map of endpoint_id => resource metrics
  """
  @spec route(map(), [map()], map()) :: {:ok, map()} | {:fallback, atom(), atom()}
  def route(task, endpoints, endpoint_resources) do
    tier = TierResolver.resolve(task)

    case find_target(tier, task, endpoints, endpoint_resources) do
      {:ok, target, candidate_count} ->
        decision = build_decision(task, tier, target, candidate_count)
        {:ok, decision}

      {:unavailable, reason} ->
        {:fallback, tier, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Target Finding
  # ---------------------------------------------------------------------------

  defp find_target(:trivial, _task, _endpoints, _resources) do
    {:ok, %{type: :sidecar, endpoint: nil, model: nil}, 0}
  end

  defp find_target(:standard, task, endpoints, resources) do
    candidates =
      endpoints
      |> Enum.filter(fn ep -> ep.status == :healthy and ep.models != [] end)

    case candidates do
      [] ->
        {:unavailable, :no_healthy_ollama_endpoints}

      _ ->
        scored = LoadScorer.score_and_rank(candidates, resources, task)
        {best_id, _score, _details} = hd(scored)
        best_endpoint = Enum.find(candidates, fn ep -> ep.id == best_id end)
        model = select_model(best_endpoint)
        {:ok, %{type: :ollama, endpoint: best_id, model: model}, length(candidates)}
    end
  end

  defp find_target(:complex, _task, _endpoints, _resources) do
    {:ok, %{type: :claude, endpoint: :claude_api, model: "claude"}, 0}
  end

  # ---------------------------------------------------------------------------
  # Private: Decision Building
  # ---------------------------------------------------------------------------

  defp build_decision(task, tier, target, candidate_count) do
    %{
      effective_tier: tier,
      target_type: target.type,
      selected_endpoint: target.endpoint,
      selected_model: target.model,
      fallback_used: false,
      fallback_from_tier: nil,
      fallback_reason: nil,
      candidate_count: candidate_count,
      classification_reason: build_classification_reason(task),
      estimated_cost_tier: cost_tier(target.type),
      decided_at: System.system_time(:millisecond)
    }
  end

  defp build_classification_reason(task) do
    case task do
      %{complexity: %{source: source, effective_tier: tier, inferred: %{confidence: conf} = inferred}} ->
        signals = Map.get(inferred, :signals, %{})
        wc = Map.get(signals, :word_count, "?")
        fc = Map.get(signals, :file_count, "?")
        "#{source}:#{tier} (confidence #{format_confidence(conf)}, word_count=#{wc}, files=#{fc})"

      %{complexity: %{source: source, effective_tier: tier}} ->
        "#{source}:#{tier}"

      %{complexity: nil} ->
        "none:standard (no complexity data)"

      _ ->
        "none:standard (no complexity data)"
    end
  end

  defp format_confidence(conf) when is_float(conf), do: :erlang.float_to_binary(conf, decimals: 2)
  defp format_confidence(conf), do: "#{conf}"

  defp cost_tier(:sidecar), do: :free
  defp cost_tier(:ollama), do: :local
  defp cost_tier(:claude), do: :api

  defp select_model(endpoint) do
    case endpoint.models do
      [first | _] -> first
      [] -> nil
    end
  end
end
