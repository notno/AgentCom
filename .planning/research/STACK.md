# Technology Stack: LLM Mesh Routing & Enriched Tasks

**Project:** AgentCom v2 -- Milestone 2 (Distributed LLM, Enriched Tasks, Self-Verification)
**Researched:** 2026-02-12
**Confidence:** HIGH (Ollama API verified via GitHub docs, Req verified via Hex, ollama npm verified via npm/GitHub)

## Scope

This document covers ONLY the stack additions for milestone 2 features:
1. Distributed LLM routing (Ollama across Tailscale mesh)
2. Enriched task format with context/criteria
3. Model-aware scheduling
4. Sidecar trivial execution (zero-token tasks)
5. Agent self-verification

Existing stack (Elixir/BEAM, Bandit, Phoenix.PubSub, Jason, ws, chokidar, etc.) is
unchanged and not re-documented here.

---

## Recommended Stack Additions

### Hub-Side (Elixir)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Req | ~> 0.5.0 | HTTP client for Ollama API calls | Batteries-included Elixir HTTP client. Built-in streaming (`into:` option), automatic JSON decode via Jason, retries with `max_retries`, connection pooling via Finch. Community standard -- likely becoming Phoenix's default HTTP client. v0.5.17 current (Jan 2026). Replaces need for raw hackney/HTTPoison calls. |

### Sidecar-Side (Node.js)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| ollama (npm) | ^0.6.3 | Ollama client for sidecar model invocation | Official Ollama JavaScript library. Exposes `chat()`, `generate()`, `list()`, `ps()` methods. Configurable `host` for remote instances. Supports `format` parameter for structured JSON output. Handles streaming via async iterators. Accepts custom `fetch` implementation. 412 downstream dependents on npm. |

### Infrastructure (No Code Dependency)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Ollama | latest (0.15.x) | Local LLM inference server | Runs on each Tailscale machine with GPU. REST API on port 11434. Supports model management, VRAM reporting (`/api/ps` returns `size_vram`), health check (`GET /api/version`), structured output via `format` parameter with JSON Schema. v0.15.6 current (Feb 7, 2026). |
| Qwen3 8B | Q4_K_M quant | Primary local inference model | Fits in 12GB VRAM (~6-7GB at Q4_K_M including KV cache). Supports tool calling, structured JSON output, thinking/non-thinking modes. 32K native context. Handles tiers 1-2 tasks (trivial and standard). Optimized for reasoning and structured responses. |
| Tailscale MagicDNS | (existing) | Cross-machine Ollama discovery | Already deployed for agent mesh. MagicDNS resolves hostnames automatically (e.g., `nathan-pc.tail1234.ts.net`). Hub discovers Ollama instances at `http://{hostname}:11434`. No additional service discovery needed. |

### Custom Implementations (No External Dependency)

| Component | Approach | Lines (est.) | Why Custom |
|-----------|----------|-------------|------------|
| OllamaPool | GenServer + ETS | ~250 | Multi-host Ollama endpoint registry. Periodic health checks via `GET /api/version`, model inventory via `GET /api/tags`, VRAM status via `GET /api/ps`. Tracks endpoint health state (healthy/degraded/down) with circuit-breaker semantics. No off-the-shelf Elixir multi-host Ollama pool exists. |
| TaskClassifier | Pure function module | ~80 | Classifies task complexity (trivial/standard/complex) from enriched task metadata. Drives model routing decisions. Domain-specific logic unique to AgentCom's 3-tier model. |
| VerificationEngine | GenServer | ~150 | Accepts self-verification reports from sidecars, validates against task acceptance criteria, updates task status with verification_status field. Unique to AgentCom's task lifecycle. |
| TrivialExecutor | Module in sidecar | ~120 | Node.js module handling zero-LLM-token mechanical operations (file writes, git status, status reports) and low-token operations (summaries, simple analysis) using local Ollama via the `ollama` npm package. |

