# Architecture Research: Hardening Features Integration

**Domain:** Hardening an existing Elixir/BEAM agent coordination system
**Researched:** 2026-02-11
**Confidence:** HIGH (based on codebase analysis + Erlang/Elixir official docs + ecosystem research)

## Current System Inventory

Before designing integration points, here is every module and its DETS/state dependency.

### GenServers and Their State

| Module | State Type | DETS Tables | PubSub Topics | Notes |
|--------|-----------|-------------|---------------|-------|
| Auth | GenServer (in-memory map) | None (JSON file: `priv/tokens.json`) | None | Token store |
| Mailbox | GenServer + DETS | `priv/mailbox.dets` | None | Per-agent message queue |
| Channels | GenServer + DETS | `priv/channels.dets`, `priv/channel_history.dets` | `channel:*` | Two DETS tables |
| MessageHistory | GenServer + DETS | `priv/message_history.dets` | None | Global audit log |
| Threads | GenServer + DETS | `~/.agentcom/data/thread_messages.dets`, `~/.agentcom/data/thread_replies.dets` | None | Two DETS tables, different path |
| Config | GenServer + DETS | `~/.agentcom/data/config.dets` | None | KV store, different path |
| TaskQueue | GenServer + DETS | `priv/task_queue.dets`, `priv/task_dead_letter.dets` | `tasks` | Two DETS tables |
| Presence | GenServer (in-memory map) | None | `presence` | Volatile |
| Analytics | GenServer + ETS | None (`:agent_analytics` ETS table) | None | Volatile, public ETS |
| Reaper | GenServer (timer-based) | None | None | Sweeps Presence |
| Scheduler | GenServer (stateless) | None | `tasks`, `presence` | Subscribes, no own state |
| DashboardState | GenServer | None | Subscribes to multiple | Aggregates state |
| DashboardNotifier | GenServer | None | None | Push notifications |
| AgentFSM | GenServer (per-agent, under DynamicSupervisor) | None | None | In-memory per-agent |

**Total DETS tables: 8** across 5 modules (Mailbox: 1, Channels: 2, MessageHistory: 1, Threads: 2, Config: 1, TaskQueue: 2... wait, that is 9). Let me recount:

1. `priv/mailbox.dets` (Mailbox)
2. `priv/channels.dets` (Channels)
3. `priv/channel_history.dets` (Channels)
4. `priv/message_history.dets` (MessageHistory)
5. `~/.agentcom/data/thread_messages.dets` (Threads)
6. `~/.agentcom/data/thread_replies.dets` (Threads)
7. `~/.agentcom/data/config.dets` (Config)
8. `priv/task_queue.dets` (TaskQueue)
9. `priv/task_dead_letter.dets` (TaskQueue)

**Total: 9 DETS tables, two path roots (`priv/` and `~/.agentcom/data/`).**

### Entry Points That Need Hardening

| Entry Point | Module | Transport | Auth | Validation |
|-------------|--------|-----------|------|------------|
| `POST /api/message` | Endpoint | HTTP | RequireAuth plug | Minimal (checks `payload` key exists) |
| `POST /api/tasks` | Endpoint | HTTP | RequireAuth plug | Minimal (checks `description` key exists) |
| `POST /api/channels` | Endpoint | HTTP | RequireAuth plug | Minimal (checks `name` key exists) |
| `POST /api/onboard/register` | Endpoint | HTTP | **None** (public) | Checks `agent_id` is non-empty string |
| `POST /api/dashboard/push-subscribe` | Endpoint | HTTP | **None** (public) | **None** |
| WebSocket identify | Socket | WS | Token verification | Checks `agent_id` + `token` |
| WebSocket message | Socket | WS | Identified state check | No payload validation |
| WebSocket task lifecycle | Socket | WS | Identified state check | Checks required keys only |
| All WS channel ops | Socket | WS | Identified state check | Channel name normalized, no size limits |

---

## Feature 1: Comprehensive Tests

### Architecture Decision: ExUnit with Real GenServers, Isolated DETS

Tests should use real GenServer processes and real DETS tables, but in isolated temporary directories to prevent cross-test contamination.

### Integration Points

**New modules:**

| Module | Purpose | Location |
|--------|---------|----------|
| `test/test_helper.exs` | Already exists. Needs enhancement for DETS isolation. |
| `test/support/dets_helpers.ex` | Helper to create temp DETS paths per test | `test/support/` |
| `test/support/factory.ex` | Message, Task, Token factories | `test/support/` |
| `test/support/ws_client.ex` | WebSocket test client wrapping `Fresh` or `:gun` | `test/support/` |

