# Architecture Patterns: Smart Agent Pipeline Integration

**Domain:** Distributed LLM routing, enriched tasks, model-aware scheduling, sidecar trivial execution, and agent self-verification for an existing Elixir/BEAM hub + Node.js sidecar system
**Researched:** 2026-02-11
**Confidence:** HIGH (grounded in direct codebase analysis of all 24 source files + Ollama API docs + LLM routing research)

---

## Current System Inventory

Before designing integration, every component and its extension points.

### Hub-Side GenServers (Elixir/BEAM)

| Module | Role | State | Extension Points for v1.2 |
|--------|------|-------|---------------------------|
| TaskQueue | DETS-backed queue with priority/retry/dead-letter | DETS + in-memory priority index | **Task struct**: add enriched fields (context, criteria, model, complexity, verification_steps). **submit/1**: accept new fields. **assign_task/3**: include model routing info in assignment. |
| Scheduler | Event-driven task-to-agent matcher | Stateless (queries TaskQueue + AgentFSM) | **try_schedule_all/0**: add model-aware matching. **do_assign/1**: include model endpoint in push_task payload. **agent_matches_task?/2**: extend beyond capability matching to include model availability. |
| AgentFSM | Per-agent state machine (idle/assigned/working/blocked/offline) | In-memory per-process | **No structural changes needed.** FSM transitions are model-agnostic. May add `verifying` state if verification is a distinct phase. |
| Socket | WebSocket protocol handler | Connection state (agent_id, identified) | **handle_info({:push_task, ...})**: extend task_assign payload with model, context, criteria, verification_steps. **handle_msg("task_complete")**: accept verification_result in result payload. |
| Config | DETS-backed KV store | DETS | **Store LLM endpoint registry data.** Already supports arbitrary key-value pairs. |
| Presence | In-memory agent tracker | In-memory map | **No changes.** Presence tracks connection state, not model state. |
| Analytics | ETS-based metrics | ETS | **Add model-related metrics**: track model used per task, tokens by model, local vs cloud ratio. |
| Endpoint | HTTP + WS routes | Stateless | **New admin endpoints**: GET /api/llm/endpoints, POST /api/llm/endpoints, DELETE /api/llm/endpoints/:id, GET /api/llm/health. |

### Sidecar-Side (Node.js)

| Module | Role | Extension Points for v1.2 |
|--------|------|---------------------------|
| index.js (HubConnection) | WebSocket relay + task lifecycle | **handleTaskAssign**: parse model/context/criteria from task_assign. Route to correct execution path (trivial/local-LLM/cloud-LLM). |
| index.js (wakeAgent) | Launches agent process | **Model-aware wake**: interpolate model endpoint into wake command. Different wake commands for local vs cloud models. |
| index.js (handleResult) | Processes task completion | **Verification**: run verification steps before reporting complete. Only sendTaskComplete if verification passes. |
| lib/queue.js | Persists queue state | **Extended task object**: store model, context, criteria, verification_steps in queue.json. |
| lib/wake.js | Wake command interpolation | **New variables**: ${MODEL}, ${MODEL_ENDPOINT}, ${COMPLEXITY}. |
| lib/git-workflow.js | Git branch/PR automation | **No changes needed.** Git workflow is model-agnostic. |

---

## Recommended Architecture

### New Components

Six new components integrate with the existing system. Three are hub-side (Elixir), three are sidecar-side (Node.js enhancements).

#### Hub-Side New Components

**1. AgentCom.LlmRegistry (NEW GenServer)**

Tracks Ollama instances across the Tailscale mesh. Each endpoint is a machine:port running Ollama with one or more models available.

```
AgentCom.LlmRegistry (NEW GenServer)
  |
  |-- register_endpoint(host, port, opts)    # Add an Ollama endpoint
  |-- unregister_endpoint(endpoint_id)       # Remove an endpoint
  |-- list_endpoints()                       # All registered endpoints
  |-- list_models()                          # All models across all endpoints
  |-- get_endpoint_for_model(model_name)     # Find healthy endpoint serving model
  |-- health_check_all()                     # Probe all endpoints
  |-- report_health(endpoint_id, status)     # Update health status
  |
  State stored in DETS (priv/llm_endpoints.dets):
    %{
      endpoint_id => %{
        id: "nathan-desktop",
        host: "100.x.x.x",          # Tailscale IP
        port: 11434,
        models: ["qwen3:8b", "llama3:70b"],
        status: :healthy | :degraded | :unreachable,
        last_check: timestamp,
        last_response_ms: 245,
        registered_at: timestamp,
        metadata: %{}                 # VRAM, GPU, etc.
      }
    }
```

**Why a GenServer and not Config KV:** Endpoints need structured data (host, port, models list, health status, last check time), periodic health probing (Process.send_after), and atomic state transitions. Config KV is for scalar values. A dedicated GenServer encapsulates the health-check timer, HTTP client calls to Ollama, and PubSub broadcasts when endpoint status changes.

**Health check protocol:**
```
Every 60 seconds (configurable via Config):
  For each registered endpoint:
    1. GET http://{host}:{port}/             # Ollama health check
       -> 200 "Ollama is running"            # Mark :healthy
       -> timeout/error                      # Mark :unreachable
    2. GET http://{host}:{port}/api/tags     # List available models
       -> Update endpoint.models list
       -> Compare with previous: broadcast model_added/model_removed events
```

