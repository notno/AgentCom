---
phase: 13-structured-logging
plan: 03
subsystem: infra
tags: [structured-logging, json-logging, sidecar, ndjson, request-id, log-level-api, websocket]

# Dependency graph
requires:
  - phase: 13-01
    provides: "LoggerJSON infrastructure and Telemetry module"
provides:
  - "All 9 remaining Elixir modules converted to structured Logger.metadata format"
  - "Per-WS-message request_id generation in Socket handle_in/2"
  - "PUT /api/admin/log-level runtime configuration endpoint"
  - "sidecar/lib/log.js structured JSON logger with function/line metadata"
  - "All sidecar stdout output is NDJSON with consistent field conventions"
  - "Global error handlers for unhandled rejections and uncaught exceptions"
affects: [13-04, 14-metrics]

# Tech tracking
tech-stack:
  added: []
  patterns: [structured-log-metadata, request-id-per-ws-message, runtime-log-level-api, ndjson-sidecar-logging]

key-files:
  created:
    - sidecar/lib/log.js
  modified:
    - lib/agent_com/socket.ex
    - lib/agent_com/endpoint.ex
    - lib/agent_com/dashboard_notifier.ex
    - lib/agent_com/dashboard_state.ex
    - lib/agent_com/channels.ex
    - lib/agent_com/mailbox.ex
    - lib/agent_com/config.ex
    - lib/agent_com/threads.ex
    - lib/agent_com/message_history.ex
    - sidecar/index.js

key-decisions:
  - "request_id generated via :crypto.strong_rand_bytes(8) hex-encoded -- 16-char lowercase hex per WS message"
  - "PUT /api/admin/log-level is auth-protected, validates against 5 levels, resets on restart (ephemeral)"
  - "Sidecar log function/line extracted via Error().stack frame parsing at call site"
  - "Sidecar log levels match Elixir: debug(10), info(20), notice(30), warning(40), error(50)"
  - "Global error handlers added: unhandledRejection logs + continues, uncaughtException logs + exits"

patterns-established:
  - "Logger.metadata(module: __MODULE__) in every GenServer/WebSock init/1"
  - "Logger.metadata(request_id: ...) at top of WebSock handle_in/2 for per-message correlation"
  - "Structured Logger calls: Logger.info(event_string, key: value) not Logger.info(interpolated_string)"
  - "Sidecar log(level, event, data, moduleName) 4-arg convention matching hub field names"

# Metrics
duration: 15min
completed: 2026-02-12
---

# Phase 13 Plan 03: Remaining Modules + Sidecar Structured Logging Summary

**All 9 Elixir modules converted to structured Logger.metadata, per-WS-message request_id, runtime log-level API, and Node.js sidecar NDJSON output with function/line metadata**

## Performance

- **Duration:** ~15 min (across two sessions due to context reset)
- **Started:** 2026-02-12T10:06:00Z
- **Completed:** 2026-02-12T10:22:00Z
- **Tasks:** 2
- **Files modified:** 11

## Accomplishments
- All 9 remaining Elixir modules now set Logger.metadata(module: __MODULE__) in init/1 and use structured log format
- Socket generates a unique request_id per WebSocket message via :crypto.strong_rand_bytes(8), set in Logger.metadata for log correlation
- Socket sets Logger.metadata(agent_id: agent_id) after successful identification in do_identify/3
- PUT /api/admin/log-level endpoint added with auth protection, level validation, and Logger.configure runtime change
- sidecar/lib/log.js created with NDJSON output, level filtering, file rotation (10MB x 5), token redaction, and function/line capture
- All 50+ sidecar log calls converted from old 2-arg to new 4-arg structured format with appropriate severity levels
- Global error handlers (unhandledRejection, uncaughtException) route through structured logger
- Zero console.log/console.error calls remain in sidecar codebase

## Task Commits

Each task was committed atomically:

1. **Task 1: Convert remaining Elixir modules + Socket request_id + log-level API** - `9525ea4` (feat)
2. **Task 2: Convert Node.js sidecar to structured JSON logging with function/line metadata** - `7c3ae7e` (feat)

## Files Created/Modified
- `lib/agent_com/socket.ex` - request_id per WS message, agent_id after auth, structured log_task_event
- `lib/agent_com/endpoint.ex` - PUT /api/admin/log-level endpoint, structured reset warning
- `lib/agent_com/dashboard_notifier.ex` - Logger.metadata + 6 structured log calls
- `lib/agent_com/dashboard_state.ex` - Logger.metadata + 4 structured log calls
- `lib/agent_com/channels.ex` - Logger.metadata + 2 DETS corruption structured logs
- `lib/agent_com/mailbox.ex` - Logger.metadata + 2 DETS corruption structured logs
- `lib/agent_com/config.ex` - Logger.metadata + 2 DETS corruption structured logs
- `lib/agent_com/threads.ex` - Logger.metadata + 3 DETS corruption structured logs
- `lib/agent_com/message_history.ex` - Logger.metadata + 1 DETS corruption structured log
- `sidecar/lib/log.js` - Structured JSON logger (NDJSON, levels, rotation, redaction, function/line)
- `sidecar/index.js` - All log calls converted to structured 4-arg format, initLogger, global error handlers

## Decisions Made
- request_id uses `:crypto.strong_rand_bytes(8)` with `Base.encode16(case: :lower)` for 16-char hex strings -- lightweight, unique enough for log correlation
- PUT /api/admin/log-level validates against `~w(debug info notice warning error)` and uses `String.to_existing_atom/1` for safety
- Log level changes are ephemeral (reset on restart) per user decision -- config.exs default reasserted on next start
- Sidecar log function/line extracted via `Error().stack` parsing (frame index 3 = caller of log())
- Sidecar severity levels numerically match Elixir convention: debug=10, info=20, notice=30, warning=40, error=50
- unhandledRejection logs the error and continues; uncaughtException logs and calls process.exit(1)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- Port 4002 already in use (BEAM processes from prior sessions) -- killed orphaned processes to run tests
- Pre-existing compile warning in socket.ex (unreachable {:error, reason} clause) -- not caused by changes, used `mix compile` without --warnings-as-errors
- 1 pre-existing test failure in dets_backup_test.exs (backup_all :enoent) -- not related to logging changes

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All Elixir modules and sidecar now emit structured JSON logs with consistent field conventions
- Ready for Plan 04 (integration verification and log format compliance testing)
- Telemetry events (from Plan 02) + structured logging (this plan) provide full observability foundation for Phase 14 metrics

## Self-Check: PASSED

- All 11 files verified present (1 created, 10 modified)
- Commit 9525ea4 verified (Task 1: Elixir modules)
- Commit 7c3ae7e verified (Task 2: sidecar logging)
- Zero old-format log() calls in sidecar/index.js (grep verified)
- Zero console.log/console.error in sidecar/ (grep verified)
- Sidecar JSON output verified with all required fields (time, severity, message, module, pid, node, agent_id, function, line)
- Token redaction verified ([REDACTED] in output)
- Log level filtering verified (debug filtered at info level)

---
*Phase: 13-structured-logging*
*Plan: 03*
*Completed: 2026-02-12*
