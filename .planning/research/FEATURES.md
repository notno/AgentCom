# Feature Landscape: AgentCom v1.2 -- Smart Agent Pipeline

**Domain:** Distributed multi-model LLM inference routing, enriched task orchestration, and agent self-verification for autonomous AI coding agents
**Researched:** 2026-02-12 (updated from 2026-02-11 initial research)
**Overall Confidence:** MEDIUM-HIGH (Ollama API well-documented, Claude API well-documented, routing patterns established in industry; self-verification is an emerging but well-evidenced pattern)

## Table Stakes

Features that the system must deliver for the milestone to achieve its stated goal: "Transform agents from blind task executors into context-aware, self-verifying workers with cost-efficient model routing."

| Feature | Why Expected | Complexity | Depends On (Existing) | Notes |
|---------|--------------|------------|----------------------|-------|
| **LLM endpoint registry (OllamaRegistry)** | Cannot route to endpoints you do not know about. The hub must track which Ollama hosts exist across the Tailscale mesh, what models each has, and whether they are reachable. | Low | Config GenServer (for host list), Application supervisor (for process lifecycle) | Ollama exposes `GET /` for health (200 = running), `GET /api/tags` for model list, `GET /api/ps` for running models. New GenServer, polled every 30s. ETS for hot reads. |
| **Health-checked Ollama connections** | If an Ollama host goes offline (GPU reboot, network partition), the scheduler must stop routing to it within one health cycle. Without this, tasks fail silently and retry burns slots. | Low | OllamaRegistry (same module) | `GET /` returns 200 when healthy. `GET /api/tags` confirms model availability. HTTP client needed (Elixir `Req` or bare `:httpc`). Unhealthy after 2 consecutive failures. |
| **Enriched task format** | Tasks currently carry only `description` and `metadata`. Agents need structured context (repo, branch, relevant files), success criteria (testable conditions for "done"), and verification steps (how to check). Without this, agents guess what "done" means. | Medium | TaskQueue (task struct in DETS), endpoint.ex POST /api/tasks, Scheduler (reads task fields), Sidecar (receives task via WS) | Backward-compatible: all new fields optional. Existing tasks continue working with empty context/criteria. Schema-as-data pattern (Phase 12) already established for validation. |
| **Complexity classification** | Tasks must be tagged with complexity to determine routing path: trivial (zero LLM tokens), standard (local Ollama), complex (Claude API). This is the decision input for the entire routing pipeline. | Medium | TaskQueue (new field), endpoint.ex (accepts field), Scheduler (reads field) | Start with explicit submitter tagging (`complexity_tier: "trivial" | "standard" | "complex"`). Add keyword heuristic later as a differentiator. Default: "standard" for backward compat. |
| **Model-aware scheduler routing** | The core value proposition. Scheduler currently matches `needed_capabilities` only. Must also match complexity tier to agent/endpoint type: trivial to sidecar direct, standard to Ollama-backed agents, complex to Claude-backed agents. | High | Scheduler (`agent_matches_task?/2`, `try_schedule_all/1`), AgentFSM (capabilities), OllamaRegistry, TaskQueue (complexity_tier field) | Extends existing capability matching. Scheduler is stateless (queries on every event). New matching dimension layered on top. Risk: combinatorial complexity in matching logic. |
| **Sidecar LLM backend routing** | When a sidecar receives a task, it must call the correct LLM backend based on task assignment: local Ollama instance (via HTTP to `/api/chat`) or Claude API (via `POST /v1/messages`). Currently all tasks wake OpenClaw uniformly. | High | Sidecar index.js (handleTaskAssign), config.json (new fields for Ollama/Claude endpoints), wake.js (wake command interpolation) | Sidecar already has `execCommand()`. Needs: HTTP client for Ollama (`fetch` or `node-fetch`), Anthropic SDK or raw HTTP for Claude. Config carries endpoint URLs and API keys. |
| **Sidecar trivial execution (zero-token)** | 60-70% of typical agent operations are mechanical (git status, file writes, status checks). Executing these locally saves API cost entirely. The sidecar already has `execCommand()` and `runGitCommand()`. | Medium | Sidecar index.js, lib/queue.js, lib/git-workflow.js, complexity_tier field on task | Task arrives with `complexity_tier: "trivial"` and `metadata.action` specifying the handler. Sidecar executes locally, reports result. Zero LLM tokens consumed. |
| **Task result with verification report** | When task completes, result must include what was verified and pass/fail per check. This is the output complement to enriched tasks -- without it, the hub cannot assess completion quality. | Low | Sidecar result file format (`{task_id}.json`), TaskQueue `complete_task/3` (accepts result params) | Extend existing JSON result format with `verification: [{step, passed, output}]`. Hub stores in task history. Dashboard can display. |