**Integration with existing system:**
- Added to supervision tree in application.ex (before Scheduler)
- Registers with DetsManager for backup/compaction (when v1.1 DetsManager ships)
- Broadcasts to PubSub topic "llm" for Scheduler to react to endpoint changes
- Admin endpoints in endpoint.ex for CRUD operations

---

**2. AgentCom.ComplexityClassifier (NEW library module -- NOT a GenServer)**

Classifies tasks into complexity tiers based on heuristics. This is a pure function module, not a process. Called by the Scheduler during routing decisions.

```elixir
defmodule AgentCom.ComplexityClassifier do
  @moduledoc """
  Classifies task complexity to drive model selection.

  Tiers:
    :trivial   -> sidecar handles directly, zero LLM tokens
    :simple    -> local Ollama (Qwen3 8B or equivalent)
    :complex   -> cloud API (Claude, GPT-4, etc.)
  """

  @trivial_patterns [
    ~r/^(write|create|touch)\s+.*(file|output)/i,
    ~r/^git\s+(status|fetch|pull|checkout|add|commit|push)/i,
    ~r/^(check|read|cat|ls|dir)\s+/i,
    ~r/^echo\s+/i,
    ~r/^(copy|move|rename|delete|remove)\s+/i
  ]

  @doc """
  Classify a task based on description, metadata, and explicit overrides.

  Priority:
  1. Explicit metadata.complexity (submitter override)
  2. Explicit metadata.model (forces specific model = skip classification)
  3. metadata.trivial_ops list (zero-LLM shortcut)
  4. Heuristic pattern matching on description
  5. Default to :complex (safe fallback -- never accidentally run complex work on small model)
  """
  def classify(task) do
    cond do
      # Explicit override in metadata
      task.metadata["complexity"] ->
        normalize_complexity(task.metadata["complexity"])

      # Explicit model forces specific tier
      task.metadata["model"] ->
        :explicit_model

      # Trivial ops list in metadata
      is_list(task.metadata["trivial_ops"]) ->
        :trivial

      # Pattern matching on description
      matches_trivial?(task.description) ->
        :trivial

      # Short descriptions with simple verbs tend to be simple
      simple_task?(task.description) ->
        :simple

      # Default: complex (safe)
      true ->
        :complex
    end
  end
end
```

**Why a library module not a GenServer:** Classification is a pure function of the task data. No state to maintain. No timers. No subscriptions. A GenServer would serialize all classification through a single process for no reason. The Scheduler calls `ComplexityClassifier.classify/1` inline during scheduling.

**Why heuristic-based not ML-based:** At 5 agents with <100 tasks/day, an ML classifier is overkill. Heuristics are transparent, debuggable, and tunable via Config. The classification can be overridden per-task via `metadata.complexity` by the submitter. If heuristics prove insufficient at scale, they can be replaced with a model-based classifier later without changing the interface.

---

**3. Task Format Extension (modification to TaskQueue)**

The task struct grows with new optional fields. All existing tasks continue to work (new fields default to nil/empty).

```elixir
# CURRENT task struct (in TaskQueue.submit/1):
%{
  id: task_id,
  description: "...",
  metadata: %{},
  priority: 2,
  status: :queued,
  assigned_to: nil,
  generation: 0,
  retry_count: 0,
  max_retries: 3,
  needed_capabilities: [],
  result: nil,
  tokens_used: nil,
  ...
}

# ENRICHED task struct (v1.2 additions shown with # NEW):
%{
  id: task_id,
  description: "...",
  metadata: %{},
  priority: 2,
  status: :queued,
  assigned_to: nil,
  generation: 0,
  retry_count: 0,
  max_retries: 3,
  needed_capabilities: [],

  # NEW: Enriched context
  context: %{                           # NEW -- optional context block
    "repo" => "AgentCom",               # Working repository
    "branch" => "main",                 # Base branch
    "related_files" => ["lib/agent_com/scheduler.ex"],
    "depends_on" => ["task-abc123"],     # Task dependencies
    "notes" => "See ARCHITECTURE.md"    # Human notes
  },

  # NEW: Success criteria
  criteria: [                           # NEW -- list of checkable conditions
    %{"type" => "file_exists", "path" => "lib/agent_com/llm_registry.ex"},
    %{"type" => "test_passes", "command" => "mix test test/llm_registry_test.exs"},
    %{"type" => "no_warnings", "command" => "mix compile --warnings-as-errors"},
    %{"type" => "custom", "description" => "Module implements health_check/0"}
  ],

  # NEW: Verification steps (run by sidecar after task completion)
  verification_steps: [                 # NEW -- ordered list of verification commands
    %{"name" => "compile_check", "command" => "mix compile --warnings-as-errors", "expect" => "exit_0"},
    %{"name" => "test_run", "command" => "mix test test/llm_registry_test.exs", "expect" => "exit_0"},
    %{"name" => "file_check", "command" => "test -f lib/agent_com/llm_registry.ex", "expect" => "exit_0"}
  ],

  # NEW: Model routing
  complexity: :complex,                 # NEW -- :trivial | :simple | :complex (set by classifier)
  assigned_model: nil,                  # NEW -- model string set during assignment (e.g., "ollama/qwen3:8b")
  assigned_endpoint: nil,               # NEW -- endpoint ID set during assignment
  model_override: nil,                  # NEW -- explicit model from submitter (bypasses classifier)

  # NEW: Verification result
  verification_result: nil,             # NEW -- populated by sidecar after verification

  result: nil,
  tokens_used: nil,
  ...
}
```

