# Feature Landscape: AgentCom v1.4 -- Agentic Local LLM Execution, Self-Healing, and Pipeline Reliability

**Domain:** Agentic tool-calling LLM execution, distributed system self-healing, pipeline reliability hardening
**Researched:** 2026-02-14
**Overall Confidence:** MEDIUM-HIGH (Ollama tool calling API is documented and verified; ReAct/agentic loop patterns well-established; self-healing patterns standard in OTP; pipeline reliability patterns are standard distributed systems engineering)

---

## Table Stakes

Features users expect. Missing = the milestone fails its stated goal.

### 1. Ollama Tool-Calling Agent Loop

| Feature | Why Expected | Complexity | Depends On (Existing) | Notes |
|---------|--------------|------------|----------------------|-------|
| **Tool definition registry** | The LLM needs to know what tools exist. Without a registry of available tools (file read/write, shell exec, git operations, hub API calls), the model cannot request actions. This is the foundation of agentic execution. | Medium | OllamaExecutor (sidecar), dispatcher.js | New module in sidecar: `tool-registry.js`. Each tool has: name, description, parameter JSON schema. Ollama API accepts `tools` array in `/api/chat` request body. Keep tool count under 5 for Qwen3 8B -- above 5 tools, Qwen3 switches from native JSON tool calls to XML-in-content, which breaks parsing. |
| **Tool execution engine** | When the LLM returns `tool_calls` in its response, something must actually execute those calls (read a file, run a command, call an API) and return results. Without execution, tool calling is theater. | Medium | ShellExecutor (existing), workspace-manager.js | New module: `tool-executor.js`. Maps tool names to execution functions. Sandboxed: tools operate within the agent's workspace directory only. File operations use workspace-manager paths. Shell operations use existing ShellExecutor patterns with timeout enforcement. |
| **Observation-reasoning loop (ReAct pattern)** | The core agentic pattern: LLM thinks, calls tool, observes result, thinks again, calls next tool, until done. Without the loop, tool calling is single-shot (call one tool and stop). Real tasks require 3-15 tool calls in sequence. | High | OllamaExecutor, tool registry, tool executor | Modify OllamaExecutor to implement multi-turn conversation. After receiving `tool_calls`, execute tools, append `role: "tool"` messages with results, call `/api/chat` again. Loop until LLM returns content without tool_calls (final answer) or iteration limit hit. This is the ReAct Thought-Action-Observation cycle. |
| **Loop safety guardrails** | LLMs get stuck in infinite loops: calling the same tool repeatedly, ignoring stop signals, re-processing old information. Without external enforcement, a stuck agent burns tokens and blocks the pipeline indefinitely. | Medium | ReAct loop, CostLedger | External enforcement (not LLM self-policing): (1) Max iteration limit (default 15, configurable per task), (2) Repetition detection -- if same tool+args called 3 times consecutively, force-stop, (3) Token budget per task from CostLedger, (4) Wall-clock timeout (existing 5min, extend to 10min for agentic tasks), (5) Monotonic progress check -- if no new file modifications or test results in 5 iterations, force-stop. |
| **Structured output parsing** | Ollama returns tool calls as `message.tool_calls[]` with `function.name` and `function.arguments`. The parser must handle: normal content responses (no tools), single tool call, multiple tool calls, and malformed responses from smaller models. | Medium | OllamaExecutor streaming parser | Extend existing NDJSON streaming parser in OllamaExecutor. Current parser only reads `message.content`. Must also read `message.tool_calls`. Handle edge case: Qwen3 with >5 tools returns XML tool calls in `content` field instead of `tool_calls` field -- parse both formats. |

### 2. Hub FSM Healing State

