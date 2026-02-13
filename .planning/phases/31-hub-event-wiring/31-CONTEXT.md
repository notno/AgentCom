# Phase 31: Hub Event Wiring - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

GitHub webhook endpoint exposed via Tailscale Funnel. Push and PR merge events on active repos wake the FSM. Goal backlog changes (API submission) also trigger FSM transitions.
</domain>

<decisions>
## Implementation Decisions

### GitHub Webhooks
- Hub exposes POST /api/webhooks/github endpoint
- Verify webhook signature (HMAC-SHA256 with webhook secret)
- Handle push events: extract repo, branch, commit info
- Handle pull_request events (action: "closed" + merged: true): extract repo, PR info
- Match incoming repo to active repos in RepoRegistry

### Tailscale Funnel
- Expose hub's port 4000 via `tailscale funnel 4000`
- HTTPS termination handled by Tailscale
- Funnel URL becomes the webhook URL configured in GitHub repo settings

### FSM Transitions
- Git push on active repo -> wake FSM from Resting to Improving
- PR merge on active repo -> wake FSM from Resting to Improving
- Goal submission (already handled by GoalBacklog PubSub in Phase 27) -> wake FSM to Executing
- Events on non-active repos are ignored

### Claude's Discretion
- Webhook event filtering (which GitHub events to subscribe to beyond push/PR)
- Event debouncing (rapid pushes shouldn't trigger multiple transitions)
- Whether to store webhook event history
- Tailscale Funnel setup documentation
</decisions>

<specifics>
## Specific Ideas

- Webhook secret stored in Config GenServer (not hardcoded)
- Log all webhook events for debugging
- Consider a "webhook test" endpoint for verifying connectivity
</specifics>

<constraints>
## Constraints

- Depends on Phase 29 (HubFSM) for transition triggers
- Tailscale Funnel must be available on the hub machine
- Webhook signature verification is mandatory (security)
- Must handle GitHub's webhook retry behavior gracefully
</constraints>