**Backward compatibility:** All new fields default to nil or empty list. Existing task submission (POST /api/tasks with just `description`) continues to work. The Scheduler classifies tasks that lack explicit complexity. Sidecars that do not understand the new fields ignore them (they only read `task_id`, `description`, `metadata`, `generation`).

---

#### Sidecar-Side Enhancements

**4. Model Router (enhancement to sidecar index.js)**

A new module `lib/model-router.js` that the sidecar calls to determine how to execute a task.

```javascript
// lib/model-router.js

/**
 * Determine execution strategy for a task based on assigned model/complexity.
 *
 * Returns: { strategy: 'trivial' | 'local_llm' | 'cloud_llm' | 'wake_default', config: {...} }
 */
function routeTask(task, sidecarConfig) {
  // Strategy 1: Trivial execution (zero LLM tokens)
  if (task.complexity === 'trivial' || (task.metadata && task.metadata.trivial_ops)) {
    return {
      strategy: 'trivial',
      config: { ops: task.metadata.trivial_ops || inferTrivialOps(task.description) }
    };
  }

  // Strategy 2: Explicit model assigned by scheduler
  if (task.assigned_model) {
    const isLocal = task.assigned_model.startsWith('ollama/');
    if (isLocal && task.assigned_endpoint) {
      return {
        strategy: 'local_llm',
        config: {
          model: task.assigned_model.replace('ollama/', ''),
          endpoint: task.assigned_endpoint,  // { host, port }
          api_url: `http://${task.assigned_endpoint.host}:${task.assigned_endpoint.port}`
        }
      };
    }
    // Cloud model
    return {
      strategy: 'cloud_llm',
      config: { model: task.assigned_model }
    };
  }

  // Strategy 3: Default -- wake agent with existing wake_command
  return { strategy: 'wake_default', config: {} };
}
```

**Integration with existing sidecar:** `handleTaskAssign` in index.js calls `routeTask()` before deciding whether to call `wakeAgent()`, execute trivially, or call Ollama directly.

---

**5. Trivial Executor (new sidecar module)**

Handles zero-LLM-token tasks: git operations, file I/O, shell commands.

```javascript
// lib/trivial-executor.js

/**
 * Execute a trivial task without invoking any LLM.
 * Returns { status: 'success' | 'failure', output: string, reason?: string }
 */
async function executeTrivial(task, ops, config) {
  const results = [];

  for (const op of ops) {
    switch (op.type) {
      case 'shell':
        const result = await execCommand(op.command);
        results.push({ op: op.type, command: op.command, exit_code: result.code, stdout: result.stdout });
        if (result.code !== 0) return { status: 'failure', output: results, reason: `shell command failed: ${op.command}` };
        break;

      case 'write_file':
        fs.writeFileSync(op.path, op.content);
        results.push({ op: op.type, path: op.path });
        break;

      case 'read_file':
        const content = fs.readFileSync(op.path, 'utf8');
        results.push({ op: op.type, path: op.path, content });
        break;

      case 'git':
        const gitResult = await execCommand(`git ${op.args}`);
        results.push({ op: op.type, args: op.args, exit_code: gitResult.code, stdout: gitResult.stdout });
        break;

      default:
        return { status: 'failure', output: results, reason: `unknown op type: ${op.type}` };
    }
  }

  return { status: 'success', output: results };
}
```

---

**6. Self-Verification Runner (new sidecar module)**

Executes verification steps after task completion, before reporting to hub.

```javascript
// lib/verification.js

/**
 * Run verification steps against task criteria.
 * Returns { passed: boolean, results: [...], summary: string }
 */
async function runVerification(task, verificationSteps) {
  if (!verificationSteps || verificationSteps.length === 0) {
    return { passed: true, results: [], summary: 'no_verification_steps' };
  }

  const results = [];
  let allPassed = true;

  for (const step of verificationSteps) {
    const startTime = Date.now();
    let stepResult;

    try {
      const cmdResult = await execCommand(step.command);
      const passed = evaluateExpectation(step.expect, cmdResult);

      stepResult = {
        name: step.name,
        command: step.command,
        passed,
        exit_code: cmdResult.code,
        stdout: cmdResult.stdout.substring(0, 2000),  // Truncate
        stderr: cmdResult.stderr.substring(0, 2000),
        duration_ms: Date.now() - startTime
      };
    } catch (err) {
      stepResult = {
        name: step.name,
        command: step.command,
        passed: false,
        error: err.message,
        duration_ms: Date.now() - startTime
      };
    }

    results.push(stepResult);
    if (!stepResult.passed) allPassed = false;
  }

  return {
    passed: allPassed,
    results,
    summary: allPassed
      ? `all ${results.length} verification steps passed`
      : `${results.filter(r => !r.passed).length}/${results.length} steps failed`
  };
}