**Existing modules that need modification:**

| Module | Change | Why |
|--------|--------|-----|
| `mix.exs` | Add `:mox` or `:mimic` to test deps; configure `elixirc_paths` for test support | Test infrastructure |
| `config/test.exs` | NEW file. Override DETS paths, port, log level | Test isolation |
| Every DETS GenServer (Mailbox, Channels, MessageHistory, Threads, Config, TaskQueue) | Make DETS path configurable via Application env | Tests need temp paths |

**Critical pattern -- DETS isolation:**

```
# Each DETS-backed GenServer already reads its path from Application config:
#   Application.get_env(:agent_com, :mailbox_path, "priv/mailbox.dets")
#
# In test config:
#   config :agent_com, mailbox_path: "/tmp/agentcom_test_#{System.unique_integer()}/mailbox.dets"
#
# Problem: GenServers are named singletons, so tests cannot run in parallel
# if they touch the same GenServer.
#
# Solution: Use `start_supervised!/1` with unique names in tests that need
# isolated GenServer instances. For integration tests, accept serial execution.
```

**Test topology:**

```
test/
  unit/
    message_test.exs           # Message struct, JSON conversion
    channel_normalize_test.exs  # Channel name normalization
  integration/
    auth_test.exs              # Token generate/verify/revoke cycle
    mailbox_test.exs           # Enqueue/poll/ack/evict cycle
    task_queue_test.exs        # Submit/assign/complete/fail/dead-letter
    router_test.exs            # Message routing: direct, broadcast, offline
    channels_test.exs          # Create/subscribe/publish/history
    scheduler_test.exs         # Event-driven scheduling, capability matching
  system/
    ws_lifecycle_test.exs      # Full WebSocket protocol: identify, message, disconnect
    task_pipeline_test.exs     # Submit task -> schedule -> assign -> complete
  smoke/                       # Already exists
    basic_test.exs
    failure_test.exs
    scale_test.exs
  support/
    dets_helpers.ex
    factory.ex
    ws_client.ex
```

### Data Flow Impact

No runtime data flow changes. Tests exercise existing data flows.

---

## Feature 2: DETS Backup / Compaction / Recovery

### Architecture Decision: New GenServer `AgentCom.DetsManager`

A single new GenServer that owns all DETS lifecycle operations: backup, compaction, repair, and health monitoring. Each DETS-owning GenServer continues to own its own table for reads/writes, but `DetsManager` coordinates maintenance operations.

**Why a separate GenServer instead of adding to each module:**
- Compaction requires closing and reopening a DETS table, which means the owning GenServer must pause.
- Backup requires copying files atomically, which is a cross-cutting concern.
- Health checks (file size, fragmentation estimate) are a single responsibility.
- A dedicated process avoids polluting each GenServer with maintenance code.

### Component Design

```
AgentCom.DetsManager (NEW GenServer)
  |
  |-- register_table(name, path, owning_pid)   # Called by each GenServer in init
  |-- backup_all()                             # Copies all DETS files to backup dir
  |-- compact_table(name)                      # Close, reopen with repair: :force
  |-- compact_all()                            # Compact every registered table
  |-- health()                                 # File sizes, last backup time
  |
  Coordinates with owning GenServers via:
  |-- GenServer.call(owning_pid, :pause_for_compaction)
  |-- GenServer.call(owning_pid, :resume_after_compaction)
```

### Integration Points

**New modules:**

| Module | Purpose |
|--------|---------|
| `lib/agent_com/dets_manager.ex` | GenServer for DETS lifecycle operations |

**Existing modules that need modification:**

| Module | Change | Why |
|--------|--------|-----|
| `application.ex` | Add `AgentCom.DetsManager` to children list (before DETS-owning GenServers) | Supervisor tree |
| `mailbox.ex` | In `init/1`: register table with DetsManager. Add `handle_call(:pause_for_compaction)` and `handle_call(:resume_after_compaction)` | Compaction coordination |
| `channels.ex` | Same pattern as mailbox (two tables to register) | Compaction coordination |
| `message_history.ex` | Same pattern as mailbox | Compaction coordination |
| `threads.ex` | Same pattern (two tables) | Compaction coordination |
| `config.ex` | Same pattern | Compaction coordination |
| `task_queue.ex` | Same pattern (two tables) | Compaction coordination |
| `endpoint.ex` | Add admin endpoints: `POST /api/admin/backup`, `POST /api/admin/compact`, `GET /api/admin/dets-health` | Operational visibility |

