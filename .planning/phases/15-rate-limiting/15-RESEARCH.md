# Phase 15: Rate Limiting - Research

**Researched:** 2026-02-12
**Domain:** Token bucket rate limiting for WebSocket and HTTP entry points in Elixir/BEAM hub
**Confidence:** HIGH

## Summary

Phase 15 adds per-agent rate limiting at both WebSocket and HTTP entry points with per-action-tier granularity. The system currently has no rate limiting -- any connected agent can send unlimited messages, submit unlimited tasks, or create unlimited channels. The Phase 12 ViolationTracker provides basic protection against malformed messages (10 validation failures in 1 minute triggers disconnect), but this does nothing against a well-formed message flood.

The core deliverable is a `RateLimiter` module backed by an ETS table that implements a token bucket algorithm with lazy refill. Each agent gets independent buckets for three action tiers (light/normal/heavy) and separate buckets for WebSocket vs HTTP. The module is called from `Socket.handle_in/2` (after validation, before business logic) and from a new `RateLimitPlug` in the HTTP pipeline. Over-limit requests receive structured `rate_limited` error frames with `retry_after_ms`. Agents approaching their limit (80%) receive proactive warning frames. Rate-limited agents are temporarily excluded from the Scheduler's assignment pool via a flag mechanism. Per-agent overrides and whitelist exemptions are stored in Config DETS and manageable via admin API endpoints. Dashboard integration shows per-agent rate limit status and a system-wide summary card, with push notifications for sustained abuse.

**Primary recommendation:** Build a custom ETS-backed token bucket rate limiter as a pure-function module (not a GenServer), following the same architecture as ViolationTracker from Phase 12. ETS provides lock-free concurrent reads/writes from multiple Socket processes. A companion GenServer handles only periodic cleanup of stale bucket entries. No external dependencies needed -- the algorithm is ~100 lines of core logic.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Default thresholds
- Lenient defaults -- high limits that only catch clear abuse. Agents are trusted; limits are a safety net
- 3-tier action classification: light actions (heartbeat, status) get highest limits; normal actions (messages, updates) get moderate; heavy actions (task submit, channel create) get lowest
- WebSocket and HTTP have independent rate limit buckets -- an agent at its WS limit can still make HTTP calls
- Claude's Discretion: token bucket vs fixed window algorithm choice

#### Throttling response
- Over-limit messages are rejected with a structured error frame: `rate_limited` type with `retry_after_ms` field
- Progressive backoff for repeat offenders -- each consecutive violation increases `retry_after_ms`. Resets after a quiet period
- Rate-limited agents are temporarily excluded from Scheduler's assignment pool -- existing work continues but no new tasks assigned until rate limit clears
- Claude's Discretion: exact retry_after calculation (precise ms vs rounded to seconds)

#### Override policy
- Per-agent overrides supported -- admins can set custom limits for specific agents via API, stored in Config DETS
- Runtime configuration via PUT API endpoint -- changes take effect immediately on the agent's current connection (bucket reset/adjusted to new limits)
- Configurable whitelist of exempt agent_ids -- dashboard is always exempt. Whitelist manageable via API
- Auth follows existing admin endpoint pattern (same as PUT /api/admin/log-level)

#### Visibility & escalation
- Both: agent cards show per-agent rate limit status (usage %, violations) AND a summary "Rate Limits" card with system-wide overview and top offenders
- Push notifications on threshold -- when an agent exceeds a violation count in a window (e.g., 10 violations in 5 min), not every single violation
- Pre-warning at 80% -- agents receive a warning frame when reaching 80% of a bucket, allowing proactive slowdown

### Claude's Discretion
- Token bucket algorithm implementation details (refill rate, burst allowance)
- ETS vs GenServer for bucket state storage
- Exact default threshold numbers per tier
- Progressive backoff curve and reset timing
- Dashboard card layout and real-time update mechanism

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

## Discretion Recommendations

### 1. Token Bucket Algorithm (over Fixed Window)

**Recommendation:** Token bucket with lazy refill.

**Rationale:** The user listed "token bucket vs fixed window" as Claude's discretion, but the phase requirements (RATE-01) explicitly state "token bucket algorithm." Token bucket is also the better fit because:

1. **Burst tolerance:** Agents naturally send messages in bursts (e.g., task_accepted + task_progress + task_complete in quick succession). A fixed window would count these against a hard limit that resets at arbitrary boundaries. Token bucket accumulates capacity during idle periods, naturally absorbing legitimate bursts.

2. **No boundary spike problem:** Fixed window allows 2x the limit at window boundaries (e.g., 100 requests at 59:59 + 100 at 00:01). Token bucket has no window boundaries.

3. **Smooth refill:** Tokens refill continuously at `capacity / window_ms` rate. An agent that backs off regains capacity proportionally to how long they waited.

4. **Lazy refill pattern:** No timer needed. On each request, compute `elapsed_ms * refill_rate`, add tokens (capped at capacity), then check if enough tokens for the action. This is a single ETS read + write per request with no background process.

