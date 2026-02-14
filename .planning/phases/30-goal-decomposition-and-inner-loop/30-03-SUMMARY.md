---
phase: 30-goal-decomposition-and-inner-loop
plan: 03
subsystem: orchestration
tags: [genserver, pubsub, task-async, goal-lifecycle, inner-loop, orchestration]

requires:
  - phase: 30-01
    provides: FileTree and DagValidator for decomposition pipeline
  - phase: 30-02
    provides: Decomposer.decompose/1 and Verifier.verify/2 LLM pipelines
  - phase: 27-goal-backlog
    provides: GoalBacklog with lifecycle state machine and dequeue
  - phase: 28-task-queue-and-goal-backlog
    provides: TaskQueue with goal_progress/1 for task completion tracking
provides:
  - "GoalOrchestrator GenServer orchestrating dequeue -> decompose -> monitor -> verify lifecycle"
  - "HubFSM executing tick drives GoalOrchestrator.tick/0 for autonomous operation"
  - "GoalOrchestrator in supervision tree after GoalBacklog, before HubFSM"
affects: [hub-fsm-executing-state, goal-lifecycle, autonomous-loop]

tech-stack:
  added: []
  patterns:
    - "Task.async with single pending_async slot for serial LLM call queuing"
    - "try/catch :exit pattern for safe GenServer interop during startup"
    - "PubSub event-driven goal progress monitoring"

key-files:
  created:
    - lib/agent_com/goal_orchestrator.ex
    - test/agent_com/goal_orchestrator_test.exs
  modified:
    - lib/agent_com/hub_fsm.ex
    - lib/agent_com/application.ex

key-decisions:
  - "Single pending_async slot ensures only one LLM call in-flight at a time (respects ClaudeClient serialization)"
  - "Verification before decomposition priority: verification unlocks completed goals, decomposition creates new work"
  - "Process.demonitor with :flush in Task.async result handlers prevents stale DOWN messages"

patterns-established:
  - "GoalOrchestrator as central orchestration GenServer tying Decomposer, Verifier, GoalBacklog, and TaskQueue together"
  - "Fire-and-forget tick cast from HubFSM never blocks the 1s tick interval"

duration: 5min
completed: 2026-02-14
---

# Phase 30 Plan 03: GoalOrchestrator GenServer Summary

**Central orchestration GenServer with Task.async non-blocking LLM calls, PubSub task monitoring, and HubFSM executing tick integration for autonomous goal lifecycle**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-14T03:25:45Z
- **Completed:** 2026-02-14T03:31:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- GoalOrchestrator GenServer manages full inner loop: dequeue -> decompose -> monitor -> verify -> complete/retry/fail
- Task.async pattern with single pending_async slot ensures LLM calls never block HubFSM tick while respecting ClaudeClient serialization
- PubSub task_completed and task_dead_letter events drive goal progress monitoring with automatic ready_to_verify transition
- HubFSM calls GoalOrchestrator.tick/0 on every :executing state :stay tick via safe try/catch pattern
- GoalOrchestrator placed in supervision tree after GoalBacklog and before HubFSM for correct dependency ordering
- 13 tests covering init subscriptions, active counting, decomposition/verification result handling, and task event processing

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement GoalOrchestrator GenServer** - `b61e407` (feat)
2. **Task 2: Wire GoalOrchestrator into HubFSM and supervision tree** - `2743ebf` (feat)

## Files Created/Modified
- `lib/agent_com/goal_orchestrator.ex` - Central orchestration GenServer with tick-driven goal lifecycle, Task.async LLM calls, PubSub monitoring
- `test/agent_com/goal_orchestrator_test.exs` - 13 tests for GenServer lifecycle, async result handling, PubSub events
- `lib/agent_com/hub_fsm.ex` - Added GoalOrchestrator.tick/0 call in :executing :stay branch with try/catch safety
- `lib/agent_com/application.ex` - Added GoalOrchestrator to supervision tree between GoalBacklog and HubFSM

## Decisions Made
- Single pending_async slot instead of multiple concurrent async tasks -- respects ClaudeClient serial GenServer queue and simplifies state tracking
- Verification before decomposition in tick priority -- completing goals frees resources faster than starting new ones
- Process.demonitor with :flush on Task.async result receipt prevents double-handling via stale DOWN messages

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 30 (goal decomposition and inner loop) is now complete
- Full autonomous loop wired: HubFSM tick -> GoalOrchestrator.tick -> dequeue/decompose/monitor/verify
- Ready for Phase 31 (hub event wiring) to add webhook-driven goal submission

## Self-Check: PASSED

- All 4 created/modified files verified on disk
- Both task commits (b61e407, 2743ebf) verified in git log

---
*Phase: 30-goal-decomposition-and-inner-loop*
*Completed: 2026-02-14*