function evaluateExpectation(expect, cmdResult) {
  switch (expect) {
    case 'exit_0': return cmdResult.code === 0;
    case 'exit_nonzero': return cmdResult.code !== 0;
    case 'contains': return cmdResult.stdout.includes(expect.substring);
    default: return cmdResult.code === 0;  // Default: success = exit 0
  }
}
```

---

### Component Boundaries

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| **LlmRegistry** (NEW hub GenServer) | Tracks Ollama endpoints, health-checks them, serves model lookups | Scheduler (model routing queries), Endpoint (admin CRUD), Config (check interval), PubSub "llm" topic |
| **ComplexityClassifier** (NEW hub library) | Classifies task complexity for model routing | Scheduler (called inline), Config (pattern overrides) |
| **TaskQueue** (MODIFIED) | Stores enriched tasks with context, criteria, verification, model fields | Scheduler (reads tasks), Socket (receives results with verification), Endpoint (CRUD) |
| **Scheduler** (MODIFIED) | Model-aware task-to-agent matching with endpoint selection | TaskQueue, AgentFSM, LlmRegistry, ComplexityClassifier |
| **Socket** (MODIFIED) | Extended task_assign payload, verification results in task_complete | AgentFSM, TaskQueue, Scheduler |
| **Endpoint** (MODIFIED) | LLM admin endpoints, enriched task submission | LlmRegistry, TaskQueue |
| **model-router.js** (NEW sidecar module) | Routes tasks to trivial/local/cloud execution | index.js (called from handleTaskAssign) |
| **trivial-executor.js** (NEW sidecar module) | Zero-LLM-token task execution | model-router.js (called when strategy=trivial) |
| **verification.js** (NEW sidecar module) | Runs verification steps before reporting complete | index.js (called after task execution, before sendTaskComplete) |

---

### Data Flow Changes

#### Current Flow (v1.0): Task Submit -> Schedule -> Assign -> Wake -> Complete

```
POST /api/tasks {description, priority}
  |
  v
TaskQueue.submit/1 -> stores in DETS -> broadcasts :task_submitted
  |
  v
Scheduler.try_schedule_all/0
  | queries: TaskQueue.list(status: :queued) + AgentFSM.list_all()
  | matches: capability-based (needed_capabilities subset of agent.capabilities)
  |
  v
TaskQueue.assign_task/3 -> updates DETS -> broadcasts :task_assigned
  |
  v
Socket.handle_info({:push_task, ...})
  | sends: {"type":"task_assign", "task_id":..., "description":..., "metadata":..., "generation":...}
  |
  v
Sidecar.handleTaskAssign(msg)
  | persists to queue.json
  | sendTaskAccepted(task_id)
  | git start-task (if repo_dir configured)
  | wakeAgent(task) -- executes wake_command
  |
  v
Agent works... writes {task_id}.json to results dir
  |
  v
Sidecar.handleResult(taskId, filePath, hub)
  | reads result JSON
  | git submit (if repo_dir configured)
  | hub.sendTaskComplete(taskId, result)
  |
  v
Socket.handle_msg("task_complete")
  | TaskQueue.complete_task(task_id, generation, result_params)
  | AgentFSM.task_completed(agent_id)
  | broadcasts :task_completed -> triggers Scheduler for next task
```

#### New Flow (v1.2): Enriched Task -> Classify -> Model-Route -> Execute/Wake -> Verify -> Complete

```
POST /api/tasks {description, priority, context, criteria, verification_steps, model_override}
  |                                                                         # NEW FIELDS
  v
TaskQueue.submit/1
  | stores enriched task in DETS (new fields: context, criteria,
  |   verification_steps, model_override)
  | ComplexityClassifier.classify(task) -> sets task.complexity              # NEW
  | broadcasts :task_submitted
  |
  v
Scheduler.try_schedule_all/0
  | queries: TaskQueue.list(status: :queued) + AgentFSM.list_all()
  |
  | NEW MATCHING LOGIC:
  | 1. Capability match (existing)
  | 2. Complexity classification (already set on task)
  | 3. Model selection:
  |    - task.model_override? -> use it directly
  |    - :trivial -> no model needed (sidecar handles)
  |    - :simple -> LlmRegistry.get_endpoint_for_model("qwen3:8b")
  |    - :complex -> use cloud model (from Config, e.g., "anthropic/claude-opus-4-6")
  | 4. Agent selection:
  |    - :trivial/:simple -> prefer agent on same machine as Ollama endpoint
  |    - :complex -> any idle agent with matching capabilities
  |
  v
TaskQueue.assign_task/3
  | updates task: assigned_model, assigned_endpoint, complexity              # NEW
  | broadcasts :task_assigned
  |
  v
Socket.handle_info({:push_task, ...})
  | sends ENRICHED task_assign:                                              # MODIFIED
  | {
  |   "type": "task_assign",
  |   "task_id": "...",
  |   "description": "...",
  |   "metadata": {...},
  |   "generation": 1,
  |   "assigned_at": 1234567890,
  |   "context": {...},                    # NEW
  |   "criteria": [...],                   # NEW
  |   "verification_steps": [...],         # NEW
  |   "complexity": "simple",              # NEW
  |   "assigned_model": "ollama/qwen3:8b", # NEW
  |   "assigned_endpoint": {               # NEW
  |     "host": "100.x.x.x",
  |     "port": 11434
  |   }
  | }
  |
  v
