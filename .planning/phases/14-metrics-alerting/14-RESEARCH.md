# Phase 14: Metrics + Alerting - Research

**Researched:** 2026-02-12
**Domain:** Telemetry aggregation, metrics endpoints, alerting systems, time-series dashboard visualization
**Confidence:** HIGH

## Summary

This phase aggregates the telemetry events emitted by Phase 13 into actionable metrics and alerts. The existing system already has: (1) a complete telemetry event catalog in `AgentCom.Telemetry` covering task lifecycle, agent lifecycle, FSM transitions, scheduler operations, and DETS operations; (2) an ETS-backed `Analytics` GenServer with hourly bucketed message counts; (3) a `DashboardState` GenServer that already computes health heuristics (queue growing, high failure rate, stuck tasks, agent offline, DETS health); and (4) a `DashboardNotifier` GenServer that sends push notifications when health degrades. The dashboard itself is a self-contained inline HTML page with CSS and vanilla JavaScript served from `AgentCom.Dashboard`, connected via WebSocket at `/ws/dashboard`.

The architecture strategy is to build a new `AgentCom.MetricsCollector` GenServer that attaches to telemetry events and maintains rolling-window aggregations in ETS (queue depth gauge, task latency percentile histograms, per-agent utilization tracking, error rate counters). A new `AgentCom.Alerter` GenServer monitors these metrics on a configurable check cycle (default 30s), evaluates alert rules loaded from the Config store (DETS), manages cooldowns and acknowledgment state, and broadcasts alerts via PubSub. The existing `DashboardNotifier` pattern is extended to handle alert events. A new `GET /api/metrics` endpoint exposes the aggregated data. The dashboard gains an alert banner on the main page and a dedicated metrics tab with time-series charts using uPlot (~50KB, zero-dependency, Canvas-based).

The key insight is that DashboardState already does 70% of the health-checking work. Phase 14 formalizes this into a proper metrics aggregation pipeline (telemetry events -> MetricsCollector -> Alerter) with configurable thresholds stored in the Config DETS store, rather than the hardcoded heuristics currently in DashboardState.

**Primary recommendation:** Build MetricsCollector (ETS-backed telemetry aggregation with rolling windows), Alerter (configurable rule evaluator with cooldown/ack), and extend the dashboard with uPlot charts and an alert banner. Store alert thresholds in Config DETS for hot-reload without restart.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Metrics content
- Expose: queue depth, task latency percentiles (p50, p90, p99), agent utilization (per-agent + system-wide aggregate), error rates
- Return both cumulative totals and a recent rolling window for current health
- Whether to consolidate DETS health into the metrics endpoint: Claude's discretion

#### Alert rules
- Two severity levels: WARNING (slow degradation -- queue growing, high failure rate) and CRITICAL (immediate -- stuck tasks, no agents online)
- Default alert rules: Claude's discretion (sensible defaults vs blank slate)
- Stuck task definition: Claude's discretion (based on existing TaskQueue/AgentFSM state model)
- Threshold storage: Claude's discretion (success criteria says "Config store without restarting" which points to DETS Config)

#### Alert delivery
- Dashboard + push notifications for all alert events (same pattern as DETS compaction failures)
- Cooldown period between repeated alerts for the same condition -- configurable per alert type
- CRITICAL alerts bypass cooldown and always fire immediately
- WARNING alerts respect cooldown
- Alerts have an "acknowledged" state -- operators can acknowledge to suppress repeat notifications; resets if condition clears and returns

#### Dashboard presentation
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

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

## Discretion Recommendations

### 1. Consolidate DETS health into the metrics endpoint: YES

**Recommendation:** Include DETS health data in the `/api/metrics` response under a `dets_health` key.

**Rationale:** The metrics endpoint should be a single source of truth for system health. Currently DETS health is available only via `GET /api/admin/dets-health` (auth required). Including it in `/api/metrics` (no auth, same as `/api/dashboard/state`) centralizes all observability data. The DETS health data is already computed by `DetsBackup.health_metrics/0` and consumed by `DashboardState.compute_health/3`. Including it in the metrics endpoint costs nothing (one extra function call) and eliminates the need for dashboard clients to make separate requests.

### 2. Default alert thresholds: Ship sensible defaults

**Recommendation:** Ship 5 default alert rules with conservative thresholds. All thresholds configurable via Config store.

**Default rules:**

| Rule ID | Severity | Condition | Default Threshold | Rationale |
|---------|----------|-----------|-------------------|-----------|
| `queue_growing` | WARNING | Queue depth increasing for N consecutive checks | 3 consecutive increases (existing `DashboardState` logic) | Already proven in DashboardState |
| `high_failure_rate` | WARNING | Failure rate exceeds threshold in rolling window | >50% failure rate over last hour (existing logic) | Already proven in DashboardState |
| `stuck_tasks` | CRITICAL | Tasks assigned for longer than threshold with no progress | >5 minutes with no `updated_at` change | Matches existing `@stuck_task_threshold_ms 300_000` in DashboardState and `@stuck_threshold_ms 300_000` in Scheduler |
| `no_agents_online` | CRITICAL | Zero agents connected | 0 agents in FSM registry | Immediate -- no work can be processed |
| `high_error_rate` | WARNING | Error rate (task failures per hour) exceeds threshold | >10 failures per hour | Absolute count catches degradation even with low throughput |

**Why sensible defaults over blank slate:** Operators should get value immediately without configuration. The existing `DashboardState.compute_health/3` already hardcodes these exact checks. Phase 14 extracts them into configurable rules with the same proven defaults. Blank slate would mean zero alerts until someone configures every rule -- a worse experience.

### 3. Stuck task detection: Hybrid time-based + state-based

