# Phase 28: Pipeline Dependencies - Research

**Researched:** 2026-02-13
**Domain:** Elixir GenServer state extension, DETS schema evolution, scheduler filtering
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Add `depends_on`: list of task IDs that must complete before this task can be scheduled
- Add `goal_id`: reference to parent goal (for goal-level progress tracking)
- Both fields optional -- existing tasks continue working unchanged (backward compatible)
- ~15-line addition to try_schedule_all after existing paused-repo filter
- For each candidate task, check if all depends_on tasks have status "completed"
- O(d) check per task where d is typically 0-3 dependencies
- No graph library needed -- each task knows its predecessors
- TaskQueue can aggregate completion status by goal_id
- Enables "3 of 7 tasks complete for Goal X" reporting
- GoalBacklog (Phase 27) subscribes to task completion events and updates goal progress

### Claude's Discretion
- Whether depends_on validation should check task existence at submission time
- How circular dependencies are detected (if at all -- decomposition should prevent them)
- Whether to add an API endpoint for querying tasks by goal_id

### Deferred Ideas (OUT OF SCOPE)
None specified.
</user_constraints>

## Summary

Phase 28 adds two optional fields (`depends_on` and `goal_id`) to the task map in TaskQueue and a dependency filter in the Scheduler's `try_schedule_all/2` function. This is a minimal, surgical extension of existing infrastructure -- not a rewrite.

The existing task map in TaskQueue is a plain Elixir map (not a struct), built in the `handle_call({:submit, params}, ...)` handler at line 237 of `task_queue.ex`. Adding new keys requires: (1) reading them from `params` during submit, (2) storing them on the map, (3) using `Map.get/3` with defaults when reading (for backward compatibility with tasks already persisted in DETS that lack these keys). This is the exact same pattern used for enrichment fields added in Phase 17 (repo, branch, file_hints, etc.).

The Scheduler filter goes in `try_schedule_all/2` in `scheduler.ex`, after the existing Phase 23 paused-repo filter (line 280-300). The filter iterates `schedulable_tasks` and rejects any task whose `depends_on` list contains task IDs that are not yet `:completed`. Each dependency check requires a `TaskQueue.get/1` call (or a batch lookup), which is a DETS read -- fast for 0-3 dependencies.

**Primary recommendation:** Follow the exact patterns established by Phase 17 (enrichment fields) and Phase 23 (scheduler filtering). This is a ~50-line change across 3-4 files plus tests.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir GenServer | OTP 27+ | TaskQueue and Scheduler are GenServers | Already in use |
| DETS | OTP built-in | Task persistence | Already in use, tasks survive restarts |
| Phoenix.PubSub | 2.1+ | Event broadcasting (task_completed triggers dependency re-evaluation) | Already in use |

### Supporting
No new libraries needed. This phase extends existing modules only.

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Per-task `depends_on` list | Full DAG library (libgraph) | Unnecessary complexity for 0-3 deps per task; DAG validation deferred to decomposition layer |
| DETS lookup per dependency | ETS cache of completed task IDs | Premature optimization; DETS lookup is ~microseconds for key lookup |

## Architecture Patterns

### Pattern 1: Optional Field Extension (Phase 17 Established Pattern)

**What:** Add new optional fields to the task map in `submit/1`, defaulting to `nil` or `[]` so existing tasks without these fields continue working.

**When to use:** Every time the task schema needs extension.

**Example:**
```elixir
# In TaskQueue.handle_call({:submit, params}, ...):
task = %{
  # ... existing fields ...
  depends_on: Map.get(params, :depends_on, Map.get(params, "depends_on", [])),
  goal_id: Map.get(params, :goal_id, Map.get(params, "goal_id", nil))
}
```

**Backward compatibility for DETS-persisted tasks:**
```elixir
# When reading depends_on from a task that may predate Phase 28:
deps = Map.get(task, :depends_on, [])
goal = Map.get(task, :goal_id, nil)
```

This pattern is used throughout the codebase (see lines 555-566 of scheduler.ex where `Map.get(assigned_task, :repo)` etc. are used).

### Pattern 2: Scheduler Filter Chain (Phase 23 Established Pattern)

**What:** After fetching `queued_tasks` and filtering by repo status, apply an additional filter for dependency satisfaction.

**Where:** In `try_schedule_all/2` in `scheduler.ex`, after the `schedulable_tasks` variable is computed (line 280-300), add a dependency filter.

**Example:**
```elixir
# After Phase 23 repo filter produces schedulable_tasks:
schedulable_tasks =
  Enum.filter(schedulable_tasks, fn task ->
    deps = Map.get(task, :depends_on, [])
    deps == [] or Enum.all?(deps, fn dep_id ->
      case AgentCom.TaskQueue.get(dep_id) do
        {:ok, %{status: :completed}} -> true
        _ -> false
      end
    end)
  end)
```

