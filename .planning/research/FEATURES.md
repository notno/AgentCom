# Feature Landscape: AgentCom v2.0 -- Distributed LLM Routing & Enriched Tasks

**Domain:** Distributed multi-model LLM inference routing, enriched task orchestration, and agent self-verification for AI coding agents
**Researched:** 2026-02-11
**Overall Confidence:** MEDIUM (novel integration of established patterns; Ollama API is well-documented, but multi-host mesh routing and self-verification loops are project-specific compositions)

## Table Stakes

Features users expect from a system claiming distributed LLM routing, enriched tasks, and self-verification. Missing = the milestone does not deliver its value proposition.

| Feature | Why Expected | Complexity | Dependencies on Existing | Notes |
|---------|--------------|------------|--------------------------|-------|
| **Ollama host registry** | Cannot route to hosts you do not know about. The hub must track which Ollama instances are available, what models each has loaded, and whether they are healthy. | Low | Config GenServer (DETS-backed), Presence patterns | Ollama exposes `GET /` for health, `GET /api/tags` for model list, `GET /api/ps` for running models. Poll these periodically per host. |
| **Model-aware task routing** | The core value proposition. Tasks declare a `model` or `complexity_tier` field. The scheduler uses this to route tasks to Ollama hosts that have the required model available. Without this, all tasks go to Claude. | High | Scheduler (Phase 4), TaskQueue task struct, AgentFSM capabilities | Extends existing capability matching. Scheduler already does `needed_capabilities` matching; this adds `model_preference` or `complexity_tier` to the routing decision. |
| **Enriched task struct (context + success criteria)** | Tasks currently carry only `description` and `metadata`. Agents receiving a task need structured context (what repo, what branch, what files), success criteria (what "done" means), and verification steps (how to check). Without enrichment, the agent guesses what "done" means. | Medium | TaskQueue (Phase 2) task struct, endpoint.ex POST /api/tasks | Backward-compatible: new optional fields. Existing tasks work with empty context/criteria. |
| **Sidecar trivial execution (zero-token)** | 60-70% of agent turns are mechanical (git ops, file writes, status reports). The sidecar currently wakes OpenClaw for everything. Executing trivial tasks locally saves significant API cost. | Medium | Sidecar index.js, wake.js, git-workflow.js | Sidecar already has `exec` capability via `execCommand()`. Extend with a task classifier and a set of scripted handlers. |
| **Complexity classification** | Tasks must be tagged with complexity (trivial/standard/complex) to know where to route them. This is the decision input for both model selection and sidecar execution. | Medium | TaskQueue, endpoint.ex, Scheduler | Can be explicit (submitter tags) or heuristic (scheduler infers from task content). Start with explicit, add heuristic later. |
| **Health-checked Ollama connections** | If an Ollama host goes down, the scheduler must stop routing to it. Without health checks, tasks fail silently. | Low | New OllamaRegistry GenServer | Ollama `GET /` returns 200 when healthy. `GET /api/tags` confirms model availability. Poll every 30s. |
| **Task result with verification report** | When an agent completes a task, the result must include what was verified, not just "done." This is the output side of enriched tasks. | Low | Sidecar result file format, TaskQueue complete_task | Extend the existing `{task_id}.json` result format with a `verification` field. |

## Differentiators

Features that go beyond minimum viable. Not expected, but significantly increase the value of the milestone.

