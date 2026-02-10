# Phase 2: Task Queue - Research

**Researched:** 2026-02-10
**Domain:** Elixir/OTP GenServer, DETS persistence, priority queue design, dead-letter patterns, generation-based idempotency, periodic sweep timers
**Confidence:** HIGH

## Summary

Phase 2 builds a hub-side persistent task queue as a new GenServer module (`AgentCom.TaskQueue`), following the established patterns already used by Mailbox, Channels, MessageHistory, and other DETS-backed modules in the codebase. The core challenge is not technology selection -- DETS is the established persistence layer, GenServer is the established concurrency model -- but rather designing correct state transitions, priority ordering, generation fencing, and crash-safe sync patterns within that existing framework.

The codebase already contains six DETS-backed GenServers, each following the same pattern: open table in `init/1`, use `:dets.insert/select/delete` for operations, `auto_save: 5_000`, close in `terminate/2`. The task queue module will follow this same pattern but add two DETS tables (task queue + dead-letter storage), an in-memory priority index (sorted list or ETS for O(1) dequeue by priority), a periodic sweep timer for overdue reclamation, and `dets.sync/1` after every status change (per TASK-06 requirement).

The sidecar (Phase 1) already implements the client-side task protocol: it receives `task_assign`, sends `task_accepted`/`task_complete`/`task_failed`/`task_recovering`, and handles `task_reassign`/`task_continue`. The hub's Socket module already handles these messages with PubSub broadcasts. Phase 2 replaces the "log and ack" stub behavior in Socket with actual TaskQueue state management.

**Primary recommendation:** Build a single `AgentCom.TaskQueue` GenServer module with two DETS tables (tasks + dead-letter), four priority lanes as integer weights (urgent=0, high=1, normal=2, low=3), generation-numbered assignments for fencing, a 30-second periodic sweep for overdue reclamation, and explicit `:dets.sync/1` after every state mutation. Wire Socket task handlers and a new HTTP API to delegate to TaskQueue. The dead-letter store is a separate DETS table, not a separate GenServer.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GenServer (OTP) | built-in | Serialize all task queue operations through single process | Already used by all 8 stateful modules in codebase; eliminates race conditions |
| DETS (OTP) | built-in | Persistent key-value storage for tasks and dead-letter | Already used by Mailbox, Channels, Config, Threads, MessageHistory; no external DB needed |
| Phoenix.PubSub | 2.2.0 | Broadcast task events for dashboard/scheduler consumption | Already in project; Socket already broadcasts to "tasks" topic |
| Process.send_after | built-in | Schedule periodic overdue task sweep | Already used by Mailbox (eviction) and Reaper (stale agent sweep) |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| :crypto (OTP) | built-in | Generate task IDs with `strong_rand_bytes/1` | Task creation -- consistent with existing auth token and push-task ID patterns |
| Jason | 1.4.4 | JSON encode/decode for HTTP API responses | Already in project; all endpoints use it |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| DETS for task storage | ETS + periodic file dump | ETS is faster but loses data on crash; DETS matches existing codebase pattern and satisfies TASK-01 persistence requirement |
| DETS for task storage | Mnesia | Mnesia adds transaction support and ordered_set but is significantly more complex to configure and recover; overkill for single-node hub with 4-5 agents |
| DETS for task storage | SQLite via Exqlite | Would give true ordered queries and ACID transactions, but adds external dependency; project explicitly chose DETS as persistence layer |
| In-memory priority index | DETS-only priority queries | DETS does not support `ordered_set`; scanning all tasks for priority ordering on every dequeue is O(n); an in-memory sorted structure enables O(1) dequeue |
| GenServer for TaskQueue | Agent (Elixir) | Agent is simpler but lacks `handle_info` for timer sweeps and PubSub subscriptions; GenServer is the codebase standard |

**Installation:** No new dependencies required. Everything is OTP built-in or already in mix.exs.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  task_queue.ex          # GenServer: task CRUD, priority dequeue, retry, dead-letter
                         # Owns two DETS tables: :task_queue and :task_dead_letter
