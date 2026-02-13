# Architecture: Hub FSM Autonomous Brain

**Domain:** Autonomous hub orchestration with LLM-powered goal decomposition, codebase self-improvement, pipeline DAG scheduling, and pre-publication cleanup for existing Elixir/BEAM distributed agent coordination system
**Researched:** 2026-02-12
**Confidence:** HIGH (grounded in direct analysis of all source files in shipped v1.2 codebase)

---

## Current System Inventory (Post-v1.2)

### Supervision Tree (23 children, :one_for_one)

```
AgentCom.Supervisor
  |-- Phoenix.PubSub
  |-- Registry (AgentCom.AgentRegistry)
  |-- AgentCom.Config
  |-- AgentCom.Auth
  |-- AgentCom.Mailbox
  |-- AgentCom.Channels
  |-- AgentCom.Presence
  |-- AgentCom.Analytics
  |-- AgentCom.Threads
  |-- AgentCom.MessageHistory
  |-- AgentCom.Reaper
  |-- Registry (AgentCom.AgentFSMRegistry)
  |-- AgentCom.AgentSupervisor (DynamicSupervisor for per-agent FSMs)
  |-- AgentCom.Verification.Store
  |-- AgentCom.TaskQueue
  |-- AgentCom.Scheduler
  |-- AgentCom.MetricsCollector
  |-- AgentCom.Alerter
  |-- AgentCom.RateLimiter.Sweeper
  |-- AgentCom.LlmRegistry
  |-- AgentCom.RepoRegistry
  |-- AgentCom.DashboardState
  |-- AgentCom.DashboardNotifier
  |-- AgentCom.DetsBackup
  |-- Bandit
```

### DETS Tables (10 tables, managed by DetsBackup)

| Table | Owner | Purpose |
|-------|-------|---------|
| :task_queue | TaskQueue | Active tasks (queued/assigned/completed) |
| :task_dead_letter | TaskQueue | Failed tasks exhausting retries |
| :agent_mailbox | Mailbox | Agent message storage |
| :message_history | MessageHistory | Historical messages |
| :agent_channels | Channels | Channel definitions |
| :channel_history | Channels | Channel message history |
| :agentcom_config | Config | Hub-wide key-value settings |
| :thread_messages | Threads | Thread data |
| :thread_replies | Threads | Thread reply data |
| :repo_registry | RepoRegistry | Priority-ordered repo list |

Plus non-backup-managed tables:
- :llm_registry (DETS, LlmRegistry -- endpoint registrations)
- :llm_resource_metrics (ETS, LlmRegistry -- ephemeral host metrics)
- :validation_backoff (ETS -- validation backoff tracking)
- :rate_limit_buckets (ETS -- token bucket state)
- :rate_limit_overrides (ETS -- per-agent overrides)
- verification_reports (DETS, Verification.Store -- unique atom per instance)

### PubSub Topics

| Topic | Publishers | Subscribers |
|-------|-----------|-------------|
| "tasks" | TaskQueue (7 events) | Scheduler |
| "presence" | AgentFSM (idle/joined/left) | Scheduler |
| "llm_registry" | LlmRegistry (endpoint_changed) | Scheduler |
| "repo_registry" | RepoRegistry (changed) | -- |
| "backups" | DetsBackup (backup/compaction/recovery) | DashboardNotifier |

### Key Existing Patterns

1. **DETS + sync for persistence** -- every mutation calls `:dets.sync/1`
2. **PubSub for event distribution** -- loose coupling, Scheduler reacts to events
3. **ETS for hot-path ephemeral data** -- metrics, rate limits, validation backoff
4. **GenServer for serialized state** -- each service owns its state
5. **DynamicSupervisor for per-connection processes** -- AgentFSM per agent
6. **Process.send_after for periodic work** -- sweeps, health checks, backup timers
7. **Hub decides, sidecar executes** -- routing decisions made centrally

---

## New Component: AgentCom.HubFSM

### Why a New GenServer

The Hub FSM is the "autonomous brain" of the system. It operates independently from the existing task pipeline, which is reactive (submit task -> schedule -> execute). The Hub FSM is proactive: it generates goals, decomposes them into tasks, monitors system state, and decides what work to do next.

This cannot be bolted onto an existing module because:
- **Scheduler** is reactive (event-driven matching). The Hub FSM is proactive (generates work).
- **TaskQueue** is a data store. The Hub FSM is a decision engine.
- **Config** is key-value storage. The Hub FSM maintains complex state (current phase, goal backlog, scan results).

### FSM State Machine Design

**Use GenServer, not GenStateMachine.** The existing codebase uses GenServer for all processes including the existing AgentFSM. GenStateMachine (gen_state_machine v3.0.0 on hex) wraps :gen_statem and provides state timeouts and state_enter callbacks, but the Hub FSM's 4 states are simple enough that GenServer with Process.send_after handles them cleanly. Adding a new dependency and a different OTP behaviour pattern would create cognitive overhead for a 4-state machine. The existing AgentFSM already demonstrates the pattern: store `fsm_state` as an atom in GenServer state, validate transitions explicitly.

**The four states:**

```
                    +--> Improving --+
                    |                |
  Executing <-------+                +-------> Contemplating
      ^             |                |              |
      |             +--> Resting <---+              |
      |                                             |
      +---------------------------------------------+
```

