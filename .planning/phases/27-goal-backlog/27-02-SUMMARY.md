---
phase: 27-goal-backlog
plan: 02
subsystem: api
tags: [http-api, validation, cli, sidecar, goal-lifecycle, plug-router]

requires:
  - phase: 27-goal-backlog
    plan: 01
    provides: GoalBacklog GenServer with submit/get/list/transition/stats/delete API
provides:
  - 5 HTTP routes for goal CRUD and lifecycle transitions (POST, GET list, GET single, GET stats, PATCH transition)
  - post_goal and patch_goal_transition validation schemas
  - agentcom-submit-goal.js CLI sidecar tool for goal submission
  - goal_backlog registered in @dets_table_atoms for admin compact/restore
affects: [28-hub-fsm, dashboard, cli-tooling]

tech-stack:
  added: []
  patterns: [goal-api-routes, cli-goal-submission]

key-files:
  created:
    - sidecar/agentcom-submit-goal.js
  modified:
    - lib/agent_com/endpoint.ex
    - lib/agent_com/validation/schemas.ex

key-decisions:
  - "Goal API routes placed after Task Queue section, stats route before :goal_id to prevent parameter capture"
  - "CLI tool follows agentcom-submit.js pattern exactly: standalone, no shared modules, inline HTTP helper"
  - "Goal source defaults to 'api' for HTTP submissions and 'cli' for CLI submissions"

patterns-established:
  - "Repeatable CLI flags via parseArgs multiple:true for list inputs (--criteria)"
  - "format_goal/1 helper converts atom keys/status to strings for JSON serialization"

duration: 6min
completed: 2026-02-13
---

# Phase 27 Plan 02: Goal API & CLI Summary

**5 HTTP goal routes with validation schemas, admin DETS registration, and agentcom-submit-goal.js CLI sidecar tool for multi-source goal intake**

## Performance

- **Duration:** 6 min
- **Started:** 2026-02-13T23:59:01Z
- **Completed:** 2026-02-14T00:04:55Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- 5 HTTP routes for goal CRUD: POST create, GET list, GET single, GET stats, PATCH transition -- all auth-gated with input validation
- post_goal and patch_goal_transition validation schemas added to Schemas module
- agentcom-submit-goal.js CLI tool with repeatable --criteria flag, posting to /api/goals
- goal_backlog added to @dets_table_atoms for admin compact/restore operations
- format_goal/1 helper for JSON-safe goal serialization with atom-to-string conversion

## Task Commits

Each task was committed atomically:

1. **Task 1: Add validation schemas and HTTP API routes for goals** - `424c2fa` (feat, previously committed in 28-01 execution)
2. **Task 2: Create agentcom-submit-goal.js CLI sidecar tool** - `b3fc51a` (feat)

## Files Created/Modified
- `sidecar/agentcom-submit-goal.js` - CLI tool for goal submission from command line, follows agentcom-submit.js pattern
- `lib/agent_com/endpoint.ex` - 5 goal API routes (POST, GET list, GET single, GET stats, PATCH transition), format_goal/1 helper, @dets_table_atoms entry
- `lib/agent_com/validation/schemas.ex` - post_goal and patch_goal_transition HTTP validation schemas

## Decisions Made
- Goal API routes placed after Task Queue section; stats route before :goal_id to prevent "stats" matching as parameter
- CLI tool follows agentcom-submit.js pattern exactly: standalone Node.js script, no shared modules, inline HTTP helper
- Goal source defaults to "api" for HTTP submissions and "cli" for CLI tool submissions
- Repeatable --criteria flag uses parseArgs multiple:true for collecting success criteria array

## Deviations from Plan

None - plan executed exactly as written.

Note: Task 1 (API routes and validation schemas) was found already committed as part of the 28-01 execution (commit 424c2fa). This is because phase 28-01 depended on goal API routes being available and included them proactively. No re-implementation was needed.

## Issues Encountered
- Port 4002 in use prevented initial test runs (lingering Erlang processes from previous sessions). Resolved by killing orphaned erl.exe processes.
- Task 1 artifacts already existed in HEAD (committed during 28-01 execution). No new commit needed for Task 1.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Goal API fully operational: submit, list, get, transition, stats
- CLI tool ready for human/script goal submission
- GoalBacklog + API ready for Hub FSM consumption in Phase 28

## Self-Check: PASSED

All files exist. All commit hashes verified.

---
*Phase: 27-goal-backlog*
*Completed: 2026-02-13*
