# Phase 18: LLM Registry and Host Resources - Research

**Researched:** 2026-02-12
**Domain:** Ollama endpoint registry, health checking, host resource monitoring, Elixir/OTP GenServer patterns
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Registration workflow
- Dual registration: sidecars auto-report local Ollama during heartbeat, plus admin can manually register remote endpoints via HTTP API
- Auto-reported endpoints are trusted immediately (no approval step) -- consistent with existing sidecar trust model
- Hub auto-discovers available models by querying Ollama's /api/tags after registration -- no manual model listing
- Model availability is binary (available or not) -- no warm/cold VRAM tracking

#### Health check behavior
- Hub polls Ollama endpoints directly on a timer (not relying on sidecar heartbeat for health)
- Health checks apply to both auto-reported and manually-registered endpoints

#### Resource reporting
- Resource metrics are ephemeral -- rebuilt from live reports as sidecars reconnect, not persisted in DETS
- When a sidecar stops reporting, clear its resource data after a timeout (show as unknown, not stale)

#### Dashboard presentation
- Table view for the LLM registry -- one row per endpoint showing host, port, models, health status
- Resource utilization bars (CPU, RAM, etc.) shown alongside endpoint status per host
- Fleet-level model summary at top ("3 hosts have llama3, 1 has codellama") plus per-endpoint model detail
- Dashboard controls for adding/removing endpoints -- not API-only

#### CONTEXT overrides to Success Criteria
- Model availability is BINARY (no warm/cold VRAM tracking) -- overrides Success Criteria #3
- Resource metrics are EPHEMERAL (not persisted in DETS) -- overrides Success Criteria #5 for resource metrics. Only endpoint registrations need DETS persistence.

### Claude's Discretion
- Health check polling interval and failure threshold (how many misses before unhealthy)
- Recovery behavior (immediate vs probation after coming back online)
- Deregistration handling when tasks are in-flight (drain vs block)
- Which specific resource metrics to collect (CPU/RAM/GPU/VRAM mix)
- Resource reporting transport mechanism (piggyback on heartbeat vs separate message)
- Exact dashboard layout and component design within table-based approach

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

## Summary

Phase 18 introduces an LLM Registry GenServer on the hub that tracks Ollama endpoints across the Tailscale mesh, performs active health checks, and displays both registry and host resource data on the dashboard. There are two registration paths: sidecars auto-report local Ollama instances via their existing WebSocket connection, and admins can manually register remote endpoints via HTTP API. The hub queries Ollama's `/api/tags` endpoint to discover models and polls endpoints on a timer for health. Host resource metrics (CPU, RAM, GPU/VRAM) are ephemeral in-memory data reported by sidecars.

The existing codebase provides all the infrastructure patterns needed: GenServer with DETS persistence (see `AgentCom.Config`, `AgentCom.TaskQueue`), HTTP API routes via `AgentCom.Endpoint` (Plug.Router), WebSocket message handling via `AgentCom.Socket`, PubSub-driven dashboard updates via `AgentCom.DashboardState`/`AgentCom.DashboardSocket`, and periodic timers via `Process.send_after`. The sidecar is a Node.js process using the `ws` library, with a heartbeat (ping/pong) every 30 seconds. This is an Elixir/OTP project using Bandit as the HTTP server, Phoenix.PubSub, and Jason for JSON. No new dependencies are needed -- `:httpc` from Erlang's `:inets` (already in `extra_applications`) handles outbound HTTP to Ollama.

**Primary recommendation:** Build `AgentCom.LlmRegistry` as a single GenServer that owns a DETS table for endpoint persistence and an ETS table for ephemeral resource metrics. Use `:httpc` for Ollama health checks. Extend the sidecar's identify or ping messages to include `ollama_url` and resource metrics. Follow the existing DashboardState/DashboardSocket pattern for real-time UI updates.

## Standard Stack