### Pattern 3: Goal Progress Aggregation

**What:** TaskQueue provides a function to query tasks by `goal_id` and compute completion status.

**Example:**
```elixir
# New function in TaskQueue:
def tasks_for_goal(goal_id) do
  GenServer.call(__MODULE__, {:tasks_for_goal, goal_id})
end

# Handler:
def handle_call({:tasks_for_goal, goal_id}, _from, state) do
  tasks =
    :dets.foldl(
      fn {_id, task}, acc ->
        if Map.get(task, :goal_id) == goal_id, do: [task | acc], else: acc
      end,
      [],
      @tasks_table
    )
  {:reply, tasks, state}
end
```

### Anti-Patterns to Avoid
- **Building a full DAG scheduler:** The decision is explicit: each task knows its predecessors via `depends_on`. No topological sort needed at scheduling time -- just check "are all my deps completed?"
- **Restructuring DETS schema:** Tasks are stored as `{task_id, task_map}` tuples. Adding keys to the map requires zero DETS schema changes. Do NOT attempt DETS table migration.
- **Synchronous dependency resolution at submit time:** Submission should be fast. Dependency validation (if any) should be lightweight -- checking existence only, not full graph analysis.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Dependency graph library | Custom DAG implementation | Simple list iteration + `TaskQueue.get/1` | 0-3 deps per task; a graph library is overkill |
| Batch task lookup | Custom ETS index by goal_id | `:dets.foldl/3` with filter | Existing pattern used by `list/1`, `stats/0`; goal queries are infrequent |

**Key insight:** The dependency check is O(d) per task where d is 0-3. Even with 100 queued tasks, that's at most 300 DETS key lookups -- microseconds. No caching or indexing needed.

## Common Pitfalls

### Pitfall 1: DETS Backward Compatibility on Missing Keys
**What goes wrong:** Existing tasks persisted in DETS before Phase 28 lack `depends_on` and `goal_id` keys. Code that accesses `task.depends_on` directly (dot syntax) will crash with `KeyError`.
**Why it happens:** DETS stores the exact map that was persisted. Old tasks never had these keys.
**How to avoid:** ALWAYS use `Map.get(task, :depends_on, [])` and `Map.get(task, :goal_id, nil)` when reading from any task. Never use `task.depends_on` dot syntax in code that might encounter pre-Phase-28 tasks.
**Warning signs:** `KeyError` in production on task maps from DETS.

### Pitfall 2: Scheduler GenServer.call to TaskQueue During Scheduling
**What goes wrong:** The dependency filter calls `TaskQueue.get/1` (a GenServer.call) from within `try_schedule_all/2`, which runs inside the Scheduler's GenServer. If TaskQueue is slow or blocked, the Scheduler blocks.
**Why it happens:** `TaskQueue.get/1` is `GenServer.call(__MODULE__, {:get, task_id})`. From the Scheduler process, this is a cross-GenServer call -- safe but blocking.
**How to avoid:** This is actually fine for 0-3 deps per task. The DETS lookup is fast (~microseconds for key-based lookup). If performance becomes a concern (unlikely), consider a batch lookup function.
**Warning signs:** Scheduler telemetry showing slow scheduling cycles (> 100ms).

### Pitfall 3: Dependency on Dead-Lettered or Nonexistent Tasks
**What goes wrong:** A task depends on `task-abc`, but `task-abc` was dead-lettered (moved to `@dead_letter_table`) or never existed. The dependency is never satisfied, and the dependent task sits queued forever.
**Why it happens:** `TaskQueue.get/1` checks both tables and returns the dead-lettered task, but its status is `:dead_letter` not `:completed`. A nonexistent ID returns `{:error, :not_found}`.
**How to avoid:** Both `:dead_letter` and `:not_found` should be treated as "dependency not satisfied" (the task stays queued). Consider whether a dead-lettered dependency should unblock dependents or permanently block them. Recommendation: treat it as unsatisfied -- if the dependency is retried from dead-letter and eventually completes, the dependent task will unblock naturally. If the dependency is truly dead, the dependent task will eventually TTL-expire (existing Phase 19-03 sweep).
**Warning signs:** Tasks stuck in `:queued` with non-empty `depends_on` where all dependencies are dead-lettered.

### Pitfall 4: Circular Dependencies
**What goes wrong:** Task A depends on B, B depends on A. Both tasks stay queued forever.
**Why it happens:** Goal decomposition (Phase 29+) should produce a DAG, but bugs or manual submission could create cycles.
**How to avoid:** The CONTEXT.md leaves this to Claude's discretion. **Recommendation: Do NOT add cycle detection at submit time for Phase 28.** Rationale: (1) dependencies are typically set by HubFSM decomposition, which should produce a DAG; (2) cycle detection requires loading all tasks in the dependency chain, adding complexity; (3) the TTL sweep already handles permanently stuck tasks. Add a telemetry event for "task blocked by dependencies for > N minutes" to surface cycles for debugging.
**Warning signs:** Two or more tasks mutually stuck in `:queued` with circular `depends_on` references.

