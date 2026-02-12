---
phase: 17-enriched-task-format
plan: 01
subsystem: task-pipeline
tags: [complexity, heuristic, telemetry, pure-function, tdd]

# Dependency graph
requires: []
provides:
  - "AgentCom.Complexity module with build/1 and infer/1 for task complexity classification"
  - "Four-tier classification: trivial, standard, complex, unknown"
  - "Heuristic engine with keyword detection, word count, file count, verification count signals"
  - "Telemetry event [:agent_com, :complexity, :disagreement] for observability"
affects: [17-03-PLAN, 19-scheduler-routing]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Pure-function heuristic engine (no GenServer)", "Keyword-priority signal classification with majority-vote fallback", "Dual atom/string key support for params"]

key-files:
  created:
    - lib/agent_com/complexity.ex
    - test/agent_com/complexity_test.exs
  modified: []

key-decisions:
  - "Keywords as strong signals: complex keywords override other signals since short sentences can describe complex work"
  - "Majority-vote for non-keyword signals with conservative tie-breaking (prefer :standard)"
  - "Confidence scoring: keyword-driven = 0.7 base + 0.1 per supporting signal; trivial keyword = 0.9/0.75; majority-vote = agreement ratio"

patterns-established:
  - "Pure-function module for stateless computation (no GenServer, no supervision tree changes)"
  - "Dual key support via Map.get with atom fallback to string for API compatibility"

# Metrics
duration: 4min
completed: 2026-02-12
---

# Phase 17 Plan 01: Complexity Heuristic Engine Summary

**Pure-function complexity heuristic with 4 signals (words, files, verifications, keywords), 4 tiers, telemetry on disagreement, and 24 TDD tests**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-12T19:29:36Z
- **Completed:** 2026-02-12T19:33:39Z
- **Tasks:** 1 (TDD: RED-GREEN-REFACTOR)
- **Files modified:** 2

## Accomplishments
- Built AgentCom.Complexity module as pure-function heuristic engine
- Four-signal classification: word count, file hint count, verification step count, keyword detection
- Keywords treated as strong signals that override other signals (a short "refactor auth" still classifies as complex)
- Telemetry emission on explicit/inferred tier disagreement for observability
- Full test coverage: 24 tests covering explicit tiers, inferred tiers, atom/string keys, signals, edge cases, and telemetry

## Task Commits

Each task was committed atomically (TDD cycle):

1. **RED: Failing tests** - `c548d66` (test)
2. **GREEN: Implementation** - `5e93355` (feat)
3. **REFACTOR: N/A** - Code was clean after GREEN; no refactoring needed

## Files Created/Modified
- `lib/agent_com/complexity.ex` - Complexity heuristic engine with build/1 and infer/1
- `test/agent_com/complexity_test.exs` - 24 unit tests for all classification scenarios

## Decisions Made
- Keywords treated as strong signals that override word-count majority voting (a 5-word description with "refactor" should classify as :complex, not :trivial)
- Non-keyword classification uses majority vote across 3 signals (word count, file count, verification count) with conservative tie-breaking toward :standard
- Confidence scoring varies by path: keyword-driven gets 0.7 base + 0.1 per supporting signal; trivial keyword gets 0.9 (short) or 0.75 (longer); majority-vote gets agreement ratio (e.g., 3/3 = 1.0, 2/3 = 0.67)
- Empty params classify as :unknown with 0.0 confidence (no signals = no information)
- Invalid explicit tier strings are silently ignored (treated as nil, falls through to inference)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed keyword signal being outvoted by word-count majority**
- **Found during:** GREEN phase test execution
- **Issue:** Plan specified majority-vote classification across 4 equal signals. But descriptions like "refactor auth system" (3 words) would classify as :trivial because word_count=trivial, file_count=trivial, verification_count=trivial outvoted keyword=complex 3:1.
- **Fix:** Made keywords a strong signal that short-circuits majority voting. Complex keywords immediately classify as :complex with confidence boosted by supporting signals. Trivial keywords classify as :trivial unless contradicted by high file/verification counts. Non-keyword cases fall through to 3-signal majority vote.
- **Files modified:** lib/agent_com/complexity.ex
- **Verification:** All 24 tests pass including keyword-specific tests
- **Committed in:** 5e93355 (GREEN commit)

---

**Total deviations:** 1 auto-fixed (1 bug fix)
**Impact on plan:** Classification logic refined to match real-world expectations. Keywords are the strongest heuristic signal and should not be outvoted by absent signals (0 files, 0 verification steps).

## Issues Encountered
- `:telemetry_test` module not available as a dependency; used the project's established pattern of `:telemetry.attach_many/4` with process messaging instead

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- AgentCom.Complexity.build/1 ready to be called from TaskQueue.submit/1 (Plan 03 wiring)
- AgentCom.Complexity.infer/1 available for standalone use and testing
- Telemetry event registered for [:agent_com, :complexity, :disagreement]

## Self-Check: PASSED

- FOUND: lib/agent_com/complexity.ex
- FOUND: test/agent_com/complexity_test.exs
- FOUND: 17-01-SUMMARY.md
- FOUND: c548d66 (RED commit)
- FOUND: 5e93355 (GREEN commit)

---
*Phase: 17-enriched-task-format*
*Completed: 2026-02-12*
