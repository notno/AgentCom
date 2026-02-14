---
phase: 28-pipeline-dependencies
plan: 01
subsystem: api
tags: [task-queue, scheduler, dependencies, goals, pipeline]

# Dependency graph
requires:
  - phase: 17-task-enrichment
    provides: task enrichment fields in TaskQueue, Scheduler, Endpoint
  - phase: 19-tier-routing
    provides: scheduler routing loop, task_data forwarding
provides:
  - depends_on and goal_id fields on task map
  - dependency validation at submit time
  - scheduler dependency filter (tasks wait for prerequisites)
  - goal progress query API (tasks_for_goal, goal_progress)
  - goal_id filter on GET /api/tasks
affects: [28-02-PLAN, phase-30-goal-decomposition]

# Tech tracking
tech-stack:
  added: []
  patterns: [dependency-aware scheduling, goal-based task grouping]

key-files:
  modified:
    - lib/agent_com/task_queue.ex
    - lib/agent_com/scheduler.ex
    - lib/agent_com/validation/schemas.ex
    - lib/agent_com/endpoint.ex
    - test/support/test_factory.ex

key-decisions:
  - "Dependency validation at submit time rejects unknown task IDs immediately rather than at schedule time"
  - "Dependencies checked against both tasks and dead_letter tables to accept deps on failed tasks"
  - "goal_progress/1 implemented as client-side aggregation over tasks_for_goal/1 (no extra GenServer call)"

patterns-established:
  - "Map.get(task, :field, default) pattern for DETS backward compatibility with new fields"

# Metrics
duration: 8min
completed: 2026-02-13
---

# Phase 28 Plan 01: Pipeline Dependencies Summary

**depends_on and goal_id fields across task pipeline -- submit-time dependency validation, scheduler filtering, goal progress queries, and API endpoint support**

## Performance

- **Duration:** 8 min
- **Started:** 2026-02-13T23:52:42Z
- **Completed:** 2026-02-14T00:00:16Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Tasks can be submitted with depends_on (list of task IDs) and goal_id fields via HTTP API
- TaskQueue validates dependency IDs exist at submit time, rejecting invalid ones
- Scheduler filters out tasks whose dependencies are not yet completed before matching
- Goal progress can be queried via tasks_for_goal/1 and goal_progress/1
- GET /api/tasks supports goal_id query parameter for filtering
- All 122 relevant tests pass with zero regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Add depends_on and goal_id to TaskQueue** - `04c0f69` (feat)
2. **Task 2: Scheduler dependency filter, API schema/endpoint updates** - `424c2fa` (feat)

## Files Created/Modified
- `lib/agent_com/task_queue.ex` - depends_on/goal_id fields, dependency validation, tasks_for_goal/1, goal_progress/1, goal_id list filter
- `lib/agent_com/scheduler.ex` - dependency completion filter in try_schedule_all, depends_on/goal_id in task_data
- `lib/agent_com/validation/schemas.ex` - depends_on and goal_id in post_task schema
- `lib/agent_com/endpoint.ex` - depends_on/goal_id forwarding in POST, goal_id filter in GET, format_task output
- `test/support/test_factory.ex` - depends_on and goal_id opts in submit_task/1

## Decisions Made
- Dependency validation at submit time (not schedule time) -- fail fast on bad IDs
- Check both tasks and dead_letter tables for dependency existence -- allows deps on completed-then-failed tasks
- goal_progress/1 as a pure client function over tasks_for_goal/1 -- avoids extra GenServer call overhead

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Added depends_on and goal_id to format_task API output**
- **Found during:** Task 2 (endpoint updates)
- **Issue:** Plan specified API input forwarding but not output formatting; tasks would be stored with the fields but API responses would not include them
- **Fix:** Added depends_on and goal_id to the format_task/1 helper in endpoint.ex
- **Files modified:** lib/agent_com/endpoint.ex
- **Verification:** Compile clean, tests pass
- **Committed in:** 424c2fa (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** Essential for API consumers to see dependency data. No scope creep.

## Issues Encountered
- Port 4002 conflict during full test suite run (pre-existing process using port) -- killed stale process and re-ran
- 3 pre-existing test failures in RepoScanner/DetsBackup unrelated to this plan's changes

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Pipeline dependency fields are in place for Phase 28 Plan 02 (integration tests)
- Foundation ready for Phase 30 goal decomposition to produce ordered task graphs

---
*Phase: 28-pipeline-dependencies*
*Completed: 2026-02-13*
