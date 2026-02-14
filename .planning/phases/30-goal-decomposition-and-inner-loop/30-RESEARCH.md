# Phase 30: Goal Decomposition and Inner Loop - Research

**Researched:** 2026-02-13
**Domain:** LLM-driven goal decomposition, DAG task scheduling, event-driven completion monitoring
**Confidence:** HIGH

## Summary

Phase 30 implements the autonomous inner loop that transforms high-level goals into executable task graphs and drives them to verified completion. This is the orchestration layer connecting GoalBacklog (Phase 27), ClaudeClient (Phase 26), TaskQueue (Phase 2), Pipeline Dependencies (Phase 28), and HubFSM (Phase 29).

The codebase already has all the building blocks in place: `ClaudeClient.decompose_goal/2` and `ClaudeClient.verify_completion/2` provide the LLM operations; `GoalBacklog.dequeue/0` pops goals and transitions them through the lifecycle; `TaskQueue.submit/1` accepts tasks with `goal_id` and `depends_on` fields; the Scheduler (Phase 28) already filters out tasks with unsatisfied dependencies; and PubSub broadcasts on "tasks" and "goals" topics provide the event fabric for monitoring.

The primary implementation challenge is building the **GoalOrchestrator** -- a new module (or set of modules) that sits between HubFSM and the existing infrastructure, handling the decompose-submit-monitor-verify loop for each goal. The current HubFSM tick handler in `:executing` state does nothing beyond checking predicates. Phase 30 fills that gap: on each tick (or triggered by PubSub events), the orchestrator checks for dequeued goals needing decomposition, monitors in-flight goals for task completion, and triggers verification when all child tasks complete.

**Primary recommendation:** Implement a `GoalOrchestrator` module (called by HubFSM during the `:executing` tick) that manages per-goal state machines. Use a `FileTree` module to gather and cache repo file listings for prompt grounding. Extend `ClaudeClient.Prompt.build(:decompose, ...)` to include file tree context. Add a `GoalOrchestrator.Monitor` that subscribes to PubSub "tasks" and aggregates completion by `goal_id`.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Hub calls ClaudeClient (Phase 26) which spawns `claude -p`
- Prompt includes: goal description, success criteria, file tree listing, codebase context
- Output format at Claude's discretion during planning (JSON, XML, or structured text)
- Post-decomposition validation: check that referenced files/modules actually exist
- Each task should be completable in one agent context window (15-30 min of work)
- Typical decomposition: 3-8 tasks per goal
- If LLM returns fewer than 2 tasks, the goal might be atomic -- submit as single task
- If LLM returns more than 10 tasks, consider it a smell -- may need goal refinement
- Decomposition produces parallel + sequential markers
- Independent tasks get no depends_on (can run simultaneously via Phase 28)
- Sequential tasks carry depends_on references to their prerequisites
- Graph is a DAG -- no cycles (decomposition prompt should enforce this)
- Before calling Claude, gather: `ls -R lib/` + `ls -R sidecar/` output
- Include in prompt: "These are the ONLY files that exist. Do NOT reference files not in this list."
- Post-decomposition: validate every file path mentioned in task descriptions exists
- If validation fails, re-prompt with specific "file X does not exist" feedback
- Goal lifecycle: submitted -> decomposing -> executing -> verifying -> complete/failed
- After decomposition: submit all tasks to TaskQueue with goal_id and depends_on
- Monitor: subscribe to PubSub task completion events, aggregate by goal_id
- When all tasks complete: run goal-level verification
- If verification fails: redecompose with gap context (max 2 retries)
- Call ClaudeClient with: original goal + success criteria + task results
- Claude judges: "Are all success criteria met based on these task outcomes?"
- If gaps identified: create follow-up tasks to address gaps (not full redecomposition)
- Max 2 verification-retry cycles per goal, then mark as needs_human_review

### Claude's Discretion
- Decomposition prompt template design
- Output format (JSON/XML/structured text)
- Verification prompt design
- How to handle partial decomposition failures
- Task description detail level

