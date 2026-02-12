# Architecture: Smart Agent Pipeline Integration

**Domain:** LLM mesh routing, model-aware scheduling, and agent self-verification for existing Elixir/BEAM hub + Node.js sidecar system
**Researched:** 2026-02-12
**Confidence:** HIGH (grounded in direct analysis of all source files in the shipped v1.1 codebase)

---

## Current System Inventory (Post-v1.1)

The v1.1 hardening milestone shipped since the initial architecture research. The actual codebase now includes components that were only projected before. This updated architecture reflects the real system.

### Hub-Side Components (Elixir/BEAM)

| Module | Role | State Storage | v1.2 Extension Points |
|--------|------|--------------|----------------------|
| **Application** | Supervision tree root. Creates 3 ETS tables in start/2 before children. 22 children in :one_for_one. | N/A | Add LlmRegistry to children list before Scheduler |
| **TaskQueue** | DETS-backed queue. Priority index in memory. Generation fencing. Overdue sweep on timer. | DETS (:task_queue, :task_dead_letter) + in-memory sorted list | **Primary modification target.** Extend task struct with context, criteria, verification_steps, complexity, assigned_model, assigned_endpoint, verification_result. All additive with nil defaults. |
| **Scheduler** | Stateless event-driven matcher. Subscribes to PubSub "tasks" + "presence". Queries TaskQueue + AgentFSM per event. Capability-based subset matching. 30s stuck sweep. | No state (queries on demand) | **Primary logic modification.** Add ComplexityClassifier call. Add LlmRegistry query for model endpoint. Extend do_assign to include model routing in push_task payload. |
| **AgentFSM** | Per-agent :gen_server with lifecycle states (idle/assigned/working/blocked/offline). 60s acceptance timeout. Process-monitors WebSocket pid. | In-memory per-process | **No structural changes.** FSM transitions are model-agnostic. Verification happens in sidecar before task_complete arrives at hub. |
| **Socket** | WebSocket handler (WebSock behaviour). Handles 15 WS message types. Rate limiting via RateLimiter inline. Validation via Validation module. | Connection state (%__MODULE__{agent_id, identified, violation_count}) | Extend :push_task handler to pass enriched fields. Accept verification_result in task_complete result payload. |
| **Endpoint** | Plug.Router with 60+ routes. Auth via RequireAuth plug. Rate limiting via RateLimit plug. Validation via Validation module. | Stateless | Add LLM admin endpoints (4 new routes). Extend POST /api/tasks to accept new optional fields. Add validation schemas. |
| **Config** | DETS-backed KV store. Arbitrary key-value pairs. | DETS (:agentcom_config) | Store LLM config: default cloud model, health check interval, complexity classification patterns. Already supports this -- no code change needed. |
| **Validation** | Library module with Schemas submodule. 27 schemas (15 WS + 12 HTTP). Pattern matching + guards. Length limits. | N/A (pure functions) | Add schemas for new WS message fields and new HTTP endpoints. |
| **DetsBackup** | Manages 9 DETS tables. Daily backup, 3-backup retention, 6-hour compaction cycle, fragmentation threshold. Health metrics. | In-memory (backup history, compaction history) | Register new llm_endpoints.dets table for backup/compaction. |
| **MetricsCollector** | ETS-backed telemetry aggregation. 10s snapshot broadcast. 5m cleanup. 60s handler health check. | ETS (:agent_metrics) | Add model routing metrics: tasks by complexity tier, local vs cloud ratio, model endpoint health stats. |
| **Alerter** | 5 alert rules with configurable thresholds. 60s check interval. Dashboard integration. Cooldowns. | In-memory (active alerts, cooldowns) | Add alert rules: LLM endpoint unhealthy, high verification failure rate. |
| **RateLimiter** | ETS-backed token bucket. 3-tier classification (light/normal/heavy). Progressive backoff. Admin overrides. | ETS (:rate_limit_buckets, :rate_limit_overrides) | Add rate tier for new LLM admin endpoints. No structural changes. |
| **Telemetry** | 22 event types attached on app start. Logs all events via Logger.info. | N/A | Add events: llm.health_check, llm.endpoint_change, task.classify, task.verify. |
| **Presence** | In-memory agent tracker with PubSub broadcasts. | In-memory | No changes. |
| **DashboardState** | Aggregates system state for dashboard. | In-memory cache | Include LLM endpoint status in dashboard state. |

### Sidecar-Side Components (Node.js)

