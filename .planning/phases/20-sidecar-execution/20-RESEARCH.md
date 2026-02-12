# Phase 20: Sidecar Execution - Research

**Researched:** 2026-02-12
**Domain:** Three-tier task execution (Ollama HTTP, Claude Code CLI, shell commands) from Node.js sidecar with streaming and cost tracking
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Execution feedback
- LLM response tokens stream to the dashboard in real-time as they're generated
- Trivial task stdout also streams to dashboard -- consistent experience across all execution types

#### Failure behavior
- Ollama failure: sidecar retries 1-2 times locally, then reports failure to hub for reassignment to a different endpoint
- Claude API failure: retry 2-3 times with exponential backoff, then mark task as failed (no downgrade to lesser model -- complex tasks need Claude)
- Trivial shell failure: retry once before reporting (covers transient issues like file locks)
- All retry attempts and failure events stream to dashboard in real-time (e.g., "Ollama retry 1/2...", "backing off 5s...")

#### Cost visibility
- Per-task cost breakdown: model used, tokens in/out, estimated cost in dollars
- Ollama tasks show equivalent Claude API cost -- demonstrates savings from running locally
- No spending guardrails at sidecar level -- that's the hub/scheduler's responsibility
- Claude API calls go through Claude Code, which handles key management -- sidecar doesn't manage API keys directly

#### Trivial execution boundaries
- Anything with a specific shell command qualifies for trivial execution -- not limited to git/file ops
- Timeout is configurable per-task -- a file rename and a test suite have different needs

### Claude's Discretion

- **Streaming path:** hub relay vs direct sidecar-to-dashboard -- pick based on existing architecture
- **Storage scope:** whether to store full LLM response or just extracted result -- pick based on storage implications
- **Sandboxing/isolation:** approach for trivial shell execution -- pick based on existing sidecar execution model
- **stdout/stderr capture:** strategy for trivial tasks -- pick based on what's most useful for downstream processing

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

## Summary

Phase 20 adds the actual execution layer to the sidecar -- making it execute tasks using the backend the hub assigned rather than just forwarding them to a wake command. The sidecar already has a task lifecycle (accept, wake, watch for result file, report complete/failed) implemented in `sidecar/index.js`. Phase 20 replaces the "wake agent and watch for result file" flow with direct execution for all three tiers: calling Ollama's HTTP API for standard tasks, invoking Claude Code CLI for complex tasks, and running shell commands for trivial tasks.

The architecture requires changes on both sides. On the **sidecar (Node.js)**, a new execution engine module dispatches to the correct executor based on routing fields the hub sends with `task_assign`. Each executor streams progress events back through the existing WebSocket `task_progress` message type. On the **hub (Elixir)**, the `task_assign` message already carries `complexity` data from Phase 17; it needs to also carry routing decision fields from Phase 19's `TaskRouter` (target_type, selected_endpoint, selected_model). The dashboard receives streaming events through the existing PubSub "tasks" topic.

The key technical challenges are: (1) streaming NDJSON from Ollama's HTTP API and forwarding token-by-token to the hub, (2) invoking Claude Code CLI with `--output-format stream-json` and capturing structured output including token counts, (3) streaming shell stdout through the same WebSocket progress channel, and (4) computing cost estimates from token counts using a model-to-price lookup table.

**Primary recommendation:** Build an `execution/` module directory in the sidecar with a dispatcher and three executor classes (OllamaExecutor, ClaudeCodeExecutor, ShellExecutor), all conforming to a common interface that emits progress events and returns a structured result with model/tokens/cost.

## Standard Stack