```

New/modified files:
```
lib/
  agent_com/
    task_queue.ex        # NEW: Core task queue GenServer
    endpoint.ex          # MODIFIED: Add task API endpoints
    socket.ex            # MODIFIED: Wire task handlers to TaskQueue
priv/
  task_queue.dets        # RUNTIME: Task storage (created on first run)
  task_dead_letter.dets  # RUNTIME: Dead-letter storage (created on first run)
```

### Pattern 1: Task Data Model
**What:** A task record stored as a map in DETS with composite keys for efficient lookup.
**When to use:** Every task operation.

The task struct represents the full lifecycle state of a unit of work:

```elixir
# Task record stored in DETS as {task_id, task_map}
%{
  id: "task-a1b2c3d4e5f6g7h8",       # Unique ID (crypto.strong_rand_bytes)
  description: "Implement feature X",  # Human-readable description
  metadata: %{},                        # Arbitrary key-value (repo, branch, etc.)
  priority: 2,                          # 0=urgent, 1=high, 2=normal, 3=low
  status: :queued,                      # :queued | :assigned | :completed | :failed | :dead_letter

  # Assignment tracking
  assigned_to: nil,                     # agent_id or nil
  assigned_at: nil,                     # timestamp (ms) or nil
  generation: 0,                        # Bumped on each assignment (fencing token)

  # Retry tracking
  retry_count: 0,                       # Number of failed attempts
  max_retries: 3,                       # Configurable per-task
  last_error: nil,                      # Most recent failure reason

  # Deadline tracking
  complete_by: nil,                     # Deadline timestamp (ms) or nil

  # Result tracking
  result: nil,                          # Completion result (includes tokens_used)
  tokens_used: nil,                     # Extracted from result for easy querying

  # Audit
  submitted_by: "admin-agent",         # Who created the task
  created_at: 1707500000000,           # Creation timestamp (ms)
  updated_at: 1707500000000,           # Last status change timestamp (ms)
  history: []                           # [{status, timestamp, details}] audit trail
}
```

**DETS key:** `{task_id, task_map}` -- simple key lookup by task ID.

### Pattern 2: Priority Index (In-Memory)
**What:** Maintain a sorted list in GenServer state that mirrors the DETS queue, enabling O(1) dequeue by priority.
**When to use:** Every enqueue and dequeue operation.

DETS does not support `ordered_set` type. Scanning all DETS entries to find the highest-priority queued task on every dequeue would be O(n). Instead, maintain an in-memory sorted list of `{priority, created_at, task_id}` tuples for all tasks with status `:queued`.

```elixir
# GenServer state includes priority index
%{
  tasks_table: :task_queue,            # DETS table name
  dead_letter_table: :task_dead_letter, # DETS table name
  priority_index: [],                   # Sorted list of {priority, created_at, task_id}
  sweep_interval_ms: 30_000            # Overdue sweep interval
}

# Enqueue: insert at sorted position
# Dequeue: take head of list (lowest priority number = highest priority)
# On startup: rebuild from DETS scan of all :queued tasks
```

The priority index is rebuilt from DETS on startup (in `init/1`), ensuring it survives restarts despite being in-memory. This pattern keeps DETS as the source of truth while enabling efficient priority ordering.

Sorting key is `{priority, created_at}` -- this gives priority-then-FIFO order as required by TASK-02. Within the same priority lane, earlier tasks are dequeued first.

### Pattern 3: Generation-Based Fencing (TASK-05)
**What:** Each task assignment increments a generation counter. All status updates from an agent must include the correct generation number to be accepted.
**When to use:** Every task assignment and every status update from an agent.

This prevents stale agents from updating tasks that have been reassigned:

```elixir
# When assigning a task:
task = %{task |
  status: :assigned,
  assigned_to: agent_id,
  assigned_at: now,
  generation: task.generation + 1  # Increment generation
}

# When agent reports completion/failure:
def complete_task(task_id, generation, result) do
  case lookup(task_id) do
    %{generation: ^generation, status: :assigned} ->
      # Generation matches, accept the update
      do_complete(task, result)
    %{generation: other_gen} when other_gen != generation ->
      # Stale update from previous assignment, reject
      {:error, :stale_generation}
    _ ->
      {:error, :invalid_state}
  end
