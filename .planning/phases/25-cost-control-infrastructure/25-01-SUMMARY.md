---
phase: 25-cost-control-infrastructure
plan: 01
subsystem: infra
tags: [genserver, dets, ets, budget, rate-limiting, cost-control]

# Dependency graph
requires:
  - phase: 04-config-persistence
    provides: "Config GenServer for dynamic budget thresholds"
  - phase: 17-dets-backup
    provides: "DetsBackup for backup, compaction, and recovery of DETS tables"
provides:
  - "CostLedger GenServer with dual-layer DETS+ETS invocation tracking"
  - "check_budget/1 hot-path budget gate (ETS direct read, no GenServer.call)"
  - "record_invocation/2 for persisting hub-side CLI invocations"
  - "Per-state (executing/improving/contemplating) hourly and daily budget caps"
  - "DetsBackup registration for :cost_ledger table"
affects: [26-claude-client, 27-goal-backlog, 28-hub-fsm]

# Tech tracking
tech-stack:
  added: []
  patterns: [dual-layer-dets-ets, hot-path-ets-reads, rolling-window-counters]

key-files:
  created:
    - lib/agent_com/cost_ledger.ex
  modified:
    - lib/agent_com/application.ex
    - lib/agent_com/dets_backup.ex

key-decisions:
  - "Fail-open on ETS/Config unavailability -- safety during startup outweighs cost risk"
  - "Session counters count all DETS records on cold start (no session boundary in persistent store)"
  - "Added get_table_path clause for :cost_ledger in DetsBackup for restore support"

patterns-established:
  - "Budget gate pattern: ETS direct read for hot-path checks, GenServer.call for writes"
  - "CostLedger DETS record format: {id, %{id, hub_state, timestamp, duration_ms, prompt_type}}"

# Metrics
duration: 3min
completed: 2026-02-13
---

# Phase 25 Plan 01: CostLedger Summary

**CostLedger GenServer with dual-layer DETS+ETS store enforcing per-state invocation budgets (Executing 20/hr, Improving 10/hr, Contemplating 5/hr) via hot-path ETS reads**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-13T23:14:31Z
- **Completed:** 2026-02-13T23:17:12Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- CostLedger GenServer with 5-function public API (start_link, check_budget, record_invocation, stats, history)
- Dual-layer persistence: DETS for durability, ETS for O(1) budget checks without GenServer.call
- Per-state budget enforcement with configurable limits via Config GenServer
- Integrated into supervision tree (after Config, before Auth) and DetsBackup (11 tables)

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement CostLedger GenServer with dual-layer DETS+ETS store** - `8bd825b` (feat)
2. **Task 2: Add CostLedger to supervision tree and register with DetsBackup** - `fd282b6` (feat)

**Plan metadata:** `9c2fba5` (docs: complete plan)

## Files Created/Modified
- `lib/agent_com/cost_ledger.ex` - CostLedger GenServer with dual-layer DETS+ETS store, budget checking, invocation recording, stats, history
- `lib/agent_com/application.ex` - CostLedger added to supervision tree after Config, before Auth
- `lib/agent_com/dets_backup.ex` - :cost_ledger registered in @tables, table_owner/1, get_table_path/1 (11 tables)

## Decisions Made
- Fail-open on ETS/Config unavailability during startup to avoid blocking the hub when infrastructure is still initializing
- Session counters count all DETS records on cold start since there is no persistent session boundary marker
- Added get_table_path(:cost_ledger) clause in DetsBackup (not explicitly in plan) to ensure backup/restore works correctly for the new table

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Added get_table_path clause for :cost_ledger in DetsBackup**
- **Found during:** Task 2 (DetsBackup registration)
- **Issue:** Plan specified adding to @tables and table_owner/1 but did not mention get_table_path/1, which is required for backup/restore to locate the DETS file
- **Fix:** Added `get_table_path(:cost_ledger)` case clause returning the correct path
- **Files modified:** lib/agent_com/dets_backup.ex
- **Verification:** Compiles cleanly, matches pattern of all other table entries
- **Committed in:** fd282b6 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** Essential for DetsBackup restore support. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- CostLedger is operational and ready for integration with Claude Code CLI client (Phase 26+)
- check_budget/1 can be called from any process without blocking on GenServer
- Budget limits configurable at runtime via `AgentCom.Config.put(:hub_invocation_budgets, %{...})`
- Ready for Plan 25-02 (budget alert/notification integration) and Plan 25-03 (cost reporting API)

## Self-Check: PASSED

All files verified present, all commits verified in git log.

---
*Phase: 25-cost-control-infrastructure*
*Completed: 2026-02-13*
