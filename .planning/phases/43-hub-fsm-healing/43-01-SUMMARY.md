---
phase: 43-hub-fsm-healing
plan: 01
subsystem: fsm
tags: [health-aggregator, healing, fsm, predicates]

requires:
  - phase: 38-ollama-client-hub-llm-routing
    provides: Hub LLM routing for health checks
  - phase: 39-pipeline-reliability
    provides: Stuck task detection and recovery primitives
provides:
  - HealthAggregator module aggregating 4 health sources
  - 5-state FSM with :healing state and transitions
  - Predicate evaluation for healing with cooldown/attempt limits
affects: [43-02, 43-03, 44-hub-fsm-testing]

tech-stack:
  added: []
  patterns: [health-aggregation, healing-state-machine, cooldown-guard]

key-files:
  created:
    - lib/agent_com/health_aggregator.ex
    - test/agent_com/health_aggregator_test.exs
  modified:
    - lib/agent_com/hub_fsm.ex
    - lib/agent_com/hub_fsm/predicates.ex

key-decisions:
  - "HealthAggregator is stateless (no GenServer) -- just functions wrapping safe_call"
  - "Healing preempts all other transitions via pattern matching priority in Predicates"
  - "gather_system_state accepts optional state param for cooldown/attempt checking"

patterns-established:
  - "safe_call/2 pattern: wrap external service calls with try/rescue/catch returning defaults"
  - "Predicate layering: healing check first, then delegate to evaluate_normal for existing logic"

duration: 4min
completed: 2026-02-14
---

# Phase 43 Plan 01: HealthAggregator and :healing FSM State Summary

**Stateless HealthAggregator aggregating Alerter/MetricsCollector/LlmRegistry/AgentFSM signals, 5-state FSM with :healing and predicate-driven healing transitions with cooldown protection**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-14T19:10:00Z
- **Completed:** 2026-02-14T19:14:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- HealthAggregator.assess/0 returns structured health report with issues list and critical_count
- FSM expanded from 4 to 5 states with :healing as a valid state
- Predicates evaluate health and trigger :healing on critical issues (highest priority)
- 5-minute cooldown and 3-attempt rolling window prevent healing storms
- All 845 existing tests pass with no regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Create HealthAggregator module with assess/0** - `291471f` (feat)
2. **Task 2: Add :healing state to FSM and Predicates** - `495c09a` (feat)

## Files Created/Modified
- `lib/agent_com/health_aggregator.ex` - Stateless health signal aggregator with 4 check functions
- `test/agent_com/health_aggregator_test.exs` - Unit tests for HealthAggregator
- `lib/agent_com/hub_fsm.ex` - 5-state FSM with healing struct fields, gather_system_state health data
- `lib/agent_com/hub_fsm/predicates.ex` - Healing preemption with cooldown/attempt guards

## Decisions Made
- HealthAggregator is stateless (no GenServer) to avoid adding another process to the supervision tree
- Healing preempts via pattern matching priority -- checked before all other transitions
- gather_system_state accepts optional state param to pass cooldown info without coupling Predicates to FSM internals

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- HealthAggregator and FSM healing state foundation complete
- Ready for Plan 02: Healing remediation actions (stuck task requeue, endpoint recovery)

---
*Phase: 43-hub-fsm-healing*
*Completed: 2026-02-14*