end
```

The generation number is sent in the `task_assign` message to the sidecar. The sidecar includes it in `task_complete`/`task_failed` messages. This is a standard fencing token pattern used in distributed lock systems.

### Pattern 4: Explicit DETS Sync After Every Mutation (TASK-06)
**What:** Call `:dets.sync/1` after every task status change.
**When to use:** After every `:dets.insert/2` that changes task state.

DETS has a default auto_save interval of 3 minutes (180,000 ms). The codebase uses `auto_save: 5_000` (5 seconds). But TASK-06 explicitly requires syncing after every status change to prevent data loss on crash. The existing `AgentCom.Config` module already does this:

```elixir
# From config.ex line 51-52 (existing pattern):
:ok = :dets.insert(@table, {key, value})
:dets.sync(@table)

# Apply same pattern in TaskQueue for every mutation:
defp persist_task(task, table) do
  :dets.insert(table, {task.id, task})
  :dets.sync(table)
end
```

**Performance note:** `:dets.sync/1` flushes to disk and writes buddy system structures. For a task queue with 4-5 agents and tasks completing every few minutes, this is negligible overhead. The DETS documentation states that sync "ensures that all updates made to table are written to disk."

### Pattern 5: Periodic Sweep for Overdue Tasks (TASK-04)
**What:** A timer-based sweep that finds assigned tasks past their `complete_by` deadline and reclaims them.
**When to use:** Runs on a 30-second interval (matches Reaper's sweep interval pattern).

```elixir
# In init/1:
Process.send_after(self(), :sweep_overdue, @sweep_interval_ms)

# In handle_info:
def handle_info(:sweep_overdue, state) do
  now = System.system_time(:millisecond)

  # Find all assigned tasks past their deadline
  overdue = :dets.select(state.tasks_table, [
    {{:"$1", :"$2"},
     [{:==, {:map_get, :status, :"$2"}, :assigned},
      {:"/=", {:map_get, :complete_by, :"$2"}, nil},
      {:<, {:map_get, :complete_by, :"$2"}, now}],
     [:"$2"]}
  ])

  Enum.each(overdue, fn task ->
    reclaim_task(task, state)
  end)

  Process.send_after(self(), :sweep_overdue, state.sweep_interval_ms)
  {:noreply, state}
end

defp reclaim_task(task, state) do
  # Bump generation, reset to queued, add to priority index
  updated = %{task |
    status: :queued,
    assigned_to: nil,
    assigned_at: nil,
    generation: task.generation + 1,
    updated_at: System.system_time(:millisecond),
    history: [{:reclaimed, System.system_time(:millisecond), "overdue"} | task.history]
  }
  persist_task(updated, state.tasks_table)
  # Re-add to priority index
  add_to_priority_index(state, updated)
  # Broadcast reclamation event
  broadcast_task_event(:task_reclaimed, updated)
end
```

### Pattern 6: Dead-Letter Storage (TASK-03)
**What:** Tasks that exhaust max_retries are moved to a separate DETS table for manual inspection.
**When to use:** When a task fails and retry_count >= max_retries.

```elixir
defp handle_task_failure(task, error, state) do
  if task.retry_count + 1 >= task.max_retries do
    # Exhausted retries -- move to dead letter
    dead = %{task |
      status: :dead_letter,
      last_error: error,
      retry_count: task.retry_count + 1,
      updated_at: System.system_time(:millisecond),
      history: [{:dead_letter, System.system_time(:millisecond), error} | task.history]
    }
    # Remove from main table, add to dead-letter table
    :dets.delete(state.tasks_table, task.id)
    persist_task(dead, state.dead_letter_table)
    broadcast_task_event(:task_dead_letter, dead)
    {:dead_letter, dead}
  else
    # Retry: bump count, reset to queued
    retried = %{task |
      status: :queued,
      assigned_to: nil,
      assigned_at: nil,
      retry_count: task.retry_count + 1,
      generation: task.generation + 1,
      last_error: error,
      updated_at: System.system_time(:millisecond),
      history: [{:retry, System.system_time(:millisecond), error} | task.history]
    }
    persist_task(retried, state.tasks_table)
    add_to_priority_index(state, retried)
    broadcast_task_event(:task_retry, retried)
    {:retried, retried}
  end
