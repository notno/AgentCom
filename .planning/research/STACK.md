# Technology Stack: Agentic Tool Calling, Hub FSM Healing & Ollama Routing

**Project:** AgentCom v2 -- Milestone 3 (Agentic Execution, Self-Healing FSM, Hub LLM Routing)
**Researched:** 2026-02-14
**Confidence:** HIGH (Ollama tool calling API verified via official docs, ollama-js verified via GitHub/npm, GenServer testing patterns verified via Elixir community sources)

## Scope

This document covers ONLY the stack additions/changes for milestone 3 features:

1. Ollama native function/tool calling API integration in sidecar
2. Agentic execution loop in Node.js sidecar (ReAct-style tool use)
3. Self-healing FSM state (`:healing`) in Elixir Hub FSM
4. Hub FSM integration testing improvements
5. Routing Hub LLM calls through Ollama instead of `claude -p` CLI

Existing stack from Milestone 2 (Req, ollama npm, OllamaPool, TaskClassifier, etc.) is
assumed present and not re-documented here.

---

## Recommended Stack Additions

### Hub-Side (Elixir) -- No New Dependencies

No new hex packages required. All changes use existing dependencies:

| Technology | Already Present | New Usage |
|------------|----------------|-----------|
| Req ~> 0.5.0 | Yes (Milestone 2) | Replace `ClaudeClient.Cli` System.cmd calls with Ollama `/api/chat` HTTP calls via Req. Add tool-calling-formatted requests for Hub LLM operations. |
| GenServer (OTP) | Yes (stdlib) | Add `:healing` state to HubFSM. No new behaviour needed -- GenServer handles this. Do NOT migrate to `:gen_statem`; the existing GenServer pattern with `@valid_transitions` map is working and well-tested. |
| ExUnit (OTP) | Yes (stdlib) | New integration test patterns for 5-state FSM. Use `start_supervised!/2` and direct `send/2` for tick simulation (pattern already established in existing `hub_fsm_test.exs`). |

### Sidecar-Side (Node.js) -- No New Dependencies

| Technology | Already Present | New Usage |
|------------|----------------|-----------|
| ollama npm ^0.6.3 | Yes (Milestone 2) | Use `chat()` with `tools` parameter for function/tool calling. Build agentic ReAct loop on top. |
| Node.js built-in `child_process` | Yes (ShellExecutor) | Reuse existing `spawn` pattern from ShellExecutor for tool-invoked shell commands. |
| Node.js built-in `fs/promises` | Yes (stdlib) | File operation tools (read, write, list) for agentic execution. |
| Node.js built-in `test` runner | Yes (package.json scripts) | Integration tests for agentic loop. Already using `node --test`. |

### Custom Implementations (No External Dependency)

| Component | Approach | Lines (est.) | Why Custom |
|-----------|----------|-------------|------------|
| AgenticExecutor | New class in sidecar | ~350 | ReAct loop: send task + tools to Ollama, parse tool_calls, execute tools, feed results back, repeat until done or max iterations. No off-the-shelf library fits because: (1) we need tight integration with existing ShellExecutor/OllamaExecutor patterns, (2) tool definitions are AgentCom-specific (hub API, git, file ops), (3) must report progress via existing `onProgress` callback, (4) must conform to existing ExecutionResult format. Building a framework-agnostic agentic loop from ollama-js `chat()` is ~350 lines vs. pulling in a framework like LangChain (~50MB) or Bee Agent Framework that would impose their own abstractions. |
| ToolRegistry | Module in sidecar | ~150 | Registry of available tools with their Ollama-format schemas and execution functions. Maps tool names to handlers (shell, file_read, file_write, git_status, hub_api). Keeps tool definitions in one place for the agentic loop. |
| HubLLMClient | New Elixir module | ~200 | Replaces `ClaudeClient.Cli` for Hub FSM LLM operations. Calls Ollama `/api/chat` via Req with tool calling support. Handles streaming NDJSON response parsing (pattern already exists in sidecar OllamaExecutor). Same API surface as ClaudeClient (decompose_goal, verify_completion, identify_improvements, generate_proposals) but routes through Ollama. |
| HubFSM.Healing | Extension to existing FSM | ~100 | New `:healing` state in `@valid_transitions`. Healing predicates in `HubFSM.Predicates`. Async healing cycle spawned on enter (same pattern as `:improving` and `:contemplating`). |
| HubFSM.HealthCheck | New module | ~80 | Gathers infrastructure health signals (Ollama reachability, sidecar connectivity, DETS integrity) that the Healing state acts on. Consumed by `HubFSM.Predicates` to trigger healing transitions. |