| Feature | Value Proposition | Complexity | Dependencies on Existing | Notes |
|---------|-------------------|------------|--------------------------|-------|
| **Agent self-verification loop** | After an agent completes work, it runs its own verification steps (tests, file checks, grep assertions) before submitting the result. If verification fails, it retries without human intervention. Success jumped to 100% in Vercel's agent-browser experiments with this pattern. | High | Sidecar, enriched task struct, OpenClaw/LLM integration | The sidecar can run verification scripts. The LLM can evaluate whether verification output matches success criteria. This is the "build-verify-fix" loop. |
| **Multi-host model-aware load balancing** | When multiple Ollama hosts have the same model, distribute requests based on current load (running model count from `/api/ps`). Prevents one GPU from being overloaded while others idle. | Medium | OllamaRegistry, Scheduler | Least-connections or round-robin across hosts with the required model. Ollama `/api/ps` reports currently running models per host. |
| **Complexity heuristic engine** | Instead of requiring the task submitter to manually tag complexity, the scheduler infers it from task content: tasks mentioning "review," "architect," or "design" get `complex`; tasks mentioning "write file," "git commit," or "update config" get `trivial`. | Medium | Scheduler, TaskQueue | Keyword-based heuristic initially. Could use a small local model to classify later. |
| **Tiered model fallback** | If the preferred model is unavailable (host down, model not loaded), fall back to the next tier: `qwen3:8b` -> `qwen3:1.7b` -> `reject and requeue`. Prevents tasks from blocking when a specific model is temporarily unavailable. | Low | OllamaRegistry, Scheduler | Configuration-driven fallback chain. |
| **Cost tracking per task** | Track which model handled each task and estimated token cost. Enables cost optimization analysis over time. | Low | TaskQueue, Analytics | Extend task result with `model_used`, `tokens_used`, `estimated_cost`. |
| **Verification step library** | Pre-built verification steps for common patterns: "file X exists," "test suite passes," "git branch pushed," "PR created," "no syntax errors." Agents select from library instead of writing verification from scratch. | Low | Sidecar, enriched task struct | JSON-defined verification steps that the sidecar can execute deterministically. |
| **Dashboard model utilization view** | Show which Ollama hosts are active, what models are loaded, which tasks went to which model tier. | Low | Dashboard (Phase 6), OllamaRegistry, Analytics | Extends existing dashboard with a new "Models" card. |

## Anti-Features

Features to explicitly NOT build in this milestone. Documented to prevent scope creep.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Full LiteLLM/OpenAI gateway** | AgentCom is a task coordinator, not an API gateway. Adding a full LLM proxy layer creates massive scope. | Use Ollama's native API directly. The hub routes TASKS to agents, not individual LLM requests. The agent/sidecar makes the actual LLM call. |
| **Distributed Ollama model splitting** | Splitting a single model across multiple GPUs (tensor parallelism) is an Ollama/llama.cpp concern, not AgentCom's. OLOL handles this if needed. | If a model needs multiple GPUs, configure that at the Ollama level. AgentCom just knows "host X has model Y available." |
| **Dynamic model loading/unloading** | Telling Ollama hosts to `pull` or unload models based on demand adds operational complexity and risk. Models should be pre-loaded. | Document which models to pre-load on each host. Use `GET /api/tags` to verify, not to manage. |
| **LLM-based complexity classifier** | Using an LLM to classify task complexity before routing is a chicken-and-egg problem (burns tokens to save tokens). | Use keyword heuristics or explicit submitter tags. Classification should be free (CPU-only). |
| **Cross-agent task dependencies (DAG scheduling)** | Task A depends on Task B's output. This is a DAG scheduler, which is a much larger system. | Tasks are independent units. If ordering matters, the submitter submits them sequentially. The convoy/formula pattern from Gas Town can be explored in a future milestone. |
| **Automated PR review by local model** | Qwen 8B is not reliable enough for code review (per local-llm-offloads.md). Routing review to a weak model creates false confidence. | Keep code review on Claude. Use local models only for Tier 1-2 tasks (mechanical/moderate). |
| **Agent-to-agent delegation** | One agent dynamically assigning work to another agent. This is peer-to-peer scheduling that bypasses the central scheduler. | All task routing goes through the hub scheduler. Agents submit tasks to the queue, not to each other. |
| **Streaming inference results** | Streaming LLM output back through the hub WebSocket. AgentCom handles task coordination, not token-by-token output. | The agent/sidecar manages its own LLM interaction. It reports the final result to the hub. |

## Feature Dependencies

```
OllamaRegistry (host + model tracking)
  |
  +--> Health Check Polling (requires OllamaRegistry to store host list)
  |
  +--> Model-Aware Scheduler Routing (requires OllamaRegistry + existing Scheduler)
  |      |
  |      +--> Multi-Host Load Balancing (requires model-aware routing foundation)
  |      |
  |      +--> Tiered Model Fallback (requires model-aware routing foundation)
  |
  +--> Dashboard Model View (requires OllamaRegistry data)

Enriched Task Struct (context + criteria + verification)
  |
  +--> Complexity Classification (explicit tags in enriched struct)
  |      |
  |      +--> Complexity Heuristic Engine (automated tagging)
  |
  +--> Task Result with Verification Report (output side of enriched struct)
  |
  +--> Agent Self-Verification Loop (requires enriched struct + sidecar execution)

Sidecar Trivial Execution (zero-token handlers)
  |
  +--> Complexity Classification (needs complexity tag to decide: sidecar vs. LLM)
  |
  +--> Verification Step Library (sidecar runs verification scripts)

Cost Tracking
  +--> Requires model_used field in task result (from model-aware routing)
  +--> Requires Analytics module (already exists)
```

