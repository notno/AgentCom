---
phase: 01-sidecar
plan: 01
subsystem: sidecar
tags: [websocket, ws, node, reconnect, heartbeat, json-lines-logging]

# Dependency graph
requires: []
provides:
  - "sidecar/ project scaffold with ws, write-file-atomic, chokidar dependencies"
  - "HubConnection class with WebSocket connect, identify, exponential backoff reconnect"
  - "Heartbeat ping/pong monitoring (30s interval, 10s timeout)"
  - "Structured JSON-lines logging to configurable log file"
  - "Graceful shutdown on SIGINT/SIGTERM/SIGBREAK"
  - "Config loader with validation and config.json.example template"
affects: [01-02, 01-03, 01-04]

# Tech tracking
tech-stack:
  added: [ws 8.19.0, write-file-atomic 5.x, chokidar 3.6.x]
  patterns: [exponential-backoff-reconnect, json-lines-logging, hub-identify-protocol-reuse]

key-files:
  created:
    - sidecar/package.json
    - sidecar/config.json.example
    - sidecar/.gitignore
    - sidecar/index.js
    - sidecar/package-lock.json
  modified: []

key-decisions:
  - "Reuse existing hub identify protocol with client_type: sidecar field (backward-compatible)"
  - "Add protocol_version: 1 to all outgoing messages for forward-compatibility"
  - "Use chokidar v3 (CJS-compatible) not v4 (ESM-only) matching codebase conventions"
  - "Use write-file-atomic v5 (latest CJS-compatible version)"

patterns-established:
  - "HubConnection class pattern: connect/identify/reconnect/heartbeat/shutdown lifecycle"
  - "Structured log format: JSON-lines with ts, event, agent_id, plus event-specific data"
  - "Config loading: fs.readFileSync from __dirname/config.json with required field validation"
  - "Exponential backoff: 1s -> 2s -> 4s -> 8s -> 16s -> 32s -> 60s cap"

# Metrics
duration: 3min
completed: 2026-02-10
---

# Phase 1 Plan 1: Sidecar Core Connection Summary

**Node.js sidecar with persistent WebSocket hub connection, exponential backoff reconnect (1s-60s cap), heartbeat ping/pong monitoring, and structured JSON-lines logging**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-10T05:48:28Z
- **Completed:** 2026-02-10T05:51:30Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Scaffolded sidecar/ project with ws, write-file-atomic, and chokidar dependencies installed
- Implemented HubConnection class with WebSocket connect, identify (reuses existing hub protocol), and exponential backoff reconnect
- Heartbeat monitoring: ping every 30s, pong timeout at 10s detects silent WebSocket death
- Structured JSON-lines logging to configurable log file plus console output for pm2 capture
- Graceful shutdown on SIGINT, SIGTERM, and SIGBREAK (Windows)
- Config loader with validation for required fields and helpful error message when config.json is missing

## Task Commits

Each task was committed atomically:

1. **Task 1: Create sidecar project scaffolding** - `ea8f6a2` (feat)
2. **Task 2: Implement core WebSocket connection with reconnect, heartbeat, config, logging, and shutdown** - `ab5a83d` (feat)

**Plan metadata:** `fbcab03` (docs: complete plan)

## Files Created/Modified
- `sidecar/package.json` - Node.js project with ws, write-file-atomic, chokidar dependencies
- `sidecar/package-lock.json` - Locked dependency versions (18 packages)
- `sidecar/config.json.example` - Configuration template with agent_id, token, hub_url, wake_command, capabilities, timeouts
- `sidecar/.gitignore` - Ignores runtime files (config.json, queue.json, sidecar.log, results/, logs/)
- `sidecar/index.js` - Core sidecar process (328 lines): config loading, structured logging, HubConnection class, graceful shutdown

## Decisions Made
- Reused existing hub identify protocol format, adding `client_type: "sidecar"` field -- hub ignores unknown fields so this is backward-compatible
- Added `protocol_version: 1` to all outgoing messages for forward-compatibility per research recommendation
- Used chokidar v3 (not v4) because v4 is ESM-only and the sidecar follows CJS conventions matching the existing codebase
- Used `ws.terminate()` (not `ws.close()`) for heartbeat timeout to force-close dead connections immediately
- Resolved relative config paths (log_file, results_dir) against __dirname for consistent behavior regardless of cwd

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- HubConnection class is ready for extension in Plan 02 (pm2 ecosystem, start scripts) and Plan 03 (task handling, queue management, wake commands)
- The `handleMessage` method has a default case for unhandled message types -- Plan 03 will add task_assign, task_reassign handlers
- Config template includes wake_command and results_dir fields that will be used in Plan 03

## Self-Check: PASSED

- [x] sidecar/package.json exists
- [x] sidecar/config.json.example exists
- [x] sidecar/.gitignore exists
- [x] sidecar/index.js exists (328 lines, min 150 required)
- [x] sidecar/package-lock.json exists
- [x] All dependencies load (ws, write-file-atomic, chokidar)
- [x] Commit ea8f6a2 found (Task 1)
- [x] Commit ab5a83d found (Task 2)
- [x] Reconnect backoff verified: 1s, 2s, 4s, 8s pattern observed
- [x] Structured JSON-lines log verified in sidecar.log
- [x] Config missing error verified (exit code 1 with helpful message)

---
*Phase: 01-sidecar*
*Completed: 2026-02-10*
