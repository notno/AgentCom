# Phase 6: Dashboard - Context

**Gathered:** 2026-02-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Real-time observability dashboard showing queue depth, agent states, task flow, and system health. Nathan can see the full state of the system at a glance without asking any agent. Dashboard is read-focused with optional safe actions (Claude's discretion). No task creation, agent management, or configuration — those happen via CLI/API.

</domain>

<decisions>
## Implementation Decisions

### Information layout
- Command center style — dense grid layout with multiple panels visible at once (Grafana/Datadog inspiration)
- Agent display: compact table (row per agent — name, state, task, last seen)
- Queue display: summary counts by priority lane at top, expandable full task list below
- Dark theme — dark background with bright accents
- PR links: placeholder column in task table, empty until Phase 7 wires it up
- LiveView-style implementation — real-time server-push, no page reloads

### Refresh & liveness
- Server-push via WebSocket — hub pushes state changes to dashboard in real-time
- Subtle transitions on state changes — fade/highlight briefly so changes are noticeable, queue counts animate
- Visible connection indicator — green dot / "Connected" badge, turns red/yellow on disconnect
- Auto-reconnect with exponential backoff — same pattern as sidecar, no manual reload needed

### Task flow visibility
- Recent tasks shown as sortable/filterable table (columns: task, agent, status, duration, tokens)
- Failed/dead-letter tasks in a separate dedicated panel for quick scanning
- Throughput metrics: tasks completed in last hour, average completion time, total tokens used

### Health & alerts
- Hub uptime displayed prominently at top
- Browser push notifications when agent goes offline or queue stalls

### Claude's Discretion
- Action buttons on dashboard (view-only vs basic safe actions like retry failed task)
- Historical data time window (how far back recent activity goes)
- Active assignments display (separate panel vs column in agent table)
- Health heuristics (what defines unhealthy — agent offline, queue growing, failure rate)
- Overall health summary format (traffic light vs status bar vs other)

</decisions>

<specifics>
## Specific Ideas

- Command center feel like Grafana — multiple panels, dense information, everything visible without scrolling
- Dark theme consistent with terminal/ops aesthetic
- LiveView-style for real-time updates without page reloads — leverages existing hub WebSocket infrastructure
- Reconnection should feel invisible — same resilience pattern as sidecar

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 06-dashboard*
*Context gathered: 2026-02-10*
