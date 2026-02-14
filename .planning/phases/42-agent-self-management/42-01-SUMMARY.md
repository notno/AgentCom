---
phase: 42-agent-self-management
plan: 01
subsystem: infra
tags: [pm2, process-management, websocket, restart, sidecar]

requires:
  - phase: 01-foundation
    provides: sidecar WebSocket connection, hub socket handler
provides:
  - pm2-manager module for sidecar self-awareness and graceful restart
  - Hub-commanded restart via WebSocket and HTTP API
  - Agent restarting status tracking in Presence
affects: [healing-state, dashboard, monitoring]

tech-stack:
  added: []
  patterns: [pm2-cli-discovery, deferred-restart, hub-commanded-restart]

key-files:
  created:
    - sidecar/lib/pm2-manager.js
    - sidecar/test/pm2-manager.test.js
  modified:
    - sidecar/index.js
    - sidecar/ecosystem.config.js
    - lib/agent_com/socket.ex
    - lib/agent_com/endpoint.ex

key-decisions:
  - "PM2_PROCESS_NAME env var as primary identification source (fast, no subprocess)"
  - "Deferred restart pattern: set flag when task active, check after completion"
  - "process.exit(0) for restart -- let pm2 auto-restart handle lifecycle"

patterns-established:
  - "Deferred restart: gracefulRestart sets _pendingRestart flag, checked in handleResult/executeTask"
  - "Hub-to-sidecar command: handle_info in socket.ex pushes message, sidecar switch case handles"

duration: 9 min
completed: 2026-02-14
---

# Phase 42 Plan 01: Agent Self-Management Summary

**pm2 self-awareness module with hub-commanded graceful restart via WebSocket and HTTP API**

## Performance

- **Duration:** 9 min
- **Started:** 2026-02-14T18:47:02Z
- **Completed:** 2026-02-14T18:56:46Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- Created pm2-manager.js with 6 exports for process identity, status, info, and graceful restart
- Wired restart_sidecar WebSocket message handling into sidecar with deferred restart during active tasks
- Added hub-side restart command support (socket.ex handle_info + endpoint.ex POST /api/admin/agents/:id/restart)
- Sidecar includes pm2 info in identify payload for dashboard visibility

## Task Commits

Each task was committed atomically:

1. **Task 1: Create pm2-manager module and update ecosystem.config.js** - `53ca66e` (feat)
2. **Task 2: Wire pm2-manager into sidecar and add hub-side restart support** - `e771693` (feat)

## Files Created/Modified
- `sidecar/lib/pm2-manager.js` - pm2 self-awareness: getProcessName, getStatus, getInfo, gracefulRestart, hasPendingRestart, clearPendingRestart
- `sidecar/test/pm2-manager.test.js` - Unit tests for pm2-manager (5 tests, node:test runner)
- `sidecar/ecosystem.config.js` - Added PM2_PROCESS_NAME env var
- `sidecar/index.js` - require pm2Manager, restart_sidecar case, pending restart checks in handleResult/executeTask, pm2Info in identify
- `lib/agent_com/socket.ex` - :restart_sidecar handle_info push, agent_restarting message handler with Presence update
- `lib/agent_com/endpoint.ex` - POST /api/admin/agents/:agent_id/restart (auth required)

## Decisions Made
- Used PM2_PROCESS_NAME env var as primary source (no subprocess needed for common case)
- Deferred restart sets a module-level flag checked after task completion (both file-watcher and direct-execution paths)
- 500ms setTimeout before process.exit(0) ensures WebSocket message flushes

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed pre-existing validation test count mismatch**
- **Found during:** Task 2 (verification step: mix test)
- **Issue:** Test expected 17 message types but schemas had 19 (state_report + wake_result added in Phases 39-40)
- **Fix:** Updated test to expect 19 types and include state_report + wake_result
- **Files modified:** test/agent_com/validation_test.exs
- **Verification:** mix test passes
- **Committed in:** e771693

**2. [Rule 3 - Blocking] Fixed Prompt.build/3 missing function and Response.parse_ollama/2**
- **Found during:** Task 2 (verification step: mix compile --warnings-as-errors)
- **Issue:** claude_client.ex calls build/3 and parse_ollama/2 but only build/2 and parse/3 existed
- **Fix:** Added build/3 delegation and parse_ollama/2 wrapper
- **Files modified:** lib/agent_com/claude_client/prompt.ex, lib/agent_com/claude_client/response.ex
- **Verification:** mix compile --warnings-as-errors passes
- **Committed in:** e771693

---

**Total deviations:** 2 auto-fixed (1 bug, 1 blocking)
**Impact on plan:** Both pre-existing issues unrelated to Phase 42 scope. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 42 complete, sidecar can query its own pm2 identity and restart on hub command
- Ready for healing state integration (future phase can use POST /api/admin/agents/:id/restart)
- Dashboard can display pm2_info from identify payload

---
*Phase: 42-agent-self-management*
*Completed: 2026-02-14*