**Critical path:** OllamaRegistry -> Model-Aware Routing -> Enriched Task Struct -> Sidecar Trivial Execution -> Self-Verification

## MVP Recommendation

Prioritize (in order):

1. **Enriched task struct** -- Foundation for everything else. Add `context`, `success_criteria`, `verification_steps`, and `complexity_tier` fields to the task struct. Backward-compatible (all optional). This is the schema change that enables all downstream features.

2. **Complexity classification (explicit)** -- Task submitters tag `complexity_tier: "trivial" | "standard" | "complex"`. The scheduler reads this field. No heuristic needed initially -- humans/submitting systems know task complexity.

3. **OllamaRegistry GenServer** -- Track Ollama hosts, their available models, and health status. Poll `GET /` and `GET /api/tags` every 30s. Store in ETS (volatile, rebuilt on start from config). This is the data foundation for all routing decisions.

4. **Model-aware scheduler routing** -- Extend the existing Scheduler to consider `complexity_tier` when matching tasks to agents. `trivial` tasks prefer agents backed by local Ollama. `complex` tasks require Claude-capable agents. `standard` tasks try local first, fall back to Claude.

5. **Sidecar trivial execution** -- When the sidecar receives a task with `complexity_tier: "trivial"`, execute it locally (git ops, file ops, status reports) without waking OpenClaw. This is the zero-token path. Start with a hardcoded set of trivial handlers: `git_status`, `write_file`, `read_file`, `run_command`.

6. **Task result verification report** -- Extend the sidecar result format to include a `verification` section listing what was checked and pass/fail per check.

Defer:

- **Agent self-verification loop**: High complexity, requires tight integration between sidecar and LLM. Build the enriched struct and trivial execution first, then layer self-verification on top. This is a Phase 2 of the milestone.
- **Multi-host load balancing**: Get single-host routing working first. Load balancing is an optimization.
- **Complexity heuristic engine**: Start with explicit tags. Add heuristics when you have enough task history to know what patterns exist.
- **Cost tracking**: Nice but not load-bearing. Add after routing is stable.
- **Dashboard model view**: After OllamaRegistry is stable and has data flowing.

## Detailed Feature Specifications

### Enriched Task Struct

The current task struct (from TaskQueue) has these fields:
```
id, description, metadata, priority, status, created_at, updated_at,
assigned_to, assigned_at, completed_at, result, generation, retry_count,
max_retries, complete_by, error, needed_capabilities
```

Add these new fields (all optional, backward-compatible):

```elixir
%{
  # Existing fields...

  # NEW: Enrichment fields
  context: %{
    repo: "AgentCom",                    # Which repository
    branch: "main",                      # Base branch
    files: ["lib/agent_com/scheduler.ex"], # Relevant files
    background: "The scheduler currently..." # Why this task exists
  },

  success_criteria: [
    "Scheduler assigns trivial tasks to local model agents",
    "Tasks complete within 60 seconds",
    "No Claude API calls for trivial tasks"
  ],

  verification_steps: [
    %{type: "file_exists", path: "lib/agent_com/ollama_registry.ex"},
    %{type: "test_passes", command: "mix test test/ollama_registry_test.exs"},
    %{type: "grep_match", file: "lib/agent_com/scheduler.ex", pattern: "ollama"},
    %{type: "command_succeeds", command: "curl http://localhost:11434/"}
  ],

  complexity_tier: "standard",  # "trivial" | "standard" | "complex"

  model_preference: "ollama/qwen3:8b",  # Preferred model (optional)
  model_fallback: ["ollama/qwen3:1.7b", "anthropic/claude-opus-4-6"],  # Fallback chain
}
```

**Confidence:** HIGH -- this is a schema extension to an existing Elixir map, purely additive, no breaking changes.

### OllamaRegistry

A new GenServer that maintains a registry of Ollama hosts and their capabilities.