### Core (already in project, no new deps)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `:httpc` (Erlang) | OTP 27+ | HTTP client for Ollama API calls | Already available via `:inets` in extra_applications; no new deps |
| `:dets` (Erlang) | OTP 27+ | Persistent storage for endpoint registry | Existing pattern used by TaskQueue, Config, Channels |
| `:ets` (Erlang) | OTP 27+ | In-memory storage for ephemeral resource metrics | Existing pattern used by MetricsCollector |
| Phoenix.PubSub | ~> 2.1 | Event broadcast for dashboard updates | Already in deps, used everywhere |
| Jason | ~> 1.4 | JSON encoding/decoding | Already in deps |

### Supporting (sidecar side, Node.js)
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `os` (Node.js built-in) | N/A | CPU/RAM metrics via `os.cpus()`, `os.totalmem()`, `os.freemem()` | Always -- no extra deps needed |
| `child_process` (Node.js built-in) | N/A | Shell out to `nvidia-smi` for GPU metrics on hosts with NVIDIA GPUs | Only when GPU reporting is needed |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `:httpc` | `req` or `finch` | New dependency for simple GET requests; `:httpc` is sufficient for low-volume health checks |
| `nvidia-smi` shell | `systeminformation` npm | Heavy npm package for one data point; prefer Ollama `/api/ps` for VRAM data instead |

**Installation:** No new packages needed. The `:inets` application is already configured in `application.ex`.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  llm_registry.ex          # GenServer: endpoint CRUD, health check timer, model discovery, resource aggregation

# Modifications to existing files:
  socket.ex                # Handle new WS message types: ollama_report, resource_report
  endpoint.ex              # New HTTP routes: /api/admin/llm-registry/*
  dashboard_state.ex       # Include LLM registry data in snapshot
  dashboard_socket.ex      # Forward LLM registry PubSub events to browser
  dashboard.ex             # New dashboard section: LLM Registry table + Resource bars
  validation/schemas.ex    # New schemas for LLM registry HTTP/WS messages

# Sidecar modifications:
sidecar/
  lib/resources.js         # New: collect CPU/RAM/GPU metrics
  index.js                 # Extend identify/ping to include ollama_url, resource metrics
```

### Pattern 1: GenServer with DETS + ETS Hybrid Storage
**What:** A single GenServer owns a DETS table for persistent endpoint data and an ETS table for ephemeral resource metrics. DETS stores what survives restart (endpoint registrations), ETS stores what is rebuilt live (resource snapshots).
**When to use:** When some data must survive restart and some is purely ephemeral.
**Example:**
```elixir
# Source: Existing patterns from AgentCom.TaskQueue (DETS) + AgentCom.MetricsCollector (ETS)
defmodule AgentCom.LlmRegistry do
  use GenServer
  require Logger

  @dets_table :llm_registry
  @ets_table :llm_resources
  @health_check_interval_ms 30_000
  @resource_stale_timeout_ms 120_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    # DETS for persistent endpoint registrations
    dets_path = Path.join(data_dir(), "llm_registry.dets") |> String.to_charlist()
    {:ok, @dets_table} = :dets.open_file(@dets_table, file: dets_path, type: :set, auto_save: 5_000)

    # ETS for ephemeral resource metrics
    :ets.new(@ets_table, [:named_table, :public, :set, {:read_concurrency, true}])

    # Start health check timer
    Process.send_after(self(), :health_check, @health_check_interval_ms)
    # Start resource staleness sweep
    Process.send_after(self(), :sweep_stale_resources, @resource_stale_timeout_ms)

    # Load endpoints from DETS and schedule immediate model discovery
    endpoints = load_all_endpoints()
    if length(endpoints) > 0, do: send(self(), :discover_models)

    {:ok, %{endpoints_cache: endpoints}}
  end
end
```

### Pattern 2: Sidecar Auto-Report via Extended Identify/Ping
**What:** The sidecar includes `ollama_url` in its identify message (or a new `ollama_report` message type) and periodically sends resource metrics piggybacked on existing pings or as a separate message.
**When to use:** Dual-registration -- auto-report from sidecar + manual from admin.
**Example:**
```javascript
// Sidecar: extend identify to include ollama_url
identify() {
  this.send({
    type: 'identify',
    agent_id: this.config.agent_id,
    token: this.config.token,
    name: this.config.agent_id,
    status: 'idle',
    capabilities: this.config.capabilities,
    client_type: 'sidecar',
    protocol_version: 1,
    // NEW: Phase 18 LLM Registry auto-report
    ollama_url: this.config.ollama_url || null
  });
}

