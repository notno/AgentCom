---
phase: 18-llm-registry-host-resources
plan: 02
subsystem: sidecar
tags: [node.js, os-metrics, cpu, ram, vram, ollama, websocket, resource-reporting]

# Dependency graph
requires:
  - phase: 13-structured-logging
    provides: "Structured log module (lib/log.js) used by resources.js"
provides:
  - "collectMetrics() function returning CPU/RAM/VRAM host metrics"
  - "Sidecar sends ollama_url in identify message when configured"
  - "Sidecar sends periodic resource_report WS messages every 30 seconds"
affects: [18-03, 18-04, 19, 20]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Periodic WS message reporting alongside heartbeat", "Graceful null degradation for optional metrics"]

key-files:
  created:
    - sidecar/lib/resources.js
  modified:
    - sidecar/index.js

key-decisions:
  - "CPU percent from os.loadavg[0] / core count -- simple, cross-platform, 1-min average"
  - "VRAM from Ollama /api/ps size_vram sum -- no nvidia-smi dependency"
  - "Separate resource_report WS message type rather than piggybacking on ping"
  - "5-second initial report delay after identify for connection stabilization"

patterns-established:
  - "Resource collection module pattern: async collectMetrics(ollamaUrl) with null fallbacks"
  - "Optional config field pattern: config.ollama_url = config.ollama_url || null"

# Metrics
duration: 2min
completed: 2026-02-12
---

# Phase 18 Plan 02: Sidecar Resource Metrics Summary

**Host resource collection (CPU/RAM/VRAM) via Node.js os module and Ollama /api/ps, with periodic resource_report WebSocket messages every 30 seconds**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-12T22:08:25Z
- **Completed:** 2026-02-12T22:10:43Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Created resources.js module that collects CPU percent, RAM used/total, and VRAM from Ollama /api/ps
- Extended sidecar identify message to include ollama_url when configured
- Added 30-second periodic resource_report WebSocket messages with full host metrics
- All metrics gracefully degrade to null when data is unavailable (no GPU, no Ollama, etc.)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create resources.js metrics collection module** - `56d0cf3` (feat)
2. **Task 2: Extend sidecar identify and add periodic resource reporting** - `7ad2a2a` (feat)

## Files Created/Modified
- `sidecar/lib/resources.js` - Resource metrics collection: CPU from os.loadavg, RAM from os.totalmem/freemem, VRAM from Ollama /api/ps
- `sidecar/index.js` - Extended with ollama_url in identify, periodic resource_report messages, cleanup on disconnect/shutdown

## Decisions Made
- Used `os.loadavg()[0] / cpuCount * 100` for CPU percent -- simple, cross-platform, gives 1-minute load average as percentage
- Used Node.js built-in `http` module for Ollama /api/ps request (not fetch) to avoid Node version dependency
- VRAM total reported as null (not available from Ollama API) -- only VRAM used is meaningful
- 5-second delay for initial resource report after identify to let the connection stabilize
- Resource interval cleanup added to both disconnect (close handler) and explicit shutdown

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required. Users can optionally add `"ollama_url": "http://localhost:11434"` to their sidecar config.json to enable VRAM reporting and Ollama auto-discovery.

## Next Phase Readiness
- Sidecar now sends resource data and ollama_url to hub
- Hub-side handling of resource_report and ollama_url messages needed (Plan 03)
- LlmRegistry GenServer can consume these messages once Plan 01 establishes the GenServer

## Self-Check: PASSED

All artifacts verified:
- sidecar/lib/resources.js: FOUND
- sidecar/index.js: FOUND
- Commit 56d0cf3: FOUND
- Commit 7ad2a2a: FOUND
- 18-02-SUMMARY.md: FOUND

---
*Phase: 18-llm-registry-host-resources*
*Completed: 2026-02-12*