| Module | Role | v1.2 Extension Points |
|--------|------|-----------------------|
| **index.js (HubConnection)** | WebSocket relay. Task lifecycle. Heartbeat. Recovery. | **Primary modification.** handleTaskAssign: route via model-router before wake. handleResult: run verification before sendTaskComplete. |
| **index.js (wakeAgent)** | Launch agent process with configurable command. 3 retries. Confirmation timeout. | Modify to support model-specific wake commands. New interpolation variables. |
| **lib/queue.js** | Persistent queue state to queue.json. loadQueue/saveQueue. | No code change -- JSON serialization handles new fields automatically. |
| **lib/wake.js** | Wake command interpolation (${TASK_ID}, ${TASK_JSON}). execCommand wrapper. | Add ${MODEL}, ${MODEL_ENDPOINT}, ${COMPLEXITY} interpolation variables. |
| **lib/git-workflow.js** | Git branch/PR automation. | No changes -- model-agnostic. |
| **lib/log.js** | Structured JSON logging with levels. | No changes. |

---

## New Components

### Hub-Side: AgentCom.LlmRegistry (NEW GenServer)

**Responsibility:** Tracks Ollama instances across the Tailscale mesh. Periodic health checking. Model discovery. Single source of truth for which LLM endpoints are available.

**Why a new GenServer (not an extension of Config):**
- Endpoints need structured data (host, port, models list, health status, timestamps)
- Periodic health probing requires Process.send_after timer
- Atomic state transitions on health changes require GenServer semantics
- PubSub broadcasts when endpoint status changes (Scheduler reacts)
- Config KV store is for scalar values, not structured entity collections

**State design:**

```elixir
# GenServer state
%{
  endpoints: %{
    "nathan-desktop" => %{
      id: "nathan-desktop",
      host: "100.x.x.x",           # Tailscale IP
      port: 11434,
      models: ["qwen3:8b", "llama3:70b"],
      status: :healthy,             # :healthy | :degraded | :unreachable
      last_check: 1707660000000,
      last_response_ms: 245,
      consecutive_failures: 0,
      registered_at: 1707650000000,
      metadata: %{}                 # VRAM, GPU info, etc.
    }
  },
  check_interval_ms: 60_000         # From Config, default 60s
}
```

**Persistence:** DETS (priv/llm_endpoints.dets) for endpoint registrations. Health status is ephemeral (rebuilt on startup via health check sweep). This matches the existing pattern -- DETS for durable config, in-memory for transient state.

**Health check protocol:**

```
Every check_interval_ms (default 60s):
  For each registered endpoint:
    1. HTTP GET http://{host}:{port}/
       200 "Ollama is running" -> mark :healthy, reset consecutive_failures
       timeout (5s) or error  -> increment consecutive_failures
         consecutive_failures >= 3 -> mark :unreachable
         consecutive_failures < 3  -> mark :degraded

    2. HTTP GET http://{host}:{port}/api/tags
       Parse response -> update endpoint.models list
       Compare with previous -> broadcast :model_added/:model_removed if changed
```

**HTTP client:** Erlang's built-in :httpc. The hub makes ~5 health checks per minute. Adding Req would pull in Finch, Mint, NimblePool, NimbleOptions as transitive deps -- overkill for periodic probes. If the project later needs connection pooling or streaming, Req can be added then.

**Public API:**

```elixir
defmodule AgentCom.LlmRegistry do
  # CRUD
  def register_endpoint(id, host, port, opts \\ %{})
  def unregister_endpoint(endpoint_id)
  def list_endpoints()
  def get_endpoint(endpoint_id)

  # Model queries (used by Scheduler)
  def list_models()
  def get_endpoint_for_model(model_name)  # Returns healthy endpoint serving model
  def get_endpoints_for_model(model_name) # All endpoints serving model (for load spread)

  # Health
  def health_check_all()                  # Force immediate check cycle
  def get_health_summary()                # Aggregate health status

  # Admin
  def update_endpoint_metadata(endpoint_id, metadata)
end
```

**Integration points:**
- Supervision tree: Added to application.ex children list AFTER Config, BEFORE Scheduler
- DetsBackup: Register llm_endpoints.dets table (add to @tables list in dets_backup.ex)
- PubSub: Broadcasts on "llm" topic for endpoint status changes
- Scheduler: Queries get_endpoint_for_model/1 during assignment (cached state, no network call)
- Endpoint: 4 new admin HTTP routes
- Telemetry: Emits [:agent_com, :llm, :health_check] and [:agent_com, :llm, :endpoint_change]

---

### Hub-Side: AgentCom.ComplexityClassifier (NEW library module)

**Responsibility:** Classifies task complexity to drive model selection. Pure function module -- no GenServer, no state, no timer.

**Why not a GenServer:** Classification is a deterministic function of task data. No state to maintain. Serializing through a single process would add latency to every scheduling attempt for no benefit. The Scheduler calls `ComplexityClassifier.classify/1` inline.

**Classification tiers:**

| Tier | Meaning | Model Route |
|------|---------|-------------|
| :trivial | Zero LLM tokens needed. Git, file I/O, shell commands. | Sidecar handles directly |
| :simple | Single-step coding, small edits, documentation. | Local Ollama (fast, free) |
| :complex | Multi-file changes, architecture, debugging. | Cloud API (Claude, GPT-4) |
| :explicit_model | Submitter specified exact model. | Use specified model |

