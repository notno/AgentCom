---
phase: 01-sidecar
plan: 04
subsystem: sidecar
tags: [node, crash-recovery, pm2, deployment, auto-update, cross-platform, process-management]

# Dependency graph
requires:
  - phase: 01-sidecar
    plan: 01
    provides: "HubConnection class with WebSocket connect, identify, reconnect, heartbeat, logging, config loader"
  - phase: 01-sidecar
    plan: 03
    provides: "Queue manager with atomic persistence, task lifecycle handling, wake command execution"
provides:
  - "Startup recovery logic: detect incomplete tasks in queue.json, move to recovering slot, report to hub"
  - "task_recovering message sent to hub after WebSocket identification"
  - "task_reassign handler: hub takes task back, sidecar clears recovering state"
  - "task_continue handler: hub says keep working, sidecar moves recovering back to active"
  - "pm2 ecosystem.config.js with auto-restart, memory limits, structured logging"
  - "start.sh (Linux) and start.bat (Windows) wrapper scripts with git pull auto-update"
  - "Setup instructions for pm2 + pm2-logrotate + pm2-installer (Windows)"
affects: [02-task-queue, 05-smoke-test]

# Tech tracking
tech-stack:
  added: [pm2]
  patterns: [crash-recovery-with-recovering-slot, auto-update-on-restart, cross-platform-wrapper-scripts]

key-files:
  created:
    - sidecar/ecosystem.config.js
    - sidecar/start.sh
    - sidecar/start.bat
  modified:
    - sidecar/index.js

key-decisions:
  - "Recovery reports task_recovering AFTER WebSocket identification (needs connection to send message)"
  - "task_reassign is default Phase 1 behavior; task_continue reserved for Phase 2+ intelligence"
  - "Wrapper scripts handle git pull failure gracefully (continue with current version if offline)"
  - "pm2 interpreter set dynamically via process.platform for cross-platform ecosystem config"

patterns-established:
  - "Recovering slot pattern: queue holds max 1 active + 1 recovering task, crash moves active to recovering"
  - "Post-identification hook: recovery reporting happens in handleMessage after 'identified' message"
  - "Auto-update-on-restart: wrapper script does git pull + npm install before exec node"
  - "Cross-platform pm2: single ecosystem.config.js with platform-conditional script/interpreter fields"

# Metrics
duration: 2min
completed: 2026-02-10
---

# Phase 1 Plan 4: Startup Recovery and Deployment Summary

**Crash recovery with queue.json recovering slot and task_recovering hub reporting, plus pm2 ecosystem config with cross-platform auto-update wrapper scripts**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-10T06:11:24Z
- **Completed:** 2026-02-10T06:13:43Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Startup recovery logic: detects incomplete tasks in queue.json, moves active to recovering slot, reports task_recovering to hub after WebSocket identification
- Hub response handlers: task_reassign (hub takes task back, clears recovering) and task_continue (move back to active, resume watching)
- pm2 ecosystem.config.js with auto-restart (max 50 restarts, 2s delay), 200M memory limit, and structured log output
- Cross-platform wrapper scripts: start.sh (Linux, uses exec for proper pm2 monitoring) and start.bat (Windows) both perform git pull + npm install before launching
- Setup instructions documented in ecosystem.config.js comments covering pm2-logrotate and Windows pm2-installer

## Task Commits

Each task was committed atomically:

1. **Task 1: Add startup recovery logic for incomplete tasks** - `a52da66` (feat)
2. **Task 2: Create pm2 ecosystem config and wrapper scripts for deployment** - `cf0cb21` (feat)

**Plan metadata:** (pending final commit)

## Files Created/Modified
- `sidecar/index.js` - Extended from 718 to 791 lines: recovery logic in main(), reportRecovery(), handleTaskReassign(), handleTaskContinue() methods, task_reassign/task_continue message handlers
- `sidecar/ecosystem.config.js` - pm2 process config with auto-restart, memory limits, log settings, and cross-platform script/interpreter selection
- `sidecar/start.sh` - Linux wrapper: git pull --ff-only, npm install --production, mkdir -p results logs, exec node index.js
- `sidecar/start.bat` - Windows wrapper: git pull --ff-only, npm install --production, mkdir results/logs, node index.js

## Decisions Made
- Recovery reports task_recovering AFTER WebSocket identification -- needs the connection to send the message, and the hub needs to know the sidecar's identity before processing recovery
- task_reassign is the default Phase 1 response (hub takes task back); task_continue handler is in place for Phase 2+ when the hub gains intelligence to decide whether the agent is still working
- Wrapper scripts handle git pull and npm install failures gracefully (echo warning, continue with current version) -- sidecar should start even if offline
- pm2 ecosystem.config.js uses process.platform to dynamically select start.bat vs start.sh and cmd vs /bin/bash interpreter -- single config file works on both platforms

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required. pm2 setup instructions are documented as comments in ecosystem.config.js.

## Next Phase Readiness
- Phase 1 (Sidecar) is now complete: all 4 plans executed
- Full task lifecycle: receive -> persist -> wake -> confirm -> watch -> report -> cleanup
- Full recovery lifecycle: crash -> restart -> detect -> report -> hub decides -> clear
- Full deployment story: pm2 managed with auto-restart, auto-update, log rotation, cross-platform
- Ready for Phase 2 (Task Queue) hub-side integration and Phase 5 (Smoke Test) end-to-end validation

## Self-Check: PASSED

- [x] sidecar/index.js exists (791 lines)
- [x] sidecar/ecosystem.config.js exists
- [x] sidecar/start.sh exists
- [x] sidecar/start.bat exists
- [x] Commit a52da66 found (Task 1)
- [x] Commit cf0cb21 found (Task 2)
- [x] task_recovering pattern present in index.js
- [x] agentcom-sidecar pattern present in ecosystem.config.js
- [x] git pull pattern present in start.sh and start.bat
- [x] Syntax check passes for index.js and ecosystem.config.js

---
*Phase: 01-sidecar*
*Completed: 2026-02-10*