**Recommendation:** Use time-based detection (task `updated_at` > threshold) as primary, with state awareness (only check `:assigned` status tasks).

**Rationale:** The current codebase already uses this exact strategy in two places:
- `DashboardState.compute_health/3`: Checks assigned tasks where `now - updated_at > @stuck_task_threshold_ms` (5 minutes)
- `Scheduler.handle_info(:sweep_stuck, ...)`: Checks assigned tasks where `task.updated_at < threshold` (5 minutes)

Pure state-based detection (e.g., "in `:assigned` state too long") would miss tasks that are `:working` but actually hung. Pure time-based without state filtering would flag completed tasks. The hybrid approach is already battle-tested in the codebase.

The `TaskQueue.update_progress/1` cast function provides the heartbeat mechanism -- sidecars that call this reset the `updated_at` timestamp, preventing false positives for long-running legitimate tasks.

### 4. Alert threshold storage: Config DETS store with atom keys

**Recommendation:** Store alert thresholds in the existing `AgentCom.Config` GenServer (DETS-backed) using atom keys prefixed with `alert_`.

**Implementation:**
```elixir
# Store thresholds as a single map under one key
Config.put(:alert_thresholds, %{
  queue_growing_checks: 3,
  failure_rate_pct: 50,
  stuck_task_ms: 300_000,
  error_count_hour: 10,
  check_interval_ms: 30_000,
  cooldowns: %{
    queue_growing: 300_000,       # 5 min
    high_failure_rate: 600_000,   # 10 min
    stuck_tasks: 0,               # CRITICAL - no cooldown
    no_agents_online: 0,          # CRITICAL - no cooldown
    high_error_rate: 300_000      # 5 min
  }
})
```

**Rationale:** The success criteria explicitly states "Alert thresholds can be changed via the Config store without restarting the hub." The Config GenServer already provides `get/1` and `put/2` with DETS persistence and sync. Storing all thresholds as a single map under one atom key keeps the Config store clean (one key instead of 10+). The Alerter reads thresholds on each check cycle, so changes take effect immediately on the next evaluation.

### 5. Metrics page refresh: WebSocket (extend existing `/ws/dashboard`)

**Recommendation:** Use the existing WebSocket connection at `/ws/dashboard` to push metrics updates, rather than adding a polling mechanism.

**Rationale:** The dashboard already has a real-time WebSocket connection via `DashboardSocket` with event batching (100ms flush interval). Adding metrics data to the existing snapshot and event stream is simpler than creating a new polling endpoint. The MetricsCollector can broadcast on PubSub topic `"metrics"`, and DashboardSocket subscribes to it alongside the existing "tasks", "presence", and "backups" topics.

The alternative (polling with `setInterval`) would require the client to manage a second data refresh loop with its own reconnection logic, error handling, and state management. The WebSocket approach is consistent with the existing architecture and provides sub-second updates without polling overhead.

**Implementation:** Add a `metrics_snapshot` message type that DashboardSocket pushes every 10 seconds (configurable), containing the current aggregated metrics. The metrics tab in the dashboard uses this stream to update charts.

### 6. Charting library: uPlot

**Recommendation:** Use uPlot (~50KB minified+gzipped, zero dependencies, Canvas 2D-based) loaded via CDN `<script>` tag in the dashboard HTML.

**Rationale:** The dashboard is a self-contained HTML page with inline CSS and vanilla JavaScript (no build step, no npm, no bundler). The charting library must:
1. Work with a `<script>` tag (CDN or inline)
2. Have zero dependencies
3. Handle time-series data efficiently
4. Support real-time updates (data appended on WebSocket push)
5. Be small enough to not bloat the inline dashboard

**uPlot fits all criteria:**
- ~50KB minified (smallest Canvas-based time-series library)
- Zero dependencies
- Designed specifically for time series data
- Handles 100K+ data points at 60fps
- Available via CDN: `https://unpkg.com/uplot/dist/uPlot.iife.min.js` + `https://unpkg.com/uplot/dist/uPlot.min.css`
- Simple API: `new uPlot(opts, data, container)` where data is `[timestamps[], series1[], series2[], ...]`

**Alternatives rejected:**
- Chart.js (~48KB, heavier, not time-series-focused, slower with large datasets)
- D3.js (~300KB, massive, requires SVG DOM manipulation, overkill)
- Plotly.js (~3MB, way too large for inline embedding)
- No charting library (just numbers): User explicitly requested "full time-series charts"

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `:telemetry` | 1.3.0 (already present) | Event source for MetricsCollector | Phase 13 emits all events. MetricsCollector attaches handlers via `:telemetry.attach_many/4`. Already in dependency tree via Bandit. |
| ETS | OTP stdlib | In-memory metrics aggregation store | Sub-microsecond reads, concurrent read access, perfect for metrics counters and gauges that are written by one process and read by many. Already used by Analytics. |
| DETS (Config) | OTP stdlib | Alert threshold persistence | Already used by Config GenServer. Thresholds survive restart. Hot-reloadable via `Config.put/2`. |
| Phoenix.PubSub | ~> 2.1 (already present) | Alert event distribution | Broadcasts alerts to DashboardSocket, DashboardNotifier, and any future consumers. Existing pattern. |
| uPlot | 1.6.31 | Time-series charting in dashboard | ~50KB, zero-dep, Canvas-based, CDN-loadable. Ideal for inline HTML dashboard. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Jason | ~> 1.4 (already present) | JSON encoding for /api/metrics response | Existing dependency, used for all HTTP responses. |
| web_push_elixir | ~> 0.4 (already present) | Push notifications for alerts | Existing pattern from DashboardNotifier. Used for WARNING and CRITICAL alerts. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Custom ETS-based MetricsCollector | `telemetry_metrics` + `telemetry_metrics_prometheus` | Telemetry.Metrics is a specification library for defining metrics, but it requires a reporter (like Prometheus, StatsD). We do not have Prometheus or any external time-series DB. Building a custom ETS reporter for Telemetry.Metrics would be more code than building the collector directly. The custom approach lets us compute percentiles in-process with exactly the rolling windows we need. |
| Custom percentile calculation | `statistex` hex package | Adding a dependency for percentile calculation of small datasets (hundreds of task durations per hour) is overkill. Sorting a list and indexing at p50/p90/p99 positions is ~5 lines of Elixir. |
| uPlot | Chart.js | Chart.js is more popular but 48KB and not time-series-focused. uPlot is purpose-built for time series with 10x better performance on large datasets. Both work via CDN `<script>`. |
| Single MetricsCollector GenServer | Separate GenServers per metric type | At current scale (5 agents, <100 tasks/day), a single process handling all metrics is sufficient. Splitting into multiple processes adds coordination complexity without benefit. If scale increases 10x+, the ETS-backed approach scales naturally (ETS reads are concurrent). |

