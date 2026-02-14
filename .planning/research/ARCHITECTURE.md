# Architecture: Agentic Tool Calling, Hub FSM Healing State, and Hub-to-Ollama LLM Routing

**Domain:** Agentic local LLM execution, self-healing FSM, pipeline reliability for existing Elixir/BEAM distributed agent coordination system
**Researched:** 2026-02-14
**Confidence:** HIGH (grounded in direct analysis of shipped v1.3 codebase: HubFSM, ClaudeClient, Scheduler, GoalOrchestrator, AgentFSM)

---

## Current System Inventory (Post-v1.3)

### Relevant Existing Components

| Component | Type | Key Behavior |
|-----------|------|-------------|
| **HubFSM** | GenServer | 4-state tick-driven FSM (resting/executing/improving/contemplating). 1s tick, 2h watchdog. Spawns async Task for improvement/contemplation cycles. |
| **ClaudeClient** | GenServer | Wraps `claude -p` CLI via `ClaudeClient.Cli`. Serial GenServer queue. CostLedger budget check before every invocation. |
| **ClaudeClient.Cli** | Module | Writes prompt to temp .md file, spawns `claude -p --output-format json`, parses JSON output. CLAUDECODE env var unset to avoid nesting. |
| **GoalOrchestrator** | GenServer | Tick-driven by HubFSM. One async op at a time (decompose or verify). Decomposer and Verifier sub-modules. |
| **Scheduler** | GenServer | PubSub-driven. Tier-aware routing via TaskRouter. Capability matching. Fallback timers. Stuck sweep (30s). TTL sweep (60s). |
| **TaskRouter** | Module (pure) | Routes by tier: trivial -> sidecar, standard -> ollama, complex -> claude. LoadScorer ranks endpoints. |
| **AgentFSM** | GenServer | Per-agent: idle -> assigned -> working -> idle. Acceptance timeout (60s). Process monitors WebSocket pid. |
| **CostLedger** | GenServer | DETS + ETS dual-layer. Per-state budget enforcement. check_budget/1 reads ETS (no GenServer.call). |

### Current Data Flow for LLM Calls

```
Hub-side LLM (goal decomposition, verification, improvement, contemplation):
  HubFSM/GoalOrchestrator -> ClaudeClient GenServer -> ClaudeClient.Cli
    -> writes temp .md file
    -> System.cmd("claude", ["-p", "Read...", "--output-format", "json"])
    -> parses JSON output
    -> File.rm(tmp_path)

Sidecar-side LLM (task execution):
  Scheduler assigns task via WebSocket -> Sidecar receives task_data
    -> Sidecar dispatches to OllamaExecutor or ClaudeExecutor
    -> OllamaExecutor: HTTP POST to Ollama /api/chat, streams NDJSON, returns text
    -> ClaudeExecutor: spawns claude -p process
```

---

## Integration Challenge Analysis

### Challenge 1: OllamaExecutor Returns Text, Not Tool Calls

**Current state:** OllamaExecutor sends a single HTTP POST to `/api/chat`, streams NDJSON response lines, concatenates content, returns plain text. No awareness of `tool_calls` in the response.

**Required state:** OllamaExecutor must support an agentic loop: send request with `tools` definitions -> receive response with `tool_calls` -> execute tool locally -> send tool result back -> repeat until model produces final text.

**Integration point:** This is entirely within the sidecar. The hub does not need to change for sidecar-side tool calling. The sidecar receives `task_data` via WebSocket (already includes `routing_decision` with `target_type: :ollama`). The sidecar's OllamaExecutor handles the multi-turn loop internally.

### Challenge 2: ClaudeClient.Cli Spawns `claude -p`, Needs Ollama HTTP

**Current state:** `ClaudeClient.Cli.invoke/3` builds a prompt, writes to temp file, runs `System.cmd("claude", ["-p", ...])`, parses JSON output. This is the ONLY path for hub-side LLM calls.

**Required state:** Hub needs an alternative LLM backend that calls Ollama's `/api/chat` HTTP endpoint directly from Elixir, without shelling out to a CLI.

**Integration point:** Create `AgentCom.OllamaClient` as a new module (parallel to `ClaudeClient.Cli`) and modify `ClaudeClient` GenServer to route to either backend based on configuration/task requirements. The existing CostLedger integration, budget checks, and telemetry in ClaudeClient GenServer remain unchanged.

### Challenge 3: Hub FSM Needs 5th State (Healing)

**Current state:** 4 states with transitions defined in `@valid_transitions`:
```elixir
@valid_transitions %{
  resting: [:executing, :improving],
  executing: [:resting],
  improving: [:resting, :executing, :contemplating],
  contemplating: [:resting, :executing]
}
```

**Required state:** A 5th `:healing` state reachable from any active state when system health degrades. Healing runs detection -> diagnosis -> fix -> verify cycle. Returns to previous state or resting.

**Integration point:** Modify `HubFSM` to add `:healing` to `@valid_transitions` map. Add healing-specific fields to GenServer state struct. Add healing detection to `gather_system_state/0` and healing predicates to `HubFSM.Predicates`. Spawn async healing cycle (same pattern as improvement/contemplation cycles).

### Challenge 4: Sidecar Tool Definitions and Execution Sandbox

