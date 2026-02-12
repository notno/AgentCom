# Phase 13: Structured Logging + Telemetry - Research

**Researched:** 2026-02-12
**Domain:** Structured JSON logging, Erlang/Elixir telemetry, Node.js structured logging
**Confidence:** HIGH

## Summary

This phase converts AgentCom's existing unstructured logging (69 Logger calls across 14 Elixir modules + ~40 console.log calls in the Node.js sidecar) into structured JSON output with consistent metadata, and adds telemetry events for all key lifecycle points. The Elixir hub currently uses the default console formatter (`$time $metadata[$level] $message\n`) with only `:request_id` and `:agent_id` metadata configured. The Node.js sidecar already has a partially structured `log()` function that writes JSON to a file but uses `console.log()` for stdout with inconsistent formatting.

The standard approach for Elixir is LoggerJSON ~> 7.0 for JSON formatting (4 lines of config change) combined with `:telemetry` (already present as transitive dependency via Bandit at version 1.3.0) for event emission. The Elixir Logger system natively supports per-process metadata via `Logger.metadata/1`, file rotation via OTP's `:logger_std_h` handler, and runtime level changes via `Logger.configure/1`. For the sidecar, the existing `log()` function needs enhancement to include all required fields (level, module, function, line) and the stdout output should emit raw JSON lines (NDJSON format) instead of the current mixed format.

The migration is big-bang by user decision: all 69 Logger calls across all 14 modules are converted in one phase. This is feasible because the conversion is mechanical (add metadata in `init/1`, replace string interpolation with structured metadata) and the test suite can verify JSON output per-module. The key technical risk is ensuring all log output paths (including Bandit/Plug.Logger HTTP request logs and OTP supervisor reports) emit valid JSON, not just application-level Logger calls.

**Primary recommendation:** Use LoggerJSON ~> 7.0 with Basic formatter, set Logger.metadata/1 in every GenServer init/1 with module-level context, use `:telemetry.span/3` for operations with duration and `:telemetry.execute/3` for point-in-time events, and add a second OTP logger handler for file output with size-based rotation.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Log format & fields
- Full trace metadata in every log entry: timestamp, level, module, message, pid, node, function name, line number
- Context fields included when available: task_id, agent_id, request_id
- 5-level system: debug (internal state), info (lifecycle events), notice (operational completions like backups/compaction), warning (recoverable issues), error (failures requiring attention)
- Redact auth tokens/secrets in log output; task content and agent names are allowed

#### Telemetry event design
- Erlang/OTP naming convention: `[:agent_com, :task, :submit]` style atom lists
- Full state machine granularity: every FSM state transition emits an event (idle->assigned, assigned->working, working->blocked, etc.)
- Events carry measurements with timing: duration_ms for operations, queue_depth for submissions, retry_count for failures -- enables Phase 14 metrics aggregation
- DETS operations included: backup:start/complete/fail, compaction:start/complete, restore:start/complete

#### Migration approach
- Big bang migration: replace all Logger calls across all modules in one phase -- clean cutover, no mixed formats
- Both Elixir hub and Node.js sidecar get structured JSON logging with same field conventions for unified log parsing
- Tests assert log output is valid JSON with required fields (per-module assertion tests, not just smoke)

#### Output & consumption
- Dual output: stdout for real-time monitoring + rotating log files for historical analysis
- Log level configurable both via config.exs (default) and runtime API endpoint (PUT /api/admin/log-level) -- API override resets on restart

### Claude's Discretion
- Nested operation correlation strategy (flat correlation IDs vs span-style parent/child)
- Whether to use a shared AgentCom.Log helper module or Logger.metadata per-process
- File rotation strategy (size-based vs time-based, retention count)
- Whether telemetry events should feed into the dashboard in real-time now or wait for Phase 14

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| LoggerJSON | ~> 7.0 (7.0.4 current) | JSON formatter for Elixir Logger | Official structured logging library for Elixir. Provides Basic, GoogleCloud, Datadog, Elastic formatters. Uses Jason encoder (already in project). Supports metadata filtering, redactors for secret scrubbing, and Elixir 1.18+ built-in JSON encoder. |
| :telemetry | 1.3.0 (already present) | Event emission for lifecycle points | Already a transitive dependency via Bandit and Plug. Standard Erlang/Elixir observability primitive. Provides execute/3, attach/4, span/3 for point events and timed operations. |
| Logger (stdlib) | Elixir 1.19.5 built-in | Per-process metadata, runtime config | `Logger.metadata/1` sets per-process metadata automatically included in every log entry. `Logger.configure/1` enables runtime log level changes. `:default_handler` supports file rotation natively via OTP `:logger_std_h`. |
| Jason | ~> 1.4 (already present) | JSON encoding for log output | Already a dependency. Used by LoggerJSON as encoder. Also used for sidecar JSON log output validation in tests. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| :logger_std_h | OTP stdlib | File handler with rotation | Used to add a second OTP logger handler for rotating log files alongside the default stdout handler. Supports `max_no_bytes`, `max_no_files`, `compress_on_rotate`. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| LoggerJSON | Custom formatter (~30 lines) | LoggerJSON handles edge cases: safe encoding of non-UTF8 binaries, PID/ref formatting, crash reason formatting, Plug.Conn extraction. Custom formatter would need to handle these individually. LoggerJSON is 1 dependency with 0 transitive deps beyond Jason. |
| LoggerJSON | Elixir 1.18+ built-in JSON module as formatter | Built-in JSON can be used as LoggerJSON's encoder (reducing Jason coupling), but you still need LoggerJSON for the formatting logic (timestamp, severity, metadata structuring). Not a replacement. |
| Pino (Node.js) | Keep custom log() function | The sidecar already has a `log()` function writing JSON. Adding Pino (a full framework) for 1 file with ~40 log calls is unnecessary overhead. Enhance the existing function instead. |