**Installation:**
No new Elixir dependencies needed. uPlot is loaded via CDN `<script>` tag in the dashboard HTML -- no npm install required.

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  metrics_collector.ex    # NEW: ETS-backed telemetry event aggregation
  alerter.ex              # NEW: Configurable alert rule evaluator with cooldown/ack
  telemetry.ex            # EXISTING: Event definitions and handler attachment
  analytics.ex            # EXISTING: Unchanged (message-level analytics)
  config.ex               # EXISTING: Stores alert_thresholds (no code change)
  dashboard_state.ex      # MODIFIED: Delegates health computation to Alerter
  dashboard_socket.ex     # MODIFIED: Adds metrics and alert event streaming
  dashboard_notifier.ex   # MODIFIED: Handles alert push notifications
  dashboard.ex            # MODIFIED: Adds metrics tab HTML, uPlot charts, alert banner
  endpoint.ex             # MODIFIED: Adds GET /api/metrics, alert management endpoints
  application.ex          # MODIFIED: Adds MetricsCollector and Alerter to supervision tree
```

### Pattern 1: ETS-Backed Rolling Window Metrics

**What:** MetricsCollector maintains rolling-window aggregations in a named ETS table. Telemetry handlers write data points; the `/api/metrics` endpoint reads them.

**When to use:** All metric aggregation.

**Example:**
```elixir
defmodule AgentCom.MetricsCollector do
  use GenServer

  @table :agent_metrics
  @window_ms 3_600_000  # 1-hour rolling window
  @snapshot_interval_ms 10_000  # Broadcast snapshot every 10s

  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Attach telemetry handlers
    attach_telemetry_handlers()

    # Schedule periodic snapshot broadcast
    Process.send_after(self(), :broadcast_snapshot, @snapshot_interval_ms)

    # Schedule periodic window cleanup
    Process.send_after(self(), :cleanup_window, @window_ms)

    {:ok, %{started_at: System.system_time(:millisecond)}}
  end

  # Public API: get current metrics snapshot
  def snapshot do
    now = System.system_time(:millisecond)
    window_start = now - @window_ms

    %{
      timestamp: now,
      queue_depth: get_gauge(:queue_depth),
      task_latency: compute_percentiles(:task_durations, window_start),
      agent_utilization: compute_utilization(window_start),
      error_rates: compute_error_rates(window_start),
      cumulative: get_cumulative_totals()
    }
  end
end
```

**Why ETS:** Telemetry handlers run in the emitting process (not the MetricsCollector process). ETS with `:public` access lets handlers write directly without GenServer call overhead. Read concurrency is enabled for the metrics endpoint to read without blocking.

### Pattern 2: Sorted List Percentile Calculation

**What:** Maintain a bounded list of recent duration values, sort on read, index for percentiles.

**When to use:** Task latency p50/p90/p99 computation.

**Example:**
```elixir
defp compute_percentiles(metric_key, window_start) do
  # Read all duration data points within window
  durations =
    case :ets.lookup(@table, {metric_key, :data}) do
      [{{_, :data}, points}] ->
        points
        |> Enum.filter(fn {ts, _val} -> ts >= window_start end)
        |> Enum.map(fn {_ts, val} -> val end)
      _ -> []
    end

  case durations do
    [] -> %{p50: 0, p90: 0, p99: 0, count: 0, min: 0, max: 0, mean: 0}
    vals ->
      sorted = Enum.sort(vals)
      count = length(sorted)
      %{
        p50: percentile_at(sorted, count, 0.50),
        p90: percentile_at(sorted, count, 0.90),
        p99: percentile_at(sorted, count, 0.99),
        count: count,
        min: hd(sorted),
        max: List.last(sorted),
        mean: div(Enum.sum(sorted), count)
      }
  end
end

defp percentile_at(sorted, count, p) do
  index = trunc(p * (count - 1))
  Enum.at(sorted, index, 0)