**Current state:** Sidecar dispatches to executors that return text results. No tool infrastructure.

**Required state:** Sidecar must define tool schemas (file ops, git, shell, hub API), execute tools safely in sandboxed context, and feed results back into the Ollama tool-calling loop.

**Integration point:** New sidecar-side `ToolRegistry` defining available tools, `ToolExecutor` for sandboxed execution, and modifications to `OllamaExecutor` to orchestrate the agentic loop.

### Challenge 5: Pipeline Reliability

**Current state:** Scheduler has 30s stuck sweep, 60s TTL sweep. ClaudeClient has configurable timeout (default 120s). GoalOrchestrator has one-at-a-time async guard. No explicit wake failure handling or execution timeout enforcement at the sidecar level.

**Required state:** Execution timeouts at sidecar level, wake failure detection and recovery, stuck task recovery with exponential backoff.

**Integration point:** Extend Scheduler sweeps, add timeout enforcement to task_data sent to sidecar, add health signals to WebSocket protocol.

---

## Recommended Architecture

### Component Map: New vs Modified

```
NEW COMPONENTS (build from scratch):
  [Hub-side]
  AgentCom.OllamaClient          -- HTTP client for Ollama /api/chat
  AgentCom.OllamaClient.ToolLoop -- Agentic tool-calling loop logic
  AgentCom.HubFSM.Healer        -- Healing cycle detection/diagnosis/fix/verify
  AgentCom.HubFSM.HealthCheck   -- System health signal gathering

  [Sidecar-side]
  ToolRegistry                   -- Tool definitions (schemas)
  ToolExecutor                   -- Sandboxed tool execution
  ToolSandbox                    -- Filesystem/process isolation

MODIFIED COMPONENTS:
  AgentCom.HubFSM               -- Add :healing state, health detection in gather_system_state
  AgentCom.HubFSM.Predicates    -- Add healing predicates
  AgentCom.ClaudeClient          -- Route to OllamaClient or Cli based on config
  AgentCom.Scheduler             -- Enhanced stuck detection, timeout propagation
  OllamaExecutor (sidecar)       -- Agentic tool-calling loop
```

### Component Boundaries

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| **OllamaClient** | HTTP client for Ollama /api/chat. Request building, NDJSON streaming, response parsing. No tool execution logic. | ClaudeClient (called by), Ollama HTTP server |
| **OllamaClient.ToolLoop** | Hub-side agentic loop: send with tools -> receive tool_calls -> execute -> send results -> repeat. Max iteration guard. | OllamaClient (HTTP calls), ToolRegistry (schemas), ToolExecutor (execution) |
| **HubFSM.Healer** | Stateless healing cycle module. Detection -> diagnosis -> fix -> verify. Returns healing report. | HubFSM (called by), OllamaClient or ClaudeClient (LLM calls), system health signals |
| **HubFSM.HealthCheck** | Gathers health signals: agent connectivity, task throughput, error rates, Ollama endpoint health, DETS integrity. Pure function, no side effects. | AgentFSM.list_all, TaskQueue.stats, LlmRegistry, DETS tables |
| **ToolRegistry (sidecar)** | Defines available tools as JSON schemas. Static definitions. | OllamaExecutor (reads schemas) |
| **ToolExecutor (sidecar)** | Executes tool calls in sandboxed context. Enforces timeouts, path restrictions, output limits. | ToolRegistry (validates calls), filesystem/git/shell |
| **ToolSandbox (sidecar)** | Workspace isolation: chroot-like path restriction, process timeout, output truncation. | ToolExecutor (wraps execution) |

---

## Detailed Architecture: Agentic Tool-Calling Loop

### Where the Loop Lives: Sidecar AND Hub (Different Purposes)

**Sidecar agentic loop** (primary, for task execution):
The sidecar's OllamaExecutor manages the tool-calling loop for task execution. This is where the bulk of agentic work happens. The sidecar has filesystem access to the target repo, can run git commands, and execute shell operations.

**Hub agentic loop** (secondary, for healing/diagnosis):
The hub's OllamaClient.ToolLoop manages a simpler loop for healing operations. The hub has access to system state (DETS, ETS, PubSub) but not to repo filesystems. Hub tools are system-introspection tools (check agent status, query task queue, read logs, check endpoint health).

### Sidecar Tool-Calling Loop Architecture

```
OllamaExecutor receives task_data from WebSocket
  |
  v
Build initial messages: system prompt + task description
Attach tool definitions from ToolRegistry.tools_for_task(task_data)
  |
  v
LOOP (max_iterations: 10, timeout: task_timeout_ms):
  |
  POST /api/chat {model, messages, tools, stream: false}
  |
  v
  Response has tool_calls?
    YES:
      For each tool_call:
        ToolExecutor.execute(tool_call.function.name, tool_call.function.arguments)
          -> ToolSandbox.run(fn -> ... end, timeout: 30_000)
          -> Returns {:ok, result} or {:error, reason}
      Append assistant message (with tool_calls) to messages
      Append tool result messages to messages
      CONTINUE LOOP
    NO:
      Extract final content
      BREAK -> return content as task result
  |
  v
  Iteration limit or timeout reached?
    -> Return partial result with warning
```