### 2. ETS for Bucket State (not GenServer)

**Recommendation:** Use ETS (`:public`, `:set`) with atomic operations, following the ViolationTracker pattern from Phase 12.

**Rationale:** The existing system already uses this pattern successfully. Socket processes are one-per-agent WebSocket connections. If bucket state lived in a GenServer, every message from every agent would serialize through that single process. With ETS:

- Socket process reads/writes its agent's bucket directly -- zero serialization
- HTTP request handler reads/writes its agent's bucket directly -- zero serialization
- Multiple agents' requests process in parallel with no contention
- The ViolationTracker (`:validation_backoff` ETS table) proves this pattern works in the codebase

A companion GenServer (`RateLimiter.Sweeper` or integration into existing `Reaper`) handles only periodic cleanup of stale bucket entries (agents that disconnected). This is identical to how `ViolationTracker.sweep_expired/1` works.

**ETS table structure:**

```
Table: :rate_limit_buckets (named, public, set)

Entry format:
{
  {agent_id, channel, tier},  # key: channel = :ws | :http, tier = :light | :normal | :heavy
  tokens,                      # current token count (float, stored as integer * 1000 for precision)
  last_refill_at,             # timestamp in milliseconds (monotonic or system time)
  capacity,                    # max tokens (may differ from default if agent has override)
  refill_rate                  # tokens per millisecond
}

Example entries for agent "my-agent":
{{"my-agent", :ws, :light},   120_000, 1707660000000, 120_000, 2_000}
{{"my-agent", :ws, :normal},   60_000, 1707660000000,  60_000, 1_000}
{{"my-agent", :ws, :heavy},    10_000, 1707660000000,  10_000,   167}
{{"my-agent", :http, :light}, 120_000, 1707660000000, 120_000, 2_000}
{{"my-agent", :http, :normal}, 60_000, 1707660000000,  60_000, 1_000}
{{"my-agent", :http, :heavy},  10_000, 1707660000000,  10_000,   167}
```

Tokens stored as integer * 1000 to avoid floating-point precision issues while still supporting sub-token refill rates.

**Violation tracking (separate entries):**

```
{
  {agent_id, :violations},     # key
  count,                        # violations in current window
  window_start,                 # timestamp
  consecutive_violations        # for progressive backoff
}
```

### 3. Default Threshold Numbers Per Tier

**Recommendation:** Lenient defaults that only catch clear abuse, per the "safety net, not a cage" philosophy.

| Tier | Actions | WS Capacity (per minute) | HTTP Capacity (per minute) | Rationale |
|------|---------|--------------------------|---------------------------|-----------|
| **Light** | `ping`, `list_agents`, `list_channels`, `status`, `channel_history` | 120/min (2/sec) | 120/min (2/sec) | Heartbeats at default 15-min interval are ~0.07/min. Even aggressive polling at 1/sec is well within 120. |
| **Normal** | `message`, `channel_publish`, `channel_subscribe`, `channel_unsubscribe`, `task_accepted`, `task_progress`, `task_complete`, `task_failed`, `task_recovering` | 60/min (1/sec) | 60/min (1/sec) | Normal agent work produces ~5-10 messages/min. 60/min is 6x headroom. |
| **Heavy** | `channel_create` (HTTP), `task_submit` (HTTP), `identify` (WS) | 10/min | 10/min | Creating channels or submitting tasks is infrequent. 10/min handles batch submissions without allowing flood. |

**Burst allowance:** Capacity = the number above. An agent that has been idle accumulates up to `capacity` tokens. A burst of `capacity` messages is allowed, then the agent must slow to the refill rate.

**Refill rate:** `capacity / 60_000` tokens per millisecond (linear refill over one minute to reach full capacity).

**Why these numbers are lenient:** At 5 agents, the hub handles ~500 total messages/minute at normal load. Even with all 5 agents at full WS normal rate (60/min each = 300/min), the hub operates well within capacity. The limits exist only to catch a tight loop sending thousands of messages per second.

### 4. Progressive Backoff Curve

**Recommendation:** Exponential backoff with reset after quiet period.

| Consecutive Violations | `retry_after_ms` | Cumulative Penalty |
|------------------------|-------------------|--------------------|
| 1st | 1,000 (1 second) | Mild -- agent likely just hit a burst |
| 2nd | 2,000 (2 seconds) | Getting persistent |
| 3rd | 5,000 (5 seconds) | Clear pattern |
| 4th | 10,000 (10 seconds) | Significant slowdown |
| 5th+ | 30,000 (30 seconds) | Agent needs attention |

**Reset:** After 60 seconds with no violations, the consecutive count resets to 0.

**Calculation:** Return `retry_after_ms` rounded to seconds (e.g., 1000, 2000, 5000). This is simpler for agents to handle and avoids sub-second timing precision requirements. The exact value is `retry_after_ms` in the response but rounded to nearest 1000ms.

### 5. Dashboard Card Layout

**Recommendation:** Follow the existing dashboard card pattern. Two new components:

1. **Per-agent rate limit status** added to existing agent cards: a small bar or percentage showing bucket fill level for the dominant tier (the one closest to limit). Color-coded: green (<50%), yellow (50-80%), red (>80%).

2. **System-wide "Rate Limits" summary card**: Shows total violations in the last hour, top 3 offending agents, and current exempt agents count. Uses the same card layout as the existing queue stats card.

**Real-time updates:** Follow the existing DashboardSocket pattern -- the DashboardState GenServer already subscribes to PubSub topics and computes snapshots. Add rate limit data to the snapshot. The dashboard WebSocket pushes updates on the existing 10-second cycle.

## Standard Stack

### Core

| Component | Type | Purpose | Why Standard |
|-----------|------|---------|--------------|
| ETS `:rate_limit_buckets` | OTP stdlib | Bucket state storage | Lock-free concurrent access from Socket/Plug processes. Same pattern as `:validation_backoff` and `:agent_metrics`. |
| ETS `:rate_limit_overrides` | OTP stdlib | Per-agent override cache | Read from Config DETS on startup, cached in ETS for O(1) lookup on every request. Updated on admin API calls. |
| Config DETS | Existing GenServer | Persistent override/whitelist storage | Already used for heartbeat interval, default repo, etc. Per-agent overrides need persistence across restarts. |

### Supporting

| Component | Type | Purpose | When to Use |
|-----------|------|---------|-------------|
| Phoenix.PubSub | Existing | Broadcast rate limit events | When violation thresholds are crossed, for dashboard/alerter consumption |
| :telemetry | Existing (via Bandit) | Emit rate limit metrics | Every check (allow/deny), for MetricsCollector to aggregate |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Custom ETS token bucket | Hammer ~> 7.0 library | Hammer is mature and battle-tested, but adds a dependency for ~100 lines of core logic. Our requirements (3 tiers, per-agent overrides, Scheduler integration, 80% warning, progressive backoff) would require wrapping Hammer anyway. The ViolationTracker pattern already proves custom ETS works in this codebase. |
| Custom ETS token bucket | ExRated library | Similar tradeoff to Hammer. ExRated is a GenServer (serialization bottleneck). Our use case needs parallel per-agent access from Socket processes. |
| Custom ETS token bucket | Atomic Bucket library | Uses `:atomics` for even faster access, but very new (Feb 2026). Adds dependency risk for marginal speed gain at our scale (<100 requests/second). |
| ETS | GenServer state | GenServer serializes all rate limit checks through one process. At 5 agents sending 60 msg/min each, this is ~5 msg/sec -- fine. But ETS is also fine and is the established pattern in this codebase. No reason to deviate. |

**No new dependencies needed.** Pure Elixir + ETS, consistent with Phase 12 decision: "Pure Elixir validation (no external deps)."

## Architecture Patterns

### Recommended Module Structure

```
lib/agent_com/
  rate_limiter.ex              # Core: pure functions for bucket operations + ETS
  rate_limiter/
    config.ex                  # Action tier classification, default thresholds
    sweeper.ex                 # Periodic cleanup of stale buckets (or integrate into Reaper)
  plugs/
    rate_limit.ex              # Plug for HTTP rate limiting
```

### Pattern 1: Lazy Token Bucket in ETS

**What:** Token bucket where tokens are not refilled on a timer. Instead, on each request, compute tokens to add based on elapsed time since last access, then deduct the cost.

**When to use:** Every rate limit check (both WS and HTTP).

**Why:** No background timer per agent. No timer per bucket. Zero overhead when agents are idle. Bucket state is only updated when actually accessed. This means 5 agents = 5 sets of buckets with zero background cost. 1000 agents = 1000 sets of buckets with zero background cost. Refill computation happens inline at the point of use.

**Example:**
```elixir
defmodule AgentCom.RateLimiter do
  @table :rate_limit_buckets

  @doc """
  Check if an action is allowed for an agent on a channel.

  Returns:
    {:allow, remaining_tokens}
    {:warn, remaining_tokens}    # 80% threshold crossed
    {:deny, retry_after_ms}
  """
  def check(agent_id, channel, tier) do
    # 1. Check whitelist -- exempt agents skip rate limiting
    if exempt?(agent_id), do: {:allow, :exempt}, else: do_check(agent_id, channel, tier)
  end

  defp do_check(agent_id, channel, tier) do
    key = {agent_id, channel, tier}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, tokens, last_refill, capacity, refill_rate}] ->
        # Lazy refill: compute tokens gained since last access
        elapsed_ms = max(now - last_refill, 0)
        new_tokens = min(tokens + elapsed_ms * refill_rate, capacity)

        cond do
          new_tokens >= 1000 ->
            # Deduct 1 token (stored as * 1000)
            remaining = new_tokens - 1000
            :ets.insert(@table, {key, remaining, now, capacity, refill_rate})

            if remaining < capacity * 0.2 do
              {:warn, div(remaining, 1000)}
            else
              {:allow, div(remaining, 1000)}
            end

          true ->
            # Insufficient tokens -- calculate retry_after
            tokens_needed = 1000 - new_tokens
            retry_ms = ceil(tokens_needed / refill_rate)
            :ets.insert(@table, {key, new_tokens, now, capacity, refill_rate})
            {:deny, retry_ms}
        end

      [] ->
        # First request -- initialize bucket at full capacity minus 1
        {capacity, refill_rate} = get_limits(agent_id, channel, tier)
        remaining = capacity - 1000
        :ets.insert(@table, {key, remaining, now, capacity, refill_rate})
        {:allow, div(remaining, 1000)}
    end
  end
end
```