## Differentiators

Features that go beyond minimum viable. Not expected by users, but significantly increase the value of the milestone and the system's intelligence.

| Feature | Value Proposition | Complexity | Depends On (Existing) | Notes |
|---------|-------------------|------------|----------------------|-------|
| **Agent self-verification loop** | After completing work, agent runs verification steps (tests, file checks, grep assertions) before submitting. If verification fails, agent retries the fix. Industry evidence (Vercel agent-browser, Anthropic evals guidance) shows this dramatically improves success rates. This is the "build-verify-fix" pattern. | High | Enriched task struct (verification_steps), sidecar execution, LLM integration | Sidecar runs deterministic checks. LLM evaluates subjective criteria. Loop up to N times (default 3). Submit with verification report. Start with sidecar-only (Option A), add LLM evaluation later. |
| **Complexity heuristic engine** | Instead of requiring submitters to manually tag complexity, the scheduler infers it from task content. Tasks mentioning "review," "architect," or "design" get `complex`; tasks mentioning "write file," "git commit," or "update config" get `trivial`. | Medium | Scheduler, TaskQueue, complexity_tier field | Keyword-based heuristic (zero tokens, CPU only). NOT an LLM classifier -- that is explicitly an anti-feature. Applied as default when submitter does not specify. Submitter override always wins. |
| **Multi-host load balancing** | When multiple Ollama hosts have the same model loaded, distribute requests by current load. Prevents one GPU from being saturated while others idle. | Medium | OllamaRegistry, Scheduler | Ollama `/api/ps` reports running models per host. Least-connections or round-robin across hosts with the required model. Simple counter per host. |
| **Tiered model fallback chain** | If preferred model is unavailable (host down, model not loaded), fall back to next tier: `qwen3:8b` -> `qwen3:1.7b` -> `requeue with delay`. Prevents task blocking when a specific model is temporarily unavailable. | Low | OllamaRegistry, Scheduler routing | Configuration-driven fallback chain per complexity tier. Fallback decisions logged for cost analysis. |
| **Cost tracking per task** | Track which model handled each task, tokens consumed, and estimated cost. Enables cost optimization and answers "how much did we save by routing X% to local models?" | Low | TaskQueue (result params), Analytics module (already exists but orphaned) | Extend task result with `model_used`, `tokens_used`, `estimated_cost`. Analytics aggregation. Dashboard display. |
| **Verification step library** | Pre-built verification step types for common patterns: file_exists, test_passes, git_clean, git_branch_pushed, http_status, json_field. Agents and submitters select from library instead of defining custom verification from scratch. | Low | Sidecar execution, enriched task struct | JSON-defined steps executed deterministically by sidecar. No LLM needed. Makes verification reusable and composable. |
| **Dashboard model utilization view** | Show which Ollama hosts are active, what models are loaded, which tasks went to which model tier, and cost breakdown. | Low | Dashboard (Phase 6), OllamaRegistry, Analytics | New "Models" card on existing dashboard. Reads from OllamaRegistry state and task completion data. |

## Anti-Features