**Critical design decision: `stream: false` for tool calling.** Ollama's streaming tool call support is inconsistent and incomplete (GitHub issue #12557). Use non-streaming for tool-calling turns. This simplifies parsing -- a single JSON response per turn rather than NDJSON chunks. The latency trade-off is acceptable because tool-calling turns are short (model decides which tool to call, not generating long text).

### Sidecar Tool Definitions

```javascript
// ToolRegistry.js
const TOOLS = {
  read_file: {
    type: "function",
    function: {
      name: "read_file",
      description: "Read contents of a file in the workspace",
      parameters: {
        type: "object",
        required: ["path"],
        properties: {
          path: { type: "string", description: "Relative path from workspace root" }
        }
      }
    }
  },
  write_file: {
    type: "function",
    function: {
      name: "write_file",
      description: "Write contents to a file in the workspace",
      parameters: {
        type: "object",
        required: ["path", "content"],
        properties: {
          path: { type: "string", description: "Relative path from workspace root" },
          content: { type: "string", description: "File content to write" }
        }
      }
    }
  },
  run_shell: {
    type: "function",
    function: {
      name: "run_shell",
      description: "Run a shell command in the workspace directory",
      parameters: {
        type: "object",
        required: ["command"],
        properties: {
          command: { type: "string", description: "Shell command to execute" },
          timeout_ms: { type: "integer", description: "Command timeout in ms (default 30000)" }
        }
      }
    }
  },
  git_diff: {
    type: "function",
    function: {
      name: "git_diff",
      description: "Get git diff of current changes",
      parameters: {
        type: "object",
        properties: {
          staged: { type: "boolean", description: "Show staged changes only" }
        }
      }
    }
  },
  list_files: {
    type: "function",
    function: {
      name: "list_files",
      description: "List files matching a glob pattern in workspace",
      parameters: {
        type: "object",
        required: ["pattern"],
        properties: {
          pattern: { type: "string", description: "Glob pattern (e.g. 'lib/**/*.ex')" }
        }
      }
    }
  },
  search_content: {
    type: "function",
    function: {
      name: "search_content",
      description: "Search file contents with regex pattern",
      parameters: {
        type: "object",
        required: ["pattern"],
        properties: {
          pattern: { type: "string", description: "Regex pattern to search for" },
          glob: { type: "string", description: "File glob to restrict search" }
        }
      }
    }
  },
  hub_api: {
    type: "function",
    function: {
      name: "hub_api",
      description: "Call the hub's REST API",
      parameters: {
        type: "object",
        required: ["method", "path"],
        properties: {
          method: { type: "string", enum: ["GET", "POST", "PUT", "DELETE"] },
          path: { type: "string", description: "API path (e.g. /api/tasks)" },
          body: { type: "object", description: "Request body for POST/PUT" }
        }
      }
    }
  }
};
```

### Tool Execution Sandbox

```javascript
// ToolSandbox.js
class ToolSandbox {
  constructor(workspacePath, options = {}) {
    this.workspacePath = path.resolve(workspacePath);
    this.timeout = options.timeout || 30_000;
    this.maxOutputBytes = options.maxOutputBytes || 1_000_000; // 1MB
    this.allowedPaths = [this.workspacePath]; // No path traversal
  }

  validatePath(relativePath) {
    const resolved = path.resolve(this.workspacePath, relativePath);
    if (!resolved.startsWith(this.workspacePath)) {
      throw new Error(`Path traversal blocked: ${relativePath}`);
    }
    return resolved;
  }

  async execute(toolName, args) {
    const startMs = Date.now();
    try {
      const result = await Promise.race([
        this._dispatch(toolName, args),
        this._timeoutPromise()
      ]);
      return { ok: true, result: this._truncate(result), duration_ms: Date.now() - startMs };
    } catch (err) {
      return { ok: false, error: err.message, duration_ms: Date.now() - startMs };
    }
  }
}
```

---

## Detailed Architecture: Hub FSM Healing State

### State Transition Map (5-State)

```
                        +--> Improving --+
                        |                |
  Executing <-----------+                +-------> Contemplating
      ^                 |                |              |
      |                 +--> Resting <---+              |
      |                 |                               |
      +-----+-----------+-------------------------------+
            |
            v
        Healing <-- (reachable from executing, improving, contemplating)
```

### Updated Valid Transitions

```elixir
@valid_transitions %{
  resting:       [:executing, :improving],
  executing:     [:resting, :healing],
  improving:     [:resting, :executing, :contemplating, :healing],
  contemplating: [:resting, :executing, :healing],
  healing:       [:resting, :executing]
}
```

**Transition rationale:**
- `:healing` is reachable from any active state (executing, improving, contemplating) but NOT from resting. If the system is resting, there is nothing to heal.
- `:healing` exits to `:resting` (if healing completed but system should cool down) or `:executing` (if healing fixed the issue and there is pending work).
- `:healing` does NOT transition to `:improving` or `:contemplating` to prevent healing -> contemplating -> healing oscillation.

### Healing Trigger Detection

Add health signals to `gather_system_state/0`:

```elixir
defp gather_system_state do
  # ... existing goal/budget gathering ...

  # NEW: Health signals for healing detection
  health = gather_health_signals()

  %{
    # existing fields...
    pending_goals: pending_goals,
    active_goals: active_goals,
    budget_exhausted: budget_exhausted,
    # NEW fields
    health_degraded: health.degraded,
    health_signals: health.signals
  }
end

defp gather_health_signals do
  signals = []

  # Signal 1: Agent connectivity (all agents offline)
  agents = try_safe(fn -> AgentCom.AgentFSM.list_all() end, [])
  online_agents = Enum.count(agents, fn a -> a.fsm_state != :offline end)
  signals = if online_agents == 0 and length(agents) > 0,
    do: [{:no_agents_online, %{total: length(agents)}} | signals],
    else: signals

  # Signal 2: Task throughput collapse (tasks stuck for extended period)
  stuck_tasks = try_safe(fn ->
    AgentCom.TaskQueue.list(status: :assigned)
    |> Enum.count(fn t ->
      System.system_time(:millisecond) - t.updated_at > 600_000  # 10 min
    end)
  end, 0)
  signals = if stuck_tasks > 3,
    do: [{:tasks_stuck, %{count: stuck_tasks}} | signals],
    else: signals

  # Signal 3: Ollama endpoint health (all endpoints unhealthy)
  endpoints = try_safe(fn -> AgentCom.LlmRegistry.list_endpoints() end, [])
  healthy = Enum.count(endpoints, fn ep -> ep.status == :healthy end)
  signals = if length(endpoints) > 0 and healthy == 0,
    do: [{:all_endpoints_unhealthy, %{total: length(endpoints)}} | signals],
    else: signals

  # Signal 4: Repeated goal failures
  recent_failures = try_safe(fn ->
    AgentCom.GoalBacklog.stats()
    |> Map.get(:by_status, %{})
    |> Map.get(:failed, 0)
  end, 0)
  signals = if recent_failures > 3,
    do: [{:excessive_goal_failures, %{count: recent_failures}} | signals],
    else: signals

  %{
    degraded: length(signals) > 0,
    signals: signals
  }
end
```

### Healing Predicates

Add to `HubFSM.Predicates`:

```elixir
# From any active state, transition to healing if health degraded
def evaluate(:executing, %{health_degraded: true, health_signals: signals}) do
  {:transition, :healing, "health degraded: #{format_signals(signals)}"}
end

def evaluate(:improving, %{health_degraded: true, health_signals: signals}) do
  {:transition, :healing, "health degraded: #{format_signals(signals)}"}
end

def evaluate(:contemplating, %{health_degraded: true, health_signals: signals}) do
  {:transition, :healing, "health degraded: #{format_signals(signals)}"}
end

# Healing: stay while cycle running (async Task pattern, same as improving)
def evaluate(:healing, _system_state), do: :stay
```

### Healing Cycle (HubFSM.Healer)

```elixir
defmodule AgentCom.HubFSM.Healer do
  @moduledoc """
  Stateless healing cycle module. Called by HubFSM when entering :healing state.

  Four-phase cycle: detect -> diagnose -> fix -> verify.
  Uses deterministic checks first, LLM diagnosis only if deterministic checks
  are inconclusive.
  """

  @max_fix_attempts 3

  def run(health_signals) do
    with {:ok, diagnosis} <- diagnose(health_signals),
         {:ok, fix_result} <- apply_fixes(diagnosis),
         {:ok, verification} <- verify(fix_result) do
      {:ok, %{
        signals: health_signals,
        diagnosis: diagnosis,
        fix_result: fix_result,
        verification: verification,
        healed_at: System.system_time(:millisecond)
      }}
    else
      {:error, reason} ->
        {:error, %{signals: health_signals, failure_reason: reason}}
    end
  end

  defp diagnose(signals) do
    # Deterministic diagnosis first (no LLM needed for most cases)
    diagnoses = Enum.map(signals, fn
      {:no_agents_online, _meta} ->
        %{signal: :no_agents_online, action: :wait_for_reconnect, severity: :high}

      {:tasks_stuck, %{count: count}} ->
        %{signal: :tasks_stuck, action: :reclaim_and_requeue, severity: :medium,
          detail: "#{count} tasks stuck >10min"}

      {:all_endpoints_unhealthy, _meta} ->
        %{signal: :all_endpoints_unhealthy, action: :restart_health_checks, severity: :high}

      {:excessive_goal_failures, %{count: count}} ->
        %{signal: :excessive_goal_failures, action: :pause_goal_processing, severity: :medium,
          detail: "#{count} recent failures"}
    end)

    {:ok, diagnoses}
  end

  defp apply_fixes(diagnoses) do
    results = Enum.map(diagnoses, fn diagnosis ->
      case diagnosis.action do
        :wait_for_reconnect ->
          # Cannot fix externally, just wait. Set a reconnect deadline.
          {:deferred, :waiting_for_agents, 120_000}

        :reclaim_and_requeue ->
          # Reclaim all stuck assigned tasks
          reclaimed = reclaim_stuck_tasks()
          {:fixed, :tasks_reclaimed, reclaimed}

        :restart_health_checks ->
          # Trigger immediate health check cycle on all endpoints
          trigger_endpoint_health_checks()
          {:fixed, :health_checks_triggered, nil}

        :pause_goal_processing ->
          # Don't submit new goals until failures investigated
          {:fixed, :goal_processing_paused, nil}
      end
    end)

    {:ok, results}
  end

  defp verify(fix_results) do
    # Wait briefly (5s) then re-check health signals
    Process.sleep(5_000)
    # Re-gather signals and check if situation improved
    {:ok, %{re_checked: true, timestamp: System.system_time(:millisecond)}}
  end
end
```

