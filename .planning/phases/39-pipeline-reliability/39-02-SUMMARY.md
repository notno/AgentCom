---
phase: 39-pipeline-reliability
plan: 02
subsystem: sidecar, hub
tags: [timeout, stuck-detection, generation, websocket, pipeline]

requires:
  - phase: 39-pipeline-reliability
    provides: wake_result message protocol (Plan 01)
provides:
  - Execution timeout via Promise.race (PIPE-02)
  - Agent-aware stuck detection with 10min threshold (PIPE-03)
  - Generation check before executing (PIPE-04)
  - Hub wake_result message handler
  - wake_result validation schema
affects: [39-03, 43-hub-fsm-healing]

tech-stack:
  added: []
  patterns: [promise-race-timeout, agent-aware-stuck-sweep, generation-fencing]

key-files:
  created: []
  modified:
    - sidecar/index.js
    - lib/agent_com/scheduler.ex
    - lib/agent_com/socket.ex
    - lib/agent_com/validation/schemas.ex

key-decisions:
  - "Timeout values: 10min trivial, 30min standard/complex -- simple tier-based lookup"
  - "Stuck threshold: 10min (was 5min), working agents get 2x patience (20min)"
  - "wake_result handler is fire-and-forget (no reply), just logs and updates progress"

patterns-established:
  - "Promise.race timeout: always clearTimeout on both success and failure paths"
  - "Agent-aware reclaim: offline=immediate, working=2x patience, unexpected=reclaim"
  - "Generation check at executeTask entry prevents stale assignment execution"

duration: 4 min
completed: 2026-02-14
---

# Phase 39 Plan 02: Execution Timeouts, Stuck Detection, Generation Checks Summary

**Promise.race execution timeout, agent-aware stuck sweep with 10min threshold, generation fencing, and hub wake_result handler**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-14T12:03:00Z
- **Completed:** 2026-02-14T12:07:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- executeTask() wraps executeWithVerification in Promise.race with tier-based timeout (10min trivial, 30min standard/complex)
- Generation check at executeTask entry skips stale assignments
- Stuck sweep threshold increased from 5min to 10min, checks agent FSM state before reclaiming
- Hub handles wake_result messages (from Plan 39-01) by logging and updating task progress
- wake_result added to validation schemas

## Task Commits

Each task was committed atomically:

1. **Task 1: PIPE-02 execution timeout + PIPE-04 generation check** - `c17e639` (feat)
2. **Task 2: PIPE-03 agent-aware stuck detection + hub wake_result** - `8988f61` (feat)

**Plan metadata:** pending

## Files Created/Modified
- `sidecar/index.js` - Promise.race timeout wrapper, generation check before execute
- `lib/agent_com/scheduler.ex` - @stuck_threshold_ms 600_000, AgentFSM.get_state check before reclaim
- `lib/agent_com/socket.ex` - wake_result handle_msg clause
- `lib/agent_com/validation/schemas.ex` - wake_result schema definition

## Decisions Made
- Timeout tier lookup uses simple object: trivial=10min, standard=30min, complex=30min
- Stuck sweep differentiates 3 agent states: offline (immediate reclaim), working (2x patience), other (reclaim)
- wake_result is informational only -- hub logs and touches progress, no reply

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Execution protection complete, ready for Plan 39-03 (reconnect state recovery)
- Hub now handles wake_result messages without validation errors

---
*Phase: 39-pipeline-reliability*
*Completed: 2026-02-14*
