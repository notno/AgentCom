# Phase 6: Dashboard - Research

**Researched:** 2026-02-10
**Domain:** Real-time observability dashboard (Elixir/WebSocket/HTML)
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Information layout
- Command center style -- dense grid layout with multiple panels visible at once (Grafana/Datadog inspiration)
- Agent display: compact table (row per agent -- name, state, task, last seen)
- Queue display: summary counts by priority lane at top, expandable full task list below
- Dark theme -- dark background with bright accents
- PR links: placeholder column in task table, empty until Phase 7 wires it up
- LiveView-style implementation -- real-time server-push, no page reloads

#### Refresh & liveness
- Server-push via WebSocket -- hub pushes state changes to dashboard in real-time
- Subtle transitions on state changes -- fade/highlight briefly so changes are noticeable, queue counts animate
- Visible connection indicator -- green dot / "Connected" badge, turns red/yellow on disconnect
- Auto-reconnect with exponential backoff -- same pattern as sidecar, no manual reload needed

#### Task flow visibility
- Recent tasks shown as sortable/filterable table (columns: task, agent, status, duration, tokens)
- Failed/dead-letter tasks in a separate dedicated panel for quick scanning
- Throughput metrics: tasks completed in last hour, average completion time, total tokens used

#### Health & alerts
- Hub uptime displayed prominently at top
- Browser push notifications when agent goes offline or queue stalls

### Claude's Discretion
- Action buttons on dashboard (view-only vs basic safe actions like retry failed task)
- Historical data time window (how far back recent activity goes)
- Active assignments display (separate panel vs column in agent table)
- Health heuristics (what defines unhealthy -- agent offline, queue growing, failure rate)
- Overall health summary format (traffic light vs status bar vs other)

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

## Summary

This phase builds a real-time observability dashboard for AgentCom using the existing Plug.Router + Bandit + WebSock stack. The project does NOT use Phoenix Framework, so Phoenix LiveView is not available. Instead, the "LiveView-style" behavior (server-push, no page reloads) will be implemented using a dedicated dashboard WebSocket handler that subscribes to PubSub events and pushes JSON state updates to connected browser clients. The browser renders updates using vanilla JavaScript with DOM diffing.

The existing codebase already has significant infrastructure that the dashboard can leverage: PubSub topics for `"tasks"`, `"presence"`, and `"messages"` already broadcast all the events needed. There is already a basic polling-based dashboard at `/dashboard` (in `AgentCom.Dashboard`) and API endpoints for analytics, task stats, agent states, and dead-letter tasks. The new dashboard replaces the existing polling dashboard with a WebSocket-driven command center.

For browser push notifications (agent offline / queue stalls), the `web_push_elixir` library (0.4.0) provides VAPID-based Web Push API support. This requires a service worker on the client and VAPID key configuration on the server.

**Primary recommendation:** Build a dedicated `AgentCom.DashboardSocket` WebSock handler that subscribes to existing PubSub topics and pushes state deltas to browser clients. Serve a single self-contained HTML page with inline CSS/JS that connects via WebSocket and renders a command-center layout. No external JS frameworks needed -- vanilla JavaScript with structured DOM updates.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Bandit | ~> 1.0 (current: 1.10.2) | HTTP server hosting dashboard page | Already in project, serves HTML + upgrades WebSocket |
| WebSock | 0.5.3 | WebSocket behavior for dashboard handler | Already in project, proven pattern in AgentCom.Socket |
| WebSockAdapter | 0.5.9 | HTTP-to-WebSocket upgrade | Already in project, used in Endpoint for /ws |
| Phoenix.PubSub | 2.2.0 | Event bus for state changes | Already in project, all events already broadcast |
| Jason | 1.4.4 | JSON encoding for WebSocket messages | Already in project |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| web_push_elixir | ~> 0.4 | VAPID-based browser push notifications | For "agent offline" / "queue stalls" alerts |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Raw WebSocket + vanilla JS | Phoenix LiveView | Would require adding Phoenix Framework as dependency; massive scope increase for minimal gain since we already have Bandit + WebSock |
| Raw WebSocket + vanilla JS | Server-Sent Events (SSE) | SSE is unidirectional (server->client only); dashboard needs client->server for filter/sort commands; WebSocket is bidirectional and already proven in codebase |
| web_push_elixir | Notification API only (no push) | Notification API only works when tab is open; Web Push works even when browser is closed; push requires service worker + VAPID setup |
| Self-contained HTML | Separate React/Vue SPA | Adds build toolchain, package management, CORS concerns; self-contained HTML with inline JS matches existing dashboard pattern |

