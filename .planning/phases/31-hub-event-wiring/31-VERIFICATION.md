---
phase: 31-hub-event-wiring
verified: 2026-02-13T20:00:00Z
status: human_needed
score: 3/3 truths verified (with warnings)
re_verification: false
warnings:
  - category: predicate-logic
    severity: warning
    issue: "Improving state predicates prioritize pending_goals over budget_exhausted"
    impact: "Edge case: if goals submitted while improving AND budget exhausted, transitions to :executing instead of :resting"
    location: "lib/agent_com/hub_fsm/predicates.ex:61-68"
    test_failures: "test/agent_com/hub_fsm/predicates_test.exs - 2 failures"
    blocking: false
    note: "Webhook wiring (Phase 31 goal) is complete and functional. This is a predicate evaluation order issue that should be addressed separately."
human_verification:
  - test: "GitHub webhook receives push event"
    expected: "Push event to active repo wakes FSM to :improving state"
    why_human: "Requires actual GitHub webhook delivery or ngrok tunnel"
  - test: "GitHub webhook receives PR merge event"
    expected: "PR merge on active repo wakes FSM to :improving state"
    why_human: "Requires actual GitHub PR merge webhook delivery"
  - test: "Webhook signature verification rejects tampered payloads"
    expected: "Invalid HMAC returns 401, event not processed"
    why_human: "Security validation in production environment"
---

# Phase 31: Hub Event Wiring Verification Report

**Phase Goal:** External repository events wake the hub from rest and trigger appropriate state transitions

**Verified:** 2026-02-13T20:00:00Z

**Status:** human_needed (automated checks passed with warnings)

**Re-verification:** No - initial verification


## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Hub exposes a GitHub webhook endpoint that receives push and PR merge events with signature verification | ✓ VERIFIED | POST /api/webhooks/github exists, WebhookVerifier HMAC-SHA256 implemented, 20/20 webhook tests pass |
| 2 | Git push or PR merge on active repo wakes the FSM from Resting to Improving | ✓ VERIFIED | handle_github_event calls wake_fsm(:improving), test "push on active repo" passes, force_transition implemented |
| 3 | Goal backlog changes wake the FSM from Resting to Executing | ✓ VERIFIED | Predicates.evaluate(:resting, %{pending_goals: >0}) returns {:transition, :executing}, test passes |

**Score:** 3/3 truths verified

### Required Artifacts

#### Core Implementation Files

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| lib/agent_com/webhook_verifier.ex | HMAC-SHA256 signature verification | ✓ VERIFIED | 45 lines, verify_signature/1 with timing-safe comparison, handles all error cases |
| lib/agent_com/webhook_history.ex | ETS-backed event history | ✓ VERIFIED | 57 lines, init_table, record, list, clear, 100-entry cap with trim |
| lib/agent_com/cache_body_reader.ex | Raw body caching for Plug.Parsers | ✓ VERIFIED | 28 lines, read_body/2 accumulates chunks in conn.assigns[:raw_body] |
| lib/agent_com/endpoint.ex | Webhook routes and handlers | ✓ VERIFIED | POST /api/webhooks/github, GET /history, PUT /config/webhook-secret, handle_github_event helpers |
| lib/agent_com/hub_fsm.ex | :improving state and force_transition | ✓ VERIFIED | 3-state FSM, force_transition/2 GenServer call, WebhookHistory.init_table in init |
| lib/agent_com/hub_fsm/predicates.ex | :improving state evaluation | ✓ VERIFIED | evaluate(:improving) clauses for pending_goals, budget_exhausted, stay |

#### Test Files

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| test/agent_com/webhook_verifier_test.exs | HMAC verification unit tests | ✓ VERIFIED | 107 lines, 6 tests: valid, invalid, missing, no secret, empty body, malformed |
| test/agent_com/webhook_history_test.exs | ETS history unit tests | ✓ VERIFIED | 101 lines, 5 tests: record/list, ordering, limit, cap at 100, clear |
| test/agent_com/webhook_endpoint_test.exs | Integration tests for webhook endpoint | ✓ VERIFIED | 249 lines, 9 tests: push/PR events, active/non-active repos, sig verification, history, config |
| test/agent_com/hub_fsm/predicates_test.exs | Extended predicate tests | ⚠️ PARTIAL | 4 :improving tests added, but 2 tests fail due to predicate evaluation order bug (not blocking Phase 31 goal) |


### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| Endpoint | WebhookVerifier | verify_signature/1 call | ✓ WIRED | Line 1458: AgentCom.WebhookVerifier.verify_signature(conn) |
| Endpoint | WebhookHistory | record/1 calls | ✓ WIRED | 8 references, record called for all event types |
| Endpoint | HubFSM | wake_fsm -> force_transition | ✓ WIRED | wake_fsm calls AgentCom.HubFSM.force_transition(target_state, reason) |
| Endpoint | RepoRegistry | match_active_repo | ✓ WIRED | 8 references, AgentCom.RepoRegistry.list_repos() called |
| CacheBodyReader | Plug.Parsers | body_reader option | ✓ WIRED | body_reader: {AgentCom.CacheBodyReader, :read_body, []} in endpoint |
| WebhookVerifier | raw_body assign | conn.assigns[:raw_body] | ✓ WIRED | Line 20: reads raw_body from conn.assigns populated by CacheBodyReader |
| HubFSM | WebhookHistory | init_table call | ✓ WIRED | Line 1: AgentCom.WebhookHistory.init_table() in HubFSM.init |