### Already Present (No Change Needed)

| Technology | Version | Role in Milestone 2 |
|------------|---------|---------------------|
| Phoenix.PubSub | ~> 2.1 | Broadcasts Ollama pool status changes, model routing events, verification results |
| Jason | ~> 1.4 | JSON encoding/decoding for Ollama API payloads, enriched task serialization |
| DETS | OTP stdlib | Persists enriched task fields (context, criteria, model, verification_status) |
| ETS | OTP stdlib | OllamaPool health state cache (fast reads from Scheduler), validation backoff (existing) |
| Registry | OTP stdlib | AgentRegistry (existing), AgentFSMRegistry (existing) -- no new registries needed |
| :telemetry | 1.3.0 (via Bandit) | Instrument Ollama call latency, token counts, routing decisions |
| AgentCom.Validation | custom | Extend existing pattern-matching schemas for enriched task fields |
| AgentCom.Validation.Schemas | custom | Add new schemas for enriched task submission, verification results |
| ws (npm) | ^8.19.0 | WebSocket relay unchanged. Enriched task payloads flow through existing channel |
| write-file-atomic (npm) | ^5.0.0 | Queue persistence for sidecar. Enriched task data persisted same way |
| chokidar (npm) | ^3.6.0 | Result file watcher unchanged. Verification results use same .json pattern |

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| HTTP Client (Elixir) | Req ~> 0.5 | ollama hex package 0.9.0 | The `ollama` hex package (v0.9.0, Sep 2025) wraps Req and provides `init/1`, `list_models/1`, `list_running/1`, `chat/2` with structured output. However: (1) hasn't been updated since Sep 2025 while Ollama server went from ~0.3.x to 0.15.6, (2) we need custom health-check polling and multi-host pool management that goes beyond its single-client model, (3) adds nimble_options and plug version constraint as transitive deps, (4) only ~2K downloads for latest version. Using Req directly gives us full control over endpoints and zero risk of wrapper staleness. |
| HTTP Client (Elixir) | Req ~> 0.5 | HTTPoison (already transitive via web_push_elixir) | HTTPoison wraps hackney which is in maintenance mode. Not directly used in codebase (only a transitive dep). Req uses Finch (modern, connection-pooling, HTTP/2). Req has better streaming via `into:` parameter and built-in retries. |
| HTTP Client (Elixir) | Req ~> 0.5 | Tesla ~> 1.13 | Tesla adds middleware abstraction we don't need. Req is simpler, has streaming built-in, and is the emerging community standard (preferred per ElixirForum consensus). |
| LLM Client (Node.js) | ollama npm 0.6.3 | Raw fetch/http calls | Official ollama-js library handles streaming, structured output format, host configuration, and exposes all API methods (chat, generate, list, ps, etc.). Doing this manually would be ~200 lines of fetch boilerplate for no benefit. |
| LLM Client (Node.js) | ollama npm 0.6.3 | @langchain/ollama | LangChain is a heavy framework with chains, agents, memory abstractions we don't need. Our sidecar does ONE thing: send a task to Ollama and get structured JSON back. |
| Task Validation | Extend existing Validation module | ex_json_schema ~> 0.11.0 | The existing `AgentCom.Validation` module uses a custom pattern-matching approach with `required`/`optional` field maps and type atoms. Adding ex_json_schema introduces a second validation paradigm. Better to extend the existing system -- it already handles nested types (`{:list, :string}`), length limits, and error formatting. Adding new schemas for enriched tasks is ~30 lines of schema definitions in `Validation.Schemas`. |
| Service Discovery | Tailscale MagicDNS + config | Consul / etcd | Overkill for 3-5 machines. MagicDNS already resolves hostnames. A config list of endpoint maps with health checks is sufficient. |
| Model Routing | Custom TaskClassifier | LiteLLM proxy | LiteLLM is a Python proxy adding another runtime. Our routing logic is simple (3 tiers) and lives naturally in the Elixir scheduler. |
| Health Checking | Custom OllamaPool GenServer | External monitoring (Prometheus, etc.) | Already have :telemetry and MetricsCollector. Health checks are simple HTTP GETs on a timer. A GenServer with Process.send_after/3 is the idiomatic Elixir pattern (same as existing Scheduler stuck-sweep and TaskQueue overdue-sweep). |