### Deferred Ideas (OUT OF SCOPE)
None specified.
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GenServer (OTP) | stdlib | GoalOrchestrator process | Matches all existing AgentCom GenServers |
| Phoenix.PubSub | existing | Task/Goal event monitoring | Already used by Scheduler, HubFSM, GoalBacklog |
| System.cmd/3 | stdlib | File tree gathering via system commands | Same pattern as ClaudeClient.Cli |
| AgentCom.ClaudeClient | Phase 26 | Goal decomposition and verification LLM calls | Already has `decompose_goal/2` and `verify_completion/2` |
| AgentCom.GoalBacklog | Phase 27 | Goal lifecycle management | Already has full state machine with transitions |
| AgentCom.TaskQueue | Phase 2/28 | Task submission with `goal_id` and `depends_on` | Already supports dependency fields |
| AgentCom.HubFSM | Phase 29 | Drives executing state tick that triggers orchestration | Already ticks every 1s in `:executing` |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| AgentCom.CostLedger | Phase 25 | Budget check before LLM calls | Already integrated into ClaudeClient |
| :telemetry | existing | Observable decomposition/verification events | Every orchestration step |
| Jason | ~> 1.4 | JSON parsing of LLM responses | If output format is JSON |
| File | stdlib | File existence validation for grounding | Post-decomposition path validation |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| GoalOrchestrator GenServer | Inline logic in HubFSM tick | HubFSM would become bloated; separate module is cleaner and testable |
| System.cmd for file tree | File.ls_r! or Path.wildcard | System.cmd gives exact same output agents see; Path.wildcard is Elixir-native but produces different format |
| PubSub monitoring | Polling TaskQueue.tasks_for_goal/1 | PubSub is event-driven and already in use; polling adds latency and load |

**Installation:** No new deps needed. All libraries already in mix.exs.

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  goal_orchestrator.ex            # GenServer: per-goal state tracking, PubSub subscription
  goal_orchestrator/
    decomposer.ex                 # Pure function: build decomposition context, validate results
    file_tree.ex                  # File tree gathering and caching
    verifier.ex                   # Goal-level verification logic
    dag_validator.ex              # DAG cycle detection and dependency index resolution
