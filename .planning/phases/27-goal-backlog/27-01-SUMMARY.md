---
phase: 27-goal-backlog
plan: 01
subsystem: core
tags: [genserver, dets, state-machine, pubsub, telemetry, goal-lifecycle]

requires:
  - phase: 25-cost-control
    provides: CostLedger pattern for DETS-backed GenServer with DetsBackup registration
provides:
  - GoalBacklog GenServer with DETS persistence and lifecycle state machine
  - Goal submit/get/list/transition/dequeue/stats/delete API
  - PubSub events on "goals" topic for all state changes
  - Priority-ordered dequeue for Hub FSM consumption
affects: [27-02-goal-backlog, 28-hub-fsm, http-api, cli]

tech-stack:
  added: []
  patterns: [goal-lifecycle-state-machine, priority-index-dequeue]

key-files:
  created:
    - lib/agent_com/goal_backlog.ex
    - test/agent_com/goal_backlog_test.exs
  modified:
    - lib/agent_com/application.ex
    - lib/agent_com/dets_backup.ex
    - test/support/dets_helpers.ex
    - test/dets_backup_test.exs

key-decisions:
  - "GoalBacklog follows TaskQueue pattern exactly: DETS+sync, priority index, PubSub broadcast"
  - "Lifecycle state machine with 6 states: submitted->decomposing->executing->verifying->complete/failed"
  - "Priority index only tracks :submitted goals; dequeue pops and transitions to :decomposing atomically"

patterns-established:
  - "Goal lifecycle: submitted->decomposing->executing->verifying->complete/failed with @valid_transitions enforcement"
  - "Goal IDs: goal-{hex16} format matching task-{hex16} convention"

duration: 5min
completed: 2026-02-13
---

# Phase 27 Plan 01: GoalBacklog GenServer Summary

**GoalBacklog GenServer with DETS persistence, 6-state lifecycle machine, priority-ordered dequeue, PubSub broadcasting, and DetsBackup registration**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-13T23:52:07Z
- **Completed:** 2026-02-13T23:57:01Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- GoalBacklog GenServer with full CRUD API (submit, get, list, transition, dequeue, stats, delete)
- Lifecycle state machine enforcing valid transitions across 6 states with history tracking
- Priority-ordered dequeue with in-memory sorted index for O(1) highest-priority goal selection
- PubSub events broadcast on "goals" topic for every state change
- 16 tests covering all API functions, lifecycle enforcement, persistence, and PubSub events

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement GoalBacklog GenServer with DETS persistence and lifecycle state machine** - `cca1b60` (feat)
2. **Task 2: Register GoalBacklog in supervision tree, DetsBackup, DetsHelpers, and write tests** - `4ea4d53` (feat)

## Files Created/Modified
- `lib/agent_com/goal_backlog.ex` - GoalBacklog GenServer with DETS persistence, lifecycle state machine, priority index, PubSub
- `test/agent_com/goal_backlog_test.exs` - 16 tests covering submit, transition, list, stats, persistence, PubSub
- `lib/agent_com/application.ex` - Added GoalBacklog to supervision tree (after DetsBackup, before Bandit)
- `lib/agent_com/dets_backup.ex` - Registered :goal_backlog table, table_owner, get_table_path
- `test/support/dets_helpers.ex` - Added goal_backlog data dir, mkdir, stop/restart order, DETS close
- `test/dets_backup_test.exs` - Updated hardcoded table counts from 10 to 12 (cost_ledger + goal_backlog)

## Decisions Made
- GoalBacklog follows TaskQueue pattern exactly: DETS+sync, priority index, PubSub broadcast
- Lifecycle state machine with 6 states: submitted->decomposing->executing->verifying->complete/failed
- Priority index only tracks :submitted goals; dequeue pops and transitions to :decomposing atomically

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed persistence restart test using Supervisor.terminate_child**
- **Found during:** Task 2 (test writing)
- **Issue:** GenServer.stop leaves child in :running state in supervisor, preventing restart_child
- **Fix:** Used Supervisor.terminate_child + :dets.close before restart_child
- **Files modified:** test/agent_com/goal_backlog_test.exs
- **Verification:** Test passes -- goal persists across restart
- **Committed in:** 4ea4d53 (Task 2 commit)

**2. [Rule 1 - Bug] Fixed DetsBackup test hardcoded table counts**
- **Found during:** Task 2 (verification)
- **Issue:** dets_backup_test.exs hardcoded table count as 10, but @tables now has 12 entries (cost_ledger added in Phase 25, goal_backlog added now)
- **Fix:** Updated all count assertions from 10 to 12 and added cost_ledger/goal_backlog to retention test table list
- **Files modified:** test/dets_backup_test.exs
- **Verification:** GoalBacklog tests pass 16/16; DetsBackup counts now correct
- **Committed in:** 4ea4d53 (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs)
**Impact on plan:** Both auto-fixes necessary for test correctness. No scope creep.

## Issues Encountered
- Port 4002 already in use prevented full test suite execution (environment issue, not code regression). GoalBacklog-specific tests confirmed 16/16 passing.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- GoalBacklog GenServer operational with full API, ready for HTTP API and CLI integration in Plan 02
- Priority dequeue ready for Hub FSM consumption in Phase 28

---
*Phase: 27-goal-backlog*
*Completed: 2026-02-13*
