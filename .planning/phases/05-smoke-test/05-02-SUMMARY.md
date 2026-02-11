---
phase: 05-smoke-test
plan: 02
subsystem: testing
tags: [smoke-test, exunit, websocket, failure-recovery, load-distribution, priority-scheduling]

# Dependency graph
requires:
  - phase: 05-smoke-test
    plan: 01
    provides: "Smoke test infrastructure (AgentSim, Http helpers, Assertions, Setup)"
  - phase: 01-sidecar
    provides: "Sidecar task lifecycle with generation tracking"
  - phase: 02-task-queue
    provides: "TaskQueue DETS persistence with generation fencing and priority ordering"
  - phase: 03-agent-state
    provides: "AgentFSM process monitoring, task reclamation on :DOWN"
  - phase: 04-scheduler
    provides: "Event-driven task-to-agent matching with greedy loop"
provides:
  - "TEST-01: Basic pipeline validation -- 10 tasks across 2 agents with latency and token assertions"
  - "TEST-02: Failure recovery validation -- agent kill triggers task reclamation and reassignment"
  - "TEST-03: Scale distribution validation -- 4 agents, 20 tasks, even distribution, no priority starvation"
  - "Full end-to-end smoke test suite proving Phases 1-4 work correctly together"
  - "Fix: AgentFSM broadcasts :agent_idle to PubSub so Scheduler picks up newly-idle agents"
  - "Fix: AgentFSM.list_all catches :exit for FSMs stopping during query"
affects: [06-dashboard, 07-cli-tools, 08-documentation]

# Tech tracking
tech-stack:
  added: []
  patterns: [exunit-async-false-smoke-tests, polling-assertion-with-deadline, agent-kill-recovery-testing]

key-files:
  created:
    - test/smoke/basic_test.exs
    - test/smoke/failure_test.exs
    - test/smoke/scale_test.exs
    - test/test_helper.exs
  modified:
    - lib/agent_com/agent_fsm.ex
    - lib/agent_com/scheduler.ex
    - test/smoke/helpers/agent_sim.ex
    - test/smoke/helpers/setup.ex

key-decisions:
  - "AgentFSM broadcasts :agent_idle PubSub event on idle transition to fix scheduler race condition"
  - "AgentFSM.list_all catches :exit for FSMs stopping during enumeration (defensive against race)"
  - "Setup uses Supervisor.terminate_child/restart_child instead of GenServer.stop for clean DETS reset"
  - "AgentSim sends identify after WebSocket upgrade completes (not before) to fix connection sequencing"

patterns-established:
  - "Smoke test per scenario: basic_test.exs, failure_test.exs, scale_test.exs with async: false"
  - "Agent-before-task submission pattern: connect and identify agents before submitting tasks to avoid scheduler miss"
  - "Priority starvation check: submit mixed priorities and assert all levels reach :completed"

# Metrics
duration: 5min
completed: 2026-02-10
---

# Phase 5 Plan 2: Smoke Test Scenarios Summary

**3 ExUnit smoke test suites validating full pipeline: 10-task throughput, agent-kill recovery, and 4-agent scale distribution with priority fairness**

## Performance

- **Duration:** ~5 min (across 2 execution sessions with checkpoint)
- **Started:** 2026-02-10
- **Completed:** 2026-02-10
- **Tasks:** 3 (2 auto + 1 human-verify checkpoint)
- **Files modified:** 8

## Accomplishments
- TEST-01 passes: 10 tasks dispatched across 2 simulated WebSocket agents, all complete with under 5s assignment latency and under 500 token overhead
- TEST-02 passes: killing an agent mid-task triggers :DOWN in AgentFSM, task reclaimed and reassigned to survivor, no duplicate completions
- TEST-02b passes: 5 tasks across 2 agents, one killed, all 5 complete with no duplicates
- TEST-03 passes: 4 agents process 20 mixed-priority tasks with even distribution (each agent 3-7 tasks, within +/-2 of expected 5)
- TEST-03b passes: sequential alternating urgent/low submission proves low-priority tasks are not starved
- Fixed scheduler race condition: AgentFSM now broadcasts :agent_idle to PubSub so Scheduler picks up agents that become idle between event cycles
- Fixed AgentFSM.list_all crash: catches :exit for FSMs stopping during enumeration

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement TEST-01 basic pipeline and TEST-02 failure recovery tests** - `1da96b2` (feat)
2. **Task 2: Implement TEST-03 scale distribution test** - `64c38d0` (feat)
3. **Task 3: Verify all smoke tests pass** - checkpoint approved by user (no commit)