**Classification priority chain:**

```
1. task.metadata["complexity"]    -> explicit override by submitter
2. task.metadata["model"]         -> explicit model forces :explicit_model
3. task.metadata["trivial_ops"]   -> explicit trivial ops list = :trivial
4. Pattern match on description   -> regex heuristics
5. Default                        -> :complex (safe fallback)
```

**Why heuristic-based, not ML-based:** At 5 agents with <100 tasks/day, an ML classifier is unjustifiable complexity. Heuristics are transparent, debuggable, and tunable via Config. The submitter can always override via `metadata.complexity`. If heuristics prove insufficient, the module interface stays the same -- only the implementation changes.

---

### Sidecar: lib/model-router.js (NEW module)

**Responsibility:** Determines execution strategy for a task based on hub-assigned routing info.

```javascript
/**
 * Returns: { strategy: 'trivial' | 'local_llm' | 'cloud_llm' | 'wake_default', config: {...} }
 */
function routeTask(task, sidecarConfig) {
  // 1. Trivial: zero LLM tokens
  if (task.complexity === 'trivial' || task.metadata?.trivial_ops) {
    return { strategy: 'trivial', config: { ops: task.metadata?.trivial_ops || [] } };
  }

  // 2. Explicit model assigned by hub
  if (task.assigned_model) {
    const isLocal = task.assigned_model.startsWith('ollama/');
    if (isLocal && task.assigned_endpoint) {
      return {
        strategy: 'local_llm',
        config: {
          model: task.assigned_model.replace('ollama/', ''),
          endpoint: task.assigned_endpoint,
          api_url: `http://${task.assigned_endpoint.host}:${task.assigned_endpoint.port}`
        }
      };
    }
    return { strategy: 'cloud_llm', config: { model: task.assigned_model } };
  }

  // 3. Default: wake agent with existing command (backward compatible)
  return { strategy: 'wake_default', config: {} };
}
```

**Key principle:** The sidecar does NOT decide which model to use. The hub decides during scheduling and passes `assigned_model` + `assigned_endpoint` in the task_assign message. The sidecar only translates the assignment into an execution strategy.

---

### Sidecar: lib/trivial-executor.js (NEW module)

**Responsibility:** Execute zero-LLM-token tasks. Git operations, file I/O, shell commands.

**Security model:** Allowlist of permitted commands in sidecar config.json. Commands not in `trivial_execution.allowed_commands` are rejected. Working directory constrained to `trivial_execution.working_dir`.

**Interface:**

```javascript
/**
 * Returns: { status: 'success' | 'failure', output: [...results], reason?: string }
 */
async function executeTrivial(task, ops, config)
```

**Supported op types:** `shell`, `write_file`, `read_file`, `git`. Each executes sequentially. First failure aborts remaining ops.

---

### Sidecar: lib/verification.js (NEW module)

**Responsibility:** Run verification steps after task completion, before reporting to hub. Deterministic code (shell commands with exit code checks), not LLM judgment.

**Why sidecar-side, not hub-side:**
- Verification steps are shell commands (mix compile, mix test, file existence checks)
- They must run in the agent's working directory on the agent's machine
- The hub has no filesystem access to agent machines
- The sidecar already has execCommand infrastructure (lib/wake.js)

**Why deterministic verification, not LLM self-assessment:**
- LLM agents can hallucinate "all tests pass" without running tests
- Shell commands return factual results (exit codes, stdout/stderr)
- The verification module makes pass/fail decisions based on exit codes, not LLM judgment
- This aligns with the 2026 consensus: "verification-aware planning" with machine-checkable checks

**Interface:**

```javascript
/**
 * Returns: { passed: boolean, results: [...stepResults], summary: string }
 */
