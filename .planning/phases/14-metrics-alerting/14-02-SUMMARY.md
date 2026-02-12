---
phase: 14-metrics-alerting
plan: 02
subsystem: alerting
tags: [genserver, pubsub, alerter, cooldown, thresholds, api]

# Dependency graph
requires:
  - phase: 14-metrics-alerting
    plan: 01
    provides: "MetricsCollector with snapshot/0 for rule evaluation data"
provides:
  - "AgentCom.Alerter GenServer with 5 configurable alert rules and cooldown/ack state machine"
  - "PubSub broadcasts on 'alerts' topic (alert_fired/cleared/acknowledged)"
  - "GET /api/alerts endpoint returning active alerts"
  - "POST /api/alerts/:rule_id/acknowledge for alert acknowledgment"
  - "GET/PUT /api/config/alert-thresholds for threshold management"
affects: [14-03-PLAN, 14-04-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Alert lifecycle state machine: inactive -> active -> acknowledged -> cleared"
    - "Cooldown bypass for CRITICAL severity, per-rule cooldown for WARNING"
    - "Config hot-reload: thresholds re-read from DETS on every check cycle"
    - "Hysteresis for queue_growing: 3 stable checks required to clear"

key-files:
  created:
    - "lib/agent_com/alerter.ex"
  modified:
    - "lib/agent_com/application.ex"
    - "lib/agent_com/endpoint.ex"

key-decisions:
  - "Alerter placed after MetricsCollector, before DashboardState in supervision tree"
  - "30-second startup delay prevents false positives before agents reconnect"
  - "CRITICAL alerts (stuck_tasks, no_agents_online) bypass cooldown per locked decision"
  - "Thresholds merged with defaults so partial updates don't break other rules"
  - "GET /api/alerts is unauthenticated (same pattern as /api/dashboard/state and /api/metrics)"
  - "Queue growing uses hysteresis: 3 consecutive stable checks required to clear alert"

patterns-established:
  - "Alert rule pattern: evaluate_* returns {:triggered, severity, message, details} | :ok"
  - "Cooldown logic: should_fire?/5 checks severity then per-rule cooldown timer"
  - "Safe atom conversion: safe_to_existing_atom/1 for user-supplied rule_id strings"

# Metrics
duration: 4min
completed: 2026-02-12
---

# Phase 14 Plan 02: Alerter Summary

**Alerter GenServer with 5 configurable alert rules, cooldown/ack state machine, PubSub broadcasting, and alert management API endpoints**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-12T10:48:25Z
- **Completed:** 2026-02-12T10:52:00Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Alerter GenServer with 5 alert rules (queue_growing, high_failure_rate, stuck_tasks, no_agents_online, high_error_rate) evaluating MetricsCollector snapshots on configurable check cycles
- Alert lifecycle state machine (inactive/active/acknowledged/cleared) with CRITICAL bypass and WARNING cooldown support
- PubSub broadcasting on "alerts" topic for dashboard consumption
- Full alert management API: GET alerts, POST acknowledge, GET/PUT thresholds with hot-reload via Config DETS

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Alerter GenServer with rule evaluation, cooldown, and ack state machine** - `a460a0e` (feat)
2. **Task 2: Add Alerter to supervision tree and create alert API endpoints** - `bd20d0d` (feat)

## Files Created/Modified
- `lib/agent_com/alerter.ex` - Alerter GenServer with 5 alert rules, cooldown logic, ack state machine, PubSub broadcasting, Config threshold loading
- `lib/agent_com/application.ex` - Added Alerter to supervision tree after MetricsCollector, before DashboardState
- `lib/agent_com/endpoint.ex` - Added GET /api/alerts, POST /api/alerts/:rule_id/acknowledge, GET/PUT /api/config/alert-thresholds endpoints

## Decisions Made
- Alerter placed after MetricsCollector and before DashboardState in supervision tree so it can read metrics and broadcasts are available before DashboardState/DashboardNotifier
- 30-second startup delay to prevent false positives on fresh start before agents reconnect
- CRITICAL alerts (stuck_tasks, no_agents_online) fire immediately, bypassing cooldown
- Thresholds from Config are merged with defaults so partial custom configs don't break rules with missing keys
- GET /api/alerts is unauthenticated (same pattern as /api/dashboard/state and /api/metrics)
- Queue growing alert uses hysteresis: requires 3 consecutive stable/decreasing checks before clearing
- acknowledge/1 accepts both atom and string rule_id for API ergonomics (safe_to_existing_atom prevents atom leak)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Alerter provides the alert evaluation layer needed by DashboardState (plan 03) for alert integration
- PubSub "alerts" topic is broadcasting alert events for dashboard real-time updates (plan 04)
- Alert thresholds are configurable via API without restart
- Ready for plan 03 (DashboardState alert integration) and plan 04 (dashboard UI updates)

## Self-Check: PASSED

- [x] lib/agent_com/alerter.ex exists
- [x] lib/agent_com/application.ex exists
- [x] lib/agent_com/endpoint.ex exists
- [x] 14-02-SUMMARY.md exists
- [x] Commit a460a0e exists
- [x] Commit bd20d0d exists

---
*Phase: 14-metrics-alerting*
*Completed: 2026-02-12*
