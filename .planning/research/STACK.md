# Technology Stack: LLM Mesh Routing & Enriched Tasks

**Project:** AgentCom v2 -- Milestone 2 (Distributed LLM, Enriched Tasks, Self-Verification)
**Researched:** 2026-02-11
**Confidence:** HIGH (Ollama API verified via docs, Req verified via Hex, npm ollama verified)

## Scope

This document covers ONLY the stack additions for milestone 2 features:
1. Distributed LLM routing (Ollama across Tailscale mesh)
2. Enriched task format with context/criteria
3. Model-aware scheduling
4. Sidecar trivial execution (zero-token tasks)
5. Agent self-verification

Existing stack (Elixir/BEAM, Bandit, Phoenix.PubSub, Jason, ws, chokidar, etc.) is
unchanged and not re-documented here. See milestone 1 STACK.md for baseline.

---

## Recommended Stack Additions

### Hub-Side (Elixir)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Req | ~> 0.5.0 | HTTP client for Ollama API calls | Batteries-included Elixir HTTP client. Supports streaming responses (`into:` option), automatic JSON decode, retries, connection pooling via Finch. Already standard in Elixir ecosystem. v0.5.17 current (Jan 2026). Replaces need for HTTPoison (already a dep but heavier, callback-based). |
| ex_json_schema | ~> 0.11.0 | Task schema validation | Validates enriched task format against JSON Schema draft 4/7. Zero dependencies. v0.11.2 current (Dec 2025). Used to validate task submission payloads and self-verification result schemas. |

### Sidecar-Side (Node.js)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| ollama (npm) | ^0.6.3 | Ollama client for sidecar trivial execution | Official Ollama JavaScript library. Supports chat(), generate(), list(), structured output via `format` parameter, configurable `host` for remote instances. Handles streaming. v0.6.3 current. |

### Infrastructure (No Code Dependency)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Ollama | latest (0.7.x) | Local LLM inference server | Runs on each Tailscale machine with GPU. Exposes REST API on port 11434. Supports model management, GPU memory reporting (`/api/ps`), health check (`GET /`), structured output. |
| Qwen3 8B | Q4_K_M quant | Primary local inference model | Fits in 12GB VRAM (4.7GB at Q4_K_M). Supports tool calling, structured JSON output, thinking/non-thinking modes. 32K native context. Handles tiers 1-2 tasks per existing analysis. RTX 3080 Ti runs at 40+ tok/s. |
| Tailscale MagicDNS | (existing) | Cross-machine Ollama discovery | Already deployed for agent mesh. MagicDNS resolves hostnames automatically (e.g., `nathan-pc.tail1234.ts.net`). Hub discovers Ollama instances at `http://{hostname}:11434`. No additional service discovery needed. |

### Custom Implementations (No Dependency)

| Component | Approach | Lines (est.) | Why Custom |
|-----------|----------|-------------|------------|
| OllamaPool | GenServer managing Ollama endpoint registry | ~200 | Tracks multiple Ollama instances across Tailscale. Periodic health checks (`GET /`), model inventory (`GET /api/tags`), VRAM status (`GET /api/ps`). No off-the-shelf Elixir Ollama pool exists for multi-host routing. |
| TaskClassifier | Pure function module | ~80 | Classifies task complexity (trivial/standard/complex) from enriched task metadata. Drives model routing decisions. Domain-specific logic, not a library concern. |
| VerificationEngine | GenServer processing verification results | ~150 | Accepts self-verification reports from agents, validates against task criteria, updates task status. Unique to AgentCom's task lifecycle. |
| EnrichedTaskSchema | JSON Schema + validation module | ~60 | Schema definition for enriched task format (context, criteria, model hints). Uses ex_json_schema for validation. |

### Already Present (No Change Needed)