| Feature | Why Expected | Complexity | Depends On (Existing) | Notes |
|---------|--------------|------------|----------------------|-------|
| **Healing state in FSM** | The hub currently has no response to infrastructure failures beyond alerting. When Ollama endpoints go down, tasks get stuck, or agents disconnect, the system alerts but does not act. A Healing state lets the FSM detect problems and attempt automated remediation before human intervention. | Medium | HubFSM (4 states + transitions), Alerter (7 alert rules), MetricsCollector | Add 5th state `:healing` to HubFSM. Valid transitions: any state -> :healing (triggered by critical alerts), :healing -> :resting (remediation complete or failed). Healing preempts other states -- if infrastructure is broken, executing goals is pointless. |
| **Health check aggregation** | The FSM needs a single "is the system healthy?" signal. Currently health data is scattered: Alerter has alert rules, MetricsCollector has metrics, LLM Registry has endpoint health, AgentFSM has agent states. Healing needs a unified health assessment. | Medium | Alerter, MetricsCollector, LLM Registry, AgentFSM | New module: `HealthAggregator`. Polls existing sources on tick. Returns structured health report: `{healthy: bool, issues: [{source, severity, detail}]}`. FSM transition predicate: `not healthy? and has_critical_issues? -> :healing`. |
| **Stuck task detection and remediation** | Tasks assigned to agents that never complete are the most common pipeline failure. Current `stuck_tasks` alert fires but requires human intervention. Healing should automatically: reassign stuck tasks, restart unresponsive agents, or escalate to dead-letter. | Medium | Alerter stuck_tasks rule, TaskQueue, Scheduler, AgentFSM | Remediation actions: (1) If agent heartbeat missing > 2min: mark agent offline, unassign task, requeue. (2) If task assigned > 15min with no progress events: cancel and requeue with incremented retry count. (3) If task retried 3x and still stuck: move to dead-letter, alert human. All actions logged to healing history. |
| **Ollama endpoint recovery** | When all Ollama endpoints go unhealthy (tier_down alert), the system stops processing tasks. Healing should attempt endpoint recovery: health check retries with backoff, endpoint restart commands (if configured), graceful degradation to Claude-only routing. | Low | LLM Registry health checks, tier_down alert rule | Remediation: (1) Retry health checks with exponential backoff (5s, 15s, 45s). (2) If endpoint has a configured restart command (e.g., `systemctl restart ollama`), execute via sidecar shell. (3) If recovery fails after 3 attempts, mark endpoints as down, route remaining tasks to Claude backend (cost increase accepted). (4) When endpoints recover, transition back to normal routing. |

### 3. Pipeline Reliability Fixes

| Feature | Why Expected | Complexity | Depends On (Existing) | Notes |
|---------|--------------|------------|----------------------|-------|
| **Wake failure recovery** | Sidecar wake (process spawn) fails silently when the target process crashes on startup. Currently the hub never learns the wake failed -- it marks the task as assigned and waits forever. | Low | sidecar/lib/wake.js, AgentFSM, Scheduler | Add wake acknowledgment: sidecar reports wake success/failure within 10s. If no ack received, hub marks agent as potentially offline and requeues task. Existing acceptance_timeout mechanism can be reused but needs shorter timeout for wake specifically. |
| **Task timeout enforcement** | Tasks have no enforced wall-clock deadline. An LLM that generates output forever (or an Ollama endpoint that streams indefinitely) blocks the agent. The existing 5min timeout in OllamaExecutor is per-HTTP-request, not per-task. A task with 15 tool-call iterations could run for 75 minutes. | Medium | OllamaExecutor, verification-loop.js, dispatcher.js | Add task-level timeout in dispatcher.js: wraps entire execution (including verification retries) in a Promise.race with configurable deadline (default 30min for agentic tasks, 10min for simple tasks). On timeout: kill execution, report timeout failure, requeue if retries remain. |
| **Graceful degradation on budget exhaustion** | CostLedger can block LLM calls when budget is exhausted, but tasks already in-flight have no way to learn this mid-execution. An agentic loop could start 15 iterations, exhaust the budget on iteration 3, and have the remaining iterations fail with cryptic errors. | Low | CostLedger, verification-loop.js | Check budget before each tool-calling iteration, not just at task start. If budget exhausted mid-loop: save partial progress, return partial result with clear "budget_exhausted" status, let hub decide whether to continue later or accept partial work. |
| **Idempotent task requeue** | When tasks are requeued after failures (stuck, timeout, agent crash), duplicate execution can occur if the original execution is still running. Need fence tokens or generation counters to ensure only the latest assignment executes. | Medium | TaskQueue, Scheduler, sidecar queue.js | Add `assignment_generation` counter to tasks. Incremented on each assign. Sidecar checks generation before starting execution -- if stale, skip. Hub checks generation before accepting results -- if stale, discard. Prevents ghost results from zombie executions. |
| **Sidecar reconnect with state recovery** | When a sidecar loses WebSocket connection and reconnects, it currently re-identifies but loses knowledge of in-flight tasks. If a task was mid-execution during disconnect, the result is lost. | Medium | sidecar/index.js, WebSocket handler, AgentFSM | On reconnect: sidecar reports its current state (idle, executing task_id X, completed task_id Y). Hub reconciles: if sidecar says "executing X" and hub agrees, continue waiting. If sidecar says "completed Y" but hub never got the result, accept the late result. If sidecar says "idle" but hub thinks it has a task, requeue the task. |