Features to explicitly NOT build. Documented to prevent scope creep and re-discussion.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Full LiteLLM/OpenAI gateway proxy** | AgentCom routes TASKS to agents, not individual LLM API requests. Adding a full LLM proxy layer creates massive scope and an architectural mismatch. LiteLLM is 100+ provider support; we need 2 (Ollama + Claude). | Use Ollama's native HTTP API directly. Use Claude Messages API directly. The sidecar makes the LLM call, not the hub. Hub routes tasks, not tokens. |
| **LLM-based complexity classifier** | Using an LLM to classify task complexity before routing is a chicken-and-egg problem (burns tokens to save tokens). RouteLLM uses trained classifiers, but training requires preference data we do not have. | Keyword heuristics (CPU-only, zero cost) plus explicit submitter tags. Classification must be free. If heuristics prove insufficient, collect labeled data from production routing decisions to train a classifier later. |
| **Dynamic model loading/unloading** | Telling Ollama hosts to `pull` or `unload` models based on demand adds operational complexity and risk. Models should be pre-loaded by the operator. | Document which models to pre-load on each host. Use `GET /api/tags` to verify availability, not to manage lifecycle. |
| **Distributed Ollama model splitting (tensor parallelism)** | Splitting a single model across multiple GPUs is an Ollama/llama.cpp concern. AgentCom should not manage inference infrastructure. | If a model needs multiple GPUs, configure at the Ollama level. AgentCom knows "host X has model Y available." |
| **Cross-agent task dependencies (DAG scheduling)** | Task A depends on Task B's output. This is a DAG scheduler -- a much larger system. | Tasks are independent units. If ordering matters, the submitter submits sequentially. DAG scheduling is a future milestone. |
| **Automated PR review by local model** | Local models (Qwen 8B) are not reliable enough for code review. Routing review to a weak model creates false confidence worse than no review. | Keep code review on Claude or human. Use local models only for mechanical/moderate tasks, not judgment-heavy work. |
| **Agent-to-agent delegation** | One agent dynamically assigning work to another bypasses the central scheduler and creates untrackable work. | All task routing goes through the hub scheduler. Agents submit tasks to the queue, not to each other. |
| **Streaming LLM output through hub** | Streaming token-by-token through the hub WebSocket adds latency and bandwidth for zero coordination value. AgentCom handles task lifecycle, not inference output. | The sidecar manages its own LLM interaction. It reports the final result to the hub. |
| **Token budget enforcement** | Per-task token spend caps. Good idea but adds enforcement complexity and requires reliable token counting before the call. | Track tokens used (cost tracking differentiator) but do not enforce caps. Analyze spending patterns first, enforce in a future milestone. |

## Feature Dependencies

```
OllamaRegistry (host + model tracking)
  |
  +--> Health Check Polling (integral to OllamaRegistry, same module)
  |
  +--> Model-Aware Scheduler Routing (requires OllamaRegistry + existing Scheduler)
  |      |
  |      +--> Multi-Host Load Balancing (requires model-aware routing foundation)
  |      |
  |      +--> Tiered Model Fallback (requires model-aware routing foundation)
  |
  +--> Dashboard Model View (requires OllamaRegistry data)

Enriched Task Struct (context + criteria + verification_steps + complexity_tier)
  |
  +--> Complexity Classification (explicit tags in enriched struct)
  |      |
  |      +--> Complexity Heuristic Engine (automated tagging, layered on explicit)
  |
  +--> Task Result with Verification Report (output side of enriched struct)
  |
  +--> Agent Self-Verification Loop (requires enriched struct + sidecar execution)

Sidecar LLM Backend Routing (call Ollama or Claude based on task)
  |
  +--> Requires: OllamaRegistry (to know which host/model)
  +--> Requires: Enriched Task Struct (complexity_tier, model_preference)
  +--> Enables: Cost Tracking (model_used comes from routing decision)

Sidecar Trivial Execution (zero-token handlers)
  |
  +--> Requires: Complexity Classification (needs complexity_tier to decide sidecar vs LLM)
  +--> Requires: Enriched Task Struct (metadata.action for handler dispatch)
  +--> Enables: Verification Step Library (sidecar runs verification scripts with same executor)
```

**Critical path:** Enriched Task Struct -> OllamaRegistry -> Complexity Classification -> Model-Aware Routing -> Sidecar Backend Routing -> Sidecar Trivial Execution -> Self-Verification

**Why this order:**
1. Enriched task struct first: every other feature reads from these fields
2. OllamaRegistry second: routing decisions need endpoint data
3. Complexity classification third: routing logic needs the tier field populated
4. Model-aware routing fourth: the scheduler extension that ties it together
5. Sidecar backend routing fifth: the agent-side complement to scheduler routing
6. Trivial execution sixth: specialization of backend routing for zero-token path
7. Self-verification last: highest complexity, requires all other pieces in place