| State | Behavior | Transition Trigger |
|-------|----------|-------------------|
| **Executing** | Decompose top goal, submit tasks to TaskQueue, monitor completion | All goal's tasks completed OR all agents idle with empty queue |
| **Improving** | Run self-improvement scanner on repos, generate improvement tasks | Scan complete, improvement tasks submitted |
| **Contemplating** | Evaluate system state, prioritize goal backlog, decide next action | Decision made (which goal to execute next, or rest) |
| **Resting** | Idle timer. No work generation. Allows system to settle. | Timer expires (configurable, default 5 minutes) |

**Valid transitions:**

```elixir
@valid_transitions %{
  executing: [:contemplating, :resting],
  improving: [:contemplating, :resting],
  contemplating: [:executing, :improving, :resting],
  resting: [:contemplating]
}
```

**Rationale for transition rules:**
- Executing and Improving always go through Contemplating before choosing the next action. This prevents rapid oscillation between executing and improving without evaluation.
- Contemplating is the decision point. It can choose to execute a goal, run improvement scans, or rest.
- Resting always returns to Contemplating. It never directly starts work.

### GenServer State Structure

```elixir
defstruct [
  :fsm_state,           # :executing | :improving | :contemplating | :resting
  :current_goal_id,     # Goal being executed (nil when not executing)
  :rest_timer_ref,      # Process.send_after ref for rest -> contemplating
  :last_state_change,   # Timestamp
  :cycle_count,         # How many full loops completed
  :last_scan_at,        # When self-improvement last ran
  :paused,              # Manual pause flag (human override)
  :pause_reason,        # Why paused
  config: %{
    rest_duration_ms: 300_000,       # 5 minutes default
    scan_interval_ms: 3_600_000,     # 1 hour minimum between scans
    max_concurrent_goals: 1,         # Start with 1, can increase later
    auto_start: false                # Don't auto-start on hub boot
  }
]
```

### Placement in Supervision Tree

```
AgentCom.Supervisor (:one_for_one)
  |-- ...existing children...
  |-- AgentCom.RepoRegistry
  |-- AgentCom.GoalBacklog           # NEW -- before HubFSM
  |-- AgentCom.ClaudeClient          # NEW -- before HubFSM
  |-- AgentCom.SelfImprovement       # NEW -- before HubFSM
  |-- AgentCom.HubFSM               # NEW -- after all its dependencies
  |-- AgentCom.DashboardState
  |-- AgentCom.DashboardNotifier
  |-- AgentCom.DetsBackup
  |-- Bandit
```

**Placement rationale:**
- GoalBacklog before HubFSM because HubFSM reads/writes goals
- ClaudeClient before HubFSM because HubFSM calls Claude for decomposition
- SelfImprovement before HubFSM because HubFSM triggers scans
- HubFSM before DashboardState so dashboard can query HubFSM state
- All new GenServers before DetsBackup so their DETS tables get backed up

### Integration Points

| Existing Module | How HubFSM Integrates |
|----------------|----------------------|
| **TaskQueue** | HubFSM calls `TaskQueue.submit/1` to inject decomposed tasks. Subscribes to PubSub "tasks" to monitor completion of its goal's tasks. |
| **Scheduler** | No direct interaction. HubFSM submits tasks; Scheduler schedules them. Decoupled via TaskQueue + PubSub. |
| **AgentFSM** | HubFSM reads `AgentFSM.list_all/0` to check agent utilization during Contemplating state. No writes. |
| **RepoRegistry** | HubFSM reads `RepoRegistry.list_repos/0` to know which repos to scan for improvement. |
| **LlmRegistry** | HubFSM reads `LlmRegistry.list_endpoints/0` to understand available compute during Contemplating. |
| **Config** | HubFSM reads configuration (rest duration, scan interval) from Config. Stores runtime config there too. |
| **PubSub** | Subscribes to "tasks" (task completion), "presence" (agent availability). Publishes on "hub_fsm" (state changes for dashboard). |
| **DashboardState** | Dashboard queries HubFSM.snapshot/0 for current state, goal progress, cycle history. |
| **DetsBackup** | GoalBacklog DETS table added to DetsBackup's @tables list. |

### PubSub Events (new "hub_fsm" topic)

```elixir
# HubFSM publishes:
{:hub_fsm_event, %{event: :state_changed, from: :contemplating, to: :executing, goal_id: "goal-xxx"}}
{:hub_fsm_event, %{event: :goal_started, goal_id: "goal-xxx", task_count: 3}}
{:hub_fsm_event, %{event: :goal_completed, goal_id: "goal-xxx", results: %{}}}
{:hub_fsm_event, %{event: :scan_started, repos: ["repo1", "repo2"]}}
{:hub_fsm_event, %{event: :scan_complete, findings_count: 5}}
{:hub_fsm_event, %{event: :paused, reason: "manual"}}
{:hub_fsm_event, %{event: :resumed}}

# HubFSM subscribes to:
"tasks"     -- monitors :task_completed, :task_dead_letter for its goals' tasks
"presence"  -- monitors agent availability for scheduling decisions
```

---

## New Component: AgentCom.GoalBacklog

### Why a Separate GenServer (not TaskQueue extension)

Goals and tasks are fundamentally different entities:

| Aspect | Goal | Task |
|--------|------|------|
| Lifecycle | Created -> Decomposed -> Executing -> Completed/Failed | Queued -> Assigned -> Working -> Completed/Failed |
| Granularity | High-level objective ("Add authentication to API") | Atomic work unit ("Create auth plug module") |
| Decomposition | Contains sub-tasks (1:N relationship) | Atomic, no children |
| Priority | Strategic ordering, human-managed | Execution-time priority (urgent/high/normal/low) |
| Owner | HubFSM (proactive) | Any submitter (reactive) |
| Persistence | Survives across multiple execution cycles | Completed tasks are historical |

Cramming goals into TaskQueue would:
- Pollute TaskQueue's scheduling index with non-schedulable entities
- Require complex status filtering (is this a goal or a task?)
- Break TaskQueue's clean generation-fencing model (goals don't have generations)
- Mix two different priority systems (strategic ordering vs execution priority)

### State Design

```elixir
# DETS table: :goal_backlog
# Key: goal_id (string)
# Value: goal map

%{
  id: "goal-abc123",
  title: "Add rate limiting to Claude API calls",
  description: "Implement per-minute and per-hour rate limits...",
  status: :pending,            # :pending | :decomposing | :ready | :executing |
                               # :completed | :failed | :blocked
  priority: 0,                 # Lower = higher priority (same as task queue)
  source: :manual,             # :manual | :self_improvement | :llm_generated
  created_at: 1707660000000,
  created_by: "admin",         # or "hub_fsm" for auto-generated goals
  decomposition: nil,          # Populated after Claude decomposes
  task_ids: [],                # Task IDs created from this goal
  task_results: %{},           # task_id => :completed | :failed
  metadata: %{},               # Arbitrary context
  parent_goal_id: nil,         # For hierarchical goals (future)
  repo: "https://github.com/...",  # Target repo
  completed_at: nil,
  error: nil
}
```

**Decomposition structure** (populated by Claude):

```elixir
%{
  tasks: [
    %{
      description: "Create AgentCom.RateLimit.Claude module",
      priority: "normal",
      complexity_tier: "standard",
      repo: "https://github.com/...",
      file_hints: ["lib/agent_com/rate_limit/claude.ex"],
      success_criteria: ["Module compiles", "Tests pass"],
      verification_steps: [
        %{name: "compile", command: "mix compile", expect: "exit_0"},
        %{name: "test", command: "mix test test/rate_limit/claude_test.exs", expect: "exit_0"}
      ],
      depends_on: []            # Indices into this tasks list
    },
    # ...more tasks
  ],
  reasoning: "Split into 3 tasks because...",
  estimated_total_complexity: "standard",
  decomposed_at: 1707660100000
}
```

### Public API

```elixir
defmodule AgentCom.GoalBacklog do
  def add_goal(params)           # Add a new goal
  def get_goal(goal_id)          # Retrieve by ID
  def list_goals(opts \\ [])     # List with filters (status, source)
  def update_goal(goal_id, updates)  # Update fields
  def reorder(goal_id, new_position) # Change priority ordering
  def next_pending()             # Get highest-priority pending goal
  def mark_decomposed(goal_id, decomposition)
  def mark_executing(goal_id, task_ids)
  def mark_completed(goal_id)
  def mark_failed(goal_id, error)
  def record_task_result(goal_id, task_id, result)
  def snapshot()                 # Dashboard summary
  def stats()                    # Counts by status
end
```

### Persistence

DETS table `:goal_backlog`, same pattern as other DETS GenServers. Add to DetsBackup's @tables list. Priority ordering stored as an integer field (same pattern as TaskQueue).

---

## New Component: AgentCom.ClaudeClient

### Why a Separate GenServer

The Hub FSM needs to call the Claude Messages API directly from the Elixir hub for goal decomposition and self-improvement analysis. This is different from the sidecar's ClaudeExecutor (which shells out to `claude` CLI). The hub needs:

1. **Programmatic API access** -- structured JSON request/response, not CLI spawning
2. **Rate limiting** -- the hub must not exceed API rate limits across all its own calls
3. **Shared configuration** -- API key, default model, max tokens managed centrally
4. **Telemetry** -- track hub-side LLM usage separately from agent task execution

### Architecture Decision: GenServer with Req

**Use a dedicated GenServer wrapping the Req HTTP client.** Not a library like Anthropix because:

1. The hub makes ~10-50 Claude API calls per hour (goal decomposition, self-improvement analysis). This is low-volume, bursty work.
2. Anthropix (v0.6.2) uses Req internally, so we would be wrapping a wrapper. Direct Req usage gives full control over retries, timeouts, and error handling.
3. The GenServer serializes requests to enforce rate limiting. With only the hub making calls (not agents), a single process with a simple token bucket is sufficient.
4. Req needs to be added as a dependency anyway (it is not currently in mix.exs).

**Alternative considered and rejected:** Using the existing sidecar ClaudeExecutor pattern (spawn `claude` CLI). Rejected because: the hub is Elixir, spawning a Node.js CLI from Elixir adds unnecessary process management. Direct HTTP is simpler, faster, and more observable.

**Alternative considered and rejected:** No GenServer, just a module with functions that call Req directly. Rejected because: rate limiting state, API key management, and request queuing require process state.

### State Design

