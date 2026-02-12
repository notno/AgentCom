---
phase: 19-model-aware-scheduler
plan: 03
subsystem: scheduler
tags: [config, alerting, ttl, degraded-behavior, tier-down, task-expiry]

# Dependency graph
requires:
  - phase: 19-02
    provides: "Scheduler with tier-aware routing, fallback timers, routing decisions on tasks"
  - phase: 14-metrics-alerting
    provides: "Alerter with 5 alert rules and periodic evaluation pattern"
provides:
  - "Runtime-configurable routing timeouts via Config (fallback_wait_ms, task_ttl_ms, tier_down_alert_threshold_ms)"
  - "Tier-down alert rule that fires when all Ollama endpoints stay unhealthy beyond threshold"
  - "TTL sweep that expires non-trivial queued tasks to prevent unbounded backlog"
  - "TaskQueue.expire_task/1 for queued-to-dead_letter transitions"
affects: [19-04-dashboard-routing, 20-execution-engine]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Stateful tier_down_since tracking in Alerter for duration-based alerting", "Periodic TTL sweep with tier-aware exemption for trivial tasks"]

key-files:
  created: []
  modified:
    - lib/agent_com/config.ex
    - lib/agent_com/alerter.ex
    - lib/agent_com/scheduler.ex
    - lib/agent_com/task_queue.ex

key-decisions:
  - "Tier-down alert tracks tier_down_since timestamp, only fires after duration exceeds configurable threshold (not on brief blips)"
  - "TTL sweep exempts trivial-tier tasks from expiry (they execute locally regardless of tier availability)"
  - "expire_task moves queued tasks directly to dead_letter with reason ttl_expired (cleanest transition path)"
  - "Fallback timeout reads Config.get(:fallback_wait_ms) at timer creation time (runtime configurable, no restart needed)"

patterns-established:
  - "Duration-based alerting: track condition-start timestamp in alerter state, only fire after threshold"
  - "TTL-based task expiry: periodic sweep with tier-aware exemption for tasks that can always execute locally"

# Metrics
duration: 5min
completed: 2026-02-12
---

# Phase 19 Plan 03: Degraded Behavior Configuration Summary

**Runtime-configurable routing timeouts, tier-down alert rule with duration threshold, and TTL sweep for non-trivial queued task expiry**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-12T22:19:39Z
- **Completed:** 2026-02-12T22:24:12Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- All routing timeouts (fallback_wait_ms, task_ttl_ms, tier_down_alert_threshold_ms) configurable at runtime via Config.get/put without restart
- Alerter has 6th rule: tier_down (WARNING) that tracks when all Ollama endpoints go unhealthy and only fires after configurable threshold duration (default 60s)
- TTL sweep runs every 60s in the Scheduler, expiring non-trivial queued tasks older than task_ttl_ms (default 10min) to prevent unbounded backlog
- Trivial tasks are exempt from TTL expiry per locked decision -- they always execute locally via sidecar

## Task Commits

Each task was committed atomically:

1. **Task 1: Add routing config defaults and tier-down alert rule** - `db29062` (feat)
2. **Task 2: Add task TTL sweep and configurable fallback timeout in Scheduler** - `69145e8` (feat)

## Files Created/Modified
- `lib/agent_com/config.ex` - Added 4 new routing config defaults (fallback_wait_ms, task_ttl_ms, tier_down_alert_threshold_ms, default_ollama_model)
- `lib/agent_com/alerter.ex` - Added 6th alert rule: tier_down with duration-based tracking via tier_down_since state field
- `lib/agent_com/scheduler.ex` - Replaced hardcoded fallback timeout with Config.get, added periodic TTL sweep with trivial-tier exemption
- `lib/agent_com/task_queue.ex` - Added expire_task/1 API and handler for queued-to-dead_letter TTL expiry transition

## Decisions Made
- **Duration-based tier_down alerting:** Alerter tracks `tier_down_since` timestamp in its state. When all endpoints are unhealthy, the timestamp is set on first observation and the alert only fires when `now - tier_down_since > threshold`. This prevents false positives on brief health check failures.
- **Trivial task TTL exemption:** The TTL sweep explicitly filters out tasks with `effective_tier == :trivial`. These tasks route to sidecar direct execution regardless of Ollama endpoint availability, so expiring them would incorrectly discard work that can still be done.
- **expire_task via dead_letter:** Rather than adding a new task status, expire_task reuses the existing dead_letter mechanism with `last_error: "ttl_expired"`. This keeps the task lifecycle simple and gives operators visibility into expired tasks via the existing dead-letter UI.
- **Runtime Config.get at timer creation:** The fallback timeout reads Config.get(:fallback_wait_ms) at the point where Process.send_after is called, not at module compilation. This means operators can change the timeout via Config.put and it takes effect on the next fallback timer without restart.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- All degraded behavior configuration complete, ready for Plan 04 (dashboard routing display)
- Routing decisions, fallback indicators, and tier-down alerts are all available for dashboard visualization
- Full test suite passes: 393 tests, 0 failures, 0 warnings

## Self-Check: PASSED

- All 4 modified files exist on disk
- Commit db29062 (Task 1) verified in git log
- Commit 69145e8 (Task 2) verified in git log
- Full suite: 393 tests, 0 failures

---
*Phase: 19-model-aware-scheduler*
*Completed: 2026-02-12*