async function runVerification(task, verificationSteps)
```

**Verification is a gate, not a feedback loop.** If verification fails, the sidecar reports `task_failed` with the verification result. The hub's existing retry logic (TaskQueue.fail_task -> retry or dead-letter) handles the retry decision. This avoids building a second retry mechanism in the sidecar.

---

## Modified Components: Detailed Change Maps

### TaskQueue Changes

**File:** `lib/agent_com/task_queue.ex`
**Change type:** Schema extension (additive, backward compatible)

The task map in `handle_call({:submit, params}, ...)` grows with 8 new optional fields:

```elixir
# Additions to the task map in submit/1:
task = %{
  # ... all 18 existing fields unchanged ...

  # NEW: enriched context (optional)
  context: Map.get(params, :context, Map.get(params, "context", nil)),

  # NEW: success criteria (optional list)
  criteria: Map.get(params, :criteria, Map.get(params, "criteria", [])),

  # NEW: verification steps (optional list)
  verification_steps: Map.get(params, :verification_steps,
    Map.get(params, "verification_steps", [])),

  # NEW: model routing (set by classifier/scheduler, not submitter)
  complexity: nil,
  assigned_model: nil,
  assigned_endpoint: nil,

  # NEW: explicit model override from submitter
  model_override: Map.get(params, :model_override,
    Map.get(params, "model_override", nil)),

  # NEW: verification result (set on completion)
  verification_result: nil
}
```

**assign_task/3 changes:** After assigning, set `complexity`, `assigned_model`, `assigned_endpoint` on the task record based on Scheduler's routing decision.

**complete_task/3 changes:** Accept `verification_result` in result_params and store on the task record.

**DETS compatibility:** Existing tasks in DETS lack the new fields. `Map.get(task, :context, nil)` pattern handles this gracefully. No migration needed.

**Risk:** LOW. All changes are additive. Defaults are nil/empty. Existing code paths (submit without new fields, complete without verification_result) continue to work unchanged.

---

### Scheduler Changes

**File:** `lib/agent_com/scheduler.ex`
**Change type:** Logic extension (medium risk -- core scheduling path)

**Changes to try_schedule_all/1:**

After getting `queued_tasks` from TaskQueue, the Scheduler now checks:
1. Is the task classified? If not, classify inline.
2. What model does it need? Query LlmRegistry.

**Changes to do_match_loop/2:**

The matching logic extends from pure capability matching to:

```
1. Capability match (existing -- needed_capabilities subset of agent.capabilities)
2. If task.complexity == :trivial -> any idle agent with capabilities matches
3. If task.complexity == :simple ->
     a. Query LlmRegistry for healthy endpoint serving the needed model
     b. If no healthy endpoint -> skip (leave task queued for retry on next health check)
     c. Prefer agents on the same Tailscale node as the Ollama endpoint (locality)
4. If task.complexity == :complex -> any idle agent (cloud model, location irrelevant)
5. If task has model_override -> check LlmRegistry for that specific model
```

**Changes to do_assign/2:**

The push_task payload enrichment:

```elixir
# CURRENT:
task_data = %{
  task_id: assigned_task.id,
  description: assigned_task.description,
  metadata: assigned_task.metadata,
  generation: assigned_task.generation
}

# NEW:
task_data = %{
  task_id: assigned_task.id,
  description: assigned_task.description,
  metadata: assigned_task.metadata,
  generation: assigned_task.generation,
  # v1.2 enriched fields
  context: assigned_task.context,
  criteria: assigned_task.criteria,
  verification_steps: assigned_task.verification_steps,
  complexity: assigned_task.complexity,
  assigned_model: assigned_task.assigned_model,
  assigned_endpoint: assigned_task.assigned_endpoint
}
```

**Risk:** MEDIUM. The scheduling hot path changes. Mitigation: LlmRegistry queries are against cached GenServer state (zero network I/O in scheduler). ComplexityClassifier is a pure function (microsecond execution). Fallback: if LlmRegistry is unreachable or has no endpoints, fall back to existing behavior (assign to any capable agent, sidecar uses wake_default).

---

### Socket Changes

**File:** `lib/agent_com/socket.ex`
**Change type:** Payload extension (low risk)

**handle_info({:push_task, task})** -- Pass through new fields:

```elixir
push = %{
  "type" => "task_assign",
  "task_id" => task[:task_id],
  "description" => task[:description] || "",
  "metadata" => task[:metadata] || %{},
  "generation" => task[:generation] || 0,
  "assigned_at" => System.system_time(:millisecond),
  # v1.2 enriched fields (nil-safe)
  "context" => task[:context],
  "criteria" => task[:criteria],
  "verification_steps" => task[:verification_steps],
  "complexity" => task[:complexity] && to_string(task[:complexity]),
  "assigned_model" => task[:assigned_model],
  "assigned_endpoint" => task[:assigned_endpoint]
}
```

**handle_msg("task_complete")** -- Accept verification_result:

```elixir
# Add to the result_params passed to TaskQueue.complete_task:
verification_result: msg["verification_result"]
```

**Risk:** LOW. Additive fields only. Sidecars running v1.0 code ignore unknown fields in task_assign.

---

### Sidecar index.js Changes

**File:** `sidecar/index.js`
**Change type:** Flow branching (medium risk -- core task path)

**handleTaskAssign:** After persisting task and sending acceptance, route via model-router:

```javascript
// CURRENT flow:
//   persist -> accept -> git start-task -> wakeAgent

// NEW flow:
//   persist -> accept -> git start-task ->
//     routeTask(task, _config) ->
//       'trivial'     -> executeTrivialTask -> handleTrivialResult
//       'local_llm'   -> wakeAgentWithModel
//       'cloud_llm'   -> wakeAgentWithModel
//       'wake_default' -> wakeAgent (existing, unchanged)
```

**handleResult:** After reading result JSON, before sendTaskComplete:

```javascript
// CURRENT flow:
//   readResult -> gitSubmit -> sendTaskComplete