---

## What NOT to Add

| Avoid | Why | Do Instead |
|-------|-----|------------|
| ex_json_schema | Would introduce a second validation paradigm alongside existing pattern-matching validation. Enriched task schemas are flat enough for the existing system. | Extend `AgentCom.Validation.Schemas` with new schema maps for enriched tasks and verification results. |
| LangChain (any variant) | Framework overhead for simple prompt-response pattern. Adds chains, memory, agent abstractions that conflict with AgentCom's own agent model. | Direct Ollama API calls via `ollama` npm package (sidecar) and `Req` (hub). |
| vLLM / TGI inference servers | Complex GPU serving infrastructure for a 5-agent system. Ollama handles model management, quantization, and GPU scheduling already. | Ollama on each machine. If you outgrow it, revisit. |
| OpenAI SDK for Ollama | Ollama's OpenAI compatibility endpoint has historically been experimental. The native `/api/chat` endpoint is stable and returns richer metadata (timing, token counts, VRAM info). | Use Ollama native API endpoints directly. |
| Redis / external message broker | System is single-hub, 5 agents. Phoenix.PubSub with local adapter handles all event distribution. Adding Redis adds operational complexity for zero benefit at this scale. | Continue using Phoenix.PubSub for all event distribution. |
| Ecto | No database in this system. DETS is the persistence layer. Adding Ecto would require rethinking the entire data layer for no benefit at this scale. | Continue DETS for persistence. Extend existing validation for schemas. |
| Vector database (Qdrant, Pinecone) | No semantic search or RAG requirements in scope. Task matching is capability-based, not similarity-based. | Continue using exact-match capability filtering in scheduler. |
| Circuit breaker library (breaker, fuse) | Adds a dependency for something that is ~20 lines in a GenServer. Our health check intervals are 30s with simple healthy/degraded/down state tracking. | Custom health state tracking in OllamaPool GenServer with consecutive-failure counting. |

---

## Integration Points

### How New Stack Connects to Existing Code

```
Existing Scheduler (scheduler.ex)
    |
    +-- NEW: Calls OllamaPool.available_models() to check capacity
    +-- NEW: Uses TaskClassifier.classify(task) for complexity tier
    +-- NEW: Selects model/endpoint based on tier + availability
    +-- NEW: Adds `model` and `ollama_endpoint` fields to task_data in do_assign/2
    |
    v
Existing TaskQueue (task_queue.ex)
    |
    +-- NEW: Enriched task map gains fields:
    |     context, acceptance_criteria, model, complexity,
    |     ollama_endpoint, verification_status, verification_result
    +-- UNCHANGED: DETS persistence, priority index, generation fencing
    |
    v
Existing Sidecar (sidecar/index.js)
    |
    +-- NEW: Reads task.complexity from enriched task_assign payload
    +-- NEW: If trivial, calls Ollama via `ollama` npm (TrivialExecutor)
    +-- NEW: If not trivial, wakes agent as before
    +-- NEW: After task complete, runs self-verification prompt if criteria present
    +-- UNCHANGED: WebSocket relay, queue.json, result watcher, git workflow
```

### Scheduler Integration Detail