### Pattern 2: Action Tier Classification

**What:** Map each WebSocket message type and HTTP endpoint to one of three tiers.

**When to use:** At the point of rate limit check, to determine which bucket to debit.

**Example:**
```elixir
defmodule AgentCom.RateLimiter.Config do
  @light_ws ["ping", "list_agents", "list_channels", "status", "channel_history"]
  @normal_ws ["message", "channel_publish", "channel_subscribe", "channel_unsubscribe",
              "task_accepted", "task_progress", "task_complete", "task_failed", "task_recovering"]
  @heavy_ws ["identify"]

  def ws_tier(message_type) when message_type in @light_ws, do: :light
  def ws_tier(message_type) when message_type in @normal_ws, do: :normal
  def ws_tier(message_type) when message_type in @heavy_ws, do: :heavy
  def ws_tier(_unknown), do: :normal  # Safe default for future message types

  # HTTP endpoints classified by action weight
  @light_http [:get_agents, :get_channels, :get_tasks, :get_metrics, :get_health,
               :get_mailbox, :get_schemas, :get_dashboard_state]
  @normal_http [:post_message, :post_channel_publish, :post_mailbox_ack,
                :get_messages, :get_task_detail, :get_channel_info]
  @heavy_http [:post_task, :post_channel, :post_admin_push_task, :post_onboard_register]

  def http_tier(action) when action in @light_http, do: :light
  def http_tier(action) when action in @normal_http, do: :normal
  def http_tier(action) when action in @heavy_http, do: :heavy
  def http_tier(_unknown), do: :normal
end
```

### Pattern 3: Integration Points -- Socket and Endpoint

**What:** Rate limiting gate inserted at the right point in the request pipeline.

**WebSocket (Socket.handle_in/2):** After JSON decode and validation, before `handle_msg/2`. This matches the existing flow: `JSON.decode -> Validation.validate_ws_message -> [NEW: RateLimiter.check] -> handle_msg`.

```elixir
# In Socket.handle_in/2, after validation succeeds:
case Validation.validate_ws_message(msg) do
  {:ok, validated} ->
    message_type = Map.get(validated, "type")
    tier = RateLimiter.Config.ws_tier(message_type)

    case RateLimiter.check(state.agent_id, :ws, tier) do
      {:allow, _remaining} ->
        handle_msg(validated, state)
      {:warn, remaining} ->
        # Send warning frame then process normally
        warn_frame = Jason.encode!(%{
          "type" => "rate_limit_warning",
          "tier" => to_string(tier),
          "remaining" => remaining,
          "capacity" => RateLimiter.capacity(state.agent_id, :ws, tier)
        })
        {:push, [{:text, warn_frame}], state}
        # Then continue to handle_msg...
      {:deny, retry_after_ms} ->
        RateLimiter.record_violation(state.agent_id)
        reply = Jason.encode!(%{
          "type" => "rate_limited",
          "retry_after_ms" => retry_after_ms,
          "tier" => to_string(tier)
        })
        {:push, {:text, reply}, state}
    end
end
```

**HTTP (Plug):** A new `AgentCom.Plugs.RateLimit` plug inserted after `RequireAuth` (so we have `agent_id`) or using the source IP for unauthenticated endpoints.

```elixir
defmodule AgentCom.Plugs.RateLimit do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    action = Keyword.get(opts, :action, :unknown)
    tier = AgentCom.RateLimiter.Config.http_tier(action)

    # Use authenticated agent_id if available, fall back to IP
    agent_id = conn.assigns[:authenticated_agent] ||
               to_string(:inet_parse.ntoa(conn.remote_ip))

    case AgentCom.RateLimiter.check(agent_id, :http, tier) do
      {:allow, _} -> conn
      {:warn, _} -> conn  # HTTP has no warning mechanism, just allow
      {:deny, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", to_string(div(retry_after_ms, 1000)))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{
          "error" => "rate_limited",
          "retry_after_ms" => retry_after_ms,
          "tier" => to_string(tier)
        }))
        |> halt()
    end
  end
end
```

### Pattern 4: Scheduler Exclusion

**What:** When an agent is rate-limited, temporarily exclude it from the Scheduler's assignment pool.

**When:** Rate-limited agents should not receive new task assignments. Existing work (already assigned tasks) continues.