**Installation (Elixir only -- no new sidecar deps):**
```bash
cd C:/Users/nrosq/src/AgentCom
# Add to mix.exs deps: {:logger_json, "~> 7.0"}
mix deps.get
```

## Discretion Recommendations

### 1. Correlation Strategy: Use flat request_id (not span-style parent/child)

**Recommendation:** Flat correlation IDs with `request_id` metadata.

**Rationale:** AgentCom's operations are shallow (1-2 levels deep). A task submission flows: HTTP/WS entry -> TaskQueue.submit -> PubSub broadcast -> Scheduler.assign. There is no deep call tree requiring parent/child spans. A single `request_id` generated at the entry point (WebSocket message or HTTP request) and propagated via `Logger.metadata` is sufficient for correlating all log entries for a single operation.

Span-style parent/child adds complexity (generating span IDs, tracking parent context, propagating across GenServer calls) that only pays off with deep nesting or distributed tracing across services. AgentCom is a single BEAM node. The `:telemetry.span/3` function already emits start/stop/exception events with duration -- this provides span-like timing data without requiring custom span IDs in log metadata.

**Implementation:** Generate `request_id` at entry points (Socket.handle_in, Endpoint routes), set via `Logger.metadata(request_id: id)`. GenServers that receive messages with task_id/agent_id set those as metadata in their handlers.

### 2. Logger.metadata per-process (not shared helper module)

**Recommendation:** Use `Logger.metadata/1` directly in GenServer `init/1` callbacks. No shared `AgentCom.Log` helper module.

**Rationale:** `Logger.metadata/1` is a per-process operation that sets metadata for the current process. In GenServers, calling it in `init/1` automatically tags every subsequent log call from that process. This is the standard Elixir pattern and requires zero custom infrastructure.

A shared helper module would add indirection without benefit. The metadata fields are simple (:module, :agent_id, :task_id) and vary per-module. Each GenServer knows its own context best. The only shared logic needed is request_id generation, which is a one-line function (`Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)`).

**Implementation pattern:**
```elixir
# In GenServer init/1:
Logger.metadata(module: __MODULE__, agent_id: agent_id)

# In handle_cast/handle_call when task context changes:
Logger.metadata(task_id: task_id)
```

### 3. File Rotation: Size-based, 10MB, 5 files

**Recommendation:** Size-based rotation at 10MB per file, keeping 5 rotated files, with compression.

**Rationale:** OTP's `:logger_std_h` natively supports size-based rotation via `max_no_bytes` and `max_no_files`. Time-based rotation requires a cron job or custom timer -- unnecessary complexity. At the current scale (5 agents, ~100 events/minute), 10MB per file gives roughly 1-2 days of logs per file. 5 rotated files (50MB total) provides a week of history, which is sufficient for a local system. Compressed rotated files further reduce disk usage.

**Implementation:**
```elixir
# config/config.exs -- add file handler alongside default stdout handler
config :logger, [
  {:handler, :file_handler, :logger_std_h, %{
    config: %{
      file: ~c"priv/logs/agent_com.log",
      max_no_bytes: 10_000_000,
      max_no_files: 5,
      compress_on_rotate: true
    },
    formatter: LoggerJSON.Formatters.Basic.new(
      metadata: {:all_except, [:conn, :crash_reason]}
    )
  }}
]
```

### 4. Telemetry Events: Do NOT feed into dashboard now -- wait for Phase 14

**Recommendation:** Emit telemetry events in Phase 13 but do NOT wire them to the dashboard. Phase 14 (Metrics + Alerting) will aggregate events into dashboard-consumable metrics.

**Rationale:** The dashboard currently consumes PubSub events directly (DashboardState subscribes to "tasks", "presence", "backups", "validation" topics). Adding raw telemetry event streaming to the dashboard would bypass the aggregation layer that Phase 14 is designed to provide. Raw telemetry events are high-volume (every FSM transition, every DETS operation) and would overwhelm the dashboard WebSocket without aggregation.

Phase 13 delivers the event emission infrastructure. Phase 14 attaches handlers that aggregate events into counters, gauges, and histograms, then pushes aggregated snapshots to the dashboard at configurable intervals.

**Implementation:** In Phase 13, telemetry events are emitted via `:telemetry.execute/3` and `:telemetry.span/3`. A simple `AgentCom.Telemetry` module documents all events and attaches a logging handler (for structured log output of key events). Phase 14 adds metric aggregation handlers.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  telemetry.ex            # NEW: Event definitions, handler attachment, logging handler
  # All existing modules modified:
  agent_fsm.ex            # Add Logger.metadata in init, telemetry events on transitions
  task_queue.ex            # Add telemetry spans for submit/assign/complete/fail
  scheduler.ex             # Add telemetry events for scheduling attempts
  dets_backup.ex           # Add telemetry spans for backup/compaction/restore
  presence.ex              # Add telemetry events for agent connect/disconnect
  socket.ex                # Add request_id generation, Logger.metadata per-connection
  endpoint.ex              # Add request_id to HTTP requests, runtime log-level endpoint
  reaper.ex                # Add telemetry events for stale agent eviction
  channels.ex              # Add Logger.metadata
  mailbox.ex               # Add Logger.metadata
  config.ex                # Add Logger.metadata
  threads.ex               # Add Logger.metadata
  message_history.ex       # Add Logger.metadata
  dashboard_notifier.ex    # Add Logger.metadata