---

## Differentiators

Features that go beyond minimum viable. Not expected but significantly increase system capability.

| Feature | Value Proposition | Complexity | Depends On | Notes |
|---------|-------------------|------------|------------|-------|
| **Workspace-aware file tools** | Tools that understand the project structure: read file with line numbers, write file with diff preview, search codebase with ripgrep, list directory with gitignore awareness. Goes beyond "shell exec" to structured file manipulation that smaller LLMs handle better. | Medium | Tool registry, workspace-manager.js | Structured tools produce structured observations. Instead of `tool: shell, args: "cat foo.ex"` returning raw text, `tool: read_file, args: {path: "lib/foo.ex", lines: "1-50"}` returns `{content: "...", total_lines: 120, language: "elixir"}`. Structured observations help smaller models (Qwen3 8B) reason more effectively than raw shell output. |
| **Tool call streaming to dashboard** | Real-time visibility into what the agentic LLM is doing: which tools it calls, what it observes, what it reasons. Without this, agentic execution is a black box -- you submit a task and wait. | Low | Dashboard WebSocket, progress-emitter.js | Extend existing progress events: add `type: "tool_call"` with tool name, args, and result summary. Dashboard shows live tool-call timeline per task. Invaluable for debugging stuck agents and understanding LLM decision patterns. |
| **Adaptive iteration limits** | Instead of fixed max iterations, adjust based on task complexity tier. Trivial tasks get 5 iterations max. Standard get 10. Complex get 20. Prevents overthinning on simple tasks while allowing complex tasks enough room. | Low | Task complexity classification (existing), ReAct loop | Map complexity_tier to iteration budget: `{trivial: 5, standard: 10, complex: 20}`. Configurable via Config GenServer. Simple lookup, no LLM involved. |
| **Healing playbook system** | Instead of hardcoded remediation, a configurable playbook of condition-action pairs. "If stuck_tasks > 3 for > 5min, then requeue all stuck tasks." "If no_agents_online for > 10min, then send push notification." Allows Nathan to define remediation strategies without code changes. | Medium | HealthAggregator, HubFSM healing state | DETS-backed playbook with rules: `{condition: {alert_rule, duration_ms}, actions: [{:requeue_stuck}, {:notify, :push}], cooldown_ms: 300_000}`. Evaluated in Healing state on each tick. Auditable: all playbook actions logged with context. |
| **Partial result acceptance** | When an agentic task times out or exhausts budget mid-way, the partial work (files already modified, tests already written) should be preserved and reported, not discarded. Hub can decide: accept partial, create follow-up task for remainder, or discard. | Medium | ReAct loop, verification-loop.js, GoalBacklog | On forced stop: run verification on current workspace state. If some checks pass, report as `partial_pass` with list of completed vs remaining work. Hub creates follow-up task for remaining work with context from partial result. Avoids wasting completed work on timeout. |
| **LLM output format correction** | When Qwen3 8B returns malformed tool calls (common with smaller models), attempt auto-correction before failing: fix JSON syntax errors, extract tool calls from markdown code blocks, handle XML-format tool calls from Qwen3's >5-tool fallback mode. | Medium | Structured output parser | Three-layer parsing: (1) Native `tool_calls` field (preferred), (2) JSON extraction from content (regex for `{"name":..., "arguments":...}` patterns), (3) XML extraction from content (Qwen3 fallback format: `<tool_call>...</tool_call>`). Log which layer succeeded for model quality tracking. |