// Sidecar: send resource_report periodically (separate from ping)
startResourceReporting() {
  this.resourceInterval = setInterval(() => {
    const metrics = collectResourceMetrics();
    this.send({ type: 'resource_report', metrics });
  }, 30000); // Every 30 seconds
}
```

### Pattern 3: Hub-Initiated Ollama Health Check via :httpc
**What:** The hub polls each registered Ollama endpoint directly, independent of sidecar heartbeat.
**When to use:** Per locked decision -- hub polls endpoints on a timer.
**Example:**
```elixir
# Source: Erlang :httpc docs + Ollama API docs
defp check_ollama_health(host, port) do
  url = ~c"http://#{host}:#{port}/api/tags"
  timeout_opts = [timeout: 5_000, connect_timeout: 3_000]

  case :httpc.request(:get, {url, []}, timeout_opts, []) do
    {:ok, {{_, 200, _}, _headers, body}} ->
      case Jason.decode(to_string(body)) do
        {:ok, %{"models" => models}} ->
          model_names = Enum.map(models, fn m -> m["name"] end)
          {:ok, :healthy, model_names}
        _ ->
          {:ok, :healthy, []}
      end
    {:ok, {{_, status, _}, _, _}} ->
      {:error, :unhealthy, "HTTP #{status}"}
    {:error, reason} ->
      {:error, :unreachable, inspect(reason)}
  end
