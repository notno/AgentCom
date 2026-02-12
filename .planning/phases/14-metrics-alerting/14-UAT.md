---
status: testing
phase: 14-metrics-alerting
source: 14-01-SUMMARY.md, 14-02-SUMMARY.md, 14-03-SUMMARY.md, 14-04-SUMMARY.md
started: 2026-02-12T11:15:00Z
updated: 2026-02-12T11:15:00Z
---

## Current Test
<!-- OVERWRITE each test - shows where we are -->

number: 9
name: Alert acknowledgment works
expected: |
  If an alert is active, the Metrics tab "Active Alerts" section shows it
  with an "Acknowledge" button. Click Acknowledge — the button should disable
  and the alert card should show an "Acknowledged" badge. The alert banner
  should update (remove acknowledged alerts from count, hide if all acknowledged).
awaiting: user response

## Tests

### 1. GET /api/metrics returns metrics JSON
expected: Run `curl http://localhost:4000/api/metrics | jq .`. Response is JSON with top-level keys: timestamp, window_ms, queue_depth, task_latency, agent_utilization, error_rates, dets_health. queue_depth has "current" and "trend". task_latency has "window" and "cumulative" with p50/p90/p99. agent_utilization has "system" and "per_agent". error_rates has "window" and "cumulative".
result: pass

### 2. GET /api/alerts returns alert list
expected: Run `curl http://localhost:4000/api/alerts | jq .`. Response is JSON with "alerts" array (may be empty if no conditions are triggered) and "timestamp" field. No auth required.
result: pass

### 3. GET /api/config/alert-thresholds returns defaults
expected: Run `curl http://localhost:4000/api/config/alert-thresholds -H "Authorization: Bearer TOKEN"` (use a valid agent token). Response is JSON with threshold fields including queue_growing_checks, failure_rate_pct, stuck_task_ms, error_count_hour, check_interval_ms, and a cooldowns map.
result: pass

### 4. PUT /api/config/alert-thresholds updates thresholds
expected: Run `curl -X PUT http://localhost:4000/api/config/alert-thresholds -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" -d '{"check_interval_ms": 15000}'`. Response includes "status": "updated" and "effective": "next_check_cycle". GET the thresholds again to confirm the change persisted.
result: pass

### 5. Dashboard loads with tab navigation
expected: Visit http://localhost:4000/dashboard in a browser. Page loads with a tab bar at the top showing "Dashboard" and "Metrics" tabs. The Dashboard tab is active by default and shows the existing dashboard content (agents, tasks, health).
result: pass

### 6. Metrics tab shows charts and summary cards
expected: Click the "Metrics" tab. The page shows: 4 summary metric cards (Queue Depth, Task Latency p50, Agent Utilization, Error Rate), 4 chart containers (Queue Depth, Task Latency, Agent Utilization, Error Rate), an Active Alerts section, and a Per-Agent Metrics table. Charts may be empty initially.
result: pass

### 7. Metrics update in real time via WebSocket
expected: Stay on the Metrics tab for 20-30 seconds. Summary cards should update with actual values (queue depth number, latency ms, utilization %, error rate). Charts should show data points accumulating as time passes. If no agents are connected, values may be zero but should still update.
result: pass

### 8. Alert banner appears when alerts are active
expected: If no agents are connected, the "no_agents_online" CRITICAL alert should fire after ~30 seconds (startup delay). A red/amber alert banner should appear at the top of the page (visible on both Dashboard and Metrics tabs) showing the count of active alerts. Click "Details" to expand the alert details.
result: pass

### 9. Alert acknowledgment works
expected: If an alert is active, the Metrics tab "Active Alerts" section shows it with an "Acknowledge" button. Click Acknowledge — the button should disable and the alert card should show an "Acknowledged" badge. The alert banner should update (remove acknowledged alerts from count, hide if all acknowledged).
result: [pending]

## Summary

total: 9
passed: 8
issues: 0
pending: 1
skipped: 0

## Gaps

[none yet]