```elixir
# Current do_assign/2 in scheduler.ex sends:
task_data = %{
  task_id: assigned_task.id,
  description: assigned_task.description,
  metadata: assigned_task.metadata,
  generation: assigned_task.generation
}

# After milestone 2, adds:
task_data = %{
  task_id: assigned_task.id,
  description: assigned_task.description,
  metadata: assigned_task.metadata,
  generation: assigned_task.generation,
  # NEW fields:
  complexity: assigned_task.complexity,         # "trivial" | "standard" | "complex"
  model: assigned_task.model,                   # "qwen3:8b" | nil (use agent's own)
  ollama_endpoint: assigned_task.ollama_endpoint, # "http://host:11434" | nil
  context: assigned_task.context,               # map with project context
  acceptance_criteria: assigned_task.acceptance_criteria,  # list of check strings
  self_verify: assigned_task.self_verify        # boolean
}
```

### OllamaPool Supervision

```elixir
# New entry in Application.children list (after TaskQueue, before Scheduler):
{AgentCom.OllamaPool, []}
```

The OllamaPool GenServer must start BEFORE the Scheduler so that when the
Scheduler processes its first event, `OllamaPool.available_models()` is ready.

### Ollama API Endpoints Used

| Endpoint | Method | Purpose | Called From |
|----------|--------|---------|------------|
| `GET /api/version` | GET | Health check (returns `{"version": "0.15.6"}`) | Hub OllamaPool (periodic, every 30s) |
| `GET /api/tags` | GET | List available models on instance | Hub OllamaPool (periodic, every 60s + on-demand) |
| `GET /api/ps` | GET | Running models + `size_vram` field | Hub OllamaPool (periodic, every 60s) |
| `POST /api/chat` | POST | Chat completion with structured output | Sidecar TrivialExecutor (trivial tasks, verification) |

### Sidecar Config Changes

```json
{
  "agent_id": "gcu-conditions-permitting",
  "token": "...",
  "hub_url": "ws://localhost:4000/ws",
  "wake_command": "echo 'Waking for task ${TASK_ID}'",
  "capabilities": ["code"],
  "ollama_host": "http://localhost:11434",
  "trivial_execution": true,
  "trivial_model": "qwen3:8b",
  "self_verification": true,
  "verification_model": "qwen3:8b"
}
```

New fields: `ollama_host`, `trivial_execution`, `trivial_model`, `self_verification`, `verification_model`.
All optional with sensible defaults. Backward-compatible with existing configs.

---

## Installation

### Hub (Elixir)

```elixir
# mix.exs - add to deps
defp deps do
  [
    # ... existing deps ...
    {:req, "~> 0.5.0"}
  ]
end
```

```bash
mix deps.get
```

### Sidecar (Node.js)

```bash
cd sidecar
npm install ollama@^0.6.3
```

### Infrastructure (Per Ollama Host Machine)

```bash
# Install Ollama (if not already installed)
curl -fsSL https://ollama.com/install.sh | sh

# Pull Qwen3 8B (default quantization is Q4_K_M)
ollama pull qwen3:8b

# Verify GPU detection
ollama ps

# Configure Ollama to listen on all interfaces (for Tailscale access)
# Set OLLAMA_HOST=0.0.0.0:11434 in systemd unit or environment
# On Windows: set OLLAMA_HOST=0.0.0.0:11434 as system env var
```

---

## Configuration

### Hub Application Config

```elixir
# config/config.exs
config :agent_com, :ollama_pool,
  # List of Ollama instances on the Tailscale mesh
  endpoints: [
    %{host: "nathan-pc", port: 11434, label: "rtx3080ti"},
    %{host: "second-machine", port: 11434, label: "cpu-only"}
  ],
  health_check_interval_ms: 30_000,
  model_sync_interval_ms: 60_000,
  health_failure_threshold: 3  # mark as :down after 3 consecutive failures

config :agent_com, :task_classification,
  # Keywords/patterns that hint at trivial tasks
  trivial_patterns: ["write file", "git status", "heartbeat", "status report"],
  # Default model for each tier
  models: %{
    trivial: "qwen3:8b",
    standard: "qwen3:8b",
    complex: nil  # nil = don't assign model, agent uses its own (Claude)
  }
```