**Installation:**
```bash
# Only new dependency needed:
mix deps.get  # after adding {:web_push_elixir, "~> 0.4"} to mix.exs
```

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  dashboard.ex              # REPLACE: self-contained HTML renderer (command center layout)
  dashboard_socket.ex       # NEW: WebSock handler for real-time push to browser
  dashboard_state.ex        # NEW: GenServer aggregating state from multiple sources
  dashboard_notifier.ex     # NEW: Web Push notification sender (agent offline / queue stalls)
```

### Pattern 1: Dedicated Dashboard WebSocket Handler

**What:** A new WebSock handler (`AgentCom.DashboardSocket`) separate from the agent-facing `AgentCom.Socket`. Dashboard clients connect to `/ws/dashboard` and receive real-time state updates. This handler subscribes to PubSub topics `"tasks"`, `"presence"`, and `"messages"` during `init/1`.

**When to use:** Always -- this is the core real-time mechanism.

**Example:**
```elixir
# Source: Existing AgentCom.Socket pattern + WebSock docs (hexdocs.pm/websock/WebSock.html)
defmodule AgentCom.DashboardSocket do
  @behaviour WebSock

  @impl true
  def init(_opts) do
    # Subscribe to all relevant PubSub topics
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")

    # Send full initial state snapshot
    state = AgentCom.DashboardState.snapshot()
    {:push, {:text, Jason.encode!(%{type: "snapshot", data: state})}, %{}}
  end

  @impl true
  def handle_info({:task_event, event}, state) do
    # Push task event delta to browser
    {:push, {:text, Jason.encode!(%{type: "task_event", data: format_event(event)})}, state}
  end

  def handle_info({:agent_joined, info}, state) do
    {:push, {:text, Jason.encode!(%{type: "agent_joined", data: info})}, state}
  end

  def handle_info({:agent_left, agent_id}, state) do
    {:push, {:text, Jason.encode!(%{type: "agent_left", agent_id: agent_id})}, state}
  end

  # Client messages for filter/sort preferences (optional)
  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "request_snapshot"}} ->
        snapshot = AgentCom.DashboardState.snapshot()
        {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot})}, state}
      _ ->
        {:ok, state}
    end
  end
end
```

### Pattern 2: State Aggregator GenServer

**What:** A `DashboardState` GenServer that subscribes to PubSub and maintains a pre-computed snapshot of dashboard state. Dashboard WebSocket handlers call `DashboardState.snapshot()` on initial connect. The aggregator also computes derived metrics (tasks/hour, avg completion time, uptime) that would be expensive to compute per-client.

**When to use:** For initial state on connect and for computed/derived metrics.

**Example:**
```elixir
defmodule AgentCom.DashboardState do
  use GenServer

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")

    state = %{
      started_at: System.system_time(:millisecond),
      recent_completions: [],  # ring buffer, last N completions
      hourly_completions: 0,
      total_tokens_hour: 0
    }
    # Recompute hourly metrics every 60 seconds
    Process.send_after(self(), :recompute_metrics, 60_000)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      uptime_ms: System.system_time(:millisecond) - state.started_at,
      agents: AgentCom.AgentFSM.list_all(),
      queue_stats: AgentCom.TaskQueue.stats(),
      recent_completions: state.recent_completions,
      dead_letter: AgentCom.TaskQueue.list_dead_letter(),
      hourly_completions: state.hourly_completions,
      total_tokens_hour: state.total_tokens_hour,
      health: compute_health(state)
    }
    {:reply, snapshot, state}
  end