## User Workflows

### Workflow 1: Task Submission with Complexity Routing

**Actor:** Task submitter (human or automated system)

```
1. Submitter creates task via POST /api/tasks:
   {
     description: "Add error handling to scheduler.ex",
     priority: "normal",
     complexity_tier: "standard",
     context: {
       repo: "AgentCom",
       branch: "main",
       files: ["lib/agent_com/scheduler.ex"],
       background: "Scheduler silently drops errors in do_assign"
     },
     success_criteria: [
       "All error paths in do_assign log and return meaningful errors",
       "Existing tests still pass",
       "New test covers the error path"
     ],
     verification_steps: [
       { type: "test_passes", command: "mix test test/scheduler_test.exs" },
       { type: "grep_match", file: "lib/agent_com/scheduler.ex", pattern: "Logger.error" }
     ]
   }

2. Hub validates, persists task, broadcasts :task_submitted

3. Scheduler receives event, queries idle agents:
   - Finds agents with Ollama-backed capability (for "standard" tier)
   - Queries OllamaRegistry for healthy hosts with preferred model
   - Matches agent to task, assigns

4. Sidecar receives task_assign with full enriched payload:
   - Reads complexity_tier: "standard"
   - Routes to local Ollama instance (from config)
   - Calls POST /api/chat with task prompt
   - Agent does the work

5. Agent completes, sidecar runs verification_steps:
   - Runs "mix test test/scheduler_test.exs" -> checks exit code 0
   - Greps scheduler.ex for "Logger.error" -> finds match
   - Both pass -> reports success with verification report

6. Hub receives task_complete with verification data
   - Stores in task history
   - Dashboard shows green verification badges
```

### Workflow 2: Trivial Task (Zero-Token Execution)

**Actor:** Automated pipeline or human operator

```
1. Submitter creates trivial task:
   {
     description: "Check git status on AgentCom repo",
     complexity_tier: "trivial",
     metadata: {
       action: "run_command",
       command: "git status --porcelain"
     }
   }

2. Scheduler assigns to any idle sidecar (trivial = any agent)

3. Sidecar receives task_assign:
   - Reads complexity_tier: "trivial"
   - Reads metadata.action: "run_command"
   - Does NOT wake OpenClaw or call any LLM
   - Executes command locally via child_process.exec
   - Captures stdout/stderr
   - Reports result immediately

4. Hub receives task_complete:
   { result: { stdout: "M lib/scheduler.ex", exit_code: 0 },
     tokens_used: 0, model_used: "sidecar_direct" }

5. Total LLM cost: $0.00
   Total time: <2 seconds (no model warm-up)
```

### Workflow 3: Complex Task Routed to Claude

**Actor:** Senior developer submitting architectural work

```
1. Submitter creates complex task:
   {
     description: "Design and implement the OllamaRegistry GenServer",
     complexity_tier: "complex",
     model_preference: "anthropic/claude-opus-4-6",
     context: {
       repo: "AgentCom",
       branch: "main",
       files: ["lib/agent_com/application.ex", "lib/agent_com/scheduler.ex"],
       background: "Need a new GenServer that tracks Ollama hosts..."
     },
     success_criteria: [
       "OllamaRegistry GenServer starts in supervisor tree",
       "Health polling works against test Ollama instance",
       "Scheduler can query available models"
     ],
     verification_steps: [
       { type: "file_exists", path: "lib/agent_com/ollama_registry.ex" },
       { type: "test_passes", command: "mix test test/ollama_registry_test.exs" },
       { type: "command_succeeds", command: "mix compile --warnings-as-errors" }
     ]
   }

2. Scheduler routes to Claude-capable agent:
   - Filters for agents with "claude" capability
   - No Ollama host needed (Claude API is cloud-based)

3. Sidecar receives task, routes to Claude:
   - Calls Anthropic Messages API: POST /v1/messages
   - model: "claude-opus-4-6"
   - System prompt includes task context, success criteria
   - Agent does the work

4. Self-verification loop (if enabled):
   - Sidecar runs verification_steps after agent completes
   - If "mix compile --warnings-as-errors" fails:
     - Feed failure output back to Claude
     - Agent fixes warnings
     - Re-run verification
     - Loop up to 3 times
   - Submit when all pass (or after max attempts with partial report)

5. Hub receives task_complete with full verification report
   - Tokens used: ~50K (Claude Opus)
   - Cost: ~$0.75
   - But: verified correct before submission
```

