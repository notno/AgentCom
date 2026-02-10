---
phase: 03-agent-state
plan: 02
subsystem: agent-state
tags: [websocket, fsm-wiring, presence, http-api, task-reclaim, plug-router]

# Dependency graph
requires:
  - phase: 03-agent-state
    provides: "AgentFSM GenServer and AgentSupervisor from Plan 01"
  - phase: 02-task-queue
    provides: "TaskQueue GenServer with assign/complete/fail API"
provides:
  - "Socket starts/stops AgentFSM on connect/disconnect with reconnect handling"
  - "Socket forwards task_accepted/task_complete/task_failed/assign events to AgentFSM"
  - "TaskQueue.reclaim_task/1 for idempotent task reclamation on disconnect/timeout"
  - "Presence.update_fsm_state/2 for real-time FSM state in Presence cache"
  - "GET /api/agents includes fsm_state field (backward-compatible)"
  - "GET /api/agents/states returns all agent FSM states (auth required)"
  - "GET /api/agents/:id/state returns detailed FSM state (auth required)"
affects: [04-scheduler, 05-smoke-test]

# Tech tracking
tech-stack:
  added: []
  patterns: [Socket-to-FSM event forwarding, idempotent task reclamation with generation bump, Presence FSM state push on transitions]

key-files:
  created: []
  modified:
    - lib/agent_com/socket.ex
    - lib/agent_com/task_queue.ex
    - lib/agent_com/agent_fsm.ex
    - lib/agent_com/endpoint.ex
    - lib/agent_com/presence.ex

key-decisions:
  - "Socket.terminate does NOT clean up FSM -- AgentFSM's :DOWN handler owns task reclamation (clear ownership per Pitfall 3)"
  - "Presence.update_fsm_state does NOT broadcast to PubSub -- FSM state changes are frequent and internal, queryable via HTTP"
  - "AgentFSM get_state reply includes name field for HTTP endpoint use"

patterns-established:
  - "Socket-to-FSM forwarding: Socket handlers call AgentFSM.task_accepted/completed/failed after TaskQueue operations"
  - "Idempotent reclaim: TaskQueue.reclaim_task/1 only reclaims :assigned tasks, returns :not_assigned for already-completed"
  - "Presence FSM push: AgentFSM calls Presence.update_fsm_state on init, transition, and :DOWN (offline)"
  - "Route ordering: specific paths (/states) before parameterized (/:agent_id/state) before existing (/:agent_id/subscriptions)"

# Metrics
duration: 3min
completed: 2026-02-10
---

# Phase 3 Plan 2: AgentFSM Integration Wiring Summary

**Socket-to-FSM lifecycle wiring, idempotent task reclamation via TaskQueue.reclaim_task/1, Presence FSM state push, and HTTP agent state query endpoints**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-10T16:25:16Z
- **Completed:** 2026-02-10T16:28:30Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Socket starts AgentFSM on connect and handles reconnect by stopping old FSM before creating new one
- Socket forwards all task lifecycle events (assign, accepted, complete, failed) to AgentFSM for state synchronization
- TaskQueue.reclaim_task/1 provides idempotent task reclamation with generation bump and priority index re-add
- Presence stores fsm_state updated by AgentFSM on every state transition (init, transition, disconnect)
- HTTP API exposes agent FSM state via existing /api/agents (with fsm_state field) and new dedicated endpoints

## Task Commits

Each task was committed atomically:

1. **Task 1: Wire Socket to AgentFSM lifecycle and add reclaim_task to TaskQueue** - `78837eb` (feat)
2. **Task 2: Add HTTP agent state endpoints and wire AgentFSM to Presence** - `60bcc38` (feat)

## Files Created/Modified
- `lib/agent_com/socket.ex` - FSM startup on identify, reconnect handling, task event forwarding to AgentFSM
- `lib/agent_com/task_queue.ex` - Added reclaim_task/1 public API and handle_call for idempotent task reclamation
- `lib/agent_com/agent_fsm.ex` - Real reclaim_task call replacing stub, Presence push on transitions, name in get_state
- `lib/agent_com/endpoint.ex` - GET /api/agents/states, GET /api/agents/:id/state, fsm_state in /api/agents
- `lib/agent_com/presence.ex` - update_fsm_state/2 function and handle_cast for FSM state storage

## Decisions Made
- **Socket.terminate does NOT clean up FSM** -- AgentFSM's :DOWN handler owns task reclamation, avoiding duplicate cleanup (Pitfall 3 from research: clear ownership)
- **Presence.update_fsm_state does NOT broadcast to PubSub** -- FSM state changes are frequent and internal; the existing :status_changed broadcast remains for human-visible status updates
- **AgentFSM get_state includes name field** -- needed by the new HTTP endpoints to return agent display name

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Added name field to AgentFSM get_state reply**
- **Found during:** Task 2 (HTTP endpoint implementation)
- **Issue:** The endpoint template in the plan references `agent_state.name` but the existing get_state reply from Plan 01 did not include the `name` field
- **Fix:** Added `name: state.name` to the get_state reply map in AgentFSM
- **Files modified:** lib/agent_com/agent_fsm.ex
- **Verification:** mix compile produces zero errors; endpoint can access agent_state.name
- **Committed in:** 60bcc38 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** Trivial addition of existing field to reply map. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 3 (Agent State) is fully complete -- both infrastructure (Plan 01) and wiring (Plan 02) done
- Scheduler (Phase 4) can use AgentFSM.list_all, get_capabilities, assign_task for intelligent task routing
- All agent state is queryable via HTTP API for monitoring and debugging
- TaskQueue.reclaim_task/1 is ready for any future disconnect/timeout reclamation paths

## Self-Check: PASSED

All artifacts verified:
- lib/agent_com/socket.ex: FOUND
- lib/agent_com/task_queue.ex: FOUND
- lib/agent_com/agent_fsm.ex: FOUND
- lib/agent_com/endpoint.ex: FOUND
- lib/agent_com/presence.ex: FOUND
- 03-02-SUMMARY.md: FOUND
- Commit 78837eb: FOUND
- Commit 60bcc38: FOUND

---
*Phase: 03-agent-state*
*Completed: 2026-02-10*