end
```

### Pattern 7: Socket Integration
**What:** Modify existing Socket task handlers to delegate to TaskQueue instead of just logging.
**When to use:** When wiring Phase 2 into existing Phase 1 protocol handlers.

The Socket already handles `task_complete`, `task_failed`, `task_recovering`, and `task_accepted`. Currently these just log and ack. Phase 2 changes them to call TaskQueue:

```elixir
# BEFORE (Phase 1 - current):
defp handle_msg(%{"type" => "task_complete", "task_id" => task_id} = msg, state) do
  log_task_event(state.agent_id, "task_complete", task_id, msg)
  reply = Jason.encode!(%{"type" => "task_ack", "task_id" => task_id, "status" => "complete"})
  {:push, {:text, reply}, state}
end

# AFTER (Phase 2):
defp handle_msg(%{"type" => "task_complete", "task_id" => task_id} = msg, state) do
  generation = msg["generation"] || 0
  result = msg["result"] || %{}
  tokens_used = msg["tokens_used"] || result["tokens_used"]

  case AgentCom.TaskQueue.complete_task(task_id, generation, %{
    result: result,
    tokens_used: tokens_used,
    agent_id: state.agent_id
  }) do
    {:ok, _task} ->
      reply = Jason.encode!(%{"type" => "task_ack", "task_id" => task_id, "status" => "complete"})
      {:push, {:text, reply}, state}
    {:error, reason} ->
      reply_error(to_string(reason), state)
  end
end
```

### Pattern 8: HTTP Task API (API-02 + management)
**What:** REST endpoints for task submission, querying, and management.
**When to use:** External task creation, dashboard queries, dead-letter inspection.

```elixir
# New endpoints in endpoint.ex:

# Submit a task to the queue
post "/api/tasks" do
  # Auth required, parse priority/description/metadata/complete_by/max_retries
  # Call TaskQueue.submit(params)
  # Return task_id
end

# Get task status
get "/api/tasks/:task_id" do
  # Call TaskQueue.get(task_id)
  # Return full task record including history with tokens_used
end

# List queued tasks (with optional priority filter)
get "/api/tasks" do
  # Call TaskQueue.list(opts)
  # Return tasks with status filter, priority filter
end

# List dead-letter tasks
get "/api/tasks/dead-letter" do
  # Call TaskQueue.list_dead_letter()
end

# Retry a dead-letter task
post "/api/tasks/:task_id/retry" do
  # Call TaskQueue.retry_dead_letter(task_id)
  # Move back to queue with reset retry count
