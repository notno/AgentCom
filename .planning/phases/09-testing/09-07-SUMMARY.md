---
phase: 09-testing
plan: 07
subsystem: testing
tags: [exunit, smoke-tests, ci, test-exclusion]

# Dependency graph
requires:
  - phase: 09-04
    provides: Smoke test modules (basic, failure, scale)
  - phase: 09-06
    provides: CI workflow with mix test --exclude skip
provides:
  - Smoke tests tagged @moduletag :smoke and excluded from default mix test
  - CI workflow excluding both :skip and :smoke tags
  - Smoke tests remain runnable via mix test --only smoke
affects: [ci, testing]

# Tech tracking
tech-stack:
  added: []
  patterns: ["@moduletag :smoke for environment-dependent test exclusion"]

key-files:
  created: []
  modified:
    - test/smoke/basic_test.exs
    - test/smoke/failure_test.exs
    - test/smoke/scale_test.exs
    - test/test_helper.exs
    - .github/workflows/ci.yml

key-decisions:
  - "Use @moduletag :smoke (not per-test @tag) for whole-module exclusion"

patterns-established:
  - "@moduletag :smoke pattern: tag entire test module when it requires running infrastructure"

# Metrics
duration: 1min
completed: 2026-02-11
---

# Phase 09 Plan 07: Smoke Test Exclusion Summary

**Tagged smoke tests with @moduletag :smoke and excluded from default test runs and CI to eliminate 5 econnrefused failures**

## Performance

- **Duration:** 1 min
- **Started:** 2026-02-11T11:06:14Z
- **Completed:** 2026-02-11T11:07:23Z
- **Tasks:** 1
- **Files modified:** 5

## Accomplishments
- All 3 smoke test modules tagged with `@moduletag :smoke` for automatic exclusion
- ExUnit.start updated to exclude both `:skip` and `:smoke` tags by default
- CI workflow updated to `--exclude skip --exclude smoke`
- Verified `mix test --exclude skip` passes with 134 tests, 0 failures (6 excluded)

## Task Commits

Each task was committed atomically:

1. **Task 1: Tag smoke tests and update exclusion config** - `2004ce5` (fix)

## Files Created/Modified
- `test/smoke/basic_test.exs` - Added `@moduletag :smoke` after `use ExUnit.Case`
- `test/smoke/failure_test.exs` - Added `@moduletag :smoke` after `use ExUnit.Case`
- `test/smoke/scale_test.exs` - Added `@moduletag :smoke` after `use ExUnit.Case`
- `test/test_helper.exs` - Changed exclude list from `[:skip]` to `[:skip, :smoke]`
- `.github/workflows/ci.yml` - Added `--exclude smoke` to test command

## Decisions Made
- Used `@moduletag :smoke` (module-level tag) rather than per-test `@tag :smoke` since all tests in each smoke module require a running hub server

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All phase 09 plans complete (7/7)
- `mix test --exclude skip` passes cleanly with 0 failures
- CI workflow ready for use with proper exclusions
- Smoke tests remain independently runnable with `mix test --only smoke` when hub server is available

## Self-Check: PASSED

- All 5 modified files exist on disk
- Commit `2004ce5` confirmed in git log
- SUMMARY.md created at `.planning/phases/09-testing/09-07-SUMMARY.md`

---
*Phase: 09-testing*
*Completed: 2026-02-11*