### HubFSM Integration for Healing

In `do_transition/3`, add healing cycle spawn (same pattern as improving/contemplating):

```elixir
# Spawn async healing cycle when entering :healing
if new_state == :healing do
  pid = self()
  signals = Map.get(state, :health_signals, [])

  Task.start(fn ->
    result = AgentCom.HubFSM.Healer.run(signals)
    send(pid, {:healing_cycle_complete, result})
  end)
end
```

Add `handle_info` for healing completion:

```elixir
def handle_info({:healing_cycle_complete, result}, state) do
  Logger.info("healing_cycle_complete", result: inspect(result))

  if state.fsm_state == :healing do
    system_state = gather_system_state()

    {new_state, reason} =
      if system_state.pending_goals > 0 and not system_state.health_degraded do
        {:executing, "healed, pending goals"}
      else
        {:resting, "healing cycle complete"}
      end

    updated = do_transition(state, new_state, reason)
    {:noreply, updated}
  else
    {:noreply, state}
  end
end
```

### State Struct Extension

Add to `HubFSM` defstruct:

```elixir
defstruct [
  # existing fields...
  :fsm_state,
  :last_state_change,
  :tick_ref,
  :watchdog_ref,
  cycle_count: 0,
  paused: false,
  transition_count: 0,
  # NEW fields for healing
  health_signals: [],        # Latest health signals from gather_system_state
  healing_attempts: 0,       # Count of healing cycles since last healthy state
  last_healed_at: nil        # Timestamp of last healing completion
]
```

---

## Detailed Architecture: Hub-to-Ollama LLM Routing

### Architecture Decision: OllamaClient Module, Not Replace ClaudeClient

**Do not replace ClaudeClient.** Create `AgentCom.OllamaClient` as a parallel backend module. ClaudeClient continues to work for Claude CLI calls. A routing layer in ClaudeClient chooses which backend to use.

**Rationale:**
1. Claude CLI is the proven backend for complex operations (goal decomposition, semantic verification). Ollama models may not match quality for these tasks.
2. Hub needs both backends: Claude for high-quality reasoning, Ollama for fast/cheap operations (healing diagnosis, simple triage).
3. CostLedger already gates ClaudeClient. OllamaClient is free (local compute), so it bypasses CostLedger budget checks.

### OllamaClient Module Design

```elixir
defmodule AgentCom.OllamaClient do
  @moduledoc """
  HTTP client for Ollama /api/chat endpoint.

  Direct HTTP calls to locally-running Ollama. No GenServer wrapper needed
  because:
  1. Ollama handles concurrency internally
  2. No rate limiting needed (local compute)
  3. No API key management
  4. No cost tracking (free)

  Functions are called by ClaudeClient or HubFSM.Healer directly.
  """

  @default_url "http://localhost:11434"
  @default_model "qwen3:8b"
  @default_timeout_ms 120_000

  @doc """
  Send a chat request to Ollama. Returns {:ok, response} or {:error, reason}.

  Options:
  - :model - model name (default: #{@default_model})
  - :url - Ollama base URL (default: #{@default_url})
  - :tools - list of tool definitions for tool calling
  - :timeout_ms - request timeout (default: #{@default_timeout_ms})
  """
  @spec chat(list(map()), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []) do
    url = Keyword.get(opts, :url, ollama_url())
    model = Keyword.get(opts, :model, ollama_model())
    tools = Keyword.get(opts, :tools, [])
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    body = %{
      model: model,
      messages: messages,
      stream: false
    }

    body = if tools != [], do: Map.put(body, :tools, tools), else: body

    case http_post("#{url}/api/chat", body, timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Check if Ollama is reachable and the target model is loaded.
  """
  @spec health_check(keyword()) :: :ok | {:error, term()}
  def health_check(opts \\ []) do
    url = Keyword.get(opts, :url, ollama_url())
    model = Keyword.get(opts, :model, ollama_model())

    case http_get("#{url}/api/tags") do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        if Enum.any?(models, fn m -> String.starts_with?(m["name"], model) end) do
          :ok
        else
          {:error, {:model_not_found, model}}
        end

      {:ok, %{status: status}} ->
        {:error, {:unhealthy, status}}

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  defp ollama_url, do: Application.get_env(:agent_com, :ollama_url, @default_url)
  defp ollama_model, do: Application.get_env(:agent_com, :ollama_model, @default_model)

  defp http_post(url, body, timeout) do
    # Use :httpc (already available, no new deps) for simple HTTP POST
    # Req is an option but :httpc avoids adding dependency for simple JSON POST
    headers = [{'content-type', 'application/json'}]
    json_body = Jason.encode!(body)

    case :httpc.request(:post,
      {String.to_charlist(url), headers, 'application/json', json_body},
      [{:timeout, timeout}, {:connect_timeout, 5_000}],
      [{:body_format, :binary}]
    ) do
      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:ok, %{status: status, body: Jason.decode!(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_get(url) do
    case :httpc.request(:get,
      {String.to_charlist(url), []},
      [{:timeout, 5_000}, {:connect_timeout, 3_000}],
      [{:body_format, :binary}]
    ) do
      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:ok, %{status: status, body: Jason.decode!(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

**HTTP client decision: Use `:httpc` (built-in), not Req.** The hub already uses `:httpc` for LlmRegistry health probes. OllamaClient makes simple JSON POST requests. Adding Req for this would be overkill -- `:httpc` is already available with no additional dependencies. If the hub needs Req for Claude API calls later (replacing CLI), it can be added then.

### ClaudeClient Routing Layer

Modify `ClaudeClient` to support routing between backends:

```elixir
# In ClaudeClient.handle_call({:invoke, prompt_type, params}, ...)
defp select_backend(prompt_type, state) do
  ollama_enabled = Application.get_env(:agent_com, :ollama_hub_enabled, false)
  ollama_types = Application.get_env(:agent_com, :ollama_prompt_types, [:diagnose, :triage])

  if ollama_enabled and prompt_type in ollama_types do
    :ollama
  else
    :claude_cli
  end
