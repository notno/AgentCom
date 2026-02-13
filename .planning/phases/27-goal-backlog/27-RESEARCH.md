# Phase 27: Goal Backlog - Research

**Researched:** 2026-02-13
**Domain:** Elixir GenServer + DETS persistence, HTTP API, Node.js CLI sidecar
**Confidence:** HIGH

## Summary

The GoalBacklog GenServer follows a well-established pattern in this codebase. TaskQueue, RepoRegistry, and CostLedger all demonstrate the exact GenServer + DETS pattern needed. The primary implementation is a new `AgentCom.GoalBacklog` GenServer that stores goals as individual DETS records (like TaskQueue, not like RepoRegistry's single-key approach), with an in-memory priority index for O(1) dequeue of the highest-priority goal.

The HTTP API follows the exact pattern of `/api/tasks` endpoints in `AgentCom.Endpoint`. The CLI tool follows the `agentcom-submit.js` pattern -- a standalone Node.js script using `node:util/parseArgs` and raw `http` module. PubSub integration follows the `broadcast_task_event` pattern from TaskQueue, publishing on a `"goals"` topic.

An XML schema struct already exists at `AgentCom.XML.Schemas.Goal` which defines the goal structure for XML parsing. The GoalBacklog's internal goal map should align with this schema's fields but will add lifecycle and tracking fields (status, child_task_ids, timestamps, history).

**Primary recommendation:** Follow the TaskQueue pattern closely -- per-goal DETS keys, in-memory priority index, `persist_goal` helper with `dets.sync`, PubSub broadcast on state changes, and register the DETS table with DetsBackup from day one.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Goal Structure
- Unique goal ID (UUID or sequential)
- Description, success criteria (required at submission)
- Priority lanes: urgent/high/normal/low (same pattern as TaskQueue)
- Lifecycle: submitted -> decomposing -> executing -> verifying -> complete/failed
- Tracks child task IDs after decomposition
- Source field: api/cli/internal (for tracking where goals come from)

#### Multi-Source Input
- HTTP API endpoint: POST /api/goals with description + success_criteria + priority
- CLI tool: `agentcom-submit-goal.js` (Node.js, follows existing sidecar CLI pattern)
- Internal generation: HubFSM (Phase 29) and SelfImprovement (Phase 32) create goals programmatically

#### Parallel Goal Processing
- Goals are independent by default -- multiple can execute simultaneously
- Before decomposing a new goal, preprocessing step checks: "does this depend on anything currently executing or in the backlog?"
- Dependency detection at Claude's discretion (keyword matching, file overlap, explicit user annotation)

#### PubSub Integration
- Publish on "goals" topic for state changes
- FSM-08 requirement: goal backlog changes wake FSM from Resting to Executing

### Claude's Discretion
- Goal ID format (UUID vs sequential with prefix)
- DETS key structure (single key vs per-goal keys)
- Dependency detection approach between goals
- API response format
- CLI tool design

### Deferred Ideas (OUT OF SCOPE)
(none specified)
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GenServer (OTP) | Elixir stdlib | Goal state management | Every GenServer in this codebase uses this pattern |
| :dets (OTP) | Erlang stdlib | Persistent goal storage | Established pattern from TaskQueue/RepoRegistry/CostLedger |
| Phoenix.PubSub | Already in deps | Goal lifecycle event broadcasting | Used by all event-producing GenServers in the codebase |
| Jason | Already in deps | JSON encoding for HTTP responses | Used throughout Endpoint |
| node:util (parseArgs) | Node.js stdlib | CLI argument parsing | Used by agentcom-submit.js |
| node:http | Node.js stdlib | HTTP client for CLI tool | Used by agentcom-submit.js |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| :telemetry | Already in deps | Goal operation metrics | Emit on submit, transition, complete -- same as TaskQueue |
| AgentCom.Validation.Schemas | Existing module | HTTP body validation | Add `post_goal` and `patch_goal_transition` schemas |
| AgentCom.DetsBackup | Existing module | Backup registration | Register `:goal_backlog` table on day one |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Per-goal DETS keys | Single-key list (RepoRegistry pattern) | Per-key is better for individual lookups, concurrent access, and large goal counts; single-key is simpler but forces full-list reads |
| Prefix-based goal IDs | UUID v4 | Prefix IDs (`goal-` + hex) match TaskQueue pattern and are human-readable; UUIDs are globally unique but harder to read in logs |

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  goal_backlog.ex          # GenServer: DETS persistence, priority index, lifecycle, PubSub
sidecar/
  agentcom-submit-goal.js  # CLI tool for goal submission
test/agent_com/
  goal_backlog_test.exs    # Unit tests
```

### Pattern 1: TaskQueue-style GenServer + DETS (PRIMARY PATTERN)
**What:** Named GenServer with DETS table opened in init/1, per-record keys, in-memory priority index, dets.sync after every mutation
**When to use:** This is THE pattern for GoalBacklog
**Example from TaskQueue:**
```elixir
# Init: open DETS, rebuild in-memory index
def init(_opts) do
  {:ok, @table} = :dets.open_file(@table, file: path, type: :set, auto_save: 5_000)
  priority_index = rebuild_priority_index()
  {:ok, %{priority_index: priority_index}}
end

# Persist: insert + sync + corruption detection
defp persist_goal(goal, table) do
  case :dets.insert(table, {goal.id, goal}) do
    :ok -> :dets.sync(table) ; :ok
    {:error, reason} ->
      GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, table, reason})
      {:error, :table_corrupted}
  end