// NEW flow:
//   readResult ->
//     if task.verification_steps:
//       runVerification(task, task.verification_steps) ->
//         passed: true  -> gitSubmit -> sendTaskComplete({...result, verification: verResult})
//         passed: false -> sendTaskFailed('verification_failed: ' + summary)
//     else:
//       gitSubmit -> sendTaskComplete (existing, unchanged)
```

**Risk:** MEDIUM. Two branch points in the core task lifecycle. Mitigation: wake_default strategy preserves exact existing behavior. Verification only runs if verification_steps are present (empty list = no verification). Both new paths are independently testable.

---

## Data Flow: Complete v1.2 Pipeline

```
POST /api/tasks {description, priority, context, criteria, verification_steps, model_override}
  |
  v
Validation.validate_http(:post_task, params)          # Extended schema
  |
  v
TaskQueue.submit/1
  | Creates task with enriched fields (all new fields nil/empty by default)
  | ComplexityClassifier.classify(task) -> sets task.complexity
  | DETS persist
  | PubSub broadcast :task_submitted
  |
  v
Scheduler.handle_info({:task_event, %{event: :task_submitted}})
  | try_schedule_all(:task_submitted)
  | Get queued tasks + idle agents
  |
  | FOR EACH (task, agent) match candidate:
  |   1. Capability check (existing)
  |   2. Model routing:
  |      :trivial  -> no model needed, any capable agent
  |      :simple   -> LlmRegistry.get_endpoint_for_model(default_local_model)
  |                   prefer agent co-located with endpoint
  |      :complex  -> Config.get(:default_cloud_model), any capable agent
  |      :explicit -> LlmRegistry check for specific model
  |   3. If healthy endpoint found (or not needed): assign
  |      If no healthy endpoint: skip, leave queued
  |
  v
TaskQueue.assign_task/3
  | Updates: assigned_model, assigned_endpoint, complexity on task record
  | DETS persist, PubSub broadcast :task_assigned
  |
  v
Socket.handle_info({:push_task, task_data})
  | Sends enriched task_assign over WebSocket:
  | { type, task_id, description, metadata, generation, assigned_at,
  |   context, criteria, verification_steps, complexity,
  |   assigned_model, assigned_endpoint }
  |
  v
Sidecar: handleTaskAssign(msg)
  | Persist enriched task to queue.json
  | sendTaskAccepted(task_id)
  | git start-task (if repo_dir configured)
  |
  | model-router.routeTask(task, config) -> { strategy, config }
  |
  +--> strategy: 'trivial'
  |    trivial-executor.executeTrivial(task, ops, config)
  |    -> produces result directly (no LLM, no wake)
  |
  +--> strategy: 'local_llm'
  |    wakeAgentWithModel(task, { model, endpoint, api_url })
  |    -> e.g., "openclaw agent --model qwen3:8b --api-url http://100.x.x.x:11434 ..."
  |
  +--> strategy: 'cloud_llm'
  |    wakeAgentWithModel(task, { model })
  |    -> e.g., "openclaw agent --model claude-opus-4-6 ..."
  |
  +--> strategy: 'wake_default'
       wakeAgent(task) -- EXISTING behavior, fully backward compatible
  |
  v
Agent works... writes {task_id}.json to results dir
  |
  v
Sidecar: handleResult(taskId, filePath, hub)
  | Read result JSON
  |
  | IF task.verification_steps exist AND verification.enabled:
  |   verification.runVerification(task, task.verification_steps)
  |   |
  |   +--> passed: true
  |   |    git submit (if repo_dir)
  |   |    hub.sendTaskComplete(taskId, { ...result, verification_result })
  |   |
  |   +--> passed: false
  |        hub.sendTaskFailed(taskId, 'verification_failed: ' + summary)
  |        -> Hub retry/dead-letter logic handles it
  |
  | ELSE (no verification -- backward compatible):
  |   git submit + sendTaskComplete (existing behavior)
  |
  v
Socket.handle_msg("task_complete" or "task_failed")
  | TaskQueue.complete_task or fail_task (with verification_result stored)
  | AgentFSM state transition
  | PubSub broadcast -> Scheduler picks up next task