**How:** The Scheduler already queries `AgentFSM.list_all()` and filters for `:idle` agents. The simplest integration is to add a flag check:

```elixir
# In Scheduler.try_schedule_all/1, filter out rate-limited agents:
idle_agents =
  AgentCom.AgentFSM.list_all()
  |> Enum.filter(fn a -> a.fsm_state == :idle end)
  |> Enum.reject(fn a -> AgentCom.RateLimiter.rate_limited?(a.agent_id) end)
```

`rate_limited?/1` checks ETS for the agent's violation state. An agent is considered "rate-limited" when they have active violations (consecutive_violations > 0). The flag clears automatically after the quiet period resets the violation count.

### Pattern 5: Admin API Endpoints

**What:** CRUD endpoints for per-agent overrides and whitelist management.

**Endpoints:**
```
GET    /api/admin/rate-limits              -- Current default limits + all overrides
PUT    /api/admin/rate-limits/defaults     -- Update default limits (takes effect for new connections)
PUT    /api/admin/rate-limits/:agent_id    -- Set per-agent override
DELETE /api/admin/rate-limits/:agent_id    -- Remove per-agent override (revert to defaults)
GET    /api/admin/rate-limits/whitelist    -- List exempt agent_ids
PUT    /api/admin/rate-limits/whitelist    -- Set whitelist (replaces entire list)
POST   /api/admin/rate-limits/whitelist    -- Add agent_id to whitelist
DELETE /api/admin/rate-limits/whitelist/:agent_id -- Remove from whitelist
```

**Auth:** Same as `PUT /api/admin/log-level` -- requires authenticated agent with admin privileges (via `RequireAuth` plug + admin check). The admin_agents() helper in endpoint.ex already provides this pattern.

**Storage:** Overrides and whitelist stored in Config DETS under keys like `:rate_limit_overrides` and `:rate_limit_whitelist`. On startup, these are loaded into ETS (`:rate_limit_overrides` table) for O(1) lookup. On API update, both DETS and ETS are updated atomically.

**Immediate effect:** When an override is set via PUT, the agent's current ETS bucket entries are deleted. The next request from that agent creates new bucket entries with the override limits. This is simpler than trying to adjust existing bucket state and has the same practical effect.

### Anti-Patterns to Avoid

- **Single GenServer for all rate limiting:** Serializes every message through one process. Use ETS for parallel access.
- **Timer-based token refill:** Creates N timers for N agents x M tiers. Lazy refill is O(0) when idle.
- **Rate limiting before authentication:** The agent_id is needed for per-agent buckets. On WebSocket, the `identify` message must be processed first. On HTTP, auth provides the agent_id. For unauthenticated endpoints, rate limit by IP.
- **Coupling rate limiter to specific message types:** Classify actions into tiers, not individual types. Adding a new message type should only require adding it to the tier list.
- **Global rate limit (not per-agent):** A single global bucket means one agent's burst affects all agents. Per-agent isolation is critical.
- **Modifying AgentFSM state for rate limiting:** Adding rate_limited state to FSM overcomplicates it. Instead, use a simple ETS flag check in the Scheduler. The FSM knows nothing about rate limits.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Token bucket algorithm | Complex stateful bucket with background timers | Lazy refill pattern (compute on access) | Timer-based refill is harder to test, creates N*M background processes, and accumulates timer drift. Lazy refill is a single pure function. |
| Monotonic time | System.system_time/1 for bucket timing | System.monotonic_time/1 | System time can jump (NTP correction). Monotonic time only moves forward. Prevents negative elapsed time causing token underflow. |
| ETS atomic read-modify-write | Read, compute, write (race condition) | Single :ets.insert that computes new state atomically | Actually, ETS insert is not atomic with respect to concurrent reads. For this use case, the worst case of a race is slightly inaccurate token count, which is acceptable. True atomicity would require :atomics or a GenServer. At our scale (~5 agents), races are astronomically unlikely. |

**Key insight:** The token bucket with lazy refill is genuinely simple -- ~100 lines of core logic. Adding a library dependency for this is not justified when the codebase already has the ETS-access pattern (ViolationTracker) and the rate limiting requirements are project-specific (3 tiers, Scheduler integration, 80% warning).

## Common Pitfalls

### Pitfall 1: Monotonic Time vs System Time

**What goes wrong:** Using `System.system_time(:millisecond)` for elapsed time calculation. NTP correction can cause time to jump backward, making `elapsed_ms` negative, which subtracts tokens instead of adding them.

**Why it happens:** `System.system_time` is the default mental model. ViolationTracker uses it because it tracks timestamps for human-readable reporting. But rate limiting needs elapsed duration, not wall-clock timestamps.

**How to avoid:** Use `System.monotonic_time(:millisecond)` for all bucket timing. It is guaranteed to never go backward. Store the monotonic timestamp in the ETS bucket entry. Use `System.system_time` only for human-facing timestamps (dashboard display, API responses).

**Warning signs:** Negative `retry_after_ms` values in error responses. Tokens appearing to increase without time passing.