---

## Req Usage Patterns for Ollama

### Health Check

```elixir
def check_health(endpoint) do
  url = "http://#{endpoint.host}:#{endpoint.port}/api/version"

  case Req.get(url, receive_timeout: 5_000, retry: false) do
    {:ok, %{status: 200, body: %{"version" => version}}} ->
      {:ok, version}
    {:ok, %{status: status}} ->
      {:error, {:unexpected_status, status}}
    {:error, reason} ->
      {:error, reason}
  end
end
```

### List Models

```elixir
def list_models(endpoint) do
  url = "http://#{endpoint.host}:#{endpoint.port}/api/tags"

  case Req.get(url, receive_timeout: 10_000) do
    {:ok, %{status: 200, body: %{"models" => models}}} ->
      {:ok, models}
    {:error, reason} ->
      {:error, reason}
  end
end
```

### List Running Models (VRAM)

```elixir
def list_running(endpoint) do
  url = "http://#{endpoint.host}:#{endpoint.port}/api/ps"

  case Req.get(url, receive_timeout: 10_000) do
    {:ok, %{status: 200, body: %{"models" => models}}} ->
      # Each model has: name, size, size_vram, digest, details, expires_at
      {:ok, models}
    {:error, reason} ->
      {:error, reason}
  end
end
```

---

## Sidecar ollama npm Usage Patterns

### Trivial Task Execution

```javascript
const { Ollama } = require('ollama');

const ollama = new Ollama({ host: config.ollama_host || 'http://127.0.0.1:11434' });

async function executeTrivial(task) {
  const response = await ollama.chat({
    model: task.model || config.trivial_model || 'qwen3:8b',
    messages: [
      { role: 'system', content: 'You are a task executor. Respond with JSON.' },
      { role: 'user', content: task.description }
    ],
    format: 'json',
    stream: false
  });

  return JSON.parse(response.message.content);
}
```

### Self-Verification

```javascript
async function selfVerify(task, result) {
  const response = await ollama.chat({
    model: config.verification_model || 'qwen3:8b',
    messages: [
      {
        role: 'system',
        content: 'You are a verification checker. Given a task and its result, check each acceptance criterion. Respond with JSON: { "passed": boolean, "checks": [{"criterion": "...", "passed": boolean, "reason": "..."}] }'
      },
      {
        role: 'user',
        content: `Task: ${task.description}\nCriteria: ${JSON.stringify(task.acceptance_criteria)}\nResult: ${JSON.stringify(result)}`
      }
    ],
    format: {
      type: 'object',
      properties: {
        passed: { type: 'boolean' },
        checks: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              criterion: { type: 'string' },
              passed: { type: 'boolean' },
              reason: { type: 'string' }
            },
            required: ['criterion', 'passed', 'reason']
          }
        }
      },
      required: ['passed', 'checks']
    },
    stream: false
  });

  return JSON.parse(response.message.content);
}
```

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|----------------|-------|
| Req ~> 0.5.0 | Elixir >= 1.13, OTP >= 25 | Project requires Elixir ~> 1.14 (compatible). Uses Finch internally. No conflict with existing deps. |
| ollama npm ^0.6.3 | Node.js >= 18 | Uses native fetch (Node 18+). Check sidecar Node version. Accepts custom fetch for older runtimes. |
| Ollama server 0.15.x | Qwen3 8B, structured output, /api/ps | Stable REST API. `format` parameter accepts JSON Schema since v0.5. `/api/ps` includes `size_vram` field. |
| Qwen3 8B Q4_K_M | RTX 3080 Ti 12GB | ~6-7GB VRAM including KV cache. Leaves 5-6GB headroom. Supports structured output and tool calling. |

---

## Dependency Count Impact

