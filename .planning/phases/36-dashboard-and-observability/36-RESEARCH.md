# Phase 36: Dashboard and Observability - Research

**Researched:** 2026-02-13
**Domain:** Elixir dashboard extension -- Hub FSM visibility, GoalBacklog metrics, CostLedger display
**Confidence:** HIGH

<user_constraints>

## User Constraints (from CONTEXT.md)

### Locked Decisions

- **FSM State Panel:** Current state displayed prominently (Executing/Improving/Contemplating/Resting/Paused). Transition timeline showing state history with timestamps and durations. State duration metrics (how long in each state).
- **Goal Progress:** Goal backlog depth (pending/active/completed counts). Per-goal progress (N of M tasks complete). Goal lifecycle visualization (submitted -> decomposing -> executing -> verifying -> complete).
- **Cost Tracking:** Hub CLI invocation count over time (separate from sidecar execution costs). Per-state invocation breakdown. Budget utilization (current vs configured limits).
- **Implementation Approach:** Extend existing DashboardState GenServer with hub data. WebSocket pushes for real-time updates (existing pattern). uPlot charts for time-series data (invocation rate, goal throughput). HTML/CSS/JS in existing dashboard template.

### Claude's Discretion

- Dashboard layout and panel placement
- Chart types and time ranges
- How much goal detail to show (summary vs drill-down)
- Whether to add a dedicated "Hub" tab or integrate into existing dashboard

### Deferred Ideas (OUT OF SCOPE)

None specified.

</user_constraints>

## Summary

Phase 36 extends the existing AgentCom Command Center dashboard with three new data domains: Hub FSM state visibility, GoalBacklog progress tracking, and CostLedger budget monitoring. The existing dashboard architecture is well-established with a clear pattern: DashboardState GenServer aggregates data from various GenServers, DashboardSocket pushes snapshots and delta events via WebSocket, and Dashboard.render/0 produces a self-contained HTML page with inline CSS/JS and uPlot charting.

The key finding is that **Hub FSM data is already partially integrated** -- DashboardState.snapshot/0 already calls `AgentCom.HubFSM.get_state()` and includes it in the snapshot, DashboardSocket already subscribes to the "hub_fsm" PubSub topic and handles `hub_fsm_state_change` events, and the dashboard already renders a Hub FSM panel with state, cycles, transitions, last change, pause/resume button, and transition timeline. However, **CostLedger and GoalBacklog data are NOT yet included in the dashboard snapshot** and have no dashboard rendering.

The implementation amounts to: (1) adding CostLedger.stats() and GoalBacklog.stats()/list() calls to DashboardState.snapshot/0, (2) subscribing DashboardSocket to the "goals" PubSub topic for real-time goal events, (3) extending the dashboard HTML with new panels for goal progress and cost tracking, and (4) enhancing the existing Hub FSM panel with state duration metrics.

**Primary recommendation:** Extend the existing Dashboard tab with goal progress and cost tracking panels adjacent to the existing Hub FSM panel, rather than creating a new tab. The Hub FSM panel already exists and just needs enhancement.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| uPlot | 1.6.31 | Time-series charting | Already loaded in dashboard (`<script src="https://unpkg.com/uplot@1.6.31/dist/uPlot.iife.min.js">`) |
| Phoenix.PubSub | (bundled) | Real-time event broadcasting | Already used for all dashboard updates |
| WebSock | (bundled) | WebSocket handler | Already powers DashboardSocket |
| Jason | (bundled) | JSON encoding for WebSocket messages | Already used throughout |

### Supporting

No new libraries needed. Everything is already in place.

### Alternatives Considered

None -- locked decision requires using existing patterns and no new frameworks.

## Architecture Patterns

### Existing Dashboard Data Flow

```
GenServers (HubFSM, GoalBacklog, CostLedger)
    |
    v
DashboardState.snapshot/0  <-- aggregates live data via GenServer.call
    |
    v
DashboardSocket            <-- pushes snapshots + delta events via WebSocket
    |
    v
Dashboard.render/0 (HTML)  <-- vanilla JS renders data, uPlot for charts
```

### Pattern 1: Adding Data to DashboardState Snapshot

**What:** Call new GenServer APIs from `handle_call(:snapshot, ...)` and add results to the snapshot map.
**When to use:** For data that should be available on every dashboard refresh.
**Example from existing code:**