```elixir
# State structure
%{
  hosts: %{
    "nathan-desktop" => %{
      url: "http://100.64.x.x:11434",
      status: :healthy,                    # :healthy | :unhealthy | :unknown
      last_check: 1707000000000,
      models: ["qwen3:8b", "qwen3:1.7b"], # From /api/tags
      running: ["qwen3:8b"],              # From /api/ps
      gpu: "RTX 3080 Ti"                  # Informational
    },
    "gpu-server-2" => %{...}
  }
}
```

**Key behaviors:**
- Init: Load host list from config (DETS or config.exs)
- Health poll: Every 30s, `GET /` each host. Update status.
- Model discovery: On health check success, `GET /api/tags` to refresh model list.
- Running model query: `GET /api/ps` to see what is currently loaded.
- Public API: `list_healthy_hosts/0`, `hosts_with_model/1`, `least_loaded_host/1`

**Confidence:** HIGH -- Ollama API endpoints (`/`, `/api/tags`, `/api/ps`) are well-documented and stable.

### Sidecar Trivial Execution

Extend the sidecar's `handleTaskAssign` to check `complexity_tier`:

```
Task arrives at sidecar
  |
  +--> complexity_tier == "trivial"?
  |      YES --> Execute locally via scripted handler
  |               (git ops, file ops, shell commands)
  |               Report result directly to hub
  |               ZERO LLM tokens consumed
  |
  +--> complexity_tier == "standard"?
  |      YES --> Wake OpenClaw with LOCAL Ollama model
  |               (e.g., wake_command uses ollama/qwen3:8b)
  |
  +--> complexity_tier == "complex"?
         YES --> Wake OpenClaw with CLAUDE
                  (existing behavior, default)
```

**Trivial handler set (v1):**

| Handler | Trigger Pattern | What It Does |
|---------|----------------|--------------|
| `write_file` | metadata.action == "write_file" | Write content to specified path |
| `read_file` | metadata.action == "read_file" | Read file, return contents |
| `git_status` | metadata.action == "git_status" | Run `git status`, return output |
| `git_commit` | metadata.action == "git_commit" | Stage + commit with message |
| `run_command` | metadata.action == "run_command" | Execute shell command, return stdout/stderr |
| `file_exists` | metadata.action == "file_exists" | Check if file exists, return boolean |
| `http_get` | metadata.action == "http_get" | Fetch URL, return response body |

**Confidence:** MEDIUM -- The sidecar already has `execCommand()` and file I/O. The complexity is in defining the right handler interface and making it extensible without becoming a full scripting engine.

### Verification Step Types

Standardized verification steps that the sidecar can execute deterministically:

| Type | Parameters | What It Checks | Pass Condition |
|------|-----------|----------------|----------------|
| `file_exists` | `path` | File exists on disk | `fs.existsSync(path)` |
| `file_contains` | `path`, `pattern` | File contains a string/regex | `content.match(pattern)` |
| `test_passes` | `command` | Test suite passes | Exit code 0 |
| `command_succeeds` | `command` | Arbitrary command succeeds | Exit code 0 |
| `grep_match` | `file`, `pattern` | File matches grep pattern | At least one match |
| `git_clean` | none | No uncommitted changes | `git status --porcelain` is empty |
| `git_branch_pushed` | `branch` | Branch exists on remote | `git ls-remote --heads origin {branch}` |
| `http_status` | `url`, `expected_status` | HTTP endpoint returns expected status | Response status matches |
| `json_field` | `path`, `field`, `expected` | JSON file has expected field value | `data[field] === expected` |

**Confidence:** HIGH -- These are all deterministic, scriptable checks. No LLM needed.

### Model-Aware Scheduling Extension

The existing scheduler's `agent_matches_task?/2` function matches `needed_capabilities`. Extend it to also consider `complexity_tier` and `model_preference`:

```
Scheduling decision flow:

1. Filter agents by needed_capabilities (existing)
2. Filter by complexity_tier:
   - "trivial": prefer agents with sidecar trivial execution capability
   - "standard": prefer agents backed by local Ollama
   - "complex": prefer agents backed by Claude
3. If model_preference set:
   - Query OllamaRegistry for hosts with that model
   - Match against agents on those hosts
4. If no agent matches preferred model:
   - Try model_fallback chain
   - If all fallbacks exhausted, requeue with delay
5. Among remaining candidates: pick least-recently-assigned (simple fairness)
```

**Confidence:** MEDIUM -- The scheduler extension is architecturally straightforward (existing pattern + new fields), but the interaction between complexity tiers, model preferences, host availability, and fallback chains has combinatorial complexity that needs careful testing.