end
```

### Pattern 3: Vanilla JS DOM Update with Flash Highlights

**What:** Browser receives JSON events over WebSocket and updates specific DOM elements. CSS transitions provide visual feedback for state changes. No framework needed -- use `document.getElementById` / `querySelector` with data attributes for targeted updates.

**When to use:** All client-side rendering.

**Example:**
```javascript
// Source: MDN WebSocket API + CSS Transitions docs
const ws = new WebSocket(`ws://${location.host}/ws/dashboard`);

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  switch (msg.type) {
    case 'snapshot':
      renderFullState(msg.data);
      break;
    case 'task_event':
      updateTaskPanel(msg.data);
      flashElement(document.querySelector(`[data-task-id="${msg.data.task_id}"]`));
      break;
    case 'agent_joined':
      addAgentRow(msg.data);
      break;
    case 'agent_left':
      removeAgentRow(msg.agent_id);
      break;
  }
};

function flashElement(el) {
  if (!el) return;
  el.classList.add('flash');
  setTimeout(() => el.classList.remove('flash'), 1500);
}
```

```css
/* Flash highlight for state changes */
.flash { background-color: rgba(126, 184, 218, 0.3) !important; }
tr, .card, .count { transition: background-color 0.3s ease; }

/* Animated count changes */
.count { transition: transform 0.2s ease; }
.count.bumped { transform: scale(1.2); }
```

### Pattern 4: WebSocket Reconnect with Exponential Backoff

**What:** Client-side reconnection logic matching the sidecar pattern. On disconnect, visual indicator turns red/yellow, and reconnection attempts use exponential backoff with jitter. On reconnect, request a full snapshot to resync state.

**When to use:** Always -- connection drops are inevitable.

**Example:**
```javascript
// Source: Common exponential backoff pattern
class DashboardConnection {
  constructor() {
    this.reconnectDelay = 1000;
    this.maxDelay = 30000;
    this.connect();
  }