### Already Present (No Change Needed)

| Technology | Role in Milestone 3 |
|------------|---------------------|
| Phoenix.PubSub ~> 2.1 | Broadcasts healing state changes, agentic execution progress |
| Jason ~> 1.4 | JSON encode/decode for Ollama tool calling payloads |
| DETS (OTP stdlib) | Persists healing history, agentic execution logs |
| ETS (OTP stdlib) | Fast health-state reads for healing predicates |
| :telemetry (via Bandit) | Instrument agentic loop iterations, tool call latency, healing cycles |
| ws npm ^8.19.0 | WebSocket relay unchanged. Agentic results flow through existing channel |
| write-file-atomic npm ^5.0.0 | Queue persistence unchanged |
| chokidar npm ^3.6.0 | Result file watcher unchanged |

---

## Key Technical Details

### 1. Ollama Tool Calling API Format

**Confidence: HIGH** (verified via [official Ollama docs](https://docs.ollama.com/capabilities/tool-calling))

The existing OllamaExecutor uses `/api/chat` with `stream: true` and plain messages. Tool calling extends this by adding a `tools` array to the request body.

**Request format:**

```json
{
  "model": "qwen3:8b",
  "messages": [
    {"role": "system", "content": "You are a coding agent..."},
    {"role": "user", "content": "Fix the failing test in auth.js"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "Read a file from the workspace",
        "parameters": {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path": {"type": "string", "description": "File path relative to workspace root"}
          }
        }
      }
    }
  ],
  "stream": false
}
```

**Response with tool calls:**

```json
{
  "message": {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "function": {
          "name": "read_file",
          "arguments": {"path": "test/auth.test.js"}
        }
      }
    ]
  },
  "done": true
}
```

**Tool result message:**

```json
{
  "role": "tool",
  "content": "// file contents here..."
}
```

**Critical implementation note:** When using tool calling, set `stream: false` initially. Streaming with tool calls works but requires accumulating `tool_calls` chunks and reconstructing the complete message before execution. Start with `stream: false` for reliability, optimize to streaming later if needed.

### 2. Models for Tool Calling on RTX 3080 Ti (12GB VRAM)

**Confidence: HIGH** (verified via Ollama model pages and VRAM guides)

| Model | VRAM (Q4_K_M) | Tool Calling | Recommendation |
|-------|---------------|-------------|----------------|
| Qwen3 8B | ~6-7GB | Yes, F1 0.933 | **Primary choice.** Best tool calling accuracy for size. Fits comfortably in 12GB with headroom for KV cache. ~40+ tok/s at Q4_K_M. |
| Llama 3.1 8B | ~6-7GB | Yes | Good alternative. Meta's tool calling improvements are solid. Slightly less accurate than Qwen3 on tool calling benchmarks. |
| Qwen3 4B | ~3-4GB | Yes | Faster but less accurate. Use only if running two models simultaneously or for simple tool calls. |
| Mistral 7B | ~5-6GB | Yes | Decent but Qwen3 8B outperforms it on structured output and tool calling. |

**Recommendation:** Use Qwen3 8B (Q4_K_M) for both sidecar agentic execution AND Hub LLM routing. Single model simplifies operations. It handles tool calling well and fits in 12GB VRAM.

### 3. Agentic Execution Loop Architecture

**Confidence: HIGH** (ReAct pattern is well-established; implementation is custom)

The agentic loop follows the standard ReAct (Reason + Act + Observe) pattern:

```
User Task
    |
    v
[1] Send task + tool definitions to Ollama /api/chat
    |
    v
[2] Parse response:
    - If response has tool_calls -> execute each tool -> add tool results to messages -> goto [1]
    - If response has content only (no tool_calls) -> task complete -> return result
    - If max iterations reached -> return partial result with warning
    |
    v
[3] Return ExecutionResult (same format as OllamaExecutor/ClaudeExecutor)
```

**Key design decisions:**

- **Max iterations:** 10 (configurable). Prevents runaway loops. Most tasks complete in 3-5 iterations.
- **Tool execution timeout:** 60s per tool call (reuse ShellExecutor timeout pattern).
- **Tool result truncation:** Cap tool output at 4000 chars to stay within context window.
- **Error handling:** Tool execution failures are reported back to the LLM as tool results with error messages. The LLM can retry or choose a different approach.
- **Progress reporting:** Each iteration fires `onProgress({ type: 'agentic_iteration', iteration: N, tool_calls: [...] })`.

### 4. Hub FSM Healing State

**Confidence: HIGH** (extending well-understood existing patterns)

The existing HubFSM uses a `@valid_transitions` map and `do_transition/3` for state management. Adding `:healing` requires:

**New transitions:**

```elixir
@valid_transitions %{
  resting: [:executing, :improving, :healing],       # +healing
  executing: [:resting, :healing],                    # +healing
  improving: [:resting, :executing, :contemplating],  # unchanged
  contemplating: [:resting, :executing],              # unchanged
  healing: [:resting, :executing]                     # NEW
}
```

**Healing triggers (in Predicates):**
- Ollama endpoint unreachable for > 3 consecutive health checks
- Sidecar disconnected and tasks stuck in `:assigned` for > 5 minutes
- DETS corruption detected (read error)
- Test suite regression detected (git hook failure)

**Healing actions:**
- Restart failed Ollama endpoints (via SSH/Tailscale or local restart)
- Reassign stuck tasks from disconnected sidecars
- DETS table repair/rebuild from backup
- Run targeted test suite and report results

**Healing cycle pattern** (mirrors existing `:improving` cycle):

```elixir
# In do_transition/3, after entering :healing
if new_state == :healing do
  pid = self()
  Task.start(fn ->
    result = AgentCom.SelfHealing.run_healing_cycle()
    send(pid, {:healing_cycle_complete, result})
  end)
end
```

### 5. Hub LLM Routing Through Ollama

**Confidence: HIGH** (replacing System.cmd with HTTP calls via already-present Req)

The current flow is:
```
ClaudeClient -> ClaudeClient.Cli -> System.cmd("claude", ["-p", ...]) -> parse JSON output
```

The new flow will be:
```
ClaudeClient -> HubLLMClient -> Req.post("http://localhost:11434/api/chat", ...) -> parse JSON response
```

**Key changes:**

1. **New module `AgentCom.HubLLMClient`** -- drop-in replacement for `ClaudeClient.Cli`. Same `invoke/3` API but calls Ollama HTTP instead of CLI.
2. **ClaudeClient stays as-is** -- just swap the backend it calls. Change one line in `handle_call`:
   ```elixir
   # Before:
   AgentCom.ClaudeClient.Cli.invoke(prompt_type, params, state)
   # After:
   AgentCom.HubLLMClient.invoke(prompt_type, params, state)
   ```
3. **Prompt module reuse** -- `ClaudeClient.Prompt.build/2` already builds prompts as strings. These become the `user` message content for Ollama.
4. **Response module adaptation** -- `ClaudeClient.Response.parse/3` currently parses Claude CLI JSON output. Need a parallel `HubLLMClient.Response` that parses Ollama `/api/chat` response format.
5. **Configuration change:**
   ```elixir
   # Before:
   config :agent_com, :claude_cli_path, "claude"
   config :agent_com, :claude_model, "sonnet"

   # After:
   config :agent_com, :hub_llm_backend, :ollama  # or :claude for fallback
   config :agent_com, :hub_llm_model, "qwen3:8b"
   config :agent_com, :hub_llm_endpoint, "http://localhost:11434"
   ```
6. **Budget tracking unchanged** -- `CostLedger.record_invocation/2` works the same way. Ollama calls are free (local) but still worth tracking for rate limiting and metrics.

**Ollama request for Hub LLM operations:**

```elixir
def invoke(:decompose, params, state) do
  prompt = AgentCom.ClaudeClient.Prompt.build(:decompose, params)

  body = %{
    model: state.model,
    messages: [
      %{role: "system", content: "You are a goal decomposition engine. Respond with valid JSON."},
      %{role: "user", content: prompt}
    ],
    format: "json",
    stream: false
  }

  case Req.post("#{state.endpoint}/api/chat", json: body, receive_timeout: 120_000) do
    {:ok, %{status: 200, body: %{"message" => %{"content" => content}}}} ->
      AgentCom.HubLLMClient.Response.parse(content, :decompose)
    {:ok, %{status: status, body: body}} ->
      {:error, {:ollama_error, status, body}}
    {:error, reason} ->
      {:error, {:http_error, reason}}
  end
end
```

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Agentic Framework (Node.js) | Custom ReAct loop (~350 LOC) | LangChain.js / @langchain/ollama | LangChain adds ~50MB of dependencies, imposes chain/agent/memory abstractions that conflict with AgentCom's own architecture. Our loop is simple: call Ollama with tools, execute tool calls, feed back results. ~350 lines vs. learning and fighting a framework. |
| Agentic Framework (Node.js) | Custom ReAct loop | Bee Agent Framework | TypeScript-first with heavy type system. Our sidecar is plain JavaScript. Would require TS compilation pipeline. Also imposes its own agent model. |
| Agentic Framework (Node.js) | Custom ReAct loop | OpenAI Agents SDK (JS) | Designed for OpenAI API, not Ollama. Would need adapter layer. Adds complexity for no benefit. |
| Agentic Framework (Node.js) | Custom ReAct loop | Vercel AI SDK | Primarily designed for streaming chat UIs. Agentic capabilities are secondary. Heavy dependency tree. |
| FSM Implementation | Extend GenServer | Migrate to :gen_statem | The existing GenServer-based FSM is working, well-tested (47 lines of tests), and well-understood. Migrating to :gen_statem would require rewriting all callbacks, tests, and the History module for ONE new state. :gen_statem benefits (postpone, state enter callbacks, typed timeouts) are not needed here -- our tick-based evaluation handles everything. |
| FSM Implementation | Extend GenServer | gen_state_machine hex package | Wrapper around :gen_statem. Same migration cost as above, plus an external dependency. |
| Hub LLM Backend | Ollama via Req | Keep claude -p CLI | The CLI approach has known bugs (>7000 char stdin issue requiring temp files), is slow (cold start per invocation), costs money (Claude API fees), and requires internet. Ollama is local, free, fast (model stays loaded in VRAM), and already deployed for sidecar tasks. |
| Hub LLM Backend | Ollama via Req | LiteLLM proxy | Adds a Python process as middleware between Elixir and Ollama. Extra failure point, extra process to manage, extra complexity. Direct HTTP calls via Req are simpler. |
| Hub LLM Backend | Ollama via Req | ollama hex package 0.9.0 | Same issue as Milestone 2 research: stale (Sep 2025), adds transitive deps, single-client model doesn't fit our multi-endpoint architecture. |
| Testing | ExUnit + send(:tick) | Mox for mock-based testing | The existing test pattern (direct `send(pid, :tick)` with real GoalBacklog/CostLedger) is already established and works well. Adding Mox would introduce a second testing paradigm. For the Healing state, follow the same pattern: set up conditions, send tick, assert state. |
| Testing | ExUnit + send(:tick) | Property-based testing (StreamData) | Overkill for FSM transitions. The state space is small (5 states, ~12 transitions). Exhaustive case testing with ExUnit is sufficient and more readable. |

---

## What NOT to Add

| Avoid | Why | Do Instead |
|-------|-----|------------|
| LangChain / any agent framework | 50MB+ deps, imposes foreign abstractions, our use case is simple ReAct loop | Custom AgenticExecutor class (~350 LOC) using ollama npm `chat()` with `tools` parameter |
| :gen_statem migration | Rewrite cost for no benefit. Existing GenServer FSM works. | Add `:healing` to `@valid_transitions` map, add handler in `do_transition/3` |
| Separate Ollama client library (Elixir) | Already have Req. Adding another abstraction layer is unnecessary. | Use Req.post/get directly for Ollama calls (same pattern as OllamaPool health checks) |
| MCP (Model Context Protocol) | Emerging standard but overkill for local tool calling. Adds protocol complexity between sidecar and Ollama. Our tools are simple function calls. | Define tools directly in Ollama API `tools` array |
| Streaming for tool calling (initially) | Streaming + tool calls requires chunk accumulation logic. Non-streaming is simpler and reliable. | Start with `stream: false` for tool calling. Optimize to streaming later if latency matters. |
| External process supervisor for healing | Erlang/OTP already supervises processes. Adding systemd/pm2 orchestration from Elixir is fragile. | Healing actions: reassign tasks, rebuild DETS, restart GenServers via Supervisor API. For Ollama restarts, use simple HTTP health checks + alert (human intervention for server-level restarts). |
| Claude API as fallback | Adds complexity (two backends), internet dependency, and cost. If Ollama is down, the Healing state should fix it, not fall back to paid API. | Single backend (Ollama). Healing state handles Ollama outages. |

---

## Integration Points

### How New Components Connect to Existing Code

```
Existing Dispatcher (dispatcher.js)
    |
    +-- EXISTING: 'ollama' -> OllamaExecutor (text generation only)
    +-- NEW: 'agentic' -> AgenticExecutor (tool-calling loop)
    |         |
    |         +-- Uses ToolRegistry for tool schemas
    |         +-- Uses ollama npm chat() with tools parameter
    |         +-- Calls ShellExecutor._runCommand() for shell tools
    |         +-- Uses fs/promises for file tools
    |         +-- Uses http for hub API tools
    |         |
    |         +-- Returns same ExecutionResult format
    |
    v
Existing HubFSM (hub_fsm.ex)
    |
    +-- EXISTING: 4 states (resting/executing/improving/contemplating)
    +-- NEW: 5th state :healing
    |         |
    |         +-- Entered from: resting, executing (when health check fails)
    |         +-- Exits to: resting, executing
    |         +-- Spawns SelfHealing.run_healing_cycle() (same pattern as SelfImprovement)
    |
    +-- EXISTING: ClaudeClient for LLM operations
    +-- CHANGED: ClaudeClient backend swapped from Cli to HubLLMClient
    |         |
    |         +-- HubLLMClient.invoke/3 replaces Cli.invoke/3
    |         +-- Uses Req.post to Ollama /api/chat
    |         +-- Reuses ClaudeClient.Prompt for prompt building
    |         +-- New HubLLMClient.Response for Ollama response parsing
    |
    v
Existing TaskClassifier
    |
    +-- EXISTING: trivial/standard/complex classification
    +-- NEW: 'agentic' classification for tasks requiring tool use
    |         |
    |         +-- Detected by: presence of tool_hints in metadata,
    |         |   keywords like "fix", "implement", "debug", "create"
    |         +-- Routes to AgenticExecutor instead of plain OllamaExecutor
```

### Dispatcher Changes

```javascript
// In dispatcher.js switch statement, add new case:
case 'agentic': {
  const { AgenticExecutor } = require('./agentic-executor');
  rawResult = await new AgenticExecutor().execute(task, config, onProgress);
  break;
}
```

### Tool Registry Schema (Sidecar)

```javascript
// tool-registry.js
const TOOLS = [
  {
    type: 'function',
    function: {
      name: 'read_file',
      description: 'Read a file from the workspace',
      parameters: {
        type: 'object',
        required: ['path'],
        properties: {
          path: { type: 'string', description: 'File path relative to workspace root' }
        }
      }
    },
    handler: async (args, context) => {
      const content = await fs.readFile(path.resolve(context.workDir, args.path), 'utf8');
      return content.slice(0, 4000); // Truncate for context window
    }
  },
  {
    type: 'function',
    function: {
      name: 'write_file',
      description: 'Write content to a file',
      parameters: {
        type: 'object',
        required: ['path', 'content'],
        properties: {
          path: { type: 'string' },
          content: { type: 'string' }
        }
      }
    },
    handler: async (args, context) => {
      await fs.writeFile(path.resolve(context.workDir, args.path), args.content);
      return `Written ${args.content.length} bytes to ${args.path}`;
    }
  },
  {
    type: 'function',
    function: {
      name: 'run_shell',
      description: 'Run a shell command and return output',
      parameters: {
        type: 'object',
        required: ['command'],
        properties: {
          command: { type: 'string', description: 'Shell command to execute' }
        }
      }
    },
    handler: async (args, context) => {
      // Reuse ShellExecutor._runCommand pattern
      // With timeout and output truncation
    }
  },
  {
    type: 'function',
    function: {
      name: 'list_files',
      description: 'List files in a directory',
      parameters: {
        type: 'object',
        required: ['directory'],
        properties: {
          directory: { type: 'string' }
        }
      }
    },
    handler: async (args, context) => {
      const entries = await fs.readdir(path.resolve(context.workDir, args.directory));
      return entries.join('\n');
    }
  },
  {
    type: 'function',
    function: {
      name: 'task_complete',
      description: 'Signal that the task is complete with a summary',
      parameters: {
        type: 'object',
        required: ['summary'],
        properties: {
          summary: { type: 'string', description: 'Summary of what was accomplished' }
        }
      }
    },
    handler: async (args) => {
      return `TASK_COMPLETE: ${args.summary}`;
    }
  }
];
```

### HubFSM Test Patterns for Healing State

Follow the existing test patterns in `hub_fsm_test.exs`:

```elixir
describe "healing transitions" do
  test "transitions to :healing when health check fails" do
    # Force into executing state first
    :ok = HubFSM.force_transition(:executing, "setup")

    # Simulate health check failure (set up OllamaPool mock state)
    # ... set up conditions ...

    # Trigger tick
    send(Process.whereis(HubFSM), :tick)
    Process.sleep(100)

    assert HubFSM.get_state().fsm_state == :healing
  end

  test "healing cycle complete returns to :resting" do
    :ok = HubFSM.force_transition(:executing, "setup")
    :ok = HubFSM.force_transition(:healing, "test healing")

    # Simulate healing cycle completion
    send(Process.whereis(HubFSM), {:healing_cycle_complete, %{repaired: 1}})
    Process.sleep(100)

    assert HubFSM.get_state().fsm_state == :resting
  end

  test "invalid transition: contemplating -> healing returns error" do
    :ok = HubFSM.force_transition(:executing, "setup")
    :ok = HubFSM.force_transition(:resting, "reset")
    :ok = HubFSM.force_transition(:improving, "improve")

    # Contemplating can't go to healing (healing is for infrastructure issues)
    # Need to be in improving -> contemplating first
    send(Process.whereis(HubFSM), {:improvement_cycle_complete, %{findings: 0}})
    Process.sleep(100)

    # Now in contemplating -- healing not a valid transition
    assert {:error, :invalid_transition} = HubFSM.force_transition(:healing, "should fail")
  end
end
```

**Testing the HubLLMClient integration:**

```elixir
# Option 1: Test against real local Ollama (integration test)
# Tag with @tag :ollama so it can be excluded in CI
@tag :ollama
test "HubLLMClient.invoke(:decompose, ...) returns valid task list" do
  state = %{model: "qwen3:8b", endpoint: "http://localhost:11434"}
  params = %{goal: %{description: "Add logging"}, context: %{repo: "test"}}

  result = AgentCom.HubLLMClient.invoke(:decompose, params, state)
  assert {:ok, tasks} = result
  assert is_list(tasks)
end

# Option 2: Test response parsing in isolation (unit test)
test "HubLLMClient.Response.parse handles decompose response" do
  raw = ~s({"tasks": [{"description": "Add logger config", "priority": "high"}]})
  assert {:ok, [%{"description" => "Add logger config"}]} =
    AgentCom.HubLLMClient.Response.parse(raw, :decompose)
end
```

---

## Configuration Changes

### Hub Application Config (Additions)

```elixir
# config/config.exs -- NEW entries for Milestone 3

# Hub LLM backend (replaces claude -p CLI)
config :agent_com, :hub_llm,
  backend: :ollama,           # :ollama (default) or :claude (legacy fallback)
  model: "qwen3:8b",          # Model for hub LLM operations
  endpoint: "http://localhost:11434",
  timeout_ms: 120_000,        # Same default as existing claude timeout
  max_retries: 1              # Retry once on failure

# Healing state configuration
config :agent_com, :healing,
  health_check_failure_threshold: 3,    # consecutive failures before triggering healing
  stuck_task_threshold_ms: 300_000,     # 5 minutes
  healing_cycle_timeout_ms: 600_000,    # 10 minutes max for healing cycle
  auto_heal: true                       # set false to require manual trigger

# Agentic execution configuration
config :agent_com, :agentic,
  max_iterations: 10,          # Max ReAct loop iterations
  tool_timeout_ms: 60_000,     # Per-tool execution timeout
  tool_output_max_chars: 4000, # Truncate tool output
  enabled_tools: ["read_file", "write_file", "run_shell", "list_files", "task_complete"]
```

### Sidecar Config Changes

```json
{
  "agent_id": "gcu-conditions-permitting",
  "token": "...",
  "hub_url": "ws://localhost:4000/ws",
  "wake_command": "echo 'Waking for task ${TASK_ID}'",
  "capabilities": ["code"],
  "ollama_host": "http://localhost:11434",
  "agentic_execution": true,
  "agentic_model": "qwen3:8b",
  "agentic_max_iterations": 10,
  "agentic_tools": ["read_file", "write_file", "run_shell", "list_files", "task_complete"]
}
```

New fields: `agentic_execution`, `agentic_model`, `agentic_max_iterations`, `agentic_tools`.
All optional with sensible defaults. Backward-compatible.

---

## Installation

### Hub (Elixir) -- No New Packages

```bash
# No new dependencies. Req is already in mix.exs from Milestone 2.
# Only code changes needed.
```

### Sidecar (Node.js) -- No New Packages

```bash
# No new npm packages. ollama is already in package.json from Milestone 2.
# Only code changes needed.
```

### Infrastructure -- Model Verification

```bash
# Verify Qwen3 8B supports tool calling on your Ollama instance
ollama run qwen3:8b "Use the get_weather tool to check weather in NYC" --format json

# Verify tool calling works via API
curl -s http://localhost:11434/api/chat -d '{
  "model": "qwen3:8b",
  "messages": [{"role": "user", "content": "What is 2+2?"}],
  "tools": [{
    "type": "function",
    "function": {
      "name": "calculator",
      "description": "Calculate a math expression",
      "parameters": {
        "type": "object",
        "required": ["expression"],
        "properties": {"expression": {"type": "string"}}
      }
    }
  }],
  "stream": false
}'

# Expected: response.message.tool_calls should contain calculator call
```

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|----------------|-------|
| Req ~> 0.5.0 | Elixir >= 1.13, OTP >= 25 | Already present from Milestone 2. No version change needed. |
| ollama npm ^0.6.3 | Node.js >= 18 | Already present from Milestone 2. Tool calling supported via `tools` parameter in `chat()`. |
| Ollama server 0.15.x | Tool calling, Qwen3 8B | Tool calling has been stable since Ollama 0.3.x. Current 0.15.x is fully compatible. |
| Qwen3 8B Q4_K_M | RTX 3080 Ti 12GB VRAM | ~6-7GB VRAM. Tool calling verified working. F1 score 0.933 on tool calling benchmarks. |

---

## Dependency Count Impact

| Before Milestone 3 | After Milestone 3 |
|--------------------|--------------------|
| Hub: 8 runtime deps in mix.exs | Hub: 8 deps (unchanged) |
| Sidecar: 4 deps in package.json | Sidecar: 4 deps (unchanged) |
| Total new runtime deps: **0** | |

This milestone adds ZERO new external dependencies. All new functionality is built on
libraries already added in Milestone 2 (Req, ollama npm) plus OTP/Node.js standard library.

---

## Migration Path: ClaudeClient to HubLLMClient

**Phase 1: Add HubLLMClient alongside existing ClaudeClient.Cli**

```elixir
# ClaudeClient handle_call changes to check config:
case Application.get_env(:agent_com, [:hub_llm, :backend], :claude) do
  :ollama -> AgentCom.HubLLMClient.invoke(prompt_type, params, state)
  :claude -> AgentCom.ClaudeClient.Cli.invoke(prompt_type, params, state)
end
```

**Phase 2: Validate Ollama produces equivalent results**

Run both backends in parallel, compare outputs. Log discrepancies.

**Phase 3: Default to Ollama, keep Claude as opt-in fallback**

Set `config :agent_com, :hub_llm, backend: :ollama` as default.

**Phase 4: Remove ClaudeClient.Cli** (future milestone)

Once Ollama routing is proven stable, remove the CLI wrapper code.

---

## Sources

- [Ollama Tool Calling Documentation](https://docs.ollama.com/capabilities/tool-calling) -- Request/response format, tool schemas, tool role messages (HIGH confidence)
- [Ollama Streaming Tool Calling Blog](https://ollama.com/blog/streaming-tool) -- Streaming with tool calls, chunk accumulation (HIGH confidence)
- [Ollama API Reference (GitHub)](https://github.com/ollama/ollama/blob/main/docs/api.md) -- /api/chat endpoint, tools parameter, response format (HIGH confidence)
- [ollama-js GitHub](https://github.com/ollama/ollama-js) -- npm library API, chat() with tools, streaming (HIGH confidence)
- [ollama npm v0.6.3](https://www.npmjs.com/package/ollama) -- Current version, 416 dependents (HIGH confidence)
- [Ollama VRAM Requirements Guide](https://localllm.in/blog/ollama-vram-requirements-for-local-llms) -- Q4_K_M memory requirements (MEDIUM confidence)
- [Qwen3 8B Tool Calling](https://collabnix.com/best-ollama-models-for-function-calling-tools-complete-guide-2025/) -- F1 0.933, model comparison (MEDIUM confidence)
- [Docker LLM Tool Calling Evaluation](https://www.docker.com/blog/local-llm-tool-calling-a-practical-evaluation/) -- Practical tool calling benchmarks (MEDIUM confidence)
- [Elixir GenServer Testing Patterns](https://www.freshcodeit.com/blog/how-to-design-and-test-elixir-genservers) -- start_supervised, callback testing (HIGH confidence)
- [Architecting GenServers for Testability](https://tylerayoung.com/2021/09/12/architecting-genservers-for-testability/) -- Thin GenServer pattern (HIGH confidence)
- [gen_statem vs GenServer comparison](https://potatosalad.io/2017/10/13/time-out-elixir-state-machines-versus-servers) -- Why GenServer is sufficient for simple FSMs (HIGH confidence)
- [GenStateMachine hex package](https://hexdocs.pm/gen_state_machine/GenStateMachine.html) -- Alternative considered, not recommended (HIGH confidence)

---

*Stack research for: AgentCom Milestone 3 -- Agentic Tool Calling, Self-Healing FSM, Hub LLM Routing*
*Researched: 2026-02-14*
*Key finding: Zero new dependencies required. All new capabilities built on Milestone 2 stack (Req, ollama npm) plus custom implementations.*
