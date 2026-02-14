---
phase: 31-hub-event-wiring
plan: 01
subsystem: fsm
tags: [hub-fsm, webhook, hmac, plug, body-reader, github]

# Dependency graph
requires:
  - phase: 29-hub-fsm-core
    provides: "2-state HubFSM GenServer with tick-based evaluation and Predicates module"
provides:
  - "3-state HubFSM with :improving state for webhook-triggered improvement cycles"
  - "CacheBodyReader for raw request body caching in conn.assigns"
  - "WebhookVerifier for HMAC-SHA256 GitHub webhook signature verification"
  - "Plug.Parsers wired with body_reader for all requests"
affects: [31-02-PLAN, 31-03-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns: ["CacheBodyReader body_reader option for Plug.Parsers", "HMAC-SHA256 timing-safe webhook verification"]

key-files:
  created:
    - lib/agent_com/cache_body_reader.ex
    - lib/agent_com/webhook_verifier.ex
  modified:
    - lib/agent_com/hub_fsm.ex
    - lib/agent_com/hub_fsm/predicates.ex
    - lib/agent_com/endpoint.ex

key-decisions:
  - "Both resting->executing and resting->improving increment cycle count (both are active work cycles)"
  - ":improving exits only via budget exhaustion or watchdog timeout (not goal-based predicates)"

patterns-established:
  - "body_reader option on Plug.Parsers: CacheBodyReader accumulates chunks in conn.assigns[:raw_body] as reversed list"
  - "WebhookVerifier.verify_signature/1 returns {:ok, conn} | {:error, reason} for pipeline integration"

# Metrics
duration: 2min
completed: 2026-02-14
---

# Phase 31 Plan 01: FSM Improving State + Webhook Infrastructure Summary

**3-state HubFSM with :improving state, CacheBodyReader for raw body caching, and WebhookVerifier for HMAC-SHA256 GitHub signature verification**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-14T03:07:05Z
- **Completed:** 2026-02-14T03:09:01Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- HubFSM expanded from 2-state to 3-state FSM with :improving for webhook-triggered improvement cycles
- CacheBodyReader caches raw request body in conn.assigns[:raw_body] for all requests via Plug.Parsers body_reader
- WebhookVerifier performs timing-safe HMAC-SHA256 verification against GitHub X-Hub-Signature-256 header
- Predicates evaluate :improving state: exits on budget exhaustion, stays otherwise

## Task Commits

Each task was committed atomically:

1. **Task 1: Add :improving state to HubFSM and Predicates** - `1e9fa63` (feat)
2. **Task 2: Create CacheBodyReader and WebhookVerifier modules** - `1e92203` (feat)

## Files Created/Modified
- `lib/agent_com/hub_fsm.ex` - 3-state FSM with :improving transitions and updated cycle count logic
- `lib/agent_com/hub_fsm/predicates.ex` - Evaluation clauses for :improving state (budget exit + stay)
- `lib/agent_com/cache_body_reader.ex` - Raw body caching for Plug.Parsers body_reader option
- `lib/agent_com/webhook_verifier.ex` - HMAC-SHA256 signature verification with timing-safe comparison
- `lib/agent_com/endpoint.ex` - Plug.Parsers configured with CacheBodyReader body_reader

## Decisions Made
- Both resting->executing and resting->improving increment cycle count -- both represent active work cycles
- :improving exits only via budget exhaustion or watchdog timeout, not via goal-based predicates like :executing

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- FSM foundation ready for Plan 31-02 (webhook route handler in endpoint)
- CacheBodyReader and WebhookVerifier are the building blocks the webhook POST handler will use

---
*Phase: 31-hub-event-wiring*
*Completed: 2026-02-14*