end
```

**Why not a histogram:** At current scale (<100 tasks/hour), keeping raw duration values and sorting on read is simpler and more accurate than pre-bucketed histograms. The list is bounded by the rolling window (old entries pruned periodically). If scale increases 100x, switch to t-digest or DDSketch for approximate percentiles.

### Pattern 3: Alert Rule Evaluation with Cooldown + Acknowledgment

**What:** The Alerter runs a check cycle, evaluates rules against current metrics, manages cooldown timers and ack state, and broadcasts only when conditions change.

**When to use:** All alert evaluation.

**Example:**
```elixir
defmodule AgentCom.Alerter do
  use GenServer

  @default_check_interval_ms 30_000

  defstruct [
    :check_interval_ms,
    :rules,            # Map of rule_id => rule definition
    :active_alerts,    # Map of rule_id => %{fired_at, severity, message, acknowledged}
    :cooldown_state,   # Map of rule_id => last_fired_at timestamp
    :thresholds        # Loaded from Config on each check
  ]

  def handle_info(:check, state) do
    thresholds = AgentCom.Config.get(:alert_thresholds) || default_thresholds()
    metrics = AgentCom.MetricsCollector.snapshot()
    now = System.system_time(:millisecond)

    {new_alerts, cleared_alerts, state} =
      evaluate_rules(state.rules, metrics, thresholds, state, now)

    # Fire new alerts
    Enum.each(new_alerts, fn alert ->
      broadcast_alert(alert)
    end)

    # Clear resolved alerts (reset ack state for re-fire if condition returns)
    Enum.each(cleared_alerts, fn rule_id ->
      broadcast_alert_cleared(rule_id)
    end)

    schedule_check(thresholds[:check_interval_ms] || @default_check_interval_ms)
    {:noreply, state}
  end

  defp should_fire?(rule_id, severity, cooldown_state, thresholds, now) do
    # CRITICAL always fires
    if severity == :critical, do: true, else: check_cooldown(rule_id, cooldown_state, thresholds, now)
  end
end
```

### Pattern 4: Alert State Machine

**What:** Each alert rule has a lifecycle: `inactive -> active -> acknowledged -> cleared`.

```
[condition FALSE]     [condition TRUE]      [operator ack]     [condition FALSE]
  inactive ---------> active ------------> acknowledged -----> inactive
                      |                                         ^
                      |       [condition FALSE]                 |
                      +----------------------------------------+
                      |
                      |       [still TRUE, cooldown expired, not acked]
                      +----> re-fire (broadcast again)
```

**When to use:** All alert management.

**Key behaviors:**
- `active`: Alert is firing. Broadcasts to dashboard + push notifications. Enters cooldown (WARNING) or fires immediately (CRITICAL).
- `acknowledged`: Operator acknowledged. Suppresses repeat notifications while condition persists. If condition clears and returns, ack is reset and alert re-fires.
- `inactive`: Condition no longer met. Alert cleared. Any previous ack is discarded.

### Pattern 5: Extending DashboardSocket for Metrics Streaming

**What:** DashboardSocket subscribes to a new PubSub topic `"metrics"` and pushes periodic snapshots to the browser.

**When to use:** Real-time metrics tab updates.

**Example:**
```elixir
# In DashboardSocket.init/1:
Phoenix.PubSub.subscribe(AgentCom.PubSub, "metrics")
Phoenix.PubSub.subscribe(AgentCom.PubSub, "alerts")

# In DashboardSocket.handle_info:
def handle_info({:metrics_snapshot, snapshot}, state) do
  formatted = %{type: "metrics_snapshot", data: snapshot}
  {:ok, %{state | pending_events: [formatted | state.pending_events]}}
end

def handle_info({:alert_fired, alert}, state) do
  formatted = %{type: "alert_fired", data: alert}
  {:ok, %{state | pending_events: [formatted | state.pending_events]}}
end

def handle_info({:alert_cleared, rule_id}, state) do
  formatted = %{type: "alert_cleared", rule_id: rule_id}
  {:ok, %{state | pending_events: [formatted | state.pending_events]}}
end
```

### Pattern 6: uPlot Inline Integration

**What:** Load uPlot via CDN `<script>` tag. Create chart instances in the metrics tab. Update data array on each WebSocket `metrics_snapshot` push.

**Example:**
```html
<!-- In dashboard HTML head -->
<link rel="stylesheet" href="https://unpkg.com/uplot@1.6.31/dist/uPlot.min.css">
<script src="https://unpkg.com/uplot@1.6.31/dist/uPlot.iife.min.js"></script>

<!-- Chart container -->
<div id="latency-chart" style="width:100%;"></div>

<script>
// Initialize chart
const latencyOpts = {
  width: 800, height: 300,
  title: "Task Latency",
  series: [
    {}, // x-axis (timestamps)
    { label: "p50", stroke: "#4ade80", width: 2 },
    { label: "p90", stroke: "#fbbf24", width: 2 },
    { label: "p99", stroke: "#ef4444", width: 2 }
  ],
  axes: [
    { label: "Time" },
    { label: "ms", size: 60 }
  ]
};

// Data format: [timestamps[], p50[], p90[], p99[]]
let latencyData = [[], [], [], []];
const latencyChart = new uPlot(latencyOpts, latencyData, document.getElementById('latency-chart'));