```

---

## WebSocket Protocol Extensions

### task_assign (hub -> sidecar) -- Extended

```json
{
  "type": "task_assign",
  "task_id": "task-abc123",
  "description": "Add health check to LlmRegistry",
  "metadata": {},
  "generation": 1,
  "assigned_at": 1707660000000,

  "context": {
    "repo": "AgentCom",
    "branch": "main",
    "related_files": ["lib/agent_com/llm_registry.ex"],
    "notes": "See ARCHITECTURE.md"
  },
  "criteria": [
    {"type": "file_exists", "path": "lib/agent_com/llm_registry.ex"},
    {"type": "test_passes", "command": "mix test test/llm_registry_test.exs"}
  ],
  "verification_steps": [
    {"name": "compile", "command": "mix compile --warnings-as-errors", "expect": "exit_0"},
    {"name": "tests", "command": "mix test test/llm_registry_test.exs", "expect": "exit_0"}
  ],
  "complexity": "simple",
  "assigned_model": "ollama/qwen3:8b",
  "assigned_endpoint": {"host": "100.64.0.1", "port": 11434}
}
```

All new fields are optional. Sidecars running v1.0 code ignore them. Protocol version stays at 1 (all changes additive).

### task_complete (sidecar -> hub) -- Extended

```json
{
  "type": "task_complete",
  "task_id": "task-abc123",
  "generation": 1,
  "result": {"status": "success", "output": "...", "pr_url": "..."},
  "tokens_used": 1250,
  "model_used": "ollama/qwen3:8b",
  "verification_result": {
    "passed": true,
    "results": [
      {"name": "compile", "passed": true, "exit_code": 0, "duration_ms": 3200},
      {"name": "tests", "passed": true, "exit_code": 0, "duration_ms": 8100}
    ],
    "summary": "all 2 verification steps passed"
  }
}
```

### task_failed with verification failure (sidecar -> hub)

```json
{
  "type": "task_failed",
  "task_id": "task-abc123",
  "generation": 1,
  "reason": "verification_failed",
  "verification_result": {
    "passed": false,
    "results": [
      {"name": "compile", "passed": true, "exit_code": 0, "duration_ms": 3200},
      {"name": "tests", "passed": false, "exit_code": 1, "duration_ms": 5400,
       "stderr": "1 test, 1 failure"}
    ],
    "summary": "1/2 steps failed"
  }
}
```

---

## Updated Supervision Tree

```
AgentCom.Supervisor (:one_for_one)
  |
  |-- Phoenix.PubSub (name: AgentCom.PubSub)
  |-- Registry (keys: :unique, name: AgentCom.AgentRegistry)
  |-- AgentCom.Config
  |-- AgentCom.Auth
  |-- AgentCom.Mailbox
  |-- AgentCom.Channels
  |-- AgentCom.Presence
  |-- AgentCom.Analytics
  |-- AgentCom.Threads
  |-- AgentCom.MessageHistory
  |-- AgentCom.Reaper
  |-- Registry (keys: :unique, name: AgentCom.AgentFSMRegistry)
  |-- AgentCom.AgentSupervisor
  |-- AgentCom.LlmRegistry                 # NEW -- after Config, before TaskQueue
  |-- AgentCom.TaskQueue                    # MODIFIED (enriched task struct)
  |-- AgentCom.Scheduler                    # MODIFIED (model-aware matching)
  |-- AgentCom.MetricsCollector
  |-- AgentCom.Alerter
  |-- AgentCom.RateLimiter.Sweeper
  |-- AgentCom.DashboardState
  |-- AgentCom.DashboardNotifier
  |-- AgentCom.DetsBackup
  |-- Bandit
```

**LlmRegistry placement rationale:**
- After Config (reads health check interval from Config)
- Before TaskQueue and Scheduler (Scheduler queries LlmRegistry during assignment)
- ComplexityClassifier is a pure function module, not in supervision tree

---

## Updated Sidecar Architecture

```
sidecar/
  index.js                    # MODIFIED: handleTaskAssign routes via model-router
  lib/
    queue.js                  # UNCHANGED (JSON serialization handles new fields)
    wake.js                   # MODIFIED: new interpolation variables
    git-workflow.js           # UNCHANGED
    log.js                    # UNCHANGED
    model-router.js           # NEW: routeTask() returns execution strategy
    trivial-executor.js       # NEW: executeTrivial() for zero-LLM tasks
    verification.js           # NEW: runVerification() against criteria
  config.json                 # MODIFIED: new optional fields
  test/
    model-router.test.js      # NEW
    trivial-executor.test.js  # NEW
    verification.test.js      # NEW