end
```

This allows gradual migration: start with Claude CLI for everything, enable Ollama for specific low-stakes operations (healing diagnosis, triage), expand as confidence grows.

---

## Detailed Architecture: Pipeline Reliability

### Execution Timeout Enforcement

**Current gap:** Task timeout is set in ClaudeClient (120s default) but not propagated to sidecar execution.

**Fix:** Include `execution_timeout_ms` in task_data sent via WebSocket. Sidecar enforces this timeout on OllamaExecutor/ClaudeExecutor.

```elixir
# In Scheduler.do_assign, add to task_data:
task_data = %{
  # ... existing fields ...
  execution_timeout_ms: Map.get(assigned_task, :execution_timeout_ms,
    default_timeout_for_tier(routing_decision.effective_tier))
}

defp default_timeout_for_tier(:trivial), do: 30_000
defp default_timeout_for_tier(:standard), do: 300_000  # 5 min for agentic loop
defp default_timeout_for_tier(:complex), do: 600_000   # 10 min
defp default_timeout_for_tier(_), do: 300_000
```

### Wake Failure Handling

**Current gap:** When a task is routed to `:claude` (wake/complex tier) and the Claude CLI fails to start, the task sits in assigned state until the 30s stuck sweep catches it.

**Fix:** Sidecar reports execution start/failure back to hub within 10 seconds. If no start acknowledgment received, Scheduler reclaims immediately.

```
WebSocket protocol extension:
  Hub -> Sidecar: {:push_task, task_data}         (existing)
  Sidecar -> Hub: {:task_started, task_id}         (NEW - within 10s)
  Sidecar -> Hub: {:task_start_failed, task_id, reason}  (NEW)

If neither received within 10s, Scheduler reclaims task.
```

### Stuck Task Recovery with Backoff

**Current gap:** Scheduler reclaims stuck tasks after 5 minutes, but the task may be reassigned to the same failing agent/endpoint.

**Fix:** Track reclaim count per task. After N reclaims, either dead-letter or change routing strategy.

```elixir
# In Scheduler stuck sweep, check reclaim history:
defp handle_stuck_task(task) do
  reclaim_count = Map.get(task, :reclaim_count, 0)

  cond do
    reclaim_count >= 3 ->
      # Dead-letter after 3 reclaims
      AgentCom.TaskQueue.dead_letter(task.id, "stuck 3x")

    reclaim_count >= 1 ->
      # On second reclaim, try different routing
      AgentCom.TaskQueue.reclaim_task(task.id)
      AgentCom.TaskQueue.update(task.id, %{
        reclaim_count: reclaim_count + 1,
        routing_hint: :force_fallback
      })

    true ->
      AgentCom.TaskQueue.reclaim_task(task.id)
      AgentCom.TaskQueue.update(task.id, %{reclaim_count: reclaim_count + 1})
  end
end
```

---

## Data Flow: Agentic Task Execution (End-to-End)

```
1. TASK ASSIGNMENT (existing, no changes)
   Scheduler routes task via TaskRouter
   TaskRouter returns decision: {target_type: :ollama, model: "qwen3:8b", endpoint: "host1:11434"}
   Scheduler sends {:push_task, task_data} via WebSocket to sidecar

2. SIDECAR RECEIVES TASK
   WebSocket handler receives task_data
   Dispatches to OllamaExecutor based on routing_decision.target_type
   Sidecar sends {:task_started, task_id} back to hub (NEW)

3. AGENTIC TOOL-CALLING LOOP (NEW - inside OllamaExecutor)
   a. Build system prompt from task description + context
   b. Load tool definitions: ToolRegistry.tools_for_task(task_data)
   c. POST /api/chat {model, messages, tools, stream: false}
   d. Parse response:
      - If response.message.tool_calls exists:
          For each tool_call:
            result = ToolExecutor.execute(tool_call)
          Append assistant message + tool results to messages
          GOTO (c) [max 10 iterations]
      - If response.message.content (no tool_calls):
          Final answer reached. BREAK.
   e. Return final content as task result

4. VERIFICATION (existing, enhanced)
   If task has verification_steps:
     Run mechanical checks (compile, test, etc.)
     If verification fails and retries remain:
       Feed failure back into agentic loop as new context
       GOTO 3 with failure context appended to messages

