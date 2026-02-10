---
phase: 01-sidecar
plan: 02
subsystem: api
tags: [websocket, elixir, task-protocol, pubsub, registry]

# Dependency graph
requires:
  - phase: 01-sidecar
    provides: "Existing WebSocket handler (socket.ex) and HTTP endpoint (endpoint.ex) from hub"
provides:
  - "WebSocket handlers for sidecar task lifecycle messages (task_accepted, task_progress, task_complete, task_failed, task_recovering)"
  - "task_assign push capability via handle_info :push_task"
  - "POST /api/admin/push-task endpoint for testing task assignment flow"
  - "PubSub broadcast on tasks topic for all task events"
affects: [01-sidecar, 02-task-queue, 05-smoke-test]

# Tech tracking
tech-stack:
  added: []
  patterns: [task-lifecycle-protocol, registry-lookup-send-pattern, pubsub-task-events]

key-files:
  created: []
  modified:
    - lib/agent_com/socket.ex
    - lib/agent_com/endpoint.ex

key-decisions:
  - "Task IDs auto-generated using crypto.strong_rand_bytes (consistent with existing auth token pattern)"
  - "task_progress is fire-and-forget (no ack) to reduce chattiness for frequent progress updates"
  - "task_recovering triggers task_reassign response (hub takes task back) -- Phase 2 will add intelligence"
  - "Push-task endpoint uses existing RequireAuth plug -- any authenticated agent can push (scheduler replaces this in Phase 2)"

patterns-established:
  - "Task lifecycle protocol: sidecar reports status via typed messages, hub acks with task_ack"
  - "Task push pattern: endpoint looks up agent PID via Registry, sends {:push_task, task}, Socket handle_info pushes over WebSocket"
  - "Task event broadcasting: all task events broadcast to PubSub tasks topic for monitoring/dashboard consumption"

# Metrics
duration: 5min
completed: 2026-02-10
---

# Phase 1 Plan 2: Hub Task Protocol Summary

**WebSocket task lifecycle handlers (5 message types) with PubSub broadcasting and admin push-task HTTP endpoint for testing sidecar flow**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-10T05:48:30Z
- **Completed:** 2026-02-10T05:53:04Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Hub WebSocket handler now accepts all 5 sidecar task lifecycle messages (task_accepted, task_progress, task_complete, task_failed, task_recovering) with proper acknowledgment
- Socket can push task_assign messages to connected agents via handle_info :push_task pattern
- Admin push-task HTTP endpoint enables testing the full sidecar task flow before the Phase 2 scheduler exists
- All task events are broadcast to PubSub "tasks" topic for future dashboard/monitoring integration

## Task Commits

Each task was committed atomically:

1. **Task 1: Add sidecar message type handlers to Socket.ex** - `8d8acd4` (feat)
2. **Task 2: Add admin push-task HTTP endpoint** - `03137e6` (feat)

**Plan metadata:** (pending final commit)

## Files Created/Modified
- `lib/agent_com/socket.ex` - Added 5 task lifecycle message handlers, log_task_event helper with PubSub broadcast, handle_info for :push_task, and updated moduledoc with task protocol docs
- `lib/agent_com/endpoint.ex` - Added POST /api/admin/push-task endpoint with auth, Registry lookup, task ID generation, and updated moduledoc

## Decisions Made
- Task IDs auto-generated using crypto.strong_rand_bytes (consistent with existing auth token generation pattern in auth.ex)
- task_progress has no ack response (fire-and-forget) since progress updates are frequent and don't need confirmation
- task_recovering responds with task_reassign immediately -- Phase 2 will add logic to check if agent is still working on the task
- Push-task endpoint requires authentication but does not restrict to admin agents -- any authenticated agent can push (scheduler takes over in Phase 2)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - both tasks compiled cleanly on first attempt. All pre-existing compiler warnings remain unchanged.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Hub now accepts sidecar task messages and can push assignments -- ready for sidecar Node.js implementation (Plan 03)
- PubSub "tasks" topic is broadcasting events -- ready for dashboard/monitoring integration when needed
- Push-task endpoint provides testing capability for end-to-end sidecar flow validation

## Self-Check: PASSED

- [x] lib/agent_com/socket.ex - FOUND
- [x] lib/agent_com/endpoint.ex - FOUND
- [x] .planning/phases/01-sidecar/01-02-SUMMARY.md - FOUND
- [x] Commit 8d8acd4 (Task 1) - FOUND
- [x] Commit 03137e6 (Task 2) - FOUND

---
*Phase: 01-sidecar*
*Completed: 2026-02-10*