```

**Sidecar config.json additions (all optional, backward compatible):**

```json
{
  "model_wake_commands": {
    "ollama/*": "openclaw agent --model ${MODEL} --api-url ${MODEL_ENDPOINT} ...",
    "anthropic/*": "openclaw agent --model ${MODEL} ...",
    "default": "openclaw agent ..."
  },
  "trivial_execution": {
    "enabled": true,
    "allowed_commands": ["git", "cat", "ls", "echo", "test", "mkdir", "cp", "mv"],
    "working_dir": "/path/to/agent/repo"
  },
  "verification": {
    "enabled": true,
    "timeout_ms": 120000,
    "max_retries_on_failure": 1
  }
}
```

---

## Patterns to Follow

### Pattern 1: Additive Schema Evolution

All v1.2 changes add optional fields with nil/empty defaults. Existing DETS data, existing sidecars, existing API callers continue to work without modification. No data migration.

### Pattern 2: Hub Decides, Sidecar Executes

All routing decisions happen in the hub (LlmRegistry state, ComplexityClassifier logic, model selection in Scheduler). The sidecar receives explicit instructions (assigned_model, assigned_endpoint) and executes them. This avoids split-brain scenarios and keeps the sidecar as a thin relay.

### Pattern 3: Strategy Dispatch in Sidecar

The model-router returns a strategy object. handleTaskAssign dispatches on strategy type. Each strategy is independently testable. Adding a new strategy requires no changes to dispatch logic.

### Pattern 4: Verification as Gate, Not Feedback Loop

Verification is pass/fail. If it fails, the sidecar reports task_failed. The hub's existing retry logic handles retries. No new retry mechanism in the sidecar. This preserves the hub as single source of truth for task lifecycle.

### Pattern 5: No Network I/O in Scheduler Hot Path

LlmRegistry health-checks asynchronously on a timer. Scheduler reads cached state from LlmRegistry GenServer. Zero network calls during scheduling. If LlmRegistry is unavailable, scheduling falls back to existing behavior (ignore model routing, assign to any capable agent).

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Sidecar Making Model Decisions

The sidecar must NOT classify complexity or select models. Multiple sidecars making independent decisions leads to uncoordinated endpoint load, inconsistent classification, and inability to enforce cost policies from the hub.

### Anti-Pattern 2: Health Checking from Sidecars

N sidecars x M endpoints = N*M health checks per interval. No single source of truth. The hub's LlmRegistry is the sole health checker.

### Anti-Pattern 3: Storing Model Config in Sidecar Config

Adding a new Ollama instance would require updating every sidecar config. The hub's LlmRegistry is the single registry. Sidecars receive model+endpoint per task_assign message. Sidecar config only contains execution preferences (wake command templates, trivial execution config, verification config).

### Anti-Pattern 4: LLM Self-Assessment for Verification

The LLM agent must NOT judge whether its own work passes verification. Shell commands with exit codes are factual. LLM self-assessment is unreliable and can hallucinate success.

### Anti-Pattern 5: Blocking Health Checks on Scheduler Path

The Scheduler must NOT make synchronous HTTP calls to Ollama endpoints during scheduling. It reads cached state from LlmRegistry.

---

## Integration Matrix

### New Components (build from scratch)

| Component | Type | Location | Lines (est.) | Depends On |
|-----------|------|----------|-------------|------------|
| LlmRegistry | Elixir GenServer | lib/agent_com/llm_registry.ex | ~300 | Config, PubSub, :httpc, DETS |
| ComplexityClassifier | Elixir module | lib/agent_com/complexity_classifier.ex | ~100 | None (pure functions) |
| model-router.js | Node.js module | sidecar/lib/model-router.js | ~60 | None |
| trivial-executor.js | Node.js module | sidecar/lib/trivial-executor.js | ~100 | wake.js (execCommand) |
| verification.js | Node.js module | sidecar/lib/verification.js | ~120 | wake.js (execCommand) |

### Modified Components

| Component | File | Change Summary | Risk |
|-----------|------|----------------|------|
| TaskQueue | task_queue.ex | +8 optional fields in submit/1. Set model fields in assign_task/3. Store verification_result in complete_task/3. | LOW |
| Scheduler | scheduler.ex | ComplexityClassifier.classify/1 call. LlmRegistry query. Extended do_assign payload. Model-aware matching in do_match_loop. | MEDIUM |
| Socket | socket.ex | Pass enriched fields in :push_task handler. Accept verification_result in task_complete. | LOW |
| Endpoint | endpoint.ex | 4 new LLM admin routes. Extended POST /api/tasks schema. | LOW |
| Validation.Schemas | validation/schemas.ex | New fields in post_task schema. New schemas for LLM endpoints. | LOW |
| Sidecar index.js | index.js | handleTaskAssign routes via model-router. handleResult runs verification. | MEDIUM |
| Sidecar wake.js | lib/wake.js | Add ${MODEL}, ${MODEL_ENDPOINT}, ${COMPLEXITY} interpolation. | LOW |
| Application | application.ex | Add LlmRegistry to children list. | LOW |
| DetsBackup | dets_backup.ex | Add :llm_endpoints to @tables list. | LOW |
| Telemetry | telemetry.ex | Add 4 new event types for LLM operations. | LOW |
| MetricsCollector | metrics_collector.ex | Track model routing metrics in snapshot. | LOW |

---

## Build Order (Dependency-Constrained)

```
Phase 1: Enriched Task Format
  TaskQueue schema + Endpoint accepts new fields + Socket passes through
  ComplexityClassifier module (pure functions, independently testable)
  Validation schema updates
  |
  v