### Core (already in project, no new deps)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Node.js `http` | built-in | Ollama HTTP API calls (streaming NDJSON) | Already used in `lib/resources.js` for Ollama /api/ps |
| Node.js `child_process` | built-in | Claude Code CLI invocation and trivial shell execution | Already used in `lib/wake.js` for wake commands |
| `ws` | ^8.19.0 | WebSocket for streaming events back to hub | Already a dependency |
| `write-file-atomic` | ^5.0.0 | Crash-safe queue persistence | Already a dependency |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Node.js `child_process.spawn` | built-in | Streaming stdout from CLI processes (Claude Code, shell) | When real-time token streaming is needed (vs `exec` which buffers) |
| Node.js `readline` | built-in | Line-by-line NDJSON parsing from Ollama stream | Parse streaming HTTP response chunks into complete JSON lines |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Built-in `http` for Ollama | `node-fetch` or `undici` | New dependency for simple POST with streaming; `http` is sufficient and already proven in resources.js |
| `child_process.spawn` for Claude Code | `child_process.exec` | `exec` buffers all output; `spawn` streams stdout line-by-line which is needed for real-time token streaming |
| Inline cost table | npm package for LLM pricing | Cost tables change with model releases; a simple const map is easier to update than a dependency |

**Installation:** No new npm packages needed. All capabilities come from Node.js built-ins and existing dependencies.

## Architecture Patterns

### Recommended Module Structure
```
sidecar/
├── lib/
│   ├── execution/
│   │   ├── dispatcher.js       # Routes task to correct executor based on routing decision
│   │   ├── ollama-executor.js  # Calls Ollama /api/chat with streaming, collects tokens
│   │   ├── claude-executor.js  # Invokes claude CLI with --output-format stream-json
│   │   ├── shell-executor.js   # Runs shell commands via spawn with streaming stdout
│   │   ├── cost-calculator.js  # Model-to-price lookup, equivalent cost computation
│   │   └── progress-emitter.js # Formats progress events for WebSocket transmission
│   ├── queue.js                # Existing -- no changes
│   ├── wake.js                 # Existing -- used as fallback when no execution strategy
│   ├── resources.js            # Existing -- no changes
│   └── log.js                  # Existing -- no changes
├── index.js                    # Modified -- integrate execution engine into task lifecycle
└── package.json                # No new dependencies
```

### Pattern 1: Executor Interface (Strategy Pattern)
**What:** Each executor implements a common async interface: `execute(task, config, onProgress) -> ExecutionResult`.
**When to use:** Always -- the dispatcher selects the executor and calls it uniformly.

```javascript
// Common executor interface
// Every executor must implement:
//   async execute(task, config, onProgress) -> ExecutionResult
//
// onProgress(event) is called during execution with:
//   { type: 'token', text: '...', tokens_so_far: N }          // LLM streaming
//   { type: 'stdout', text: '...' }                            // Shell output
//   { type: 'status', message: 'Ollama retry 1/2...' }        // Retry/status events
//   { type: 'error', message: '...' }                          // Non-fatal errors
//
// ExecutionResult shape:
//   {
//     status: 'success' | 'failed',
//     output: string,                // The actual response/output text
//     model_used: string | 'none',   // e.g. 'llama3.2:latest', 'claude-sonnet-4.5', 'none'
//     tokens_in: number | 0,
//     tokens_out: number | 0,
//     estimated_cost_usd: number,
//     equivalent_claude_cost_usd: number | null,  // For Ollama tasks
//     execution_ms: number,
//     error: string | null
//   }
```

Source: Architectural pattern derived from existing codebase conventions (wake.js `execCommand` pattern, resources.js `collectMetrics` pattern).

### Pattern 2: Streaming via Existing WebSocket Progress Messages
**What:** Stream execution events through the existing `task_progress` WebSocket message type with an extended payload.
**When to use:** For all three execution types -- tokens, stdout, retry events.

```javascript
// Extended task_progress message (sidecar -> hub)
// Existing fields: type, task_id, progress (integer)
// New fields for execution streaming:
{
  type: 'task_progress',
  task_id: 'task-abc123',
  progress: 45,                    // Optional percentage estimate
  execution_event: {               // NEW: structured execution event
    event_type: 'token',           // 'token' | 'stdout' | 'status' | 'error'
    text: 'Hello, I can help',     // Token text, stdout line, or status message
    tokens_so_far: 42,             // Running token count (LLM only)
    model: 'llama3.2:latest',      // Model producing this output
    timestamp: 1707753600000
  }
}
```

**Discretion Decision -- Streaming Path:** Use hub relay (sidecar -> hub WS -> PubSub -> dashboard WS). This is the existing path for all task events. Direct sidecar-to-dashboard would require a new connection type and bypass the hub's event logging. Hub relay adds minimal latency (~1ms per hop on local network) and keeps the architecture consistent.