```elixir
# In DashboardState.handle_call(:snapshot, _from, state):
# Already done for hub_fsm:
hub_fsm =
  try do
    AgentCom.HubFSM.get_state()
  catch
    :exit, _ -> %{fsm_state: :unknown, paused: false, cycle_count: 0, transition_count: 0}
  end

# NEW -- Add GoalBacklog stats:
goal_stats =
  try do
    AgentCom.GoalBacklog.stats()
  catch
    :exit, _ -> %{by_status: %{}, total: 0}
  end

goal_list =
  try do
    AgentCom.GoalBacklog.list()
  catch
    :exit, _ -> []
  end

# NEW -- Add CostLedger stats:
cost_stats =
  try do
    AgentCom.CostLedger.stats()
  catch
    :exit, _ -> %{hourly: %{}, daily: %{}, session: %{}, budgets: %{}}
  end
```

### Pattern 2: Subscribing to PubSub for Real-Time Events

**What:** Subscribe DashboardSocket to PubSub topics and forward events as WebSocket messages.
**When to use:** For real-time delta updates (goal state changes, cost ledger updates).
**Example from existing code:**

```elixir
# In DashboardSocket.init/1 -- already subscribes to "hub_fsm":
Phoenix.PubSub.subscribe(AgentCom.PubSub, "hub_fsm")

# NEW -- subscribe to "goals" for real-time goal events:
Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")

# Handler for goal events:
def handle_info({:goal_event, payload}, state) do
  formatted = %{
    type: "goal_event",
    data: %{
      event: to_string(payload.event),
      goal_id: payload.goal_id,
      status: to_string(payload.goal.status),
      timestamp: payload.timestamp
    }
  }
  {:ok, %{state | pending_events: [formatted | state.pending_events]}}
end
```

### Pattern 3: Dashboard Panel Rendering (Vanilla JS)

**What:** Add HTML panels and JS render functions following existing dashboard conventions.
**When to use:** For all new dashboard UI elements.
**Example from existing code:**

```html
<!-- Panel structure (from existing Hub FSM panel): -->
<div class="panel" id="panel-hub-fsm">
  <div class="panel-title">Hub FSM</div>
  <div class="throughput-cards">
    <div class="tp-card">
      <div class="tp-value" id="hub-fsm-state">--</div>
      <div class="tp-label">FSM State</div>
    </div>
    <!-- ... more tp-cards ... -->
  </div>
</div>
```

```javascript
// JS render function pattern:
function renderHubFSM(data) {
  if (!data) return;
  var stateEl = document.getElementById('hub-fsm-state');
  stateEl.textContent = data.fsm_state ? String(data.fsm_state) : 'unknown';
  // ... etc
}

// Called from applyFullSnapshot:
function applyFullSnapshot(data) {
  // ...
  renderHubFSM(data.hub_fsm || null);
  // NEW:
  // renderGoalProgress(data.goal_stats || null, data.goal_list || []);
  // renderCostTracking(data.cost_stats || null);
}
```

### Pattern 4: uPlot Time-Series Chart

**What:** Create uPlot chart instances for time-series data.
**When to use:** For invocation rate over time, goal throughput.
**Already loaded:** uPlot 1.6.31 is already included in the dashboard HTML.

```javascript
// uPlot chart initialization pattern (already used in metrics tab):
var opts = {
  width: containerWidth,
  height: 200,
  series: [
    {},  // x-axis (timestamps)
    { label: 'Invocations', stroke: '#4ade80', fill: 'rgba(74,222,128,0.1)' }
  ],
  axes: [
    { stroke: '#666', grid: { stroke: '#2a2a3a' } },
    { stroke: '#666', grid: { stroke: '#2a2a3a' } }
  ],
  scales: { x: { time: true } }
};
var chart = new uPlot(opts, data, container);
```

### Recommended Layout

Based on analysis of the existing dashboard structure and the locked decisions:

**Recommendation: Extend existing Dashboard tab, not a new tab.**

Rationale: The Hub FSM panel already exists in the Dashboard tab. Goal progress and cost tracking are closely related to the Hub FSM state. Adding them adjacent to the Hub FSM panel maintains logical grouping. The existing two-tab layout (Dashboard, Metrics) is clean; adding a third tab fragments attention.

**Proposed panel arrangement (after existing Repo Registry panel):**

1. **Hub FSM panel** -- Already exists. Enhance with state duration metrics.
2. **Goal Progress panel** -- NEW. Backlog depth cards + per-goal lifecycle table/kanban.
3. **Cost Tracking panel** -- NEW. Budget utilization gauges + invocation rate chart.