config/
  config.exs               # LoggerJSON formatter config, file handler, telemetry setup
  dev.exs                  # NEW: Human-readable dev logging (or keep JSON for consistency)
  test.exs                 # Log level :warning (already set)

sidecar/
  index.js                 # Enhance log() function with full field set
  lib/log.js               # NEW: Extracted structured logger module with level support
```

### Pattern 1: GenServer Logger.metadata in init/1
**What:** Set process-level metadata once during GenServer initialization, automatically included in all subsequent log calls from that process.
**When to use:** Every GenServer that logs.
**Example:**
```elixir
# Source: https://hexdocs.pm/logger/Logger.html#metadata/1
@impl true
def init(args) do
  agent_id = Keyword.fetch!(args, :agent_id)
  Logger.metadata(module: __MODULE__, agent_id: agent_id)
  # ... rest of init
end
```

### Pattern 2: Telemetry Event Emission with :telemetry.execute/3
**What:** Emit a point-in-time event with measurements and metadata for Phase 14 aggregation.
**When to use:** State transitions, task lifecycle events, agent connect/disconnect.
**Example:**
```elixir
# Source: https://hexdocs.pm/telemetry/telemetry.html
# Point-in-time event (no duration):
:telemetry.execute(
  [:agent_com, :task, :submit],
  %{queue_depth: length(state.priority_index) + 1},
  %{task_id: task.id, priority: task.priority, submitted_by: task.submitted_by}
)
```

### Pattern 3: Telemetry Span for Timed Operations
**What:** Wrap an operation to automatically emit start/stop/exception events with duration_ms.
**When to use:** DETS backup, compaction, restore -- operations where duration matters.
**Example:**
```elixir
# Source: https://hexdocs.pm/telemetry/telemetry.html
:telemetry.span(
  [:agent_com, :dets, :backup],
  %{table: table_atom},
  fn ->
    result = do_backup_table(table_atom, backup_dir)
    {result, %{table: table_atom, size: result_size(result)}}
  end
)
# Emits: [:agent_com, :dets, :backup, :start] with system_time, monotonic_time
# Emits: [:agent_com, :dets, :backup, :stop] with duration (native time units)
# Emits: [:agent_com, :dets, :backup, :exception] on error with duration, kind, reason, stacktrace
```

### Pattern 4: Dual Output Configuration (stdout + file)
**What:** OTP Logger supports multiple handlers. Configure one for stdout (default) and one for rotating files.
**When to use:** Production and development environments.
**Example:**
```elixir
# config/config.exs
# Default handler: stdout with JSON formatting
config :logger, :default_handler,
  formatter: LoggerJSON.Formatters.Basic.new(
    metadata: {:all_except, [:conn, :crash_reason]}
  )

# Additional handler: rotating file
config :logger, [
  {:handler, :file_handler, :logger_std_h, %{
    config: %{
      file: ~c"priv/logs/agent_com.log",
      max_no_bytes: 10_000_000,
      max_no_files: 5,
      compress_on_rotate: true
    },
    formatter: LoggerJSON.Formatters.Basic.new(
      metadata: {:all_except, [:conn, :crash_reason]}
    )
  }}
]
```

### Pattern 5: Redactor Configuration for Secret Scrubbing
**What:** LoggerJSON supports redactors -- modules that scrub sensitive data from log output before encoding.
**When to use:** Any log entry that might contain auth tokens.
**Example:**
```elixir
# Source: https://hexdocs.pm/logger_json/LoggerJSON.html
config :logger, :default_handler,
  formatter: LoggerJSON.Formatters.Basic.new(
    metadata: {:all_except, [:conn, :crash_reason]},
    redactors: [{LoggerJSON.Redactors.RedactKeys, keys: ["token", "auth_token", "secret"]}]
  )
```

### Pattern 6: Runtime Log Level API Endpoint
**What:** HTTP endpoint to change log level without restart. Resets on restart per user decision.
**When to use:** PUT /api/admin/log-level
**Example:**
```elixir
# In endpoint.ex:
put "/api/admin/log-level" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    level = conn.body_params["level"]
    if level in ~w(debug info notice warning error) do
      Logger.configure(level: String.to_existing_atom(level))
      send_json(conn, 200, %{"status" => "ok", "level" => level})
    else
      send_json(conn, 422, %{"error" => "invalid_level", "valid" => ["debug", "info", "notice", "warning", "error"]})
    end
  end
end
```

### Pattern 7: Node.js Sidecar Structured Logger
**What:** Enhanced log() function with full field set matching Elixir hub conventions.
**When to use:** All sidecar log output.
**Example:**
```javascript
// sidecar/lib/log.js
const LEVELS = { debug: 10, info: 20, notice: 30, warning: 40, error: 50 };
let _logLevel = LEVELS.info;
let _logStream = null;