end
```

### Pattern 4: PubSub-Driven Dashboard Updates
**What:** LlmRegistry broadcasts events on a "llm_registry" PubSub topic. DashboardState subscribes and includes registry data in snapshots. DashboardSocket forwards events to browser.
**When to use:** Consistent with all existing dashboard data flows.
**Example:**
```elixir
# In LlmRegistry after health check or registration change:
Phoenix.PubSub.broadcast(AgentCom.PubSub, "llm_registry", {:endpoint_health_changed, %{
  endpoint_id: endpoint_id,
  host: host,
  port: port,
  status: :healthy,
  models: model_names,
  timestamp: System.system_time(:millisecond)
}})
```

### Anti-Patterns to Avoid
- **Coupling health checks to sidecar heartbeat:** The locked decision says hub polls Ollama directly. Do NOT rely on sidecar ping/pong for Ollama health status.
- **Warm/cold model tracking:** The locked decision says model availability is binary. Do NOT query `/api/ps` for loaded model status.
- **Persisting resource metrics in DETS:** Resource metrics are ephemeral per decision. Store in ETS, not DETS.
- **Blocking GenServer with HTTP calls:** `:httpc` requests in `handle_info` timers are fine for a few endpoints, but use `Task.async` if polling many endpoints to avoid blocking the GenServer message queue.
- **Separate GenServer per endpoint:** Keep it simple -- one GenServer manages all endpoints. The expected scale (< 20 endpoints) does not warrant per-endpoint processes.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HTTP client for Ollama | Custom TCP/socket | `:httpc` from `:inets` | Already available, handles HTTP 1.1, sufficient for simple GET requests |
| JSON encoding | String interpolation | `Jason.encode!/1` / `Jason.decode/1` | Already in deps, handles edge cases |
| Periodic timers | `:timer.apply_interval` | `Process.send_after` in GenServer | Existing pattern throughout codebase (TaskQueue, Scheduler, Alerter) |
| DETS persistence | Custom file I/O | `:dets.open_file` + `:dets.insert` + `:dets.sync` | Existing pattern in TaskQueue, Config |
| CPU/RAM metrics (Node.js) | Parse /proc/stat manually | `os.cpus()` / `os.totalmem()` / `os.freemem()` | Built-in Node.js, cross-platform |
| Dashboard WebSocket events | Custom event system | Phoenix.PubSub broadcast + DashboardSocket handler | Existing pipeline, battle-tested |

**Key insight:** This phase introduces no genuinely new technical challenges. Every pattern (GenServer, DETS, ETS, PubSub, WebSocket messages, HTTP routes, dashboard rendering) is already established in the codebase. The work is assembly, not invention.

## Common Pitfalls

### Pitfall 1: Blocking GenServer with Sequential HTTP Health Checks
**What goes wrong:** If `handle_info(:health_check, ...)` makes HTTP requests to 10 Ollama endpoints sequentially, each with a 5-second timeout, the GenServer is blocked for up to 50 seconds. All `call` and `cast` messages queue up.
**Why it happens:** `:httpc.request` is synchronous by default.
**How to avoid:** For a small number of endpoints (< 10), sequential checks with a short timeout (3-5s) are acceptable. For more endpoints, spawn `Task.async_stream` from the GenServer's `handle_info` and collect results.
**Warning signs:** Dashboard snapshot calls timeout; registry API responses slow down.

### Pitfall 2: DETS Table Not in DetsBackup.@tables List
**What goes wrong:** The new `:llm_registry` DETS table is not included in DetsBackup's `@tables` list, so it never gets backed up or compacted.
**Why it happens:** Forgetting to update the existing DetsBackup module.
**How to avoid:** Add `:llm_registry` to `@tables` in DetsBackup, add a `table_owner(:llm_registry)` clause, and add the DETS path to `get_table_path(:llm_registry)`.
**Warning signs:** `DetsBackup.health_metrics()` does not show the new table.

### Pitfall 3: Stale Resource Data Displayed as Current
**What goes wrong:** A sidecar disconnects, but its last resource report (CPU 80%, RAM 6GB) stays displayed on the dashboard as if it's live.
**Why it happens:** No staleness sweep for the ETS resource table.
**How to avoid:** Store a `last_reported_at` timestamp with each resource entry. Run a periodic sweep (every 60-120s) that clears entries older than the timeout. Show "unknown" on dashboard when data is absent.
**Warning signs:** Dashboard shows resource data for hosts that are offline.

### Pitfall 4: Charlist vs Binary String Confusion with :httpc
**What goes wrong:** `:httpc.request` expects charlists (`~c"..."`) for URLs, but Elixir string interpolation produces binaries. The call crashes with an argument error.
**Why it happens:** Erlang/Elixir string type mismatch.
**How to avoid:** Always convert URLs to charlists: `String.to_charlist("http://#{host}:#{port}/api/tags")`.
**Warning signs:** `** (ArgumentError)` in health check logs.

### Pitfall 5: Race Between Sidecar Register and First Health Check
**What goes wrong:** Sidecar reports `ollama_url` on identify, hub registers the endpoint, but the first health check runs before Ollama has finished loading. Endpoint is immediately marked unhealthy.
**Why it happens:** Health check fires on its timer regardless of when registration happened.
**How to avoid:** Set initial status to `:unknown` or `:pending` for newly registered endpoints. Don't mark an endpoint unhealthy until it has failed at least 2 consecutive health checks (not just 1).
**Warning signs:** Newly registered endpoints briefly flash as unhealthy on dashboard.

### Pitfall 6: Endpoint ID Collisions Between Auto and Manual Registration
**What goes wrong:** Admin manually registers `http://192.168.1.5:11434`, then a sidecar on the same host auto-reports the same Ollama instance. Two entries appear for one endpoint.
**Why it happens:** Different registration paths create different endpoint IDs.
**How to avoid:** Use `"#{host}:#{port}"` as the canonical endpoint ID for both auto and manual registration. On auto-report, upsert (update if exists, insert if not). Mark the registration source (`:auto` or `:manual`) but deduplicate by host:port.
**Warning signs:** Duplicate rows in the LLM registry table.

### Pitfall 7: Missing Validation for HTTP API Inputs
**What goes wrong:** Admin registers an endpoint with an invalid URL or missing port, causing crashes in health check code.
**Why it happens:** Skipping input validation on the new HTTP routes.
**How to avoid:** Add validation schemas in `AgentCom.Validation.Schemas` for the new endpoints (host, port, optional name). Follow existing pattern: `Validation.validate_http(:post_llm_endpoint, params)`.
**Warning signs:** `500` errors on admin registration attempts.