```elixir
defstruct [
  :api_key,
  :default_model,           # "claude-sonnet-4-5" or configurable
  :max_tokens,              # Default max output tokens
  :requests_this_minute,    # Simple counter for rate limiting
  :minute_reset_at,         # When to reset counter
  :total_input_tokens,      # Lifetime tracking
  :total_output_tokens,     # Lifetime tracking
  :total_requests           # Lifetime tracking
]
```

### Public API

```elixir
defmodule AgentCom.ClaudeClient do
  @doc "Send a messages request. Returns {:ok, response} or {:error, reason}."
  def chat(messages, opts \\ [])

  @doc "Convenience: single user message, get text response."
  def ask(prompt, opts \\ [])

  @doc "Structured output: ask Claude to respond in JSON matching a schema."
  def ask_json(prompt, schema_description, opts \\ [])

  @doc "Get usage statistics."
  def usage_stats()
end
```

### Rate Limiting Strategy

Simple counter per minute. The Claude API uses RPM (requests per minute), ITPM (input tokens per minute), and OTPM (output tokens per minute). For the hub's low volume, tracking RPM is sufficient:

```elixir
defp check_rate_limit(state) do
  now = System.system_time(:millisecond)
  if now >= state.minute_reset_at do
    # New minute window
    {:ok, %{state | requests_this_minute: 0, minute_reset_at: now + 60_000}}
  else
    if state.requests_this_minute >= max_rpm() do
      wait_ms = state.minute_reset_at - now
      {:rate_limited, wait_ms, state}
    else
      {:ok, state}
    end
  end
end
```

When rate limited, the GenServer returns `{:error, {:rate_limited, wait_ms}}`. Callers (HubFSM) handle backoff by scheduling a retry via Process.send_after.

### HTTP Client: Req

Add `{:req, "~> 0.5"}` to mix.exs. Req brings Finch (connection pooling) as a transitive dependency. This is appropriate now because:
- The hub is making real HTTP calls to the Claude API (not just :httpc health probes)
- Req provides built-in retry, JSON encoding/decoding, and error handling
- Finch provides connection pooling for keep-alive to api.anthropic.com

**No connection pooling tuning needed.** Default Finch pool (10 connections) is far more than the hub's ~1 request per minute average.

### Telemetry Events

```elixir
[:agent_com, :claude_client, :request]   # duration_ms, model, input_tokens, output_tokens
[:agent_com, :claude_client, :error]     # error_type, status_code
[:agent_com, :claude_client, :rate_limit] # wait_ms
```

---

## New Component: AgentCom.SelfImprovement

### Architecture

A library module (not a GenServer) called by HubFSM during the Improving state. Stateless analysis functions that return findings.

**Why not a GenServer:** Self-improvement scanning is triggered by HubFSM and runs synchronously within its context. There is no persistent state to maintain between scans. Results are returned to HubFSM, which decides what to do with them.

### Analysis Strategy: LLM-Based Code Review (not AST parsing)

**Use Claude to analyze code, not Elixir's AST parser or static analysis.** Rationale:

1. **AST parsing is limited to Elixir.** The codebase includes Node.js sidecar code, configuration files, and documentation. AST-based analysis would miss most of the codebase.
2. **Credo/Dialyzer already exist.** If we wanted static analysis, we would just run those tools. The self-improvement scanner should find higher-level issues: architectural concerns, missing error handling patterns, inconsistent conventions, documentation gaps, dead code.
3. **LLM analysis can reason about intent.** "This module duplicates logic from X" or "This error path silently swallows failures" requires understanding of the codebase, not just syntax.

### Scan Workflow

```
HubFSM enters :improving
  |
  v
SelfImprovement.scan(repos, claude_client)
  |
  | For each repo in RepoRegistry (active only):
  |   1. Git diff since last scan (or last N days)
  |   2. If no changes, skip repo
  |   3. Gather changed files + surrounding context
  |   4. Send to Claude with analysis prompt
  |   5. Parse structured response into findings
  |
  v
Returns: [%Finding{severity, category, file, description, suggested_fix}]
  |
  v
HubFSM filters findings by severity/category
  |
  v
High-severity findings -> GoalBacklog.add_goal()
Low-severity findings -> logged for dashboard visibility
```

### Scan Input Strategy

**Git diff analysis, not full codebase scan.** Scanning the entire codebase on every cycle would:
- Cost excessive Claude API tokens
- Produce repetitive findings
- Take too long (blocking HubFSM in Improving state)

Instead, scan only files changed since the last scan:

```elixir
defmodule AgentCom.SelfImprovement do
  @doc "Scan repos for improvement opportunities based on recent changes."
  def scan(repos, last_scan_at, claude_client) do
    repos
    |> Enum.filter(fn repo -> repo.status == :active end)
    |> Enum.flat_map(fn repo ->
      case get_changes_since(repo, last_scan_at) do
        {:ok, changes} when changes != [] ->
          analyze_changes(repo, changes, claude_client)
        _ ->
          []
      end
    end)
  end

  defp get_changes_since(repo, since_timestamp) do
    # Shell out to git diff --name-only --since=...
    # Returns list of changed file paths
  end

  defp analyze_changes(repo, changed_files, claude_client) do
    # Read file contents, build context, send to Claude
    # Parse response into Finding structs
  end
end
```

### Finding Structure