function log(level, event, data = {}, source = 'sidecar') {
  if (LEVELS[level] < _logLevel) return;

  const entry = {
    time: new Date().toISOString(),
    severity: level,
    message: event,
    module: source,
    agent_id: _config ? _config.agent_id : 'unknown',
    pid: process.pid,
    node: require('os').hostname(),
    ...data
  };

  // NDJSON to stdout (matches Elixir hub format for unified parsing)
  process.stdout.write(JSON.stringify(entry) + '\n');

  // Rotating file output
  if (_logStream) {
    _logStream.write(JSON.stringify(entry) + '\n');
  }
}
```

### Anti-Patterns to Avoid
- **String interpolation in log messages:** Do NOT use `Logger.info("Task #{task_id} submitted by #{agent_id}")`. Instead, use structured metadata: `Logger.info("task_submitted", task_id: task_id, agent_id: agent_id)` or `Logger.info(%{event: "task_submitted", task_id: task_id})`. String interpolation defeats the purpose of structured logging.
- **Logging in hot paths without level guards:** `:telemetry.execute/3` is lightweight but Logger calls with string building are not. Use `Logger.debug(fn -> "expensive: #{inspect(large_state)}" end)` for debug-level messages.
- **Setting metadata on every log call:** Set metadata once in `init/1`, not before every `Logger.info`. Logger metadata is per-process and persists.
- **Mixing PubSub events and telemetry events:** PubSub broadcasts trigger application behavior (scheduler reacts to task_submitted). Telemetry events are observability-only (no business logic should depend on them). Keep these separate.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON log formatting | Custom JSON formatter | LoggerJSON ~> 7.0 | Handles PID/ref/crash_reason formatting, non-UTF8 binaries, Plug.Conn extraction, timestamp formatting, metadata filtering. ~300 lines of edge-case handling you would need to replicate. |
| Log file rotation | Custom file rotation logic | OTP `:logger_std_h` with `max_no_bytes` / `max_no_files` | Built into Erlang/OTP stdlib. Handles atomic rotation, compressed archives, concurrent writes safely. |
| Telemetry event dispatch | Custom PubSub-based event system | `:telemetry` 1.3.0 (already present) | Already in the dependency tree. ETS-based dispatch is faster than PubSub. Handlers are detached on crash (fail-safe). Standard ecosystem convention. |
| Secret redaction in logs | Custom regex scrubbing | LoggerJSON redactors | Pluggable redactor system with `RedactKeys` built-in. Handles nested maps, lists of maps, and string values. |
| Sidecar file rotation | Custom file rotation in JS | Node.js write stream with size check | The sidecar is a single-file process. A simple size-check-and-rename on write is ~15 lines. No npm dependency needed (avoid winston/pino for 1 file). |

**Key insight:** The Elixir Logger + OTP handler system already provides 90% of what this phase needs. LoggerJSON adds the remaining 10% (JSON formatting with edge cases). The telemetry library is already in the dependency tree. The real work is mechanical: converting 69 Logger calls to use structured metadata and adding ~15 telemetry event emission points.

## Common Pitfalls

### Pitfall 1: OTP Supervisor Reports Breaking JSON Output
**What goes wrong:** Even after configuring LoggerJSON, OTP supervisor crash reports and SASL reports emit non-JSON formatted output, breaking log parsers.
**Why it happens:** OTP's default report handler uses its own formatting, not the application Logger formatter. Bandit/Plug also emit their own formatted logs via Plug.Logger.
**How to avoid:** LoggerJSON handles OTP reports when configured as the `:default_handler` formatter -- it converts crash_reason tuples to JSON-safe maps. Verify by crashing a GenServer in test and asserting the output is valid JSON. For Plug.Logger, it emits standard Logger calls that LoggerJSON will format. No additional work needed.
**Warning signs:** Non-JSON lines in log output, especially during error conditions. Test by killing a GenServer and checking log output format.

### Pitfall 2: Metadata Key Explosion
**What goes wrong:** Setting too many metadata keys across too many processes creates inconsistent log schemas. Different modules include different keys, making log parsing unreliable.
**Why it happens:** No central definition of what metadata keys exist.
**How to avoid:** Define a fixed set of metadata keys in `AgentCom.Telemetry` module documentation. Standard keys: `module`, `agent_id`, `task_id`, `request_id`, `table` (for DETS ops). All other context goes in the log message struct, not metadata. Use `metadata: {:all_except, [:conn, :crash_reason]}` in LoggerJSON config to avoid leaking large structs.
**Warning signs:** Log entries with 20+ top-level keys, or keys that appear in <5% of entries.

### Pitfall 3: Telemetry Handler Crash Detaching All Handlers
**What goes wrong:** If a telemetry handler function crashes, `:telemetry` automatically detaches it. All subsequent events for that handler are silently dropped.
**Why it happens:** `:telemetry` is designed for fail-safety -- a crashing handler should not crash the emitting process. The tradeoff is silent detachment.
**How to avoid:** Wrap handler functions in try/rescue. Log handler crashes at :error level. In the `AgentCom.Telemetry` module, use `Process.send_after(self(), :reattach_handlers, 5_000)` as a safety net to periodically verify handlers are still attached. Use `:telemetry.list_handlers/1` to verify.
**Warning signs:** Telemetry events stop appearing in logs. Add a periodic health check that calls `:telemetry.list_handlers([:agent_com])` and logs the count.

### Pitfall 4: Logger.metadata Pollution Across GenServer Calls
**What goes wrong:** When GenServer A calls GenServer B via `GenServer.call`, Logger metadata from process A does NOT propagate to process B. Logs from B lack the request_id that A set.
**Why it happens:** `Logger.metadata` is per-process (stored in process dictionary). Inter-process calls create new execution contexts.
**How to avoid:** For operations that span multiple GenServers (e.g., Scheduler calls TaskQueue.assign_task then sends to AgentFSM), accept this limitation. The request_id correlates log entries within a single process. Cross-process correlation uses task_id and agent_id which are set independently in each GenServer's metadata. This is acceptable for a single-node system.
**Warning signs:** Expecting request_id to appear in logs from GenServers that were called indirectly.

### Pitfall 5: Sidecar stdout JSON Mixed with Non-JSON Output
**What goes wrong:** The sidecar currently uses both `console.log()` (mixed format) and `log()` (JSON to file). Converting stdout to NDJSON requires ensuring NO other output goes to stdout (npm warnings, unhandled promise rejections, etc.).
**Why it happens:** Node.js libraries and runtime errors write directly to stdout/stderr.
**How to avoid:** Redirect all output through the structured log function. Set `process.on('unhandledRejection', ...)` and `process.on('uncaughtException', ...)` to route through the logger. Replace all `console.error()` calls with the structured logger. In ecosystem.config.js (pm2), use `error_file` and `out_file` to separate streams.
**Warning signs:** Lines in sidecar log output that fail JSON.parse().

### Pitfall 6: Test Log Noise Overwhelming Test Output
**What goes wrong:** With structured JSON logging, test output becomes unreadable walls of JSON.
**Why it happens:** Tests trigger real GenServer operations which emit JSON logs.
**How to avoid:** config/test.exs already sets `config :logger, level: :warning`. Keep this. For tests that need to assert log content, use `ExUnit.CaptureLog.capture_log/1` which captures log output into a string for assertion. For log format tests specifically, temporarily configure logger level to capture the level being tested.
**Warning signs:** Test output taking multiple screens of JSON.

## Code Examples

Verified patterns from official sources:

### LoggerJSON Configuration (config.exs)
```elixir
# Source: https://hexdocs.pm/logger_json/readme.html
# Replace existing Logger console config with:

config :logger, :default_handler,
  formatter: LoggerJSON.Formatters.Basic.new(
    metadata: {:all_except, [:conn, :crash_reason]},
    redactors: [{LoggerJSON.Redactors.RedactKeys, keys: ["token", "auth_token", "secret"]}]
  )

# Add file handler for rotating log files
config :logger, [
  {:handler, :file_handler, :logger_std_h, %{
    config: %{
      file: ~c"priv/logs/agent_com.log",
      max_no_bytes: 10_000_000,
      max_no_files: 5,
      compress_on_rotate: true
    },
    formatter: LoggerJSON.Formatters.Basic.new(
      metadata: {:all_except, [:conn, :crash_reason]},
      redactors: [{LoggerJSON.Redactors.RedactKeys, keys: ["token", "auth_token", "secret"]}]
    )
  }}
]
```

### AgentCom.Telemetry Module
```elixir
# Source: https://hexdocs.pm/telemetry/telemetry.html, https://keathley.io/blog/telemetry-conventions.html
defmodule AgentCom.Telemetry do
  @moduledoc """
  Telemetry event definitions and handler attachment for AgentCom.

  ## Event Catalog

  ### Task Lifecycle
  - `[:agent_com, :task, :submit]` - Task submitted to queue
  - `[:agent_com, :task, :assign]` - Task assigned to agent
  - `[:agent_com, :task, :complete]` - Task completed
  - `[:agent_com, :task, :fail]` - Task failed
  - `[:agent_com, :task, :dead_letter]` - Task moved to dead letter
  - `[:agent_com, :task, :reclaim]` - Task reclaimed from agent
  - `[:agent_com, :task, :retry]` - Dead-letter task retried

  ### Agent Lifecycle
  - `[:agent_com, :agent, :connect]` - Agent connected via WebSocket
  - `[:agent_com, :agent, :disconnect]` - Agent disconnected
  - `[:agent_com, :agent, :evict]` - Agent evicted by Reaper

  ### FSM Transitions
  - `[:agent_com, :fsm, :transition]` - Any FSM state change
    measurements: %{duration_ms: integer}
    metadata: %{agent_id, from_state, to_state, task_id}

  ### Scheduler
  - `[:agent_com, :scheduler, :attempt]` - Scheduling loop triggered
  - `[:agent_com, :scheduler, :match]` - Task-agent match found

  ### DETS Operations (span events with :start/:stop/:exception)
  - `[:agent_com, :dets, :backup]` - Backup operation
  - `[:agent_com, :dets, :compaction]` - Compaction operation
  - `[:agent_com, :dets, :restore]` - Restore operation
  """

  require Logger

  @doc "Attach all telemetry handlers. Called from Application.start/2."
  def attach_handlers do
    events = [
      [:agent_com, :task, :submit],
      [:agent_com, :task, :assign],
      [:agent_com, :task, :complete],
      [:agent_com, :task, :fail],
      [:agent_com, :task, :dead_letter],
      [:agent_com, :task, :reclaim],
      [:agent_com, :task, :retry],
      [:agent_com, :agent, :connect],
      [:agent_com, :agent, :disconnect],
      [:agent_com, :agent, :evict],
      [:agent_com, :fsm, :transition],
      [:agent_com, :scheduler, :attempt],
      [:agent_com, :scheduler, :match],
      [:agent_com, :dets, :backup, :start],
      [:agent_com, :dets, :backup, :stop],
      [:agent_com, :dets, :backup, :exception],
      [:agent_com, :dets, :compaction, :start],
      [:agent_com, :dets, :compaction, :stop],
      [:agent_com, :dets, :compaction, :exception],
      [:agent_com, :dets, :restore, :start],
      [:agent_com, :dets, :restore, :stop],
      [:agent_com, :dets, :restore, :exception]
    ]

    :telemetry.attach_many(
      "agent-com-telemetry-logger",
      events,
      &__MODULE__.handle_event/4,
      %{}
    )
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    Logger.info(
      %{
        telemetry_event: Enum.join(event, "."),
        measurements: measurements,
        metadata: metadata
      }
    )
  rescue
    e ->
      Logger.error("Telemetry handler crashed: #{inspect(e)}")
  end