### Anti-Patterns to Avoid

- **Anti-pattern: Adding new JS frameworks or dependencies.** The dashboard is self-contained with inline vanilla JS. Adding React, Vue, or even a CSS framework would violate the existing architecture.
- **Anti-pattern: Making CostLedger GenServer.call from the hot path.** CostLedger.check_budget/1 reads directly from ETS for zero latency. Dashboard reads should use CostLedger.stats/0 via GenServer.call, which is fine since dashboard updates are low-frequency (snapshots every ~10s).
- **Anti-pattern: Polling CostLedger history on every dashboard tick.** CostLedger has no PubSub broadcast. The stats/0 call in DashboardState.snapshot/0 is sufficient; history/0 is too heavy for real-time polling.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Time-series charting | Custom canvas renderer | uPlot (already loaded) | Already integrated, performant, well-tested |
| Real-time updates | HTTP polling | WebSocket via DashboardSocket (existing) | Already implemented, supports batched events |
| State aggregation | Direct GenServer.calls from JS | DashboardState.snapshot/0 (existing) | Centralizes data access, single point of truth |
| Progress bars | Custom SVG/canvas bars | CSS `width: N%` on styled divs | Simple, matches existing dashboard style |
| Budget gauges | D3.js or Chart.js | CSS percentage bars with color coding | No new dependencies, matches existing minimal aesthetic |

**Key insight:** The entire dashboard rendering pipeline already exists. This phase is purely about adding new data sources to the existing pipeline and rendering new panels in the existing HTML template.

## Common Pitfalls

### Pitfall 1: Large Snapshot Bloat from Goal List

**What goes wrong:** Including ALL goal data (description, metadata, file_hints, history) in every snapshot makes the WebSocket payload enormous when many goals exist.
**Why it happens:** GoalBacklog.list/0 returns full goal maps with all fields.
**How to avoid:** Only include summary data in the snapshot: `{id, description (truncated), status, priority, child_task_ids count, created_at, updated_at}`. Full goal detail should be fetched on-demand via the existing `/api/goals/:goal_id` endpoint.
**Warning signs:** Dashboard reconnect takes > 500ms, browser console shows large JSON payloads.

### Pitfall 2: CostLedger Has No PubSub -- No Real-Time Cost Updates

**What goes wrong:** Expecting real-time cost tracking updates via WebSocket, but CostLedger only emits telemetry events, not PubSub broadcasts.
**Why it happens:** CostLedger was designed for budget gating, not dashboard observability.
**How to avoid:** Two options: (a) Accept that cost data refreshes only on snapshot requests (~10s intervals), or (b) add a lightweight PubSub broadcast in CostLedger.record_invocation/2. Option (a) is simpler and acceptable since invocations are infrequent (max 20/hour for executing state).
**Warning signs:** Cost display appears stale compared to other dashboard data.

### Pitfall 3: Dashboard.ex File Size

**What goes wrong:** dashboard.ex is already 43,000+ tokens (extremely large single file). Adding three new panels with HTML/CSS/JS will push it further.
**Why it happens:** The dashboard is a single self-contained HTML page with inline everything.
**How to avoid:** Keep new panel code compact. Use the existing CSS class patterns (`.panel`, `.panel-title`, `.throughput-cards`, `.tp-card`, `.tp-value`, `.tp-label`) rather than defining new classes where possible. Consider extracting the render/0 function body into a separate template file if size becomes unmanageable, but this is a discretionary concern.
**Warning signs:** Editor/IDE sluggishness, compilation times increasing.

### Pitfall 4: HubFSM States Don't Match CONTEXT.md

**What goes wrong:** CONTEXT.md mentions 5 states (Executing/Improving/Contemplating/Resting/Paused), but HubFSM.ex only has 2 states (`:resting`, `:executing`) plus a `paused` boolean flag.
**Why it happens:** The HubFSM was simplified to a 2-state core. Improving and Contemplating states were not implemented.
**How to avoid:** Display what actually exists: `:resting` and `:executing` as FSM states, with `paused` as a badge/overlay. The color mapping in the dashboard already handles this -- `hubFsmStateColors` has colors for `executing`, `resting`, `improving`, `contemplating`, `unknown`. If only 2 states exist, the other colors are just future-proofing.
**Warning signs:** UI shows "Improving" or "Contemplating" states that never actually occur.