Sidecar.handleTaskAssign(msg)
  | persists enriched task to queue.json
  | sendTaskAccepted(task_id)
  |
  | model-router.routeTask(task, config)                                     # NEW
  |   |
  |   |--> strategy: 'trivial'
  |   |     trivial-executor.executeTrivial(task, ops, config)
  |   |     -> skip wakeAgent entirely, produce result directly
  |   |
  |   |--> strategy: 'local_llm'
  |   |     wakeAgent with modified wake_command using Ollama endpoint
  |   |     e.g., "openclaw agent --model ollama/qwen3:8b --api-url http://100.x.x.x:11434 ..."
  |   |
  |   |--> strategy: 'cloud_llm'
  |   |     wakeAgent with cloud model in wake_command
  |   |     e.g., "openclaw agent --model anthropic/claude-opus-4-6 ..."
  |   |
  |   |--> strategy: 'wake_default'
  |         wakeAgent() with existing wake_command (backward compatible)
  |
  v
Agent works... writes {task_id}.json to results dir
  |
  v
Sidecar.handleResult(taskId, filePath, hub)                                  # MODIFIED
  | reads result JSON
  |
  | VERIFICATION (NEW):
  | if task has verification_steps:
  |   verification.runVerification(task, task.verification_steps)
  |   |
  |   |--> passed: true
  |   |     git submit (if repo_dir)
  |   |     hub.sendTaskComplete(taskId, { ...result, verification: verificationResult })
  |   |
  |   |--> passed: false
  |         log verification failure
  |         hub.sendTaskFailed(taskId, 'verification_failed: ' + summary)
  |         -> TaskQueue retries or dead-letters based on retry_count
  |
  | else (no verification_steps -- backward compatible):
  |   git submit + sendTaskComplete (existing behavior)
  |
  v
Socket.handle_msg("task_complete")
  | TaskQueue.complete_task(task_id, generation, {
  |   result: result,
  |   tokens_used: tokens_used,
  |   verification_result: verification_result                               # NEW
  | })
  | AgentFSM.task_completed(agent_id)
  | broadcasts :task_completed
```

---

### Updated Supervision Tree

```
AgentCom.Supervisor (:one_for_one)
  |
  |-- Phoenix.PubSub (name: AgentCom.PubSub)
  |-- Registry (name: AgentCom.AgentRegistry)
  |-- Registry (name: AgentCom.AgentFSMRegistry)
  |
  |-- AgentCom.Config                  # existing
  |-- AgentCom.Auth                    # existing
  |-- AgentCom.LlmRegistry            # NEW -- must start before Scheduler
  |-- AgentCom.Mailbox                 # existing
  |-- AgentCom.Channels               # existing
  |-- AgentCom.Presence               # existing
  |-- AgentCom.Analytics              # existing
  |-- AgentCom.Threads                # existing
  |-- AgentCom.MessageHistory          # existing
  |-- AgentCom.Reaper                  # existing
  |-- AgentCom.AgentSupervisor         # existing (DynamicSupervisor)
  |-- AgentCom.TaskQueue               # existing (MODIFIED: enriched task struct)
  |-- AgentCom.Scheduler               # existing (MODIFIED: model-aware matching)
  |-- AgentCom.DashboardState          # existing
  |-- AgentCom.DashboardNotifier       # existing
  |-- Bandit                           # existing
```

**Ordering rationale:**
- LlmRegistry starts after Config (reads health check interval from Config) and before Scheduler (Scheduler queries LlmRegistry for model endpoints)
- ComplexityClassifier is a library module, not in supervision tree
- All existing children unchanged in position

---

### Updated Sidecar Architecture

```
sidecar/
  index.js                    # MODIFIED: handleTaskAssign routes via model-router
  lib/
    queue.js                  # MODIFIED: extended task object in queue.json
    wake.js                   # MODIFIED: new interpolation variables (${MODEL}, ${MODEL_ENDPOINT})
    git-workflow.js           # UNCHANGED
    model-router.js           # NEW: routeTask() returns execution strategy
    trivial-executor.js       # NEW: executeTrivial() for zero-LLM tasks
    verification.js           # NEW: runVerification() against criteria
  config.json                 # MODIFIED: new optional fields