## Files Created/Modified
- `test/smoke/basic_test.exs` - TEST-01: 10 tasks across 2 agents, latency/token assertions
- `test/smoke/failure_test.exs` - TEST-02: agent kill recovery, no duplicate completions; TEST-02b: multi-task recovery
- `test/smoke/scale_test.exs` - TEST-03: 4 agents, 20 tasks, even distribution; TEST-03b: no starvation under sequential submission
- `test/test_helper.exs` - ExUnit configuration with smoke helper module compilation
- `lib/agent_com/agent_fsm.ex` - Broadcast :agent_idle to PubSub on idle transition; catch :exit in list_all
- `lib/agent_com/scheduler.ex` - Subscribe to :agent_idle PubSub events for newly-idle agents
- `test/smoke/helpers/agent_sim.ex` - Fix: send identify after WebSocket upgrade completes (not before)
- `test/smoke/helpers/setup.ex` - Fix: use Supervisor.terminate_child/restart_child for clean reset

## Decisions Made
- **AgentFSM :agent_idle broadcast:** The scheduler fires on task_submitted and task_reclaimed events, but if an agent becomes idle (e.g., after completing a task) while tasks are already queued, nothing triggers a match attempt. Adding :agent_idle broadcast fixes this race.
- **Defensive list_all:** AgentFSM processes can terminate between Registry.select and GenServer.call. Catching :exit prevents cascading failures during test cleanup and production usage.
- **Setup cleanup via Supervisor:** Using GenServer.stop on supervised children caused restart loops. Supervisor.terminate_child + restart_child cleanly resets DETS tables.
- **Identify-after-upgrade sequencing:** AgentSim was sending the identify frame before the WebSocket upgrade completed, causing protocol errors. Moved identify to post-upgrade callback.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] AgentSim identify sent before WebSocket upgrade**
- **Found during:** Task 1 (basic pipeline test)
- **Issue:** AgentSim was sending identify frame before WebSocket handshake completed, causing connection failure
- **Fix:** Moved identify send to after WebSocket upgrade confirmation in AgentSim
- **Files modified:** test/smoke/helpers/agent_sim.ex
- **Verification:** AgentSim connects and identifies successfully in all smoke tests
- **Committed in:** 1da96b2

**2. [Rule 1 - Bug] Setup.reset_all caused restart loops with GenServer.stop**
- **Found during:** Task 1 (test setup)
- **Issue:** Calling GenServer.stop on supervised DETS processes triggered supervisor restarts with stale state
- **Fix:** Changed to Supervisor.terminate_child/restart_child for clean process lifecycle management
- **Files modified:** test/smoke/helpers/setup.ex
- **Verification:** DETS tables cleanly reset between test runs
- **Committed in:** 1da96b2

**3. [Rule 1 - Bug] AgentFSM.list_all crash on concurrent termination**
- **Found during:** Task 1 (failure recovery test)
- **Issue:** AgentFSM processes terminating during Registry enumeration caused unhandled :exit
- **Fix:** Added try/catch :exit around GenServer.call in list_all
- **Files modified:** lib/agent_com/agent_fsm.ex
- **Verification:** Failure tests no longer crash during agent cleanup
- **Committed in:** 1da96b2

**4. [Rule 1 - Bug] Scheduler race: idle agents missed when tasks already queued**
- **Found during:** Task 1 (basic pipeline test)
- **Issue:** Scheduler only fires on task_submitted and task_reclaimed. If agent becomes idle while tasks are queued, no match attempt occurs.
- **Fix:** AgentFSM broadcasts :agent_idle to PubSub; Scheduler subscribes and triggers match attempt
- **Files modified:** lib/agent_com/agent_fsm.ex, lib/agent_com/scheduler.ex
- **Verification:** All 10 tasks in TEST-01 complete without manual scheduling intervention
- **Committed in:** 1da96b2

---

**Total deviations:** 4 auto-fixed (4 bugs via Rule 1)
**Impact on plan:** All fixes were necessary for the smoke tests to exercise the real pipeline correctly. The scheduler race fix (#4) is a genuine production bug that would have affected real agent workloads. No scope creep.

## Issues Encountered

None beyond the auto-fixed deviations above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- All smoke tests pass: Phases 1-4 are validated end-to-end
- The system correctly handles: task submission, agent matching, WebSocket delivery, completion tracking, failure recovery, and priority scheduling
- Ready for Phase 6 (Dashboard), Phase 7 (CLI Tools), and Phase 8 (Documentation) which are independent of each other
- The :agent_idle PubSub fix improves production reliability beyond just test scenarios

## Self-Check: PASSED

- All 8 files verified present on disk (3 test files, 1 test_helper, 2 lib files, 2 helper files)
- Commit 1da96b2 verified (Task 1: basic pipeline + failure recovery tests)
- Commit 64c38d0 verified (Task 2: scale distribution test)
- Task 3 checkpoint approved by user (all smoke tests pass)

---
*Phase: 05-smoke-test*
*Completed: 2026-02-10*