end
```

### Anti-Patterns to Avoid
- **Multiple GenServers for queue subsystem:** Do not split TaskQueue into separate GenServers for queue, dead-letter, and sweep. One GenServer owns all state, avoiding distributed coordination complexity. At 4-5 agents this is not a bottleneck.
- **DETS select for priority ordering on every dequeue:** Without `ordered_set`, this scans the entire table. Use in-memory priority index instead.
- **Storing task history in a separate table:** Keep history as a list inside the task record. It's small (one entry per status change) and eliminates cross-table joins.
- **Relying on auto_save for crash safety:** TASK-06 requires explicit sync. Do not skip `:dets.sync/1` thinking auto_save is sufficient.
- **Mutable task IDs or external-facing generation numbers:** Task IDs are immutable. Generation numbers are internal fencing tokens -- the sidecar receives them but does not generate them.
- **Using atoms for task status in DETS:** This is actually safe in this context because the set of statuses is fixed and small (5 values). Atoms are not garbage collected, but a fixed enum of 5 atoms has zero risk. Use atoms for status (:queued, :assigned, :completed, :failed, :dead_letter) for pattern matching readability.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Task ID generation | Custom UUID implementation | `:crypto.strong_rand_bytes(8) \|> Base.encode16(case: :lower)` prefixed with "task-" | Already established in auth.ex and endpoint.ex push-task; consistent and cryptographically random |
| Priority ordering | Custom sort on every dequeue | Sorted list maintained on insert (`Enum.sort_by`) or `:gb_trees` | Elixir's sorted data structures handle this efficiently for the expected scale (tens to low hundreds of tasks) |
| Periodic timer | Custom timer process | `Process.send_after/3` in GenServer `handle_info` | Already used by Mailbox and Reaper in this codebase; standard OTP pattern |
| JSON serialization | Custom encoder | Jason (already in deps) | All endpoints already use Jason; no reason to diverge |
| Crash-safe persistence | Custom write-ahead log | DETS + `:dets.sync/1` | DETS is the established persistence layer; sync provides the crash safety guarantee needed |

**Key insight:** Phase 2 introduces zero new dependencies. Everything needed is already in OTP or the existing project. The challenge is correct state machine design, not technology integration.

## Common Pitfalls

### Pitfall 1: DETS Sync Performance Under Load
**What goes wrong:** Calling `:dets.sync/1` after every task status change could become a bottleneck if many tasks change state simultaneously.
**Why it happens:** `:dets.sync/1` writes buddy system structures to disk, which takes longer as tables grow or fragment.
**How to avoid:** At the current scale (4-5 agents, tasks completing every few minutes), this is not a concern. The hub processes maybe 1-2 task state changes per minute. If scaling to 50+ agents, consider batching syncs on a 100ms timer instead of per-operation. For now, sync-per-mutation is correct and simple.
**Warning signs:** `handle_call` response times for task operations exceeding 100ms consistently.

### Pitfall 2: Priority Index Drift from DETS
**What goes wrong:** In-memory priority index gets out of sync with DETS (e.g., after a crash between DETS write and index update).
**Why it happens:** The priority index is in-memory GenServer state, while DETS is on disk. A crash after DETS persist but before index update creates inconsistency.
**How to avoid:** Rebuild the priority index from DETS on every GenServer start (`init/1`). This makes DETS the authoritative source of truth. The rebuild scans all DETS entries with status `:queued` and sorts by `{priority, created_at}`. For hundreds of tasks this takes <1ms.
**Warning signs:** Tasks visible in DETS but never dequeued; or tasks dequeued that are no longer in DETS.

### Pitfall 3: Stale Agent Completing Reassigned Task
**What goes wrong:** Agent A is assigned a task, goes silent (network issue), task is reclaimed and assigned to Agent B, Agent A comes back and reports completion.
**Why it happens:** Without fencing, the hub accepts any completion for a task ID regardless of who was assigned.
**How to avoid:** Generation-based fencing (TASK-05). Each assignment increments the generation. Agent A has generation 1, Agent B has generation 2. When Agent A reports completion with generation 1, the hub rejects it because the current generation is 2.
**Warning signs:** Tasks being marked complete by agents that are no longer assigned to them; duplicate completion events.

### Pitfall 4: Sweep Racing with Normal Completion
**What goes wrong:** The overdue sweep reclaims a task at the exact moment the agent is reporting completion. The sweep bumps generation, then the completion arrives with the old generation and is rejected.
**Why it happens:** The sweep runs on a timer and the GenServer processes messages sequentially, but the "overdue" check and the completion message can be very close in time.
**How to avoid:** This is actually handled correctly by the GenServer's sequential message processing. The sweep and completion messages are processed one at a time. If the sweep runs first, the completion will see a generation mismatch and be rejected (correct behavior -- the task was overdue). If the completion runs first, the task is no longer `:assigned` when the sweep checks it (also correct). GenServer serialization is the solution, not a problem.
**Warning signs:** None -- this is a non-issue when using GenServer serialization correctly. Worth documenting to prevent unnecessary defensive coding.

### Pitfall 5: Dead-Letter Table Growing Unbounded
**What goes wrong:** Failed tasks accumulate in dead-letter storage forever, consuming disk space.
**Why it happens:** Dead-letter tasks are stored for manual inspection but never automatically cleaned up.
**How to avoid:** Add a configurable TTL for dead-letter tasks (e.g., 30 days). Include cleanup in the periodic sweep. Alternatively, keep it simple and add a manual "purge dead-letter" API endpoint. At 4-5 agents, dead-letter volume is negligible.
**Warning signs:** `priv/task_dead_letter.dets` growing beyond a few MB.

### Pitfall 6: DETS 2GB Size Limit
**What goes wrong:** DETS files cannot exceed 2 GB. If the task queue somehow accumulates enough tasks, writes fail.
**Why it happens:** DETS has a hard 2 GB limit per file.
**How to avoid:** This is a non-issue at current scale. A task record is roughly 1-2 KB. 2 GB would hold ~1 million tasks. With 4-5 agents completing tasks every few minutes, this would take years to fill. Completed tasks should be trimmed from the main table after a retention period (e.g., keep last 1000 completed tasks for history, archive or delete the rest).
**Warning signs:** DETS file size approaching hundreds of MB.

### Pitfall 7: Task History List Growing Large
**What goes wrong:** The `history` list inside each task record grows with every status change. Tasks that are retried many times accumulate large histories.
**Why it happens:** History is a list of `{event, timestamp, details}` tuples appended on every state change.
**How to avoid:** Cap history at 50 entries per task. For most tasks, history will be 3-5 entries (queued -> assigned -> completed). Only heavily retried tasks approach even 20 entries. A cap of 50 provides safety without complexity.
**Warning signs:** Single task records exceeding 10 KB.

## Code Examples

Verified patterns from the existing codebase (adapted for task queue):

### GenServer Module Template (from existing codebase pattern)
```elixir
# Source: Derived from lib/agent_com/mailbox.ex and lib/agent_com/config.ex patterns
defmodule AgentCom.TaskQueue do
  @moduledoc """
  Persistent task queue with priority lanes, retry logic, and dead-letter storage.

  Tasks are stored in DETS and survive hub restarts. Priority ordering uses
  integer weights (0=urgent, 1=high, 2=normal, 3=low) with FIFO within
  each lane.

  Backed by two DETS tables:
  - `:task_queue` for active tasks (queued, assigned, completed)
  - `:task_dead_letter` for failed tasks that exhausted retries
  """
  use GenServer
  require Logger

  @tasks_table :task_queue
  @dead_letter_table :task_dead_letter
  @sweep_interval_ms 30_000
  @default_max_retries 3
  @priority_map %{"urgent" => 0, "high" => 1, "normal" => 2, "low" => 3}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Open DETS tables (follows mailbox.ex pattern)
    tasks_path = dets_path("task_queue.dets") |> String.to_charlist()
    dl_path = dets_path("task_dead_letter.dets") |> String.to_charlist()
    File.mkdir_p!(Path.dirname(dets_path("task_queue.dets")))

    {:ok, @tasks_table} = :dets.open_file(@tasks_table, [
      file: tasks_path, type: :set, auto_save: 5_000
    ])
    {:ok, @dead_letter_table} = :dets.open_file(@dead_letter_table, [
      file: dl_path, type: :set, auto_save: 5_000
    ])

    # Rebuild priority index from DETS
    priority_index = rebuild_priority_index()

    # Schedule overdue sweep
    Process.send_after(self(), :sweep_overdue, @sweep_interval_ms)

    {:ok, %{
      priority_index: priority_index,
      sweep_interval_ms: @sweep_interval_ms
    }}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@tasks_table)
    :dets.close(@dead_letter_table)
    :ok
  end

  # ... public API and handlers follow