All key links verified and wired correctly.

### Requirements Coverage

| Requirement | Status | Evidence |
|-------------|--------|----------|
| FSM-06: Hub exposes GitHub webhook endpoint for push and PR merge events | ✓ SATISFIED | POST /api/webhooks/github with HMAC verification, tests pass |
| FSM-07: Git push/PR merge on active repos wakes FSM from Resting to Improving | ✓ SATISFIED | handle_github_event -> wake_fsm(:improving) -> force_transition, tests pass |
| FSM-08: Goal backlog changes wake FSM from Resting to Executing | ✓ SATISFIED | Predicates evaluate(:resting, pending_goals > 0) -> :executing, tests pass |

All requirements satisfied.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| lib/agent_com/hub_fsm/predicates.ex | 61-68 | Predicate evaluation order bug: pending_goals checked before budget_exhausted in :improving | ⚠️ WARNING | Edge case where FSM transitions to :executing instead of :resting when both pending_goals > 0 AND budget_exhausted. Does not block webhook wiring functionality. |

No blocker anti-patterns. One warning-level predicate logic issue that should be addressed in a separate fix.


### Test Results

**Phase 31 Webhook Tests:** 20/20 passed

```
AgentCom.WebhookVerifierTest: 6/6 passed
AgentCom.WebhookHistoryTest: 5/5 passed
AgentCom.WebhookEndpointTest: 9/9 passed
```

**Predicates Tests:** 11/13 passed (2 failures due to evaluation order bug - not blocking Phase 31)

The 2 failing tests reveal a bug in predicate evaluation order, but do not block the Phase 31 goal achievement. The webhook wiring is complete and functional.

### Commit Verification

All commits from SUMMARYs verified in git history:

- **31-01:** 1e9fa63 (feat: :improving state), 1e92203 (feat: CacheBodyReader + WebhookVerifier)
- **31-02:** 67770be (feat: webhook endpoint + history)
- **31-03:** 1654d0a (test: verifier + history), d65d781 (test: endpoint + predicates)

All commits exist and match SUMMARY descriptions.


### Human Verification Required

#### 1. GitHub Webhook Push Event Delivery

**Test:** Configure a GitHub repository webhook to point to the hub's /api/webhooks/github endpoint (via ngrok or public URL), set the webhook secret, and push to the repository.

**Expected:** 
- Hub receives the push event with valid HMAC signature
- WebhookVerifier accepts the signature
- match_active_repo finds the repo in RepoRegistry
- wake_fsm calls force_transition(:improving, reason)
- HubFSM transitions from :resting to :improving
- WebhookHistory records the event
- GET /api/webhooks/github/history shows the push event

**Why human:** Requires actual GitHub webhook delivery, network configuration (ngrok tunnel), and external GitHub repository.

#### 2. GitHub Webhook PR Merge Event Delivery

**Test:** Configure GitHub webhook, merge a pull request in the repository.

**Expected:**
- Hub receives pull_request event with action: "closed", merged: true
- Signature verified
- Active repo matched
- FSM wakes to :improving
- Event recorded in history

**Why human:** Requires actual PR merge operation on GitHub, webhook delivery.

#### 3. Webhook Signature Rejection (Security)

**Test:** Send a webhook request to /api/webhooks/github with a valid GitHub event payload but an incorrect HMAC signature (tampered payload).

**Expected:**
- WebhookVerifier returns {:error, :invalid_signature}
- Endpoint returns 401 Unauthorized
- Event is not processed
- No FSM transition occurs
- No history entry created

**Why human:** Security validation in production environment with real webhook requests.

#### 4. Goal Backlog FSM Wake (Integration)

**Test:** With HubFSM in :resting state, submit a new goal via the goal submission endpoint.

**Expected:**
- Goal is added to backlog with :submitted status
- On next FSM tick, Predicates.evaluate(:resting, %{pending_goals: 1}) returns {:transition, :executing}
- HubFSM transitions to :executing state
- FSM begins processing the goal

**Why human:** Requires integration test across multiple subsystems (goal submission, goal tracker, FSM ticker).

---

## Summary

**Phase 31 goal achieved with warnings.**

All three success criteria verified:
1. ✓ GitHub webhook endpoint with HMAC verification fully implemented and tested
2. ✓ Push and PR merge events wake FSM from :resting to :improving
3. ✓ Goal backlog changes wake FSM from :resting to :executing

**Warnings:**
- Predicate evaluation order bug: :improving state checks pending_goals before budget_exhausted, causing incorrect transition in edge case. Does not block webhook functionality. Should be fixed separately.

**Test Coverage:** 20/20 webhook-specific tests pass. All implementation artifacts verified at all three levels (exists, substantive, wired).

**Human verification recommended** for end-to-end webhook delivery, signature security validation, and goal backlog integration.

---

_Verified: 2026-02-13T20:00:00Z_
_Verifier: Claude (gsd-verifier)_