Phase 2: LLM Endpoint Registry
  LlmRegistry GenServer + DETS + health checking
  Admin HTTP endpoints (CRUD + health)
  DetsBackup integration
  Telemetry events
  |
  v
Phase 3: Model-Aware Scheduler
  Scheduler modifications (classify + route + assign)
  Wire ComplexityClassifier into task submit/schedule
  Wire LlmRegistry into scheduler assignment
  |
  v
Phase 4: Sidecar Model Routing
  model-router.js module
  wake.js interpolation variables
  index.js handleTaskAssign branching
  config.json schema extension
  |
  v
Phase 5: Sidecar Trivial Execution
  trivial-executor.js module
  Wire into model-router 'trivial' strategy
  |
  v
Phase 6: Self-Verification
  verification.js module
  Wire into index.js handleResult
  (Can be built in parallel with Phases 2-5 since it only touches completion path)
```

**Rationale:**
- Task format first: every other feature reads from it
- LlmRegistry second: Scheduler needs it for model routing
- Scheduler third: connects classification + registry into assignment flow
- Sidecar routing fourth: consumes hub decisions
- Trivial execution fifth: special case of routing
- Verification independent: only touches completion path, not assignment path

---

## Scalability Considerations

| Concern | At 5 agents (current) | At 20 agents | At 50 agents |
|---------|----------------------|-------------|-------------|
| LLM health checks | 3 endpoints x 1/min = 3 req/min | 10 endpoints x 1/min = 10 req/min | 20 endpoints x 1/min = 20 req/min |
| Complexity classification | ~50 tasks/day, microseconds each | ~200 tasks/day, trivial | ~500 tasks/day, still trivial |
| Model routing (Scheduler) | 1 LlmRegistry GenServer.call per assignment | Same, cached | Same, cached |
| DETS storage per task | +~500 bytes (context, criteria, verification) | Same per task | Monitor file sizes |
| Verification steps | 0-3 shell commands per task | Same | Same |
| Trivial execution | Near-instant, no LLM calls | Same | Same |

No architectural changes needed at realistic scale. The bottleneck is LLM inference time, not coordination overhead.

---

## Sources

### Primary (HIGH confidence)
- AgentCom v1.1 shipped codebase -- all source files in lib/agent_com/ and sidecar/ (direct analysis, 2026-02-12)
- [Ollama API documentation](https://github.com/ollama/ollama/blob/main/docs/api.md) -- GET / health check, GET /api/tags model listing, POST /api/chat, POST /api/generate
- [Ollama health check issue #1378](https://github.com/ollama/ollama/issues/1378) -- GET / returns "Ollama is running"
- [Ollama REST API reference](https://docs.ollama.com/api/introduction) -- endpoint documentation

### Secondary (MEDIUM confidence)
- [LLM routing architecture patterns (OpenRouter guide)](https://medium.com/@milesk_33/a-practical-guide-to-openrouter-unified-llm-apis-model-routing-and-real-world-use-d3c4c07ed170) -- reverse proxy and routing layer patterns
- [Complete Guide to LLM Routing (2026)](https://medium.com/@kamyashah2018/the-complete-guide-to-llm-routing-5-ai-gateways-transforming-production-ai-infrastructure-b5c68ee6d641) -- gateway architecture, routing strategies
- [LiteLLM proxy documentation](https://docs.litellm.ai/docs/simple_proxy) -- model routing, load balancing patterns
- [Self-Verification Prompting](https://learnprompting.org/docs/advanced/self_criticism/self_verification) -- verification patterns for LLM output
- [Agents at Work: 2026 Playbook](https://promptengineering.org/agents-at-work-the-2026-playbook-for-building-reliable-agentic-workflows/) -- verification-aware planning, machine-checkable acceptance criteria
- [Elixir GenServer health check polling pattern](https://lucapeppe31.medium.com/how-to-easily-create-a-healthcheck-endpoint-for-your-phoenix-app-the-elixir-way-d0eeb0b3a271) -- per-service GenServer with configurable interval

### Tertiary (LOW confidence)
- [NVIDIA LLM Router blueprint](https://github.com/NVIDIA-AI-Blueprints/llm-router) -- complexity-based model selection (ML approach, not adopted)
- [LLM Semantic Router (Red Hat)](https://developers.redhat.com/articles/2025/05/20/llm-semantic-router-intelligent-request-routing) -- semantic routing concepts

---

*Architecture research for: Smart Agent Pipeline (v1.2) integration into AgentCom v1.1-hardened system*
*Researched: 2026-02-12*
*Based on: shipped v1.1 codebase with 22 supervision tree children, 9 DETS tables, 22 telemetry events*