```

### Pattern 1: GoalOrchestrator as Event-Driven GenServer
**What:** A singleton GenServer that subscribes to PubSub "tasks" and "goals" topics, maintaining an in-memory map of `goal_id => goal_state` for all active (decomposing/executing/verifying) goals.
**When to use:** Always -- this is the primary orchestration mechanism.
**How it integrates:** HubFSM calls `GoalOrchestrator.tick/0` on each executing tick. The orchestrator checks for goals needing work (decomposition, verification) and processes one per tick to avoid blocking.

```elixir
defmodule AgentCom.GoalOrchestrator do
  use GenServer
  require Logger

  defstruct active_goals: %{}, verification_retries: %{}

  # Client API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Called by HubFSM on each :executing tick."
  def tick do
    GenServer.cast(__MODULE__, :tick)
  end

  @doc "Check if any goals are actively being orchestrated."
  def active_goal_count do
    GenServer.call(__MODULE__, :active_goal_count)
  end

  # Server callbacks
  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast(:tick, state) do
    state = maybe_dequeue_goal(state)
    state = maybe_verify_completed_goals(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_event, %{event: :task_completed, task: task}}, state) do
    goal_id = Map.get(task, :goal_id)
    if goal_id, do: {:noreply, check_goal_progress(state, goal_id)},
    else: {:noreply, state}
  end

  def handle_info({:task_event, %{event: :task_dead_letter, task: task}}, state) do
    goal_id = Map.get(task, :goal_id)
    if goal_id, do: {:noreply, handle_task_failure(state, goal_id, task)},
    else: {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

### Pattern 2: Decomposition with File-Tree Grounding
**What:** Before calling ClaudeClient for decomposition, gather the actual file tree from the goal's repo directory and include it in the prompt context. After decomposition, validate all referenced file paths exist.
**When to use:** Every decomposition call.

```elixir
defmodule AgentCom.GoalOrchestrator.FileTree do
  @doc "Gather file tree listing for a repository path."
  def gather(repo_path) when is_binary(repo_path) do
    case System.cmd("find", [repo_path, "-type", "f", "-not", "-path", "*/.*"],
           stderr_to_stdout: true) do
      {output, 0} ->
        files = output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        {:ok, files}

      {error, _code} ->
        {:error, {:file_tree_error, error}}
    end
  end

  @doc "Validate that all file paths in task descriptions exist in the file tree."
  def validate_references(tasks, file_tree) do
    file_set = MapSet.new(file_tree)

    Enum.reduce(tasks, {[], []}, fn task, {valid, invalid} ->
      referenced = extract_file_references(task.description)
      missing = Enum.reject(referenced, &MapSet.member?(file_set, &1))

      if missing == [] do
        {[task | valid], invalid}
      else
        {valid, [{task, missing} | invalid]}
      end
    end)
  end

  defp extract_file_references(description) do
    # Match common file path patterns: lib/..., test/..., sidecar/...
    Regex.scan(~r"(?:lib|test|sidecar|config)/[\w/.-]+\.(?:ex|exs|js|ts|json|yml|yaml|md)", description)
    |> Enum.map(fn [match] -> match end)
    |> Enum.uniq()
  end
end
```

### Pattern 3: DAG Validation and Dependency Index Resolution
**What:** The LLM returns depends_on as 1-based indices (e.g., task 3 depends on task 1). These must be converted to actual task IDs after TaskQueue submission. Also validate the graph has no cycles.
**When to use:** Post-decomposition, before submitting tasks.

```elixir
defmodule AgentCom.GoalOrchestrator.DagValidator do
  @doc "Check that dependency indices form a valid DAG (no cycles, valid references)."
  def validate(tasks) when is_list(tasks) do
    count = length(tasks)

    # Check all dependency indices are valid (1-based, within range)
    invalid_refs =
      tasks
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {task, idx} ->
        Enum.filter(task.depends_on, fn dep ->
          dep < 1 or dep >= idx or dep > count  # Can't depend on self or later tasks
        end)
        |> Enum.map(&{idx, &1})
      end)

    if invalid_refs != [] do
      {:error, {:invalid_dependencies, invalid_refs}}
    else
      # Topological sort to detect cycles
      case topological_sort(tasks) do
        {:ok, _order} -> :ok
        {:error, :cycle} -> {:error, :cycle_detected}
      end
    end
  end

  @doc "Convert 1-based index dependencies to task IDs after submission."
  def resolve_dependencies(decomposed_tasks, submitted_task_ids) do
    # decomposed_tasks is the LLM output with index-based depends_on
    # submitted_task_ids is a list of IDs in the same order
    id_map = submitted_task_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {id, idx} -> {idx, id} end)
    |> Map.new()

    Enum.zip(decomposed_tasks, submitted_task_ids)
    |> Enum.map(fn {task, task_id} ->
      resolved_deps = Enum.map(task.depends_on, &Map.get(id_map, &1))
      |> Enum.reject(&is_nil/1)
      {task_id, resolved_deps}
    end)
  end

  defp topological_sort(tasks) do
    # Kahn's algorithm
    count = length(tasks)
    adj = for {task, idx} <- Enum.with_index(tasks, 1), into: %{} do
      {idx, task.depends_on}
    end

    in_degree = Enum.reduce(1..count, %{}, fn i, acc ->
      Map.put(acc, i, length(Map.get(adj, i, [])))
    end)

    # Invert: find who depends on whom
    reverse_adj = Enum.reduce(1..count, %{}, fn i, acc ->
      Enum.reduce(Map.get(adj, i, []), acc, fn dep, inner_acc ->
        Map.update(inner_acc, dep, [i], &[i | &1])
      end)
    end)

    queue = for {node, 0} <- in_degree, do: node
    do_topo_sort(queue, reverse_adj, in_degree, [], count)
  end

  defp do_topo_sort([], _rev, _deg, sorted, count) do
    if length(sorted) == count, do: {:ok, Enum.reverse(sorted)}, else: {:error, :cycle}
  end

  defp do_topo_sort([node | rest], rev, deg, sorted, count) do
    dependents = Map.get(rev, node, [])
    {new_queue, new_deg} = Enum.reduce(dependents, {rest, deg}, fn dep, {q, d} ->
      new_d = Map.update!(d, dep, &(&1 - 1))
      if new_d[dep] == 0, do: {q ++ [dep], new_d}, else: {q, new_d}
    end)
    do_topo_sort(new_queue, rev, new_deg, [node | sorted], count)
  end
end
```

### Pattern 4: Two-Phase Task Submission (Index Dependencies)
**What:** Because TaskQueue validates `depends_on` IDs exist at submit time (Phase 28 locked decision), tasks with dependencies cannot reference IDs that don't exist yet. Solution: submit independent tasks first, then submit dependent tasks with resolved IDs.
**When to use:** Every decomposition submission.

```elixir
# Submit tasks in topological order so depends_on IDs exist when needed
defp submit_tasks_in_order(decomposed_tasks, goal) do
  # First pass: submit all tasks with no dependencies
  # Second pass: submit tasks whose dependencies are now submitted
  # Continue until all tasks submitted

  id_map = %{}  # index -> task_id
  sorted = topological_order(decomposed_tasks)

  Enum.reduce(sorted, {:ok, id_map, []}, fn idx, {:ok, map, submitted} ->
    task = Enum.at(decomposed_tasks, idx - 1)
    resolved_deps = Enum.map(task.depends_on, &Map.get(map, &1)) |> Enum.reject(&is_nil/1)

    params = %{
      description: task.description,
      goal_id: goal.id,
      depends_on: resolved_deps,
      repo: goal.repo,
      file_hints: extract_file_hints(task),
      success_criteria: parse_criteria(task.success_criteria),
      priority: priority_for_goal(goal)
    }

    case AgentCom.TaskQueue.submit(params) do
      {:ok, submitted_task} ->
        {:ok, Map.put(map, idx, submitted_task.id), [submitted_task.id | submitted]}
      {:error, reason} ->
        {:error, reason}
    end
  end)
end
```

### Anti-Patterns to Avoid
- **Blocking HubFSM tick with LLM calls:** ClaudeClient calls can take 30-120 seconds. Never make them synchronously in the tick handler. Use `Task.async` or cast to GoalOrchestrator.
- **Polling for task completion:** Don't scan TaskQueue on every tick. Subscribe to PubSub "tasks" events and track completion incrementally.
- **Trusting LLM file references:** LLMs hallucinate file paths. Always validate against the actual file tree. The prompt grounding helps but is not sufficient -- post-validation is mandatory.
- **Full redecomposition on verification failure:** The user decision specifies creating follow-up tasks for gaps, not redecomposing from scratch. Redecomposition is only for catastrophic failures.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Task dependency scheduling | Custom dependency scheduler | Existing Scheduler (Phase 28) | Already filters on `depends_on` in `try_schedule_all` |
| Goal lifecycle state machine | Custom state tracking | GoalBacklog.transition/3 | Already has full lifecycle with validation |
| LLM invocation | Direct System.cmd calls | ClaudeClient.decompose_goal/2, verify_completion/2 | Budget checking, timeout handling, response parsing all built-in |
| Event broadcasting | Custom notification | Phoenix.PubSub | Already integrated into TaskQueue and GoalBacklog |
| Task submission with deps | Custom batch submit | TaskQueue.submit/1 with depends_on | Already validates dependency IDs exist at submit time |
| Progress tracking | Custom counter | TaskQueue.goal_progress/1 | Already aggregates completed/failed/pending by goal_id |

**Key insight:** Nearly all the infrastructure exists. Phase 30 is primarily orchestration glue connecting existing components, not building new infrastructure.

## Common Pitfalls

### Pitfall 1: Index-to-ID Dependency Resolution Ordering
**What goes wrong:** LLM returns `depends_on: [1]` meaning "depends on task 1 in this list." But TaskQueue.submit validates that dependency IDs exist at submit time. If you submit task 2 before task 1's ID is known, submission fails with `{:error, {:invalid_dependencies, [...]}}`.
**Why it happens:** The LLM uses 1-based indices; the system uses opaque task IDs. Translation must happen in the right order.
**How to avoid:** Submit tasks in topological order. Independent tasks (no depends_on) first. Then tasks depending only on already-submitted tasks. Build an index-to-ID map as you go.
**Warning signs:** `{:error, {:invalid_dependencies, _}}` from TaskQueue.submit.

### Pitfall 2: ClaudeClient Serialization Blocking Orchestration
**What goes wrong:** ClaudeClient is a serial GenServer -- one call at a time. If decomposition takes 60 seconds, no other LLM operation can proceed (verification, improvement identification). Multiple goals queue up behind each other.
**Why it happens:** Phase 26 locked decision: serial GenServer execution (no concurrency pool).
**How to avoid:** Accept this as a design constraint. Process goals one at a time. Use `Task.async` in the orchestrator so the tick doesn't block. Prioritize: always decompose before verify (decomposition unlocks new work).
**Warning signs:** Long delays between goal dequeue and first task appearing in TaskQueue.

### Pitfall 3: Infinite Verification-Retry Loop
**What goes wrong:** Verification fails, follow-up tasks are created, they complete, verification fails again with the same gaps, creating the same follow-up tasks forever.
**Why it happens:** Follow-up tasks address symptoms rather than root causes; or the success criteria are ambiguous and the LLM judges differently each time.
**How to avoid:** Track `verification_retries` per goal (max 2, per user decision). After 2 retries, mark as `:failed` with reason `:needs_human_review`. Store gap descriptions from each verification attempt for context.
**Warning signs:** Goals cycling between `:executing` and `:verifying` more than twice.

### Pitfall 4: File Tree Staleness During Long Decompositions
**What goes wrong:** File tree is gathered at decomposition start. By the time tasks execute (minutes to hours later), files may have been created/deleted by other agents working on other goals.
**Why it happens:** The file tree is a snapshot, not a live view.
**How to avoid:** File tree grounding is for the decomposition prompt only (preventing hallucinated files in task descriptions). Tasks themselves should handle missing files gracefully. Don't re-validate file tree at verification time.
**Warning signs:** Tasks failing because files referenced in their descriptions were created by earlier tasks in the same goal -- this is expected and fine.

### Pitfall 5: PubSub Event Flood During Batch Submission
**What goes wrong:** Submitting 8 tasks for a goal fires 8 `:task_submitted` PubSub events, each triggering the Scheduler. This creates redundant scheduling attempts.
**Why it happens:** TaskQueue broadcasts on every submit.
**How to avoid:** This is acceptable -- the Scheduler is idempotent and fast. The cost is 8 quick scheduling attempts instead of 1. If performance becomes an issue, batch submissions could be wrapped in a PubSub quiet period, but this is premature optimization.
**Warning signs:** High scheduler attempt telemetry counts during decomposition. Acceptable if latency is low.

### Pitfall 6: Goal Verification with Incomplete Task Results
**What goes wrong:** Calling verify_completion with task results that are nil or placeholder strings because tasks were marked complete without meaningful results.
**Why it happens:** Some agents may complete tasks without providing detailed result strings.
**How to avoid:** When gathering results for verification, include task descriptions plus any non-nil results. If all results are nil, use task descriptions and completion status as evidence. The verification prompt should be designed to work with minimal result data.
**Warning signs:** Verification LLM calls consistently returning "insufficient evidence" verdicts.

## Code Examples

### Example 1: HubFSM Integration Point
The key integration is making HubFSM's `:executing` tick drive the orchestrator:

```elixir
# In HubFSM.handle_info(:tick, state) when fsm_state is :executing
def handle_info(:tick, %{fsm_state: :executing} = state) do
  # Existing: gather system state and check predicates
  system_state = gather_system_state()

  case Predicates.evaluate(:executing, system_state) do
    {:transition, new_state, reason} ->
      updated = do_transition(state, new_state, reason)
      tick_ref = arm_tick()
      {:noreply, %{updated | tick_ref: tick_ref}}

    :stay ->
      # NEW: Drive goal orchestration
      AgentCom.GoalOrchestrator.tick()
      tick_ref = arm_tick()
      {:noreply, %{state | tick_ref: tick_ref}}
  end
end
```

### Example 2: Decomposition Context Building
```elixir
defp build_decomposition_context(goal) do
  # Gather file tree from the goal's repo
  repo_path = resolve_repo_path(goal.repo)
  {:ok, file_tree} = AgentCom.GoalOrchestrator.FileTree.gather(repo_path)

  %{
    repo: goal.repo,
    files: file_tree,
    constraints: """
    These are the ONLY files that exist in the repository.
    Do NOT reference files not in this list.
    Each task should be completable in 15-30 minutes of focused work.
    Return 3-8 tasks. Use depends-on indices to mark sequential dependencies.
    Tasks with no dependencies can execute in parallel.
    """
  }
end
```

### Example 3: Post-Decomposition Validation and Submission
```elixir
defp process_decomposition(goal, tasks) do
  cond do
    length(tasks) < 2 ->
      # Atomic goal -- submit as single task
      submit_single_task(goal, List.first(tasks) || %{description: goal.description})

    length(tasks) > 10 ->
      # Too many tasks -- likely needs goal refinement
      Logger.warning("decomposition_too_many_tasks",
        goal_id: goal.id, task_count: length(tasks))
      # Still submit but log the smell
      validate_and_submit(goal, tasks)

    true ->
      validate_and_submit(goal, tasks)
  end
end

defp validate_and_submit(goal, tasks) do
  # 1. Validate DAG structure
  case DagValidator.validate(tasks) do
    :ok -> :ok
    {:error, reason} ->
      Logger.error("dag_validation_failed", goal_id: goal.id, reason: inspect(reason))
      # Re-prompt with feedback
      return {:error, {:dag_invalid, reason}}
  end

  # 2. Validate file references
  repo_path = resolve_repo_path(goal.repo)
  {:ok, file_tree} = FileTree.gather(repo_path)
  {_valid, invalid} = FileTree.validate_references(tasks, file_tree)

  if invalid != [] do
    # Re-prompt with specific feedback
    missing_files = invalid |> Enum.flat_map(fn {_, files} -> files end) |> Enum.uniq()
    {:error, {:invalid_file_references, missing_files}}
  else
    # 3. Submit in topological order
    submit_tasks_in_order(tasks, goal)
  end
end
```

### Example 4: Task Completion Monitoring via PubSub
```elixir
# In GoalOrchestrator
def handle_info({:task_event, %{event: :task_completed, task: task}}, state) do
  goal_id = Map.get(task, :goal_id)

  if goal_id && Map.has_key?(state.active_goals, goal_id) do
    progress = AgentCom.TaskQueue.goal_progress(goal_id)

    if progress.pending == 0 and progress.failed == 0 do
      # All tasks complete -- trigger verification
      state = put_in(state.active_goals[goal_id].phase, :verifying)
      AgentCom.GoalBacklog.transition(goal_id, :verifying,
        reason: "all #{progress.completed} tasks completed")
      send(self(), {:verify_goal, goal_id})
    end

    {:noreply, state}
  else
    {:noreply, state}
  end
end
```

### Example 5: Goal Verification with Retry Logic
```elixir
defp verify_goal(goal_id, state) do
  {:ok, goal} = AgentCom.GoalBacklog.get(goal_id)
  tasks = AgentCom.TaskQueue.tasks_for_goal(goal_id)

  results = %{
    summary: Enum.map(tasks, fn t ->
      "Task: #{t.description}\nResult: #{t.result || "completed"}"
    end) |> Enum.join("\n\n"),
    files_modified: tasks |> Enum.flat_map(& &1.file_hints) |> Enum.uniq(),
    test_outcomes: ""
  }

  case AgentCom.ClaudeClient.verify_completion(goal, results) do
    {:ok, %{verdict: :pass}} ->
      AgentCom.GoalBacklog.transition(goal_id, :complete,
        reason: "verification passed")
      remove_from_active(state, goal_id)

    {:ok, %{verdict: :fail, gaps: gaps}} ->
      retries = Map.get(state.verification_retries, goal_id, 0)

      if retries >= 2 do
        AgentCom.GoalBacklog.transition(goal_id, :failed,
          reason: "max verification retries exceeded: #{inspect(gaps)}")
        remove_from_active(state, goal_id)
      else
        # Create follow-up tasks for gaps
        create_followup_tasks(goal, gaps)
        AgentCom.GoalBacklog.transition(goal_id, :executing,
          reason: "verification gaps: #{length(gaps)} issues")
        state
        |> put_in([:verification_retries, goal_id], retries + 1)
        |> put_in([:active_goals, goal_id, :phase], :executing)
      end

    {:error, reason} ->
      Logger.error("verification_error", goal_id: goal_id, reason: inspect(reason))
      state
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual task creation | LLM-driven decomposition | Phase 30 | Goals auto-decompose into executable tasks |
| Flat task list | DAG with depends_on | Phase 28 | Parallel execution of independent tasks |
| No completion check | LLM-verified success criteria | Phase 30 | Autonomous quality gate before marking complete |
| Single-shot execution | Inner loop with retries | Phase 30 | Self-healing: gaps detected and addressed automatically |

## Recommendations for Claude's Discretion Areas

### Decomposition Prompt Template Design
**Recommendation:** Use the existing XML-based prompt pattern from `ClaudeClient.Prompt.build(:decompose, ...)` but extend the context section to include the full file tree. The current prompt already instructs 3-8 tasks with depends_on indices. Enhance it with:
- Explicit elephant carpaccio instruction: "Each task should touch all necessary layers but do minimal work"
- Time budget: "Each task should be completable in 15-30 minutes"
- File tree grounding clause
- Confidence: HIGH (existing prompt pattern is proven)

### Output Format
**Recommendation:** Keep XML format. The existing `ClaudeClient.Response.parse_inner(:decompose, ...)` already parses `<tasks>` XML with `<task>` children containing `<title>`, `<description>`, `<success-criteria>`, and `<depends-on>`. No reason to change what works. Add `<file-hints>` as an optional child element for grounding validation.
- Confidence: HIGH (existing parser is proven)

### Verification Prompt Design
**Recommendation:** Keep the existing `ClaudeClient.Prompt.build(:verify, ...)` pattern. Enhance the results context to include per-task summaries with their descriptions and outcomes. The current `<verification>` response format with `<verdict>`, `<reasoning>`, and `<gaps>` is already well-suited. When creating follow-up tasks from gaps, use gap descriptions directly as task descriptions.
- Confidence: HIGH (existing pattern works)

### How to Handle Partial Decomposition Failures
**Recommendation:** If decomposition returns an error (timeout, parse error, empty response), retry once with the same prompt. If it fails again, mark the goal as `:failed` with the error reason. If decomposition succeeds but file validation fails, re-prompt once with specific feedback about which files don't exist. If it fails again, submit the tasks anyway but strip invalid file references from descriptions (better to have slightly imprecise tasks than no tasks).
- Confidence: MEDIUM (untested, but follows defensive patterns from other modules)

### Task Description Detail Level
**Recommendation:** Include in each task: what to do, which files to modify, what the expected outcome is, and how to verify success. The LLM prompt should instruct: "Each task description should be self-contained -- an agent reading only this task should know what to do without seeing the original goal." This prevents information loss during decomposition.
- Confidence: MEDIUM (depends on LLM response quality)

## Open Questions

1. **Repo Path Resolution**
   - What we know: Goals have a `repo` field (URL string like "https://github.com/user/repo"). File tree gathering needs a local filesystem path.
   - What's unclear: How does the hub resolve a repo URL to a local checkout path? RepoRegistry stores URLs but not local paths.
   - Recommendation: Add a `local_path` field to RepoRegistry entries, or use a convention like `~/repos/{repo_name}`. This may need a decision during planning.

2. **Windows File Tree Gathering**
   - What we know: The platform is Windows 11. The locked decision says `ls -R lib/` but `ls` is a Unix command. Git Bash provides `ls` but `find` may not behave identically.
   - What's unclear: Whether `System.cmd("ls", ["-R", "lib/"])` works on Windows with the user's shell setup.
   - Recommendation: Use `Path.wildcard("lib/**/*.ex")` or `File.ls!/1` recursively as a cross-platform alternative. This is more reliable than shelling out to `ls` on Windows.

3. **Concurrent Goal Orchestration**
   - What we know: HubFSM context mentions "Hub processes multiple independent goals simultaneously." ClaudeClient is serial (one call at a time).
   - What's unclear: How to handle multiple goals in `:executing` state when LLM calls are serialized. Goal A in decomposition blocks Goal B's verification.
   - Recommendation: The orchestrator should track multiple active goals but queue LLM operations. Process the highest-priority goal's LLM needs first. Multiple goals can have their tasks executing in parallel (that's handled by Scheduler), but decomposition/verification LLM calls are sequential.

## Sources

### Primary (HIGH confidence)
- Codebase inspection: `lib/agent_com/claude_client.ex` -- ClaudeClient GenServer with decompose_goal/2, verify_completion/2
- Codebase inspection: `lib/agent_com/claude_client/prompt.ex` -- Existing decomposition and verification prompt templates
- Codebase inspection: `lib/agent_com/claude_client/response.ex` -- XML response parser with regex extraction
- Codebase inspection: `lib/agent_com/goal_backlog.ex` -- Full lifecycle state machine with transitions
- Codebase inspection: `lib/agent_com/task_queue.ex` -- Task submission with goal_id, depends_on, goal_progress/1
- Codebase inspection: `lib/agent_com/hub_fsm.ex` -- Tick-based FSM with PubSub subscriptions
- Codebase inspection: `lib/agent_com/hub_fsm/predicates.ex` -- Pure transition predicates
- Codebase inspection: `lib/agent_com/scheduler.ex` -- Phase 28 dependency filtering in try_schedule_all
- Codebase inspection: `lib/agent_com/application.ex` -- Supervision tree ordering

### Secondary (MEDIUM confidence)
- Phase 26 Research: `26-RESEARCH.md` -- ClaudeClient design decisions, temp file strategy
- Phase 29 Research: `29-RESEARCH.md` -- HubFSM architecture, tick-based evaluation

### Tertiary (LOW confidence)
- None. All findings verified against actual codebase.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All components already exist in the codebase; Phase 30 is pure orchestration
- Architecture: HIGH - Patterns follow existing GenServer/PubSub conventions proven across 29 prior phases
- Pitfalls: HIGH - Identified from actual code constraints (serial ClaudeClient, submit-time dependency validation, PubSub event patterns)

**Research date:** 2026-02-13
**Valid until:** 2026-03-13 (stable -- internal architecture, no external dependency changes expected)
