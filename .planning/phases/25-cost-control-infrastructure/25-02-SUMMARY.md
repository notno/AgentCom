---
phase: 25-cost-control-infrastructure
plan: 02
subsystem: infra
tags: [telemetry, alerting, dets, cost-control, observability]

# Dependency graph
requires:
  - phase: 25-01
    provides: "CostLedger GenServer with record_invocation, check_budget, and stats API"
  - phase: 10-telemetry
    provides: "Telemetry event catalog, attach_handlers/0, handle_event/4"
  - phase: 12-alerter
    provides: "Alerter check cycle, evaluate_* pattern, rule list, default_thresholds"
provides:
  - "[:agent_com, :hub, :claude_call] telemetry event on each CostLedger invocation"
  - "[:agent_com, :hub, :budget_exhausted] telemetry event on budget gate rejection"
  - "Alerter rule 7 (hub_invocation_rate) evaluating CostLedger.stats() each cycle"
  - "DetsHelpers CostLedger DETS isolation for test suites"
affects: [26-claude-client, 28-hub-fsm]

# Tech tracking
tech-stack:
  added: []
  patterns: [telemetry-emit-on-write, alerter-rule-with-try-rescue-guard]

key-files:
  created: []
  modified:
    - lib/agent_com/telemetry.ex
    - lib/agent_com/cost_ledger.ex
    - lib/agent_com/alerter.ex
    - test/support/dets_helpers.ex

key-decisions:
  - "try/rescue around budget_exhausted telemetry emit so telemetry failure never blocks budget checking"
  - "catch :exit in evaluate_hub_invocation_rate to handle CostLedger not started during alerter init"
  - "hub_invocation_rate cooldown set to 300s matching other WARNING-level rules"

patterns-established:
  - "Alerter rule pattern: try/rescue/catch around GenServer.call in evaluators for startup safety"
  - "Telemetry emit-on-write: CostLedger emits telemetry after DETS+ETS persistence, not before"

# Metrics
duration: 3min
completed: 2026-02-13
---

# Phase 25 Plan 02: Telemetry, Alerter, and DETS Isolation Summary

**Hub invocation telemetry events (claude_call + budget_exhausted) wired to existing handler, Alerter rule 7 (hub_invocation_rate at 50/hr threshold), and CostLedger DETS test isolation**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-13T23:19:24Z
- **Completed:** 2026-02-13T23:21:54Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Two telemetry events (claude_call, budget_exhausted) cataloged, attached to handler, and emitted by CostLedger
- Alerter rule 7 evaluates hub invocation rate each check cycle with configurable 50/hr threshold
- DetsHelpers fully isolates CostLedger DETS in tests (env override, mkdir, stop/restart order, force-close)

## Task Commits

Each task was committed atomically:

1. **Task 1: Add telemetry events and wire CostLedger emission** - `f60873b` (feat)
2. **Task 2: Add Alerter rule 7 and update DetsHelpers** - `4de70bc` (feat)

## Files Created/Modified
- `lib/agent_com/telemetry.ex` - Added Hub Claude Code Invocations event catalog section; attached claude_call and budget_exhausted events to handler
- `lib/agent_com/cost_ledger.ex` - Emits [:agent_com, :hub, :claude_call] after record_invocation; emits [:agent_com, :hub, :budget_exhausted] on budget gate rejection (try/rescue guarded)
- `lib/agent_com/alerter.ex` - Rule 7 (hub_invocation_rate) with evaluate_hub_invocation_rate/1; hub_invocations_per_hour_warn threshold (default 50); cooldown entry; updated moduledoc to 7 rules
- `test/support/dets_helpers.ex` - cost_ledger_data_dir env, cost_ledger mkdir, CostLedger in stop_order, :cost_ledger in force-close list

## Decisions Made
- Wrapped budget_exhausted telemetry emit in try/rescue so telemetry failure never blocks the budget check hot path
- Added catch :exit alongside rescue in evaluate_hub_invocation_rate to handle the case where CostLedger GenServer hasn't started yet during early alerter cycles
- Set hub_invocation_rate cooldown to 300_000ms (5 min) matching other WARNING-level rules

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Added catch :exit to evaluate_hub_invocation_rate**
- **Found during:** Task 2 (Alerter rule 7 implementation)
- **Issue:** Plan's evaluate_hub_invocation_rate only had rescue clause, but CostLedger.stats() uses GenServer.call which raises :exit (not an exception) if the GenServer is not running
- **Fix:** Added `catch :exit, _ -> 0` clause alongside the rescue
- **Files modified:** lib/agent_com/alerter.ex
- **Verification:** Compiles cleanly, alerter won't crash if CostLedger is unavailable
- **Committed in:** 4de70bc (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Essential for runtime safety during startup. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Telemetry events ready for dashboard integration and metrics collection
- Alerter rule 7 will fire when CostLedger reports >50 invocations/hour
- DetsHelpers isolation enables Plan 25-03 cost reporting tests without DETS pollution
- Ready for Plan 25-03 (cost dashboard API endpoints)

## Self-Check: PASSED

All files verified present, all commits verified in git log.

---
*Phase: 25-cost-control-infrastructure*
*Completed: 2026-02-13*