Source: Existing `Socket.handle_msg/task_progress` and `DashboardSocket.handle_info/{:task_event}` patterns.

### Pattern 3: NDJSON Streaming from Ollama HTTP
**What:** POST to Ollama's `/api/chat` with `stream: true`, parse NDJSON response line-by-line, emit progress events.
**When to use:** Standard-tier tasks routed to Ollama.

```javascript
// Ollama streaming request pattern using Node.js http
const http = require('http');

function streamOllamaChat(endpoint, model, messages, onChunk) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      model: model,
      messages: messages,
      stream: true
    });

    const options = {
      hostname: endpoint.host,
      port: endpoint.port,
      path: '/api/chat',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body)
      },
      timeout: 300000  // 5 min for long generations
    };

    const req = http.request(options, (res) => {
      let buffer = '';
      let totalTokensOut = 0;
      let finalResponse = null;

      res.on('data', (chunk) => {
        buffer += chunk.toString();
        // Split on newlines -- NDJSON protocol
        const lines = buffer.split('\n');
        buffer = lines.pop(); // Keep incomplete line in buffer

        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const parsed = JSON.parse(line);
            if (parsed.done) {
              finalResponse = parsed;
            } else if (parsed.message && parsed.message.content) {
              totalTokensOut++;
              onChunk({
                type: 'token',
                text: parsed.message.content,
                tokens_so_far: totalTokensOut
              });
            }
          } catch (e) {
            // Skip unparseable lines
          }
        }
      });

      res.on('end', () => {
        resolve({
          response: finalResponse,
          // Final response contains token counts:
          // prompt_eval_count (input tokens)
          // eval_count (output tokens)
          // total_duration (nanoseconds)
          tokens_in: finalResponse?.prompt_eval_count || 0,
          tokens_out: finalResponse?.eval_count || 0,
          total_duration_ns: finalResponse?.total_duration || 0
        });
      });

      res.on('error', reject);
    });

    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Ollama request timeout'));
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}
```

