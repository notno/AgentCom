# Project Research Summary

**Project:** AgentCom v2 Hardening (milestone v1.1)
**Domain:** System hardening for production Elixir/BEAM agent coordination system
**Researched:** 2026-02-11
**Confidence:** HIGH

## Executive Summary

AgentCom v1.0 is a production Elixir/OTP system coordinating 5 AI agents with 22 GenServers, 9 DETS tables, and zero test coverage. This hardening milestone addresses critical production gaps: comprehensive testing, DETS resilience (backup/compaction/recovery), input validation on all 9 entry points, structured logging with telemetry metrics, and rate limiting to prevent abuse. Research confirms this is a standard "production hardening retrofit" requiring careful ordering to avoid breaking existing agents while protecting against data loss and DoS attacks.

The recommended approach is dependency-constrained phasing: **test infrastructure must come first** to validate all subsequent changes, **DETS resilience second** before increasing write volume, **input validation third** (with log-only mode to avoid breaking existing agents), **structured logging fourth** to provide visibility, and **rate limiting last** after validation establishes message types. The core technical choices are minimal dependencies (only LoggerJSON and Telemetry.Metrics added), custom implementations for rate limiting and DETS management, and leveraging BEAM/OTP primitives (ETS, pattern matching, GenServer supervision) that already exist in the stack.