### Pitfall 5: Goal child_task_ids Progress Tracking

**What goes wrong:** Per-goal progress display ("N of M tasks complete") requires checking task status for each child_task_id, which means N calls to TaskQueue.
**Why it happens:** GoalBacklog stores child_task_ids but doesn't track their completion status.
**How to avoid:** In DashboardState snapshot, compute progress for active goals only (status = decomposing, executing, verifying). For each, look up child_task_ids status via TaskQueue.list() with task_id filter. Cap at top 10 active goals to limit calls.
**Warning signs:** Snapshot computation time increases linearly with goal count.

## Code Examples

### Adding GoalBacklog Data to Snapshot

```elixir
# In DashboardState.handle_call(:snapshot, _from, state):

goal_stats =
  try do
    AgentCom.GoalBacklog.stats()
  catch
    :exit, _ -> %{by_status: %{}, by_priority: %{}, total: 0}
  end

# Only fetch active goals for progress tracking (not all goals)
active_goals =
  try do
    [:decomposing, :executing, :verifying]
    |> Enum.flat_map(fn status -> AgentCom.GoalBacklog.list(%{status: status}) end)
    |> Enum.map(fn goal ->
      child_count = length(goal.child_task_ids)
      completed_count = count_completed_tasks(goal.child_task_ids)
      %{
        id: goal.id,
        description: String.slice(goal.description, 0, 100),
        status: goal.status,
        priority: goal.priority,
        tasks_total: child_count,
        tasks_complete: completed_count,
        created_at: goal.created_at,
        updated_at: goal.updated_at
      }
    end)
  catch
    :exit, _ -> []
  end

# Add to snapshot map:
snapshot = %{
  # ... existing fields ...
  goal_stats: goal_stats,
  active_goals: active_goals,
  cost_stats: cost_stats
}
```

### Adding CostLedger Data to Snapshot

```elixir
cost_stats =
  try do
    AgentCom.CostLedger.stats()
  catch
    :exit, _ -> %{
      hourly: %{executing: 0, improving: 0, contemplating: 0, total: 0},
      daily: %{executing: 0, improving: 0, contemplating: 0, total: 0},
      session: %{executing: 0, improving: 0, contemplating: 0, total: 0},
      budgets: %{
        executing: %{hourly_limit: 20, daily_limit: 100},
        improving: %{hourly_limit: 10, daily_limit: 40},
        contemplating: %{hourly_limit: 5, daily_limit: 15}
      }
    }
  end
```

### Goal Progress Panel HTML

```html
<div class="panel" id="panel-goal-progress">
  <div class="panel-title">Goal Progress <span class="panel-count" id="goal-count">0</span></div>
  <div class="throughput-cards">
    <div class="tp-card">
      <div class="tp-value" id="goal-pending">0</div>
      <div class="tp-label">Pending</div>
    </div>
    <div class="tp-card">
      <div class="tp-value" id="goal-active">0</div>
      <div class="tp-label">Active</div>
    </div>
    <div class="tp-card">
      <div class="tp-value" id="goal-complete">0</div>
      <div class="tp-label">Complete</div>
    </div>
  </div>
  <div id="goal-lifecycle-list" style="margin-top: 10px; max-height: 300px; overflow-y: auto;">
    <!-- Per-goal progress rows rendered by JS -->
  </div>
  <div id="goal-empty" class="empty-state">No active goals</div>
</div>
```

### Cost Tracking Panel HTML

```html
<div class="panel" id="panel-cost-tracking">
  <div class="panel-title">Hub Invocation Costs</div>
  <div class="throughput-cards">
    <div class="tp-card">
      <div class="tp-value" id="cost-hourly-total">0</div>
      <div class="tp-label">This Hour</div>
    </div>
    <div class="tp-card">
      <div class="tp-value" id="cost-daily-total">0</div>
      <div class="tp-label">Today</div>
    </div>
    <div class="tp-card">
      <div class="tp-value" id="cost-session-total">0</div>
      <div class="tp-label">Session</div>
    </div>
  </div>
  <!-- Per-state budget bars -->
  <div id="cost-budget-bars" style="margin-top: 10px;">
    <!-- Rendered by JS: colored bars showing usage vs limit -->
  </div>
</div>
```

### Budget Utilization Bar (JS)