### Pitfall 5: Forgetting to Update API Schema and Endpoint
**What goes wrong:** New fields are added to TaskQueue but not to the HTTP API validation schema or endpoint param forwarding.
**Why it happens:** The API layer and TaskQueue are separate code paths.
**How to avoid:** Update THREE places: (1) `TaskQueue.submit/1` handler, (2) `Validation.Schemas` `post_task` schema, (3) `Endpoint` POST /api/tasks param forwarding (line 902-918).

## Code Examples

### Adding Fields to Task Map (submit handler)
```elixir
# In task_queue.ex, inside handle_call({:submit, params}, _from, state):
# Add after the existing verification fields (line ~278):
task = %{
  # ... all existing fields ...
  depends_on: Map.get(params, :depends_on, Map.get(params, "depends_on", [])),
  goal_id: Map.get(params, :goal_id, Map.get(params, "goal_id", nil))
}
```

### Scheduler Dependency Filter
```elixir
# In scheduler.ex, inside try_schedule_all/2, after Phase 23 repo filter:

# Phase 28: Filter out tasks whose dependencies are not yet completed
schedulable_tasks =
  Enum.filter(schedulable_tasks, fn task ->
    deps = Map.get(task, :depends_on, [])
    deps == [] or Enum.all?(deps, fn dep_id ->
      case AgentCom.TaskQueue.get(dep_id) do
        {:ok, %{status: :completed}} -> true
        _ -> false
      end
    end)
  end)
```

### Goal Progress Query
```elixir
# New public API in task_queue.ex:
@doc "Return all tasks belonging to a goal, with completion summary."
def tasks_for_goal(goal_id) do
  GenServer.call(__MODULE__, {:tasks_for_goal, goal_id})
end

def goal_progress(goal_id) do
  tasks = tasks_for_goal(goal_id)
  total = length(tasks)
  completed = Enum.count(tasks, & &1.status == :completed)
  failed = Enum.count(tasks, fn t -> t.status == :dead_letter end)
  %{goal_id: goal_id, total: total, completed: completed, failed: failed,
    pending: total - completed - failed}
end
```

### Validation Schema Update
```elixir
# In validation/schemas.ex, add to post_task optional fields:
"depends_on" => {:list, :string},
"goal_id" => :string
```

### Endpoint Param Forwarding
```elixir
# In endpoint.ex, POST /api/tasks handler, add to task_params map:
depends_on: params["depends_on"] || [],
goal_id: params["goal_id"]
```

### TestFactory Extension
```elixir
# In test/support/test_factory.ex, add to submit_task/1:
def submit_task(opts \\ []) do
  params = %{
    # ... existing params ...
    depends_on: Keyword.get(opts, :depends_on, []),
    goal_id: Keyword.get(opts, :goal_id, nil)
  }
  AgentCom.TaskQueue.submit(params)
end
```

### Task Data Sent to Agent (Scheduler)
```elixir
# In scheduler.ex do_assign/4, add to task_data map:
task_data = %{
  # ... existing fields ...
  depends_on: Map.get(assigned_task, :depends_on, []),
  goal_id: Map.get(assigned_task, :goal_id)
}
```

## Discretion Recommendations

### 1. depends_on Validation at Submit Time
**Recommendation: Validate existence only (lightweight), do NOT validate status.**