### Compaction Protocol (Critical Design)

DETS compaction requires closing and reopening the file with `repair: :force`. During this window, the owning GenServer cannot serve requests. The protocol:

```
1. DetsManager sends :pause_for_compaction to owning GenServer
2. Owning GenServer:
   a. Stops accepting new calls (queues them or returns {:error, :maintenance})
   b. Calls :dets.close(table)
   c. Replies :paused
3. DetsManager:
   a. Opens the table with repair: :force (this rewrites the file, defragmenting)
   b. Closes the table
   c. Sends :resume_after_compaction to owning GenServer
4. Owning GenServer:
   a. Reopens the table normally
   b. Resumes serving requests
   c. Replies :resumed
```

**Alternative (simpler, preferred for this system):** Since the system has low throughput (5 agents), compaction can use a simpler approach:

```
1. DetsManager sends :compact to owning GenServer
2. Owning GenServer handles it inline:
   a. :dets.close(table)
   b. :dets.open_file(table, [file: path, repair: :force, ...])
   c. Replies :ok
3. During this ~100-500ms window, GenServer mailbox buffers incoming calls
   (OTP handles this naturally -- calls just wait)
```

This simpler approach works because GenServer.call has a default 5-second timeout, and compaction of our small tables takes milliseconds. No special pause/resume protocol needed.

### Backup Strategy

```
Backup destination: ~/.agentcom/backups/YYYY-MM-DD_HH-MM-SS/
  mailbox.dets
  channels.dets
  channel_history.dets
  message_history.dets
  thread_messages.dets
  thread_replies.dets
  config.dets
  task_queue.dets
  task_dead_letter.dets
  tokens.json

Process:
1. :dets.sync(table) on all tables
2. File.cp!(source, dest) for each file
3. Retain last N backups (configurable via Config, default 5)
4. Scheduled: daily via Process.send_after, configurable
5. On-demand: via admin endpoint
```

### Recovery Strategy

```
Recovery from backup:
1. Stop all DETS-owning GenServers (or entire app)
2. Copy backup files to their original locations
3. Restart (DETS auto-repair on open handles minor inconsistencies)

Recovery from corruption:
1. :dets.open_file with repair: :force
2. If repair fails: restore from latest backup
3. If no backup: :dets.open_file creates fresh empty table (data loss)
```

### Data Flow

```
Periodic timer (DetsManager)
  --> :dets.sync on all tables
  --> File.cp! to backup dir
  --> Prune old backups

Admin request: POST /api/admin/compact
  --> DetsManager.compact_all()
  --> For each registered table:
      --> GenServer.call(owner, :compact)
      --> Owner: close, reopen with repair: :force
  --> Return results
```

---

## Feature 3: Input Validation

### Architecture Decision: Validation Module with Schemaless Changesets

Use a dedicated `AgentCom.Validation` module that defines validation rules for each message type. No external library needed -- Elixir pattern matching + guard clauses are sufficient for this system's needs. Ecto changesets are overkill (no database, no forms). A simple module with explicit validation functions is more transparent.

### Integration Points

**New modules:**

| Module | Purpose |
|--------|---------|
| `lib/agent_com/validation.ex` | Central validation functions for all input types |

**Existing modules that need modification:**

| Module | Change | Why |
|--------|--------|-----|
| `socket.ex` | Call `Validation.validate_ws_message/1` before `handle_msg/2` dispatch | Reject invalid WS frames early |
| `endpoint.ex` | Call `Validation.validate_*` functions in each POST handler before processing | Reject invalid HTTP input early |
| `message.ex` | Add validation to `new/1` or add `validate/1` function | Ensure message structs are always valid |

### Validation Rules