end
```

### Task ID Generation (from existing auth.ex pattern)
```elixir
# Source: Consistent with lib/agent_com/auth.ex line 60 and endpoint.ex push-task
defp generate_task_id do
  "task-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
```

### Priority Index Rebuild on Startup
```elixir
# Source: Derived from mailbox.ex recover_seq pattern
defp rebuild_priority_index do
  :dets.select(@tasks_table, [
    {{:_, :"$1"}, [{:==, {:map_get, :status, :"$1"}, :queued}], [:"$1"]}
  ])
  |> Enum.map(fn task -> {task.priority, task.created_at, task.id} end)
  |> Enum.sort()
end
```

### Periodic Sweep (from existing Reaper pattern)
```elixir
# Source: Derived from lib/agent_com/reaper.ex sweep pattern
@impl true
def handle_info(:sweep_overdue, state) do
  now = System.system_time(:millisecond)

  # Find assigned tasks past deadline
  overdue = :dets.select(@tasks_table, [
    {{:_, :"$1"},
     [{:==, {:map_get, :status, :"$1"}, :assigned},
      {:"/=", {:map_get, :complete_by, :"$1"}, nil},
      {:<, {:map_get, :complete_by, :"$1"}, now}],
     [:"$1"]}
  ])

  new_state = Enum.reduce(overdue, state, fn task, acc ->
    Logger.warning("TaskQueue: reclaiming overdue task #{task.id} from #{task.assigned_to}")
    reclaim_task(task, acc)
  end)

  Process.send_after(self(), :sweep_overdue, state.sweep_interval_ms)
  {:noreply, new_state}