---

## Anti-Features

Features to explicitly NOT build. Documented to prevent scope creep.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Multi-agent tool collaboration** | Two agents calling tools on the same workspace creates race conditions, merge conflicts, and non-deterministic state. The blast radius of a bad tool call doubles. | One agent per task per workspace. If a task needs results from another task, use task dependencies (existing `depends_on` from v1.3 Phase 28). |
| **LLM-generated tool definitions** | Having the LLM create new tools at runtime (metaprogramming) is a security risk and debugging nightmare. "The model decided to create a `delete_all_files` tool and then called it." | Fixed tool registry defined in code. All tools are known, tested, and sandboxed. The LLM chooses which tools to call, not which tools exist. |
| **Autonomous Ollama model pulling** | In Healing state, auto-downloading new Ollama models to replace broken ones. Downloads are large (4-8GB), slow, and could fill disk. | Alert when models are unavailable. Human pulls models. Healing can retry health checks and restart the Ollama process, not download new models. |
| **Distributed healing consensus** | Multiple hub instances voting on healing actions via Raft/Paxos. AgentCom has one hub. Adding distributed consensus for a singleton is pure over-engineering. | Single hub, single healing decision-maker. If the hub itself crashes, OTP supervisor restarts it. The hub IS the single brain (established in v1.3 anti-features). |
| **Tool call caching/memoization** | Caching tool results (e.g., "file X was read, cache the content for next read") introduces stale data bugs. The LLM might modify a file via `write_file` and then read stale cached content on the next `read_file`. | Every tool call executes fresh. File reads always read from disk. Shell commands always execute. The overhead of re-reading a file is negligible compared to LLM inference time. |
| **Healing self-healing (recursive)** | If the Healing state itself fails (remediation action crashes), do NOT attempt to heal the healer. Infinite recursion risk. | Healing has a watchdog timeout (5min). If remediation does not complete in 5min, transition to Resting, fire critical alert. Human investigates. OTP supervisor handles process crashes. |
| **Custom tool protocols (MCP/A2A)** | Model Context Protocol and Agent-to-Agent protocol are emerging standards but add protocol negotiation complexity for zero benefit when you control both the LLM client and the tool server. | Direct function calls within the sidecar process. Tools are JavaScript functions called by the executor. No protocol overhead. Revisit MCP only if integrating external tool providers (not in scope). |

---

## Feature Dependencies