```elixir
defmodule AgentCom.Validation do
  @max_agent_id_length 64
  @max_payload_size 65_536          # 64KB
  @max_description_length 4096
  @max_channel_name_length 64
  @allowed_message_types ~w(chat request response status ping task system)
  @allowed_priorities ~w(urgent high normal low)
  @max_capabilities 20

  def validate_message(params) do
    # Required: from (string, <= 64 chars)
    # Required: payload (map, JSON-encoded size <= 64KB)
    # Optional: to (string or nil, <= 64 chars)
    # Optional: type (one of @allowed_message_types, default "chat")
    # Optional: reply_to (string or nil, <= 64 chars)
  end

  def validate_task_submission(params) do
    # Required: description (string, 1-4096 chars)
    # Optional: priority (one of @allowed_priorities)
    # Optional: metadata (map, JSON size <= 64KB)
    # Optional: max_retries (integer, 0-10)
    # Optional: needed_capabilities (list of strings, max 20 items)
  end

  def validate_identify(params) do
    # Required: agent_id (string, 1-64 chars, alphanumeric + hyphens)
    # Required: token (string, exactly 64 hex chars)
    # Optional: name (string, <= 128 chars)
    # Optional: capabilities (list of strings/maps, max 20 items)
    # Optional: status (string, <= 256 chars)
  end

  def validate_channel_name(name) do
    # String, 1-64 chars after normalization
    # Alphanumeric + hyphens + underscores only
  end
end
```

### Data Flow Change

```
BEFORE:
  WS frame --> Jason.decode --> handle_msg (dispatches based on "type" key)
  HTTP body --> Plug.Parsers --> route handler (checks one required field)

AFTER:
  WS frame --> Jason.decode --> Validation.validate_ws_message
    |                                |
    |--> {:error, reasons} --------> reply_error("validation_failed", reasons)
    |--> {:ok, validated} ---------> handle_msg (unchanged)

  HTTP body --> Plug.Parsers --> route handler --> Validation.validate_*
    |                                                  |
    |--> {:error, reasons} --------------------------> send_json(400, %{errors: reasons})
    |--> {:ok, validated} ---------------------------> process (unchanged)
```

---

## Feature 4: Structured Logging + Metrics + Alerting

### Architecture Decision: Logger JSON Formatter + Telemetry Events + Custom Reporter

Three layers:

1. **Structured Logging:** Replace console formatter with `LoggerJSON.Formatters.Basic` for machine-parseable output. Add Logger metadata (agent_id, request_id, task_id) to all operations.

2. **Telemetry Events:** Emit `:telemetry.execute/3` events at key points (message routed, task assigned, DETS write, WS connect/disconnect). Attach handler that logs metrics.

3. **Alerting:** A lightweight `AgentCom.Alerter` GenServer that watches for threshold violations (error rate, DETS size, queue depth) and broadcasts PubSub alerts to the dashboard.

### Integration Points

**New modules:**

| Module | Purpose |
|--------|---------|
| `lib/agent_com/telemetry_handler.ex` | Attaches to `:telemetry` events, logs metrics, updates counters |
| `lib/agent_com/alerter.ex` | GenServer that checks thresholds and broadcasts alerts |

**Existing modules that need modification:**

| Module | Change | Why |
|--------|--------|-----|
| `mix.exs` | Add `{:logger_json, "~> 7.0"}` and `{:telemetry_metrics, "~> 1.0"}` | Dependencies |
| `config/config.exs` | Configure Logger to use `LoggerJSON.Formatters.Basic`, set metadata keys | Structured output |
| `config/dev.exs` | NEW: Keep console formatter for development readability | DX |
| `application.ex` | Add `AgentCom.TelemetryHandler` and `AgentCom.Alerter` to children | Supervisor tree |
| `router.ex` | Add `:telemetry.execute([:agent_com, :message, :routed], ...)` | Track message routing |
| `task_queue.ex` | Add telemetry events for submit, assign, complete, fail, dead_letter | Track task lifecycle |
| `socket.ex` | Add `Logger.metadata(agent_id: agent_id)` after identify; telemetry for connect/disconnect | Per-connection context |
| `endpoint.ex` | Add `Logger.metadata(request_id: ...)` in a plug; telemetry for HTTP requests | Per-request context |
| `mailbox.ex` | Telemetry event for enqueue, poll, ack | Track mailbox usage |
| `scheduler.ex` | Telemetry event for scheduling attempt, match found/not found, assignment | Track scheduler efficiency |

### Telemetry Event Taxonomy