// On WebSocket metrics_snapshot:
function updateLatencyChart(snapshot) {
  const ts = Math.floor(snapshot.timestamp / 1000); // uPlot uses seconds
  latencyData[0].push(ts);
  latencyData[1].push(snapshot.task_latency.p50);
  latencyData[2].push(snapshot.task_latency.p90);
  latencyData[3].push(snapshot.task_latency.p99);

  // Keep last 360 points (1 hour at 10s intervals)
  if (latencyData[0].length > 360) {
    latencyData.forEach(arr => arr.shift());
  }

  latencyChart.setData(latencyData);
}
</script>
```

### Anti-Patterns to Avoid

- **Polling for metrics from the dashboard:** The dashboard already has a WebSocket. Adding `setInterval(fetch('/api/metrics'), 5000)` creates unnecessary HTTP overhead and a second data path to manage. Use the existing WebSocket.
- **Computing percentiles on every API request:** Calculate percentiles once per snapshot interval (10s), cache the result. The `/api/metrics` endpoint returns the cached snapshot, not a fresh computation.
- **Storing time-series data in DETS:** DETS is for configuration and persistent state. Time-series metrics data (task durations, queue depth samples) belongs in ETS (volatile, fast). Metrics reset on restart -- this is acceptable and expected.
- **Alerter directly sending push notifications:** Alerter broadcasts on PubSub. DashboardNotifier (already handling push notifications) listens and sends. This maintains separation of concerns and the existing notification pattern.
- **Making DashboardState depend on MetricsCollector:** DashboardState's existing health heuristics should delegate to Alerter for consistency, but DashboardState should NOT call MetricsCollector directly. The data flow is: telemetry events -> MetricsCollector (aggregation) -> Alerter (evaluation) -> PubSub (broadcast) -> DashboardState + DashboardSocket + DashboardNotifier.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Telemetry event dispatching | Custom PubSub event listeners | `:telemetry.attach_many/4` | Already in the project. Telemetry handlers run in the emitting process (zero message passing). Fail-safe: handler crashes don't crash emitters. |
| In-memory metric storage | GenServer state maps | ETS with `:public` + `read_concurrency: true` | Telemetry handlers run in arbitrary processes. ETS lets them write directly. GenServer state would serialize all writes through one process. |
| Push notifications | Custom WebSocket push code | `web_push_elixir` (already present) | DashboardNotifier already uses this for agent offline and DETS failure alerts. Same pattern. |
| JSON encoding for API | Custom formatters | Jason (already present) | Every endpoint in the system uses `Jason.encode!`. |
| Time-series visualization | Custom Canvas drawing | uPlot via CDN | ~50KB, zero deps, purpose-built for time series. Handles real-time updates, zooming, tooltips. Drawing custom charts would be thousands of lines. |

**Key insight:** The system already has every building block except the aggregation layer (MetricsCollector) and the rule engine (Alerter). Telemetry events exist. ETS is understood. PubSub broadcasting works. Push notifications work. The dashboard WebSocket works. This phase connects existing infrastructure with two new GenServers and a charting library.

## Common Pitfalls

### Pitfall 1: Telemetry Handler Detachment Under Load
**What goes wrong:** If the MetricsCollector's telemetry handler function crashes, `:telemetry` silently detaches it. All metric collection stops with no visible error.
**Why it happens:** `:telemetry` is designed for fail-safety -- crashing handlers are removed to protect emitting processes.
**How to avoid:** Wrap every telemetry handler callback in `try/rescue`. Log handler crashes at `:error` level. Add a periodic health check (every 60s) that verifies handlers are still attached via `:telemetry.list_handlers/1`. If detached, reattach. The existing `AgentCom.Telemetry` module already wraps its handler in try/rescue -- follow the same pattern.
**Warning signs:** Metrics stop updating but the system otherwise works fine. Check `:telemetry.list_handlers([:agent_com])`.

### Pitfall 2: ETS Memory Growth Without Window Pruning
**What goes wrong:** Duration data points accumulate in ETS without bound, consuming increasing memory.
**Why it happens:** Telemetry handlers write data points on every event. Without periodic pruning, the list grows indefinitely.
**How to avoid:** Schedule a periodic cleanup (every 5 minutes) that prunes data points older than the rolling window (1 hour). Use a bounded list approach: cap the maximum number of data points per metric (e.g., 10,000) and evict oldest when exceeded. At 100 tasks/hour, the list stays at ~100 entries -- but defensive bounding prevents issues under unexpected load.
**Warning signs:** `:ets.info(@table, :memory)` growing continuously over hours.

### Pitfall 3: Alert Storm from Rapidly Oscillating Conditions
**What goes wrong:** A condition that rapidly flips between true/false (e.g., queue depth hovering around the threshold) generates a flood of alert-fired/alert-cleared events, overwhelming the dashboard and push notifications.
**Why it happens:** The Alerter evaluates rules on a fixed interval. If the condition changes between each evaluation, every check produces a state transition.
**How to avoid:** Implement hysteresis: use different thresholds for firing vs. clearing. For example, fire queue_growing at 3 consecutive increases, but only clear when queue depth has been stable or decreasing for 3 consecutive checks. The cooldown mechanism also helps -- WARNING alerts with a 5-minute cooldown cannot fire more than once per 5 minutes regardless of oscillation. Additionally, only broadcast alert state *changes*, not alert state on every check.
**Warning signs:** Dashboard receiving alternating alert_fired/alert_cleared messages every 30 seconds for the same rule.

### Pitfall 4: Dashboard WebSocket Overload with Metrics Data
**What goes wrong:** Pushing full metrics snapshots every 10 seconds (including all per-agent utilization data, all data points) creates large WebSocket frames that overwhelm the browser.
**Why it happens:** Metrics data grows with the number of agents and task history.
**How to avoid:** Keep snapshots compact: send only aggregated values (not raw data points). The snapshot should be ~2-5KB. For time-series chart data, send only the delta (latest data point) rather than the full history on each push. The browser accumulates data points locally. On initial connection, send the last N data points (e.g., last 360 for 1 hour).
**Warning signs:** WebSocket frames exceeding 10KB, browser memory growing over time, UI lag.

### Pitfall 5: Race Condition Between MetricsCollector and Alerter Startup
**What goes wrong:** Alerter starts before MetricsCollector and tries to read metrics, getting empty/nil results.
**Why it happens:** Supervision tree ordering is sequential but telemetry attachment is asynchronous. Alerter's first check may run before MetricsCollector has processed any events.
**How to avoid:** Order MetricsCollector before Alerter in the supervision tree. Alerter's first check should handle nil/empty metrics gracefully (no alerts on empty data). Add a startup delay to Alerter's first check (e.g., 30 seconds after init) to allow MetricsCollector to accumulate initial data.
**Warning signs:** Spurious CRITICAL alerts (e.g., "no agents online") firing immediately on hub restart before agents reconnect.

### Pitfall 6: Config Store Returning Stale Defaults After Threshold Update
**What goes wrong:** Operator updates alert thresholds via API. The next Alerter check still uses the old thresholds because it read from a cached copy.
**Why it happens:** If the Alerter caches thresholds in GenServer state and only refreshes on restart.
**How to avoid:** Read thresholds from Config on *every* check cycle. `Config.get(:alert_thresholds)` is a GenServer call that reads from DETS -- fast enough for a 30-second check interval. No caching needed. This guarantees changes take effect on the next check cycle, which is exactly what the success criteria requires.
**Warning signs:** Threshold changes via API not reflected in alert behavior until restart.

## Code Examples

### GET /api/metrics Response Shape

```json
{
  "timestamp": 1707660000000,
  "window_ms": 3600000,
  "queue_depth": {
    "current": 3,
    "trend": [2, 3, 3, 4, 3],
    "max_1h": 7,
    "avg_1h": 3.2
  },
  "task_latency": {
    "window": {
      "p50": 45000,
      "p90": 120000,
      "p99": 300000,
      "count": 42,
      "min": 5000,
      "max": 350000,
      "mean": 72000
    },
    "cumulative": {
      "p50": 50000,
      "p90": 130000,
      "p99": 290000,
      "count": 1247
    }
  },
  "agent_utilization": {
    "system": {
      "total_agents": 3,
      "agents_online": 3,
      "agents_idle": 1,
      "agents_working": 2,
      "utilization_pct": 66.7
    },
    "per_agent": [
      {
        "agent_id": "flere-imsaho",
        "state": "working",
        "tasks_completed_1h": 5,
        "idle_pct_1h": 20.0,
        "working_pct_1h": 75.0,
        "blocked_pct_1h": 5.0,
        "avg_task_duration_ms": 85000
      }
    ]
  },
  "error_rates": {
    "window": {
      "total_tasks": 50,
      "failed": 3,
      "dead_letter": 1,
      "failure_rate_pct": 6.0
    },
    "cumulative": {
      "total_tasks": 1247,
      "failed": 42,
      "dead_letter": 8,
      "failure_rate_pct": 3.4
    }
  },
  "dets_health": {
    "status": "healthy",
    "tables": [
      {"table": "task_queue", "record_count": 150, "file_size_bytes": 524288, "fragmentation_ratio": 0.12, "status": "ok"}
    ],
    "last_backup_at": 1707600000000,
    "stale_backup": false,
    "high_fragmentation": false
  }
}
```

### Active Alerts Response Shape

```json
{
  "alerts": [
    {
      "rule_id": "stuck_tasks",
      "severity": "critical",
      "message": "2 tasks stuck: task-abc123, task-def456",
      "fired_at": 1707659000000,
      "acknowledged": false,
      "details": {
        "task_ids": ["task-abc123", "task-def456"],
        "stuck_duration_ms": 420000
      }
    }
  ],
  "timestamp": 1707660000000
}
```

### MetricsCollector Telemetry Handler Registration

```elixir
defp attach_telemetry_handlers do
  # Task lifecycle events for latency and error tracking
  :telemetry.attach_many(
    "metrics-collector-tasks",
    [
      [:agent_com, :task, :submit],
      [:agent_com, :task, :assign],
      [:agent_com, :task, :complete],
      [:agent_com, :task, :fail],
      [:agent_com, :task, :dead_letter],
      [:agent_com, :task, :reclaim],
      [:agent_com, :task, :retry]
    ],
    &__MODULE__.handle_task_event/4,
    %{}
  )

  # Agent lifecycle events for utilization tracking
  :telemetry.attach_many(
    "metrics-collector-agents",
    [
      [:agent_com, :agent, :connect],
      [:agent_com, :agent, :disconnect]
    ],
    &__MODULE__.handle_agent_event/4,
    %{}
  )

  # FSM transition events for per-agent utilization
  :telemetry.attach(
    "metrics-collector-fsm",
    [:agent_com, :fsm, :transition],
    &__MODULE__.handle_fsm_event/4,
    %{}
  )

  # Scheduler events for queue depth tracking
  :telemetry.attach(
    "metrics-collector-scheduler",
    [:agent_com, :scheduler, :attempt],
    &__MODULE__.handle_scheduler_event/4,
    %{}
  )