### Workflow 4: Ollama Host Goes Down Mid-Operation

**Actor:** System (automatic recovery)

```
1. OllamaRegistry health poll detects nathan-desktop unreachable:
   - GET http://100.64.x.x:11434/ -> timeout
   - Mark host :unhealthy after 2 consecutive failures
   - Broadcast :ollama_host_down event

2. Scheduler receives event:
   - Any tasks requiring models only on that host: requeue
   - Tasks with fallback chain: try next model/host
   - Log routing change with telemetry event

3. Dashboard shows host status change (yellow -> red)
   - Alert fires if configured

4. Host comes back online:
   - Next health poll succeeds
   - Mark host :healthy
   - Broadcast :ollama_host_up
   - Scheduler considers host for future assignments

5. No manual intervention needed
```

## Detailed Feature Specifications

### Enriched Task Struct

The current task struct (from TaskQueue) has these fields:
```
id, description, metadata, priority, status, created_at, updated_at,
assigned_to, assigned_at, generation, retry_count, max_retries,
complete_by, result, tokens_used, last_error, submitted_by,
needed_capabilities, history
```

New fields (all optional, backward-compatible):

```elixir
%{
  # Existing fields unchanged...

  # NEW: Context fields
  context: %{
    repo: "AgentCom",                       # Which repository
    branch: "main",                          # Base branch
    files: ["lib/agent_com/scheduler.ex"],   # Relevant files to examine
    background: "The scheduler currently..." # Why this task exists
  },

  # NEW: Success criteria (human-readable, for LLM understanding)
  success_criteria: [
    "Scheduler assigns trivial tasks to local model agents",
    "Tasks complete within 60 seconds",
    "No Claude API calls for trivial tasks"
  ],

  # NEW: Verification steps (machine-executable, for sidecar)
  verification_steps: [
    %{type: "file_exists", path: "lib/agent_com/ollama_registry.ex"},
    %{type: "test_passes", command: "mix test test/ollama_registry_test.exs"},
    %{type: "grep_match", file: "lib/agent_com/scheduler.ex", pattern: "OllamaRegistry"},
    %{type: "command_succeeds", command: "curl -s http://localhost:11434/"}
  ],

  # NEW: Routing fields
  complexity_tier: "standard",                  # "trivial" | "standard" | "complex"
  model_preference: "ollama/qwen3:8b",          # Preferred model (optional)
  model_fallback: ["ollama/qwen3:1.7b", "anthropic/claude-opus-4-6"],

  # NEW: Verification config
  max_verification_attempts: 3,                 # Self-verification loop limit
  verification_timeout_ms: 120_000              # Total verification budget
}
```

**Confidence:** HIGH -- purely additive schema extension to existing Elixir map. No breaking changes. Validated by examining task_queue.ex `submit/1` handler.

### OllamaRegistry GenServer

New module: `lib/agent_com/ollama_registry.ex`

```elixir
# State structure (ETS for hot reads, GenServer for writes)
%{
  hosts: %{
    "nathan-desktop" => %{
      url: "http://100.64.x.x:11434",
      status: :healthy,                    # :healthy | :unhealthy | :unknown
      last_check: 1707000000000,
      consecutive_failures: 0,
      models: ["qwen3:8b", "qwen3:1.7b"], # From GET /api/tags
      running: ["qwen3:8b"],              # From GET /api/ps
      gpu_info: "RTX 3080 Ti",            # Informational, from config
      tasks_active: 0                     # For load balancing
    }
  },
  check_interval_ms: 30_000,
  unhealthy_threshold: 2                   # Consecutive failures before :unhealthy
}
```

**API:**
- `list_hosts/0` -- All hosts with status
- `healthy_hosts/0` -- Only :healthy hosts
- `hosts_with_model/1` -- Hosts that have a specific model available
- `least_loaded_host/1` -- Among hosts with model, pick least active
- `register_host/2` -- Add a host (admin API)
- `remove_host/1` -- Remove a host (admin API)