```
Tool-Calling Agent Loop (sidecar-side, JavaScript)
  |
  +--> Tool Definition Registry
  |      |
  |      +--> File tools (read, write, list, search)
  |      +--> Shell tools (exec with timeout, git commands)
  |      +--> Hub API tools (task status, goal info -- future)
  |
  +--> Tool Execution Engine
  |      |
  |      +--> Workspace sandboxing (existing workspace-manager.js)
  |      +--> Timeout enforcement per tool call
  |
  +--> ReAct Loop in OllamaExecutor
  |      |
  |      +--> Multi-turn conversation management
  |      +--> Tool result injection as role:"tool" messages
  |      +--> Loop termination detection (no tool_calls = done)
  |
  +--> Safety Guardrails (EXTERNAL to loop)
         |
         +--> Max iteration limit
         +--> Repetition detection
         +--> Token/cost budget check per iteration
         +--> Wall-clock timeout

Hub FSM Healing State (hub-side, Elixir)
  |
  +--> HealthAggregator (unifies existing health sources)
  |      |
  |      +--> Reads: Alerter, MetricsCollector, LLM Registry, AgentFSM
  |
  +--> Healing state added to HubFSM
  |      |
  |      +--> Transition: any state -> :healing (critical issue detected)
  |      +--> Transition: :healing -> :resting (remediation done or failed)
  |
  +--> Remediation Actions
         |
         +--> Stuck task requeue
         +--> Agent offline cleanup
         +--> Ollama endpoint recovery
         +--> Escalation to human (push notification)

Pipeline Reliability (cross-cutting, both hub and sidecar)
  |
  +--> Wake failure recovery (sidecar ack + hub timeout)
  +--> Task-level timeout (dispatcher.js wrapper)
  +--> Budget check per iteration (CostLedger integration)
  +--> Idempotent requeue (assignment_generation counter)
  +--> Sidecar reconnect state recovery
```

**Critical path:** Tool Registry -> Tool Executor -> ReAct Loop -> Safety Guardrails -> Healing State -> Pipeline Reliability

**Why this order:**
1. Tool registry and executor first: the ReAct loop needs tools to call. Without them, the loop has nothing to act on.
2. ReAct loop second: this is the core agentic capability. It transforms OllamaExecutor from a single-shot text generator into an agent that can actually DO things.
3. Safety guardrails third: must be in place before agentic execution runs in production. An unguarded agentic loop is dangerous.
4. Healing state fourth: depends on understanding what failures look like in practice. Building healing before the agentic pipeline runs means guessing at failure modes. Better to observe real failures first, then build targeted healing.
5. Pipeline reliability last: these are fixes to existing failure modes. They make the system robust but don't unlock new capability. Some (like task timeout) naturally pair with agentic execution and can be built alongside.

---

## MVP Recommendation

Prioritize (in build order, respecting dependency chain):

1. **Tool Definition Registry** -- Define 4-5 core tools: `read_file`, `write_file`, `list_directory`, `run_command`, `search_files`. Keep under Qwen3's 5-tool native JSON limit. Each tool has name, description, JSON schema for parameters. Pure data, no execution logic yet.

2. **Tool Execution Engine** -- Implement the execution functions for each registered tool. Sandboxed to workspace directory. Timeout per tool call (30s default). Structured return format: `{success: bool, output: string, error: string}`.

3. **ReAct Loop in OllamaExecutor** -- Modify `_streamChat` to handle multi-turn: detect `tool_calls` in response, execute tools, append results, call Ollama again. Loop until final answer or limit hit. This is the highest-complexity feature and the core deliverable.

4. **Safety Guardrails** -- Max iterations, repetition detection, budget checks, wall-clock timeout. Build alongside or immediately after the ReAct loop. Non-negotiable for production use.

5. **Task-Level Timeout** -- Wraps entire agentic execution in a deadline. Essential now that a single task can involve 15+ LLM calls. Pairs naturally with the ReAct loop work.

6. **Stuck Task Remediation** -- The most impactful pipeline reliability fix. Stuck tasks are the #1 reported failure mode. Detect and requeue automatically.

7. **HealthAggregator + Healing State** -- Unify health signals, add 5th FSM state. Build after agentic pipeline is running so you can observe real failure patterns.

Defer to follow-up:
- **Wake failure recovery**: Important but lower frequency than stuck tasks. Can be addressed by shorter acceptance timeout in the interim.
- **Sidecar reconnect state recovery**: Complex state reconciliation. Acceptable to lose in-flight work on disconnect for now (task requeue handles it).
- **Idempotent requeue**: Only matters at scale with frequent failures. Add when ghost results become a real problem.
- **Healing playbook system**: Build hardcoded remediation first. Extract to configurable playbook after patterns stabilize.
- **Tool call streaming to dashboard**: Nice to have for debugging. Add after core agentic loop works.