  connect() {
    this.ws = new WebSocket(`ws://${location.host}/ws/dashboard`);
    this.ws.onopen = () => {
      this.reconnectDelay = 1000;
      setConnectionStatus('connected');
    };
    this.ws.onclose = () => {
      setConnectionStatus('disconnected');
      const jitter = Math.random() * 0.3 * this.reconnectDelay;
      setTimeout(() => this.connect(), this.reconnectDelay + jitter);
      this.reconnectDelay = Math.min(this.maxDelay, this.reconnectDelay * 2);
    };
    this.ws.onmessage = (event) => handleMessage(JSON.parse(event.data));
  }
}
```

### Anti-Patterns to Avoid

- **Polling from the dashboard HTML:** The existing dashboard polls `/api/analytics/summary` every 30s. Replace this entirely with WebSocket push. Polling introduces stale data windows and unnecessary HTTP overhead.
- **Re-using the agent WebSocket handler:** The agent `/ws` endpoint requires authentication with agent tokens. Dashboard should have its own endpoint (`/ws/dashboard`) with either no auth or a separate admin auth mechanism.
- **Full state push on every event:** Pushing the entire state on every task/agent event wastes bandwidth. Push deltas (individual events) and let the client merge them into local state. Only push full snapshots on initial connect or explicit request.
- **Blocking GenServer calls in the WebSocket handler:** The dashboard socket's `handle_info` runs in the WebSocket process. Avoid calling slow GenServer APIs synchronously here. `DashboardState.snapshot()` pre-computes expensive queries.

## Discretion Recommendations

### Action Buttons: Include Safe Actions
**Recommendation:** Include a "Retry" button on dead-letter tasks. This is the only safe write action -- it calls the existing `POST /api/tasks/:task_id/retry` endpoint. All other actions (task creation, agent management, configuration) stay in CLI/API per phase boundary.

**Rationale:** Dead-letter tasks are the #1 thing Nathan would want to act on when looking at the dashboard. Having to switch to curl is friction. Retry is idempotent and safe -- worst case the task fails again and returns to dead-letter.

### Historical Data Time Window: 1 Hour Default, Configurable
**Recommendation:** Show recent task activity for the last 1 hour. Keep a ring buffer of the last 100 completed tasks in `DashboardState`. The hourly window balances useful context with memory efficiency. No DETS persistence for dashboard metrics -- they reset on hub restart (same pattern as Analytics module).

**Rationale:** The existing Analytics module uses hourly buckets. 1 hour gives enough context for throughput metrics (tasks/hour, avg completion time) without accumulating unbounded data.

### Active Assignments: Column in Agent Table
**Recommendation:** Show current task assignment as a column in the agent table (column: "Current Task"), not a separate panel. The agent table row becomes: `Name | State | Current Task | Capabilities | Last Seen`. This is more information-dense and matches the "command center" layout decision.

**Rationale:** A separate assignments panel duplicates information already implicit in agent state. The column approach is denser and matches Grafana-style layouts where every pixel counts.

### Health Heuristics
**Recommendation:** Define three health conditions with clear thresholds:

| Condition | Heuristic | Severity |
|-----------|-----------|----------|
| Agent Offline | Agent was connected in last 5 min but now absent from Presence | WARNING |
| Queue Growing | Queued task count increased 3 consecutive checks (checked every 60s) | WARNING |
| High Failure Rate | >50% of completed tasks in last hour were failures/dead-letter | CRITICAL |
| Stuck Tasks | Any task assigned >5 min with no progress update | WARNING |
| Hub Healthy | None of above conditions active | OK |

These thresholds are computed in `DashboardState` and pushed as part of the health section.

### Health Summary Format: Traffic Light with Text
**Recommendation:** Use a simple traffic light (green/yellow/red dot) next to a text summary at the top of the dashboard.

- Green: "Healthy -- all systems operational"
- Yellow: "Warning -- {N conditions}" with expandable detail
- Red: "Critical -- {condition description}"

**Rationale:** Traffic lights are universally understood for ops dashboards. Adding text avoids accessibility issues (color blindness) and gives actionable detail without requiring a click.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| WebSocket upgrade | Custom HTTP upgrade parsing | WebSockAdapter.upgrade/3 | Already in project, handles upgrade negotiation correctly |
| Browser push notifications | Custom push encryption | web_push_elixir ~> 0.4 | VAPID encryption is complex (ECDH + HKDF + AES-GCM); library handles RFC8291 |
| JSON encoding | Manual string building | Jason.encode! | Already in project, handles edge cases |
| PubSub event distribution | Custom process registry broadcast | Phoenix.PubSub | Already in project, all events already broadcasting |
| Exponential backoff (server) | Custom timer logic | Process.send_after pattern | Already proven in Scheduler and TaskQueue sweep patterns |

**Key insight:** The existing codebase already has 90% of the infrastructure this dashboard needs. PubSub topics broadcast every event type. API endpoints exist for all data queries. The `AgentCom.Socket` module is a proven template for the WebSocket handler pattern. The main work is wiring existing data sources to a new WebSocket endpoint and building the HTML/CSS/JS frontend.

## Common Pitfalls

### Pitfall 1: PubSub Message Flood to Browser
**What goes wrong:** Every PubSub event gets pushed to every dashboard WebSocket. Under load (many tasks completing rapidly), this floods the browser with JSON messages faster than it can render.
**Why it happens:** PubSub is designed for server-to-server communication. Browser clients are slower consumers.
**How to avoid:** Batch events in the DashboardSocket handler using `Process.send_after(self(), :flush, 100)` to coalesce rapid-fire events into batched pushes. Send at most 10 updates/second to the browser.
**Warning signs:** Browser tab memory growing, dashboard becoming unresponsive during bulk task processing.

### Pitfall 2: Stale State After Reconnect
**What goes wrong:** Dashboard reconnects after a disconnect but only receives events from the reconnection point forward. State shown to Nathan is incomplete -- missing agents that joined or tasks that changed during the disconnect window.
**Why it happens:** WebSocket push is fire-and-forget. Missed events during disconnect are gone.
**How to avoid:** On WebSocket `init/1` (which fires on each new connection), always push a full state snapshot. The client replaces its entire local state on receiving a `"snapshot"` message. Also provide a "request_snapshot" message type the client can send to force-resync.
**Warning signs:** Dashboard shows different state than `curl /api/tasks/stats`.

### Pitfall 3: Dashboard WebSocket Blocking on Slow Queries
**What goes wrong:** `DashboardSocket.init/1` calls `TaskQueue.list()` and `AgentFSM.list_all()` synchronously. If TaskQueue has thousands of tasks, the GenServer call takes seconds, blocking the WebSocket upgrade.
**Why it happens:** DETS foldl over large datasets is slow. GenServer serializes all calls.
**How to avoid:** Use `DashboardState` GenServer that pre-computes and caches the snapshot. The snapshot is a simple GenServer.call returning a cached map -- fast regardless of underlying data size. `DashboardState` refreshes its cache on PubSub events, not on dashboard requests.
**Warning signs:** Dashboard takes >1s to load initially, or new dashboard tabs cause spikes.

### Pitfall 4: Service Worker Registration Failures
**What goes wrong:** Web Push notifications silently fail because the service worker wasn't registered, or VAPID keys are misconfigured, or the user denied notification permission.
**Why it happens:** Web Push has many moving parts: service worker registration, push subscription, VAPID key exchange, permission prompts.
**How to avoid:** Make push notifications a progressive enhancement. Dashboard works fully without them. Show a clear "Enable Notifications" button that handles the permission flow. Log failures visibly in the dashboard itself (a small status line). Never block dashboard rendering on notification setup.
**Warning signs:** `Notification.permission === "denied"` with no user prompt ever shown (means the prompt was blocked by browser policy or the page isn't served over HTTPS).

### Pitfall 5: HTTPS Requirement for Web Push
**What goes wrong:** Web Push API and Service Workers require HTTPS in production. AgentCom runs on HTTP locally.
**Why it happens:** Browser security model requires secure context for push subscriptions.
**How to avoid:** Web Push works on `localhost` without HTTPS (browsers make an exception for localhost). For remote access, either use HTTPS or treat push notifications as localhost-only. Document this limitation. The dashboard itself (WebSocket + HTML) works fine over HTTP.
**Warning signs:** `navigator.serviceWorker` is undefined, `PushManager.subscribe()` throws SecurityError.

### Pitfall 6: Inline HTML Size and Maintainability
**What goes wrong:** The self-contained HTML (inline CSS + JS) grows to 500+ lines and becomes unmaintainable. Changes require touching a single massive string in an Elixir module.
**Why it happens:** The existing `AgentCom.Dashboard` module is a single `render/0` function returning an HTML string. The command center layout is significantly more complex.
**How to avoid:** Split the HTML into modular sections using Elixir string interpolation or `EEx` templates. Keep CSS, JS, and HTML in separate heredoc sections within the module, or use `EEx.eval_file/2` to load from `priv/dashboard/` files. Prefer the latter for maintainability.
**Warning signs:** Syntax highlighting breaks in the editor, indentation errors in HTML within Elixir strings.

## Code Examples

### Dashboard Endpoint Route Registration

```elixir
# Source: Existing AgentCom.Endpoint pattern (lib/agent_com/endpoint.ex)
# Add to endpoint.ex alongside existing /ws route:

