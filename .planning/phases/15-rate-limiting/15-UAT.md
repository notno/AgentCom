---
status: testing
phase: 15-rate-limiting
source: [15-01-SUMMARY.md, 15-02-SUMMARY.md, 15-03-SUMMARY.md, 15-04-SUMMARY.md]
started: 2026-02-12T12:00:00Z
updated: 2026-02-12T12:00:00Z
---

## Current Test

number: 1
name: Compilation and tests pass
expected: |
  `mix compile --warnings-as-errors` succeeds with no warnings.
  `mix test --exclude smoke --exclude skip` runs 270+ tests with 0 failures (pre-existing seed-dependent failures excluded).
  Rate limiter tests specifically: `mix test test/agent_com/rate_limiter_test.exs` runs 31+ tests, all passing.
awaiting: user response

## Tests

### 1. Compilation and tests pass
expected: `mix compile --warnings-as-errors` succeeds with no warnings. `mix test --exclude smoke --exclude skip` runs 270+ tests with 0 failures. `mix test test/agent_com/rate_limiter_test.exs` runs 31+ tests, all passing.
result: [pending]

### 2. Token bucket works in IEx
expected: Start `iex -S mix`. Run `AgentCom.RateLimiter.check("test-agent", :ws, :normal)` and get `{:allow, 59}` (capacity 60 minus 1 token). Run it 59 more times rapidly and eventually get `{:deny, retry_after_ms}` with a positive integer. Run `AgentCom.RateLimiter.Config.ws_tier("ping")` and get `:light`. Run `AgentCom.RateLimiter.Config.ws_tier("message")` and get `:normal`.
result: [pending]

### 3. Rate limit defaults API
expected: With hub running, `curl http://localhost:4000/api/admin/rate-limits` (with valid auth header) returns JSON with `defaults` showing 3 tiers (light: capacity 120, normal: capacity 60, heavy: capacity 10), empty `overrides` map, and empty `whitelist` array.
result: [pending]

### 4. Whitelist management API
expected: POST `curl -X POST http://localhost:4000/api/admin/rate-limits/whitelist -H "Content-Type: application/json" -d "{\"agent_id\": \"my-exempt-agent\"}"` returns `{"status": "added", "agent_id": "my-exempt-agent"}`. GET `/api/admin/rate-limits/whitelist` shows `["my-exempt-agent"]`. DELETE `/api/admin/rate-limits/whitelist/my-exempt-agent` removes it. After whitelisting, `AgentCom.RateLimiter.check("my-exempt-agent", :ws, :normal)` returns `{:allow, :exempt}`.
result: [pending]

### 5. Per-agent override API
expected: PUT `curl -X PUT http://localhost:4000/api/admin/rate-limits/some-agent -H "Content-Type: application/json" -d "{\"normal\": {\"capacity\": 200, \"refill_rate_per_min\": 200}}"` returns `{"status": "updated", ...}`. GET `/api/admin/rate-limits` shows the override under `overrides`. DELETE `/api/admin/rate-limits/some-agent` removes it.
result: [pending]

### 6. Dashboard shows Rate Limits card
expected: Open `http://localhost:4000/dashboard` in browser. A "Rate Limits" summary panel is visible showing: violations count, rate-limited agent count, exempt agent count. If no agents are connected, values should be 0.
result: [pending]

### 7. Agent cards show rate limit usage
expected: With at least one agent connected to the hub, the agent table/cards in the dashboard include a rate limit column or indicator showing usage percentage. Color coding: green for low usage, yellow for moderate, red for high.
result: [pending]

### 8. HTTP 429 on rate limit exceeded
expected: Rapidly send many requests to an authenticated endpoint (e.g., `GET /api/tasks` in a loop). After exceeding the tier limit, the response changes to HTTP 429 with a `Retry-After` header and JSON body `{"error": "rate_limited", "retry_after_ms": N, "tier": "light"}`.
result: [pending]

### 9. Sweeper is running
expected: In IEx, `Process.whereis(AgentCom.RateLimiter.Sweeper)` returns a PID (not nil). The Sweeper is part of the supervision tree and starts automatically with the application.
result: [pending]

## Summary

total: 9
passed: 0
issues: 0
pending: 9
skipped: 0

## Gaps

[none yet]