end
```

### PubSub Event Broadcasting (from existing Socket pattern)
```elixir
# Source: Consistent with lib/agent_com/socket.ex log_task_event pattern
defp broadcast_task_event(event, task) do
  Phoenix.PubSub.broadcast(AgentCom.PubSub, "tasks", {:task_event, %{
    event: event,
    task_id: task.id,
    task: task,
    timestamp: System.system_time(:millisecond)
  }})
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Admin push-task to connected agent (Phase 1) | Submit task to persistent queue, scheduler assigns (Phase 2+4) | Phase 2 (this phase) | Tasks survive disconnections; no manual agent targeting needed |
| Log-and-ack task messages in Socket (Phase 1 stub) | Socket delegates to TaskQueue for actual state management (Phase 2) | Phase 2 (this phase) | Hub becomes source of truth for task state, not just a relay |
| No retry semantics (Phase 1) | Configurable max_retries with dead-letter fallback (Phase 2) | Phase 2 (this phase) | Failed tasks get automatic retry; permanently failed tasks are preserved for inspection |
| No deadline enforcement (Phase 1) | complete_by deadline with periodic sweep reclamation (Phase 2) | Phase 2 (this phase) | Stuck tasks are automatically recovered instead of being lost |

**Deprecated/outdated:**
- The `POST /api/admin/push-task` endpoint (Phase 1) will be superseded by `POST /api/tasks` + Scheduler (Phase 4). The push-task endpoint should remain for backward compatibility but is no longer the primary task submission path.

## Integration Points

### With Phase 1 (Sidecar) -- Already Complete
The sidecar already sends these messages that Phase 2 needs to handle:
- `task_accepted` with `task_id` -- TaskQueue marks task as `:assigned` (acknowledged by agent)
- `task_progress` with `task_id` -- Fire-and-forget, TaskQueue updates `updated_at` to prevent overdue sweep
- `task_complete` with `task_id`, `result` -- TaskQueue marks as `:completed`, stores result + tokens_used
- `task_failed` with `task_id`, `reason` -- TaskQueue handles retry or dead-letter
- `task_recovering` with `task_id` -- TaskQueue checks current state, responds with `task_continue` or `task_reassign`
- `task_rejected` with `task_id`, `reason` -- Sidecar rejected assignment (busy), TaskQueue re-queues

The sidecar also handles these responses:
- `task_assign` with `task_id`, `description`, `metadata`, `assigned_at` -- needs `generation` added
- `task_ack` with `task_id`, `status` -- no changes needed
- `task_reassign` with `task_id` -- no changes needed
- `task_continue` with `task_id` -- no changes needed

**Protocol change needed:** Add `generation` field to `task_assign` message. Add `generation` field to `task_complete` and `task_failed` messages from sidecar. The sidecar should echo back the generation it received. Update the sidecar to pass through this field.

### With Phase 3 (Agent State FSM) -- Future
Phase 3's FSM will check TaskQueue for assigned tasks when an agent's state initializes. The TaskQueue public API needs:
- `tasks_assigned_to(agent_id)` -- return all tasks currently assigned to an agent
- Event broadcasting on "tasks" PubSub topic for FSM state transitions

### With Phase 4 (Scheduler) -- Future
Phase 4's Scheduler will call TaskQueue to:
- `dequeue_next(opts)` -- get highest-priority queued task matching capabilities
- `assign_task(task_id, agent_id, complete_by)` -- assign a task with deadline
- Subscribe to "tasks" PubSub topic for task events

