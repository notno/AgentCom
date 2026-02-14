---
phase: 31-hub-event-wiring
plan: 02
subsystem: api
tags: [webhook, github, hmac, endpoint, ets, hub-fsm, repo-registry]

# Dependency graph
requires:
  - phase: 31-hub-event-wiring-01
    provides: "3-state HubFSM with :improving, CacheBodyReader, WebhookVerifier"
provides:
  - "POST /api/webhooks/github endpoint with HMAC verification, push and PR merge dispatch"
  - "GET /api/webhooks/github/history for webhook event debugging"
  - "PUT /api/config/webhook-secret for runtime HMAC secret configuration"
  - "WebhookHistory ETS module (capped at 100 entries, ordered_set)"
  - "Active repo matching via RepoRegistry with GitHub full_name to repo ID normalization"
  - "FSM wake to :improving on push/PR merge for active repos"
affects: [31-03-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns: ["WebhookHistory ETS capped log (same pattern as HubFSM.History)", "GitHub full_name to repo ID normalization (/ to -)"]

key-files:
  created:
    - lib/agent_com/webhook_history.ex
  modified:
    - lib/agent_com/endpoint.ex
    - lib/agent_com/hub_fsm.ex

key-decisions:
  - "WebhookHistory initialized in HubFSM.init alongside History.init_table (single startup point)"
  - "GitHub full_name normalized by replacing / with - to match RepoRegistry url_to_id convention"
  - "Webhook routes placed after Hub FSM API section, GET /history before POST to avoid path conflicts"
  - "Non-merge PR events stored with pr_action field to avoid duplicate :action key in history map"

patterns-established:
  - "Webhook event history: ETS ordered_set with negated timestamps, capped at 100 entries"
  - "match_active_repo/1: normalize GitHub owner/repo to owner-repo, find in RepoRegistry"

# Metrics
duration: 2min
completed: 2026-02-14
---

# Phase 31 Plan 02: Webhook Endpoint + History + Config Summary

**GitHub webhook endpoint with push/PR merge dispatch, active repo matching via RepoRegistry, FSM wake to :improving, ETS event history, and runtime webhook secret config API**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-14T03:10:46Z
- **Completed:** 2026-02-14T03:13:00Z
- **Tasks:** 1
- **Files modified:** 3

## Accomplishments
- POST /api/webhooks/github receives push and PR merge events, verifies HMAC, matches active repos, wakes FSM to :improving
- GET /api/webhooks/github/history returns capped webhook event log from ETS
- PUT /api/config/webhook-secret allows runtime configuration of HMAC signing secret (min 16 chars)
- WebhookHistory ETS module with init_table, record, list, clear (capped at 100 entries)
- All webhook events logged via Logger.info for debugging

## Task Commits

Each task was committed atomically:

1. **Task 1: Create WebhookHistory and add webhook endpoint + config routes** - `67770be` (feat)

## Files Created/Modified
- `lib/agent_com/webhook_history.ex` - ETS-backed webhook event history with 100-entry cap
- `lib/agent_com/endpoint.ex` - Webhook POST/GET/PUT routes, handle_github_event helpers, match_active_repo, wake_fsm
- `lib/agent_com/hub_fsm.ex` - WebhookHistory.init_table() call in HubFSM.init

## Decisions Made
- WebhookHistory initialized in HubFSM.init alongside History.init_table -- single startup point, idempotent check
- GitHub `repository.full_name` (owner/repo) normalized to owner-repo to match RepoRegistry `url_to_id` convention
- GET /api/webhooks/github/history placed BEFORE POST /api/webhooks/github to prevent "history" being captured as parameter
- Non-merge PR events use `pr_action` field instead of `action` to avoid duplicate map key with the "ignored" action field

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed duplicate :action key in PR non-merge history record**
- **Found during:** Task 1 (Webhook endpoint implementation)
- **Issue:** Map literal had both `action: action` (GitHub PR action) and `action: "ignored"` causing compiler warning
- **Fix:** Renamed the GitHub PR action field to `pr_action` to avoid key collision
- **Files modified:** lib/agent_com/endpoint.ex
- **Verification:** `mix compile --warnings-as-errors` passes clean
- **Committed in:** 67770be (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Minor naming fix for map key uniqueness. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Webhook endpoint fully wired, ready for Plan 31-03 (integration testing / dashboard wiring)
- FSM transitions to :improving on active repo push/PR merge events
- WebhookHistory queryable for dashboard integration

---
*Phase: 31-hub-event-wiring*
*Completed: 2026-02-14*
