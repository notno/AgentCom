# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-11)

**Core value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.
**Current focus:** v1.1 Hardening -- Phase 12 Input Validation

## Current Position

Phase: 12-input-validation
Plan: 2 of 3 complete
Status: Executing phase 12
Last activity: 2026-02-12 -- Completed 12-02-PLAN.md (validation integration into Socket and Endpoint)

## Performance Metrics

**Velocity:**
- Total plans completed: 15 (v1.1)
- Average duration: 5 min
- Total execution time: 1.2 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 09-testing | 7 | 33 min | 5 min |
| 10-dets-backup | 3 | 8 min | 3 min |
| 11-dets-compaction | 3 | 15 min | 5 min |
| 12-input-validation | 2 | 8 min | 4 min |

**Recent Trend:**
- Last 5 plans: 12-02 (4 min), 12-01 (4 min), 11-03 (5 min), 11-02 (5 min), 11-01 (5 min)
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

### Pending Todos

None.

### Blockers/Concerns

- [Tech debt]: Elixir version bump (1.14 to 1.17+) recommended for :gen_statem logger fix
- [Tech debt]: Sidecar queue.json atomicity -- fs.writeFileSync has partial-write-on-crash risk
- [Tech debt]: VAPID keys ephemeral -- push subscriptions lost on hub restart
- [Tech debt]: Analytics and Threads modules orphaned (not exposed via API)
- [Resolved 11-01]: DETS compaction uses repair: force (not copy-and-swap) -- only documented method
- [Resolved 09-01]: Config and Threads now use Application.get_env for DETS paths

## Session Continuity

Last session: 2026-02-12
Stopped at: Completed 12-02-PLAN.md (validation integration into Socket and Endpoint). Phase 12 in progress (2/3 plans).
Resume file: None