| Before Milestone 2 | After Milestone 2 |
|--------------------|--------------------|
| Hub: 7 runtime deps in mix.exs | Hub: 8 deps (+Req) |
| Sidecar: 3 deps in package.json | Sidecar: 4 deps (+ollama) |
| Total new runtime deps: **2** | |

Req brings Finch and Mint as transitive deps, but Mint is already present (used by
fresh for WebSocket testing). Net new transitive deps are minimal.

Compared to previous research: dropped ex_json_schema (-1 dep) because extending
existing `AgentCom.Validation` is more consistent and avoids dual validation paradigms.

---

## New Validation Schemas (Extending Existing System)

The enriched task format requires new schemas in `AgentCom.Validation.Schemas`:

```elixir
# New HTTP schema for enriched task submission
post_enriched_task: %{
  required: %{
    "description" => :string
  },
  optional: %{
    "priority" => :string,
    "metadata" => :map,
    "max_retries" => :integer,
    "complete_by" => :integer,
    "needed_capabilities" => {:list, :string},
    # NEW enriched fields:
    "context" => :map,
    "acceptance_criteria" => {:list, :string},
    "complexity_hint" => :string,
    "preferred_model" => :string,
    "self_verify" => :boolean
  },
  description: "Submit an enriched task with context, criteria, and model hints."
}

# New WS schema for verification results from sidecar
"task_verification" => %{
  required: %{
    "type" => :string,
    "task_id" => :string,
    "generation" => :integer,
    "passed" => :boolean
  },
  optional: %{
    "checks" => {:list, :map},
    "model_used" => :string,
    "tokens_used" => :integer
  },
  description: "Sidecar reports self-verification results."
}
```

This follows the exact pattern used by all 27 existing schemas -- no new validation
infrastructure needed.

---

## Sources

- [Req v0.5.17 on Hex](https://hex.pm/packages/req) -- version, dependencies, release date Jan 2026 (HIGH confidence)
- [Req documentation](https://hexdocs.pm/req/Req.html) -- streaming `into:`, retry, JSON support, Finch pool config (HIGH confidence)
- [Elixir Forum: Req vs HTTPoison](https://elixirforum.com/t/preferred-http-library-req-or-httpoison/71163) -- community consensus favoring Req (HIGH confidence)
- [ollama npm v0.6.3](https://www.npmjs.com/package/ollama) -- version, 412 dependents (HIGH confidence)
- [ollama-js GitHub README](https://github.com/ollama/ollama-js) -- API methods: chat, generate, list, ps, host config, format parameter (HIGH confidence)
- [Ollama API docs on GitHub](https://github.com/ollama/ollama/blob/main/docs/api.md) -- all endpoints, /api/ps response fields including size_vram (HIGH confidence)
- [Ollama releases](https://github.com/ollama/ollama/releases) -- v0.15.6 current as of Feb 7, 2026 (HIGH confidence)
- [Ollama structured outputs docs](https://docs.ollama.com/capabilities/structured-outputs) -- format parameter, JSON Schema support (HIGH confidence)
- [Ollama VRAM requirements guide](https://localllm.in/blog/ollama-vram-requirements-for-local-llms) -- Q4_K_M at 6-7GB for 8B models (MEDIUM confidence)
- [Qwen3 8B on Ollama](https://ollama.com/library/qwen3:8b) -- model details, structured output, tool calling (HIGH confidence)
- [ollama hex package v0.9.0](https://hex.pm/packages/ollama) -- alternative considered, last updated Sep 2025 (HIGH confidence)
- [Tailscale MagicDNS](https://tailscale.com/blog/magicdns-why-name) -- hostname resolution (HIGH confidence)

---
*Stack research for: AgentCom Milestone 2 -- LLM Mesh Routing & Enriched Tasks*
*Researched: 2026-02-12 (revision of 2026-02-11 research)*
*Changes from v1: dropped ex_json_schema (extend existing validation instead), updated Ollama server to v0.15.x, added Req usage patterns, added sidecar ollama npm patterns, added validation schema examples*