---

## Detailed Feature Specifications

### Tool-Calling Agent Loop: How It Works

The standard agentic pattern is ReAct (Reasoning + Acting). The loop operates as:

```
User submits task with description + context
  |
  v
[1] Build initial messages:
    system: "You are a coding agent. Use tools to complete the task."
    user: task.description + context
  |
  v
[2] Call Ollama /api/chat with messages[] + tools[]
  |
  v
[3] Parse response:
    - Has tool_calls? -> Execute tools, go to [4]
    - No tool_calls (content only)? -> Final answer, go to [6]
    - Malformed? -> Attempt auto-correction, retry once
  |
  v
[4] Execute each tool call:
    - Look up tool in registry
    - Validate arguments against schema
    - Execute with timeout (30s)
    - Capture result or error
  |
  v
[5] Append to messages:
    - assistant message (with tool_calls)
    - tool result message(s): {role: "tool", content: JSON.stringify(result)}
    - Check guardrails (iteration count, repetition, budget, timeout)
    - If guardrails tripped -> force stop, go to [6]
    - Otherwise -> go to [2]
  |
  v
[6] Return final result:
    - Collect all file modifications made via tools
    - Run verification (existing verification-loop.js)
    - Report: {status, output, tool_calls_made, iterations, tokens_used}
```

**Ollama API format for tool calling (verified from official docs):**

Request:
```json
{
  "model": "qwen3:8b",
  "messages": [
    {"role": "system", "content": "You are a coding agent..."},
    {"role": "user", "content": "Add error handling to parser.js"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "Read contents of a file in the workspace",
        "parameters": {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path": {"type": "string", "description": "Relative path from workspace root"}
          }
        }
      }
    }
  ]
}
```

Response with tool call:
```json
{
  "message": {
    "role": "assistant",
    "tool_calls": [
      {
        "type": "function",
        "function": {
          "name": "read_file",
          "arguments": {"path": "lib/parser.js"}
        }
      }
    ]
  }
}
```

Tool result fed back:
```json
{
  "role": "tool",
  "content": "{\"success\": true, \"output\": \"const parse = (input) => {\\n...\"}"
}
```

**Confidence:** HIGH -- Ollama tool calling API format verified from official docs. Qwen3 8B support confirmed. The 5-tool limit for native JSON format is a known constraint (Qwen3-coder issues documented on GitHub).

### Core Tool Definitions

| Tool | Description | Parameters | Returns | Safety |
|------|-------------|------------|---------|--------|
| `read_file` | Read file contents, optionally specific line range | `{path: string, start_line?: number, end_line?: number}` | `{content: string, total_lines: number}` | Read-only. Path must be within workspace. |
| `write_file` | Write or overwrite file contents | `{path: string, content: string}` | `{success: bool, bytes_written: number}` | Write within workspace only. No writing to paths containing `..`. |
| `list_directory` | List files in a directory | `{path?: string, recursive?: bool, pattern?: string}` | `{files: string[], directories: string[]}` | Read-only. Respects .gitignore. |
| `run_command` | Execute a shell command | `{command: string, timeout_ms?: number}` | `{exit_code: number, stdout: string, stderr: string}` | Runs in workspace dir. Blocked commands: `rm -rf /`, `sudo`, `curl` (configurable blocklist). Timeout enforced. |
| `search_files` | Search file contents with regex | `{pattern: string, path?: string, file_glob?: string}` | `{matches: [{file, line, content}]}` | Read-only. Bounded result count (max 50 matches). |

**Why these 5 tools and not more:**
- Qwen3 8B handles 5 or fewer tools reliably with native JSON tool calls. Above 5, it falls back to XML-in-content format, which requires a separate parser and is less reliable.
- These 5 cover the full read-write-execute loop needed for coding tasks.
- `search_files` replaces what would otherwise be `run_command("grep ...")` with structured output that smaller models parse more reliably.

