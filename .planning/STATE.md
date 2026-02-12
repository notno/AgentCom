# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-11)

**Core value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.
**Current focus:** v1.1 Hardening -- MILESTONE COMPLETE

## Current Position

Phase: 16-operations-docs
Plan: 3 of 3 complete
Status: Milestone Complete
Last activity: 2026-02-12 -- Phase 16 complete. v1.1 Hardening milestone complete (8 phases, 31 plans).

## Performance Metrics

**Velocity:**
- Total plans completed: 31 (v1.1)
- Average duration: 5 min
- Total execution time: 2.58 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 09-testing | 7 | 33 min | 5 min |
| 10-dets-backup | 3 | 8 min | 3 min |
| 11-dets-compaction | 3 | 15 min | 5 min |
| 12-input-validation | 3 | 13 min | 4 min |
| 13-structured-logging | 4 | 38 min | 10 min |
| 14-metrics-alerting | 4 | 17 min | 4 min |
| 15-rate-limiting | 4 | 25 min | 6 min |
| 16-operations-docs | 3 | 13 min | 4 min |

**Recent Trend:**
- Last 5 plans: 16-03 (5 min), 15-04 (6 min), 16-02 (3 min), 16-01 (5 min), 15-03 (5 min)
- Trend: --

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: Test infrastructure first -- unblocks all v1.1 phases
- [Roadmap]: DETS backup before compaction -- protect data before risky operations
- [Roadmap]: Input validation before rate limiting -- must classify messages before applying per-action limits
- [Roadmap]: Structured logging before metrics/alerting -- telemetry events are prerequisite for aggregation
- [09-05]: node:test (built-in) for sidecar tests -- zero external test deps
- [09-05]: Extract functions with path params for testability -- no global state in modules
- [Phase 09-01]: Directory-based DETS paths for multi-table modules instead of single-file paths
- [Phase 09-01]: import_config pattern with dev/prod stubs for environment-specific config
- [Phase 09-02]: Stop Scheduler in TaskQueue/AgentFSM tests to prevent PubSub auto-assignment
- [Phase 09-02]: Drain mailbox + kill FSM children in Scheduler test setup for process/message isolation
- [Phase 09-03]: Message.new requires %{} maps (not keyword lists) to avoid Access crash on nil optional fields
- [Phase 09-03]: Circular reply chain test tagged :skip to document known bug without hanging CI
- [Phase 09-04]: Polling-based assertions instead of PubSub assert_receive for Scheduler-dependent integration tests
- [Phase 09-04]: Explicit FSM sync for TestFactory agents in failure path tests where FSM state matters
- [Phase 09-06]: npm test (not raw node --test) for sidecar CI -- delegates to package.json single source of truth
- [Phase 09-06]: mix test --exclude skip to avoid known-buggy tests in CI
- [Phase 09-07]: @moduletag :smoke for whole-module exclusion of environment-dependent smoke tests
- [Phase 10-01]: Application.get_env for backup_dir (not DETS Config) to avoid chicken-and-egg problem
- [Phase 10-01]: Direct :dets.sync + File.cp for backup -- no routing through owning GenServers
- [Phase 10-01]: DetsBackup placed after DashboardNotifier, before Bandit in supervision tree
- [Phase 10-02]: try/rescue wrapper for DetsBackup calls in DashboardState for startup ordering
- [Phase 10-02]: Stale backup and high fragmentation are warning conditions, not critical
- [Phase 10-02]: backup_complete events trigger full snapshot refresh for simplicity
- [Phase 10-03]: Only normalize last_backup_results (not table_metrics) -- atoms auto-serialize in Jason
- [Phase 10-03]: Tuple-to-map normalization at GenServer boundary before JSON encoding paths
- [Phase 11-01]: Single-table GenServers use :compact atom; multi-table use {:compact, table_atom} tuple
- [Phase 11-01]: Application.compile_env for compaction_interval_ms and compaction_threshold
- [Phase 11-01]: table_owner/1 function clause dispatch for GenServer routing
- [Phase 11-01]: Compaction history capped at 20 entries in GenServer state
- [Phase 11-02]: Wrap persist_task/lookup_task helpers in TaskQueue for corruption detection (not individual handlers)
- [Phase 11-02]: Config get returns default on corruption for graceful degradation
- [Phase 11-02]: get_table_path/1 matches each GenServer's actual env var path resolution
- [Phase 11-03]: compact_one/1 on DetsBackup for efficient single-table compaction (avoid compacting all 9)
- [Phase 11-03]: @dets_table_atoms shared module attribute for validated string-to-atom table name mapping
- [Phase 11-03]: Push notifications for failures and auto-restores only (successful operations silent)
- [Phase 12-01]: Pure Elixir validation (no external deps) -- pattern matching + guards
- [Phase 12-01]: Schema-as-data: same maps for runtime validation and JSON discovery endpoint
- [Phase 12-01]: ViolationTracker as pure functions + ETS, not a GenServer
- [Phase 12-01]: generation required for task_complete/task_failed (verified sidecar sends it)
- [Phase 12-02]: Validation in handle_in before handle_msg -- single gate for all WS messages
- [Phase 12-02]: HTTP validation returns 422 (not 400) -- 400 reserved for malformed JSON
- [Phase 12-02]: GET /api/schemas is unauthenticated -- agents need introspection before identifying
- [Phase 12-02]: Validation events broadcast to PubSub "validation" topic for dashboard visibility
- [Phase 12-03]: Validation failure ring buffer capped at 50, disconnects at 20
- [Phase 12-03]: Health warning threshold: >50 validation failures per hour
- [Phase 12-03]: Empty string agent_id passes schema validation (endpoint handles emptiness)
- [Phase 13-01]: Tuple config format {Module, opts} in config.exs -- Module.new/1 unavailable at config eval time
- [Phase 13-01]: File handler added programmatically via :logger.add_handler in Application.start (Config.config/2 requires keyword lists)
- [Phase 13-01]: RedactKeys takes plain list of key strings, not keyword list
- [Phase 13-02]: Scheduler emits telemetry attempt even with 0 idle agents (capacity planning metric)
- [Phase 13-02]: DetsBackup wraps per-table compaction in telemetry.span (not compact_table directly) to avoid double-wrapping
- [Phase 13-02]: Lazy Logger.debug(fn -> ... end) for backup cleanup paths per plan guidance
- [Phase 13-03]: request_id via :crypto.strong_rand_bytes(8) hex-encoded -- 16-char lowercase hex per WS message
- [Phase 13-03]: PUT /api/admin/log-level is ephemeral (resets on restart) per user decision
- [Phase 13-03]: Sidecar log function/line via Error().stack frame parsing; unhandledRejection continues, uncaughtException exits
- [Phase 13-04]: Direct LoggerJSON.Formatters.Basic invocation for log format tests (CaptureLog bypasses formatter, captures plain text)
- [Phase 13-04]: Metadata fields tested under parsed["metadata"] nested key matching LoggerJSON actual output structure
- [Phase 14-01]: ETS :public table for telemetry handlers (they run in emitting process, not MetricsCollector)
- [Phase 14-01]: GenServer.cast for duration/transition recording to avoid blocking emitting processes
- [Phase 14-01]: Snapshot cache in ETS refreshed every 10s -- /api/metrics reads cache, zero-cost reads
- [Phase 14-01]: MetricsCollector after Scheduler, before DashboardState in supervision tree
- [Phase 14-01]: GET /api/metrics unauthenticated (same pattern as /api/dashboard/state)
- [Phase 14-02]: Alerter after MetricsCollector, before DashboardState in supervision tree
- [Phase 14-02]: 30s startup delay prevents false positives before agents reconnect
- [Phase 14-02]: CRITICAL alerts bypass cooldown; WARNING alerts respect per-rule cooldown periods
- [Phase 14-02]: Thresholds merged with defaults so partial custom configs don't break rules
- [Phase 14-02]: GET /api/alerts unauthenticated (same pattern as /api/dashboard/state)
- [Phase 14-02]: Queue growing hysteresis: 3 consecutive stable checks required to clear
- [Phase 14-03]: Compact metrics_snapshot for WebSocket: Map.take on per_agent fields to keep payload under 5KB
- [Phase 14-03]: alert_cleared/acknowledged push notifications suppressed (UI handles via WebSocket, avoids spam)
- [Phase 14-03]: DashboardState fetches active_alerts live from Alerter (no local state duplication)
- [Phase 14-03]: Alert event handlers in DashboardState are no-ops (data fetched on-demand in snapshot)
- [Phase 14-04]: uPlot via CDN (unpkg) for zero-build charting in inline HTML dashboard
- [Phase 14-04]: 360-point rolling window for chart data (1hr at 10s intervals)
- [Phase 14-04]: Alert banner uses highest-severity detection across unacknowledged alerts
- [Phase 14-04]: Extend existing WebSocket onmessage handler (no second connection)
- [Phase 15-01]: Lazy token bucket (not timer-based) -- zero background cost per agent, refill computed on access
- [Phase 15-01]: Internal token units (real * 1000) for integer precision without floating-point drift
- [Phase 15-01]: Monotonic time for bucket timing to prevent NTP clock jump issues
- [Phase 15-01]: Progressive backoff 1s/2s/5s/10s/30s with 60s quiet period reset
- [Phase 15-01]: ETS tables :rate_limit_buckets and :rate_limit_overrides created in Application.start (public, set)
- [Phase 15-03]: Lazy DETS->ETS loading with :_loaded flag -- avoids Application.start ordering issues with Config GenServer
- [Phase 15-03]: ETS foldl for get_overrides/0 -- fast read without DETS GenServer round-trip
- [Phase 15-03]: parse_override_params converts human-readable tokens/min to internal units at API boundary
- [Phase 15-03]: Whitelist routes before parameterized :agent_id routes in Plug.Router for correct matching
- [Phase 15]: [Phase 15-02]: rate_limit_and_handle gate function between validation and handle_msg (not inline)
- [Phase 15]: [Phase 15-02]: HTTP warn path is no-op (allow) -- no bidirectional warning channel for HTTP
- [Phase 15]: [Phase 15-02]: IP-based rate limiting fallback for unauthenticated HTTP routes
- [Phase 15]: [Phase 15-02]: Exempt endpoints: /health, /dashboard, /ws, /api/schemas -- critical infrastructure
- [Phase 15-04]: PubSub "rate_limits" topic for DashboardState real-time violation tracking
- [Phase 15-04]: Push notifications every 10th violation per agent (threshold-based, not per-event)
- [Phase 15-04]: Sweeper uses Presence.list() for connected agent detection
- [Phase 15-04]: DashboardNotifier.notify/1 added as public API for programmatic push
- [Phase 16-01]: ExDoc main page set to architecture (not setup) -- provides system context before procedures
- [Phase 16-01]: Placeholder extras for future plans -- ExDoc requires all referenced files to exist at generation time
- [Phase 16-02]: Windows CMD syntax for curl examples (^ line continuation) since operator is on Windows
- [Phase 16-02]: All 12 sidecar config fields documented from add-agent.js source
- [Phase 16-03]: API quick reference grouped by function (not auth requirement) for faster lookup
- [Phase 16-03]: Troubleshooting organized by symptom with inline log queries (not separate log section)

### Pending Todos

1. Clarify repo_url vs default_repo naming in agent onboarding (area: api)

### Blockers/Concerns

- [Tech debt]: Elixir version bump (1.14 to 1.17+) recommended for :gen_statem logger fix
- [Tech debt]: Sidecar queue.json atomicity -- fs.writeFileSync has partial-write-on-crash risk
- [Tech debt]: VAPID keys ephemeral -- push subscriptions lost on hub restart
- [Tech debt]: Analytics and Threads modules orphaned (not exposed via API)
- [Resolved 11-01]: DETS compaction uses repair: force (not copy-and-swap) -- only documented method
- [Resolved 09-01]: Config and Threads now use Application.get_env for DETS paths

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 1 | Fix pre-existing compilation warnings | 2026-02-12 | 898d665 | [1-fix-pre-existing-compilation-warnings](./quick/1-fix-pre-existing-compilation-warnings/) |

## Session Continuity

Last session: 2026-02-12
Stopped at: v1.1 Hardening milestone complete. All 8 phases (9-16), 31 plans executed.
Resume file: None
