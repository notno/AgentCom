---
phase: 09-testing
plan: 02
subsystem: testing
tags: [genserver, exunit, task-queue, agent-fsm, scheduler, pubsub, dets]

# Dependency graph
requires:
  - phase: 09-testing-01
    provides: DetsHelpers, TestFactory, config/test.exs DETS isolation infrastructure
provides:
  - 40 TaskQueue unit tests covering full task lifecycle
  - 20 AgentFSM unit tests covering state machine transitions and cleanup
  - 9 Scheduler unit tests covering event-driven matching and capability filtering
affects: [09-testing, 10-persistence, 11-compaction]

# Tech tracking
tech-stack:
  added: []
  patterns: [Scheduler stop/restart for GenServer isolation, mailbox drain for PubSub test hygiene, DynamicSupervisor child cleanup between tests]

key-files:
  created:
    - test/agent_com/task_queue_test.exs
    - test/agent_com/agent_fsm_test.exs
    - test/agent_com/scheduler_test.exs
  modified:
    - lib/agent_com/task_queue.ex

key-decisions:
  - "Stop Scheduler in TaskQueue/AgentFSM tests to prevent PubSub auto-assignment interference"
  - "Drain test process mailbox in Scheduler tests to eliminate stale PubSub message leakage"
  - "Kill DynamicSupervisor FSM children in setup to prevent agent leaks between tests"
  - "Manually drive FSM through assign/accept in multi-agent Scheduler test since dummy ws_pid doesn't relay push_task"

patterns-established:
  - "Scheduler terminate/restart pattern for isolated GenServer unit testing"
  - "DynamicSupervisor.which_children cleanup in setup for process leak prevention"
  - "drain_mailbox/0 helper for PubSub test isolation"
  - "Direct send to GenServer pid for testing timer-based behavior (sweep_overdue, acceptance_timeout)"

# Metrics
duration: 6min
completed: 2026-02-12
---

# Phase 9 Plan 2: Critical GenServer Unit Tests Summary

**69 unit tests for TaskQueue (40), AgentFSM (20), and Scheduler (9) covering task lifecycle, state machine transitions, generation fencing, dead-letter flow, and event-driven scheduling with capability matching**

## Performance

- **Duration:** 6 min
- **Started:** 2026-02-12T04:17:49Z
- **Completed:** 2026-02-12T04:23:33Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- TaskQueue tests cover submit (priorities, defaults, id format), get, assign, complete (generation fencing), fail (retry + dead-letter), sweep_overdue, reclaim, dequeue_next, retry_dead_letter, stats, and list filtering
- AgentFSM tests cover init state, capabilities normalization, full lifecycle (idle -> assigned -> working -> idle), blocked/unblocked transitions, ws_pid DOWN cleanup with task reclamation, acceptance timeout with :unresponsive flag, and stale timeout rejection
- Scheduler tests cover idle agent matching via PubSub events, capability filtering (matching, non-matching, empty), no-idle-agents/empty-queue edge cases, multi-agent assignment, and PubSub broadcast verification
- Fixed missing :last_error key in TaskQueue task submit map that caused KeyError crashes on fail_task

## Task Commits

Each task was committed atomically:

1. **Task 1: Write TaskQueue deep unit tests** - `6a2fdee` (test)
2. **Task 2: Write AgentFSM and Scheduler deep unit tests** - `3f96b81` (test)

## Files Created/Modified
- `test/agent_com/task_queue_test.exs` - 40 tests covering TaskQueue GenServer full API
- `test/agent_com/agent_fsm_test.exs` - 20 tests covering AgentFSM state machine lifecycle
- `test/agent_com/scheduler_test.exs` - 9 tests covering event-driven task-to-agent scheduling
- `lib/agent_com/task_queue.ex` - Added missing `last_error: nil` to task submit map

## Decisions Made
- Stopped Scheduler in TaskQueue and AgentFSM setup blocks to prevent PubSub auto-assignment interference (Pitfall #3 from research)
- Used `DynamicSupervisor.which_children` + `terminate_child` in Scheduler test setup to kill leftover FSM processes from prior tests
- Added `drain_mailbox/0` helper to flush stale PubSub messages between Scheduler tests
- In multi-agent Scheduler test, manually drove FSM through assign/accept cycle because dummy ws_pid doesn't relay `:push_task` messages back to FSM

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed missing :last_error key in TaskQueue task submit map**
- **Found during:** Task 1 (TaskQueue unit tests)
- **Issue:** The task map created in `handle_call({:submit, ...})` did not include `:last_error` field. When `fail_task` tried to update it with `%{task | last_error: error}`, Elixir raised `KeyError` because map update syntax requires the key to exist.
- **Fix:** Added `last_error: nil` to the initial task map in the submit handler.
- **Files modified:** lib/agent_com/task_queue.ex
- **Verification:** All 40 TaskQueue tests pass including fail_task dead-letter path
- **Committed in:** 6a2fdee (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Essential fix -- without it, any task failure would crash the TaskQueue GenServer. No scope creep.

## Issues Encountered
- Pre-existing compiler warnings (8 total in analytics.ex, mailbox.ex, router.ex, socket.ex, endpoint.ex) remain. These are not related to test code.
- AgentFSM tests generate an `unused alias TestFactory` warning since the helper function `start_agent` bypasses TestFactory for simpler agent creation. This is cosmetic only.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Critical path GenServer tests are complete -- TaskQueue, AgentFSM, and Scheduler all have deep coverage
- Test isolation patterns (Scheduler stop/restart, mailbox drain, FSM cleanup) are proven and reusable
- Ready for integration tests (09-03) and remaining unit test plans
- The :last_error bug fix may affect any code that catches TaskQueue.fail_task errors in production

## Self-Check: PASSED

All 4 created/modified files verified on disk. Both task commits (6a2fdee, 3f96b81) verified in git log.

---
*Phase: 09-testing*
*Completed: 2026-02-12*