## Code Examples

Verified patterns from the existing codebase:

### DETS Open, Insert, Read (from AgentCom.Config)
```elixir
# Source: lib/agent_com/config.ex
# Open DETS file
dets_path = Path.join(data_dir(), "config.dets") |> String.to_charlist()
{:ok, @table} = :dets.open_file(@table, file: dets_path, type: :set)

# Insert
:ok = :dets.insert(@table, {key, value})
:dets.sync(@table)

# Read
case :dets.lookup(@table, key) do
  [{^key, val}] -> val
  [] -> default_value
end
```

### HTTP GET with :httpc (verified from Erlang docs + :inets already in project)
```elixir
# Source: https://elixirforum.com/t/httpc-cheatsheet/50337 + Erlang :httpc docs
# :inets is already started via extra_applications in application.ex
url = String.to_charlist("http://#{host}:#{port}/api/tags")
timeout_opts = [timeout: 5_000, connect_timeout: 3_000]

case :httpc.request(:get, {url, []}, timeout_opts, []) do
  {:ok, {{_, 200, _}, _headers, body}} ->
    Jason.decode(to_string(body))
  {:ok, {{_, status, _}, _, _}} ->
    {:error, {:http_error, status}}
  {:error, reason} ->
    {:error, {:connection_error, reason}}
end
```

### Adding a WebSocket Message Handler (from AgentCom.Socket)
```elixir
# Source: lib/agent_com/socket.ex -- pattern for task_accepted, task_progress, etc.
defp handle_msg(%{"type" => "ollama_report", "ollama_url" => url}, state) do
  AgentCom.LlmRegistry.register_from_sidecar(state.agent_id, url)
  reply = Jason.encode!(%{"type" => "ollama_report_ack"})
  {:push, {:text, reply}, state}
end
```

### Adding HTTP Routes (from AgentCom.Endpoint)
```elixir
# Source: lib/agent_com/endpoint.ex -- follows existing admin route pattern
post "/api/admin/llm-endpoints" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    case Validation.validate_http(:post_llm_endpoint, conn.body_params) do
      {:ok, _} ->
        host = conn.body_params["host"]
        port = conn.body_params["port"] || 11434
        name = conn.body_params["name"]
        case AgentCom.LlmRegistry.register_manual(host, port, name) do
          {:ok, endpoint} -> send_json(conn, 201, endpoint)
          {:error, reason} -> send_json(conn, 422, %{"error" => reason})
        end
      {:error, errors} ->
        send_validation_error(conn, errors)
    end
  end
end
```

### Node.js Resource Collection (from Node.js os module docs)
```javascript
// Source: Node.js os module (built-in)
const os = require('os');

function collectResourceMetrics() {
  const cpus = os.cpus();
  const cpuUsage = cpus.map(cpu => {
    const total = Object.values(cpu.times).reduce((a, b) => a + b, 0);
    const idle = cpu.times.idle;
    return Math.round((1 - idle / total) * 100);
  });
  const avgCpu = Math.round(cpuUsage.reduce((a, b) => a + b, 0) / cpuUsage.length);

  return {
    cpu_percent: avgCpu,
    ram_total_bytes: os.totalmem(),
    ram_used_bytes: os.totalmem() - os.freemem(),
    cpu_count: cpus.length
  };
}
```

### Ollama /api/tags Response Shape (verified from official docs)
```json
{
  "models": [
    {
      "name": "llama3:latest",
      "model": "llama3",
      "modified_at": "2025-10-03T23:34:03Z",
      "size": 3825819519,
      "digest": "fe938a131f40...",
      "details": {
        "format": "gguf",
        "family": "llama",
        "families": ["llama"],
        "parameter_size": "7B",
        "quantization_level": "Q4_0"
      }
    }
  ]
}
```