end
```

### Agent Utilization Computation

```elixir
defp compute_utilization(window_start) do
  # Read FSM transition events within window
  # Each transition records: {timestamp, agent_id, from_state, to_state, duration_ms}
  transitions = get_transitions_since(window_start)

  # Group by agent_id, compute time in each state
  agents = AgentCom.AgentFSM.list_all()
  now = System.system_time(:millisecond)
  window_duration = now - window_start

  per_agent =
    Enum.map(agents, fn agent ->
      agent_transitions =
        Enum.filter(transitions, fn t -> t.agent_id == agent.agent_id end)

      {idle_ms, working_ms, blocked_ms} =
        compute_state_durations(agent_transitions, window_start, now)

      total_ms = idle_ms + working_ms + blocked_ms
      total_ms = max(total_ms, 1) # avoid division by zero

      %{
        agent_id: agent.agent_id,
        state: agent.fsm_state,
        idle_pct: Float.round(idle_ms / total_ms * 100, 1),
        working_pct: Float.round(working_ms / total_ms * 100, 1),
        blocked_pct: Float.round(blocked_ms / total_ms * 100, 1)
      }
    end)

  total_agents = length(agents)
  working = Enum.count(agents, fn a -> a.fsm_state in [:working, :assigned] end)

  %{
    total_agents: total_agents,
    agents_online: total_agents,
    agents_working: working,
    agents_idle: total_agents - working,
    utilization_pct: if(total_agents > 0, do: Float.round(working / total_agents * 100, 1), else: 0),
    per_agent: per_agent
  }
