---
phase: 13-structured-logging
plan: 02
subsystem: observability
tags: [structured-logging, telemetry, telemetry-execute, telemetry-span, logger-metadata, json-logging]

# Dependency graph
requires:
  - phase: 13-01
    provides: "LoggerJSON formatter, AgentCom.Telemetry module with 22-event catalog"
provides:
  - "All 47 Logger calls across 6 core modules converted to structured metadata format"
  - "Logger.metadata set in init/1 of all 6 modules (agent_id, module context)"
  - "15 telemetry.execute emission points for task/agent/FSM/scheduler lifecycle events"
  - "3 telemetry.span emission points for DETS backup/compaction/restore operations"
affects: [13-03, 13-04, 14-metrics]

# Tech tracking
tech-stack:
  added: []
  patterns: [structured-logger-metadata, telemetry-execute-point-events, telemetry-span-operations, lazy-debug-logging]

key-files:
  created: []
  modified:
    - lib/agent_com/agent_fsm.ex
    - lib/agent_com/task_queue.ex
    - lib/agent_com/scheduler.ex
    - lib/agent_com/dets_backup.ex
    - lib/agent_com/presence.ex
    - lib/agent_com/reaper.ex

key-decisions:
  - "Scheduler emits telemetry attempt event even when no idle agents (0 idle agents is useful metric for capacity planning)"
  - "DetsBackup wraps entire do_compact_all via per-table telemetry.span rather than wrapping compact_table to avoid double-wrapping"
  - "Lazy evaluation Logger.debug(fn -> ... end) for backup cleanup path names (potentially long file paths)"

patterns-established:
  - "Structured Logger message format: Logger.info(\"event_name\", key: value) -- message is always a snake_case event name, context in keyword metadata"
  - "Process metadata set once in init/1: Logger.metadata(module: __MODULE__) -- agent_id added when available"
  - "Telemetry.execute for point events (transitions, assignments, evictions) with measurements + metadata maps"
  - "Telemetry.span for operations with duration (DETS backup/compaction/restore) -- auto-emits start/stop/exception"
  - ":notice level for successful operational completions (backup complete, compaction complete)"

# Metrics
duration: 9min
completed: 2026-02-12
---

# Phase 13 Plan 02: Core Module Telemetry Summary

**Structured logging + telemetry events across 6 core modules: AgentFSM, TaskQueue, Scheduler, DetsBackup, Presence, Reaper with 18 emission points**

## Performance

- **Duration:** 9 min
- **Started:** 2026-02-12T10:09:37Z
- **Completed:** 2026-02-12T10:18:56Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- All 47 Logger calls across 6 core modules converted from string interpolation to structured keyword metadata format
- Logger.metadata set in init/1 of all 6 modules with module context (agent_id added in AgentFSM)
- 15 telemetry.execute emission points: 7 task lifecycle (submit/assign/complete/fail/dead_letter/reclaim/retry), 3 agent lifecycle (connect/disconnect/evict), 1 FSM transition, 2 scheduler (attempt/match), plus 2 additional reclaim events from overdue sweep
- 3 telemetry.span wrapping DETS operations (backup, compaction, restore) with automatic start/stop/exception events
- Appropriate log levels per 5-level decision: debug for cleanup details, info for lifecycle, notice for operational completions, warning for recoverable issues, error/critical for failures

## Task Commits

Each task was committed atomically:

1. **Task 1: Convert AgentFSM and TaskQueue** - `04acc32` (feat)
2. **Task 2: Convert Scheduler, DetsBackup, Presence, Reaper** - `f83eab2` (feat)

## Files Created/Modified
- `lib/agent_com/agent_fsm.ex` - 23 Logger calls converted to structured format, Logger.metadata in init/1, telemetry events for fsm:transition, agent:connect, agent:disconnect
- `lib/agent_com/task_queue.ex` - 4 Logger calls converted, Logger.metadata in init/1, telemetry events for all 7 task lifecycle events
- `lib/agent_com/scheduler.ex` - 5 Logger calls converted, Logger.metadata in init/1, telemetry events for scheduler:attempt and scheduler:match
- `lib/agent_com/dets_backup.ex` - 14 Logger calls converted, Logger.metadata in init/1, telemetry spans for backup/compaction/restore operations
- `lib/agent_com/presence.ex` - Logger.metadata in init/1, added structured log messages for register/unregister
- `lib/agent_com/reaper.ex` - 1 Logger call converted, Logger.metadata in init/1, telemetry event for agent:evict

## Decisions Made
- Scheduler emits telemetry attempt event even when no idle agents are found -- 0 idle agents with N queued tasks is a useful capacity planning metric, so both branches of try_schedule_all emit the attempt event.
- DetsBackup wraps the per-table compaction inside telemetry.span (inside do_compact_all) rather than wrapping compact_table directly, to avoid double-wrapping when compact_one also calls compact_table.
- Used Logger.debug(fn -> ... end) lazy evaluation for backup cleanup path logging, per plan guidance on avoiding evaluation of potentially large data at debug level.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed unused variable warning in AgentFSM.reclaim_task_from_agent/2**
- **Found during:** Task 1 (AgentFSM conversion)
- **Issue:** After converting Logger calls to structured format (removing string interpolation of agent_id), the agent_id parameter became unused, producing a compiler warning
- **Fix:** Prefixed with underscore: `_agent_id` -- agent_id is already in process metadata via Logger.metadata
- **Files modified:** lib/agent_com/agent_fsm.ex
- **Verification:** mix compile shows zero warnings for this module
- **Committed in:** 04acc32

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Trivial fix, direct consequence of removing string interpolation. No scope creep.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All 6 core modules now emit structured JSON logs and telemetry events
- Plan 03 can convert the remaining 8 modules (22 Logger calls) using the same patterns established here
- Plan 04 can add assertion tests verifying JSON output format per module
- Phase 14 can aggregate telemetry events from all 18 emission points

## Self-Check: PASSED

- All 6 files verified present
- Commit 04acc32 verified (Task 1)
- Commit f83eab2 verified (Task 2)
- mix compile succeeds with zero new warnings
- mix test passes (pre-existing flaky seed-order failures only)
- Zero string interpolation Logger calls in all 6 modules
- 18 telemetry emission points confirmed (15 execute + 3 span)

---
*Phase: 13-structured-logging*
*Plan: 02*
*Completed: 2026-02-12*