5. TASK COMPLETION (existing, no changes)
   Sidecar sends task_completed/task_failed event
   Hub Scheduler/GoalOrchestrator receives via PubSub
```

---

## Data Flow: Hub FSM Healing Cycle

```
1. DETECTION (in gather_system_state, every 1s tick)
   Predicates.evaluate returns {:transition, :healing, reason}
   HubFSM transitions to :healing
   Captures health_signals in GenServer state

2. HEALING CYCLE (async Task, same pattern as improving/contemplating)
   Task.start(fn -> Healer.run(health_signals) end)

3. DIAGNOSIS (in Healer.run)
   Deterministic first: map signals to known fix actions
   If inconclusive and Ollama available:
     OllamaClient.chat([system: "You are a system diagnostician...", user: signal_context])
     Parse LLM suggestion for fix actions

4. FIX APPLICATION (in Healer.apply_fixes)
   :reclaim_and_requeue -> TaskQueue.reclaim_task for each stuck task
   :restart_health_checks -> LlmRegistry.trigger_health_check
   :wait_for_reconnect -> set deadline, check again in 120s
   :pause_goal_processing -> set flag in HubFSM state

5. VERIFICATION (in Healer.verify)
   Wait 5s, re-gather health signals
   If health_degraded still true: log, return partial success
   If health restored: return full success

6. COMPLETION (back in HubFSM)
   handle_info({:healing_cycle_complete, result})
   If pending goals and health restored -> transition to :executing
   Otherwise -> transition to :resting
```

---

## Suggested Build Order

```
Phase A: OllamaClient (Hub-side HTTP client)
  - AgentCom.OllamaClient module (:httpc-based, no new deps)
  - health_check/1, chat/2
  - Config keys: :ollama_url, :ollama_model
  - Tests: unit with mock HTTP
  DEPENDS ON: nothing new
  RISK: LOW (simple HTTP wrapper)

Phase B: Hub FSM Healing State
  - HubFSM.HealthCheck module (gather_health_signals)
  - HubFSM.Healer module (diagnose/fix/verify cycle)
  - Modify HubFSM: add :healing to @valid_transitions
  - Modify HubFSM.Predicates: add healing predicates
  - Modify HubFSM struct: health_signals, healing_attempts, last_healed_at
  - Healing cycle: async Task pattern (existing pattern)
  DEPENDS ON: Phase A (for Ollama-assisted diagnosis, optional)
  RISK: MEDIUM (modifying core FSM, but follows existing patterns)

Phase C: Sidecar Tool Infrastructure
  - ToolRegistry.js (tool schema definitions)
  - ToolSandbox.js (path validation, timeout, output limits)
  - ToolExecutor.js (dispatch to tool implementations)
  - Individual tool implementations (read_file, write_file, run_shell, etc.)
  DEPENDS ON: nothing (sidecar-side, parallel with hub work)
  RISK: MEDIUM (security-sensitive: sandbox must prevent path traversal)

Phase D: Sidecar Agentic Tool-Calling Loop
  - Modify OllamaExecutor: multi-turn loop with tool calling
  - Non-streaming tool-call turns (stream: false)
  - Max iteration guard (10 turns default)
  - Timeout enforcement (execution_timeout_ms from task_data)
  DEPENDS ON: Phase C (needs ToolRegistry + ToolExecutor)
  RISK: MEDIUM-HIGH (most complex new behavior, parsing tool_calls)

Phase E: Hub-to-Ollama Routing
  - Modify ClaudeClient: backend selection (select_backend/2)
  - Config: :ollama_hub_enabled, :ollama_prompt_types
  - OllamaClient.ToolLoop for hub-side tool calling (healing tools)
  - CostLedger: skip budget check for Ollama calls
  DEPENDS ON: Phase A + Phase B
  RISK: LOW (routing is config-driven, defaults to Claude CLI)

Phase F: Pipeline Reliability
  - Execution timeout propagation in task_data
  - Wake failure detection (task_started/task_start_failed WebSocket msgs)
  - Stuck task recovery with backoff (reclaim_count tracking)
  - Dead-letter after N reclaims
  DEPENDS ON: Phase D (sidecar needs to send task_started)
  RISK: LOW-MEDIUM (extending existing sweeps and protocols)
```

### Build Order Rationale

1. **OllamaClient first** because it is a standalone module with no dependencies on other new components. Both Healing and Hub-to-Ollama routing need it.
2. **Healing State second** because it modifies the FSM core, which is the highest-risk change. Better to stabilize this before adding sidecar complexity. Healing can work with deterministic-only diagnosis initially (no LLM needed).
3. **Sidecar Tool Infrastructure third** because it is sidecar-side and can be built in parallel with hub-side phases A and B. No hub changes needed.
4. **Agentic Loop fourth** because it depends on tool infrastructure being in place. This is the most complex new behavior.
5. **Hub-to-Ollama Routing fifth** because it is config-driven and low risk. Defaults to Claude CLI, gradually enabled.
6. **Pipeline Reliability last** because it extends existing mechanisms (sweeps, timeouts) and benefits from all other phases being testable.

### Parallelization Opportunity

Phases A+B (hub-side) can run in parallel with Phase C (sidecar-side). They share no code. This reduces critical path from 6 serial phases to approximately 4.

```
Timeline:
  [A: OllamaClient] -> [B: Healing] -> [E: Hub Routing] -> [F: Reliability]
  [C: Tool Infra]    -> [D: Agentic Loop] ----------------/