```elixir
%{
  id: "finding-abc123",
  repo: "https://github.com/...",
  severity: :high,              # :high | :medium | :low | :info
  category: :error_handling,    # :error_handling | :duplication | :convention |
                                # :documentation | :performance | :security | :dead_code
  file: "lib/agent_com/scheduler.ex",
  line_range: {258, 280},       # approximate
  description: "The try_schedule_all/2 function silently ignores...",
  suggested_fix: "Add explicit error handling for...",
  auto_goalable: true,          # Can this be converted to a goal automatically?
  found_at: 1707660000000
}
```

---

## Pipeline DAG Scheduling

### How DAG Awareness Changes the Existing Scheduler

The existing Scheduler is a **flat priority queue matcher**: it takes all queued tasks, sorts by priority, and matches each against idle agents. Tasks have no dependency relationships.

Pipeline DAG scheduling adds **dependency edges** between tasks within a goal. A task cannot be scheduled until all its dependencies are completed.

### Architecture Decision: Extend TaskQueue, Don't Replace Scheduler

The DAG is a property of goals, not of the scheduling algorithm. The Scheduler's matching logic (capability check, tier routing, endpoint selection) remains unchanged. What changes is **which tasks are eligible for scheduling**.

**Implementation:**

1. **Task struct extension:** Add `depends_on: [task_id]` and `goal_id: goal_id` fields to the task map in TaskQueue. These are optional (nil for tasks not part of a goal).

2. **Scheduling eligibility filter:** In Scheduler's `try_schedule_all/2`, after filtering paused repos, add a dependency check:

```elixir
# After filtering paused repos, filter out tasks with unmet dependencies
schedulable_tasks =
  schedulable_tasks
  |> Enum.filter(fn task ->
    deps = Map.get(task, :depends_on, [])
    deps == [] or Enum.all?(deps, fn dep_id ->
      case AgentCom.TaskQueue.get(dep_id) do
        {:ok, %{status: :completed}} -> true
        _ -> false
      end
    end)
  end)
```

3. **No DAG library needed.** The dependency structure is a simple list of predecessor task IDs per task. Topological ordering happens at decomposition time (ClaudeClient produces tasks in dependency order). The Scheduler only needs to check "are my predecessors completed?" -- a simple filter, not a graph traversal.

**Why not use the `dag` hex package:** The DAG is never traversed as a graph. Each task knows its predecessors. The check is O(d) where d is the number of dependencies per task (typically 0-3). A graph library adds complexity with no performance benefit.

### Pipeline State Tracking

Goals track their tasks and pipeline progress:

```elixir
# In GoalBacklog, when goal enters :executing:
%{
  goal_id: "goal-abc",
  task_ids: ["task-1", "task-2", "task-3"],
  dependency_graph: %{
    "task-2" => ["task-1"],      # task-2 depends on task-1
    "task-3" => ["task-1", "task-2"]  # task-3 depends on both
  },
  task_results: %{
    "task-1" => :completed,
    "task-2" => :executing,
    "task-3" => :blocked          # Waiting on task-2
  }
}
```