### Pitfall 2: ETS Race Conditions on Bucket Update

**What goes wrong:** Two concurrent requests from the same agent (possible via HTTP) both read the bucket, compute new tokens, and write back. The second write overwrites the first, effectively granting a free token.

**Why it happens:** ETS read + compute + write is not atomic. In the WebSocket path this is unlikely (one Socket process per agent), but in the HTTP path multiple concurrent requests can hit the same bucket.

**How to avoid:** Accept the race as benign. At our scale (5 agents, <100 requests/second), the probability of two HTTP requests from the same agent arriving in the same microsecond is negligible. The worst case is one extra request getting through the rate limit -- not a safety concern for a "safety net" system. If precision becomes critical later, use `:atomics` or a per-agent GenServer.

**Warning signs:** None visible at normal scale. Only matters if rate limits are tight and agents are sending high-frequency HTTP requests.

### Pitfall 3: Bucket Initialization Race

**What goes wrong:** An agent's first two messages arrive nearly simultaneously. Both see an empty ETS entry, both initialize the bucket, and the second initialization overwrites the first token deduction.

**How to avoid:** Use `:ets.insert_new/2` for initialization. If it returns `false`, the bucket already exists -- fall through to the normal refill path. This is a single atomic check.

### Pitfall 4: Override/Whitelist Cache Invalidation

**What goes wrong:** Admin updates the whitelist via API, but the ETS cache is not updated. The old whitelist continues to apply until restart.

**Why it happens:** Config DETS is the source of truth, but ETS is the read path for performance. Updating one without the other creates inconsistency.

**How to avoid:** Every admin API call must update both Config DETS (persistence) and ETS cache (runtime) in the same function. The admin API handler calls `RateLimiter.update_whitelist/1` which does both operations. Additionally, on startup, load from DETS into ETS. This is the same pattern as how overrides should work.

### Pitfall 5: Rate Limiting the identify Message

**What goes wrong:** The `identify` message is classified as `:heavy` tier. But rate limiting requires knowing the `agent_id`, which is only available after `identify` succeeds. If we rate limit by the not-yet-identified agent, we use the wrong key (nil).

**How to avoid:** Skip rate limiting for the `identify` message. The `identify` message is already protected by Phase 12's ViolationTracker (authentication failure backoff). Rate limiting starts after identification. This is a small gap (one message type is unthrottled), but `identify` is already limited by: (1) token authentication, (2) ViolationTracker's backoff on auth failures, (3) WebSocket connection establishment overhead.

### Pitfall 6: Dashboard Exemption Not Configured

**What goes wrong:** The dashboard WebSocket (`/ws/dashboard` via `DashboardSocket`) does not go through the rate limiter because it uses a different WebSocket handler. But dashboard HTTP requests (`GET /api/dashboard/state`, `GET /api/metrics`) go through the HTTP pipeline and could be rate limited by IP.

**How to avoid:** Dashboard HTTP endpoints are already unauthenticated. Rate limit by IP, not agent_id. The dashboard is typically accessed from localhost or the local network. Add "dashboard" as a keyword in the whitelist documentation, but the actual exemption is at the agent_id level. For HTTP endpoints with no auth, rate limit by IP and set a generous limit. The whitelist config key `:rate_limit_whitelist` holds agent_ids. For IP-based exemption, add a separate `:rate_limit_ip_whitelist` list, or simply set very high IP-based limits.

## Code Examples

### Token Bucket Core -- Lazy Refill