end
```

### GenServer init/1 with Metadata (AgentFSM Example)
```elixir
# Converting existing AgentFSM.init/1:
@impl true
def init(args) do
  agent_id = Keyword.fetch!(args, :agent_id)
  # Set per-process metadata -- appears in all subsequent Logger calls
  Logger.metadata(module: __MODULE__, agent_id: agent_id)

  # ... existing init logic ...

  # Emit telemetry event for agent FSM start
  :telemetry.execute(
    [:agent_com, :agent, :connect],
    %{system_time: System.system_time(:millisecond)},
    %{agent_id: agent_id, initial_state: initial_state}
  )

  Logger.info("started in state :#{initial_state}")
  {:ok, state}
end
```

### FSM Transition with Telemetry Event
```elixir
# Converting the existing transition/2 helper:
defp transition(state, to) do
  from = state.fsm_state
  allowed = Map.get(@valid_transitions, from, [])

  if to in allowed do
    now = System.system_time(:millisecond)
    duration_ms = now - state.last_state_change

    # Emit FSM transition telemetry
    :telemetry.execute(
      [:agent_com, :fsm, :transition],
      %{duration_ms: duration_ms},
      %{agent_id: state.agent_id, from_state: from, to_state: to, task_id: state.current_task_id}
    )

    AgentCom.Presence.update_fsm_state(state.agent_id, to)
    {:ok, %{state | fsm_state: to, last_state_change: now}}
  else
    {:error, {:invalid_transition, from, to}}
  end
end
```

### TaskQueue Submit with Telemetry
```elixir
# In TaskQueue.handle_call({:submit, params}, ...):
# After persisting and broadcasting:
:telemetry.execute(
  [:agent_com, :task, :submit],
  %{queue_depth: length(new_index)},
  %{task_id: task.id, priority: task.priority, submitted_by: task.submitted_by}
)
```

### DETS Backup with Telemetry Span
```elixir
# Wrap existing backup logic:
defp do_backup_table(table_atom, backup_dir) do
  :telemetry.span(
    [:agent_com, :dets, :backup],
    %{table: table_atom},
    fn ->
      result = perform_backup(table_atom, backup_dir)
      case result do
        {:ok, info} -> {result, %{table: table_atom, size: info.size, status: :ok}}
        {:error, info} -> {result, %{table: table_atom, status: :error, reason: info.reason}}
      end
    end
  )
end
```

### Test: Assert JSON Log Output
```elixir
# Source: https://hexdocs.pm/ex_unit/ExUnit.CaptureLog.html
defmodule AgentCom.LogFormatTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  test "log output is valid JSON with required fields" do
    log_output = capture_log(fn ->
      Logger.info("test message", module: AgentCom.TaskQueue, task_id: "task-123")
    end)

    # Each line should be valid JSON
    for line <- String.split(log_output, "\n", trim: true) do
      {:ok, parsed} = Jason.decode(line)
      assert is_binary(parsed["time"])
      assert parsed["severity"] in ["debug", "info", "notice", "warning", "error"]
      assert is_binary(parsed["message"])
    end
  end
end
```

### Sidecar Enhanced Logger
```javascript
// sidecar/lib/log.js
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const LEVELS = { debug: 10, info: 20, notice: 30, warning: 40, error: 50 };
const LEVEL_NAMES = Object.fromEntries(
  Object.entries(LEVELS).map(([k, v]) => [v, k])
);

let _config = null;
let _logLevel = LEVELS.info;
let _logStream = null;
const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB
const MAX_FILES = 5;

function initLogger(config) {
  _config = config;
  if (config.log_level && LEVELS[config.log_level] !== undefined) {
    _logLevel = LEVELS[config.log_level];
  }
  if (config.log_file) {
    _rotateIfNeeded(config.log_file);
    _logStream = fs.createWriteStream(config.log_file, { flags: 'a' });
  }
}

function log(level, event, data = {}, moduleName = 'sidecar/index') {
  const numLevel = typeof level === 'number' ? level : (LEVELS[level] || LEVELS.info);
  if (numLevel < _logLevel) return;

  const entry = {
    time: new Date().toISOString(),
    severity: LEVEL_NAMES[numLevel] || 'info',
    message: event,
    module: moduleName,
    pid: process.pid,
    node: os.hostname(),
    agent_id: _config ? _config.agent_id : 'unknown',
    ...data
  };

  // Redact sensitive fields
  if (entry.token) entry.token = '[REDACTED]';
  if (entry.auth_token) entry.auth_token = '[REDACTED]';

  const line = JSON.stringify(entry) + '\n';

  // NDJSON to stdout
  process.stdout.write(line);

  // File output with rotation
  if (_logStream && _config && _config.log_file) {
    _logStream.write(line);
  }
}