## Open Questions

1. **Should completed tasks remain in the main DETS table or be archived?**
   - What we know: DETS has a 2GB limit. Completed tasks accumulate.
   - What's unclear: Whether to keep completed tasks indefinitely (for history queries), trim after N days, or move to a separate archive table.
   - Recommendation: Keep completed tasks in the main table with a configurable retention (default 7 days, matching mailbox TTL). Include cleanup in the periodic sweep. This keeps the API simple (one table for all task queries) while preventing unbounded growth. At current scale, this is not urgent.

2. **Should the task_progress message update the task's updated_at timestamp to prevent overdue sweep?**
   - What we know: task_progress is fire-and-forget (no ack). It represents ongoing work.
   - What's unclear: Whether receiving progress should reset the overdue timer.
   - Recommendation: Yes -- update `updated_at` on progress to signal the task is still being worked on. The overdue sweep should check `updated_at` (not `assigned_at`) against `complete_by`. This prevents reclaiming tasks that are actively progressing.

3. **What default values for max_retries and complete_by?**
   - What we know: Requirements say "configurable max_retries" and "complete_by deadline."
   - What's unclear: Sensible defaults.
   - Recommendation: `max_retries: 3` (standard in most queue systems), `complete_by: nil` (no deadline by default; scheduler sets deadline on assignment in Phase 4). Tasks submitted without explicit deadline are never reclaimed by the overdue sweep.

4. **Should the existing push-task endpoint be modified or kept alongside the new task API?**
   - What we know: Push-task (Phase 1) bypasses the queue entirely. New API (Phase 2) goes through the queue.
   - What's unclear: Whether Phase 1's push-task behavior is still needed.
   - Recommendation: Keep push-task for backward compatibility and direct testing. Add the new queue-based API alongside it. Phase 4's scheduler will use the queue API. Document the distinction clearly.

## Sources

### Primary (HIGH confidence)
- Erlang DETS official documentation (https://www.erlang.org/doc/apps/stdlib/dets.html) -- sync/1 guarantees, auto_save defaults, 2GB limit, ordered_set absence, repair behavior
- AgentCom codebase -- direct examination of mailbox.ex, config.ex, message_history.ex, reaper.ex, socket.ex, endpoint.ex, application.ex, auth.ex, presence.ex (all DETS patterns, GenServer patterns, timer patterns, task protocol)
- Sidecar implementation -- direct examination of sidecar/index.js (task protocol, message format, generation handling)
- Phase 1 research and plans -- 01-RESEARCH.md, 01-02-PLAN.md, 01-02-SUMMARY.md (established protocol, design decisions)
- Codebase analysis docs -- ARCHITECTURE.md, STACK.md, CONVENTIONS.md, STRUCTURE.md (established patterns)

### Secondary (MEDIUM confidence)
- "Avoiding Data Loss with Elixir DETS" (https://learn-elixir.dev/blogs/avoiding-data-loss-with-elixir-dets) -- confirmed auto_save behavior, sync patterns, crash risk mitigation
- Erlang DETS limitations discussion (https://erlangforums.com/t/performance-ets-vs-dets-mnesia-for-infrequent-persistence-to-disk/3214) -- confirmed DETS performance characteristics vs ETS
- Fencing token pattern (https://www.systemdesignacademy.com/blog/how-to-implement-idempotent-operations-beyond-the-basics) -- confirmed generation-based fencing as standard distributed systems pattern

### Tertiary (LOW confidence)
- None -- all findings verified against official docs or codebase

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- zero new dependencies; everything is OTP built-in or already in project
- Architecture: HIGH -- all patterns derived from existing codebase modules; 6 existing DETS-backed GenServers to reference
- Pitfalls: HIGH -- DETS behavior well-documented in official docs; fencing pattern is standard distributed systems knowledge; codebase patterns well-understood from direct examination
- Integration points: HIGH -- sidecar protocol directly examined; Phase 3/4 interfaces inferred from roadmap requirements

**Research date:** 2026-02-10
**Valid until:** 2026-03-10 (30 days -- stable domain, OTP is extremely mature)