```

**Sidecar config.json additions:**

```json
{
  "agent_id": "my-agent",
  "token": "...",
  "hub_url": "ws://hub-hostname:4000/ws",
  "wake_command": "openclaw agent --message \"Task: ${TASK_JSON}\" --session-id ${TASK_ID}",
  "capabilities": ["code"],

  "model_wake_commands": {
    "ollama/*": "openclaw agent --model ${MODEL} --api-url ${MODEL_ENDPOINT} --message \"Task: ${TASK_JSON}\" --session-id ${TASK_ID}",
    "anthropic/*": "openclaw agent --model ${MODEL} --message \"Task: ${TASK_JSON}\" --session-id ${TASK_ID}",
    "default": "openclaw agent --message \"Task: ${TASK_JSON}\" --session-id ${TASK_ID}"
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

### WebSocket Protocol Extensions

#### Extended task_assign (hub -> sidecar)

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
    "notes": "See ARCHITECTURE.md for design"
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
  "assigned_endpoint": {
    "host": "100.64.0.1",
    "port": 11434
  }
}
```

#### Extended task_complete (sidecar -> hub)

```json
{
  "type": "task_complete",
  "task_id": "task-abc123",
  "generation": 1,
  "result": {
    "status": "success",
    "output": "LlmRegistry module created with health_check/0",
    "pr_url": "https://github.com/org/AgentCom/pull/42"
  },
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

#### Extended task_failed with verification failure (sidecar -> hub)

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
      {"name": "tests", "passed": false, "exit_code": 1, "duration_ms": 5400, "stderr": "1 test failed"}
    ],
    "summary": "1/2 steps failed"
  }
}
```

**Backward compatibility:** Sidecars running v1.0 code ignore unknown fields in task_assign. Hub accepts task_complete without verification_result (existing behavior). Protocol version remains 1 because all changes are additive.

---

## Patterns to Follow

### Pattern 1: Additive Schema Evolution

**What:** Add new optional fields to existing data structures rather than breaking the schema.

**When:** Every v1.2 change touches existing data (task struct, WebSocket messages, sidecar config).

**Example:**
```elixir
# TaskQueue.submit/1 -- add new fields with defaults
task = %{
  # ... existing fields unchanged ...

  # NEW fields with safe defaults
  context: Map.get(params, :context, Map.get(params, "context", nil)),
  criteria: Map.get(params, :criteria, Map.get(params, "criteria", [])),
  verification_steps: Map.get(params, :verification_steps, Map.get(params, "verification_steps", [])),
  complexity: nil,           # Set by ComplexityClassifier after creation
  assigned_model: nil,       # Set during assignment
  assigned_endpoint: nil,    # Set during assignment
  model_override: Map.get(params, :model_override, Map.get(params, "model_override", nil)),
  verification_result: nil   # Set on completion
}
```

**Why:** Existing DETS data (tasks created before v1.2) will not have the new fields. Map.get with defaults handles this gracefully. No migration needed.

### Pattern 2: Strategy Dispatch in Sidecar

**What:** Use a strategy object to decouple task routing from execution logic.

**When:** Sidecar must handle multiple execution paths (trivial, local LLM, cloud LLM, default wake).

**Example:**
```javascript
// In handleTaskAssign:
const route = routeTask(task, _config);

