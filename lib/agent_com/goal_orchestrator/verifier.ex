defmodule AgentCom.GoalOrchestrator.Verifier do
  @moduledoc """
  Goal verification pipeline: result gathering, LLM call, gap-based follow-up task creation.

  Provides the verification side of the goal lifecycle:

  1. Gather task results for a goal from TaskQueue
  2. Call ClaudeClient.verify_completion/2 with formatted results
  3. Process the verdict: pass, fail with gaps, or needs_human_review after max retries

  Also handles follow-up task creation from verification gaps -- targeted
  gap-closing tasks, not full redecomposition.

  This is a library module (no GenServer). All state flows through function args.
  """

  require Logger

  @max_retries 2
  @priority_int_to_string %{0 => "urgent", 1 => "high", 2 => "normal", 3 => "low"}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Verify whether a goal has been completed based on its child task results.

  Takes a goal map and a retry count (integer). Returns:
  - `{:ok, :pass}` -- all success criteria met
  - `{:ok, :fail, gaps}` -- gaps identified, retry allowed
  - `{:ok, :needs_human_review}` -- max retries exceeded
  - `{:error, reason}` -- LLM call failed
  """
  @spec verify(map(), non_neg_integer()) ::
          {:ok, :pass}
          | {:ok, :fail, [map()]}
          | {:ok, :needs_human_review}
          | {:error, term()}
  def verify(goal, retry_count) when is_map(goal) and is_integer(retry_count) do
    goal_id = Map.get(goal, :id)
    tasks = AgentCom.TaskQueue.tasks_for_goal(goal_id)
    results = build_results_summary(tasks)

    case AgentCom.ClaudeClient.verify_completion(goal, results) do
      {:ok, %{verdict: :pass}} ->
        {:ok, :pass}

      {:ok, %{verdict: :fail, gaps: gaps}} ->
        if retry_count >= @max_retries do
          Logger.warning("verification_max_retries_exceeded",
            goal_id: goal_id,
            retry_count: retry_count,
            gap_count: length(gaps)
          )

          {:ok, :needs_human_review}
        else
          {:ok, :fail, gaps}
        end

      {:error, :budget_exhausted} ->
        {:error, :budget_exhausted}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("verification_failed",
          goal_id: goal_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Create follow-up tasks from verification gaps.

  Takes a goal map and a list of gap maps (from verification). Each gap
  should have `:description` and optionally `:severity` keys.

  Returns `{:ok, task_ids}` or `{:error, reason}`.
  """
  @spec create_followup_tasks(map(), [map()]) :: {:ok, [String.t()]} | {:error, term()}
  def create_followup_tasks(goal, gaps) when is_map(goal) and is_list(gaps) do
    goal_id = Map.get(goal, :id)
    goal_priority = Map.get(goal, :priority, 2)

    task_ids =
      Enum.reduce(gaps, [], fn gap, acc ->
        params = build_followup_params(gap, goal, goal_priority)

        case AgentCom.TaskQueue.submit(params) do
          {:ok, task} ->
            [task.id | acc]

          {:error, reason} ->
            Logger.error("followup_task_submit_failed",
              goal_id: goal_id,
              gap: inspect(gap),
              reason: inspect(reason)
            )

            acc
        end
      end)

    {:ok, Enum.reverse(task_ids)}
  end

  # ---------------------------------------------------------------------------
  # Public helpers (testable in isolation)
  # ---------------------------------------------------------------------------

  @doc """
  Build a results summary map from a list of task maps.

  Returns a map with:
  - `:summary` -- formatted string of task descriptions and results
  - `:files_modified` -- deduplicated list of file hints from all tasks
  - `:test_outcomes` -- empty string (reserved for future use)
  """
  @spec build_results_summary([map()]) :: map()
  def build_results_summary(tasks) when is_list(tasks) do
    summary =
      tasks
      |> Enum.map(fn task ->
        desc = Map.get(task, :description, "")
        status = Map.get(task, :status, :unknown)
        result = Map.get(task, :result) || "completed"

        "Task: #{desc}\nStatus: #{status}\nResult: #{result}"
      end)
      |> Enum.join("\n\n")

    files_modified =
      tasks
      |> Enum.flat_map(fn task -> Map.get(task, :file_hints, []) end)
      |> Enum.uniq()

    %{
      summary: summary,
      files_modified: files_modified,
      test_outcomes: ""
    }
  end

  @doc """
  Build follow-up task submission parameters from a gap and goal.

  Bumps priority by one level for critical-severity gaps.
  """
  @spec build_followup_params(map(), map(), integer()) :: map()
  def build_followup_params(gap, goal, goal_priority)
      when is_map(gap) and is_map(goal) and is_integer(goal_priority) do
    gap_desc = Map.get(gap, :description, "")
    severity = Map.get(gap, :severity, "minor")
    goal_desc = Map.get(goal, :description, "")

    priority =
      if severity == "critical" do
        bump_priority(goal_priority)
      else
        goal_priority
      end

    %{
      description: "Follow-up: #{gap_desc}\n\nOriginal goal: #{goal_desc}",
      goal_id: Map.get(goal, :id),
      depends_on: [],
      repo: Map.get(goal, :repo),
      priority: priority_to_string(priority),
      success_criteria: [gap_desc]
    }
  end

  @doc """
  Bump a priority integer one level higher (lower number = higher priority).

  0 (urgent) stays at 0. Otherwise decrements by 1.
  """
  @spec bump_priority(integer()) :: integer()
  def bump_priority(priority) when is_integer(priority) do
    max(0, priority - 1)
  end

  @doc false
  def priority_to_string(priority) when is_integer(priority) do
    Map.get(@priority_int_to_string, priority, "normal")
  end

  def priority_to_string(_), do: "normal"
end
