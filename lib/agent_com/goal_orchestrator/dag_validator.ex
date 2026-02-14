defmodule AgentCom.GoalOrchestrator.DagValidator do
  @moduledoc """
  DAG cycle detection, index validation, and topological ordering.

  Validates that a list of decomposed tasks with 1-based `depends_on` indices
  forms a valid directed acyclic graph. Uses Kahn's algorithm for topological sort.
  """

  @doc """
  Validates a task list for structural correctness.

  Each task must have a `:depends_on` field containing a list of 1-based indices.
  Validation checks:
  - Task list is non-empty
  - All dependency indices are in range [1, N]
  - No task depends on itself or a later-indexed task (forward references only)
  - No cycles (verified via Kahn's algorithm)

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate([map()]) :: :ok | {:error, term()}
  def validate([]), do: {:error, :empty_tasks}

  def validate(tasks) when is_list(tasks) do
    n = length(tasks)

    with :ok <- validate_indices(tasks, n),
         :ok <- validate_forward_only(tasks),
         :ok <- validate_acyclic(tasks) do
      :ok
    end
  end

  @doc """
  Returns a valid topological execution order for the task list.

  Returns `{:ok, [integer()]}` -- a list of 1-based indices where
  independent tasks appear before dependent ones.

  Returns `{:error, :cycle_detected}` if the graph contains cycles,
  or `{:error, :empty_tasks}` if the list is empty.
  """
  @spec topological_order([map()]) :: {:ok, [integer()]} | {:error, term()}
  def topological_order([]), do: {:error, :empty_tasks}

  def topological_order(tasks) when is_list(tasks) do
    kahns_sort(tasks)
  end

  @doc """
  Replaces 1-based index references in `:depends_on` with actual task IDs.

  Takes an index-to-ID mapping (list of `{1_based_index, task_id}` tuples)
  and the original task list. Returns the task list with `:depends_on`
  containing task IDs instead of indices.
  """
  @spec resolve_indices_to_ids([{pos_integer(), term()}], [map()]) :: [map()]
  def resolve_indices_to_ids(index_id_pairs, tasks) do
    id_map = Map.new(index_id_pairs)

    Enum.map(tasks, fn task ->
      resolved_deps =
        task
        |> Map.get(:depends_on, [])
        |> Enum.map(fn dep_idx -> Map.fetch!(id_map, dep_idx) end)

      Map.put(task, :depends_on, resolved_deps)
    end)
  end

  # --- Private ---

  defp validate_indices(tasks, n) do
    invalid =
      tasks
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {task, task_idx} ->
        task
        |> Map.get(:depends_on, [])
        |> Enum.filter(fn dep -> dep < 1 or dep > n end)
        |> Enum.map(fn bad_dep -> {task_idx, bad_dep} end)
      end)

    case invalid do
      [] -> :ok
      pairs -> {:error, {:invalid_indices, pairs}}
    end
  end

  defp validate_forward_only(tasks) do
    invalid =
      tasks
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {task, task_idx} ->
        task
        |> Map.get(:depends_on, [])
        |> Enum.filter(fn dep -> dep >= task_idx end)
        |> Enum.map(fn bad_dep -> {task_idx, bad_dep} end)
      end)

    case invalid do
      [] -> :ok
      pairs -> {:error, {:invalid_indices, pairs}}
    end
  end

  defp validate_acyclic(tasks) do
    case kahns_sort(tasks) do
      {:ok, _order} -> :ok
      {:error, _} = err -> err
    end
  end

  defp kahns_sort(tasks) do
    n = length(tasks)

    # Build adjacency list and in-degree count (1-based indexing)
    {adj, in_degree} =
      tasks
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, %{}}, fn {task, idx}, {adj_acc, deg_acc} ->
        deps = Map.get(task, :depends_on, [])
        deg_acc = Map.put(deg_acc, idx, length(deps))
        adj_acc = Map.put_new(adj_acc, idx, [])

        adj_acc =
          Enum.reduce(deps, adj_acc, fn dep, acc ->
            Map.update(acc, dep, [idx], &[idx | &1])
          end)

        {adj_acc, deg_acc}
      end)

    # Initialize queue with nodes having in-degree 0
    queue =
      1..n
      |> Enum.filter(fn idx -> Map.get(in_degree, idx, 0) == 0 end)

    process_kahn(queue, adj, in_degree, [], n)
  end

  defp process_kahn([], _adj, _in_degree, sorted, n) do
    if length(sorted) == n do
      {:ok, Enum.reverse(sorted)}
    else
      {:error, :cycle_detected}
    end
  end

  defp process_kahn([node | rest], adj, in_degree, sorted, n) do
    neighbors = Map.get(adj, node, [])

    {updated_queue, updated_in_degree} =
      Enum.reduce(neighbors, {rest, in_degree}, fn neighbor, {q, deg} ->
        new_deg = Map.get(deg, neighbor, 0) - 1
        deg = Map.put(deg, neighbor, new_deg)

        if new_deg == 0 do
          {q ++ [neighbor], deg}
        else
          {q, deg}
        end
      end)

    process_kahn(updated_queue, adj, updated_in_degree, [node | sorted], n)
  end
end
