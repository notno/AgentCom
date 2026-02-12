---
phase: 17-enriched-task-format
plan: 02
subsystem: api
tags: [elixir, validation, task-queue, enrichment, dets]

# Dependency graph
requires:
  - phase: 12-input-validation
    provides: "Validation.Schemas and Validation module for schema-based input validation"
provides:
  - "Extended post_task schema with 6 optional enrichment fields"
  - "Nested validation for file_hints, verification_steps, complexity_tier"
  - "Soft-limit warning for verification steps exceeding 10"
  - "TaskQueue.submit stores enrichment fields in task map"
  - "format_task includes enrichment fields with backward-compatible defaults"
  - "format_complexity helper for nil and map complexity serialization"
affects: [17-03-pipeline-wiring, 18-agent-routing, 19-scheduler, 21-verification]

# Tech tracking
tech-stack:
  added: []
  patterns: ["validate_enrichment_fields as separate pass after schema validation", "verify_step_soft_limit returning :ok or {:warn, msg}", "Map.get with defaults for backward-compatible enrichment field reads"]

key-files:
  created: []
  modified:
    - lib/agent_com/validation/schemas.ex
    - lib/agent_com/validation.ex
    - lib/agent_com/task_queue.ex
    - lib/agent_com/endpoint.ex
    - test/agent_com/validation_test.exs
    - test/agent_com/task_queue_test.exs

key-decisions:
  - "Enrichment validation is a separate pass (validate_enrichment_fields) called after standard schema validation, not mixed into validate_against_schema"
  - "Soft limit for verification steps set at 10, returns warning not error"
  - "complexity field in task map set to nil placeholder -- Plan 03 will wire Complexity module"
  - "Warnings included in POST /api/tasks response only when non-empty"

patterns-established:
  - "Nested map-in-list validation pattern: iterate with index, validate inner fields, return field[idx].subfield errors"
  - "Enrichment fields use nil for scalar defaults, [] for collection defaults"
  - "format_complexity/1 handles nil (old tasks) and map (new tasks) with pattern matching"

# Metrics
duration: 4min
completed: 2026-02-12
---

# Phase 17 Plan 02: Enriched Task Format Summary

**Extended task model with 6 enrichment fields (repo, branch, file_hints, success_criteria, verification_steps, complexity_tier), nested validation, and backward-compatible format_task serialization**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-12T19:29:37Z
- **Completed:** 2026-02-12T19:33:19Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- Extended post_task HTTP schema with 6 optional enrichment fields and repo length limit
- Built nested validation for file_hints (path required, reason optional), verification_steps (type+target required, description optional), and complexity_tier (enum: trivial/standard/complex/unknown)
- Added soft-limit warning system for verification steps exceeding 10
- Extended TaskQueue.submit to store all enrichment fields in the task map with backward-compatible defaults
- Wired enrichment validation into POST /api/tasks endpoint with warning propagation in response
- Extended format_task to serialize enrichment fields with defaults for old tasks

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend validation schemas and add nested file_hints/verification_steps validation** - `8d84425` (feat)
2. **Task 2: Add enrichment fields to TaskQueue.submit and extend format_task** - `e57ca2d` (feat)

## Files Created/Modified
- `lib/agent_com/validation/schemas.ex` - Added 6 enrichment optional fields to post_task schema, added repo length limit
- `lib/agent_com/validation.ex` - Added validate_enrichment_fields/1 and verify_step_soft_limit/1 public functions
- `lib/agent_com/task_queue.ex` - Extended task map in submit handler with enrichment fields
- `lib/agent_com/endpoint.ex` - Wired enrichment validation in POST /api/tasks, extended format_task, added format_complexity/1
- `test/agent_com/validation_test.exs` - 10 new tests for enrichment field validation and soft limit
- `test/agent_com/task_queue_test.exs` - 3 new tests for enriched task submission and backward compat

## Decisions Made
- Enrichment validation runs as a separate pass after schema validation (keeps schema validation pure and enrichment logic isolated)
- Soft limit threshold set at 10 verification steps -- warning not error, tasks still submit
- Complexity field stored as nil placeholder in TaskQueue.submit -- Plan 03 will wire the Complexity module to avoid compile dependency before it exists
- Warnings only included in response when non-empty (no "warnings": [] noise)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- All enrichment fields are stored and validated -- Plan 03 can wire the Complexity module and propagate through Scheduler/Socket
- Task format backward compatibility confirmed via tests with both enriched and plain tasks
- 1 pre-existing test failure in DetsBackupTest (known issue, unrelated to this plan)

## Self-Check: PASSED

- All 7 files verified present on disk
- Commit 8d84425 (Task 1) verified in git log
- Commit e57ca2d (Task 2) verified in git log
- Full test suite: 316 tests, 1 pre-existing failure, 0 new failures

---
*Phase: 17-enriched-task-format*
*Completed: 2026-02-12*