end
```

### Alert Threshold Update API

```elixir
# In endpoint.ex:
get "/api/alerts" do
  alerts = AgentCom.Alerter.active_alerts()
  send_json(conn, 200, %{"alerts" => alerts, "timestamp" => System.system_time(:millisecond)})
end

post "/api/alerts/:rule_id/acknowledge" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    case AgentCom.Alerter.acknowledge(rule_id) do
      :ok -> send_json(conn, 200, %{"status" => "acknowledged", "rule_id" => rule_id})
      {:error, :not_found} -> send_json(conn, 404, %{"error" => "alert_not_found"})
    end
  end
end

get "/api/config/alert-thresholds" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    thresholds = AgentCom.Config.get(:alert_thresholds) || AgentCom.Alerter.default_thresholds()
    send_json(conn, 200, thresholds)
  end
end

put "/api/config/alert-thresholds" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    thresholds = conn.body_params
    :ok = AgentCom.Config.put(:alert_thresholds, thresholds)
    send_json(conn, 200, %{"status" => "updated", "effective" => "next_check_cycle"})
  end
end
```

## Updated Supervision Tree

```
AgentCom.Supervisor (:one_for_one)
  |
  |-- Phoenix.PubSub (name: AgentCom.PubSub)
  |-- Registry (name: AgentCom.AgentRegistry)
  |-- AgentCom.Config
  |-- AgentCom.Auth
  |-- AgentCom.Mailbox
  |-- AgentCom.Channels
  |-- AgentCom.Presence
  |-- AgentCom.Analytics
  |-- AgentCom.Threads
  |-- AgentCom.MessageHistory
  |-- AgentCom.Reaper
  |-- Registry (name: AgentCom.AgentFSMRegistry)
  |-- AgentCom.AgentSupervisor
  |-- AgentCom.TaskQueue
  |-- AgentCom.Scheduler
  |-- AgentCom.MetricsCollector          # NEW -- before Alerter
  |-- AgentCom.Alerter                   # NEW -- after MetricsCollector
  |-- AgentCom.DashboardState
  |-- AgentCom.DashboardNotifier
  |-- AgentCom.DetsBackup
  |-- Bandit
```

**Ordering rationale:**
- MetricsCollector starts after TaskQueue and Scheduler (needs to attach to telemetry events that those modules emit)
- Alerter starts after MetricsCollector (reads metrics snapshots from MetricsCollector)
- Both start before DashboardState and DashboardNotifier (those consume alert broadcasts)

## Data Flow

```
Telemetry Events (Phase 13)
  |
  |-- [:agent_com, :task, :submit/assign/complete/fail/dead_letter/reclaim/retry]
  |-- [:agent_com, :agent, :connect/disconnect]
  |-- [:agent_com, :fsm, :transition]
  |-- [:agent_com, :scheduler, :attempt]
  |
  v
MetricsCollector (NEW)
  |-- Telemetry handlers write data points to ETS :agent_metrics
  |-- Periodic snapshot broadcast on PubSub "metrics" (every 10s)
  |-- Public API: snapshot/0 for /api/metrics endpoint
  |
  v                          v
Alerter (NEW)              DashboardSocket (MODIFIED)
  |-- Reads metrics via       |-- Subscribes to "metrics" + "alerts"
  |   MetricsCollector.        |-- Pushes metrics_snapshot + alert events
  |   snapshot/0               |   to browser via WebSocket
  |-- Reads thresholds from    |
  |   Config.get(:alert_       v
  |   thresholds)           Dashboard HTML (MODIFIED)
  |-- Evaluates rules         |-- Alert banner on main page
  |-- Manages cooldowns       |-- Metrics tab with uPlot charts
  |-- Manages ack state       |-- Acknowledge button per alert
  |-- Broadcasts on PubSub
  |   "alerts" topic
  |
  v                          v
DashboardNotifier          DashboardState (MODIFIED)
(MODIFIED)                   |-- Delegates health to Alerter.active_alerts()
  |-- Sends push notifs      |-- Removes hardcoded health heuristics
  |   for alert_fired events |   (or keeps as fallback)
  |-- Same pattern as
  |   compaction failures