HubFSM monitors task completion events and updates goal progress. When a dependency-predecessor completes, its dependents become eligible for scheduling (they are already in TaskQueue with status :queued, the Scheduler's dependency filter now lets them through).

---

## Data Flow: Complete Goal-to-Completion Pipeline

```
1. GOAL CREATION
   Manual: POST /api/goals {title, description, repo}
   Auto:   SelfImprovement finding -> GoalBacklog.add_goal()
     |
     v
   GoalBacklog stores goal with status: :pending
   PubSub broadcast {:hub_fsm_event, :goal_added}

2. CONTEMPLATION (HubFSM in :contemplating)
   HubFSM.contemplate():
     - Read GoalBacklog.next_pending()
     - Read AgentFSM.list_all() -- how many agents idle?
     - Read LlmRegistry.list_endpoints() -- compute available?
     - Read TaskQueue.stats() -- queue depth?
     - Decision: execute goal, scan for improvements, or rest
     |
     v
   Transition to :executing, :improving, or :resting

3. GOAL DECOMPOSITION (HubFSM enters :executing)
   HubFSM.start_execution(goal_id):
     - GoalBacklog.get_goal(goal_id)
     - ClaudeClient.ask_json(decomposition_prompt, schema)
       |
       | Claude API call: "Decompose this goal into tasks..."
       | Input: goal description, repo context, codebase structure
       | Output: structured task list with dependencies
       |
     - GoalBacklog.mark_decomposed(goal_id, decomposition)
     |
     v
   For each task in decomposition.tasks:
     TaskQueue.submit(%{
       description: task.description,
       priority: task.priority,
       repo: goal.repo,
       depends_on: [resolved_task_ids],  # Map decomposition indices to real IDs
       goal_id: goal_id,
       file_hints: task.file_hints,
       success_criteria: task.success_criteria,
       verification_steps: task.verification_steps,
       complexity_tier: task.complexity_tier
     })
     |
     v
   GoalBacklog.mark_executing(goal_id, task_ids)
   PubSub {:hub_fsm_event, :goal_started}

4. TASK SCHEDULING (Existing pipeline, minimal changes)
   TaskQueue broadcasts :task_submitted
     |
     v
   Scheduler.try_schedule_all()
     - Filter paused repos (existing)
     - Filter unmet dependencies (NEW)
     - Capability match (existing)
     - Tier routing (existing)
     - Assign to agent (existing)
     |
     v
   Socket pushes task_assign to sidecar (existing)
   Sidecar executes (existing 3-executor architecture)

5. COMPLETION MONITORING (HubFSM subscribes to "tasks")
   HubFSM.handle_info({:task_event, %{event: :task_completed, task_id: tid}})
     - GoalBacklog.record_task_result(goal_id, tid, :completed)
     - Check: all goal tasks completed?
       YES -> GoalBacklog.mark_completed(goal_id)
              HubFSM transitions to :contemplating
       NO  -> Continue monitoring

   HubFSM.handle_info({:task_event, %{event: :task_dead_letter, task_id: tid}})
     - GoalBacklog.record_task_result(goal_id, tid, :failed)
     - Policy: one failed task fails the goal? Or continue with others?
     - Default: continue with independent tasks, mark goal :partial on completion

6. VERIFICATION COMPLETION
   Existing self-verification loop in sidecar handles task-level verification.
   HubFSM adds goal-level verification: after all tasks complete, optionally
   run a validation check (e.g., full test suite on repo).
```

---

## Pre-Publication Repo Cleanup

### Architecture

A library module `AgentCom.RepoCleanup` called by HubFSM before or after goal execution. Performs mechanical cleanup operations:

1. **Merge stale branches** -- branches with merged PRs that weren't deleted
2. **Delete dead branches** -- branches with no recent commits and no open PR
3. **Clean build artifacts** -- `_build/`, `node_modules/`, `deps/` in DETS data dirs
4. **DETS compaction** -- trigger DetsBackup.compact_all() during quiet periods
5. **Log rotation** -- prune old log files beyond retention policy

This is NOT an LLM task. These are mechanical git and filesystem operations that can be scripted deterministically.

### Integration

HubFSM calls `RepoCleanup.run(repos)` during the Resting or Contemplating state. Results are logged. Cleanup failures don't affect FSM state transitions.

---

## Updated Supervision Tree (Post-v1.3)

```
AgentCom.Supervisor (:one_for_one)
  |-- Phoenix.PubSub
  |-- Registry (AgentCom.AgentRegistry)
  |-- AgentCom.Config
  |-- AgentCom.Auth
  |-- AgentCom.Mailbox
  |-- AgentCom.Channels
  |-- AgentCom.Presence
  |-- AgentCom.Analytics
  |-- AgentCom.Threads
  |-- AgentCom.MessageHistory
  |-- AgentCom.Reaper
  |-- Registry (AgentCom.AgentFSMRegistry)
  |-- AgentCom.AgentSupervisor
  |-- AgentCom.Verification.Store
  |-- AgentCom.TaskQueue                    # MODIFIED (depends_on, goal_id fields)
  |-- AgentCom.Scheduler                    # MODIFIED (dependency filter)
  |-- AgentCom.MetricsCollector
  |-- AgentCom.Alerter
  |-- AgentCom.RateLimiter.Sweeper
  |-- AgentCom.LlmRegistry
  |-- AgentCom.RepoRegistry
  |-- AgentCom.GoalBacklog                  # NEW
  |-- AgentCom.ClaudeClient                 # NEW
  |-- AgentCom.HubFSM                      # NEW (depends on GoalBacklog, ClaudeClient,
  |                                        #   TaskQueue, Scheduler, RepoRegistry, Config)
  |-- AgentCom.DashboardState               # MODIFIED (includes HubFSM state)
  |-- AgentCom.DashboardNotifier
  |-- AgentCom.DetsBackup                   # MODIFIED (adds :goal_backlog table)
  |-- Bandit
```

---

## Integration Matrix

### New Components (build from scratch)

| Component | Type | Location | Lines (est.) | Depends On |
|-----------|------|----------|-------------|------------|
| **HubFSM** | GenServer | lib/agent_com/hub_fsm.ex | ~400 | GoalBacklog, ClaudeClient, TaskQueue, RepoRegistry, Config, PubSub |
| **GoalBacklog** | GenServer | lib/agent_com/goal_backlog.ex | ~250 | DETS, PubSub |
| **ClaudeClient** | GenServer | lib/agent_com/claude_client.ex | ~300 | Req (new dep), Config |
| **SelfImprovement** | Module | lib/agent_com/self_improvement.ex | ~200 | ClaudeClient, RepoRegistry, git (shell) |
| **RepoCleanup** | Module | lib/agent_com/repo_cleanup.ex | ~150 | RepoRegistry, git (shell) |

### Modified Components

| Component | File | Change Summary | Risk |
|-----------|------|----------------|------|
| **TaskQueue** | task_queue.ex | +2 optional fields (depends_on, goal_id) in submit. Nil defaults. | LOW |
| **Scheduler** | scheduler.ex | Add dependency filter in try_schedule_all after repo filter. ~15 lines. | LOW |
| **DetsBackup** | dets_backup.ex | Add :goal_backlog to @tables. Add table_owner clause. | LOW |
| **DashboardState** | dashboard_state.ex | Include HubFSM.snapshot() in state aggregation. | LOW |
| **Application** | application.ex | Add 3 new children (GoalBacklog, ClaudeClient, HubFSM). | LOW |
| **Endpoint/Router** | endpoint.ex, router.ex | Add /api/goals CRUD routes, /api/hub-fsm status endpoint. | LOW |
| **Telemetry** | telemetry.ex | Add claude_client and hub_fsm event handlers. | LOW |
| **mix.exs** | mix.exs | Add {:req, "~> 0.5"} dependency. | LOW |

---

## Patterns to Follow

### Pattern 1: HubFSM as Orchestrator, Not Executor

The HubFSM never executes tasks directly. It creates goals, decomposes them into tasks via Claude, submits tasks to TaskQueue, and monitors completion via PubSub. This preserves the existing task pipeline's integrity and means all tasks (whether human-submitted or HubFSM-generated) flow through the same scheduling, routing, and verification infrastructure.

### Pattern 2: Process.send_after for State Timeouts

```elixir
# Entering :resting state
defp enter_resting(state) do
  timer_ref = Process.send_after(self(), :rest_complete, state.config.rest_duration_ms)
  %{state | fsm_state: :resting, rest_timer_ref: timer_ref}
end

# Timer fires
def handle_info(:rest_complete, state) do
  {:noreply, transition(state, :contemplating)}
end
```

This matches the existing codebase pattern (Scheduler uses Process.send_after for stuck sweep and TTL sweep, TaskQueue for overdue sweep, LlmRegistry for health checks).

### Pattern 3: Manual Pause Override

```elixir
def pause(reason \\ "manual") do
  GenServer.call(__MODULE__, {:pause, reason})
end

def resume() do
  GenServer.call(__MODULE__, :resume)
end

# In any state handler, check paused first:
defp maybe_act(state) do
  if state.paused do
    {:noreply, state}  # Do nothing while paused
  else
    do_act(state)
  end
end
```

The human (Nathan) must always be able to pause the autonomous brain. This is a safety valve, not a normal operation.

### Pattern 4: Goal-Task Linking via goal_id

Tasks submitted by HubFSM carry a `goal_id` field. This enables:
- HubFSM filtering task events to only its goals' tasks
- Dashboard showing goal progress (X of Y tasks completed)
- GoalBacklog tracking which tasks belong to which goal
- No modification to existing task lifecycle (goal_id is just metadata)

### Pattern 5: Idempotent State Transitions

```elixir
defp transition(state, to) do
  from = state.fsm_state
  allowed = Map.get(@valid_transitions, from, [])

  if to in allowed do
    now = System.system_time(:millisecond)
    broadcast_state_change(from, to)
    %{state | fsm_state: to, last_state_change: now}
  else
    Logger.warning("hub_fsm_invalid_transition", from: from, to: to)
    state  # Return unchanged state, don't crash
  end
end
```

Invalid transitions are logged and ignored, not crashes. This matches AgentFSM's existing pattern.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: HubFSM Bypassing TaskQueue

The HubFSM must NOT directly assign tasks to agents or communicate with sidecars. All task submission goes through `TaskQueue.submit/1`. All scheduling goes through `Scheduler`. This ensures generation fencing, priority ordering, capability matching, and verification all apply equally to HubFSM-generated tasks.

### Anti-Pattern 2: Synchronous Claude Calls in GenServer Callbacks

Claude API calls take 5-30 seconds. Making them in `handle_call` or `handle_info` blocks the HubFSM GenServer, preventing it from handling pause requests, state queries, or PubSub events.

**Solution:** Use `Task.async` for Claude calls, handle results via `handle_info`:

```elixir
def handle_info(:start_decomposition, state) do
  goal = GoalBacklog.get_goal(state.current_goal_id)
  task = Task.async(fn -> ClaudeClient.ask_json(build_prompt(goal), schema()) end)
  {:noreply, %{state | pending_decomposition: task.ref}}
end

def handle_info({ref, result}, %{pending_decomposition: ref} = state) do
  Process.demonitor(ref, [:flush])
  handle_decomposition_result(result, state)
end
```

### Anti-Pattern 3: Full Codebase Scan Every Cycle

Scanning every file in every repo on every improvement cycle wastes Claude API tokens and time. Use git diff to identify changes since the last scan, and only analyze changed files plus their immediate dependencies.

### Anti-Pattern 4: Goals That Generate Goals Recursively

A self-improvement finding should not trigger a goal that triggers another scan that finds more issues. Limit: one level of auto-generation. Self-improvement findings create goals with `source: :self_improvement`. Goals with this source do NOT trigger additional scans on completion. Only `:manual` goals can trigger the full improvement cycle.

### Anti-Pattern 5: HubFSM State in ETS

The HubFSM's state is low-read, low-write. Dashboard queries it once per refresh (~5s). There is no hot-path reason to use ETS. Keep state in the GenServer process. GoalBacklog uses DETS because goals must survive restarts. HubFSM's transient state (which state am I in, what timer is running) is reconstructed from GoalBacklog on restart.

---

## Restart and Recovery

### HubFSM Recovery on Hub Restart

When the hub restarts, HubFSM starts in :resting state (safe default, configurable via `auto_start`). It then:

1. Reads GoalBacklog for any goals with status :executing
2. If found, checks TaskQueue for those goals' tasks
3. If tasks are still queued/assigned, resumes monitoring (transition to :executing)
4. If all tasks completed/failed during downtime, marks goal accordingly, transitions to :contemplating

This is crash-safe because:
- GoalBacklog is DETS-persisted
- TaskQueue is DETS-persisted
- The only lost state is the in-memory timer ref (reconstructed)

### ClaudeClient Recovery

Stateless beyond usage counters. On restart, counters reset to 0 (usage is tracked per-session, not persisted). API key is read from config/environment.

---

## Build Order (Dependency-Constrained)

```
Phase 1: ClaudeClient
  New GenServer wrapping Req + Anthropic Messages API
  Add {:req, "~> 0.5"} to mix.exs
  Rate limiting, telemetry, usage tracking
  Tests: unit tests with mock HTTP
  |
  v
Phase 2: GoalBacklog
  New GenServer with DETS persistence
  CRUD operations, status lifecycle, priority ordering
  DetsBackup integration
  Tests: unit tests with DETS isolation
  |
  v
Phase 3: HubFSM Core
  4-state GenServer with transition logic
  PubSub subscriptions (tasks, presence)
  Process.send_after timers for resting
  Manual pause/resume
  Integration with GoalBacklog (read/write goals)
  Integration with ClaudeClient (decomposition)
  Integration with TaskQueue (submit tasks)
  |
  v
Phase 4: Pipeline Dependencies
  TaskQueue: add depends_on, goal_id fields
  Scheduler: add dependency filter
  HubFSM: dependency-aware task submission
  |
  v
Phase 5: Self-Improvement Scanner
  SelfImprovement module (git diff + Claude analysis)
  Wire into HubFSM :improving state
  |
  v
Phase 6: Repo Cleanup + Dashboard Integration
  RepoCleanup module
  Dashboard: HubFSM state, goal progress, cycle history
  API endpoints for goals and HubFSM control
  |
  v
Phase 7: Integration Testing
  End-to-end: goal -> decompose -> schedule -> execute -> verify -> complete
  Stress test: rapid goal submission, agent disconnects during goal execution
```

**Phase ordering rationale:**
- ClaudeClient first: HubFSM and SelfImprovement both depend on it
- GoalBacklog second: HubFSM reads/writes goals, cannot function without it
- HubFSM Core third: the orchestrator that ties everything together
- Pipeline Dependencies fourth: extending existing modules is lower risk when the new modules exist to test against
- Self-Improvement fifth: requires HubFSM + ClaudeClient working together
- Cleanup + Dashboard sixth: nice-to-have, not blocking core functionality
- Integration testing last: requires all components to exist

---

## Scalability Considerations

| Concern | At 5 agents (current) | At 20 agents | At 50 agents |
|---------|----------------------|-------------|-------------|
| Claude API calls (hub-side) | ~10-20/hour (decomposition + scans) | ~20-40/hour | ~30-60/hour |
| Goal decomposition latency | 5-15s per goal (Claude API round trip) | Same | Same |
| GoalBacklog DETS size | <100 goals, trivial | <500 goals, trivial | <2000 goals, still trivial |
| Dependency filter in Scheduler | O(t*d) where t=tasks, d=deps per task | Same | Monitor, but deps are typically 0-3 |
| Self-improvement scan cost | ~$0.10-0.50 per scan (diff-based) | Same per repo | More repos = more scans, but throttled by scan_interval_ms |
| HubFSM cycle rate | ~2-4 cycles/hour | Same (limited by agent throughput) | Same |

No architectural changes needed at realistic scale. The bottleneck is Claude API latency for decomposition and LLM inference time for task execution, not hub coordination overhead.

---

## Sources

### Primary (HIGH confidence)
- AgentCom v1.2 shipped codebase -- all source files in lib/agent_com/ and sidecar/ (direct analysis, 2026-02-12)
- [GenStateMachine v3.0.0 documentation](https://hexdocs.pm/gen_state_machine/GenStateMachine.html) -- evaluated and rejected in favor of GenServer
- [Anthropix v0.6.2 documentation](https://hexdocs.pm/anthropix/Anthropix.html) -- Elixir Claude API client using Req
- [Claude API Rate Limits](https://docs.claude.com/en/api/rate-limits) -- RPM, ITPM, OTPM rate limiting model

### Secondary (MEDIUM confidence)
- [State Timeouts with gen_statem (DockYard)](https://dockyard.com/blog/2020/01/31/state-timeouts-with-gen_statem) -- gen_statem timer patterns
- [GenServer periodic work patterns](https://hexdocs.pm/elixir/GenServer.html) -- Process.send_after for self-scheduling
- [Elixir DAG library (arjan/dag)](https://github.com/arjan/dag/) -- evaluated and rejected (simple dependency list sufficient)
- [Anthropic API pricing and tiers](https://www.aifreeapi.com/en/posts/claude-api-quota-tiers-limits) -- tier-based rate limit structure

### Tertiary (LOW confidence)
- [Runic DAG workflow library](https://github.com/zblanco/runic) -- alternative DAG approach (not adopted)
- [anthropic_community Elixir library](https://hexdocs.pm/anthropic_community/Anthropic.html) -- alternative Claude client (not adopted)

---

*Architecture research for: Hub FSM Autonomous Brain (v1.3) integration into AgentCom v1.2 system*
*Researched: 2026-02-12*
*Based on: shipped v1.2 codebase with 23+ supervision tree children, 10+ DETS tables, 22+ telemetry events*