```javascript
function renderBudgetBar(state, hourlyUsed, hourlyLimit, dailyUsed, dailyLimit) {
  var hourlyPct = hourlyLimit > 0 ? Math.min(100, (hourlyUsed / hourlyLimit) * 100) : 0;
  var dailyPct = dailyLimit > 0 ? Math.min(100, (dailyUsed / dailyLimit) * 100) : 0;
  var hourlyColor = hourlyPct > 80 ? '#ef4444' : hourlyPct > 50 ? '#fbbf24' : '#4ade80';
  var dailyColor = dailyPct > 80 ? '#ef4444' : dailyPct > 50 ? '#fbbf24' : '#4ade80';

  return '<div style="margin-bottom: 8px;">'
    + '<div style="color: #aaa; font-size: 0.8em; margin-bottom: 2px;">' + state + '</div>'
    + '<div style="display: flex; gap: 8px; align-items: center;">'
    + '<span style="font-size: 0.75em; color: #888; width: 50px;">Hourly</span>'
    + '<div style="flex: 1; background: #1a1a2e; border-radius: 3px; height: 12px;">'
    + '<div style="width: ' + hourlyPct + '%; background: ' + hourlyColor + '; height: 100%; border-radius: 3px;"></div>'
    + '</div>'
    + '<span style="font-size: 0.75em; color: #aaa; width: 60px; text-align: right;">' + hourlyUsed + '/' + hourlyLimit + '</span>'
    + '</div>'
    + '<div style="display: flex; gap: 8px; align-items: center; margin-top: 2px;">'
    + '<span style="font-size: 0.75em; color: #888; width: 50px;">Daily</span>'
    + '<div style="flex: 1; background: #1a1a2e; border-radius: 3px; height: 12px;">'
    + '<div style="width: ' + dailyPct + '%; background: ' + dailyColor + '; height: 100%; border-radius: 3px;"></div>'
    + '</div>'
    + '<span style="font-size: 0.75em; color: #aaa; width: 60px; text-align: right;">' + dailyUsed + '/' + dailyLimit + '</span>'
    + '</div>'
    + '</div>';
}
```

### Goal Lifecycle Row (JS)

```javascript
function renderGoalRow(goal) {
  var stages = ['submitted', 'decomposing', 'executing', 'verifying', 'complete'];
  var currentIdx = stages.indexOf(goal.status);
  var progressPct = goal.tasks_total > 0 ? Math.round((goal.tasks_complete / goal.tasks_total) * 100) : 0;

  var stageHtml = stages.map(function(stage, i) {
    var cls = i < currentIdx ? 'done' : (i === currentIdx ? 'active' : '');
    return '<span class="tt-step ' + cls + '">'
      + '<span class="tt-dot"></span>'
      + '<span style="font-size: 0.75em;">' + stage.charAt(0).toUpperCase() + '</span>'
      + '</span>';
  }).join('<span class="tt-arrow">&rarr;</span>');

  return '<div style="padding: 6px 0; border-bottom: 1px solid #2a2a3a;">'
    + '<div style="display: flex; justify-content: space-between; align-items: center;">'
    + '<span style="color: #e0e0e0; font-size: 0.85em;">' + escapeHtml(goal.description.substring(0, 60)) + '</span>'
    + '<span style="color: #888; font-size: 0.8em;">' + goal.tasks_complete + '/' + goal.tasks_total + ' tasks</span>'
    + '</div>'
    + '<div style="display: flex; align-items: center; gap: 4px; margin-top: 4px;">' + stageHtml + '</div>'
    + '</div>';
}
```

## Existing Infrastructure Summary

### What Already Exists (No Work Needed)

| Component | Status | Notes |
|-----------|--------|-------|
| DashboardState GenServer | EXISTS | Aggregates data from all GenServers |
| DashboardSocket WebSocket | EXISTS | Pushes snapshots + batched events |
| Dashboard.render/0 HTML | EXISTS | Self-contained page with inline CSS/JS |
| uPlot charting | EXISTS | Already loaded (1.6.31) |
| Hub FSM panel | EXISTS | State, cycles, transitions, timeline, pause/resume |
| Hub FSM PubSub subscription | EXISTS | DashboardSocket subscribes to "hub_fsm" |
| Hub FSM state in snapshot | EXISTS | `AgentCom.HubFSM.get_state()` in snapshot |
| GoalBacklog GenServer | EXISTS | stats/0, list/1, get/1 API |
| GoalBacklog PubSub | EXISTS | Broadcasts on "goals" topic |
| CostLedger GenServer | EXISTS | stats/0, history/1 API |
| Goal API endpoints | EXISTS | POST/GET /api/goals, PATCH transition |
| Hub API endpoints | EXISTS | GET /api/hub/state, /api/hub/history |