```

## Integration Points with Existing Code

### Existing Code That Overlaps with Phase 14

The `DashboardState.compute_health/3` function (lines 330-447 of `dashboard_state.ex`) already implements hardcoded versions of 5 out of 5 proposed alert rules:

| DashboardState Check | Phase 14 Alert Rule | Migration Strategy |
|---------------------|--------------------|--------------------|
| Agent Offline (line 334-346) | Part of `no_agents_online` | Keep in DashboardState for snapshot, add formal rule in Alerter |
| Queue Growing (line 349-354) | `queue_growing` | Extract to Alerter with configurable threshold |
| High Failure Rate (line 358-364) | `high_failure_rate` | Extract to Alerter with configurable threshold |
| Stuck Tasks (line 368-387) | `stuck_tasks` | Extract to Alerter with configurable threshold |
| DETS Backup Stale (line 390-410) | Included via `dets_health` in metrics | Keep in DashboardState, expose in /api/metrics |

**Migration strategy:** Keep `DashboardState.compute_health/3` functional during Phase 14 (do not remove it). Add Alerter alongside it. Once Alerter is proven, DashboardState can be refactored to read active alerts from Alerter instead of computing health independently. This avoids a breaking change to the existing dashboard snapshot.

### PubSub Topics

| Topic | Current Publishers | Phase 14 Additions |
|-------|-------------------|-------------------|
| `"tasks"` | TaskQueue | (no change -- MetricsCollector reads via telemetry, not PubSub) |
| `"presence"` | Presence, AgentFSM | (no change) |
| `"backups"` | DetsBackup | (no change) |
| `"validation"` | ViolationTracker | (no change) |
| `"metrics"` | (new) | MetricsCollector publishes snapshots every 10s |
| `"alerts"` | (new) | Alerter publishes alert_fired / alert_cleared / alert_acknowledged |

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Hardcoded health heuristics in DashboardState | Configurable alert rules in Alerter GenServer | Phase 14 | Thresholds changeable at runtime via Config store |
| No metrics aggregation (raw PubSub events) | Telemetry event -> ETS aggregation -> percentiles | Phase 14 | Enables /api/metrics endpoint with computed stats |
| DashboardNotifier checks health on 60s timer | Alerter evaluates rules on 30s timer with cooldowns | Phase 14 | Faster detection, configurable cooldowns, ack state |
| No time-series visualization | uPlot charts in dedicated metrics tab | Phase 14 | Operators see trends over time, not just snapshots |

## Open Questions

1. **Time-series data retention across restarts**
   - What we know: ETS metrics data is lost on restart. This is acceptable for operational monitoring.
   - What's unclear: Whether operators will want historical metrics across restarts (e.g., "what was the error rate yesterday?").
   - Recommendation: Accept volatile metrics for Phase 14. If historical retention is needed later, add periodic DETS snapshots of aggregated metrics (not raw data points). The Analytics module already provides 24-hour bucketed message counts -- this pattern could be extended.

2. **Concurrent MetricsCollector ETS writes from telemetry handlers**
   - What we know: Telemetry handlers run in the emitting process. Multiple processes may write to ETS concurrently.
   - What's unclear: Whether concurrent `:ets.update_counter` calls on the same key create contention under load.
   - Recommendation: Use `:ets.update_counter/3` for counters (atomic). For duration lists, use `GenServer.cast` to the MetricsCollector process for append operations (serialized but non-blocking). This hybrid approach gives atomic counters and safe list mutations.

3. **Dashboard tab routing (single-page navigation)**
   - What we know: The dashboard is a single HTML page. Adding a "metrics tab" requires client-side navigation (show/hide sections).
   - What's unclear: Whether the existing dashboard structure supports tab switching or needs refactoring.
   - Recommendation: Add simple CSS-based tab switching (show/hide `<div>` sections). The dashboard already uses vanilla JavaScript with no framework. A tab bar at the top (`Dashboard | Metrics`) with `display: none/block` toggling is the minimal approach. uPlot charts need to be initialized after their container is visible (call `uPlot.resize()` on tab switch).

## Sources

### Primary (HIGH confidence)
- Direct codebase analysis: `telemetry.ex`, `analytics.ex`, `config.ex`, `dashboard_state.ex`, `dashboard_socket.ex`, `dashboard_notifier.ex`, `endpoint.ex`, `task_queue.ex`, `scheduler.ex`, `agent_fsm.ex`, `application.ex`, `dashboard.ex` -- full module inventory and API surface
- Phase 13 research and implementation: `13-RESEARCH.md` -- telemetry event catalog, handler patterns, attachment strategy
- [Telemetry.Metrics v1.1.0 hexdocs](https://hexdocs.pm/telemetry_metrics/Telemetry.Metrics.html) -- Metric type definitions (counter, sum, last_value, summary, distribution), reporter pattern
- [:telemetry v1.3.0 hexdocs](https://hexdocs.pm/telemetry/telemetry.html) -- execute/3, attach_many/4, span/3, list_handlers/1
- [uPlot GitHub](https://github.com/leeoniya/uPlot) -- ~50KB, zero dependencies, Canvas 2D, time-series focused, CDN available

### Secondary (MEDIUM confidence)
- [Local Metrics Aggregation With Counters (Devon Estes)](https://devonestes.com/local-metrics-aggregation-with-counters) -- ETS-backed local metrics aggregation pattern in Elixir, p99 at 1 microsecond
- [Elixir Telemetry: Metrics and Reporters (Samuel Mullen)](https://samuelmullen.com/articles/elixir-telemetry-metrics-and-reporters) -- GenServer-based reporter pattern, metric definition consumption
- [Telemetry and Metrics in Elixir (Miguel Coba)](https://blog.miguelcoba.com/telemetry-and-metrics-in-elixir) -- Telemetry.Metrics summary and distribution semantics
- [6 Best JavaScript Charting Libraries for Dashboards in 2026](https://embeddable.com/blog/javascript-charting-libraries) -- Chart.js vs uPlot vs alternatives comparison

### Tertiary (LOW confidence)
- [Implementing Asynchronous Telemetry in Elixir (Elixir Merge)](https://elixirmerge.com/p/implementing-asynchronous-telemetry-in-elixir) -- ETS + GenServer batch pattern for telemetry aggregation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- All components are either already in the project (telemetry, ETS, PubSub, Config DETS, push notifications) or well-documented (uPlot). No new Elixir dependencies needed.
- Architecture: HIGH -- The data flow (telemetry events -> ETS aggregation -> alert evaluation -> PubSub broadcast -> dashboard/notifications) follows established patterns already present in the codebase. MetricsCollector mirrors Analytics pattern. Alerter mirrors DashboardNotifier pattern. Dashboard extension follows existing inline HTML approach.
- Pitfalls: HIGH -- All pitfalls are grounded in actual code analysis (telemetry handler detachment is documented in `:telemetry` docs; ETS memory growth is a known pattern; DashboardState's existing health checks are directly analyzed).

**Research date:** 2026-02-12
**Valid until:** 2026-03-14 (30 days -- stable patterns, no expected breaking changes)