```

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Streaming Tool Calls

**What:** Using `stream: true` with Ollama tool calling.
**Why bad:** Ollama's streaming tool call support is inconsistent. Tool call chunks may arrive incomplete or in unexpected format. GitHub issue #12557 documents this.
**Instead:** Use `stream: false` for tool-calling turns. Use streaming only for final text generation (no tools).

### Anti-Pattern 2: Hub Executing Tools Directly

**What:** Having the hub's OllamaClient.ToolLoop execute file/git/shell tools on the hub machine.
**Why bad:** The hub is a coordinator, not an executor. It should not have filesystem access to target repos. Mixing execution with coordination violates the existing "hub decides, sidecar executes" pattern.
**Instead:** Hub tools are limited to system introspection: query TaskQueue, check agent status, read metrics. File/git/shell tools exist only in sidecar.

### Anti-Pattern 3: Healing State That Never Exits

**What:** Healing cycle runs indefinitely because health signals never fully clear (e.g., agent that will never reconnect).
**Why bad:** System stays in :healing forever, preventing all other work.
**Instead:** Healing has a max attempt count (3) and a timeout (watchdog still applies at 2 hours). After max attempts, transition to :resting with logged warning. Do not retry healing until a state change occurs (e.g., agent reconnects, endpoint comes healthy).

### Anti-Pattern 4: Unbounded Tool-Calling Iterations

**What:** Agentic loop runs 50+ iterations because model keeps calling tools without converging.
**Why bad:** Consumes Ollama compute, delays task completion, may indicate model confusion.
**Instead:** Hard cap at 10 iterations. If not converged, return partial result with "max iterations reached" warning. Log the full conversation for debugging.

### Anti-Pattern 5: Tool Calls Without Sandbox

**What:** Executing `run_shell` tool calls without path restriction or timeout.
**Why bad:** Model could execute destructive commands (rm -rf), access files outside workspace, or run indefinitely.
**Instead:** ToolSandbox validates all paths are under workspace root. Shell commands have 30s default timeout. Dangerous commands (rm -rf /, shutdown, etc.) are blocklisted.

---

## Scalability Considerations

| Concern | At 5 agents | At 20 agents | At 50 agents |
|---------|------------|-------------|-------------|
| Ollama tool-call turns per task | 3-5 avg, 10 max | Same | Same |
| Hub-side Ollama calls (healing) | ~0-2/hour | ~0-5/hour | ~0-10/hour |
| Healing cycle frequency | Rare (< 1/day) | Occasional (1-3/day) | More frequent as system complexity grows |
| Tool execution latency | 1-5s per tool call | Same | Same |
| Sidecar memory for tool loop | ~50MB (message history) | Same per sidecar | Same per sidecar |
| WebSocket protocol overhead | Negligible (+2 msg types) | Same | Same |

**Bottleneck:** Ollama inference speed for tool-calling turns. Each tool-calling turn requires a full model forward pass. With 5 turns per task, a 7B model on GPU takes ~2-5s per turn = 10-25s total tool-calling overhead per task. This is acceptable for standard-tier tasks.

---

## Sources

### Primary (HIGH confidence)
- AgentCom v1.3 shipped codebase -- HubFSM, ClaudeClient, ClaudeClient.Cli, GoalOrchestrator, Scheduler, AgentFSM, CostLedger, TaskRouter (direct analysis, 2026-02-14)
- [Ollama Tool Calling Documentation](https://docs.ollama.com/capabilities/tool-calling) -- API format for /api/chat with tools, response format, tool result format
- [Ollama Streaming Tool Calls Blog](https://ollama.com/blog/streaming-tool) -- Streaming tool call support and limitations
- [Ollama API Documentation](https://github.com/ollama/ollama/blob/main/docs/api.md) -- Full API reference

### Secondary (MEDIUM confidence)
- [ollama-ex Elixir library](https://github.com/lebrunel/ollama-ex) -- Elixir Ollama client with tool support
- [Ollama hex package v0.9.0](https://hexdocs.pm/ollama/Ollama.html) -- Elixir Ollama client documentation
- [LangChain Elixir](https://github.com/brainlid/langchain) -- Elixir LangChain with Ollama agentic support
- [GenServer state recovery patterns](https://www.bounga.org/elixir/2020/02/29/genserver-supervision-tree-and-state-recovery-after-crash/) -- State recovery after crash
- [Ollama streaming issue #12557](https://github.com/ollama/ollama/issues/12557) -- Streaming tool call inconsistencies

### Tertiary (LOW confidence)
- [Ollama models for function calling guide](https://collabnix.com/best-ollama-models-for-function-calling-tools-complete-guide-2025/) -- Model comparison for tool calling quality
- [IBM Ollama tool calling tutorial](https://www.ibm.com/think/tutorials/local-tool-calling-ollama-granite) -- Granite model tool calling patterns

---

*Architecture research for: Agentic Tool Calling, Hub FSM Healing, Hub-to-Ollama Routing*
*Researched: 2026-02-14*
*Based on: shipped v1.3 codebase with 4-state HubFSM, ClaudeClient CLI wrapper, tier-aware TaskRouter, GoalOrchestrator, CostLedger*
