---
phase: 04-scheduler
plan: 01
subsystem: scheduler
tags: [genserver, pubsub, event-driven, capability-matching, scheduling]

# Dependency graph
requires:
  - phase: 02-task-queue
    provides: "TaskQueue GenServer with submit, list, assign_task, reclaim_task APIs"
  - phase: 03-agent-state
    provides: "AgentFSM with list_all, get_state, capabilities, idle detection"
provides:
  - "Event-driven Scheduler GenServer that auto-matches queued tasks to idle agents"
  - "needed_capabilities field on tasks for capability-based routing"
  - "30-second stuck sweep reclaiming 5-minute stale assignments"
affects: [05-smoke-test, 06-dashboard, 07-sidecar-v2]

# Tech tracking
tech-stack:
  added: []
  patterns: [event-driven-scheduling, pubsub-reactive-genserver, capability-subset-matching, stateless-scheduler]

key-files:
  created:
    - lib/agent_com/scheduler.ex
  modified:
    - lib/agent_com/task_queue.ex
    - lib/agent_com/endpoint.ex
    - lib/agent_com/application.ex

key-decisions:
  - "Scheduler is stateless -- queries TaskQueue and AgentFSM on every attempt to avoid stale-state bugs"
  - "Scheduler does NOT call AgentFSM.assign_task -- Socket push_task handler owns FSM transition to prevent duplicate notifications"
  - "Greedy matching loop iterates all queued tasks, not just queue head, preventing head-of-line blocking (Pitfall 3)"
  - "Map.get with default [] for needed_capabilities on existing DETS records for backward compatibility"

patterns-established:
  - "PubSub reactive pattern: GenServer subscribes to topics and reacts to domain events rather than polling"
  - "Capability matching: exact string match with subset semantics, empty needed_capabilities means any agent qualifies"
  - "Self-healing race conditions: assign failures are logged and ignored, next event triggers retry"

# Metrics
duration: 2min
completed: 2026-02-10
---

# Phase 4 Plan 1: Scheduler Summary

**Event-driven Scheduler GenServer with PubSub-reactive task matching, capability-based routing, and 30-second stuck sweep**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-10T18:14:58Z
- **Completed:** 2026-02-10T18:17:10Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Tasks can include `needed_capabilities` field for capability-based agent routing
- Scheduler automatically matches queued tasks to idle agents within seconds of submission or agent availability
- Stuck assignments (5+ minutes stale) detected every 30 seconds and reclaimed to queue
- Event-driven design reacts to task_submitted, task_completed, task_reclaimed, task_retried, and agent_joined

## Task Commits

Each task was committed atomically:

1. **Task 1: Add needed_capabilities field to TaskQueue and Endpoint** - `0e254b3` (feat)
2. **Task 2: Create Scheduler GenServer with event-driven matching and stuck sweep** - `e17cd2d` (feat)

## Files Created/Modified
- `lib/agent_com/scheduler.ex` - Event-driven Scheduler GenServer (new, 236 lines)
- `lib/agent_com/task_queue.ex` - Added needed_capabilities extraction in submit handler
- `lib/agent_com/endpoint.ex` - Added needed_capabilities to POST /api/tasks and format_task/1
- `lib/agent_com/application.ex` - Added Scheduler to supervision tree after TaskQueue, before Bandit

## Decisions Made
- Scheduler is stateless: queries TaskQueue and AgentFSM on every scheduling attempt rather than caching state, eliminating stale-state bugs at acceptable cost for expected scale
- Scheduler does NOT call AgentFSM.assign_task directly: sends {:push_task, task_data} to WebSocket pid, and Socket's handle_info calls AgentFSM.assign_task, preventing duplicate FSM transition notifications
- Greedy matching loop iterates all queued tasks (not just queue head) to avoid head-of-line blocking when first task requires capabilities no idle agent has
- Used Map.get with default [] for needed_capabilities on DETS records for backward compatibility with existing tasks that lack the field

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Scheduler is live in the supervision tree, ready for Phase 5 smoke test
- All four Phase 4 success criteria architecturally addressed: event-driven scheduling (SCHED-01/04), capability matching (SCHED-02), stuck sweep (SCHED-03)
- Integration point between Phases 1-3 is now operational: tasks flow to agents automatically

## Self-Check: PASSED

All files exist, all commits verified:
- lib/agent_com/scheduler.ex: FOUND
- lib/agent_com/task_queue.ex: FOUND
- lib/agent_com/endpoint.ex: FOUND
- lib/agent_com/application.ex: FOUND
- .planning/phases/04-scheduler/04-01-SUMMARY.md: FOUND
- Commit 0e254b3: FOUND
- Commit e17cd2d: FOUND

---
*Phase: 04-scheduler*
*Completed: 2026-02-10*
