---
phase: 19-model-aware-scheduler
plan: 04
subsystem: dashboard
tags: [routing-visibility, dashboard, api, routing-decision, fallback-badge, expandable-detail]

# Dependency graph
requires:
  - phase: 19-02
    provides: "TaskQueue.store_routing_decision/2, routing_decision field on task maps"
provides:
  - "routing_decision field in API task responses via format_task/1"
  - "routing_stats aggregate in dashboard snapshot (by_tier, by_target, fallback_count)"
  - "Dashboard routing column with tier badge, fallback indicator, and expandable detail"
  - "Dashboard routing stats summary bar in header"
affects: [20-execution-engine]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Atom-to-string serialization for routing decision JSON output", "Expandable detail pattern with CSS class toggle for routing trace", "Aggregate stats computed from live task data in DashboardState snapshot"]

key-files:
  created: []
  modified:
    - lib/agent_com/endpoint.ex
    - lib/agent_com/dashboard_state.ex
    - lib/agent_com/dashboard.ex

key-decisions:
  - "routing_decision serialized with safe_to_string for atoms/binaries/nil (defensive serialization)"
  - "routing_decision included in completion ring buffer entries for dashboard recent tasks"
  - "Routing stats computed from all TaskQueue tasks (not just recent completions) for full coverage"
  - "Routing column added after Status in recent tasks table (columns shifted, sort indices updated)"
  - "CSS class toggle pattern for expandable routing detail (no framework, consistent with verify details)"

patterns-established:
  - "Defensive serialization: safe_to_string/1 handles nil, atom, binary, and arbitrary terms"
  - "Routing visibility pattern: summary badge by default, expandable detail on click"
  - "Aggregate routing stats: computed from live task data, not separate counters"

# Metrics
duration: 6min
completed: 2026-02-12
---

# Phase 19 Plan 04: Dashboard Routing Visibility Summary

**Routing decision in API responses with tier badge, fallback indicator, expandable routing trace in dashboard, and aggregate routing stats in header**

## Performance

- **Duration:** 6 min
- **Started:** 2026-02-12T22:20:35Z
- **Completed:** 2026-02-12T22:26:05Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- API task responses now include full routing_decision with JSON-safe serialized fields (effective_tier, target_type, selected_endpoint, model, fallback info, classification reason)
- Dashboard recent tasks table shows routing column with color-coded tier badges (green=trivial, blue=standard, purple=complex) and orange FB badge for fallback tasks
- Expandable routing detail shows full routing trace (classification reason, candidate count, model, endpoint, fallback reason, cost tier, decision timestamp)
- Dashboard header displays aggregate routing stats: total routed, count by tier, and fallback count
- DashboardState snapshot includes routing_stats computed from all live tasks

## Task Commits

Each task was committed atomically:

1. **Task 1: Include routing_decision in API responses and dashboard snapshot** - `0c8e84e` (feat)
2. **Task 2: Add routing column, fallback badge, and expandable detail to dashboard** - `823ed0c` (feat)

## Files Created/Modified
- `lib/agent_com/endpoint.ex` - Added format_routing_decision/1 helper and routing_decision field in format_task/1
- `lib/agent_com/dashboard_state.ex` - Added compute_routing_stats/1, format_routing_decision_for_dashboard/1, routing_decision in completion entries, routing_stats in snapshot
- `lib/agent_com/dashboard.ex` - Added routing column, tier badges, FB badge, expandable detail, routing stats bar, CSS styles, and JavaScript rendering functions

## Decisions Made
- **Defensive serialization:** Used safe_to_string/1 (and safe_to_string_or_nil/1 variant) to handle all possible value types in routing decisions -- atoms, binaries, nil, and arbitrary terms are all safely converted for JSON output.
- **Ring buffer inclusion:** Added routing_decision to the completion ring buffer entries in DashboardState so the dashboard has access to routing data for recent tasks without separate API calls.
- **Full task scan for routing stats:** compute_routing_stats/1 iterates all tasks from TaskQueue.list([]) rather than only tracking in-memory counters, ensuring accuracy across process restarts.
- **Column position:** Routing column placed after Status (column index 3), shifting Duration/Tokens/Verify/Completed indices accordingly with updated sort arrow references.
- **Expandable detail pattern:** Used CSS class toggle (.routing-detail.visible) consistent with the existing verification details pattern (details/summary HTML), keeping the dashboard framework-free.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Dashboard file path mismatch**
- **Found during:** Task 2 (dashboard rendering)
- **Issue:** Plan specified `priv/static/dashboard.html` but the dashboard is rendered from `lib/agent_com/dashboard.ex` as an inline HTML string (no static file exists)
- **Fix:** Applied all dashboard changes to `lib/agent_com/dashboard.ex` instead
- **Files modified:** lib/agent_com/dashboard.ex
- **Verification:** mix compile --warnings-as-errors succeeds, dashboard renders correctly
- **Committed in:** 823ed0c (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** File path correction only. All planned functionality delivered exactly as specified.

## Issues Encountered
None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 19 plans 01, 02, and 04 complete (routing foundation, scheduler integration, and dashboard visibility)
- Plan 03 (fallback timeout refinement) remains to be executed
- Full test suite passes: 393 tests, 0 failures, 0 warnings

## Self-Check: PASSED

- All 3 modified files exist on disk
- Commit 0c8e84e (Task 1) verified in git log
- Commit 823ed0c (Task 2) verified in git log
- 393 tests, 0 failures

---
*Phase: 19-model-aware-scheduler*
*Completed: 2026-02-12*