end
```

### Pattern 2: PubSub Event Broadcasting
**What:** Broadcast lifecycle events on a named topic for downstream consumers
**When to use:** Every goal state change
**Example from TaskQueue:**
```elixir
defp broadcast_goal_event(event, goal) do
  Phoenix.PubSub.broadcast(AgentCom.PubSub, "goals", {:goal_event, %{
    event: event,
    goal_id: goal.id,
    goal: goal,
    timestamp: System.system_time(:millisecond)
  }})
end
```

### Pattern 3: HTTP Endpoint with Validation
**What:** Auth-gated HTTP endpoint using Validation.validate_http/2 before processing
**When to use:** POST /api/goals and GET /api/goals endpoints
**Example from TaskQueue POST /api/tasks:**
```elixir
post "/api/goals" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do conn
  else
    case Validation.validate_http(:post_goal, conn.body_params) do
      {:ok, _} ->
        # Build goal params, call GoalBacklog.submit/1
        case AgentCom.GoalBacklog.submit(goal_params) do
          {:ok, goal} -> send_json(conn, 201, format_goal(goal))
        end
      {:error, errors} -> send_validation_error(conn, errors)
    end
  end
end
```

### Pattern 4: CLI Sidecar Tool
**What:** Standalone Node.js script with parseArgs, raw http, no shared modules
**When to use:** `agentcom-submit-goal.js`
**Example from agentcom-submit.js:** Same structure -- parseArgs for flags, httpRequest helper, POST to `/api/goals`

### Anti-Patterns to Avoid
- **Storing goals as a single list under one DETS key:** RepoRegistry does this because repos are few (<20) and need atomic reordering. Goals can number in hundreds -- use per-goal keys like TaskQueue.
- **Blocking GenServer calls for dependency detection:** Dependency detection (if implemented) should be fast and synchronous within the GenServer, not spawning external processes during the submit path.
- **Forgetting dets.sync after mutations:** Every DETS write must be followed by `:dets.sync/1` -- this is a crash-safety invariant across the codebase.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Goal ID generation | Custom UUID library | `"goal-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)` | Matches TaskQueue's `generate_task_id/0` pattern exactly |
| Input validation | Custom validation | `AgentCom.Validation.validate_http/2` with schema in `Schemas` | Existing validation infrastructure handles types, required fields, length limits |
| DETS corruption handling | Custom recovery | `GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, ...})` | DetsBackup already handles auto-restore |
| Priority ordering | Custom sorting | In-memory sorted list `[{priority_int, created_at, goal_id}]` | Same as TaskQueue's priority index |
| Event broadcasting | Custom pubsub | `Phoenix.PubSub.broadcast/3` on "goals" topic | Standard Phoenix PubSub, already in supervision tree |

**Key insight:** Every infrastructure component needed for GoalBacklog already exists in the codebase. The implementation is purely composition of established patterns.

## Common Pitfalls

### Pitfall 1: DETS Table Name Collision
**What goes wrong:** Using a DETS table name that's already taken by another GenServer
**Why it happens:** Erlang DETS tables are globally named atoms
**How to avoid:** Use `:goal_backlog` as the table name -- verify it's not in the existing `@tables` list in DetsBackup
**Warning signs:** `{:error, {:already_open, ...}}` on startup

