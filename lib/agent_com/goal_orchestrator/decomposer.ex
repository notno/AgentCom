defmodule AgentCom.GoalOrchestrator.Decomposer do
  @moduledoc """
  Goal decomposition pipeline: context building, LLM call, validation, task submission.

  Orchestrates the full decomposition of a goal into executable tasks:

  1. Resolve repo path from RepoRegistry or fallback to cwd
  2. Gather file tree from the resolved path
  3. Build decomposition context with files and constraints
  4. Call ClaudeClient.decompose_goal/2 (with one retry on transient errors)
  5. Validate task count (2-10 expected, <2 treated as atomic)
  6. Validate DAG structure (re-prompt once on failure)
  7. Validate file references (re-prompt once, then strip invalid refs)
  8. Submit tasks in topological order to TaskQueue

  This is a library module (no GenServer). All state flows through function args.
  """

  require Logger

  alias AgentCom.GoalOrchestrator.{DagValidator, FileTree}

  @priority_int_to_string %{0 => "urgent", 1 => "high", 2 => "normal", 3 => "low"}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Decompose a goal into executable tasks and submit them to TaskQueue.

  Takes a goal map (from GoalBacklog), returns `{:ok, submitted_task_ids}`
  or `{:error, reason}`.
  """
  @spec decompose(map()) :: {:ok, [String.t()]} | {:error, term()}
  def decompose(goal) when is_map(goal) do
    with {:ok, repo_path} <- resolve_repo_path(goal),
         {:ok, file_tree} <- gather_file_tree(repo_path),
         context <- build_context(goal, file_tree),
         {:ok, tasks} <- call_claude_with_retry(goal, context),
         tasks <- validate_task_count(tasks, goal),
         {:ok, tasks} <- validate_dag_with_retry(tasks, goal, context),
         tasks <- validate_file_refs_with_retry(tasks, file_tree, goal, context),
         {:ok, task_ids} <- submit_tasks_in_order(tasks, goal) do
      {:ok, task_ids}
    end
  end

  # ---------------------------------------------------------------------------
  # Public helpers (testable in isolation)
  # ---------------------------------------------------------------------------

  @doc """
  Build decomposition context map from a goal and file tree.

  Returns a map with `:repo`, `:files`, and `:constraints` keys.
  """
  @spec build_context(map(), [String.t()]) :: map()
  def build_context(goal, file_tree) when is_map(goal) and is_list(file_tree) do
    %{
      repo: Map.get(goal, :repo),
      files: file_tree,
      constraints:
        "These are the ONLY files that exist. Do NOT reference files not in this list. " <>
          "Each task should be completable in 15-30 minutes. Return 3-8 tasks. " <>
          "Use depends-on indices (1-based) to mark sequential dependencies. " <>
          "Tasks with no dependencies can execute in parallel. " <>
          "The dependency graph must be a DAG -- no cycles."
    }
  end

  @doc """
  Validate task count and handle boundary cases.

  - 0 tasks: wrap goal description as a single task
  - 1 task: wrap as single-element list (atomic goal)
  - 2-10: pass through
  - >10: log warning, pass through
  """
  @spec validate_task_count([map()], map()) :: [map()]
  def validate_task_count(tasks, goal) when is_list(tasks) do
    count = length(tasks)

    cond do
      count == 0 ->
        Logger.info("decomposition_atomic",
          goal_id: Map.get(goal, :id),
          reason: "zero tasks returned"
        )

        [
          %{
            title: "Complete goal",
            description: Map.get(goal, :description, ""),
            success_criteria: Map.get(goal, :success_criteria, ""),
            depends_on: []
          }
        ]

      count == 1 ->
        Logger.info("decomposition_atomic",
          goal_id: Map.get(goal, :id),
          reason: "single task returned"
        )

        tasks

      count > 10 ->
        Logger.warning("decomposition_too_many_tasks",
          goal_id: Map.get(goal, :id),
          task_count: count
        )

        tasks

      true ->
        tasks
    end
  end

  @doc """
  Build task submission parameters from a decomposed task, goal, and index-to-ID map.

  Returns a map suitable for `TaskQueue.submit/1`.
  """
  @spec build_submit_params(map(), map(), map()) :: map()
  def build_submit_params(task, goal, index_to_id_map) when is_map(task) and is_map(goal) do
    deps_indices = Map.get(task, :depends_on, [])

    resolved_deps =
      Enum.flat_map(deps_indices, fn idx ->
        case Map.get(index_to_id_map, idx) do
          nil -> []
          id -> [id]
        end
      end)

    description = Map.get(task, :description, "")

    %{
      description: description,
      goal_id: Map.get(goal, :id),
      depends_on: resolved_deps,
      repo: Map.get(goal, :repo),
      file_hints: FileTree.extract_file_references(description),
      success_criteria: parse_success_criteria(Map.get(task, :success_criteria, "")),
      priority: priority_to_string(Map.get(goal, :priority, 2))
    }
  end

  @doc """
  Convert a priority integer to its string representation.

  Maps: 0 to urgent, 1 to high, 2 to normal, 3 to low.
  Defaults to normal for unknown values.
  """
  @spec priority_to_string(integer()) :: String.t()
  def priority_to_string(priority) when is_integer(priority) do
    Map.get(@priority_int_to_string, priority, "normal")
  end

  def priority_to_string(_), do: "normal"

  # ---------------------------------------------------------------------------
  # Private pipeline steps
  # ---------------------------------------------------------------------------

  defp resolve_repo_path(goal) do
    repo_url = Map.get(goal, :repo)

    resolved =
      if repo_url do
        try do
          repos = AgentCom.RepoRegistry.list_repos()

          matching =
            Enum.find(repos, fn r ->
              Map.get(r, :url) == repo_url
            end)

          case matching do
            nil -> File.cwd!()
            repo -> Map.get(repo, :local_path, File.cwd!())
          end
        rescue
          _ -> File.cwd!()
        end
      else
        File.cwd!()
      end

    {:ok, resolved}
  end

  defp gather_file_tree(repo_path) do
    case FileTree.gather(repo_path) do
      {:ok, files} ->
        {:ok, files}

      {:error, reason} ->
        Logger.error("file_tree_gather_failed", reason: inspect(reason))
        {:error, {:file_tree_error, reason}}
    end
  end

  defp call_claude_with_retry(goal, context) do
    case AgentCom.ClaudeClient.decompose_goal(goal, context) do
      {:ok, tasks} ->
        {:ok, tasks}

      {:error, :budget_exhausted} ->
        {:error, :budget_exhausted}

      {:error, _reason} ->
        # Retry once on transient errors
        case AgentCom.ClaudeClient.decompose_goal(goal, context) do
          {:ok, tasks} -> {:ok, tasks}
          {:error, reason} -> {:error, {:decomposition_failed, reason}}
        end
    end
  end

  defp validate_dag_with_retry(tasks, goal, context) do
    case DagValidator.validate(tasks) do
      :ok ->
        {:ok, tasks}

      {:error, reason} ->
        Logger.warning("dag_validation_failed",
          goal_id: Map.get(goal, :id),
          reason: inspect(reason)
        )

        # Re-prompt once with feedback
        feedback_context =
          Map.put(
            context,
            :constraints,
            Map.get(context, :constraints, "") <>
              " The dependency graph is invalid: #{inspect(reason)}. " <>
              "Please fix the depends-on indices."
          )

        case AgentCom.ClaudeClient.decompose_goal(goal, feedback_context) do
          {:ok, new_tasks} ->
            case DagValidator.validate(new_tasks) do
              :ok -> {:ok, new_tasks}
              {:error, reason2} -> {:error, {:dag_invalid, reason2}}
            end

          {:error, reason2} ->
            {:error, {:dag_invalid, reason2}}
        end
    end
  end

  defp validate_file_refs_with_retry(tasks, file_tree, goal, context) do
    {_valid, invalid} = FileTree.validate_references(tasks, file_tree)

    if invalid == [] do
      tasks
    else
      missing_files =
        invalid
        |> Enum.flat_map(fn {_task, files} -> files end)
        |> Enum.uniq()

      Logger.warning("file_reference_validation_failed",
        goal_id: Map.get(goal, :id),
        missing_files: missing_files
      )

      # Re-prompt once with feedback
      feedback_context =
        Map.put(
          context,
          :constraints,
          Map.get(context, :constraints, "") <>
            " The following files do not exist: #{Enum.join(missing_files, ", ")}. " <>
            "Please revise task descriptions to use only files from the provided file tree."
        )

      case AgentCom.ClaudeClient.decompose_goal(goal, feedback_context) do
        {:ok, new_tasks} ->
          {_valid2, invalid2} = FileTree.validate_references(new_tasks, file_tree)

          if invalid2 == [] do
            new_tasks
          else
            # Strip invalid file references and proceed
            Logger.warning("file_reference_still_invalid_stripping",
              goal_id: Map.get(goal, :id)
            )

            strip_invalid_file_refs(new_tasks, file_tree)
          end

        {:error, _reason} ->
          # Fall back to stripping invalid refs from original tasks
          strip_invalid_file_refs(tasks, file_tree)
      end
    end
  end

  defp strip_invalid_file_refs(tasks, file_tree) do
    file_set = MapSet.new(file_tree)

    Enum.map(tasks, fn task ->
      desc = Map.get(task, :description, "")
      refs = FileTree.extract_file_references(desc)
      invalid_refs = Enum.reject(refs, &MapSet.member?(file_set, &1))

      cleaned_desc =
        Enum.reduce(invalid_refs, desc, fn ref, acc ->
          String.replace(acc, ref, "[removed-file-ref]")
        end)

      Map.put(task, :description, cleaned_desc)
    end)
  end

  defp submit_tasks_in_order(tasks, goal) do
    case DagValidator.topological_order(tasks) do
      {:ok, order} ->
        {task_ids, _index_map} =
          Enum.reduce(order, {[], %{}}, fn idx, {ids, index_map} ->
            task = Enum.at(tasks, idx - 1)
            params = build_submit_params(task, goal, index_map)

            case AgentCom.TaskQueue.submit(params) do
              {:ok, submitted_task} ->
                new_map = Map.put(index_map, idx, submitted_task.id)
                {[submitted_task.id | ids], new_map}

              {:error, reason} ->
                Logger.error("task_submit_failed",
                  goal_id: Map.get(goal, :id),
                  task_index: idx,
                  reason: inspect(reason)
                )

                {ids, index_map}
            end
          end)

        {:ok, Enum.reverse(task_ids)}

      {:error, :cycle} ->
        {:error, {:dag_invalid, :cycle_detected}}
    end
  end

  defp parse_success_criteria(criteria) when is_binary(criteria) do
    criteria
    |> String.split(~r/[;\n]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_success_criteria(criteria) when is_list(criteria), do: criteria
  defp parse_success_criteria(_), do: []
end
