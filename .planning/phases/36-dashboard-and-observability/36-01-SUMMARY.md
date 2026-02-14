---
phase: 36-dashboard-and-observability
plan: 01
subsystem: dashboard
tags: [pubsub, genserver, goal-backlog, cost-ledger, websocket, real-time]

# Dependency graph
requires:
  - phase: 25-cost-ledger
    provides: CostLedger GenServer with stats/0 API
  - phase: 27-goal-backlog
    provides: GoalBacklog GenServer with stats/0, list/1 API
  - phase: 28-task-queue-goals
    provides: TaskQueue.goal_progress/1 for per-goal task tracking
provides:
  - GoalBacklog stats and active goal progress in DashboardState snapshot
  - CostLedger hourly/daily/session cost stats in DashboardState snapshot
  - Real-time goal_event forwarding via DashboardSocket WebSocket
affects: [dashboard-frontend, 36-02]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "catch :exit fallback for GenServer.call in snapshot aggregation"
    - "PubSub pass-through handler for live-fetched data sources"

key-files:
  created: []
  modified:
    - lib/agent_com/dashboard_state.ex
    - lib/agent_com/dashboard_socket.ex

key-decisions:
  - "catch :exit (not try/rescue) for GoalBacklog/CostLedger calls -- matching existing hub_fsm pattern"
  - "Cap active_goals to 10 to prevent snapshot bloat"
  - "goal_event as pass-through in DashboardState (data fetched live in snapshot)"

patterns-established:
  - "Goal data aggregation: stats + active goals with task progress in single snapshot"
  - "Cost data pass-through: CostLedger.stats() called live per snapshot request"

# Metrics
duration: 2min
completed: 2026-02-14
---

# Phase 36 Plan 01: Dashboard Goal & Cost Data Sources Summary

**GoalBacklog stats, active goal progress, and CostLedger cost breakdowns wired into DashboardState snapshot with real-time goal_event forwarding via DashboardSocket**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-14T03:08:32Z
- **Completed:** 2026-02-14T03:11:10Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- DashboardState.snapshot/0 now includes goal_stats (by_status/by_priority counts), active_goals (up to 10 with task progress), and cost_stats (hourly/daily/session breakdowns with budget limits)
- DashboardSocket subscribes to "goals" PubSub topic and forwards goal_event messages through the batched event pipeline
- All data fetches use catch :exit fallbacks for graceful degradation when GenServers are unavailable

## Task Commits

Each task was committed atomically:

1. **Task 1: Add GoalBacklog and CostLedger data to DashboardState snapshot** - `fec32de` (feat)
2. **Task 2: Subscribe DashboardSocket to goals PubSub and forward goal events** - `08bc140` (feat)

## Files Created/Modified
- `lib/agent_com/dashboard_state.ex` - Added goals PubSub subscription, goal_stats/active_goals/cost_stats to snapshot, goal_event handler
- `lib/agent_com/dashboard_socket.ex` - Added goals PubSub subscription, goal_event handler with batched event accumulation

## Decisions Made
- Used `catch :exit` (not `try/rescue`) for GoalBacklog and CostLedger calls -- matches the existing hub_fsm pattern in the same function since these are GenServer.call invocations
- Capped active_goals to 10 entries to prevent snapshot bloat on systems with many concurrent goals
- Goal events use pass-through handler in DashboardState (data is fetched live in snapshot, not cached)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Dashboard backend now exposes goal and cost data; ready for Plan 02 (frontend panels)
- All existing tests pass (12 pre-existing failures in FileTree and HubFSM.History unrelated to this plan)

---
*Phase: 36-dashboard-and-observability*
*Completed: 2026-02-14*