**Health polling flow:**
1. Every 30s: `GET {host_url}/` for each registered host
2. If 200: `GET {host_url}/api/tags` to refresh model list
3. If 200: `GET {host_url}/api/ps` to get running models
4. If timeout/error: increment consecutive_failures
5. If consecutive_failures >= threshold: mark :unhealthy, broadcast event
6. If recovering (was unhealthy, now healthy): mark :healthy, broadcast event

**Confidence:** HIGH -- Ollama API endpoints are stable and well-documented. GenServer pattern is standard. HTTP client (`Req` or `:httpc`) is straightforward.

### Sidecar Backend Routing

Extend sidecar's `handleTaskAssign` to route based on task data:

```
Task arrives at sidecar via WebSocket
  |
  +--> Read complexity_tier from task
  |
  +--> TRIVIAL?
  |      YES --> Execute via local handler (zero tokens)
  |              metadata.action dispatches to: write_file, read_file,
  |              git_status, git_commit, run_command, file_exists, http_get
  |              Report result directly
  |
  +--> STANDARD?
  |      YES --> Call Ollama /api/chat
  |              Host URL from task metadata (assigned by scheduler)
  |              or sidecar config default
  |              Model from task.model_preference or config default
  |
  +--> COMPLEX?
         YES --> Call Claude Messages API
                 POST https://api.anthropic.com/v1/messages
                 model: from task.model_preference or config default
                 Requires ANTHROPIC_API_KEY in sidecar config
```

**Sidecar config.json additions:**
```json
{
  "agent_id": "Falling-Outside",
  "token": "...",
  "hub_url": "ws://100.64.x.x:4000/ws",
  "capabilities": ["git", "code", "ollama", "claude"],

  "ollama_url": "http://localhost:11434",
  "ollama_default_model": "qwen3:8b",

  "anthropic_api_key": "sk-ant-...",
  "anthropic_default_model": "claude-opus-4-6",

  "trivial_handlers": ["run_command", "write_file", "read_file",
                        "git_status", "git_commit", "file_exists"]
}
```

**Confidence:** MEDIUM -- Ollama HTTP API is straightforward (`fetch` to `/api/chat`). Claude API requires API key management and error handling (rate limits, overloaded errors). The complexity is in the sidecar routing logic and making the three paths (trivial/standard/complex) robust with proper error handling and fallbacks.

### Verification Step Types

Standardized, deterministic verification steps executable by the sidecar:

| Type | Parameters | What It Checks | Pass Condition |
|------|-----------|----------------|----------------|
| `file_exists` | `path` | File exists on disk | `fs.existsSync(path)` returns true |
| `file_contains` | `path`, `pattern` | File contains string/regex | `content.match(pattern)` has matches |
| `file_not_contains` | `path`, `pattern` | File does NOT contain pattern | `content.match(pattern)` has zero matches |
| `test_passes` | `command` | Test suite or specific test passes | Exit code 0 |
| `command_succeeds` | `command` | Arbitrary command succeeds | Exit code 0 |
| `command_output_contains` | `command`, `pattern` | Command output matches pattern | stdout matches pattern |
| `grep_match` | `file`, `pattern` | File matches grep pattern | At least one line matches |
| `git_clean` | (none) | No uncommitted changes | `git status --porcelain` is empty |
| `git_branch_exists` | `branch` | Branch exists locally | `git rev-parse --verify {branch}` succeeds |
| `git_branch_pushed` | `branch` | Branch exists on remote | `git ls-remote --heads origin {branch}` returns match |
| `http_status` | `url`, `expected_status` | HTTP endpoint returns expected status | Response status matches |
| `json_field` | `path`, `field`, `expected` | JSON file has expected field value | Parsed `data[field] === expected` |
| `mix_compile_clean` | (none) | Elixir compiles without warnings | `mix compile --warnings-as-errors` exit code 0 |

**Confidence:** HIGH -- All deterministic, scriptable checks using standard Node.js APIs and shell commands. No LLM needed.

### Model-Aware Scheduling Extension

Extend existing `Scheduler.agent_matches_task?/2` and `do_match_loop/2`:

```
Enhanced scheduling decision flow:

1. Filter agents by needed_capabilities (EXISTING, unchanged)

2. NEW: Filter by complexity_tier:
   - "trivial": prefer agents declaring "trivial_exec" capability
     (any agent can do trivial, but prefer agents with local exec)
   - "standard": prefer agents declaring "ollama" capability
     AND backed by a host in OllamaRegistry with the required model
   - "complex": prefer agents declaring "claude" capability
     (if no agent has "claude", requeue -- do not downgrade complex to local)

3. NEW: If model_preference is set:
   - Query OllamaRegistry.hosts_with_model(model_preference)
   - Match against agents whose sidecar is on one of those hosts
   - If no match: try model_fallback chain

4. NEW: Among matching candidates:
   - For "standard" tier: prefer least_loaded_host (from OllamaRegistry)
   - For "complex" tier: round-robin among Claude-capable agents
   - For "trivial" tier: any idle agent

5. If no agent matches after fallback exhaustion:
   - Requeue task with 30s delay
   - Log routing failure with telemetry
```

**Key design decision:** The scheduler does NOT make LLM API calls. It routes TASKS to AGENTS based on declared capabilities and host availability. The agent/sidecar is responsible for the actual LLM interaction.

**Confidence:** MEDIUM -- Architecturally straightforward (existing pattern + new fields), but the interaction between complexity tiers, model preferences, host availability, and fallback chains has combinatorial complexity. Needs thorough test coverage with many edge cases (all hosts down, model not loaded, mixed capability agents).

### Self-Verification Loop

The build-verify-fix pattern executed by the sidecar after task completion:

```
1. Agent completes initial work (code written, files modified)
2. Sidecar reads verification_steps from task
3. For each step:
   a. Execute the check (file_exists, test_passes, etc.)
   b. Record result: { step_type, passed: bool, output: string }
4. If ALL steps pass:
   - Submit result with full verification report
   - Status: "verified"
5. If ANY step fails AND attempts < max_verification_attempts:
   - Feed failure details back to LLM:
     "Verification step 'test_passes' failed: [stderr output]
      Fix the issue and try again."
   - LLM makes corrections
   - Re-run ALL verification steps
   - Increment attempt counter
6. If still failing after max attempts:
   - Submit result with PARTIAL verification report
   - Status: "partial_verification"
   - Include which steps passed, which failed, and why
   - Flag for human review
```

**Who runs verification? Design decision:**
- **Option A (recommended for v1): Sidecar only.** Zero LLM tokens for verification. Works for all deterministic checks. Cannot evaluate subjective criteria.
- **Option B (future): LLM evaluates verification output.** The sidecar runs check commands, the LLM interprets whether output meets criteria. Burns tokens but handles nuanced evaluation.

**Start with Option A.** Most verification steps are deterministic (test passes, file exists). Add Option B for complex tasks in a follow-up if needed.

**Risk mitigation:**
- Max 3 verification attempts (configurable, prevents runaway loops)
- Total verification timeout of 120s (prevents stuck verification)
- Each verification step has its own 30s timeout
- If verification itself crashes, submit with error report

**Confidence:** MEDIUM -- Pattern well-established (Anthropic evals guidance, Vercel agent-browser). Implementation requires careful timeout management, loop termination logic, and integration between sidecar result watcher and verification executor. Risk of runaway loops if not properly bounded.

## MVP Recommendation

Prioritize (in build order, respecting dependency chain):

1. **Enriched task struct** -- Foundation for all other features. Add `context`, `success_criteria`, `verification_steps`, `complexity_tier`, `model_preference`, `model_fallback` fields to the task struct. Backward-compatible (all optional). This is the schema change that enables everything downstream.

2. **OllamaRegistry GenServer** -- Track Ollama hosts, models, and health. Poll `/`, `/api/tags`, `/api/ps` every 30s. ETS for hot reads. This provides the data needed for all routing decisions.

3. **Complexity classification (explicit)** -- Task submitters tag `complexity_tier`. Scheduler reads this. Default: "standard" for backward compat. No heuristic needed yet.

4. **Model-aware scheduler routing** -- Extend Scheduler to match complexity_tier and model_preference when assigning tasks. Route trivial to any agent, standard to Ollama-backed, complex to Claude-backed.