switch (route.strategy) {
  case 'trivial':
    await executeTrivialTask(task, route.config, this);
    break;
  case 'local_llm':
  case 'cloud_llm':
    await wakeAgentWithModel(task, route.config, this);
    break;
  case 'wake_default':
    await wakeAgent(task, this);
    break;
}
```

**Why:** Each strategy is independently testable. Adding a new strategy (e.g., `cached_response`) requires no changes to the dispatch logic.

### Pattern 3: Hub Decides, Sidecar Executes

**What:** All routing decisions (which model, which endpoint, complexity classification) happen in the hub. The sidecar receives instructions and executes them.

**When:** All v1.2 features.

**Why:** The hub has global visibility (all endpoints, all agents, all tasks). The sidecar only knows about its own agent. Centralizing decisions in the hub avoids split-brain scenarios where sidecars make conflicting choices. The sidecar remains a thin relay + executor, consistent with v1.0 design.

### Pattern 4: Verification as Gate, Not Feedback Loop

**What:** Verification is a pass/fail gate before task completion, not a retry-within-the-agent loop.

**When:** Self-verification feature.

**Why:** The sidecar runs verification steps after the agent produces output. If verification fails, the sidecar reports `task_failed` with the verification result. The hub's existing retry logic (TaskQueue.fail_task -> retry or dead-letter) handles the retry decision. This avoids building a second retry mechanism in the sidecar and keeps the hub as the single source of truth for task lifecycle.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Sidecar Making Model Decisions

**What:** Sidecar reads task description, classifies complexity, and picks a model independently.

**Why bad:** Multiple sidecars might pick different models for similar tasks. No global optimization (all sidecars hit the same Ollama endpoint simultaneously). Hub cannot enforce cost policies. Sidecar state diverges from hub state.

**Instead:** Hub classifies complexity during submit, selects model+endpoint during assign. Sidecar receives explicit instructions.

### Anti-Pattern 2: Health Checking from Sidecars

**What:** Each sidecar independently health-checks Ollama endpoints.

**Why bad:** N sidecars x M endpoints = N*M health checks per interval. Sidecars on different machines may see different health states (network partitions). No single source of truth for "which endpoints are healthy."

**Instead:** Hub's LlmRegistry does all health checking. Single source of truth. Broadcasts health changes via PubSub. Scheduler reads from LlmRegistry, not from sidecars.

### Anti-Pattern 3: Storing Model Config in Sidecar Config

**What:** Each sidecar config.json contains the list of available models and their endpoints.

**Why bad:** Adding a new Ollama instance requires updating every sidecar config file on every machine. Configuration drift. No dynamic discovery.

**Instead:** LlmRegistry on the hub is the single registry. Sidecars receive model+endpoint info in each task_assign message. Sidecar config only contains execution preferences (trivial_execution.enabled, allowed_commands, model_wake_commands templates).

### Anti-Pattern 4: Verification Inside the Agent Session

**What:** The LLM agent itself runs verification and decides whether to report success.

**Why bad:** LLM agents can hallucinate "all tests pass" without actually running tests. Self-assessment is unreliable. The agent might enter an infinite retry loop trying to fix verification failures, consuming tokens without bound.

**Instead:** Sidecar (deterministic code) runs verification steps as shell commands. Results are factual (exit code, stdout). The sidecar makes the pass/fail decision based on exit codes, not LLM judgment.

### Anti-Pattern 5: Blocking Health Checks on Scheduler Path

**What:** Scheduler calls LlmRegistry.get_endpoint_for_model which makes a synchronous HTTP call to Ollama.

**Why bad:** Scheduler blocks on network I/O. If Ollama is slow or unreachable, scheduling all tasks stalls.

**Instead:** LlmRegistry probes asynchronously on a timer. Scheduler reads cached health state (last_check, status) from LlmRegistry's GenServer state. Zero network calls in the scheduling hot path.

---

## Integration Matrix: New vs Modified

### New Components (build from scratch)

| Component | Type | Location | Lines (est.) | Depends On |
|-----------|------|----------|-------------|------------|
| AgentCom.LlmRegistry | Elixir GenServer | lib/agent_com/llm_registry.ex | ~250 | Config, PubSub, HTTP client (built-in :httpc or req) |
| AgentCom.ComplexityClassifier | Elixir module | lib/agent_com/complexity_classifier.ex | ~80 | None (pure functions) |
| model-router.js | Node.js module | sidecar/lib/model-router.js | ~60 | None |
| trivial-executor.js | Node.js module | sidecar/lib/trivial-executor.js | ~80 | wake.js (execCommand) |
| verification.js | Node.js module | sidecar/lib/verification.js | ~100 | wake.js (execCommand) |

### Modified Components (extend existing)

| Component | Change Type | Change Summary | Risk |
|-----------|------------|----------------|------|
| TaskQueue (task_queue.ex) | Schema extension | Add 8 optional fields to task struct in submit/1. Add complexity, assigned_model, assigned_endpoint in assign_task/3. Store verification_result in complete_task/3. | LOW -- all additive, defaults to nil |
| Scheduler (scheduler.ex) | Logic extension | Add ComplexityClassifier.classify/1 call. Add LlmRegistry.get_endpoint_for_model/1 query. Extend do_assign/1 to include model routing in push_task payload. | MEDIUM -- core scheduling logic changes |
| Socket (socket.ex) | Payload extension | Extend :push_task handler to include context, criteria, verification_steps, complexity, model, endpoint. Accept verification_result in task_complete handler. | LOW -- additive fields |
| Endpoint (endpoint.ex) | New routes | Add 4 LLM admin endpoints. Extend POST /api/tasks to accept new fields. | LOW -- new routes, existing routes unchanged |
| Sidecar index.js | Flow branching | handleTaskAssign calls routeTask, dispatches to trivial/wake/model-wake. handleResult calls runVerification before sendTaskComplete. | MEDIUM -- core task flow branching |
| Sidecar lib/wake.js | Variable addition | Add ${MODEL}, ${MODEL_ENDPOINT}, ${COMPLEXITY} interpolation. | LOW -- additive |
| Sidecar lib/queue.js | No code change | Task objects in queue.json naturally grow with new fields (JSON serialization handles it). | NONE |
| Sidecar config.json | Schema extension | Add model_wake_commands, trivial_execution, verification blocks. All optional. | LOW -- backward compatible |
| application.ex | Child addition | Add LlmRegistry to supervision tree before Scheduler. | LOW -- one line |
| Analytics (analytics.ex) | Metric extension | Add model_used tracking. | LOW |

---

## HTTP Client for LlmRegistry Health Checks

The LlmRegistry needs to make HTTP requests to Ollama endpoints. Options:

**Recommended: Erlang's built-in :httpc**

```elixir
# Already available -- no dependency. Good enough for periodic health checks.
:httpc.request(:get, {~c"http://#{host}:#{port}/", []}, [timeout: 5000], [])
```

**Why not Req/Finch/HTTPoison:** LlmRegistry makes ~5 health check requests per minute (one per endpoint). The built-in :httpc is sufficient. Adding Req would add Finch, Mint, NimblePool, and NimbleOptions as transitive dependencies -- massive dep tree for 5 HTTP requests/minute. If the project later needs a more capable HTTP client (connection pooling, streaming), Req can be added then.

**Why not :httpc for Ollama chat/generate:** The sidecar (Node.js) calls Ollama for inference, not the hub. The hub only does health checks. The sidecar uses Node.js fetch or the ollama-js library.

---

## Scalability Considerations

| Concern | At 5 agents (current) | At 20 agents | At 50 agents |
|---------|----------------------|-------------|-------------|
| LLM health checks | 5 endpoints x 1/min = 5 req/min | 10 endpoints x 1/min = 10 req/min | 20 endpoints x 1/min = 20 req/min |
| Complexity classification | ~50 tasks/day, microseconds each | ~200 tasks/day | ~500 tasks/day, still trivial |
| Model routing (Scheduler) | One LlmRegistry lookup per assignment | Same, cached | Same, cached |
| DETS storage for enriched tasks | +~500 bytes per task (context, criteria) | Same per task | Monitor file sizes |
| Verification steps | 0-3 shell commands per task | Same | Consider per-agent verification parallelism |
| Trivial execution | Near-instant, no LLM calls | Same | Same |
| Sidecar memory | ~50MB with queue.json + modules | Same | Same |

No architectural changes needed at any realistic scale. The bottleneck is LLM inference time, not coordination overhead.

---

## Build Order (Dependency-Constrained)

Features have the following dependency relationships:

```
1. Enriched Task Format (TaskQueue modification)
   |
   +--> 2. LLM Endpoint Registry (LlmRegistry GenServer)
   |         |
   |         +--> 3. Complexity Classifier + Model-Aware Scheduler
   |                   |
   |                   +--> 4. Sidecar Model Routing (model-router.js + wake.js changes)
   |                            |
   |                            +--> 5. Sidecar Trivial Execution (trivial-executor.js)
   |
   +--> 6. Sidecar Self-Verification (verification.js)
            (can be built in parallel with 2-5 -- only touches handleResult, not handleTaskAssign)
