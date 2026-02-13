# Phase 36: Dashboard and Observability - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Extend existing HTML dashboard with Hub FSM visibility: FSM state display, goal progress tracking, goal backlog depth, and hub CLI invocation cost tracking. Follows existing uPlot/WebSocket patterns from v1.1 dashboard.
</domain>

<decisions>
## Implementation Decisions

### FSM State Panel
- Current state displayed prominently (Executing/Improving/Contemplating/Resting/Paused)
- Transition timeline showing state history with timestamps and durations
- State duration metrics (how long in each state)

### Goal Progress
- Goal backlog depth (pending/active/completed counts)
- Per-goal progress (N of M tasks complete)
- Goal lifecycle visualization (submitted -> decomposing -> executing -> verifying -> complete)

### Cost Tracking
- Hub CLI invocation count over time (separate from sidecar execution costs)
- Per-state invocation breakdown
- Budget utilization (current vs configured limits)

### Implementation Approach
- Extend existing DashboardState GenServer with hub data
- WebSocket pushes for real-time updates (existing pattern)
- uPlot charts for time-series data (invocation rate, goal throughput)
- HTML/CSS/JS in existing dashboard template

### Claude's Discretion
- Dashboard layout and panel placement
- Chart types and time ranges
- How much goal detail to show (summary vs drill-down)
- Whether to add a dedicated "Hub" tab or integrate into existing dashboard
</decisions>

<specifics>
## Specific Ideas

- FSM state could be color-coded (green=Executing, blue=Improving, yellow=Contemplating, gray=Resting, red=Paused)
- Goal progress could show a Kanban-style board (backlog -> in progress -> done)
- Cost panel should show "invocations remaining today" if daily budgets are set
</specifics>

<constraints>
## Constraints

- Depends on Phase 25 (CostLedger data), Phase 27 (GoalBacklog data), Phase 29 (HubFSM state)
- Must follow existing dashboard patterns (no new frameworks)
- Real-time updates via existing WebSocket infrastructure
- No external charting dependencies beyond existing uPlot
</constraints>