```elixir
# Source: Custom implementation following ViolationTracker pattern

defmodule AgentCom.RateLimiter do
  @moduledoc """
  Per-agent token bucket rate limiter backed by ETS.

  NOT a GenServer -- provides pure functions called from Socket and Plug processes.
  Follows the same architecture as AgentCom.Validation.ViolationTracker.
  """

  @bucket_table :rate_limit_buckets
  @override_table :rate_limit_overrides

  # Default capacities per tier (tokens * 1000 for integer precision)
  @defaults %{
    light:  %{capacity: 120_000, refill_rate_per_ms: 2_000 / 60_000},  # 120/min
    normal: %{capacity:  60_000, refill_rate_per_ms: 1_000 / 60_000},  # 60/min
    heavy:  %{capacity:  10_000, refill_rate_per_ms:   167 / 60_000}   # 10/min
  }

  @warn_threshold 0.2  # Warn when 20% of capacity remains (i.e., 80% used)

  @spec check(String.t(), :ws | :http, :light | :normal | :heavy) ::
    {:allow, non_neg_integer()} | {:warn, non_neg_integer()} | {:deny, non_neg_integer()}
  def check(agent_id, channel, tier) do
    if exempt?(agent_id) do
      {:allow, :exempt}
    else
      do_check(agent_id, channel, tier)
    end
  end

  defp do_check(agent_id, channel, tier) do
    key = {agent_id, channel, tier}
    now = System.monotonic_time(:millisecond)
    cost = 1000  # 1 token = 1000 internal units

    case :ets.lookup(@bucket_table, key) do
      [{^key, tokens, last_refill, capacity, refill_rate}] ->
        elapsed = max(now - last_refill, 0)
        refilled = min(tokens + trunc(elapsed * refill_rate), capacity)

        if refilled >= cost do
          remaining = refilled - cost
          :ets.insert(@bucket_table, {key, remaining, now, capacity, refill_rate})

          if remaining < trunc(capacity * @warn_threshold) do
            {:warn, div(remaining, 1000)}
          else
            {:allow, div(remaining, 1000)}
          end
        else
          tokens_needed = cost - refilled
          retry_ms = if refill_rate > 0, do: ceil(tokens_needed / refill_rate), else: 60_000
          # Round to nearest second
          retry_ms = div(retry_ms + 999, 1000) * 1000
          :ets.insert(@bucket_table, {key, refilled, now, capacity, refill_rate})
          {:deny, retry_ms}
        end

      [] ->
        # Initialize bucket
        {capacity, refill_rate} = get_limits(agent_id, channel, tier)
        remaining = capacity - cost
        :ets.insert(@bucket_table, {key, remaining, now, capacity, refill_rate})
        {:allow, div(remaining, 1000)}
    end
  end

  defp get_limits(agent_id, _channel, tier) do
    # Check for per-agent override first
    case :ets.lookup(@override_table, {agent_id, tier}) do
      [{_, capacity, refill_rate}] -> {capacity, refill_rate}
      [] ->
        defaults = Map.get(@defaults, tier)
        {trunc(defaults.capacity), defaults.refill_rate_per_ms}
    end
  end

  defp exempt?(agent_id) do
    case :ets.lookup(@override_table, :whitelist) do
      [{:whitelist, list}] -> agent_id in list
      [] -> false
    end
  end
end
```

### HTTP Rate Limit Plug

```elixir
# Source: Following existing AgentCom.Plugs.RequireAuth pattern

defmodule AgentCom.Plugs.RateLimit do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    action = Keyword.get(opts, :action, :unknown)
    tier = AgentCom.RateLimiter.Config.http_tier(action)

    agent_id = conn.assigns[:authenticated_agent] ||
               format_ip(conn.remote_ip)

    case AgentCom.RateLimiter.check(agent_id, :http, tier) do
      {:allow, _} ->
        conn

      {:warn, _} ->
        # HTTP has no warning channel; just allow
        conn

      {:deny, retry_after_ms} ->
        AgentCom.RateLimiter.record_violation(agent_id)
        retry_seconds = max(div(retry_after_ms, 1000), 1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_seconds))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{
          "error" => "rate_limited",
          "retry_after_ms" => retry_after_ms
        }))
        |> halt()
    end
  end

  defp format_ip({a, b, c, d}), do: "ip:#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: "ip:#{inspect(ip)}"
end
```

### WebSocket Rate Limit Integration

```elixir
# Source: Extension of existing Socket.handle_in/2 pattern

# In handle_in, after validation, before handle_msg:
defp check_rate_limit(msg, state) do
  # Skip rate limiting for unidentified connections
  # (identify is the only valid message before identification)
  if not state.identified do
    {:ok, msg, state}
  else
    message_type = Map.get(msg, "type")
    tier = AgentCom.RateLimiter.Config.ws_tier(message_type)

    case AgentCom.RateLimiter.check(state.agent_id, :ws, tier) do
      {:allow, _remaining} ->
        {:ok, msg, state}

      {:warn, remaining} ->
        capacity = AgentCom.RateLimiter.capacity(state.agent_id, :ws, tier)
        warn_frame = %{
          "type" => "rate_limit_warning",
          "tier" => to_string(tier),
          "remaining" => remaining,
          "capacity" => capacity
        }
        {:warn, msg, warn_frame, state}

      {:deny, retry_after_ms} ->
        AgentCom.RateLimiter.record_violation(state.agent_id)
        {:deny, retry_after_ms, tier, state}
    end
  end
end
```

### Telemetry Events

