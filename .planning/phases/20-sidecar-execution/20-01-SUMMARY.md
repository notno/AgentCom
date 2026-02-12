---
phase: 20-sidecar-execution
plan: 01
subsystem: sidecar
tags: [cost-calculation, progress-streaming, websocket-batching, tdd, pure-functions]

# Dependency graph
requires: []
provides:
  - "calculateCost function with COST_TABLE for Claude/Ollama pricing"
  - "ProgressEmitter class with 100ms token batching"
affects: [20-sidecar-execution]

# Tech tracking
tech-stack:
  added: []
  patterns: [token-event-batching, cost-equivalence-for-local-models, prefix-match-model-lookup]

key-files:
  created:
    - sidecar/lib/execution/cost-calculator.js
    - sidecar/lib/execution/progress-emitter.js
    - sidecar/test/cost-calculator.test.js
    - sidecar/test/progress-emitter.test.js
  modified: []

key-decisions:
  - "Sonnet baseline (_claude_equivalent) for Ollama savings comparison"
  - "Prefix match after exact match for model variants with tags (e.g. claude-sonnet-4.5:latest)"
  - "First token flushes immediately, subsequent tokens batched until interval fires"
  - "Ollama models with zero tokens return null equivalent_claude_cost_usd (no savings to show)"

patterns-established:
  - "Cost calculator pure function pattern: model + tokens in/out -> cost breakdown"
  - "ProgressEmitter batching pattern: immediate first event, batch subsequent within window"

# Metrics
duration: 2min
completed: 2026-02-12
---

# Phase 20 Plan 01: Cost Calculator & Progress Emitter Summary

**Pure-function cost calculator with Claude/Ollama pricing and 100ms token-batching progress emitter for WebSocket backpressure prevention**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-12T22:29:58Z
- **Completed:** 2026-02-12T22:31:49Z
- **Tasks:** 1 (TDD: RED + GREEN)
- **Files modified:** 4

## Accomplishments
- Cost calculator correctly prices all Claude models (Sonnet, Opus, Haiku) using per-million-token rates
- Ollama models return $0 actual cost with equivalent Claude cost using Sonnet baseline for savings display
- ProgressEmitter batches high-frequency token events at 100ms intervals preventing WebSocket backpressure
- Status/error/stdout events bypass batching for real-time discrete state change reporting
- All 16 tests pass (8 cost calculator + 8 progress emitter)

## Task Commits

Each task was committed atomically:

1. **Task 1 (RED): Failing tests for cost calculator and progress emitter** - `f4c6f1a` (test)
2. **Task 1 (GREEN): Implement cost calculator and progress emitter** - `85c69e8` (feat)

_TDD task: RED commit (failing tests) followed by GREEN commit (passing implementation)_

## Files Created/Modified
- `sidecar/lib/execution/cost-calculator.js` - Pure function: calculateCost(model, tokensIn, tokensOut) with COST_TABLE and findCostEntry prefix matching
- `sidecar/lib/execution/progress-emitter.js` - ProgressEmitter class with 100ms token batching, immediate flush for non-token events
- `sidecar/test/cost-calculator.test.js` - 8 tests: Claude pricing, Ollama $0 + equivalent, null model, prefix match, zero tokens
- `sidecar/test/progress-emitter.test.js` - 8 tests: immediate first token, batching, status/stdout/error bypass, flush, destroy

## Decisions Made
- Sonnet baseline (_claude_equivalent at 3.00/15.00 per M tokens) for computing Ollama savings comparison
- Prefix match after exact match to handle model variants with tags (e.g. "claude-sonnet-4.5:latest")
- First token event flushes immediately (no latency for first output), subsequent tokens batch within window
- Ollama models with zero tokens return null equivalent_claude_cost_usd (no tokens = no savings to display)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Both modules ready for use by Plan 03 executors (Ollama executor, Claude executor, script executor)
- calculateCost and COST_TABLE exported for per-task cost breakdown
- ProgressEmitter exported for WebSocket streaming infrastructure

## Self-Check: PASSED

- All 4 created files exist on disk
- Both commits (f4c6f1a, 85c69e8) found in git log
- All 16 tests pass

---
*Phase: 20-sidecar-execution*
*Completed: 2026-02-12*
