---
phase: 17-enriched-task-format
plan: 03
subsystem: task-pipeline
tags: [complexity, enrichment, scheduler, socket, sidecar, pipeline-wiring]

# Dependency graph
requires:
  - phase: 17-01
    provides: "AgentCom.Complexity module with build/1 for task complexity classification"
  - phase: 17-02
    provides: "Enrichment fields in task map, validation, and format_task serialization"
provides:
  - "End-to-end enrichment field pipeline: TaskQueue -> Scheduler -> Socket -> Sidecar"
  - "Automatic complexity classification at task submission time via Complexity.build"
  - "Disagreement telemetry with task_id context when explicit tier != inferred tier"
  - "Backward-compatible propagation with safe defaults at every pipeline stage"
affects: [18-agent-routing, 19-scheduler-routing, 21-verification-infrastructure]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Pipeline field propagation with Map.get defaults for backward compatibility", "Dual atom/string key access in Socket push for mixed-key task maps", "format_complexity_for_ws/1 for atom-to-string serialization across WebSocket boundary"]

key-files:
  created: []
  modified:
    - lib/agent_com/task_queue.ex
    - lib/agent_com/endpoint.ex
    - lib/agent_com/scheduler.ex
    - lib/agent_com/socket.ex
    - sidecar/index.js
    - test/agent_com/task_queue_test.exs

key-decisions:
  - "Complexity.build called in TaskQueue.submit for every submission -- heuristic always runs"
  - "TaskQueue emits its own disagreement telemetry with task_id context (supplements Complexity module telemetry)"
  - "All enrichment fields use additive-only pattern with safe defaults at every pipeline stage"

patterns-established:
  - "Pipeline enrichment propagation: each stage uses Map.get with defaults for backward compat with pre-enrichment tasks"
  - "WebSocket complexity serialization via format_complexity_for_ws with dual atom/string key support"

# Metrics
duration: 4min
completed: 2026-02-12
---

# Phase 17 Plan 03: Pipeline Wiring Summary

**Complexity engine wired into task submission, enrichment fields propagated end-to-end through TaskQueue -> Scheduler -> Socket -> Sidecar with backward-compatible defaults**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-12T19:37:10Z
- **Completed:** 2026-02-12T19:40:42Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- Wired AgentCom.Complexity.build into TaskQueue.submit so every task gets automatic complexity classification at submission time
- Added complexity_tier passthrough from POST /api/tasks endpoint to TaskQueue for explicit tier submission
- Propagated all 6 enrichment fields (repo, branch, file_hints, success_criteria, verification_steps, complexity) through Scheduler.do_assign -> Socket.push_task -> Sidecar.handleTaskAssign
- Added format_complexity_for_ws/1 helper in Socket for atom-to-string serialization across WebSocket boundary
- All 5 Phase 17 roadmap success criteria satisfied

## Task Commits

Each task was committed atomically:

1. **Task 1: Wire Complexity.build into TaskQueue.submit and pass complexity_tier from Endpoint** - `75256e6` (feat)
2. **Task 2: Propagate enrichment fields through Scheduler, Socket, and Sidecar** - `f91df0f` (feat)

## Files Created/Modified
- `lib/agent_com/task_queue.ex` - Complexity.build call replaces nil placeholder, disagreement telemetry with task_id
- `lib/agent_com/endpoint.ex` - complexity_tier added to task_params in POST /api/tasks
- `lib/agent_com/scheduler.ex` - Enrichment fields included in task_data for Socket push
- `lib/agent_com/socket.ex` - Enrichment fields in task_assign push, format_complexity_for_ws/1 helper
- `sidecar/index.js` - Enrichment fields stored from task_assign with safe defaults
- `test/agent_com/task_queue_test.exs` - 4 new tests for complexity wiring, 2 updated for computed complexity

## Decisions Made
- Complexity.build is called for every submission -- heuristic always runs even when explicit tier is provided, enabling observability and disagreement detection
- TaskQueue emits its own telemetry event with task_id (supplements the module-level telemetry in Complexity.build which lacks task_id context)
- All enrichment fields use additive-only pattern with safe defaults at every pipeline stage (no existing fields removed or renamed)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Updated pre-existing tests that asserted complexity == nil**
- **Found during:** Task 1 (test execution)
- **Issue:** Two tests from Plan 02 asserted `task.complexity == nil` because Plan 02 used nil as a placeholder. After wiring Complexity.build, complexity is now always a computed map.
- **Fix:** Updated assertions to verify complexity is a non-nil map with expected structure instead of nil
- **Files modified:** test/agent_com/task_queue_test.exs
- **Verification:** All 47 TaskQueue tests pass
- **Committed in:** 75256e6 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug fix)
**Impact on plan:** Necessary update to keep tests aligned with the new behavior. No scope creep.

## Issues Encountered
None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 17 complete: all 3 plans executed, all 5 roadmap success criteria satisfied
- Enrichment fields flow end-to-end from HTTP submission to sidecar receipt
- Complexity classification happens automatically at submission time
- Ready for Phase 18 (Agent Routing) which will use complexity tiers for scheduling decisions
- 1 pre-existing test failure in DetsBackupTest remains (known issue, unrelated to Phase 17)

## Self-Check: PASSED

- FOUND: lib/agent_com/task_queue.ex
- FOUND: lib/agent_com/endpoint.ex
- FOUND: lib/agent_com/scheduler.ex
- FOUND: lib/agent_com/socket.ex
- FOUND: sidecar/index.js
- FOUND: test/agent_com/task_queue_test.exs
- FOUND: 17-03-SUMMARY.md
- FOUND: 75256e6 (Task 1 commit)
- FOUND: f91df0f (Task 2 commit)
- Full test suite: 320 tests, 1 pre-existing failure, 0 new failures

---
*Phase: 17-enriched-task-format*
*Completed: 2026-02-12*
