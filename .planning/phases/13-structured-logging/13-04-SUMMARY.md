---
phase: 13-structured-logging
plan: 04
subsystem: testing
tags: [structured-logging, telemetry, json-logging, exunit, node-test, capture-log, redaction, log-format-assertion]

# Dependency graph
requires:
  - phase: 13-02
    provides: "Telemetry event emission points (15 execute + 3 span) across 6 core modules"
  - phase: 13-03
    provides: "LoggerJSON formatter config, sidecar/lib/log.js structured logger, all modules converted to structured format"
provides:
  - "18 Elixir log format assertion tests verifying JSON validity, severity, timestamps, metadata, and redaction"
  - "26 Elixir telemetry event tests verifying handler attachment and event shapes for all lifecycle points"
  - "25 Node.js sidecar log tests verifying JSON output, redaction, level filtering, and Elixir parity"
  - "Regression guards ensuring no future changes revert to unstructured logging or break telemetry events"
affects: [14-metrics]

# Tech tracking
tech-stack:
  added: []
  patterns: [direct-formatter-invocation-testing, telemetry-attach-many-test-pattern, stdout-capture-testing]

key-files:
  created:
    - test/agent_com/log_format_test.exs
    - test/agent_com/telemetry_test.exs
    - sidecar/test/log.test.js
  modified: []

key-decisions:
  - "Direct LoggerJSON.Formatters.Basic invocation for log format tests instead of CaptureLog (ExUnit CaptureLog bypasses formatter, captures plain text)"
  - "Metadata fields tested under parsed['metadata'] nested key matching LoggerJSON.Formatters.Basic actual output structure"

patterns-established:
  - "LoggerJSON formatter tested by constructing log_event map and calling module.format/2 directly -- deterministic JSON output without ExUnit handler interference"
  - "Telemetry event shape tests use :telemetry.execute with test handler sending to self() via assert_receive -- fast, isolated, no GenServer dependency"
  - "Sidecar stdout capture via process.stdout.write replacement in try/finally block for clean restore"

# Metrics
duration: 6min
completed: 2026-02-12
---

# Phase 13 Plan 04: Structured Logging Verification Tests Summary

**69 regression tests across Elixir and Node.js verifying JSON log format, telemetry event shapes, secret redaction, and hub/sidecar field parity**

## Performance

- **Duration:** 6 min
- **Started:** 2026-02-12T10:25:08Z
- **Completed:** 2026-02-12T10:31:15Z
- **Tasks:** 2
- **Files created:** 3

## Accomplishments
- 18 Elixir log format tests verify JSON validity, required fields (time/severity/message), ISO 8601 timestamps, severity mapping for all 5 levels, NDJSON single-line format, secret redaction (token/auth_token/secret to [REDACTED]), metadata propagation (module/agent_id/task_id/mfa/line/file), per-module format for TaskQueue/DetsBackup/Scheduler, and formatter configuration
- 26 Elixir telemetry tests verify handler attachment for 13 event prefixes, event shapes with correct measurements and metadata for all 7 task lifecycle events, 3 agent events, FSM transitions (including all documented state pairs), 2 scheduler events (including 0-idle-agents capacity metric), 9 DETS span events (start/stop/exception for backup/compaction/restore), and event independence
- 25 Node.js sidecar log tests verify JSON output format (10 tests), secret redaction (4 tests), level filtering (3 tests), custom module names (2 tests), Elixir hub field parity (4 tests), and LEVELS export (2 tests)
- All 69 new tests pass alongside existing test suites (248 Elixir tests + 26 sidecar tests)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Elixir log format assertion tests and telemetry event tests** - `2126734` (test)
2. **Task 2: Create sidecar structured logger tests** - `ba4a5e2` (test)

## Files Created/Modified
- `test/agent_com/log_format_test.exs` - 18 tests: JSON format validity, severity mapping, ISO 8601 timestamps, secret redaction (token/auth_token/secret), metadata propagation, per-module format for TaskQueue/DetsBackup/Scheduler, formatter configuration
- `test/agent_com/telemetry_test.exs` - 26 tests: handler attachment for all event prefixes, event shapes for task (submit/assign/complete/fail/dead_letter/reclaim/retry), agent (connect/disconnect/evict), FSM transition, scheduler (attempt/match), DETS spans (backup/compaction/restore start/stop/exception), event independence
- `sidecar/test/log.test.js` - 25 tests: JSON output format, required fields, NDJSON format, caller stack metadata, secret redaction, level filtering, custom module names, Elixir hub field parity (shared fields, severity values, timestamp format, redaction keys), LEVELS export

## Decisions Made
- **Direct formatter invocation instead of CaptureLog**: ExUnit's CaptureLog handler bypasses the LoggerJSON formatter and captures plain-text output (e.g., `02:26:27.237 [info] test_event`). To test actual JSON output, tests call `LoggerJSON.Formatters.Basic.format/2` directly with constructed log_event maps. This gives deterministic, formatter-specific JSON output.
- **Metadata nested under "metadata" key**: LoggerJSON.Formatters.Basic wraps Logger metadata into a `metadata` nested object, with `time`, `severity`, `message` at top level. Tests assert on `parsed["metadata"]["agent_id"]` not `parsed["agent_id"]`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Adapted test approach for CaptureLog/formatter incompatibility**
- **Found during:** Task 1 (Elixir log format tests)
- **Issue:** Plan assumed `capture_log([level: :info], fn -> Logger.info(...) end)` would produce JSON output. In reality, ExUnit's CaptureLog uses its own handler that bypasses LoggerJSON formatter entirely, producing plain text like `02:26:27.237 [info] test_event`. Additionally, the test environment sets `config :logger, level: :warning` which filters out :info messages before CaptureLog captures them.
- **Fix:** Tests call `LoggerJSON.Formatters.Basic.new/1` with the same options from config.exs, then invoke `module.format/2` directly with constructed log_event maps. This tests the actual formatter behavior deterministically.
- **Files modified:** test/agent_com/log_format_test.exs
- **Verification:** All 18 log format tests pass, verifying the same JSON structure seen in production stdout output
- **Committed in:** 2126734

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Test approach adapted to match actual framework behavior. Tests verify the same JSON output that production logging produces. Stronger guarantee than CaptureLog approach since it tests the formatter directly with matching configuration.

## Issues Encountered
- CaptureLog in Elixir 1.19.5 / OTP 28 does not use the configured `:default_handler` formatter -- it has its own internal handler. This is expected behavior, not a bug. The plan's CaptureLog-based approach was adapted to direct formatter invocation.
- 1 pre-existing test failure in dets_backup_test.exs (backup_all :enoent) -- not related to logging changes, documented in 13-03 SUMMARY.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 13 (structured logging) is complete: all 4 plans executed
- All Elixir modules and sidecar emit structured JSON logs with telemetry events
- 69 regression tests guard against format/emission regressions
- Phase 14 (metrics/alerting) can aggregate telemetry events from all emission points
- Telemetry event shapes are documented and tested, providing a stable contract for Phase 14

## Self-Check: PASSED

- test/agent_com/log_format_test.exs verified present
- test/agent_com/telemetry_test.exs verified present
- sidecar/test/log.test.js verified present
- Commit 2126734 verified (Task 1: Elixir log format + telemetry tests)
- Commit ba4a5e2 verified (Task 2: sidecar log tests)
- mix test passes (44 new tests, 0 failures in new files)
- npm test passes (25 new tests, 0 failures in new file)

---
*Phase: 13-structured-logging*
*Plan: 04*
*Completed: 2026-02-12*
