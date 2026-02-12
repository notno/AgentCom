---
phase: 19-model-aware-scheduler
plan: 01
subsystem: scheduler
tags: [routing, load-balancing, tier-resolution, pure-functions, tdd]

# Dependency graph
requires:
  - phase: 17-complexity-heuristic
    provides: "Complexity.build/1 producing effective_tier for routing"
  - phase: 18-llm-registry
    provides: "LlmRegistry endpoint health, models, and ETS resource metrics"
provides:
  - "TaskRouter.route/3 -- pure-function routing decisions for any task"
  - "TierResolver.resolve/1 -- tier resolution with fallback chains"
  - "LoadScorer.score_and_rank/3 -- weighted endpoint scoring"
affects: [19-02-scheduler-integration, 19-03-fallback-timeouts, 19-04-dashboard-routing]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Pure-function routing engine (no GenServer, no side effects)", "Weighted multi-factor endpoint scoring", "Structured routing decision maps for transparency"]

key-files:
  created:
    - lib/agent_com/task_router.ex
    - lib/agent_com/task_router/tier_resolver.ex
    - lib/agent_com/task_router/load_scorer.ex
    - test/agent_com/task_router_test.exs
  modified: []

key-decisions:
  - "15% warm model bonus for endpoints with task model loaded (discretion area)"
  - "5% repo affinity bonus when same repo on similar load (simplified for Phase 19)"
  - "Neutral defaults for missing resource data (cpu=50%, vram_factor=0.9, capacity=1.0)"
  - "16GB reference capacity for capacity factor normalization, capped at 1.5x"
  - "Classification reason string format: source:tier (confidence X, word_count=Y, files=Z)"

patterns-established:
  - "Pure routing module pattern: route/3 takes data, returns decision or fallback signal"
  - "Scoring formula: base * load * capacity * vram * warm * affinity"
  - "Cost tier enumeration: :free (sidecar), :local (ollama), :api (claude)"

# Metrics
duration: 4min
completed: 2026-02-12
---

# Phase 19 Plan 01: TaskRouter Routing Decision Engine Summary

**Pure-function routing engine with tier resolution, weighted endpoint scoring (load/capacity/VRAM/warm model/repo affinity), and structured decision output for trivial/standard/complex tasks**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-12T22:02:55Z
- **Completed:** 2026-02-12T22:06:34Z
- **Tasks:** 1 (TDD: RED-GREEN, no refactor needed)
- **Files modified:** 4

## Accomplishments
- TierResolver resolves effective_tier with one-step fallback chains (trivial<->standard<->complex)
- LoadScorer ranks endpoints by weighted multi-factor score (load, capacity, VRAM, warm model 15%, repo affinity 5%)
- TaskRouter.route/3 returns complete routing decisions for all three tiers with full transparency fields
- 35 comprehensive tests covering all tiers, scoring, edge cases, and decision field completeness

## Task Commits

Each task was committed atomically:

1. **Task 1 (RED): Failing tests** - `e35cdfb` (test)
2. **Task 1 (GREEN): Implementation** - `9e89edd` (feat)

## Files Created/Modified
- `lib/agent_com/task_router.ex` - Top-level route/3 function, decision building, tier-to-target mapping
- `lib/agent_com/task_router/tier_resolver.ex` - Tier resolution from complexity, fallback_up/fallback_down chains
- `lib/agent_com/task_router/load_scorer.ex` - Weighted scoring with load, capacity, VRAM, warm model, repo affinity factors
- `test/agent_com/task_router_test.exs` - 35 tests for all routing behaviors and edge cases

## Decisions Made
- **Warm model bonus 15%:** Endpoints with the task's model loaded get 1.15x score multiplier (discretion area from CONTEXT.md)
- **Repo affinity 5%:** Same-repo endpoints get 1.05x bonus; simplified for Phase 19 using resource metadata repo field
- **Neutral defaults:** Missing resource data uses safe defaults (cpu=50%, vram_factor=0.9, capacity=1.0) so endpoints are not penalized
- **16GB reference capacity:** Capacity factor normalized against 16GB, capped at 1.5x to prevent extreme hosts from dominating
- **Classification reason format:** Human-readable string with source, tier, confidence, and key signals for routing transparency

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- TaskRouter is ready for Scheduler integration (Plan 02) -- route/3 can be called from the Scheduler GenServer
- TierResolver fallback chains ready for timeout-based fallback logic (Plan 03)
- Routing decision map structure ready for dashboard display (Plan 04)

## Self-Check: PASSED

- All 4 created files exist on disk
- Commit e35cdfb (RED) verified in git log
- Commit 9e89edd (GREEN) verified in git log
- 35/35 tests pass, 0 warnings
- Full suite: 372 tests, 0 failures

---
*Phase: 19-model-aware-scheduler*
*Completed: 2026-02-12*