```
[:agent_com, :message, :routed]        measurements: %{count: 1}  metadata: %{from:, to:, type:}
[:agent_com, :message, :broadcast]     measurements: %{count: 1}  metadata: %{from:}
[:agent_com, :task, :submitted]        measurements: %{count: 1}  metadata: %{task_id:, priority:}
[:agent_com, :task, :assigned]         measurements: %{count: 1}  metadata: %{task_id:, agent_id:}
[:agent_com, :task, :completed]        measurements: %{count: 1, tokens_used: n, duration_ms: n}
[:agent_com, :task, :failed]           measurements: %{count: 1}  metadata: %{task_id:, error:}
[:agent_com, :task, :dead_letter]      measurements: %{count: 1}  metadata: %{task_id:}
[:agent_com, :ws, :connected]          measurements: %{count: 1}  metadata: %{agent_id:}
[:agent_com, :ws, :disconnected]       measurements: %{count: 1, duration_ms: n}
[:agent_com, :dets, :write]            measurements: %{duration_ms: n}  metadata: %{table:}
[:agent_com, :mailbox, :enqueued]      measurements: %{count: 1}  metadata: %{agent_id:}
[:agent_com, :scheduler, :attempt]     measurements: %{count: 1, matches: n, idle_agents: n, queued_tasks: n}
```

### Alerter Thresholds

```elixir
defmodule AgentCom.Alerter do
  # Check every 60 seconds
  @check_interval_ms 60_000

  @thresholds %{
    dets_file_size_bytes: 100_000_000,   # 100MB per table
    dead_letter_count: 10,                # More than 10 dead-letter tasks
    queued_tasks_count: 50,               # More than 50 queued tasks (backlog)
    error_rate_per_minute: 20,            # More than 20 errors/minute
    agent_disconnects_per_hour: 10        # Frequent disconnects suggest instability
  }
end
```

Alerts broadcast to PubSub topic `"alerts"` and are picked up by the Dashboard for display.

### Logger Configuration

```elixir
# config/config.exs (production-oriented)
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic, metadata: :all}

# config/dev.exs (human-readable)
config :logger, :console,
  format: "$time [$level] $metadata $message\n",
  metadata: [:agent_id, :task_id, :request_id]
```

---

## Feature 5: Rate Limiting

### Architecture Decision: Custom ETS-Based Token Bucket (No External Dependency)

Hammer is the standard Elixir rate limiter, but for this system, a custom implementation is simpler and avoids a dependency for what amounts to 40 lines of code. The system already uses ETS extensively (Analytics module). A per-agent token bucket in ETS with atomic counter operations provides lock-free rate limiting.

**Why not Hammer:** Hammer's value is pluggable backends (Redis, Mnesia) for distributed rate limiting. AgentCom runs on a single BEAM node. A custom ETS bucket is faster, has zero dependencies, and is trivially testable.

### Component Design

```elixir
defmodule AgentCom.RateLimiter do
  @moduledoc """
  Per-agent rate limiting using ETS token bucket.

  Buckets are keyed by {agent_id, action} where action is
  :message, :task_submit, :channel_publish, :mailbox_poll, etc.
  """

  @table :rate_limiter
  @default_limits %{
    message:         {100, 60_000},    # 100 messages per minute
    task_submit:     {20, 60_000},     # 20 task submissions per minute
    channel_publish: {50, 60_000},     # 50 channel publishes per minute
    mailbox_poll:    {30, 60_000},     # 30 polls per minute
    channel_create:  {5, 60_000},      # 5 channel creates per minute
    ws_message:      {200, 60_000},    # 200 WS messages per minute (catch-all)
    onboard:         {3, 300_000}      # 3 registrations per 5 minutes (by IP)
  }

  def init do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
  end

  @doc "Check if action is allowed. Returns :ok or {:error, :rate_limited, retry_after_ms}"
  def check(agent_id, action) do
    {limit, window_ms} = Map.get(@default_limits, action, {100, 60_000})
    key = {agent_id, action}
    now = System.system_time(:millisecond)
    # ... token bucket logic using :ets.update_counter with atomics
  end
end
```

### Integration Points

**New modules:**

| Module | Purpose |
|--------|---------|
| `lib/agent_com/rate_limiter.ex` | ETS-based per-agent token bucket |
| `lib/agent_com/plugs/rate_limit.ex` | Plug middleware for HTTP rate limiting |

**Existing modules that need modification:**

| Module | Change | Why |
|--------|--------|-----|
| `application.ex` | Initialize RateLimiter ETS table (call `RateLimiter.init()` or add as child) | System startup |
| `socket.ex` | Call `RateLimiter.check(agent_id, :ws_message)` at top of `handle_msg` | WS rate limiting |
| `socket.ex` | Call specific rate limits per message type (`:message`, `:channel_publish`, `:task_submit`) | Per-action granularity |
| `endpoint.ex` | Add `RateLimit` plug to rate-limited routes | HTTP rate limiting |
| `endpoint.ex` | Rate limit unauthenticated endpoints by IP (onboard/register) | Abuse prevention |