At submission time, check that each task ID in `depends_on` exists in the task queue (either table). This catches typos and stale IDs early. Do NOT check their status -- dependencies may not be completed yet (that's the point).

```elixir
# In submit handler, after building the task map:
deps = Map.get(task, :depends_on, [])
invalid = Enum.reject(deps, fn dep_id ->
  match?({:ok, _}, lookup_task(dep_id)) or match?({:ok, _}, lookup_dead_letter(dep_id))
end)
if invalid != [] do
  {:reply, {:error, {:invalid_dependencies, invalid}}, state}
else
  # proceed with persist
end
```

**Trade-off:** This adds a DETS lookup per dependency at submit time (0-3 lookups, fast). It prevents submission of tasks with typo'd dependency IDs. However, it also means dependencies must be submitted before dependents -- which is natural for decomposition (submit all tasks, then the scheduler figures out ordering).

**Alternative considered:** Skip validation entirely. Simpler, but tasks with invalid dependency IDs would be permanently blocked until TTL expiry.

### 2. Circular Dependency Detection
**Recommendation: Do NOT detect cycles in Phase 28. Add diagnostic telemetry instead.**

Rationale:
- Goal decomposition (Phase 29) is the primary source of dependencies and should produce DAGs
- Manual task submission with circular deps is an edge case
- Cycle detection requires graph traversal (DFS/BFS) which adds complexity
- Existing TTL sweep (Phase 19-03) handles permanently stuck tasks

Add a telemetry event when a task has been queued with non-empty `depends_on` for longer than 10 minutes. This surfaces potential cycles without adding code complexity.

### 3. API Endpoint for Querying Tasks by goal_id
**Recommendation: Yes, add `GET /api/tasks?goal_id=<id>` filter to existing list endpoint.**

The existing `GET /api/tasks` endpoint already supports `status` and `priority` filters. Add `goal_id` as another filter parameter. This requires:
- Add `goal_id` filter to `TaskQueue.list/1` opts handling (line 330-357)
- Add query param parsing in the endpoint

This is the minimal, consistent approach. No new endpoint needed.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Tasks are independent, no ordering | Tasks can declare predecessors via `depends_on` | Phase 28 | Enables goal decomposition to produce ordered task graphs |
| No goal tracking on tasks | Tasks carry `goal_id` for goal-level aggregation | Phase 28 | Enables GoalBacklog (Phase 27) progress tracking |

## Open Questions

1. **What happens when a dependency is retried from dead-letter?**
   - What we know: `retry_dead_letter/1` resets status to `:queued`. If it eventually completes, the dependent task's `depends_on` check will pass on the next scheduling cycle.
   - What's unclear: Should retrying a dead-lettered dependency explicitly trigger re-evaluation of blocked tasks?
   - Recommendation: No explicit trigger needed. The Scheduler already re-evaluates all queued tasks on every scheduling trigger (task_completed, task_submitted, etc.). When the retried dependency eventually completes, the `:task_completed` event triggers scheduling, and the blocked task will pass the dependency filter.

2. **Should `goal_progress/1` be a GenServer.call or a client-side aggregation?**
   - What we know: `tasks_for_goal/1` does a DETS foldl (scan). For goals with 3-10 tasks, this is fast.
   - What's unclear: Whether GoalBacklog (Phase 27) will call this frequently.
   - Recommendation: Implement as `GenServer.call` for simplicity. If performance matters later, GoalBacklog can cache progress locally by subscribing to `:task_completed` events.

## Files to Modify

| File | Change | Lines (est.) |
|------|--------|-------------|
| `lib/agent_com/task_queue.ex` | Add `depends_on` and `goal_id` to task map in submit; add `tasks_for_goal/1` and `goal_progress/1`; add goal_id to list filter | ~40 lines |
| `lib/agent_com/scheduler.ex` | Add dependency filter after repo filter in `try_schedule_all/2` | ~10 lines |
| `lib/agent_com/validation/schemas.ex` | Add `depends_on` and `goal_id` to `post_task` optional fields | ~2 lines |
| `lib/agent_com/endpoint.ex` | Add `depends_on` and `goal_id` to task_params in POST /api/tasks; add `goal_id` filter to GET /api/tasks | ~5 lines |
| `test/agent_com/task_queue_test.exs` | Tests for depends_on, goal_id, tasks_for_goal, goal_progress | ~60 lines |
| `test/agent_com/scheduler_test.exs` | Tests for dependency filtering (3-task chain, independent tasks unaffected) | ~40 lines |
| `test/support/test_factory.ex` | Add depends_on and goal_id to submit_task/1 | ~3 lines |

**Total estimated change: ~160 lines across 7 files.**

## Sources

### Primary (HIGH confidence)
- Codebase inspection: `lib/agent_com/task_queue.ex` -- full task map structure, DETS persistence pattern, submit handler
- Codebase inspection: `lib/agent_com/scheduler.ex` -- `try_schedule_all/2` filter chain, Phase 23 repo filter pattern
- Codebase inspection: `lib/agent_com/validation/schemas.ex` -- `post_task` schema structure
- Codebase inspection: `lib/agent_com/endpoint.ex` -- POST /api/tasks param forwarding pattern
- Codebase inspection: `test/agent_com/task_queue_test.exs` -- test patterns for new fields
- Codebase inspection: `test/agent_com/scheduler_test.exs` -- test patterns for scheduling behavior
- Codebase inspection: `.planning/research/ARCHITECTURE.md` -- GoalBacklog design, dependency filter placement

### Secondary (MEDIUM confidence)
- Phase 28 CONTEXT.md -- user decisions on implementation approach

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- no new libraries, extending existing GenServers with established patterns
- Architecture: HIGH -- patterns directly observed in codebase (Phase 17 field extension, Phase 23 scheduler filter)
- Pitfalls: HIGH -- all pitfalls derived from actual codebase patterns (DETS backward compat, GenServer.call chains)

**Research date:** 2026-02-13
**Valid until:** 2026-03-13 (stable -- internal codebase patterns don't change externally)