5. **Sidecar LLM backend routing** -- When sidecar receives task, call correct backend: Ollama `/api/chat` for standard, Claude `/v1/messages` for complex. Config carries endpoint URLs and API keys.

6. **Sidecar trivial execution** -- When task is `complexity_tier: "trivial"`, execute locally via handler set. Zero LLM tokens. Start with: `run_command`, `write_file`, `read_file`, `git_status`, `file_exists`.

7. **Task result with verification report** -- Extend result format with `verification` section. Sidecar includes step-by-step pass/fail.

Defer to follow-up phases:

- **Agent self-verification loop**: Highest complexity, requires tight integration between sidecar and LLM re-prompting. Build enriched struct and all routing first, layer self-verification after the pipeline is working end-to-end.
- **Multi-host load balancing**: Get single-host routing working. Load balancing is optimization.
- **Complexity heuristic engine**: Start with explicit tags. Add heuristics when production data shows patterns.
- **Cost tracking**: Nice but not load-bearing. Add after routing is stable.
- **Dashboard model view**: After OllamaRegistry is stable and producing data.
- **Tiered model fallback**: After basic model-aware routing proves correct.

## Sources

### Primary (HIGH confidence)
- AgentCom codebase -- task_queue.ex (task struct, submit/1 params), scheduler.ex (agent_matches_task?/2, do_match_loop, PubSub events), agent_fsm.ex (capabilities, state transitions), sidecar/index.js (handleTaskAssign, wakeAgent, handleResult), sidecar/lib/queue.js, sidecar/lib/wake.js, sidecar/lib/git-workflow.js (direct code examination)
- [Ollama API docs](https://github.com/ollama/ollama/blob/main/docs/api.md) -- GET /, GET /api/tags, GET /api/ps, POST /api/chat, POST /api/generate, POST /api/show endpoints (official documentation, verified via WebFetch)
- [Ollama JavaScript library](https://github.com/ollama/ollama-js) -- Official Node.js client, ollama.chat() API (npm package, official)
- [Claude Messages API](https://platform.claude.com/docs/en/api/messages) -- POST /v1/messages, model parameter, required fields, response format (official Anthropic documentation, verified via WebFetch)
- [Anthropic: Effective Context Engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) -- Task context structure, XML/Markdown delineation, minimal high-signal tokens (official Anthropic engineering)
- [Anthropic: Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) -- Success criteria, deterministic vs LLM graders, failure patterns (official Anthropic engineering)

### Secondary (MEDIUM confidence)
- [RouteLLM (LMSYS)](https://lmsys.org/blog/2024-07-01-routellm/) -- Open-source complexity-based routing, threshold calibration, 85% cost reduction (ICLR 2025 paper, Berkeley)
- [LLM Routing in Production (LogRocket)](https://blog.logrocket.com/llm-routing-right-model-for-requests) -- Heuristic classification, rule-based vs ML-based routing, cascade fallback chains (verified via WebFetch)
- [Addy Osmani: How to Write a Good Spec for AI Agents](https://addyosmani.com/blog/good-spec/) -- Briefing packs, three-tier boundaries, success criteria patterns (verified via WebFetch)
- [LiteLLM Health Checks](https://docs.litellm.ai/docs/proxy/health) -- Background health check patterns, endpoint monitoring (official LiteLLM docs)
- [Olla Health Checking](https://thushan.github.io/olla/concepts/health-checking/) -- Service discovery, configurable intervals, timeout patterns (open source project)
- [How to Build Result Verification (OneUptime, 2026)](https://oneuptime.com/blog/post/2026-01-30-result-verification/view) -- Schema validation, assertion-based checking, retry logic (industry guide)

### Tertiary (LOW confidence)
- [IBM LLM Router cost savings](https://sourceforge.net/software/llm-routers/) -- 85% cost reduction estimate (cited in multiple sources but unverified primary claim)
- [Agents At Work: 2026 Playbook](https://promptengineering.org/agents-at-work-the-2026-playbook-for-building-reliable-agentic-workflows/) -- Verification-aware planning patterns (community guide)

---
*Research completed: 2026-02-12*
*Updated from 2026-02-11 initial research with: user workflows, deeper Ollama/Claude API verification, refined complexity assessments, existing codebase dependency mapping*