### Data Flow Change

```
BEFORE:
  WS frame --> decode --> handle_msg --> process

AFTER:
  WS frame --> decode --> RateLimiter.check(agent_id, :ws_message)
    |                         |
    |--> {:error, :rate_limited, retry_ms} --> reply_error("rate_limited", state)
    |--> :ok --> RateLimiter.check(agent_id, specific_action)
        |              |
        |--> rate_limited --> reply_error
        |--> :ok --> handle_msg --> process

HTTP:
  Request --> RequireAuth --> RateLimit plug --> route handler
                                |
                                |--> 429 Too Many Requests
```

---

## Recommended Architecture (Integrated View)

### Updated Supervision Tree

```
AgentCom.Supervisor (:one_for_one)
  |
  |-- Phoenix.PubSub (name: AgentCom.PubSub)
  |-- Registry (name: AgentCom.AgentRegistry)
  |-- Registry (name: AgentCom.AgentFSMRegistry)
  |
  |-- AgentCom.DetsManager          # NEW: DETS lifecycle (backup/compact/health)
  |-- AgentCom.RateLimiter          # NEW: ETS rate limiter (or init in Application.start)
  |-- AgentCom.TelemetryHandler     # NEW: Telemetry event handlers
  |-- AgentCom.Alerter              # NEW: Threshold monitoring + alerts
  |
  |-- AgentCom.Config               # existing (registers with DetsManager)
  |-- AgentCom.Auth                 # existing
  |-- AgentCom.Mailbox              # existing (registers with DetsManager)
  |-- AgentCom.Channels             # existing (registers with DetsManager)
  |-- AgentCom.Presence             # existing
  |-- AgentCom.Analytics            # existing
  |-- AgentCom.Threads              # existing (registers with DetsManager)
  |-- AgentCom.MessageHistory        # existing (registers with DetsManager)
  |-- AgentCom.Reaper               # existing
  |-- AgentCom.AgentSupervisor      # existing (DynamicSupervisor)
  |-- AgentCom.TaskQueue            # existing (registers with DetsManager)
  |-- AgentCom.Scheduler            # existing
  |-- AgentCom.DashboardState       # existing
  |-- AgentCom.DashboardNotifier    # existing
  |-- Bandit                        # existing (HTTP + WS server)
```

**Ordering rationale:**
- `DetsManager` starts before all DETS-owning GenServers so they can register during init
- `RateLimiter` starts early because transport layer needs it
- `TelemetryHandler` starts before modules that emit events
- `Alerter` starts after services it monitors are running

### Component Boundaries

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| **DetsManager** (NEW) | DETS backup, compaction, repair, health monitoring | All DETS-owning GenServers, Endpoint (admin API) |
| **RateLimiter** (NEW) | Per-agent and per-IP rate limiting via ETS | Socket, Endpoint (checked inline) |
| **Validation** (NEW) | Input validation and sanitization | Socket, Endpoint (called as library) |
| **TelemetryHandler** (NEW) | Attaches to telemetry events, logs structured metrics | All modules (receives events) |
| **Alerter** (NEW) | Monitors thresholds, broadcasts alerts | PubSub, DashboardState |

### Updated Data Flow (Message Send via WebSocket)

```
Agent (via sidecar)
  |
  | WebSocket frame: {"type": "message", "to": "agent-b", "payload": {"text": "hello"}}
  v
Socket.handle_in/2
  |
  | 1. Jason.decode(text)
  | 2. RateLimiter.check(agent_id, :ws_message)       <-- NEW
  | 3. RateLimiter.check(agent_id, :message)           <-- NEW
  | 4. Validation.validate_message(params)              <-- NEW
  v
Socket.handle_msg/2
  |
  | 5. Message.new(validated_params)
  | 6. Router.route(message)
  |     |
  |     | 6a. :telemetry.execute([:agent_com, :message, :routed], ...)  <-- NEW
  |     | 6b. MessageHistory.store(msg)
  |     | 6c. Registry.lookup -> send to recipient
  v
reply: {"type": "message_sent", "id": "abc123"}
  |
  | 7. Logger.info("Message routed", agent_id: from, to: to)  <-- ENHANCED
```

### Updated Data Flow (Admin Backup)