| Technology | Version | Role in Milestone 2 |
|------------|---------|---------------------|
| Phoenix.PubSub | ~> 2.1 | Broadcasts Ollama pool status changes, model routing events, verification results |
| Jason | ~> 1.4 | JSON encoding/decoding for Ollama API payloads, enriched task serialization |
| DETS | OTP stdlib | Persists enriched task fields (context, criteria, model, verification_status) |
| Registry | OTP stdlib | OllamaPool endpoint registry, verification result routing |
| :telemetry | 1.3.0 (via Bandit) | Instrument Ollama call latency, token counts, routing decisions |
| ws (npm) | ^8.19.0 | WebSocket relay unchanged. Enriched task payloads flow through existing channel |
| write-file-atomic (npm) | ^5.0.0 | Queue persistence for sidecar. Enriched task data persisted same way |
| chokidar (npm) | ^3.6.0 | Result file watcher unchanged. Verification results use same .json pattern |

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| HTTP Client (Elixir) | Req ~> 0.5 | HTTPoison (already in deps) | HTTPoison is already present but uses hackney adapter which is in maintenance mode. Req uses Finch (modern, connection-pooling HTTP2). Req has better streaming support via `into:` parameter. |
| HTTP Client (Elixir) | Req ~> 0.5 | ollama hex package 0.9.0 | The `ollama` Hex package wraps Ollama API but adds an opinionated layer. We need low-level control over health checks, `/api/ps` polling, and multi-host routing that a wrapper hides. Req gives us direct HTTP with less abstraction. |
| HTTP Client (Elixir) | Req ~> 0.5 | Tesla ~> 1.13 | Tesla adds middleware abstraction we don't need. Req is simpler, has streaming built-in, and is the current community standard. |
| LLM Client (Node.js) | ollama npm | Raw fetch/http calls | Official ollama library handles streaming, structured output format parameter, host configuration. Doing this manually would be ~200 lines of fetch boilerplate for no benefit. |
| LLM Client (Node.js) | ollama npm | @langchain/ollama | LangChain is a heavy framework with chains, agents, memory abstractions we don't need. Our sidecar does ONE thing: send a task description to Ollama and get structured JSON back. |
| Task Validation | ex_json_schema | Ecto changesets | Ecto is a massive dependency for simple JSON validation. We have flat schemas with no nested forms, no database, no associations. |
| Task Validation | ex_json_schema | Custom pattern matching | Enriched task schema has optional nested fields (context, criteria arrays, model preferences). JSON Schema handles optionals and nested structures more maintainably than hand-rolled pattern matching. |
| Service Discovery | Tailscale MagicDNS + config | Consul / etcd | Overkill for 3-5 machines. MagicDNS already resolves hostnames. A simple config list of `[{hostname, port}]` pairs with health checks is sufficient. |
| Model Routing | Custom TaskClassifier | LiteLLM proxy | LiteLLM is a Python proxy adding another runtime to manage. Our routing logic is simple (3 tiers) and lives naturally in the Elixir scheduler. |

---

## What NOT to Add

| Avoid | Why | Do Instead |
|-------|-----|------------|
| LangChain (any variant) | Framework overhead for simple prompt-response pattern. Adds chains, memory, agent abstractions that conflict with AgentCom's own agent model. | Direct Ollama API calls via `ollama` npm package (sidecar) and `Req` (hub). |
| vLLM / TGI inference servers | Complex GPU serving infrastructure for a 5-agent system. Ollama handles model management, quantization, and GPU scheduling already. | Ollama on each machine. If you outgrow it, revisit. |
| OpenAI SDK for Ollama | Ollama's OpenAI compatibility endpoint is "experimental" per their docs. The native `/api/chat` endpoint is stable and returns richer metadata (timing, token counts). | Use Ollama native API endpoints directly. |
| Redis / external message broker | System is single-hub, 5 agents. Phoenix.PubSub with local adapter handles all event distribution. Adding Redis adds operational complexity. | Continue using Phoenix.PubSub for all event distribution. |
| Ecto | No database in this system. DETS is the persistence layer. Adding Ecto would require rethinking the entire data layer for no benefit at this scale. | Continue DETS for persistence. Use ex_json_schema for validation. |
| Vector database (Qdrant, Pinecone) | No semantic search or RAG requirements in scope. Task matching is capability-based, not similarity-based. | Continue using exact-match capability filtering in scheduler. |

---

## Integration Points

### How New Stack Connects to Existing Code

```
Existing Scheduler (scheduler.ex)
    |
    +-- NEW: Checks OllamaPool for available models
    +-- NEW: Uses TaskClassifier to determine model tier
    +-- NEW: Adds `model` field when assigning task
    |
    v
Existing TaskQueue (task_queue.ex)
    |
    +-- NEW: Enriched task map gains fields:
    |     context, acceptance_criteria, model, complexity,
    |     verification_status, verification_result
    +-- UNCHANGED: DETS persistence, priority index, generation fencing
    |
    v
Existing Sidecar (sidecar/index.js)
    |
    +-- NEW: Checks task.complexity == "trivial"
    +-- NEW: If trivial, calls Ollama directly via `ollama` npm
    +-- NEW: If not trivial, wakes agent as before
    +-- NEW: After task complete, runs self-verification prompt
    +-- UNCHANGED: WebSocket relay, queue.json, result watcher
```

### Ollama API Endpoints Used

