# Phase 14: Metrics + Alerting - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Expose system health metrics via a GET /api/metrics endpoint (queue depth, task latency percentiles, agent utilization, error rates) and a configurable alerter that monitors thresholds and broadcasts alerts to the dashboard within 60 seconds. Alert thresholds are changeable via the Config store without restart. Phase 13 (telemetry events) must exist first — this phase aggregates those events into metrics and acts on them.

</domain>

<decisions>
## Implementation Decisions

### Metrics content
- Expose: queue depth, task latency percentiles (p50, p90, p99), agent utilization (per-agent + system-wide aggregate), error rates
- Return both cumulative totals and a recent rolling window for current health
- Whether to consolidate DETS health into the metrics endpoint: Claude's discretion

### Alert rules
- Two severity levels: WARNING (slow degradation — queue growing, high failure rate) and CRITICAL (immediate — stuck tasks, no agents online)
- Default alert rules: Claude's discretion (sensible defaults vs blank slate)
- Stuck task definition: Claude's discretion (based on existing TaskQueue/AgentFSM state model)
- Threshold storage: Claude's discretion (success criteria says "Config store without restarting" which points to DETS Config)

### Alert delivery
- Dashboard + push notifications for all alert events (same pattern as DETS compaction failures)
- Cooldown period between repeated alerts for the same condition — configurable per alert type
- CRITICAL alerts bypass cooldown and always fire immediately
- WARNING alerts respect cooldown
- Alerts have an "acknowledged" state — operators can acknowledge to suppress repeat notifications; resets if condition clears and returns

### Dashboard presentation
- Dedicated metrics tab/page separate from the main dashboard
- Full time-series charts for metrics visualization
- Active alerts visible as a banner/strip on the main dashboard (not just the metrics page)
- Metrics page refresh mechanism: Claude's discretion (real-time WebSocket vs polling)

### Claude's Discretion
- Whether to consolidate DETS health into the metrics endpoint or keep separate
- Default alert thresholds and which rules ship out-of-the-box
- Stuck task detection strategy (time-based vs state-based)
- Alert threshold storage mechanism (DETS Config store is implied by success criteria)
- Metrics page refresh approach (WebSocket vs polling)
- Charting library choice for time-series visualization

</decisions>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 14-metrics-alerting*
*Context gathered: 2026-02-12*