```
Admin
  |
  | POST /api/admin/backup
  v
Endpoint
  |
  | 1. RequireAuth (verify token)
  | 2. Check admin agent list
  v
DetsManager.backup_all()
  |
  | 3. For each registered table:
  |     a. :dets.sync(table)
  | 4. File.mkdir_p!(backup_dir)
  | 5. For each registered table:
  |     a. File.cp!(source, dest)
  | 6. Copy priv/tokens.json
  | 7. Prune old backups
  v
Response: {"status": "ok", "backup_path": "...", "tables": 9, "size_bytes": ...}
```

---

## New HTTP Endpoints Summary

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | `/api/admin/backup` | Admin | Trigger manual backup |
| POST | `/api/admin/compact` | Admin | Trigger DETS compaction |
| POST | `/api/admin/compact/:table` | Admin | Compact specific table |
| GET | `/api/admin/dets-health` | Admin | DETS file sizes, fragmentation estimate, last backup |
| GET | `/api/admin/rate-limits` | Auth | Current rate limit configuration |
| PUT | `/api/admin/rate-limits` | Admin | Update rate limit thresholds |
| GET | `/api/admin/alerts` | Auth | Recent alert history |

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Validation in Every Handler

**What:** Duplicating validation logic in each `handle_msg` clause and each endpoint route.

**Why bad:** Inconsistent rules across handlers. Easy to miss a path. Validation changes require touching 20+ places.

**Instead:** Centralize all validation in `AgentCom.Validation`. Socket and Endpoint call validation once at the entry point, before dispatch. Individual handlers receive already-validated data.

### Anti-Pattern 2: DETS Compaction Under Load

**What:** Running compaction on a timer without checking system state.

**Why bad:** Compaction blocks the owning GenServer. If the system is under load (tasks being assigned, messages flowing), compaction adds latency to critical operations.

**Instead:** Run compaction during quiet periods (configurable schedule, default 3 AM). Allow manual trigger via admin endpoint. Log compaction duration for monitoring.

### Anti-Pattern 3: Rate Limiting in a GenServer

**What:** Implementing rate limiting as a GenServer that serializes all rate checks.

**Why bad:** Rate checks happen on every message, every request. A GenServer serializes all checks through a single process. At 5 agents this is fine; the pattern is fundamentally wrong and will bite if the system grows.

**Instead:** Use ETS with `:read_concurrency` and `:write_concurrency` options. `:ets.update_counter/3` is atomic and does not require process serialization. The RateLimiter module is a library, not a process (or a thin GenServer that only owns the ETS table creation, not the check logic).

### Anti-Pattern 4: Logging Everything as Unstructured Strings

**What:** `Logger.info("Message from #{from} to #{to} at #{timestamp}")`.

**Why bad:** Cannot be parsed by log aggregators. Cannot filter by field. Cannot build dashboards from logs.

**Instead:** `Logger.info("Message routed", agent_id: from, to: to, type: type)` with LoggerJSON formatter producing `{"msg": "Message routed", "agent_id": "alice", "to": "bob", "type": "chat"}`.

### Anti-Pattern 5: Testing Through the HTTP Layer Only

**What:** Writing all tests as HTTP request -> response assertions.

**Why bad:** Slow (starts HTTP server per test), fragile (depends on JSON encoding), does not isolate GenServer logic from transport concerns.

**Instead:** Unit test GenServer functions directly (`Mailbox.enqueue`, `TaskQueue.submit`, etc.). Integration test the full pipeline only for critical paths. Reserve HTTP-level tests for endpoint-specific concerns (auth, routing, error responses).

---

## Build Order (Dependency-Constrained)

Features have the following dependency relationships:

```
1. Input Validation          # No dependencies on other features
2. Structured Logging        # No dependencies (enhances visibility for everything)
3. Rate Limiting             # Benefits from validation (validate before rate-check is wasteful)
4. DETS Backup/Compaction    # Benefits from logging (log all operations)
5. Comprehensive Tests       # Benefits from ALL above (tests validate all new behavior)
   But testing infrastructure should be set up FIRST to validate each feature as built.
```

**Recommended build order:**