```elixir
# New telemetry events for rate limiting:

# Emitted on every rate limit check
:telemetry.execute(
  [:agent_com, :rate_limit, :check],
  %{tokens_remaining: remaining},
  %{agent_id: agent_id, channel: channel, tier: tier, result: :allow | :warn | :deny}
)

# Emitted on rate limit violation
:telemetry.execute(
  [:agent_com, :rate_limit, :violation],
  %{retry_after_ms: retry_after_ms, consecutive: consecutive_count},
  %{agent_id: agent_id, channel: channel, tier: tier}
)
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| GenServer holding bucket state | ETS with lazy refill, no GenServer | Elixir ecosystem ~2023 | Eliminates serialization bottleneck for rate limiting in concurrent systems |
| Fixed window rate limiting | Token bucket with lazy refill | General industry practice | Handles bursts gracefully, no window boundary spikes |
| External rate limiting (nginx, API gateway) | Application-level rate limiting | N/A (both are valid) | Application-level gives per-agent granularity that reverse proxy cannot |
| Global rate limit | Per-agent rate limit | Standard practice | Prevents one agent from affecting others |

**Deprecated/outdated:**
- `Hammer v6.x` had a different API. `Hammer v7.x` (current) uses `use Hammer, backend: :ets` pattern.
- `ExRated` uses GenServer internally, which serializes. Still works, but ETS-direct is preferred for per-connection use.

## Open Questions

1. **HTTP endpoint action classification completeness**
   - What we know: All current HTTP endpoints can be classified into the 3 tiers.
   - What's unclear: As new endpoints are added in future phases, they need to be classified. There is no automated way to enforce this.
   - Recommendation: Default unknown actions to `:normal` tier. Log a warning for unclassified actions so they get noticed and classified.

2. **Interaction with Phase 12 ViolationTracker**
   - What we know: ViolationTracker disconnects after 10 validation failures in 1 minute. Rate limiting rejects messages but does NOT disconnect.
   - What's unclear: Should rate limit violations count toward the ViolationTracker's disconnect threshold? A rate-limited agent sending many messages gets many `rate_limited` responses, which are not validation failures.
   - Recommendation: Keep them independent. Validation violations indicate a broken client. Rate limit violations indicate a fast client. Different problems, different responses. ViolationTracker disconnects; rate limiter throttles. They do not interact.

3. **IP-based vs agent-based rate limiting for unauthenticated HTTP endpoints**
   - What we know: Some endpoints have no auth (`/health`, `/api/agents`, `/api/channels`, `/api/schemas`, `/api/dashboard/state`, `/api/metrics`, `/api/onboard/register`).
   - What's unclear: Whether to rate limit these at all, and if so, whether by IP or by a global pool.
   - Recommendation: Rate limit unauthenticated endpoints by IP with generous limits (e.g., 60/min for most, 5/min for `/api/onboard/register`). This prevents abuse of the registration endpoint while allowing normal dashboard polling.

## Sources

### Primary (HIGH confidence)
- AgentCom codebase -- direct analysis of all source files in `lib/agent_com/`, particularly `socket.ex`, `endpoint.ex`, `validation/violation_tracker.ex`, `scheduler.ex`, `config.ex`, `analytics.ex`, `dashboard_state.ex`, `telemetry.ex`, `metrics_collector.ex`, `application.ex`
- [Hammer v7.2.0 documentation](https://hexdocs.pm/hammer/readme.html) -- Token bucket algorithm API, ETS backend, configuration patterns
- [Hammer.ETS.TokenBucket docs](https://hexdocs.pm/hammer/Hammer.ETS.TokenBucket.html) -- `hit/5` API returning `{:allow, remaining}` or `{:deny, retry_ms}`, lazy refill implementation

### Secondary (MEDIUM confidence)
- [Atomic Bucket rate limiter](https://elixirforum.com/t/atomic-bucket-fast-single-node-rate-limiter-implementing-token-bucket-algorithm/74225) -- Lock-free atomics-based token bucket, performance characteristics, ETS + atomics hybrid approach
- [Rate Limiting in Elixir with GenServers](https://akoutmos.com/post/rate-limiting-with-genservers/) -- Token bucket vs leaky bucket architecture patterns, Task.Supervisor isolation, GenServer state management trade-offs
- [Rate Limiting Server Requests in Elixir](https://www.nutrient.io/blog/rate-limiting-server-requests/) -- ETS update_counter pattern, fixed window vs sliding window vs token bucket trade-offs
- [Building a Distributed Rate Limiter in Elixir with HashRing](https://blog.appsignal.com/2025/02/04/building-a-distributed-rate-limiter-in-elixir-with-hashring.html) -- GenServer-based rate limiter architecture, distributed considerations
- [ExRated library](https://github.com/grempe/ex_rated) -- GenServer-based rate limiter, ETS bucket storage pattern
- [Limitex library](https://github.com/pggalaviz/limitex) -- Pure Elixir distributed rate limiter with sharded ETS

### Tertiary (LOW confidence)
- [Token Bucket Algorithm explained](https://www.systemoverflow.com/learn/rate-limiting/token-bucket/token-bucket-algorithm-core-mechanics-and-burst-control) -- General token bucket theory, burst control mechanics

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- ETS is proven in this codebase (ViolationTracker, Analytics, MetricsCollector). No new dependencies.
- Architecture: HIGH -- Follows exact same patterns as ViolationTracker (ETS + pure functions). Integration points (Socket, Endpoint, Scheduler) are well-understood from codebase analysis.
- Pitfalls: HIGH -- Identified from direct codebase analysis (monotonic time, ETS races, identify message ordering, dashboard exemption, override invalidation).
- Algorithm: HIGH -- Token bucket with lazy refill is well-documented across multiple Elixir sources (Hammer, Atomic Bucket, ExRated). The lazy refill variant avoids timers entirely.

**Research date:** 2026-02-12
**Valid until:** 2026-03-14 (30 days -- stable domain, no fast-moving dependencies)