### Ollama /api/ps Response Shape (verified from official docs) -- For VRAM reporting only
```json
{
  "models": [
    {
      "name": "mistral:latest",
      "model": "mistral:latest",
      "size": 5137025024,
      "digest": "2ae6f6dd...",
      "details": { "format": "gguf", "family": "llama" },
      "expires_at": "2024-06-04T14:38:31Z",
      "size_vram": 5137025024
    }
  ]
}
```
Note: `/api/ps` provides `size_vram` per running model. Since the locked decision says model availability is binary (no warm/cold), we use `/api/tags` for model discovery, but `/api/ps` is still useful for extracting VRAM usage as a resource metric (HOST-02 requirement).

## Discretion Recommendations

Based on research of the codebase patterns and Ollama API behavior:

### Health Check Interval and Failure Threshold
**Recommendation:** 30-second polling interval, 2 consecutive failures before marking unhealthy.
**Rationale:** 30s matches the existing scheduler sweep interval and sidecar heartbeat interval. 2 misses (60s) provides tolerance for transient network blips without being so slow that actual outages go undetected. This aligns with common Ollama health check patterns found in Docker Compose configurations.

### Recovery Behavior
**Recommendation:** Immediate recovery -- mark healthy on first successful health check response.
**Rationale:** No probation period is needed because the health check itself validates Ollama is responding to API requests. If it responds to `/api/tags` with a 200, it is genuinely ready. Probation adds complexity for no practical benefit at this scale.

### Deregistration Handling When Tasks Are In-Flight
**Recommendation:** Block deregistration of endpoints that have tasks in-flight. Return an error with the task IDs. Admin must drain tasks first or use a `force` flag.
**Rationale:** Model routing (Phase 19/20) will assign tasks to specific endpoints. Removing an endpoint mid-task would require complex reassignment logic that belongs in the routing phase, not the registry phase. For now, keep it simple: refuse removal if busy.

### Resource Metrics to Collect
**Recommendation:** CPU percent (average across cores), RAM used/total bytes, and VRAM used/total bytes (from Ollama `/api/ps`). No per-core CPU breakdown, no disk metrics.
**Rationale:** CPU/RAM come free from Node.js `os` module. VRAM data comes from Ollama's `/api/ps` response (`size_vram` field) -- the hub can query this during health checks. This satisfies HOST-01 (CPU, RAM) and HOST-02 (GPU VRAM via Ollama). GPU utilization percentage (like from `nvidia-smi`) is not worth the complexity of shelling out and parsing; VRAM usage from Ollama is more directly relevant.

### Resource Reporting Transport
**Recommendation:** Separate `resource_report` WebSocket message type, sent by sidecar every 30 seconds (aligned with heartbeat interval).
**Rationale:** Piggybacking on ping would require changing the existing ping/pong protocol which is well-tested. A separate message type is cleaner, validates independently, and can be rate-limited separately. The 30s interval matches the existing heartbeat cadence without adding message volume.

### Dashboard Layout
**Recommendation:** Two new sections in the dashboard:
1. **Fleet Model Summary** (top card): "3 hosts have llama3, 1 has codellama" -- compact text summary
2. **LLM Registry Table**: columns for Host, Port, Status (color dot), Models (comma-separated), Source (auto/manual), Last Checked. Below each row (or expandable): CPU/RAM/VRAM bars.

Controls: "Add Endpoint" button opens an inline form (host, port, name). "Remove" button per row (with confirmation). Per locked decision: dashboard controls for add/remove, not API-only.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Ollama `/` health check | Ollama `/api/tags` health check | Community consensus 2024+ | `/api/tags` validates model availability, not just process liveness |
| Manual model registration | Auto-discovery via `/api/tags` | Ollama 0.1+ | Hub queries Ollama directly; no need for admin to list models |
| `nvidia-smi` for VRAM | Ollama `/api/ps` `size_vram` field | Ollama API evolution | More portable, works without NVIDIA CLI tools, gives per-model VRAM |

**Deprecated/outdated:**
- Ollama root endpoint `/` returns `"Ollama is running"` (string, not JSON). Useful only as a basic liveness check. Use `/api/tags` instead for a meaningful health check that also discovers models in one request.

## Open Questions

