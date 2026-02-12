defmodule AgentCom.TaskRouter.LoadScorer do
  @moduledoc """
  Weighted endpoint scoring with load, capacity, VRAM, warm model, and repo affinity.

  Pure module that scores and ranks candidate endpoints for task assignment.
  All scoring is deterministic and side-effect-free.

  ## Scoring Formula

  ```
  final = base * load_factor * capacity_factor * vram_factor * warm_bonus * affinity_bonus
  ```

  - `load_factor` = 1.0 - (cpu_percent / 100.0), default cpu 50.0
  - `capacity_factor` = min(ram_total / reference_capacity, 1.5), reference 16GB
  - `vram_factor` = if vram data: 0.8 + 0.2 * vram_free_pct, else 0.9
  - `warm_bonus` = 1.15 if model loaded, else 1.0
  - `affinity_bonus` = 1.05 if same repo on similar load, else 1.0
  """

  @base_score 1.0
  @reference_capacity_bytes 16 * 1024 * 1024 * 1024
  @capacity_cap 1.5
  @default_cpu 50.0
  @default_vram_factor 0.9
  @warm_model_bonus 1.15
  @repo_affinity_bonus 1.05

  @doc """
  Score and rank candidate endpoints for a task.

  Returns a list of `{endpoint_id, score, details}` tuples sorted by score descending.
  Empty candidates returns empty list.

  ## Options

  - `:default_model` - the model name to check for warm model bonus (optional)
  """
  @spec score_and_rank([map()], map(), map(), keyword()) :: [{String.t(), float(), map()}]
  def score_and_rank(candidates, resources, task, opts \\ [])
  def score_and_rank([], _resources, _task, _opts), do: []

  def score_and_rank(candidates, resources, task, opts) do
    default_model = Keyword.get(opts, :default_model, nil)

    candidates
    |> Enum.map(fn endpoint ->
      res = Map.get(resources, endpoint.id, %{})
      {score, details} = compute_score(endpoint, res, task, default_model)
      {endpoint.id, score, details}
    end)
    |> Enum.sort_by(fn {_id, score, _details} -> score end, :desc)
  end

  # ---------------------------------------------------------------------------
  # Private: Score Computation
  # ---------------------------------------------------------------------------

  defp compute_score(endpoint, resources, task, default_model) do
    load_factor = compute_load_factor(resources)
    capacity_factor = compute_capacity_factor(resources)
    vram_factor = compute_vram_factor(resources)
    warm_bonus = compute_warm_bonus(endpoint, default_model)
    affinity_bonus = compute_affinity_bonus(resources, task)

    score = @base_score * load_factor * capacity_factor * vram_factor * warm_bonus * affinity_bonus

    details = %{
      load_factor: load_factor,
      capacity_factor: capacity_factor,
      vram_factor: vram_factor,
      warm_bonus: warm_bonus,
      affinity_bonus: affinity_bonus
    }

    {score, details}
  end

  defp compute_load_factor(resources) do
    cpu = Map.get(resources, :cpu_percent) || @default_cpu
    1.0 - cpu / 100.0
  end

  defp compute_capacity_factor(resources) do
    ram_total = Map.get(resources, :ram_total_bytes)

    case ram_total do
      nil -> 1.0
      0 -> 1.0
      bytes -> min(bytes / @reference_capacity_bytes, @capacity_cap)
    end
  end

  defp compute_vram_factor(resources) do
    vram_total = Map.get(resources, :vram_total_bytes)
    vram_used = Map.get(resources, :vram_used_bytes)

    case {vram_total, vram_used} do
      {nil, _} -> @default_vram_factor
      {_, nil} -> @default_vram_factor
      {0, _} -> @default_vram_factor
      {total, used} ->
        vram_free_pct = 1.0 - used / total
        0.8 + 0.2 * vram_free_pct
    end
  end

  defp compute_warm_bonus(endpoint, default_model) do
    models = Map.get(endpoint, :models, [])

    cond do
      is_nil(default_model) -> 1.0
      default_model in models -> @warm_model_bonus
      true -> 1.0
    end
  end

  defp compute_affinity_bonus(resources, task) do
    resource_repo = Map.get(resources, :repo)
    task_repo = Map.get(task, :repo)

    cond do
      is_nil(resource_repo) -> 1.0
      is_nil(task_repo) -> 1.0
      resource_repo == task_repo -> @repo_affinity_bonus
      true -> 1.0
    end
  end
end
