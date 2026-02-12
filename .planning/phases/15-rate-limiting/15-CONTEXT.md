# Phase 15: Rate Limiting - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Token bucket rate limiting on WebSocket and HTTP entry points with per-action granularity. Misbehaving or compromised agents cannot flood the system with messages or requests. Different action types have independent limits. Agents receive structured error responses with retry guidance.

</domain>

<decisions>
## Implementation Decisions

### Default thresholds
- Lenient defaults — high limits that only catch clear abuse. Agents are trusted; limits are a safety net
- 3-tier action classification: light actions (heartbeat, status) get highest limits; normal actions (messages, updates) get moderate; heavy actions (task submit, channel create) get lowest
- WebSocket and HTTP have independent rate limit buckets — an agent at its WS limit can still make HTTP calls
- Claude's Discretion: token bucket vs fixed window algorithm choice

### Throttling response
- Over-limit messages are rejected with a structured error frame: `rate_limited` type with `retry_after_ms` field
- Progressive backoff for repeat offenders — each consecutive violation increases `retry_after_ms`. Resets after a quiet period
- Rate-limited agents are temporarily excluded from Scheduler's assignment pool — existing work continues but no new tasks assigned until rate limit clears
- Claude's Discretion: exact retry_after calculation (precise ms vs rounded to seconds)

### Override policy
- Per-agent overrides supported — admins can set custom limits for specific agents via API, stored in Config DETS
- Runtime configuration via PUT API endpoint — changes take effect immediately on the agent's current connection (bucket reset/adjusted to new limits)
- Configurable whitelist of exempt agent_ids — dashboard is always exempt. Whitelist manageable via API
- Auth follows existing admin endpoint pattern (same as PUT /api/admin/log-level)

### Visibility & escalation
- Both: agent cards show per-agent rate limit status (usage %, violations) AND a summary "Rate Limits" card with system-wide overview and top offenders
- Push notifications on threshold — when an agent exceeds a violation count in a window (e.g., 10 violations in 5 min), not every single violation
- Pre-warning at 80% — agents receive a warning frame when reaching 80% of a bucket, allowing proactive slowdown

### Claude's Discretion
- Token bucket algorithm implementation details (refill rate, burst allowance)
- ETS vs GenServer for bucket state storage
- Exact default threshold numbers per tier
- Progressive backoff curve and reset timing
- Dashboard card layout and real-time update mechanism

</decisions>

<specifics>
## Specific Ideas

- Lenient philosophy: "safety net, not a cage" — limits should be high enough that well-behaved agents never notice them
- 3-tier classification maps to action weight: light/normal/heavy rather than per-action tuning
- The Scheduler integration is important: rate-limited agents don't just get errors, they stop receiving new work
- 80% warning gives agents a chance to self-regulate before hitting the wall

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 15-rate-limiting*
*Context gathered: 2026-02-12*