get "/ws/dashboard" do
  conn
  |> WebSockAdapter.upgrade(AgentCom.DashboardSocket, [], timeout: 60_000)
  |> halt()
end

get "/dashboard" do
  conn
  |> put_resp_content_type("text/html")
  |> send_resp(200, AgentCom.Dashboard.render())
end

# Add JSON API endpoint for initial curl-friendly snapshot:
get "/api/dashboard/state" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    snapshot = AgentCom.DashboardState.snapshot()
    send_json(conn, 200, snapshot)
  end
end
```

### DashboardState Snapshot Structure

```elixir
# The snapshot returned by DashboardState.snapshot() should match this shape:
%{
  uptime_ms: 3_600_000,
  timestamp: 1707580800000,
  health: %{
    status: :ok,          # :ok | :warning | :critical
    conditions: [],       # list of active warning/critical conditions
  },
  agents: [
    %{
      agent_id: "agent-1",
      name: "Agent One",
      fsm_state: :idle,           # :idle | :assigned | :working | :blocked | :offline
      current_task_id: nil,
      capabilities: [%{name: "code"}],
      connected_at: 1707577200000,
      last_state_change: 1707580700000
    }
  ],
  queue: %{
    by_status: %{queued: 3, assigned: 1, completed: 10},
    by_priority: %{0 => 1, 1 => 0, 2 => 2, 3 => 0},
    dead_letter: 2
  },
  dead_letter_tasks: [
    %{id: "task-abc", description: "...", last_error: "...", retry_count: 3, created_at: ...}
  ],
  recent_completions: [
    %{task_id: "task-xyz", agent_id: "agent-1", duration_ms: 45000, tokens_used: 150,
      completed_at: 1707580600000, description: "..."}
  ],
  throughput: %{
    completed_last_hour: 15,
    avg_completion_ms: 32000,
    total_tokens_hour: 2250
  }
}
```

### Web Push Notification Setup

```elixir
# Source: web_push_elixir docs (hexdocs.pm/web_push_elixir)
# config/config.exs:
config :web_push_elixir,
  vapid_public_key: System.get_env("VAPID_PUBLIC_KEY"),
  vapid_private_key: System.get_env("VAPID_PRIVATE_KEY"),
  vapid_subject: "mailto:admin@agentcom.local"