Source: Ollama official API docs (https://docs.ollama.com/api/chat). Verified: response includes `prompt_eval_count`, `eval_count`, `total_duration` in the final `done: true` message.

### Pattern 4: Claude Code CLI Invocation
**What:** Invoke `claude -p` with `--output-format stream-json` via `child_process.spawn`, parse streaming JSON events, capture token usage from final output.
**When to use:** Complex-tier tasks routed to Claude API.

```javascript
const { spawn } = require('child_process');

function streamClaudeCode(prompt, onChunk) {
  return new Promise((resolve, reject) => {
    const args = [
      '-p', prompt,
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--allowedTools', 'Read,Edit,Bash'
    ];

    const proc = spawn('claude', args, {
      shell: true,
      windowsHide: true,
      env: { ...process.env }  // Claude Code uses existing API key config
    });

    let fullOutput = '';
    let lastResult = null;

    proc.stdout.on('data', (data) => {
      const lines = data.toString().split('\n');
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const event = JSON.parse(line);
          // Filter for text delta events
          if (event.type === 'stream_event' &&
              event.event?.delta?.type === 'text_delta') {
            const text = event.event.delta.text;
            fullOutput += text;
            onChunk({ type: 'token', text });
          }
          // Capture final result with usage stats
          if (event.type === 'result') {
            lastResult = event;
          }
        } catch (e) {
          // Non-JSON lines (status messages) -- skip
        }
      }
    });

    proc.stderr.on('data', (data) => {
      // Claude Code may write status to stderr
      onChunk({ type: 'status', message: data.toString().trim() });
    });

    proc.on('close', (code) => {
      if (code === 0 && lastResult) {
        resolve({
          output: fullOutput,
          result: lastResult,
          tokens_in: lastResult.usage?.input_tokens || 0,
          tokens_out: lastResult.usage?.output_tokens || 0
        });
      } else {
        reject(new Error(`Claude Code exited with code ${code}`));
      }
    });

    proc.on('error', reject);
  });
}
```

Source: Claude Code headless documentation (https://code.claude.com/docs/en/headless). The `--output-format stream-json` flag produces NDJSON with event types including `stream_event` (partial messages) and `result` (final output with usage).

### Pattern 5: Shell Command Execution with Streaming
**What:** Execute arbitrary shell commands via `child_process.spawn` with real-time stdout/stderr streaming.
**When to use:** Trivial-tier tasks with a shell command specified.

```javascript
const { spawn } = require('child_process');

function streamShellCommand(command, opts, onChunk) {
  return new Promise((resolve, reject) => {
    const timeout = opts.timeout_ms || 60000;

    const proc = spawn(command, [], {
      shell: true,
      windowsHide: true,
      cwd: opts.cwd || process.cwd(),
      env: { ...process.env, ...(opts.env || {}) }
    });

    let stdout = '';
    let stderr = '';
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      proc.kill('SIGTERM');
      // Give 5s for graceful shutdown, then SIGKILL
      setTimeout(() => {
        try { proc.kill('SIGKILL'); } catch (e) { /* ignore */ }
      }, 5000);
    }, timeout);

    proc.stdout.on('data', (data) => {
      const text = data.toString();
      stdout += text;
      onChunk({ type: 'stdout', text });
    });

    proc.stderr.on('data', (data) => {
      const text = data.toString();
      stderr += text;
      onChunk({ type: 'stderr', text });
    });

    proc.on('close', (code, signal) => {
      clearTimeout(timer);
      if (timedOut) {
        reject(new Error(`Command timed out after ${timeout}ms`));
      } else {
        resolve({ code, signal, stdout, stderr });
      }
    });

    proc.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}
```

Source: Node.js `child_process` docs. Pattern based on existing `wake.js` `execCommand` but using `spawn` instead of `exec` for streaming.

**Discretion Decision -- Sandboxing:** No additional sandboxing beyond the sidecar's process-level isolation. The sidecar already runs as a user-level process in its own directory. The shell executor inherits the sidecar's permissions. This is consistent with the existing model where the sidecar runs wake commands via `child_process.exec` without sandboxing. Sandboxing would require containers or OS-level isolation that is out of scope for this phase.

**Discretion Decision -- stdout/stderr Capture:** Capture both stdout and stderr separately. Stream stdout to dashboard as `execution_event.event_type: 'stdout'`. Stream stderr as `execution_event.event_type: 'stderr'`. Store both in the final result. This gives downstream processing full visibility while keeping the dashboard stream focused on primary output.

### Anti-Patterns to Avoid
- **Buffering entire LLM response before sending:** Defeats the purpose of streaming. Each NDJSON line should trigger an immediate progress event.
- **Using exec() for long-running processes:** `child_process.exec` buffers all output in memory and has a default maxBuffer of 1MB. Use `spawn` for streaming.
- **Parsing Ollama NDJSON on chunk boundaries:** HTTP chunks do not align with JSON line boundaries. Always buffer and split on `\n`.
- **Blocking the event loop during execution:** All execution must be async. Never use synchronous HTTP calls or `execSync` for LLM execution.
- **Sharing Claude Code sessions across tasks:** Each task gets a fresh `claude -p` invocation. Session sharing would create state contamination.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| NDJSON line buffering | Custom buffer management | Standard `\n`-split pattern with carry buffer | Edge cases with partial lines across HTTP chunks are well-understood |
| Token cost estimation | Real-time API pricing lookup | Static cost table updated per model release | API pricing rarely changes mid-session; static table is simpler and offline |
| HTTP streaming | Promise-based HTTP client | Node.js `http.request` with `res.on('data')` | Need stream events, not buffered response; `http` module gives this natively |
| Process timeout | Manual timer + process tracking | `spawn` with `setTimeout` + `kill` | Existing pattern in `wake.js`; handles SIGTERM/SIGKILL escalation |

**Key insight:** The sidecar already has all the primitives it needs (HTTP client, process spawning, WebSocket messaging). Phase 20 is a composition problem, not a new-capability problem.

## Common Pitfalls

### Pitfall 1: Ollama prompt_eval_count Missing
**What goes wrong:** Ollama sometimes omits `prompt_eval_count` from the final response, especially when prompts exceed `num_ctx` or are cached from a previous identical request.
**Why it happens:** Ollama caches prompt evaluations. When the same prompt prefix is reused, `prompt_eval_count` may be 0 or absent.
**How to avoid:** Default `prompt_eval_count` to 0 when absent. For cost estimation, use a fallback heuristic: estimate input tokens from the prompt text length (roughly 4 characters per token).
**Warning signs:** `prompt_eval_count` is 0 or undefined while `eval_count` is normal.

### Pitfall 2: Claude Code CLI Not Installed or Not on PATH
**What goes wrong:** `child_process.spawn('claude', ...)` fails with ENOENT because Claude Code CLI is not installed on the sidecar host.
**Why it happens:** Claude Code is a development tool that must be explicitly installed. Not all sidecar hosts will have it.
**How to avoid:** Check for `claude` CLI availability at sidecar startup (or first complex task). Report clearly in task failure: "Claude Code CLI not found -- install via npm install -g @anthropic-ai/claude-code". The hub should not route complex tasks to sidecars that cannot execute them.
**Warning signs:** ENOENT errors on first complex task attempt.

### Pitfall 3: NDJSON Chunk Boundary Splitting
**What goes wrong:** A JSON object is split across two HTTP data chunks. Parsing each chunk independently produces JSON parse errors.
**Why it happens:** TCP segments have no knowledge of application-level JSON boundaries. Ollama streams NDJSON where each line is a complete JSON object, but HTTP chunking can split mid-line.
**How to avoid:** Buffer incoming data, split on `\n`, and keep any incomplete trailing content for the next chunk. Only parse complete lines.
**Warning signs:** Intermittent JSON parse errors during Ollama streaming that don't happen with `stream: false`.

### Pitfall 4: Zombie Processes from Shell Execution
**What goes wrong:** A shell command spawns child processes that outlive the timeout kill signal, leaving zombie processes.
**Why it happens:** `SIGTERM` only kills the direct child process, not its process tree. Shell commands like `npm test` spawn many children.
**How to avoid:** Use `spawn` with `{ shell: true }` and send `SIGTERM` followed by `SIGKILL` after a grace period. On Windows, use `taskkill /PID /T /F` for process tree termination.
**Warning signs:** Accumulating Node.js or system processes after task timeouts.

### Pitfall 5: Claude Code Exit Without Token Usage
**What goes wrong:** Claude Code CLI exits successfully but the stream-json output does not include a `result` event with usage statistics.
**Why it happens:** Certain errors or edge cases in Claude Code may produce output without the expected final result event.
**How to avoid:** Treat missing usage data as "unknown" rather than failing the task. Report `tokens_in: null, tokens_out: null` and skip cost estimation for that task.
**Warning signs:** Successful task completion but null token/cost fields.

### Pitfall 6: WebSocket Backpressure from High-Frequency Token Streaming
**What goes wrong:** Fast LLM generation (100+ tokens/second) floods the WebSocket with task_progress messages, overwhelming the hub and dashboard.
**Why it happens:** Each generated token triggers an individual WebSocket message.
**How to avoid:** Batch token progress events -- accumulate tokens for 50-100ms windows and send one progress message per batch. The dashboard already batches events every 100ms in `DashboardSocket`.
**Warning signs:** Hub CPU spikes during LLM execution, dashboard lag.

## Code Examples

### Dispatcher Pattern
```javascript
// sidecar/lib/execution/dispatcher.js
'use strict';

const { OllamaExecutor } = require('./ollama-executor');
const { ClaudeExecutor } = require('./claude-executor');
const { ShellExecutor } = require('./shell-executor');
const { log } = require('../log');

/**
 * Dispatch a task to the appropriate executor based on routing decision.
 *
 * @param {object} task - Task from task_assign message (includes routing fields)
 * @param {object} config - Sidecar config
 * @param {function} onProgress - Callback for streaming events
 * @returns {Promise<ExecutionResult>}
 */
async function dispatch(task, config, onProgress) {
  // Routing decision comes from hub via task_assign (Phase 19 TaskRouter)
  const routing = task.routing_decision || {};
  const targetType = routing.target_type || inferTargetType(task);

  log('info', 'execution_dispatch', {
    task_id: task.task_id,
    target_type: targetType,
    model: routing.selected_model || null,
    endpoint: routing.selected_endpoint || null
  });

  switch (targetType) {
    case 'ollama':
      return new OllamaExecutor().execute(task, config, onProgress);

    case 'claude':
      return new ClaudeExecutor().execute(task, config, onProgress);

    case 'sidecar':
      return new ShellExecutor().execute(task, config, onProgress);

    default:
      throw new Error(`Unknown target type: ${targetType}`);
  }
}

/**
 * Fallback inference when routing_decision is missing.
 * Uses complexity tier from Phase 17 enrichment.
 */
function inferTargetType(task) {
  const tier = task.complexity?.effective_tier;
  switch (tier) {
    case 'trivial': return 'sidecar';
    case 'complex': return 'claude';
    case 'standard':
    default: return 'ollama';
  }
}

module.exports = { dispatch };
```

### Cost Calculator
```javascript
// sidecar/lib/execution/cost-calculator.js
'use strict';

/**
 * Cost per million tokens by model family.
 * Updated: 2026-02 (Claude pricing from https://platform.claude.com/docs/en/about-claude/pricing)
 *
 * Format: { input_per_million, output_per_million }
 */
const COST_TABLE = {
  // Claude models (used for complex tasks and equivalent cost comparison)
  'claude-sonnet-4.5':   { input_per_million: 3.00,  output_per_million: 15.00 },
  'claude-opus-4.5':     { input_per_million: 5.00,  output_per_million: 25.00 },
  'claude-haiku-4.5':    { input_per_million: 1.00,  output_per_million: 5.00 },
  'claude-opus-4.6':     { input_per_million: 5.00,  output_per_million: 25.00 },
  // Default Claude cost for equivalent comparison (Sonnet as baseline)
  '_claude_equivalent':  { input_per_million: 3.00,  output_per_million: 15.00 }
};

/**
 * Calculate estimated cost in USD from token counts.
 *
 * @param {string} model - Model name (e.g., 'llama3.2:latest', 'claude-sonnet-4.5')
 * @param {number} tokensIn - Input token count
 * @param {number} tokensOut - Output token count
 * @returns {{ cost_usd: number, equivalent_claude_cost_usd: number|null }}
 */
function calculateCost(model, tokensIn, tokensOut) {
  // Find matching cost entry (try exact match, then prefix match)
  const entry = findCostEntry(model);

  const cost_usd = entry
    ? (tokensIn / 1_000_000 * entry.input_per_million) +
      (tokensOut / 1_000_000 * entry.output_per_million)
    : 0;  // Ollama/local models = $0

  // Calculate equivalent Claude cost for local models
  let equivalent_claude_cost_usd = null;
  if (!entry && (tokensIn > 0 || tokensOut > 0)) {
    const equiv = COST_TABLE['_claude_equivalent'];
    equivalent_claude_cost_usd =
      (tokensIn / 1_000_000 * equiv.input_per_million) +
      (tokensOut / 1_000_000 * equiv.output_per_million);
  }

  return { cost_usd, equivalent_claude_cost_usd };
}

function findCostEntry(model) {
  if (!model || model === 'none') return null;
  // Exact match
  if (COST_TABLE[model]) return COST_TABLE[model];
  // Prefix match (e.g., 'claude-sonnet-4.5' matches 'claude-sonnet-4.5:latest')
  for (const [key, entry] of Object.entries(COST_TABLE)) {
    if (key.startsWith('_')) continue;
    if (model.startsWith(key)) return entry;
  }
  return null;
}

module.exports = { calculateCost, COST_TABLE };
```

### Integration with Existing Task Lifecycle (index.js changes)
```javascript
// In handleTaskAssign, after existing task creation:
// Replace the wakeAgent(task, this) call with execution dispatch

const routing = msg.routing_decision || {};
if (routing.target_type && routing.target_type !== 'wake') {
  // Phase 20: Direct execution via execution engine
  executeTask(task, this);
} else {
  // Legacy: wake agent and watch for result file
  wakeAgent(task, this);
}

async function executeTask(task, hub) {
  const { dispatch } = require('./lib/execution/dispatcher');

  const onProgress = (event) => {
    hub.send({
      type: 'task_progress',
      task_id: task.task_id,
      execution_event: {
        event_type: event.type,
        text: event.text || event.message || '',
        tokens_so_far: event.tokens_so_far || null,
        model: event.model || null,
        timestamp: Date.now()
      }
    });
  };

  try {
    task.status = 'working';
    saveQueue(QUEUE_PATH, _queue);

    const result = await dispatch(task, _config, onProgress);

    hub.sendTaskComplete(task.task_id, {
      status: result.status,
      output: result.output,
      model_used: result.model_used,
      tokens_in: result.tokens_in,
      tokens_out: result.tokens_out,
      estimated_cost_usd: result.estimated_cost_usd,
      equivalent_claude_cost_usd: result.equivalent_claude_cost_usd,
      execution_ms: result.execution_ms
    });
  } catch (err) {
    hub.sendTaskFailed(task.task_id, err.message);
  }

  _queue.active = null;
  saveQueue(QUEUE_PATH, _queue);
}
```

## Discretion Recommendations (Summary)

### Streaming Path: Hub Relay
**Recommendation:** Route all execution streaming events through the existing sidecar -> hub WebSocket -> PubSub -> dashboard WebSocket path.
**Rationale:** This is the existing architecture for all task events. The `DashboardSocket` already subscribes to PubSub "tasks" topic and batches events every 100ms. Adding a direct sidecar-to-dashboard path would require new connection infrastructure, break the hub's event logging/telemetry, and create two parallel event streams to maintain. The latency added by hub relay is negligible (~1ms on Tailscale mesh).

### Storage Scope: Store Extracted Result + Summary Metadata
**Recommendation:** Store the task's final extracted result text, NOT the full LLM response stream. Store summary metadata (model, tokens_in, tokens_out, cost, execution_ms) alongside the result.
**Rationale:** Full LLM responses (especially streaming transcripts with every intermediate token) can be very large. The existing `TaskQueue` stores results in DETS which is not designed for large blobs. The extracted result text (the final answer) plus metadata provides all the information needed for downstream processing, cost tracking, and debugging. If a full transcript is ever needed, it can be reconstructed from the streaming events logged by the hub.

### Sandboxing: Process-Level Only (No Container)
**Recommendation:** No additional sandboxing beyond the sidecar's existing process-level isolation. Shell commands run as the sidecar's user with the sidecar's environment.
**Rationale:** The existing sidecar already executes wake commands via `child_process.exec` without sandboxing. Adding OS-level sandboxing (containers, sandboxed namespaces) would be a significant infrastructure change that does not belong in an execution phase. The sidecar is already a trusted component in the architecture.

### stdout/stderr Capture: Separate Streams, Both Stored
**Recommendation:** Capture stdout and stderr as separate strings. Stream both to the dashboard as distinct `execution_event` types ('stdout' vs 'stderr'). Store both in the final result.
**Rationale:** Separating streams allows the dashboard to display them differently (stderr in warning color) and downstream processing to distinguish between program output and error output. Merging them (as `:stderr_to_stdout` would) loses information.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Claude API raw HTTP calls | Claude Code CLI (`claude -p`) | 2025 | Key management, tool use, and agentic behavior handled by CLI |
| Ollama `/api/generate` | Ollama `/api/chat` | 2024 | Chat format supports multi-turn, system messages, tool calling |
| `child_process.exec` for streaming | `child_process.spawn` for streaming | Always | `exec` buffers; `spawn` streams -- use `spawn` for real-time output |
| Single cost table | Per-context-window tiered pricing | 2025-2026 | Claude Opus 4.6 has different rates for >200k token contexts |

**Deprecated/outdated:**
- Ollama `/api/generate`: Still works but `/api/chat` is the recommended endpoint for conversational use
- `child_process.exec` for long-running processes: Buffering limit (1MB default) makes it unsuitable for LLM output
- Raw Claude API calls: Claude Code CLI wraps authentication, tool use, and context management -- no need to manage API keys in the sidecar

## Open Questions

1. **Task_assign routing fields**
   - What we know: Phase 19's `TaskRouter` produces a routing decision map with `target_type`, `selected_endpoint`, `selected_model`, etc.
   - What's unclear: Whether Phase 19 is already sending these fields in the `task_assign` WebSocket message. Currently `Socket.handle_info({:push_task, task})` sends enrichment fields but not routing decision fields.
   - Recommendation: Phase 20 Plan should include a step to add `routing_decision` to the `task_assign` message payload. If Phase 19 has already done this, verify the field names match what the sidecar expects.

2. **Claude Code `--output-format stream-json` exact event schema**
   - What we know: Events include `stream_event` with `delta.type` and `delta.text`, and a final event with `usage.input_tokens` / `usage.output_tokens`.
   - What's unclear: The exact schema of the final result event and whether it reliably includes usage statistics in all cases.
   - Recommendation: The first implementation task should include a manual test of `claude -p "hello" --output-format stream-json` to capture the actual output structure. Build parsing defensively.

3. **Ollama model name to cost mapping**
   - What we know: Ollama models are free (local execution). Cost estimation uses token counts to compute "what this would have cost on Claude."
   - What's unclear: Mapping from Ollama model names (e.g., `llama3.2:7b`, `codellama:34b`) to appropriate Claude equivalent model for cost comparison.
   - Recommendation: Use a single Claude Sonnet baseline for all equivalent cost calculations. The exact mapping is less important than showing the cost savings concept. A future phase could refine this based on model capability tiers.

4. **Token batching window for progress events**
   - What we know: High-frequency token generation (100+ tokens/sec from fast Ollama models) could flood WebSocket.
   - What's unclear: What batching interval provides the best balance between responsiveness and load.
   - Recommendation: Start with 100ms batching (matching `DashboardSocket` flush interval). Accumulate token text in a buffer and emit one progress event per 100ms window. This can be tuned later.

## Sources

### Primary (HIGH confidence)
- Ollama API docs (https://docs.ollama.com/api/chat) -- request/response format, streaming NDJSON, token fields (prompt_eval_count, eval_count)
- Ollama API docs (https://docs.ollama.com/api/generate) -- generate endpoint, token metrics, done response fields
- Claude Code headless docs (https://code.claude.com/docs/en/headless) -- `-p` flag, `--output-format stream-json`, streaming events, usage
- Claude pricing (https://platform.claude.com/docs/en/about-claude/pricing) -- per-million-token costs for Sonnet 4.5, Opus 4.5, Haiku 4.5, Opus 4.6
- Existing codebase: `sidecar/index.js`, `sidecar/lib/wake.js`, `sidecar/lib/resources.js` -- Node.js patterns for HTTP, process execution, WebSocket messaging
- Existing codebase: `lib/agent_com/socket.ex` -- task_progress handling, task_assign payload
- Existing codebase: `lib/agent_com/dashboard_socket.ex` -- event batching, PubSub forwarding
- Existing codebase: `lib/agent_com/task_router.ex` -- routing decision structure (target_type, selected_endpoint, selected_model)

### Secondary (MEDIUM confidence)
- Streaming LLM in Elixir/Phoenix (https://benreinhart.com/blog/openai-streaming-elixir-phoenix/) -- NDJSON parsing pattern, Req streaming callback
- Ollama Elixir library (https://hexdocs.pm/ollama/0.3.0/Ollama.API.html) -- streaming API, chat/completion interface

### Tertiary (LOW confidence)
- Claude Code stream-json exact event schema -- based on documentation descriptions, not hands-on verification. Should be validated during implementation.
- Token batching interval recommendation (100ms) -- based on matching DashboardSocket flush interval, not load testing.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all components use existing Node.js built-ins and project dependencies; no new packages
- Architecture: HIGH -- execution engine pattern is well-understood; sidecar already has all primitives (HTTP, spawn, WebSocket)
- Pitfalls: HIGH -- NDJSON parsing, process management, and streaming patterns are well-documented with known edge cases
- Cost estimation: MEDIUM -- pricing data is current but Claude Code stream-json output schema needs hands-on verification

**Research date:** 2026-02-12
**Valid until:** 2026-03-12 (30 days -- stable patterns; pricing may update)