| Endpoint | Method | Purpose | Called From |
|----------|--------|---------|------------|
| `GET /` | GET | Health check ("Ollama is running") | Hub OllamaPool (periodic) |
| `GET /api/tags` | GET | List available models on instance | Hub OllamaPool (periodic + on-demand) |
| `GET /api/ps` | GET | Running models + VRAM usage | Hub OllamaPool (periodic) |
| `POST /api/chat` | POST | Chat completion (trivial task execution) | Sidecar (trivial tasks) |
| `POST /api/generate` | POST | Text generation (simple prompts) | Sidecar (trivial tasks, verification) |

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
  "self_verification": true
}
```

New fields: `ollama_host`, `trivial_execution`, `trivial_model`, `self_verification`.
All optional with sensible defaults. Backward-compatible with existing configs.

---

## Installation

### Hub (Elixir)

```elixir
# mix.exs - add to deps
defp deps do
  [
    # ... existing deps ...
    {:req, "~> 0.5.0"},
    {:ex_json_schema, "~> 0.11.0"}
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

# Pull Qwen3 8B with Q4_K_M quantization (default)
ollama pull qwen3:8b

# Verify GPU detection
ollama ps

# Configure Ollama to listen on all interfaces (for Tailscale access)
# Set OLLAMA_HOST=0.0.0.0:11434 in systemd unit or environment
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
  model_sync_interval_ms: 60_000

config :agent_com, :task_classification,
  # Keywords that hint at trivial tasks
  trivial_patterns: ["write file", "git status", "heartbeat", "status report"],
  # Default model for each tier
  models: %{
    trivial: "qwen3:8b",
    standard: "qwen3:8b",
    complex: nil  # nil = don't assign model, agent uses its own (Claude)
  }
```

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|----------------|-------|
| Req ~> 0.5.0 | Elixir >= 1.13, OTP >= 25 | Project requires Elixir ~> 1.14, so compatible. Uses Finch internally. |
| ex_json_schema ~> 0.11.0 | Elixir >= 1.11 | Zero external dependencies. Uses only Elixir stdlib. |
| ollama npm ^0.6.3 | Node.js >= 18 | Uses native fetch. Check sidecar Node version. |
| Ollama server 0.7.x | Qwen3 8B, structured output, /api/ps | /api/ps VRAM reporting has known leak bug in 0.7.0 (fixed in later patches). |
| Qwen3 8B Q4_K_M | RTX 3080 Ti 12GB | 4.7GB VRAM at Q4_K_M. Leaves ~7GB for context and concurrent requests. |

---

## Dependency Count Impact

| Before Milestone 2 | After Milestone 2 |
|--------------------|--------------------|
| Hub: 7 deps in mix.exs | Hub: 9 deps (+Req, +ex_json_schema) |
| Sidecar: 3 deps in package.json | Sidecar: 4 deps (+ollama) |
| Total new runtime deps: **3** | |

Req brings Finch and Mint as transitive deps, but Mint is already present (used by
fresh for WebSocket testing). Net new transitive deps are minimal.

---

## Sources

- [Ollama API documentation](https://ollama.readthedocs.io/en/api/) -- endpoint reference, streaming format (HIGH confidence)
- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility) -- why to avoid OpenAI compat endpoint (HIGH confidence)
- [Req v0.5.17 on Hex](https://hex.pm/packages/req) -- version, release date Jan 2026 (HIGH confidence)
- [Req documentation](https://hexdocs.pm/req/Req.html) -- streaming, JSON support (HIGH confidence)
- [ex_json_schema v0.11.2 on Hex](https://hex.pm/packages/ex_json_schema) -- version, Dec 2025 (HIGH confidence)
- [ollama npm v0.6.3](https://www.npmjs.com/package/ollama) -- version, API methods (HIGH confidence)
- [ollama-js GitHub](https://github.com/ollama/ollama-js) -- host configuration, structured output (HIGH confidence)
- [Qwen3 8B VRAM requirements](https://apxml.com/models/qwen3-8b) -- Q4_K_M at 4.7GB (MEDIUM confidence)
- [Ollama structured outputs](https://ollama.com/blog/structured-outputs) -- format parameter, JSON schema (HIGH confidence)
- [Tailscale MagicDNS](https://tailscale.com/blog/magicdns-why-name) -- hostname resolution (HIGH confidence)
- [Qwen3 tool support](https://qwen.readthedocs.io/en/latest/framework/function_call.html) -- function calling (MEDIUM confidence)
- [Ollama VRAM bug](https://medium.com/@rafal.kedziorski/ollamas-hidden-vram-bug-scripted-detection-and-cleanup-b3d6439d2199) -- 0.7.0 leak issue (MEDIUM confidence)

---
*Stack research for: AgentCom Milestone 2 -- LLM Mesh Routing & Enriched Tasks*
*Researched: 2026-02-11*