### What Needs to Be Built

| Component | Work | Complexity |
|-----------|------|------------|
| GoalBacklog data in snapshot | Add stats + active goals to DashboardState.snapshot/0 | LOW |
| CostLedger data in snapshot | Add stats to DashboardState.snapshot/0 | LOW |
| Goals PubSub in DashboardSocket | Subscribe + handle goal events | LOW |
| DashboardState goals subscription | Subscribe to "goals" PubSub | LOW |
| Goal Progress panel HTML/CSS/JS | New panel with cards, lifecycle rows, progress bars | MEDIUM |
| Cost Tracking panel HTML/CSS/JS | New panel with budget bars, invocation counts | MEDIUM |
| Hub FSM state duration enhancement | Add duration display to existing panel | LOW |
| uPlot chart for invocation rate | Optional time-series chart | MEDIUM |
| WebSocket event handling (JS) | Handle goal_event type in event switch | LOW |
| CostLedger API endpoint | Optional: GET /api/hub/costs (no auth, for dashboard) | LOW |

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Polling DashboardState.snapshot | WebSocket push with batched events | Already implemented | Real-time updates without polling overhead |
| Full snapshot on every event | Delta events + periodic snapshot | Already implemented | Reduced bandwidth and processing |

**Deprecated/outdated:**
- Nothing deprecated. The existing dashboard architecture is current and well-maintained.

## Open Questions

1. **Whether to add a CostLedger PubSub broadcast**
   - What we know: CostLedger emits telemetry but not PubSub. Hub invocations are infrequent (max 20/hour).
   - What's unclear: Whether the user cares about sub-10-second cost update latency.
   - Recommendation: Skip PubSub for CostLedger. Snapshot refresh every ~10s is sufficient for invocation counts that change max 20 times per hour. Add as future enhancement if needed.

2. **Goal progress computation cost**
   - What we know: Computing "N of M tasks complete" requires looking up each child_task_id's status via TaskQueue.
   - What's unclear: How many child_task_ids a typical goal has; whether TaskQueue.list(status: X) can filter by task_id list efficiently.
   - Recommendation: Compute progress only for active goals (not historical). Cap at top 10 active goals in the snapshot to bound computation cost.

3. **uPlot chart data source for invocation rate**
   - What we know: CostLedger.history/1 can return time-series data, but polling it on every snapshot is expensive (DETS scan).
   - What's unclear: Whether a ring buffer in DashboardState for recent invocations would be more efficient.
   - Recommendation: Use CostLedger.stats/0 for aggregate numbers (hourly/daily/session counts). Skip the time-series chart initially -- aggregate budget bars provide the critical information. Add uPlot chart as a follow-up if needed.

## Sources

### Primary (HIGH confidence)

- **Codebase inspection** (all findings verified by reading source code):
  - `lib/agent_com/dashboard.ex` -- Dashboard HTML rendering (inline CSS/JS, uPlot 1.6.31)
  - `lib/agent_com/dashboard_state.ex` -- State aggregation GenServer with snapshot/0
  - `lib/agent_com/dashboard_socket.ex` -- WebSocket handler with PubSub subscriptions
  - `lib/agent_com/dashboard_notifier.ex` -- Push notification GenServer
  - `lib/agent_com/hub_fsm.ex` -- 2-state FSM (resting/executing) with pause/resume
  - `lib/agent_com/hub_fsm/history.ex` -- ETS history with negated timestamp ordering
  - `lib/agent_com/hub_fsm/predicates.ex` -- Pure transition predicates
  - `lib/agent_com/cost_ledger.ex` -- DETS+ETS invocation tracking with budget caps
  - `lib/agent_com/goal_backlog.ex` -- DETS goal storage with lifecycle state machine
  - `lib/agent_com/endpoint.ex` -- HTTP routes including goal and hub APIs

### Secondary (MEDIUM confidence)

- uPlot API knowledge from training data (v1.6.x API is stable)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- everything needed is already present in the codebase
- Architecture: HIGH -- extending well-documented existing patterns
- Pitfalls: HIGH -- identified through actual code analysis of data sizes and computation costs

**Research date:** 2026-02-13
**Valid until:** 2026-03-13 (stable internal architecture)