## Agent Self-Verification Pattern

The self-verification loop is the highest-value differentiator but also the highest complexity. Here is the pattern based on industry research:

**The Build-Verify-Fix Loop:**
1. Agent receives enriched task with `success_criteria` and `verification_steps`
2. Agent does the work (writes code, makes changes)
3. Agent (or sidecar) runs `verification_steps` sequentially
4. If all pass: submit result with verification report
5. If any fail: agent reviews failure, attempts fix, re-runs verification
6. Loop up to N times (configurable, default 3)
7. If still failing after N attempts: submit with partial verification, flag for human review

**Key design decision:** Who runs verification?
- **Option A: Sidecar runs verification** -- Zero LLM tokens for verification. Works for deterministic checks (file exists, tests pass). Cannot evaluate subjective criteria ("code is clean").
- **Option B: LLM evaluates verification output** -- The sidecar runs the check commands, returns output. The LLM evaluates whether the output meets the success criteria. Burns tokens but handles nuanced evaluation.
- **Recommendation: Start with Option A (sidecar only).** Add Option B for complex tasks later. Most verification steps are deterministic. Subjective evaluation is a luxury, not table stakes.

**Confidence:** MEDIUM -- The pattern is well-established (Vercel agent-browser, Voyager, CodeSIM). The implementation requires careful timeout management and loop termination logic. The risk is runaway verification loops burning compute.

**Sources:**
- [Pulumi: Self-Verifying AI Agents](https://www.pulumi.com/blog/self-verifying-ai-agents-vercels-agent-browser-in-the-ralph-wiggum-loop/) -- Build-verify-fix loop pattern (MEDIUM confidence)
- [Anthropic: Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) -- Success criteria and grader patterns (HIGH confidence)

## Sources

### Primary (HIGH confidence)
- AgentCom codebase -- task_queue.ex task struct, scheduler.ex routing logic, sidecar/index.js task handling, sidecar/lib/wake.js execution (direct examination)
- [AgentCom local-llm-offloads.md](docs/local-llm-offloads.md) -- Tier-based offloading strategy, cost projections, Qwen3 8B capability assessment (project documentation)
- [Ollama API docs](https://github.com/ollama/ollama/blob/main/docs/api.md) -- `/`, `/api/tags`, `/api/ps`, `/api/chat`, `/api/generate` endpoints (official documentation)
- [Ollama Elixir library](https://hexdocs.pm/ollama/0.9.0/Ollama.html) -- v0.9.0, chat/2, completion/2, list_models/1, show_model/2 (hex.pm documentation)
- [Anthropic: Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) -- Task definitions, graders, success criteria patterns (official Anthropic engineering)

### Secondary (MEDIUM confidence)
- [Swfte: Intelligent LLM Routing](https://www.swfte.com/blog/intelligent-llm-routing-multi-model-ai) -- Complexity-based routing strategies, 85% cost reduction with RouteLLM (industry analysis)
- [Pulumi: Self-Verifying AI Agents](https://www.pulumi.com/blog/self-verifying-ai-agents-vercels-agent-browser-in-the-ralph-wiggum-loop/) -- Build-verify-fix loop, 100% success rate with self-verification (case study)
- [Hive: Distributed Ollama Inference](https://www.sciencedirect.com/science/article/pii/S2352711025001505) -- HiveCore/HiveNode architecture for distributed inference (academic paper)
- [OLOL: Ollama Load Balancer](https://github.com/K2/olol) -- Multi-host Ollama inference clustering (open source project)
- [Collabnix: Scaling Ollama Deployments](https://collabnix.com/scaling-ollama-deployments-load-balancing-strategies-for-production/) -- Load balancing strategies for Ollama (community guide)
- [AgentCom gastown_learnings.md](docs/gastown_learnings.md) -- Convoy patterns, formula workflows, git-backed state (project documentation)

### Tertiary (LOW confidence)
- [Multi-Agent Code Verification via Information Theory](https://arxiv.org/pdf/2511.16708) -- CodeX-Verify multi-agent bug detection (academic, not directly applicable)
- [dasroot.net: Multi-Agent Multi-LLM Systems 2026](https://dasroot.net/posts/2026/02/multi-agent-multi-llm-systems-future-ai-architecture-guide-2026/) -- Industry trends for multi-model architectures (blog post)
