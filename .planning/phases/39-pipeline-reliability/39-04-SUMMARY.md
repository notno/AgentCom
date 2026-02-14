---
phase: 39-pipeline-reliability
plan: 04
subsystem: pipeline
tags: [sidecar, wake_command, fail-fast, task-routing, gap-closure]

# Dependency graph
requires:
  - phase: 39-pipeline-reliability
    provides: "wakeAgent fail-fast for wake path (plan 01)"
provides:
  - "Pre-routing wake_command gate in task_assigned handler covering all target_types"
affects: [pipeline-reliability, sidecar]

# Tech tracking
tech-stack:
  added: []
  patterns: ["pre-routing validation gate before execution dispatch"]

key-files:
  created: []
  modified: ["sidecar/index.js"]

key-decisions:
  - "Placed wake_command gate before routing branch rather than duplicating in each execution path"
  - "Preserved existing wakeAgent() fail-fast as defense-in-depth"

patterns-established:
  - "Pre-routing validation: validate agent config before dispatching to any execution path"

# Metrics
duration: 2min
completed: 2026-02-14
---

# Phase 39 Plan 04: Wake Command Gate Summary

**Pre-routing wake_command validation gate rejects tasks immediately regardless of routing target_type (sidecar/ollama/wake)**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-14T23:23:51Z
- **Completed:** 2026-02-14T23:25:00Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- Added wake_command validation before the routing decision branch in task_assigned handler
- All task types (trivial/sidecar, standard/ollama, complex/wake) now fail fast when wake_command is missing or empty
- Preserved existing wakeAgent() fail-fast as defense-in-depth layer

## Task Commits

Each task was committed atomically:

1. **Task 1: Add wake_command gate before routing decision branch** - `fc04889` (feat)

## Files Created/Modified
- `sidecar/index.js` - Added pre-routing wake_command validation gate (lines 793-813) that rejects tasks with missing/empty wake_command before they reach executeTask() or wakeAgent()

## Decisions Made
- Placed the gate before the routing branch to avoid duplicating the check in each execution path
- Preserved existing wakeAgent() fail-fast check (lines 99-115) as defense-in-depth -- it will never fire with the new gate, but provides backward compatibility if wakeAgent is called directly

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- UAT Test 3 gap closed: tasks with missing/empty wake_command fail immediately regardless of routing target
- All 4 plans in Phase 39 pipeline-reliability are now complete

---
*Phase: 39-pipeline-reliability*
*Completed: 2026-02-14*