# Generate VAPID keys once:
# mix generate.vapid.keys
```

```javascript
// Client-side service worker registration (in dashboard HTML):
if ('serviceWorker' in navigator && 'PushManager' in window) {
  navigator.serviceWorker.register('/sw.js').then(reg => {
    return reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: VAPID_PUBLIC_KEY  // injected by server
    });
  }).then(subscription => {
    // Send subscription to server via WebSocket
    ws.send(JSON.stringify({
      type: 'push_subscribe',
      subscription: subscription.toJSON()
    }));
  });
}
```

### Connection Status Indicator

```html
<!-- Source: Common dashboard pattern -->
<div class="connection-status" id="conn-status">
  <span class="status-dot" id="conn-dot"></span>
  <span id="conn-text">Connecting...</span>
</div>
```

```css
.connection-status {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 0.75em;
}
.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #fbbf24; /* yellow = connecting */
  transition: background-color 0.3s ease;
}
.status-dot.connected { background: #4ade80; }
.status-dot.disconnected { background: #ef4444; animation: pulse 1.5s infinite; }
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
```

## Existing Infrastructure Inventory

The following existing modules and PubSub topics are directly usable by the dashboard without modification:

### PubSub Topics Already Broadcasting

| Topic | Events | Dashboard Use |
|-------|--------|---------------|
| `"tasks"` | `:task_submitted`, `:task_assigned`, `:task_completed`, `:task_retried`, `:task_reclaimed`, `:task_dead_letter` | Task flow panel, throughput metrics, dead-letter panel |
| `"presence"` | `:agent_joined`, `:agent_left`, `:status_changed`, `:agent_idle` | Agent table, health alerts |
| `"messages"` | `:message` | Not directly needed for dashboard (message analytics handled separately) |

### Existing API Endpoints Reusable for `/api/dashboard/state`

| Endpoint | Data | Dashboard Panel |
|----------|------|-----------------|
| `AgentCom.AgentFSM.list_all()` | All agent states with FSM, capabilities, current task | Agent table |
| `AgentCom.TaskQueue.stats()` | Counts by status and priority | Queue summary cards |
| `AgentCom.TaskQueue.list_dead_letter()` | Failed tasks | Dead-letter panel |
| `AgentCom.TaskQueue.list(status: :assigned)` | Currently assigned tasks | Active assignments column |
| `AgentCom.Analytics.summary()` | Connected/active/idle counts | Summary cards |

### Existing Patterns to Reuse

| Pattern | Source | Reuse For |
|---------|--------|-----------|
| WebSock handler with PubSub | `AgentCom.Socket` + `AgentCom.Scheduler` | `DashboardSocket` structure |
| Self-contained HTML with inline JS | `AgentCom.Dashboard` (current) | New dashboard page |
| ETS/GenServer for fast reads | `AgentCom.Analytics` | `DashboardState` cache |
| Exponential backoff | Sidecar `config.ECHO.json` | Client-side reconnect |

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Polling-based dashboards (setInterval + fetch) | WebSocket server-push with delta updates | Standard since ~2020 | Lower latency, less server load, real-time feel |
| Full-page reload for updates | Single-page with DOM patching | Standard for years | No page flash, smoother UX |
| Custom WebSocket framing | WebSock behavior (Elixir) | WebSock 0.5.x (2023+) | Standardized handler interface across servers |
| Cookie/session auth for dashboards | Token or sessionless for local tools | Varies | AgentCom is local-network; auth is optional |

**Deprecated/outdated:**
- Cowboy-specific WebSocket handlers: Use WebSock behavior instead (Bandit + Cowboy both support it)
- Phoenix.Socket.Transport: Replaced by WebSock for non-Phoenix apps
- Long polling: Replaced by native WebSocket support in all modern browsers

## Open Questions

1. **Dashboard Authentication**
   - What we know: The agent WebSocket (`/ws`) uses token auth. The existing `/dashboard` page has no auth.
   - What's unclear: Should `/ws/dashboard` require authentication? The hub is typically on a local network.
   - Recommendation: No auth for the dashboard WebSocket (matches current `/dashboard` behavior). The JSON API endpoint `GET /api/dashboard/state` should require auth (matches existing API pattern). Add a note in docs that dashboard should not be exposed to the public internet.

2. **Web Push HTTPS Requirement**
   - What we know: Service Workers and Web Push require HTTPS in production browsers. Localhost is exempted.
   - What's unclear: Will Nathan access the dashboard from localhost only, or also remotely?
   - Recommendation: Implement push notification infrastructure but document the HTTPS limitation. Works on localhost without HTTPS. For remote access, push notifications degrade gracefully (WebSocket still works over HTTP; only push notifications need HTTPS).

3. **Service Worker Serving**
   - What we know: Service workers must be served from the same origin. The current Endpoint is a Plug.Router, not a static file server.
   - What's unclear: How to serve the `sw.js` file.
   - Recommendation: Add a `get "/sw.js"` route in Endpoint that serves the service worker JavaScript as a static file (inline string or from priv/). Must be served at root path for scope to cover the whole origin.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: All `.ex` files in `lib/agent_com/` -- direct code reading of Socket, Endpoint, AgentFSM, TaskQueue, Scheduler, Dashboard, Analytics, Presence modules
- [WebSock v0.5.3 docs](https://hexdocs.pm/websock/WebSock.html) -- callback signatures, return tuples, handle_info pattern
- [Bandit WebSocket README](https://github.com/mtrudel/bandit/blob/main/lib/bandit/websocket/README.md) -- WebSocket implementation details
- [WebSocket API (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API) -- client-side WebSocket API
- [Push API (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/Push_API) -- Web Push notification API

### Secondary (MEDIUM confidence)
- [Bare WebSockets in Elixir](https://kobrakai.de/kolumne/bare-websockets) -- pattern for WebSock + Plug.Router without Phoenix
- [web_push_elixir](https://github.com/midarrlabs/web-push-elixir) -- VAPID-based push library for Elixir, v0.4.0
- [CSS Transitions (MDN)](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Transitions/Using) -- transition patterns for state change highlights
- [Carbon Design System - Status Indicators](https://carbondesignsystem.com/patterns/status-indicator-pattern/) -- traffic light and status indicator design patterns

### Tertiary (LOW confidence)
- [WebSocket reconnection patterns](https://oneuptime.com/blog/post/2026-01-24-websocket-reconnection-logic/view) -- exponential backoff implementations (multiple sources agree on pattern)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries already in project except web_push_elixir; patterns directly mirror existing code
- Architecture: HIGH -- WebSock handler + PubSub subscription is proven pattern in AgentCom.Socket and AgentCom.Scheduler; DashboardState follows Analytics GenServer pattern
- Pitfalls: HIGH -- identified from direct code analysis of existing modules and standard WebSocket/push notification concerns
- Web Push: MEDIUM -- web_push_elixir library is small and less widely used; VAPID setup requires testing; HTTPS limitation is a known constraint
- Frontend (HTML/CSS/JS): MEDIUM -- vanilla JS dashboard is straightforward but the command center layout complexity is harder to estimate without mockups

**Research date:** 2026-02-10
**Valid until:** 2026-03-10 (stable domain -- no fast-moving dependencies)