```
Phase 1: Testing Infrastructure + Input Validation
  - Set up ExUnit, test helpers, factories
  - Build Validation module
  - Write tests for validation
  - Integrate validation into Socket and Endpoint
  - Write tests for existing code (baseline coverage)

Phase 2: Structured Logging + Metrics
  - Add logger_json, telemetry_metrics deps
  - Configure structured logging
  - Add telemetry events to key modules
  - Build TelemetryHandler
  - Write tests for telemetry events

Phase 3: Rate Limiting
  - Build RateLimiter (ETS-based)
  - Build RateLimit plug
  - Integrate into Socket and Endpoint
  - Write tests for rate limiting

Phase 4: DETS Backup/Compaction/Recovery + Alerter
  - Build DetsManager
  - Modify all DETS-owning GenServers to register
  - Add compaction protocol
  - Build Alerter
  - Add admin endpoints
  - Write tests for backup, compaction, recovery scenarios

Phase 5: Full Integration Tests + Hardening Verification
  - System-level tests exercising all hardening features together
  - Load testing with rate limits active
  - Failure injection: corrupt DETS, trigger recovery
  - Verify logging captures all expected events
```

**Rationale:** Testing infrastructure must come first because each subsequent feature should be tested as it is built. Validation comes first because it is the simplest feature and provides the most immediate safety. Logging comes next because it provides visibility for debugging everything that follows. Rate limiting depends on validation (no point rate-limiting invalid requests). DETS management comes last because it is the most complex and benefits from logging and testing being already in place.

---

## Scalability Considerations

| Concern | Current (5 agents) | At 20 agents | At 100 agents |
|---------|---------------------|--------------|---------------|
| Rate limit checks | ~1000/min, ETS handles trivially | ~4000/min, ETS handles trivially | ~20000/min, ETS handles trivially |
| DETS backup size | ~1MB total | ~5MB total, backup takes <1s | ~50MB total, backup takes <5s |
| DETS compaction time | ~50ms per table | ~200ms per table | ~2s per table (blocks GenServer) |
| Log volume | ~100 lines/min | ~500 lines/min | ~2000 lines/min, need log rotation |
| Telemetry events | ~500/min | ~2000/min | ~10000/min, telemetry handles fine |
| Test suite time | ~5s | ~5s (tests are constant) | ~5s (tests are constant) |

No architectural changes needed at any realistic scale for this system.

---

## Sources

- [Erlang DETS official documentation -- stdlib v7.2](https://www.erlang.org/doc/apps/stdlib/dets.html) -- repair: :force for defragmentation, bchunk for table copying (HIGH confidence)
- [LoggerJSON v7.0.4 -- Hex](https://hexdocs.pm/logger_json/readme.html) -- Structured JSON logging for Elixir (HIGH confidence)
- [Telemetry.Metrics v1.1.0 -- Hex](https://hexdocs.pm/telemetry_metrics/Telemetry.Metrics.html) -- Metric definitions for telemetry events (HIGH confidence)
- [Hammer -- Elixir rate limiter](https://github.com/ExHammer/hammer) -- Pluggable rate limiter, evaluated but custom ETS preferred (MEDIUM confidence)
- [ExRated -- OTP GenServer rate limiter](https://github.com/grempe/ex_rated) -- Token bucket implementation reference (MEDIUM confidence)
- [Easy and Robust Rate Limiting in Elixir](https://akoutmos.com/post/rate-limiting-with-genservers/) -- GenServer + ETS rate limiting patterns (MEDIUM confidence)
- [Validating Data in Elixir: Ecto and NimbleOptions](https://blog.appsignal.com/2023/11/07/validating-data-in-elixir-using-ecto-and-nimbleoptions.html) -- Schemaless changeset pattern (MEDIUM confidence)
- [Elixir Processes: Testing](https://samuelmullen.com/articles/elixir-processes-testing) -- GenServer testing patterns with start_supervised (MEDIUM confidence)
- [Testing GenServers in Elixir](https://www.freshcodeit.com/blog/how-to-design-and-test-elixir-genservers) -- Test isolation patterns (MEDIUM confidence)
- [Telemetry overview -- beam-telemetry](https://github.com/beam-telemetry/telemetry) -- Dynamic event dispatching library (HIGH confidence)
- [Elixir Telemetry: Metrics and Reporters](https://samuelmullen.com/articles/elixir-telemetry-metrics-and-reporters) -- Custom reporter patterns (MEDIUM confidence)
- AgentCom v2 codebase -- all files in `lib/agent_com/`, `config/`, `test/`, `mix.exs` (HIGH confidence, primary source)
- AgentCom codebase analysis -- `.planning/codebase/ARCHITECTURE.md`, `CONCERNS.md`, `TESTING.md` (HIGH confidence)

---

*Architecture research for: Hardening features integration into existing OTP system*
*Researched: 2026-02-11*