### Pitfall 2: Forgetting DetsBackup Registration
**What goes wrong:** GoalBacklog DETS table not backed up, not compacted, no health metrics
**Why it happens:** New tables need to be added to DetsBackup's `@tables` list and `table_owner/1`, `get_table_path/1`
**How to avoid:** Add `:goal_backlog` to DetsBackup `@tables`, add `table_owner(:goal_backlog)` clause, add `get_table_path(:goal_backlog)` clause, update DetsHelpers for tests
**Warning signs:** Missing from `/api/admin/dets-health` output

### Pitfall 3: Supervision Tree Ordering
**What goes wrong:** GoalBacklog starts before its dependencies (PubSub, Config) or after its consumers
**Why it happens:** Elixir one_for_one supervisor starts children in list order
**How to avoid:** Place GoalBacklog after DetsBackup (which it doesn't directly depend on, but follows convention) and before any future FSM consumer. Insert after `AgentCom.DetsBackup` in application.ex children list.
**Warning signs:** `{:noproc, ...}` errors on PubSub broadcast

### Pitfall 4: Lifecycle State Machine Violations
**What goes wrong:** Goals transition to invalid states (e.g., submitted -> complete, skipping decomposing/executing/verifying)
**Why it happens:** No enforcement of valid transitions
**How to avoid:** Define valid transitions as a map and validate in the `transition_goal/3` handler:
```elixir
@valid_transitions %{
  :submitted => [:decomposing],
  :decomposing => [:executing, :failed],
  :executing => [:verifying, :failed],
  :verifying => [:complete, :failed, :executing]  # executing for retry
}
```
**Warning signs:** Goals in unexpected states, downstream consumers confused

### Pitfall 5: Missing Test DETS Isolation
**What goes wrong:** Tests pollute each other or fail on CI because DETS files persist
**Why it happens:** DETS writes to disk; tests need isolated temp directories
**How to avoid:** Add `goal_backlog_data_dir` to `DetsHelpers.setup_test_dets/0`, add `AgentCom.GoalBacklog` to the restart order in `DetsHelpers.restart_dets_servers/0`
**Warning signs:** Flaky tests, test pollution, CI failures

### Pitfall 6: Endpoint Route Ordering
**What goes wrong:** `/api/goals/stats` matches `:goal_id` parameter route instead of the stats route
**Why it happens:** Plug.Router matches routes top-down; parameterized routes consume everything
**How to avoid:** Define `/api/goals/stats` BEFORE `/api/goals/:goal_id` in the endpoint, same as TaskQueue's `/api/tasks/stats` before `/api/tasks/:task_id`
**Warning signs:** 404 errors or unexpected responses for named sub-routes

## Code Examples

### Goal Map Structure
```elixir
# Internal goal representation (stored in DETS as {goal_id, goal_map})
goal = %{
  id: "goal-a1b2c3d4e5f6g7h8",
  description: "Implement rate limiting for webhook endpoint",
  success_criteria: ["Returns 429 after 100 req/min", "Configurable via Config"],
  priority: 0,           # 0=urgent, 1=high, 2=normal, 3=low (same as TaskQueue)
  status: :submitted,    # :submitted | :decomposing | :executing | :verifying | :complete | :failed
  source: "api",         # "api" | "cli" | "internal"
  child_task_ids: [],    # Populated after decomposition
  tags: [],              # Optional categorization
  repo: "https://github.com/user/repo",
  file_hints: [],        # Context for decomposition
  metadata: %{},         # Freeform metadata
  submitted_by: "agent-id-or-user",
  created_at: 1707800000000,
  updated_at: 1707800000000,
  history: [{:submitted, 1707800000000, "submitted via api"}]
}
```

### GoalBacklog GenServer Init
```elixir
@table :goal_backlog
@priority_map %{"urgent" => 0, "high" => 1, "normal" => 2, "low" => 3}
@history_cap 50

def init(_opts) do
  Logger.metadata(module: __MODULE__)
  dets_path = data_dir() |> Path.join("goal_backlog.dets") |> String.to_charlist()
  File.mkdir_p!(data_dir())
  {:ok, @table} = :dets.open_file(@table, file: dets_path, type: :set, auto_save: 5_000)
  priority_index = rebuild_priority_index()
  {:ok, %{priority_index: priority_index}}
end
```

### Submit Goal Handler
```elixir
def handle_call({:submit, params}, _from, state) do
  now = System.system_time(:millisecond)
  goal_id = generate_goal_id()
  priority_str = Map.get(params, :priority, "normal")
  priority = Map.get(@priority_map, to_string(priority_str), 2)

  goal = %{
    id: goal_id,
    description: Map.get(params, :description, ""),
    success_criteria: Map.get(params, :success_criteria, []),
    priority: priority,
    status: :submitted,
    source: Map.get(params, :source, "api"),
    child_task_ids: [],
    tags: Map.get(params, :tags, []),
    repo: Map.get(params, :repo),
    file_hints: Map.get(params, :file_hints, []),
    metadata: Map.get(params, :metadata, %{}),
    submitted_by: Map.get(params, :submitted_by, "unknown"),
    created_at: now,
    updated_at: now,
    history: [{:submitted, now, "submitted via #{Map.get(params, :source, "api")}"}]
  }

  persist_goal(goal)
  new_index = add_to_priority_index(state.priority_index, goal)
  broadcast_goal_event(:goal_submitted, goal)

  :telemetry.execute(
    [:agent_com, :goal, :submit],
    %{backlog_depth: length(new_index)},
    %{goal_id: goal_id, priority: priority, source: goal.source}
  )

  {:reply, {:ok, goal}, %{state | priority_index: new_index}}
end
```

### Lifecycle Transition Handler
```elixir
@valid_transitions %{
  :submitted => [:decomposing],
  :decomposing => [:executing, :failed],
  :executing => [:verifying, :failed],
  :verifying => [:complete, :failed, :executing]
}

def handle_call({:transition, goal_id, new_status, opts}, _from, state) do
  case lookup_goal(goal_id) do
    {:ok, goal} ->
      allowed = Map.get(@valid_transitions, goal.status, [])
      if new_status in allowed do
        now = System.system_time(:millisecond)
        updated = %{goal |
          status: new_status,
          updated_at: now,
          child_task_ids: Keyword.get(opts, :child_task_ids, goal.child_task_ids),
          history: cap_history([{new_status, now, Keyword.get(opts, :reason, "")} | goal.history])
        }
        persist_goal(updated)

        # Update priority index: remove from index when no longer in :submitted
        new_index = if new_status != :submitted do
          remove_from_priority_index(state.priority_index, goal_id)
        else
          state.priority_index
        end

        broadcast_goal_event(:"goal_#{new_status}", updated)
        {:reply, {:ok, updated}, %{state | priority_index: new_index}}
      else
        {:reply, {:error, {:invalid_transition, goal.status, new_status}}, state}
      end

    {:error, :not_found} ->
      {:reply, {:error, :not_found}, state}
  end
end
```

### Validation Schema for POST /api/goals
```elixir
# Add to @http_schemas in AgentCom.Validation.Schemas
post_goal: %{
  required: %{
    "description" => :string,
    "success_criteria" => {:list, :string}
  },
  optional: %{
    "priority" => :string,
    "source" => :string,
    "repo" => :string,
    "file_hints" => {:list, :string},
    "tags" => {:list, :string},
    "metadata" => :map
  },
  description: "Submit a goal to the backlog."
}
```

### DetsBackup Integration Points
```elixir
# In AgentCom.DetsBackup:
# 1. Add to @tables list:
@tables [
  # ... existing tables ...
  :goal_backlog
]

# 2. Add table_owner clause:
defp table_owner(:goal_backlog), do: AgentCom.GoalBacklog

# 3. Add get_table_path clause:
:goal_backlog ->
  dir = Application.get_env(:agent_com, :goal_backlog_data_dir, "priv/data/goal_backlog")
  Path.join(dir, "goal_backlog.dets")

# 4. Add to @dets_table_atoms in Endpoint for admin compact/restore:
"goal_backlog" => :goal_backlog
```

### DetsHelpers Test Integration
```elixir
# In test/support/dets_helpers.ex:
# 1. Add to setup_test_dets:
Application.put_env(:agent_com, :goal_backlog_data_dir, Path.join(tmp_dir, "goal_backlog"))
File.mkdir_p!(Path.join(tmp_dir, "goal_backlog"))

# 2. Add to restart_dets_servers stop_order (before DetsBackup):
AgentCom.GoalBacklog,

# 3. Add to dets_tables list:
:goal_backlog
```

## Discretion Recommendations

### Goal ID Format: Prefix-based (RECOMMENDED)
Use `"goal-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)` -- produces IDs like `goal-a1b2c3d4e5f6g7h8`. This matches TaskQueue's `task-` prefix pattern exactly, is human-readable in logs and API responses, and avoids UUID library dependency.

### DETS Key Structure: Per-goal keys (RECOMMENDED)
Use per-goal DETS keys `{goal_id, goal_map}` like TaskQueue, NOT single-key list like RepoRegistry. Reasons: goals can grow to hundreds, individual lookups are O(1) vs O(n), no need for atomic list reordering (priority is computed, not positional).

### Dependency Detection Approach: Lightweight keyword + repo overlap (RECOMMENDED)
For the preprocessing step that checks if a new goal depends on anything executing:
1. **Repo overlap:** If a new goal targets the same repo as an executing goal, flag it as potentially dependent
2. **Explicit user annotation:** Support an optional `depends_on` field (list of goal IDs) in the submit API
3. **No NLP/keyword matching initially:** Keep it simple for Phase 27; sophisticated detection can come later

This is sufficient for Phase 27's scope. The field `depends_on: []` in the goal struct allows explicit dependencies, and repo-overlap detection is a cheap GenServer-side check.

### API Response Format: Match TaskQueue style (RECOMMENDED)
```json
{
  "status": "submitted",
  "goal_id": "goal-a1b2c3d4e5f6g7h8",
  "priority": 2,
  "created_at": 1707800000000
}
```

### CLI Tool Design: Mirror agentcom-submit.js (RECOMMENDED)
```
node agentcom-submit-goal.js \
  --description "Implement rate limiting" \
  --criteria "Returns 429 after 100 req/min" \
  --criteria "Configurable via Config" \
  --hub http://localhost:4000 \
  --token abc123 \
  --priority normal
```
Key difference from `agentcom-submit.js`: `--criteria` flag (repeatable) instead of single `--description`. Use `parseArgs` with `multiple: true` for the criteria flag.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| No goal concept | TaskQueue handles everything | Pre-Phase 27 | Goals add decomposition layer above tasks |

**This is a new concept in the codebase** -- there is no legacy to migrate from.

## Open Questions

1. **Goal-to-task relationship tracking**
   - What we know: Goals decompose into 1-N tasks (Phase 30). GoalBacklog tracks `child_task_ids`.
   - What's unclear: Should GoalBacklog subscribe to TaskQueue events to auto-update goal status when all child tasks complete?
   - Recommendation: Add the `child_task_ids` field now but defer auto-status-update to Phase 30 (Decomposition). GoalBacklog just needs `transition/3` API -- the caller (HubFSM or Decomposition) is responsible for triggering transitions.

2. **Goal stats endpoint scope**
   - What we know: Phase 36 (dashboard) will want goal stats
   - What's unclear: How much stats infrastructure to build now vs later
   - Recommendation: Implement a basic `stats/0` function (count by status, count by priority) matching TaskQueue's `stats/0` pattern. This is cheap and immediately useful for debugging.

3. **Parallel goal limit**
   - What we know: Goals are independent by default, multiple can execute simultaneously
   - What's unclear: Should there be a configurable max-parallel-goals limit?
   - Recommendation: Don't implement a limit in Phase 27. The GoalBacklog is a storage/lifecycle layer. Execution scheduling belongs to HubFSM (Phase 29).

## Sources

### Primary (HIGH confidence)
- `lib/agent_com/task_queue.ex` -- TaskQueue GenServer pattern (DETS, priority index, PubSub, telemetry)
- `lib/agent_com/repo_registry.ex` -- RepoRegistry GenServer pattern (single-key DETS, simpler lifecycle)
- `lib/agent_com/cost_ledger.ex` -- CostLedger GenServer pattern (dual-layer DETS+ETS)
- `lib/agent_com/dets_backup.ex` -- DetsBackup registration pattern (@tables list, table_owner, get_table_path)
- `lib/agent_com/endpoint.ex` -- HTTP API routing pattern (auth, validation, JSON responses)
- `lib/agent_com/validation/schemas.ex` -- Validation schema pattern (required/optional field maps)
- `lib/agent_com/xml/schemas/goal.ex` -- Existing Goal XML schema struct
- `lib/agent_com/application.ex` -- Supervision tree ordering
- `sidecar/agentcom-submit.js` -- CLI sidecar tool pattern
- `test/support/dets_helpers.ex` -- Test isolation pattern for DETS-backed GenServers

### Secondary (MEDIUM confidence)
- Pattern inference from TaskQueue (the most analogous existing module)

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All components already exist in the codebase; no new dependencies
- Architecture: HIGH - Direct pattern replication from TaskQueue with lifecycle additions
- Pitfalls: HIGH - Identified from actual codebase patterns and test infrastructure

**Research date:** 2026-02-13
**Valid until:** 2026-03-13 (stable -- internal patterns, no external dependencies)