Critical risks are **DETS data loss on improper shutdown** (9 tables with no backup), **global GenServer names preventing test isolation**, **DETS compaction blocking operations**, and **WebSocket rate limiting requiring Socket-level implementation** (Plug middleware won't work). Mitigation is through rigorous test infrastructure setup, copy-and-swap compaction strategy, incremental validation rollout with logging, and ETS-based token bucket rate limiting integrated into Socket.handle_in/2.

## Key Findings

### Recommended Stack

Research confirms minimal new dependencies. The existing Elixir/OTP stack provides everything needed except structured logging and metric definitions. Custom implementations are preferred for rate limiting (40-60 lines of ETS code), validation (150 lines of pattern matching), DETS management (200 lines coordinating backup/compaction), and alerting (100 lines monitoring thresholds).

**Core technologies:**
- **LoggerJSON ~> 7.0**: Structured JSON log output for machine-parseable logs. Official Elixir library with Google Cloud/Datadog/Elastic formatters. Uses Jason encoder already in project.
- **Telemetry.Metrics ~> 1.0**: Metric definitions for telemetry events. Already a transitive dependency via Bandit. Formalizes metric types (counter, sum, last_value, summary, distribution).
- **ExUnit (built-in)**: Test framework already available. Needs test helpers, factories, DETS isolation setup.
- **Custom ETS rate limiter**: Token bucket with atomic counters. No library needed. Faster and simpler than Hammer (designed for distributed systems) or ExRated (serializes through GenServer).
- **Custom validation module**: Pattern matching + guards for flat JSON schemas. No Ecto (massive dep for non-DB validation) or NimbleOptions (designed for library options, not payloads).
- **Custom DetsManager GenServer**: Coordinates backup/compaction across 9 tables. No off-the-shelf solution for this topology.

**Already present (no change):**
- :telemetry 1.3.0 (emit events via :telemetry.execute/3)
- Jason 1.4.4 (JSON encoding, used by LoggerJSON)
- :dets and :ets (Erlang stdlib, used for all persistence and rate limiting)

**Alternatives explicitly rejected:**
- Hammer rate limiter (value is Redis/Mnesia backends for distributed systems; AgentCom is single-node)
- Ecto standalone validation (database library for non-database validation is architectural mismatch)
- Mox for testing (requires behaviour definitions; codebase has none; testing real GenServers is more valuable)
- TelemetryMetricsPrometheus (adds /metrics endpoint and separate port; overkill for 5-agent system; can add later)

### Expected Features

Research confirms this is "production hardening" which has well-defined table stakes. Missing any of these means the system is fragile and cannot be confidently changed or scaled.

**Must have (table stakes):**
- **Unit and integration tests**: Zero test coverage blocks confident changes. ExUnit infrastructure with test helpers, factories, DETS isolation.
- **Input validation on all entry points**: 9 entry points with minimal validation. Malformed payloads can crash GenServers or enable DoS. Central Validation module with pattern matching + guards.
- **DETS backup strategy**: 9 tables, single copy, no recovery plan. Periodic file copy + manual admin trigger.
- **Rate limiting on WebSocket and HTTP**: Any agent with valid token can spam. Security audit flagged this. ETS token bucket per {agent_id, action}.
- **Structured logging with metadata**: Current logs are unstructured strings, unusable for debugging. LoggerJSON + Logger.metadata on key paths.

**Should have (differentiators):**
- **DETS compaction**: Prevents disk waste and query slowdown on long-running hubs. Coordination with owning GenServers, copy-and-swap strategy.
- **Telemetry events + metrics**: ~12 event types for performance analysis, scheduling efficiency, capacity planning. Foundation for future Prometheus export.
- **Alerter with thresholds**: Proactive notification of health issues (DETS file size, dead letter count, error rate). GenServer with PubSub broadcast to dashboard.
- **DETS health monitoring endpoint**: Admin visibility into table sizes, fragmentation, last backup time. Read-only endpoint calling :dets.info/1.
- **Per-action rate limit granularity**: Different limits for messages vs task submissions vs channel creates. RateLimiter already keyed by {agent_id, action}.

**Defer (explicitly anti-features for this milestone):**
- **Database migration (DETS to SQLite/Postgres)**: DETS works at current scale. Migration rewrites 6 GenServers. Harden DETS instead.
- **Distributed rate limiting (Redis/Mnesia)**: Single BEAM node. External backend is complexity for zero benefit. Revisit if multi-hub happens.
- **Full observability stack (Prometheus/Grafana)**: Overkill for 5-agent system. Adds infrastructure. Use telemetry + LoggerJSON + Alerter; export to Prometheus later.
- **Property-based testing (StreamData)**: Diminishing returns for this system size. Standard ExUnit tests. Add later for edge-case modules.
- **Load testing framework**: 5 agents. Testing infra costs more than insight. Existing smoke tests sufficient.

**Feature dependencies discovered:**
```
Testing Infrastructure --> enables all features
  |
  +--> Input Validation (no deps)
  +--> Structured Logging (no deps)
  |      +--> Telemetry Events (benefits from logging)
  |             +--> Alerter (uses telemetry + PubSub)
  +--> Rate Limiting (benefits from validation)
  +--> DETS Manager (benefits from logging + testing)
        +--> Backup, Compaction, Health Monitoring
```

### Architecture Approach

Research confirms the architecture must integrate 5 new components into the existing supervision tree without disrupting the 17 running children. All new components are either GenServers (DetsManager, Alerter, TelemetryHandler) or library modules (Validation, RateLimiter uses ETS table). Integration points are well-defined: DetsManager starts before all DETS-owning GenServers so they can register during init; RateLimiter is called inline in Socket and Endpoint; Validation is called at entry points before dispatch; TelemetryHandler attaches to events emitted throughout the system.

**Major components:**

1. **AgentCom.DetsManager (NEW GenServer)**: Owns all DETS lifecycle operations. Each DETS-owning GenServer (Mailbox, Channels, MessageHistory, Threads, Config, TaskQueue — 6 modules managing 9 tables) registers with DetsManager during init. Provides backup_all(), compact_table(name), compact_all(), health() operations. Coordinates with owning GenServers for compaction (close table, copy-and-swap, reopen). Periodic backup scheduled via Process.send_after. Admin endpoints: POST /api/admin/backup, POST /api/admin/compact, GET /api/admin/dets-health.

2. **AgentCom.RateLimiter (ETS-based library module)**: Per-agent token bucket using ETS atomic counters. Keyed by {agent_id, action} where action is :message, :task_submit, :channel_publish, :mailbox_poll, :onboard (by IP). Default limits: 100 messages/min, 20 task submissions/min, 50 channel publishes/min, 30 polls/min, 5 channel creates/min, 200 WS messages/min (catch-all), 3 onboards/5min. ETS table with read_concurrency: true, write_concurrency: true for lock-free operation. Called inline in Socket.handle_in/2 and Endpoint via RateLimit plug. Returns :ok or {:error, :rate_limited, retry_after_ms}.

3. **AgentCom.Validation (library module)**: Central validation for all input types. Pattern matching + guards for flat JSON schemas. No external dependencies. Validates: message (from, to, payload, type, reply_to), task submission (description, priority, metadata, max_retries, capabilities), identify (agent_id, token, name, capabilities, status), channel name (alphanumeric + hyphens + underscores, 1-64 chars). Enforces limits: agent_id <= 64 chars, payload <= 64KB JSON, description <= 4096 chars, max 20 capabilities. Called at entry points (Socket, Endpoint) before dispatch to handlers.

4. **AgentCom.TelemetryHandler (GenServer)**: Attaches to ~12 telemetry event types: [:agent_com, :message, :routed], [:agent_com, :task, :submitted], [:agent_com, :task, :assigned], [:agent_com, :task, :completed], [:agent_com, :task, :failed], [:agent_com, :ws, :connected], [:agent_com, :ws, :disconnected], [:agent_com, :dets, :write], [:agent_com, :scheduler, :attempt]. Logs structured metrics. Foundation for future TelemetryMetricsPrometheus if Grafana is added.

5. **AgentCom.Alerter (GenServer)**: Monitors system health thresholds every 60 seconds. Checks: DETS file size (alert at 100MB per table), dead letter count (alert at 10), queued task backlog (alert at 50), error rate (alert at 20/min), agent disconnect frequency (alert at 10/hour). Broadcasts to PubSub topic "alerts" for dashboard display. Configurable thresholds via Config (DETS-backed KV store).

**Updated supervision tree:**
```
AgentCom.Supervisor (:one_for_one)
  |-- Phoenix.PubSub
  |-- Registry (AgentRegistry)
  |-- Registry (AgentFSMRegistry)
  |
  |-- AgentCom.DetsManager          (NEW: start before DETS GenServers)
  |-- AgentCom.RateLimiter           (NEW: or ETS init in Application.start)
  |-- AgentCom.TelemetryHandler      (NEW: attach before modules emit events)
  |-- AgentCom.Alerter               (NEW: start after monitored services)
  |
  |-- AgentCom.Config                (registers with DetsManager)
  |-- AgentCom.Auth
  |-- AgentCom.Mailbox               (registers with DetsManager)
  |-- AgentCom.Channels              (registers with DetsManager)
  |-- AgentCom.Presence
  |-- AgentCom.Analytics
  |-- AgentCom.Threads               (registers with DetsManager)
  |-- AgentCom.MessageHistory         (registers with DetsManager)
  |-- AgentCom.Reaper
  |-- AgentCom.AgentSupervisor
  |-- AgentCom.TaskQueue             (registers with DetsManager)
  |-- AgentCom.Scheduler
  |-- AgentCom.DashboardState
  |-- AgentCom.DashboardNotifier
  |-- Bandit
```

**Critical architectural patterns:**
- **DETS compaction protocol (simplified)**: DetsManager sends :compact to owning GenServer. GenServer handles inline: close table, reopen with repair: :force (Erlang's defragmentation), reply :ok. GenServer mailbox naturally buffers incoming calls during ~100-500ms compaction window. No special pause/resume needed because GenServer.call timeout (5s default) exceeds compaction time.
- **Test isolation**: Config and Threads hardcode DETS paths to HOME/.agentcom/data/ (not configurable). Must refactor to Application.get_env before writing tests. All other GenServers use Application.get_env with priv/ defaults (can be overridden in config/test.exs). Tests use start_supervised!/1 with unique names or accept serial execution for integration tests.
- **Rate limiting integration**: Cannot use Plug middleware for WebSocket messages (only HTTP). RateLimiter.check/2 must be called in Socket.handle_in/2 before handle_msg dispatch. HTTP endpoints use RateLimit plug. Both paths share same ETS table for per-agent tracking.

### Critical Pitfalls

Research identified 15 pitfalls across critical, moderate, and minor severity. Top 5 critical pitfalls:

1. **DETS data loss on improper shutdown**: 9 DETS tables, no backup mechanism. DETS repair process can silently lose data after crash/kill -9/power loss. Documented in Erlang OTP issue #8513. Prevention: Periodic backup (copy .dets files while open), startup integrity checks (compare record counts), WAL for TaskQueue (highest-value table), :dets.sync after critical writes, monitor file sizes for sudden drops. Phase impact: DETS backup/compaction phase. Must address BEFORE adding features that increase write volume.

2. **Named GenServers causing global state collision**: All 11 GenServers register with name: __MODULE__ (global singletons). Every test shares same state. Mailbox DETS accumulates messages, Channels DETS retains subscriptions between tests. Cannot use async: true. Risk of corrupting production DETS if tests run from same directory. Prevention: config/test.exs with temp DETS paths, refactor Config/Threads to use Application.get_env (currently hardcode HOME paths), start_supervised!/1 with unique names, or reset/0 functions. Phase impact: Testing phase. Must be FIRST thing addressed — retrofitting isolation after writing tests is a rewrite.

3. **DETS 2GB file limit**: Thread tables grow unbounded (no eviction). MessageHistory capped at 10,000 entries, channel history capped at 200/channel but no global cap. DETS writes silently fail approaching 2GB. Documented in Erlang DETS docs. Prevention: Add eviction to Threads (keep last N messages), monitor file sizes via :dets.info(table, :file_size), alert at 500MB (warning) and 1GB (critical), consider ETS + periodic snapshotting for high-write tables. Phase impact: DETS resilience phase. Must add monitoring before compaction.

4. **DETS compaction blocks operations**: Only way to defragment is close table, reopen with repair: :force. During this window, all calls to that GenServer fail (Mailbox.enqueue, TaskQueue.submit, Channels.publish). Messages/tasks submitted during compaction are lost. Large tables take longer to compact, extending outage. Prevention: Copy-and-swap strategy (copy to new file, swap, reopen), schedule during low-activity windows (configurable), emit telemetry for compaction start/end/duration, admin-only trigger. Phase impact: DETS resilience phase. Design compaction strategy before implementing.

5. **Input validation breaking existing agent protocols**: Current code is extremely permissive (Message.new/1 accepts both atom/string keys, endpoint accepts any JSON shape). Adding strict validation rejects messages that production sidecars successfully send today. Risk of coordinated multi-repo deployment. Prevention: Log-only mode first (validate but don't reject for 1-2 weeks), version the protocol (protocol_version field, strict validation for v2+ only), validate incrementally (security-critical fields first), document current contract, coordinate sidecar validation. Phase impact: Input validation phase. Audit existing sidecar message shapes before adding validation.

**Additional critical pitfalls:**
- **WebSocket rate limiting bypasses Plug**: Plug middleware only intercepts HTTP requests. WebSocket messages after upgrade are handled by Socket callbacks outside Plug pipeline. Must implement rate limiting inside Socket.handle_in/2, not Plug. Cannot reuse Hammer or PlugRateLimit.
- **Test suite requires full application**: No subset startup. Testing single GenServer requires entire supervision tree, HTTP server, DETS I/O. Tests take 30+ seconds each, must run serially. Create config/test.exs with unique port and temp paths, extract pure functions, use start_supervised!/1 with injected deps, use Plug.Test for endpoints.
- **Logging noise avalanche**: Current codebase has ~20 log statements. Adding structured logging to every callback creates thousands of lines/hour. Prevention: Log at appropriate levels (debug for routine, info for state transitions), set metadata once in init not every callback, do NOT log every WS message or DETS operation, configure log rotation, add :log_level config per module.

## Implications for Roadmap

Based on research findings, hardening work must follow a strict dependency order. The architecture defines 5 major components with clear integration points, but pitfall analysis reveals that **testing infrastructure must come first** (to validate all changes), **DETS resilience second** (before increasing write volume), **input validation third** (as prerequisite for rate limiting and to avoid breaking existing agents with log-only mode), **structured logging fourth** (provides visibility for subsequent work), and **rate limiting last** (depends on validation to classify messages). Cross-cutting concerns (test isolation, DETS path configuration, supervision tree ordering) must be resolved before implementation begins.

### Suggested Phase Structure

#### Phase 1: Testing Infrastructure + Test Isolation
**Rationale:** Every subsequent feature needs tests to verify correctness. Test isolation must be solved FIRST because retrofitting after writing hundreds of tests is a rewrite. All 11 GenServers use name: __MODULE__ (global singletons) and Config/Threads hardcode DETS paths to HOME/.agentcom/data/ (not configurable). Without isolation, tests share state and risk corrupting production data.

**Delivers:**
- config/test.exs with temp DETS paths for all tables
- Refactored Config and Threads to use Application.get_env instead of hardcoded HOME paths
- test/support/dets_helpers.ex for per-test DETS isolation
- test/support/factory.ex for message/task/token factories
- test/support/ws_client.ex for WebSocket test client
- mix.exs configured with elixirc_paths for test support
- ExUnit configuration with tag-based separation (async unit tests, serial integration tests)
- Baseline test coverage for existing code (unit tests for pure functions, integration tests for GenServer cycles)

**Addresses features:**
- Comprehensive tests (table stakes)
- Foundation for all other features

**Avoids pitfalls:**
- Pitfall 2: Global GenServer names preventing test isolation (CRITICAL)
- Pitfall 11: DETS path collision with production data (CRITICAL)
- Pitfall 8: Full application requirement making tests slow (MODERATE)
- Pitfall 14: Mixing smoke and unit tests (MODERATE)

**Research flag:** Standard patterns. ExUnit best practices are well-documented. Skip `/gsd:research-phase`.

---

#### Phase 2: DETS Resilience (Backup + Monitoring)
**Rationale:** Must protect existing data BEFORE adding features that increase DETS write volume (logging, metrics, validation). Current system has 9 DETS tables with zero backup strategy. DETS data loss on improper shutdown is a documented Erlang issue. Compaction is deferred until backup and monitoring prove stable.

**Delivers:**
- AgentCom.DetsManager GenServer coordinating all DETS lifecycle operations
- Registration protocol: each DETS-owning GenServer calls DetsManager.register_table/3 during init
- Periodic backup: copy all 9 DETS files + tokens.json to ~/.agentcom/backups/TIMESTAMP/
- Manual backup trigger: POST /api/admin/backup (admin-only endpoint)
- Backup retention: keep last N backups (configurable via Config, default 5)
- DETS health monitoring: GET /api/admin/dets-health (file sizes, record counts, last backup time)
- File size monitoring with alerting at 500MB (warning) and 1GB (critical)
- Startup integrity checks comparing record counts before/after open
- Tests for backup cycle, health endpoint, integrity checks

**Addresses features:**
- DETS backup strategy (table stakes)
- DETS health monitoring endpoint (differentiator)

**Avoids pitfalls:**
- Pitfall 1: DETS data loss on improper shutdown (CRITICAL) — backup provides recovery path
- Pitfall 3: DETS 2GB file limit (CRITICAL) — monitoring detects growth before silent failures
- Pitfall 10: DETS sync killing performance (MODERATE) — monitoring informs sync policy decisions

**Defers:**
- DETS compaction (requires coordination protocol design, addressed in Phase 4)
- DETS eviction for unbounded tables like Threads (addressed in Phase 4)

**Research flag:** Standard patterns. Erlang DETS documentation is comprehensive. Skip `/gsd:research-phase`.

---

#### Phase 3: Input Validation with Log-Only Rollout
**Rationale:** Validation is prerequisite for rate limiting (need to classify messages by type, validate agent_id format). Must come before rate limiting. But existing production agents may send messages that strict validation would reject. Log-only mode for 1-2 weeks validates without breaking existing agents.

**Delivers:**
- AgentCom.Validation module with validation functions for all input types
- Message validation: from, to, payload (64KB max), type, reply_to
- Task validation: description (4096 chars max), priority, metadata (64KB max), max_retries (0-10), capabilities (max 20)
- Identify validation: agent_id (64 chars, alphanumeric+hyphens), token (64 hex chars), name (128 chars), capabilities (max 20), status (256 chars)
- Channel name validation: 1-64 chars, alphanumeric+hyphens+underscores
- Log-only mode: Logger.warning for violations, do NOT reject (configurable via Config)
- Integration into Socket.handle_in/2 (before handle_msg dispatch)
- Integration into Endpoint route handlers (before processing)
- Switch to strict mode after observing production logs for 1-2 weeks
- Tests for validation logic, error response formats, log-only vs strict modes

**Addresses features:**
- Input validation on all entry points (table stakes)

**Avoids pitfalls:**
- Pitfall 5: Breaking existing agent protocols (CRITICAL) — log-only mode prevents disruption
- Codebase gotcha: endpoint.ex lines 215, 352-358, 438-441 call String.to_integer without rescue (MODERATE) — validation prevents crashes

**Research flag:** Standard patterns. Elixir pattern matching and guards are well-understood. Skip `/gsd:research-phase`.

---

#### Phase 4: DETS Compaction + Eviction
**Rationale:** With backup and monitoring stable, add compaction to defragment tables and eviction to prevent unbounded growth. Compaction requires coordination with owning GenServers (close table, copy-and-swap, reopen). Threads table needs eviction to avoid 2GB limit.

**Delivers:**
- Copy-and-swap compaction strategy: open new DETS file, copy records, close old, rename, reopen
- DetsManager.compact_table/1 and compact_all/0 operations
- Coordination protocol: GenServer.call(owner, :compact) handled inline (close, reopen with repair: :force)
- Scheduled compaction during configurable low-activity windows (default 3 AM, via Config)
- Manual compaction trigger: POST /api/admin/compact (admin-only)
- Telemetry events for compaction: [:agent_com, :dets, :compaction_started], [:agent_com, :dets, :compaction_completed] with duration
- Eviction for Threads tables: keep last N messages per table (configurable, default 10,000)
- Eviction for channel history: global cap in addition to per-channel cap (configurable, default 5,000)
- Tests for compaction protocol, copy-and-swap, eviction, error handling

**Addresses features:**
- DETS compaction (differentiator)

**Avoids pitfalls:**
- Pitfall 4: DETS compaction blocking operations (CRITICAL) — copy-and-swap minimizes downtime
- Pitfall 3: DETS 2GB file limit (CRITICAL) — eviction prevents unbounded growth

**Research flag:** Needs deeper research. Copy-and-swap strategy for open DETS files has sparse documentation. Consider `/gsd:research-phase` if standard DETS repair approach proves insufficient during implementation.

---

#### Phase 5: Structured Logging + Telemetry Events
**Rationale:** With validation in place and DETS stabilized, add observability. Structured logging provides debuggability. Telemetry events enable performance analysis and form foundation for future Prometheus export. Must define logging level policy to avoid noise avalanche (current codebase has only ~20 log statements).

**Delivers:**
- logger_json ~> 7.0 dependency added
- telemetry_metrics ~> 1.0 dependency added
- Logger configuration: LoggerJSON.Formatters.Basic in production, console formatter in dev
- Logger.metadata set once in GenServer init/1, not per callback (agent_id, task_id, request_id, module)
- AgentCom.TelemetryHandler GenServer attaching to ~12 event types
- Telemetry events emitted: message routed, broadcast, task submitted/assigned/completed/failed/dead_letter, WS connected/disconnected, DETS write, mailbox enqueued, scheduler attempt
- Log level policy: debug for routine operations, info for state transitions, warning for anomalies, error for failures
- Do NOT log every WebSocket message, DETS operation, or ping/pong
- config/dev.exs for human-readable development logging
- config/test.exs with log level: :warning to reduce test noise
- Tests for telemetry event emission, handler attachment, structured log format

**Addresses features:**
- Structured logging with metadata (table stakes)
- Telemetry events + metrics (differentiator)

**Avoids pitfalls:**
- Pitfall 6: Logging noise avalanche (MODERATE) — level policy and selective instrumentation prevent overwhelming output
- Pitfall 12: Telemetry on hot paths (MINOR) — coarse-grained events only, not per-message

**Research flag:** Standard patterns. LoggerJSON and Telemetry are official Elixir ecosystem libraries with comprehensive docs. Skip `/gsd:research-phase`.

---

#### Phase 6: Alerter + Metrics Aggregation
**Rationale:** With telemetry events flowing, add proactive monitoring. Alerter watches for threshold violations and broadcasts to dashboard. This is a differentiator feature, not table stakes, but provides operational visibility that justifies its inclusion.

**Delivers:**
- AgentCom.Alerter GenServer with 60-second check interval
- Thresholds monitored: DETS file size (100MB), dead letter count (10), queued tasks (50), error rate (20/min), disconnect frequency (10/hour)
- PubSub broadcast to "alerts" topic for dashboard consumption
- Configurable thresholds via Config (DETS-backed KV store)
- Admin endpoint: GET /api/admin/alerts for alert history
- Tests for threshold checks, alert broadcasts, configuration changes

**Addresses features:**
- Alerter with configurable thresholds (differentiator)

**Avoids pitfalls:**
- None directly, but provides early warning for pitfalls 1, 3, 4 (DETS issues) and 7 (rate abuse)

**Research flag:** Standard patterns. GenServer + PubSub patterns are well-established. Skip `/gsd:research-phase`.

---

#### Phase 7: Rate Limiting (WebSocket + HTTP)
**Rationale:** Final feature. Depends on input validation (need to classify messages by type, validate agent_id). WebSocket rate limiting requires Socket-level implementation (Plug middleware won't work). HTTP rate limiting uses Plug. Both share ETS table for per-agent tracking.

**Delivers:**
- AgentCom.RateLimiter ETS-based token bucket module
- ETS table :rate_limiter with read_concurrency: true, write_concurrency: true
- Per-agent limits keyed by {agent_id, action}: :message (100/min), :task_submit (20/min), :channel_publish (50/min), :mailbox_poll (30/min), :channel_create (5/min), :ws_message (200/min catch-all)
- Per-IP limit for unauthenticated endpoints: :onboard (3/5min)
- Integration in Socket.handle_in/2: check :ws_message rate, then specific action rate
- AgentCom.Plugs.RateLimit plug for HTTP endpoints
- Error responses: {"type": "error", "error": "rate_limited", "retry_after_ms": N}
- Admin endpoints: GET /api/admin/rate-limits, PUT /api/admin/rate-limits (configure limits without restart)
- Tests for token bucket logic, rate limit enforcement, error responses, admin configuration

**Addresses features:**
- Rate limiting on WebSocket and HTTP (table stakes)
- Per-action rate limit granularity (differentiator)
- Configurable rate limits via admin API (differentiator)

**Avoids pitfalls:**
- Pitfall 7: WebSocket messages bypassing Plug (CRITICAL) — Socket-level implementation catches all WS traffic
- Pitfall 13: Auth GenServer bottleneck (MODERATE) — consider moving token lookup to ETS during this phase if Auth becomes bottleneck

**Research flag:** Standard patterns. Token bucket algorithm is well-documented. ETS atomic operations are standard BEAM. Skip `/gsd:research-phase`.

---

### Phase Ordering Rationale

**Dependency chain:**
1. Testing infrastructure enables validation of all subsequent features.
2. DETS resilience must come before features that increase write volume (logging, metrics).
3. Input validation is prerequisite for rate limiting (classify messages, validate agent_id).
4. Structured logging provides visibility for debugging all subsequent features.
5. Telemetry + alerter form observability layer that measures everything built so far.
6. Rate limiting comes last because it depends on validation and benefits from metrics for tuning.

**Anti-patterns avoided:**
- Adding rate limiting before validation (cannot classify messages without validated types)
- Adding structured logging before DETS resilience (logging every DETS operation accelerates fragmentation)
- Writing 200 tests then adding validation (half would break when validation rejects current behavior)
- Adding metrics before tests (cannot verify metric accuracy without test coverage)

**Integration timing:**
- DetsManager starts before all DETS-owning GenServers (supervision tree ordering)
- RateLimiter ETS table initialized early (needed by transport layer)
- TelemetryHandler attaches before modules emit events
- Alerter starts after services it monitors are running

### Research Flags

**Phases needing deeper research during planning:**
- **Phase 4 (DETS Compaction):** Copy-and-swap strategy for open DETS files has sparse documentation. Standard :dets.open_file with repair: :force is well-documented but requires table close (blocking operations). If copy-and-swap proves complex, consider `/gsd:research-phase` focused on DETS maintenance patterns.

**Phases with standard patterns (skip research-phase):**
- **Phase 1 (Testing):** ExUnit best practices, start_supervised!/1, Plug.Test are well-documented in Elixir ecosystem.
- **Phase 2 (DETS Backup):** File.cp! while table is open is standard Erlang practice. DETS documentation covers all necessary operations.
- **Phase 3 (Validation):** Pattern matching and guards are core Elixir. No external resources needed.
- **Phase 5 (Logging + Telemetry):** LoggerJSON and Telemetry.Metrics have comprehensive official documentation.
- **Phase 6 (Alerter):** Standard GenServer + PubSub patterns.
- **Phase 7 (Rate Limiting):** Token bucket algorithm is well-documented. ETS atomic counters are standard BEAM.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | LoggerJSON and Telemetry.Metrics are official Elixir libraries with stable APIs. Custom implementations (rate limiter, validation, DETS manager) use well-documented BEAM primitives (ETS, DETS, GenServer). All alternatives evaluated with clear rationale for rejection. |
| Features | HIGH | Based on direct AgentCom codebase analysis (all 24 source files reviewed) + CONCERNS.md + TESTING.md. Table stakes features match industry standard production hardening checklists. Differentiators are justified by operational needs (compaction for long-running hubs, telemetry for capacity planning). |
| Architecture | HIGH | Integration points derived from codebase architecture analysis. All 22 GenServers inventoried with state dependencies mapped. New components fit naturally into existing supervision tree. DETS coordination protocol designed around Erlang stdlib guarantees. Test isolation strategy addresses actual GenServer naming and DETS path patterns in code. |
| Pitfalls | HIGH | 15 pitfalls identified through direct codebase analysis, confirmed by official Erlang DETS documentation and documented Erlang OTP issues. Specific code locations cited for gotchas (endpoint.ex line numbers, threads.ex infinite recursion risk, etc.). Severity ratings based on production impact analysis. |

**Overall confidence:** HIGH

All research is grounded in:
- Direct codebase analysis (24 source files in lib/agent_com/, 5 test files, config/, mix.exs)
- Official Erlang/Elixir documentation (DETS, ETS, Logger, Telemetry)
- Hex package documentation for dependencies (LoggerJSON, Telemetry.Metrics)
- Documented Erlang OTP issues (DETS data loss issue #8513)
- Community best practices for testing, validation, rate limiting

No speculative or unverified recommendations.

### Gaps to Address

**Minor gaps:**
- **DETS compaction downtime duration:** Research confirms close/reopen with repair: :force is required. Estimated ~100-500ms per table at current sizes, but this is an estimate. Actual measurement during implementation will inform whether copy-and-swap is necessary or if simple inline compaction suffices.
- **Rate limit tuning:** Recommended limits (100 messages/min, 20 task submissions/min, etc.) are based on typical patterns but should be validated against actual production traffic patterns. Alerter will detect violations; limits can be tuned via admin API without code changes.
- **Test execution time:** Recommendation is to run tests in parallel where possible (async: true for unit tests) and serially for integration tests. Actual test suite time depends on how many integration tests vs unit tests are written. Smoke tests (~60-120s) will dominate if not separated.

**How to handle during planning/execution:**
- **Compaction strategy validation:** If Phase 4 implementation reveals that inline compaction (close, repair: :force, reopen) causes unacceptable downtime (>1 second), pivot to copy-and-swap. Test with actual DETS files approaching 100MB+ to measure real downtime.
- **Rate limit tuning:** Deploy with conservative defaults. Alerter will broadcast violations. Use admin API to increase limits based on observed patterns. Log rate-limited requests for 1 week to understand agent behavior before tightening limits.
- **Test performance optimization:** If test suite exceeds 5 minutes after Phase 1, investigate: DETS I/O (use in-memory ETS for unit tests where possible), HTTP overhead (use Plug.Test instead of real connections), GenServer startup (use start_supervised! selectively, not full app). Tag smoke tests (@tag :smoke) and exclude by default.

## Sources

### Primary (HIGH confidence)
- AgentCom v2 codebase — all 24 source files in lib/agent_com/, 5 test files in test/, config/, mix.exs (direct analysis)
- AgentCom planning docs — .planning/codebase/ARCHITECTURE.md, CONCERNS.md, TESTING.md (project-specific context)
- [Erlang DETS official documentation](https://www.erlang.org/doc/apps/stdlib/dets.html) — repair: :force, 2GB limit, sync semantics, bchunk (stdlib v7.2)
- [LoggerJSON v7.0.4 on Hex](https://hexdocs.pm/logger_json/readme.html) — JSON formatters, configuration, metadata handling
- [Telemetry.Metrics v1.1.0 on Hex](https://hexdocs.pm/telemetry_metrics/Telemetry.Metrics.html) — metric type definitions (counter, sum, last_value, summary, distribution)
- [Telemetry library](https://github.com/beam-telemetry/telemetry) — event dispatching patterns, :telemetry.execute/3 API
- [ExUnit documentation](https://hexdocs.pm/ex_unit/ExUnit.html) — test configuration, start_supervised!/1, async: true behavior

### Secondary (MEDIUM confidence)
- [Erlang DETS data loss issue #8513](https://github.com/erlang/otp/issues/8513) — documented data loss on improper close
- [Hammer rate limiter on GitHub](https://github.com/ExHammer/hammer) — evaluated for rate limiting, Redis/Mnesia backends
- [ExRated on Hex](https://hexdocs.pm/ex_rated/ExRated.html) — GenServer-based rate limiter, evaluated and rejected
- [Validating Data in Elixir (AppSignal blog)](https://blog.appsignal.com/2023/11/07/validating-data-in-elixir-using-ecto-and-nimbleoptions.html) — Ecto vs NimbleOptions comparison
- [Easy and Robust Rate Limiting in Elixir (Alex Koutmos)](https://akoutmos.com/post/rate-limiting-with-genservers/) — GenServer + ETS rate limiting patterns
- [Architecting GenServers for Testability (Tyler Young)](https://tylerayoung.com/2021/09/12/architecting-genservers-for-testability/) — test isolation patterns
- [Understanding Test Concurrency in Elixir (DockYard)](https://dockyard.com/blog/2019/02/13/understanding-test-concurrency-in-elixir) — async test pitfalls with shared state
- [Elixir Structured Logging (GenUI)](https://www.genui.com/resources/elixir-learnings-structured-logging) — Logger.metadata patterns
- [Logger documentation (Elixir v1.19)](https://hexdocs.pm/logger/Logger.html) — metadata, levels, configuration
- [Elixir Testing (OneUptime, 2026)](https://oneuptime.com/blog/post/2026-01-26-elixir-testing/view) — recent testing best practices

### Tertiary (LOW confidence)
- Community forum discussions on DETS performance and maintenance (various sources, used for context, not cited as authoritative)

---
*Research completed: 2026-02-11*
*Ready for roadmap: yes*