```

**Recommended order:**

1. **Enriched Task Format** -- Foundation. Extend TaskQueue schema, Endpoint accepts new fields, Socket passes them through. All fields optional with nil defaults. Zero functional change -- just data plumbing.

2. **LLM Endpoint Registry** -- New GenServer. CRUD for Ollama endpoints. Health checking on timer. PubSub broadcasts. Admin HTTP endpoints. Fully testable in isolation.

3. **Complexity Classifier + Model-Aware Scheduler** -- Connect ClassifCrifier to TaskQueue.submit. Connect LlmRegistry to Scheduler.do_assign. This is where routing decisions start working.

4. **Sidecar Model Routing** -- model-router.js. handleTaskAssign reads new fields and dispatches. wake.js gets new interpolation variables. model_wake_commands in config.

5. **Sidecar Trivial Execution** -- trivial-executor.js. Requires model routing to be in place (routes trivial tasks to executor instead of wake).

6. **Self-Verification** -- verification.js. Hooks into handleResult. Independent of model routing (verification runs regardless of which model executed the task). Can be built in parallel with steps 2-5 if desired.

**Rationale:**
- Enriched task format first because every other feature reads from it
- LlmRegistry second because Scheduler needs it for model routing
- Classifier + Scheduler together because they form one logical unit (classify then route)
- Sidecar model routing before trivial execution because trivial is a special case of routing
- Verification last (or parallel) because it only touches the completion path, not the assignment path

---

## Sources

### Primary (HIGH confidence)
- AgentCom v2 codebase -- all 24 source files in lib/agent_com/, sidecar/, config/ (direct analysis)
- [Ollama API documentation](https://github.com/ollama/ollama/blob/main/docs/api.md) -- REST endpoints, health check, model listing, chat/generate formats
- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility) -- /v1/chat/completions, /v1/models endpoints
- [Ollama Elixir library (v0.3.0)](https://hexdocs.pm/ollama/0.3.0/Ollama.API.html) -- Elixir client API (evaluated, not recommended for health checks)
- AgentCom docs/local-llm-offloads.md -- Option B (task-level model routing) recommended, tiered complexity classification
- AgentCom docs/gastown_learnings.md -- convoy pattern, formula-based workflows

### Secondary (MEDIUM confidence)
- [Intelligent LLM Routing (Requesty)](https://www.requesty.ai/blog/intelligent-llm-routing-in-enterprise-ai-uptime-cost-efficiency-and-model-selection) -- model routing architecture patterns, cost optimization
- [Multi-LLM routing strategies (AWS)](https://aws.amazon.com/blogs/machine-learning/multi-llm-routing-strategies-for-generative-ai-applications-on-aws/) -- central router controller pattern
- [vLLM Semantic Router v0.1 Iris](https://blog.vllm.ai/2026/01/05/vllm-sr-iris.html) -- production semantic routing, complexity classification approaches
- [Self-Verification Prompting](https://learnprompting.org/docs/advanced/self_criticism/self_verification) -- forward reasoning + backward verification pattern
- [Agents At Work: 2026 Playbook](https://promptengineering.org/agents-at-work-the-2026-playbook-for-building-reliable-agentic-workflows/) -- verification-aware planning, acceptance criteria per subtask
- [Ollama health check issue #1378](https://github.com/ollama/ollama/issues/1378) -- GET / returns "Ollama is running" as health check
- [Ollama JavaScript library](https://github.com/ollama/ollama-js) -- Node.js client for sidecar Ollama calls

### Tertiary (LOW confidence)
- [Developer's Guide to Model Routing (Google Cloud)](https://medium.com/google-cloud/a-developers-guide-to-model-routing-1f21ecc34d60) -- general model routing concepts
- [AgentSpec: Runtime Enforcement for LLM Agents](https://arxiv.org/pdf/2503.18666) -- rule-based agent safety patterns
- [Distributed Systems and Service Discovery in Elixir](https://softwarepatternslexicon.com/patterns-elixir/14/12/) -- GenServer registry patterns

---

*Architecture research for: Smart Agent Pipeline integration into existing AgentCom v2 system*
*Researched: 2026-02-11*