### Hub FSM Healing State

**New state transitions:**

```
Current transitions (v1.3):
  resting:       -> [executing, improving]
  executing:     -> [resting]
  improving:     -> [resting, executing, contemplating]
  contemplating: -> [resting, executing]

New transitions (v1.4):
  resting:       -> [executing, improving, healing]
  executing:     -> [resting, healing]
  improving:     -> [resting, executing, contemplating, healing]
  contemplating: -> [resting, executing, healing]
  healing:       -> [resting]
```

Any state can transition to `:healing` when critical issues are detected. Healing always exits to `:resting` (not directly to executing/improving) to allow a clean health re-evaluation before resuming work.

**Transition predicate for entering Healing:**
```elixir
def should_heal?(system_state) do
  health = HealthAggregator.assess()
  health.has_critical_issues and not health.healing_cooldown_active
end
```

**Healing cooldown:** After a healing cycle completes, enforce a 5-minute cooldown before allowing re-entry to healing. Prevents healing oscillation (heal -> detect same issue -> heal -> repeat).

**Remediation priority order:**
1. Stuck tasks (most common, highest impact on throughput)
2. Offline agents (cleanup stale state, requeue their tasks)
3. Unhealthy Ollama endpoints (retry health checks, attempt restart)
4. Budget warnings (log, alert, but don't remediate -- human decision)

**Watchdog:** Healing state has a 5-minute watchdog. If remediation has not completed in 5 minutes, force-transition to `:resting` and fire critical alert. Prevents the healer from getting stuck.

**Confidence:** HIGH -- Adding a state to an existing GenServer FSM is straightforward. The transition logic follows established patterns from v1.3. Remediation actions are well-understood (requeue, cleanup, retry).

### Pipeline Reliability: Stuck Task Detection

**Current state:** Alerter fires `stuck_tasks` alert when tasks are assigned longer than threshold. Human must manually intervene.

**New behavior:** In Healing state, automatically remediate stuck tasks:

```elixir
def remediate_stuck_tasks do
  stuck = TaskQueue.stuck_tasks(threshold_ms: 15 * 60 * 1_000)  # 15 min

  for task <- stuck do
    agent_id = task.assigned_to

    case AgentFSM.status(agent_id) do
      :offline ->
        # Agent gone. Requeue immediately.
        TaskQueue.requeue(task.id, reason: :agent_offline)

      :working ->
        # Agent alive but task stalled. Check heartbeat age.
        if heartbeat_stale?(agent_id, threshold_ms: 120_000) do
          AgentFSM.force_offline(agent_id)
          TaskQueue.requeue(task.id, reason: :agent_unresponsive)
        else
          # Agent responsive, task legitimately slow. Extend deadline.
          TaskQueue.extend_deadline(task.id, additional_ms: 10 * 60 * 1_000)
        end

      _ ->
        # Agent in unexpected state. Requeue defensively.
        TaskQueue.requeue(task.id, reason: :agent_state_unknown)
    end
  end
end
```

**Confidence:** HIGH -- Stuck task detection already exists in Alerter. Converting from alert-only to alert-and-remediate is a small extension. The TaskQueue already supports requeue operations.

---

## Qwen3 8B Specific Considerations

The primary local LLM target is Qwen3 8B via Ollama. Key characteristics that affect feature design:

| Characteristic | Impact | Mitigation |
|----------------|--------|------------|
| 5-tool limit for native JSON | Cannot provide large tool sets | Keep core tools to exactly 5. Use tool descriptions to guide multi-step usage. |
| XML fallback above 5 tools | Different parsing format, less reliable | Implement XML parser as fallback but design for 5-tool native path. |
| Smaller context window than Claude | Cannot dump entire codebase as context | Tools must return focused, relevant content. `read_file` with line ranges. `search_files` with bounded results. |
| Lower reasoning capability | More likely to loop, call wrong tools, misparse results | Stronger system prompts with explicit step-by-step instructions. More aggressive guardrails (lower iteration limits). Structured tool results (JSON, not raw text). |
| Fast inference locally | Can afford more iterations than Claude (no API cost) | Token budget is effectively unlimited for local models. Wall-clock time is the real constraint. |
| Thinking mode (enable_thinking) | Qwen3 supports explicit chain-of-thought before tool calls | Enable thinking mode for complex tasks. Disable for trivial tasks (overhead not worth it). |

**Confidence:** MEDIUM -- Qwen3 8B tool calling capability verified from Ollama docs and Hugging Face model card. The 5-tool limit is from GitHub issues (multiple reports). Specific behavioral characteristics (loop propensity, XML fallback) come from community reports and may vary across Qwen3 versions.

---

## Sources

### Primary (HIGH confidence)
- [Ollama Tool Calling Documentation](https://docs.ollama.com/capabilities/tool-calling) -- Official API format for tool definitions, tool_calls response, multi-turn tool use (verified via WebFetch, 2026-02-14)
- [Ollama Streaming Tool Calls Blog](https://ollama.com/blog/streaming-tool) -- Streaming response format with tool calls (official Ollama blog)
- AgentCom codebase -- hub_fsm.ex, alerter.ex, ollama-executor.js, verification-loop.js, dispatcher.js (direct code examination, 2026-02-14)

### Secondary (MEDIUM confidence)
- [Qwen3 Function Calling Documentation](https://qwen.readthedocs.io/en/latest/framework/function_call.html) -- Hermes-style tool use recommended for Qwen3 (official Qwen docs)
- [LLM Tool-Calling in Production: Infinite Loop Failure Mode](https://medium.com/@komalbaparmar007/llm-tool-calling-in-production-rate-limits-retries-and-the-infinite-loop-failure-mode-you-must-2a1e2a1e84c8) -- Loop guardrail patterns: max iterations, repetition detection, resource monitors (Jan 2026)
- [Why AI Agents Get Stuck in Loops](https://www.fixbrokenaiapps.com/blog/ai-agents-infinite-loops) -- Root causes: misinterpretation of termination signals, repetitive actions, inconsistent state
- [Self-Healing Patterns for Distributed Systems (GeeksforGeeks)](https://www.geeksforgeeks.org/important-self-healing-patterns-for-distributed-systems/) -- Retry, circuit breaker, health check, watchdog patterns
- [ReAct Prompting Guide](https://www.promptingguide.ai/techniques/react) -- Thought-Action-Observation cycle definition
- [Building AI Agents with ReAct Pattern (TypeScript, 2026)](https://noqta.tn/en/tutorials/ai-agent-react-pattern-typescript-vercel-ai-sdk-2026) -- Implementation reference for ReAct in TypeScript
- [Qwen3-coder Tool Calling Fails with Many Tools (GitHub Issue)](https://github.com/block/goose/issues/6883) -- Qwen3 XML fallback with >5 tools documented

### Tertiary (LOW confidence)
- [Agent Deployment Gap (ZenML)](https://www.zenml.io/blog/the-agent-deployment-gap-why-your-llm-loop-isnt-production-ready-and-what-to-do-about-it) -- Production readiness gaps for agent loops
- [Event-Driven Agentic Loops (BoundaryML)](https://boundaryml.com/podcast/2025-11-05-event-driven-agents) -- Event log architecture for agent state management
- [Rearchitecting Agent Loops (Letta)](https://www.letta.com/blog/letta-v1-agent) -- Lessons from ReAct, MemGPT, Claude Code agent architectures

---
*Research completed: 2026-02-14*
*Focus: Agentic local LLM tool calling, Hub FSM Healing state, pipeline reliability for v1.4 milestone*
*Predecessor: v1.3 FEATURES.md covered Hub FSM Loop of Self-Improvement (shipped)*