function _rotateIfNeeded(filePath) {
  try {
    const stats = fs.statSync(filePath);
    if (stats.size >= MAX_FILE_SIZE) {
      // Rotate: shift existing files
      for (let i = MAX_FILES - 1; i >= 1; i--) {
        const from = `${filePath}.${i - 1}`;
        const to = `${filePath}.${i}`;
        if (fs.existsSync(from)) fs.renameSync(from, to);
      }
      fs.renameSync(filePath, `${filePath}.0`);
    }
  } catch (e) {
    // File doesn't exist yet, no rotation needed
  }
}

module.exports = { initLogger, log, LEVELS };
```

## Complete Telemetry Event Catalog

| Event Name | Measurements | Metadata | Emitted By |
|------------|-------------|----------|------------|
| `[:agent_com, :task, :submit]` | `%{queue_depth: int}` | `%{task_id, priority, submitted_by}` | TaskQueue |
| `[:agent_com, :task, :assign]` | `%{wait_ms: int}` | `%{task_id, agent_id, generation}` | TaskQueue |
| `[:agent_com, :task, :complete]` | `%{duration_ms: int}` | `%{task_id, agent_id, tokens_used}` | TaskQueue |
| `[:agent_com, :task, :fail]` | `%{retry_count: int}` | `%{task_id, agent_id, error}` | TaskQueue |
| `[:agent_com, :task, :dead_letter]` | `%{retry_count: int}` | `%{task_id, error}` | TaskQueue |
| `[:agent_com, :task, :reclaim]` | `%{}` | `%{task_id, agent_id, reason}` | TaskQueue |
| `[:agent_com, :task, :retry]` | `%{}` | `%{task_id, previous_error}` | TaskQueue |
| `[:agent_com, :agent, :connect]` | `%{system_time: int}` | `%{agent_id, capabilities}` | AgentFSM/Presence |
| `[:agent_com, :agent, :disconnect]` | `%{connected_duration_ms: int}` | `%{agent_id, reason}` | AgentFSM |
| `[:agent_com, :agent, :evict]` | `%{stale_ms: int}` | `%{agent_id}` | Reaper |
| `[:agent_com, :fsm, :transition]` | `%{duration_ms: int}` | `%{agent_id, from_state, to_state, task_id}` | AgentFSM |
| `[:agent_com, :scheduler, :attempt]` | `%{idle_agents: int, queued_tasks: int}` | `%{trigger}` | Scheduler |
| `[:agent_com, :scheduler, :match]` | `%{}` | `%{task_id, agent_id}` | Scheduler |
| `[:agent_com, :dets, :backup, :start]` | auto: `system_time`, `monotonic_time` | `%{table}` | DetsBackup |
| `[:agent_com, :dets, :backup, :stop]` | auto: `duration` | `%{table, size, status}` | DetsBackup |
| `[:agent_com, :dets, :backup, :exception]` | auto: `duration` | `%{table, kind, reason, stacktrace}` | DetsBackup |
| `[:agent_com, :dets, :compaction, :start]` | auto | `%{table, fragmentation_ratio}` | DetsBackup |
| `[:agent_com, :dets, :compaction, :stop]` | auto | `%{table, status, duration_ms}` | DetsBackup |
| `[:agent_com, :dets, :compaction, :exception]` | auto | `%{table, kind, reason, stacktrace}` | DetsBackup |
| `[:agent_com, :dets, :restore, :start]` | auto | `%{table, trigger}` | DetsBackup |
| `[:agent_com, :dets, :restore, :stop]` | auto | `%{table, backup_used, record_count}` | DetsBackup |
| `[:agent_com, :dets, :restore, :exception]` | auto | `%{table, kind, reason, stacktrace}` | DetsBackup |

## Module-by-Module Migration Inventory

| Module | Logger Calls | Key Changes | Telemetry Events |
|--------|-------------|-------------|-----------------|
| agent_fsm.ex | 23 | metadata(agent_id, module) in init, structured messages | fsm:transition, agent:connect, agent:disconnect |
| dets_backup.ex | 14 | metadata(module) in init, wrap ops in telemetry.span | dets:backup, dets:compaction, dets:restore (all spans) |
| dashboard_notifier.ex | 6 | metadata(module) in init | (none -- internal) |
| scheduler.ex | 5 | metadata(module) in init, structured messages | scheduler:attempt, scheduler:match |
| dashboard_state.ex | 4 | metadata(module) in init | (none -- consumer, not emitter) |
| threads.ex | 3 | metadata(module) in init | (none -- DETS corruption only) |
| task_queue.ex | 4 | metadata(module) in init | task:submit, task:assign, task:complete, task:fail, task:dead_letter, task:reclaim, task:retry |
| channels.ex | 2 | metadata(module) in init | (none -- DETS corruption only) |
| config.ex | 2 | metadata(module) in init | (none -- DETS corruption only) |
| mailbox.ex | 2 | metadata(module) in init | (none -- DETS corruption only) |
| message_history.ex | 1 | metadata(module) in init | (none -- DETS corruption only) |
| reaper.ex | 1 | metadata(module) in init | agent:evict |
| endpoint.ex | 1 | request_id generation for HTTP, log-level endpoint | (none -- uses Plug.Logger) |
| socket.ex | 1 | request_id per WS message, metadata(agent_id) on identify | agent:connect (via presence) |

**Total: 69 Logger calls across 14 modules, ~15 telemetry event emission points to add.**

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Logger console backend (Elixir <= 1.14) | OTP :logger handler system (Elixir 1.15+) | Elixir 1.15 (2023) | LoggerJSON 7.x uses new handler system. Configuration uses `:default_handler` not `:console` backend. |
| LoggerJSON 5.x (backend-based) | LoggerJSON 7.x (handler/formatter-based) | 2024 | Breaking change in config format. Use `formatter: LoggerJSON.Formatters.Basic.new(...)` not the old backend config. |
| Jason-only JSON encoding | Built-in JSON module option | Elixir 1.18 (2025) | LoggerJSON can use `JSON` module instead of Jason via `encoder: JSON` config. Reduces dependency coupling but Jason is already present. |
| Anonymous function telemetry handlers | Module function capture handlers | :telemetry 1.x best practice | Use `&Module.handler/4` not `fn ... end` for performance. Anonymous functions are slower and prevent handler identification. |

**Deprecated/outdated:**
- **Logger backends (`:console`):** Replaced by OTP handler system in Elixir 1.15+. Do NOT use `config :logger, :console, ...` style config. Use `config :logger, :default_handler, ...` instead. The current codebase config.exs uses the old format and must be updated.
- **LoggerJSON 5.x/6.x:** Major breaking changes in 7.0. Do not reference old configuration examples.

## Open Questions

1. **Plug.Logger Integration**
   - What we know: `plug Plug.Logger` is active in endpoint.ex. It emits standard Logger calls that LoggerJSON will format as JSON.
   - What's unclear: Whether Plug.Logger's output format (method, path, status, duration) meets the user's metadata requirements, or if a custom Plug that emits structured metadata is needed.
   - Recommendation: Keep Plug.Logger as-is initially. Its output will be JSON-formatted by LoggerJSON. If additional fields are needed (request_id in HTTP logs), add a custom Plug before Plug.Logger that sets Logger.metadata.

2. **Bandit Telemetry Events**
   - What we know: Bandit already emits telemetry events for HTTP requests via `:telemetry`. These are separate from AgentCom's custom events.
   - What's unclear: Whether to attach handlers to Bandit's telemetry events in this phase or defer to Phase 14.
   - Recommendation: Defer. Phase 13 focuses on AgentCom application events. Bandit/HTTP-level telemetry is infrastructure observability and fits Phase 14's metrics aggregation scope.

## Sources

### Primary (HIGH confidence)
- [LoggerJSON v7.0.4 on Hex](https://hexdocs.pm/logger_json/readme.html) - Configuration, formatters, redactors
- [LoggerJSON.Formatters.Basic](https://hexdocs.pm/logger_json/LoggerJSON.Formatters.Basic.html) - Output format: time, severity, message, metadata keys
- [LoggerJSON API docs](https://hexdocs.pm/logger_json/LoggerJSON.html) - Encoder config, shared options, metadata handling
- [:telemetry v1.3.0 on Hex](https://hexdocs.pm/telemetry/telemetry.html) - execute/3, attach/4, span/3 API reference
- [Logger v1.19.5 docs](https://hexdocs.pm/logger/Logger.html) - metadata/1, configure/1, :default_handler, custom formatters
- [OTP logger_std_h](https://www.erlang.org/doc/apps/kernel/logger_std_h.html) - File rotation: max_no_bytes, max_no_files, compress_on_rotate
- Direct codebase analysis - 69 Logger calls across 14 modules, existing config.exs format, sidecar log() function

### Secondary (MEDIUM confidence)
- [Telemetry Conventions (Chris Keathley)](https://keathley.io/blog/telemetry-conventions.html) - Event naming, span pattern, anti-patterns
- [Phoenix Telemetry guide](https://hexdocs.pm/phoenix/telemetry.html) - Telemetry conventions in Phoenix ecosystem
- [Pino Logger Guide (SigNoz)](https://signoz.io/guides/pino-logger/) - Node.js structured logging best practices (used for sidecar guidance)
- [LoggerJSON GitHub releases](https://github.com/Nebo15/logger_json/releases) - Version history, breaking changes

### Tertiary (LOW confidence)
- [Elixir Structured Logging (GenUI)](https://www.genui.com/resources/elixir-learnings-structured-logging) - Logger.metadata patterns (blog post, 2023)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - LoggerJSON and :telemetry are verified via official Hex docs. Versions confirmed. Already-present dependencies verified via `mix deps.tree`.
- Architecture: HIGH - Patterns verified against official Logger, LoggerJSON, and :telemetry documentation. OTP :logger_std_h file rotation confirmed in Erlang stdlib docs. All 14 modules inventoried with exact Logger call counts.
- Pitfalls: HIGH - OTP report formatting verified via LoggerJSON docs. Metadata per-process behavior confirmed in Logger docs. Telemetry handler detachment documented in :telemetry API reference.

**Research date:** 2026-02-12
**Valid until:** 2026-03-14 (30 days -- stable libraries, no expected breaking changes)
