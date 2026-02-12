# Phase 19: Model-Aware Scheduler - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Scheduler routes tasks to the right execution tier based on complexity classification, model availability, and host load. Trivial tasks go to sidecar direct execution, standard tasks go to local Ollama agents, complex tasks go to Claude agents. Picks the best available endpoint when multiple options exist. Execution itself is Phase 20; this phase is the routing decision layer.

</domain>

<decisions>
## Implementation Decisions

### Routing rules
- Flexible fallback: tasks can move across tiers based on availability
- One-step max fallback: tasks can only move one tier up or down (trivial<->standard<->complex), never skip a tier
- Brief wait then fallback: wait a short timeout for the preferred tier before falling back to the next tier
- Trust complexity classification: if Phase 17 marks a task as trivial, send it to sidecar without verifying sidecar capabilities

### Load balancing
- Weighted by capacity: hosts with more resources get more tasks, considering both current load and total capacity
- Soft repo affinity: prefer same host for same-repo tasks when load is similar, to benefit from filesystem caches and context
- Single Claude API key: one key shared across all agents for complex tasks, no key rotation needed

### Routing transparency
- Expandable detail on dashboard: summary (final endpoint + tier) by default, click to expand full routing trace
- Visual indicator for fallback tasks: badge or icon on tasks that didn't run on their preferred tier
- Every routing decision logged with: model selected, endpoint chosen, classification reason

### Degraded behavior
- Standard tier down: escalate standard tasks to Claude API (consistent with one-step fallback)
- All tiers down: queue non-trivial tasks with TTL, expire stale tasks rather than building unbounded backlog; trivial tasks still execute locally
- Alert after threshold: only alert when a tier stays down beyond a configurable duration, not on brief blips

### Claude's Discretion
- Warm vs cold model preference weighting in load balancer
- Telemetry approach for routing decisions (full per-task events vs aggregates) — follow existing Phase 14 patterns
- Cost estimation in routing logs — include if data available from execution layer
- Gradual vs immediate backlog drain on tier recovery — follow existing queue patterns
- Specific timeout values for fallback wait and task TTL

</decisions>

<specifics>
## Specific Ideas

- Routing should feel like a natural extension of the existing Phase 4 scheduler — augmenting its matching logic with tier awareness rather than replacing it
- Fallback decisions should be clearly traceable so cost impact of tier degradation is visible over time

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 19-model-aware-scheduler*
*Context gathered: 2026-02-12*