1. **Should health checks also query `/api/ps` for VRAM data?**
   - What we know: `/api/tags` gives available models, `/api/ps` gives running models with `size_vram`. The locked decision says no warm/cold tracking, but HOST-02 requires VRAM tracking.
   - What's unclear: Whether to query both endpoints on every health check cycle or only `/api/tags`.
   - Recommendation: Query both. `/api/tags` for model discovery and binary health, `/api/ps` for VRAM usage data per HOST-02. The VRAM data is a resource metric, not a model status -- it serves a different requirement. Sum `size_vram` across running models for total VRAM in use.

2. **Tailscale DNS vs IP addresses for Ollama endpoints**
   - What we know: The system operates across a Tailscale mesh. Sidecars can report their Tailscale hostname or IP.
   - What's unclear: Whether admin will register endpoints by Tailscale hostname (e.g., `my-gpu-box`) or by IP (e.g., `100.64.x.x`).
   - Recommendation: Accept both formats. Store as-provided. The `:httpc` client resolves DNS normally, and Tailscale names resolve on the mesh. Display the raw host string on the dashboard.

3. **What happens to endpoints when hub restarts?**
   - What we know: DETS persists endpoint registrations. Sidecars will reconnect and re-report. Manual endpoints persist.
   - What's unclear: Should all endpoints be marked `:unknown` on startup until the first health check completes?
   - Recommendation: Yes. On init, load endpoints from DETS but set all statuses to `:unknown`. Schedule an immediate health check. This prevents showing stale "healthy" status from before restart.

## Sources

### Primary (HIGH confidence)
- AgentCom codebase: `lib/agent_com/task_queue.ex` -- DETS persistence patterns
- AgentCom codebase: `lib/agent_com/config.ex` -- DETS GenServer pattern
- AgentCom codebase: `lib/agent_com/metrics_collector.ex` -- ETS ephemeral metrics pattern
- AgentCom codebase: `lib/agent_com/socket.ex` -- WebSocket message handling pattern
- AgentCom codebase: `lib/agent_com/endpoint.ex` -- HTTP API route patterns
- AgentCom codebase: `lib/agent_com/dashboard_state.ex` -- Dashboard state aggregation pattern
- AgentCom codebase: `lib/agent_com/dashboard_socket.ex` -- Dashboard WebSocket event forwarding
- AgentCom codebase: `lib/agent_com/dets_backup.ex` -- DETS backup and table management
- AgentCom codebase: `sidecar/index.js` -- Sidecar WebSocket protocol, heartbeat, identify
- [Ollama /api/tags docs](https://docs.ollama.com/api/tags) -- Model listing endpoint
- [Ollama API docs (ReadTheDocs)](https://ollama.readthedocs.io/en/api/) -- `/api/ps` running models with `size_vram`
- [Erlang :httpc docs](https://www.erlang.org/docs/24/man/httpc.html) -- HTTP client API

### Secondary (MEDIUM confidence)
- [:httpc cheatsheet (ElixirForum)](https://elixirforum.com/t/httpc-cheatsheet/50337) -- Practical Elixir usage examples for :httpc
- [Ollama GitHub Issue #1378](https://github.com/ollama/ollama/issues/1378) -- Health check endpoint discussion, confirms `GET /` returns "Ollama is running"
- [Node.js os module docs](https://nodejs.org/api/os.html) -- `os.cpus()`, `os.totalmem()`, `os.freemem()`

### Tertiary (LOW confidence)
- None -- all critical claims verified against primary sources.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries already in use in the project, no new deps
- Architecture: HIGH -- all patterns directly observed in existing codebase (DETS, ETS, GenServer, PubSub, WebSocket messages, HTTP routes, dashboard)
- Pitfalls: HIGH -- derived from direct analysis of codebase patterns and Erlang/Elixir type system
- Ollama API: HIGH -- verified against official Ollama documentation
- Discretion recommendations: MEDIUM -- based on codebase conventions and general best practice, but these are design decisions that could reasonably go other ways

**Research date:** 2026-02-12
**Valid until:** 2026-03-14 (30 days -- stable domain, no fast-moving dependencies)
