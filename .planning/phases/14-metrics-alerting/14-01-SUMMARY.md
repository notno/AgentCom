---
phase: 14-metrics-alerting
plan: 01
subsystem: metrics
tags: [telemetry, ets, genserver, metrics, percentiles, rolling-window]

# Dependency graph
requires:
  - phase: 13-structured-logging
    provides: "Telemetry event catalog with task/agent/FSM/scheduler events"
provides:
  - "AgentCom.MetricsCollector GenServer with ETS-backed telemetry aggregation"
  - "GET /api/metrics endpoint returning full metrics snapshot"
  - "PubSub broadcast on 'metrics' topic every 10 seconds"
  - "Rolling-window metrics with 1-hour window and periodic cleanup"
affects: [14-02-PLAN, 14-03-PLAN, 14-04-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "ETS public table with read_concurrency for cross-process telemetry writes"
    - "Snapshot cache pattern: compute in timer, serve from ETS for zero-cost reads"
    - "Handler health check loop: verify telemetry handlers attached, reattach if detached"

key-files:
  created:
    - "lib/agent_com/metrics_collector.ex"
  modified:
    - "lib/agent_com/application.ex"
    - "lib/agent_com/endpoint.ex"

key-decisions:
  - "ETS :public table for telemetry handlers (they run in emitting process, not MetricsCollector)"
  - "GenServer.cast for duration/transition recording to avoid blocking emitting processes"
  - "Snapshot cache in ETS refreshed every 10s -- /api/metrics reads cache, not live compute"
  - "MetricsCollector placed after Scheduler, before DashboardState in supervision tree"
  - "GET /api/metrics is unauthenticated (same pattern as /api/dashboard/state)"

patterns-established:
  - "Metrics snapshot cache: compute_snapshot() stores in ETS under {:snapshot_cache}, public API reads it"
  - "Telemetry handler IDs prefixed with 'metrics-collector-' to avoid conflicts with 'agent-com-telemetry-logger'"
  - "Rolling window via timestamp-filtered ETS entries with periodic prune"

# Metrics
duration: 5min
completed: 2026-02-12
---

# Phase 14 Plan 01: MetricsCollector Summary

**ETS-backed MetricsCollector GenServer aggregating telemetry into rolling-window metrics with GET /api/metrics endpoint**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-12T10:41:09Z
- **Completed:** 2026-02-12T10:46:08Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- MetricsCollector GenServer with ETS-backed telemetry aggregation covering task lifecycle, agent lifecycle, FSM transitions, and scheduler events
- Snapshot API returning queue_depth (with trend), task_latency (p50/p90/p99), agent_utilization (per-agent + system), error_rates (window + cumulative), and dets_health
- GET /api/metrics endpoint with zero-cost reads from ETS snapshot cache
- Automatic handler health checks with reattachment, 1-hour rolling window cleanup, and 10-second PubSub broadcast

## Task Commits

Each task was committed atomically:

1. **Task 1: Create MetricsCollector GenServer with ETS-backed telemetry aggregation** - `8cd5858` (feat)
2. **Task 2: Add supervision tree entry and GET /api/metrics endpoint** - `921fffc` (feat)

## Files Created/Modified
- `lib/agent_com/metrics_collector.ex` - ETS-backed telemetry aggregation GenServer with snapshot computation, percentile calculation, per-agent utilization, handler health checks
- `lib/agent_com/application.ex` - Added MetricsCollector to supervision tree after Scheduler, before DashboardState
- `lib/agent_com/endpoint.ex` - Added GET /api/metrics endpoint and updated @moduledoc route listing

## Decisions Made
- ETS table is :public with read_concurrency because telemetry handlers run in emitting processes (not MetricsCollector's process)
- Duration data points and FSM transitions are recorded via GenServer.cast to avoid blocking emitting processes during ETS writes
- Snapshot is computed every 10 seconds and cached in ETS -- /api/metrics reads the cache for zero-cost reads
- MetricsCollector placed after Scheduler and before DashboardState so it can attach to telemetry events from Scheduler/TaskQueue and is available before DashboardState starts
- GET /api/metrics is unauthenticated, matching the same pattern as /api/dashboard/state (local network visibility)
- Window counters are reset-on-prune; cumulative counters are never pruned

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- MetricsCollector provides the data aggregation layer needed by Alerter (plan 02)
- PubSub "metrics" topic is broadcasting snapshots for dashboard consumption (plan 04)
- /api/metrics endpoint is live for any API consumers
- Ready for plan 02 (Alerter) which will evaluate alert rules against these metrics

## Self-Check: PASSED

- [x] lib/agent_com/metrics_collector.ex exists
- [x] lib/agent_com/application.ex exists
- [x] lib/agent_com/endpoint.ex exists
- [x] 14-01-SUMMARY.md exists
- [x] Commit 8cd5858 exists
- [x] Commit 921fffc exists

---
*Phase: 14-metrics-alerting*
*Completed: 2026-02-12*
