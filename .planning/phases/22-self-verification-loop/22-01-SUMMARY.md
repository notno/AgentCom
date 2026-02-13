---
phase: 22-self-verification-loop
plan: 01
subsystem: execution
tags: [verification, retry-loop, corrective-prompt, cost-tracking]

# Dependency graph
requires:
  - phase: 21-verification-wiring
    provides: "runVerification function, verification report format, Store persistence"
  - phase: 20-sidecar-execution
    provides: "dispatch function, cost-calculator, executor implementations"
provides:
  - "executeWithVerification: bounded execute-verify-fix loop wrapping dispatch + runVerification"
  - "Corrective prompt construction from failed/passed verification checks"
  - "run_number parameterization in runVerification for multi-iteration tracking"
affects: [22-self-verification-loop, sidecar-execution, task-lifecycle]

# Tech tracking
tech-stack:
  added: []
  patterns: [bounded-retry-loop, corrective-prompt-construction, cumulative-cost-tracking]

key-files:
  created:
    - sidecar/lib/execution/verification-loop.js
  modified:
    - sidecar/verification.js

key-decisions:
  - "Shell executor (sidecar target_type) skips retry loop entirely -- deterministic commands have no LLM to correct"
  - "Default max_verification_retries is 0 (single attempt, no retries) -- safe default, opt-in retries"
  - "Corrective prompt includes both failed AND passed checks to prevent regression during fixes"
  - "Cumulative cost tracked across all iterations to provide accurate total cost reporting"

patterns-established:
  - "Corrective prompt pattern: FAILED CHECKS + PASSED CHECKS + ORIGINAL TASK + PREVIOUS OUTPUT for targeted LLM fixes"
  - "Bounded loop with configurable max_retries read from task object"
  - "Shell executor exemption: target_type check at loop entry for deterministic task bypass"

# Metrics
duration: 2min
completed: 2026-02-12
---

# Phase 22 Plan 01: Verification Loop Summary

**Bounded execute-verify-fix loop with corrective prompt construction and run_number parameterization for multi-iteration verification tracking**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-13T02:14:52Z
- **Completed:** 2026-02-13T02:16:31Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Created verification-loop.js with executeWithVerification wrapping dispatch + runVerification in a bounded retry loop
- Corrective prompts include both failed and passed checks for targeted LLM fixes without regression
- Shell executor tasks skip the retry loop entirely (single execution + single verification)
- Cumulative token/cost tracking across all retry iterations
- Parameterized runVerification with run_number (backward-compatible, default 1)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create verification-loop.js with bounded execute-verify-fix loop** - `c2d5757` (feat)
2. **Task 2: Parameterize runVerification with run_number** - `5178aee` (feat)

## Files Created/Modified
- `sidecar/lib/execution/verification-loop.js` - Core verification loop: executeWithVerification, buildCorrectiveTask, buildLoopResult, accumulateCost, truncate, countFailures
- `sidecar/verification.js` - Added optional runNumber parameter to runVerification, replaced all 5 hardcoded run_number: 1 values

## Decisions Made
- Shell executor (sidecar target_type) skips retry loop entirely -- deterministic commands have no LLM to correct
- Default max_verification_retries is 0 (single attempt, no retries) -- safe default requiring opt-in for retries
- Corrective prompt includes both failed AND passed checks to prevent regression during fixes
- Truncation limits: 500 chars for check output, 1000 chars for previous execution output in corrective prompts

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- verification-loop.js ready for integration into task lifecycle (Plan 02 will wire executeWithVerification into add-agent.js)
- runVerification backward-compatible -- existing 2-arg callers continue working
- Plan 03 can add retry configuration to task submission

## Self-Check: PASSED

- [x] sidecar/lib/execution/verification-loop.js exists
- [x] sidecar/verification.js exists
- [x] 22-01-SUMMARY.md exists
- [x] Commit c2d5757 exists
- [x] Commit 5178aee exists

---
*Phase: 22-self-verification-loop*
*Completed: 2026-02-12*
