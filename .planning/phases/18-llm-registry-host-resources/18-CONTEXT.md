# Phase 18: LLM Registry and Host Resources - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Hub tracks Ollama endpoints, model availability, and host resource utilization across the Tailscale mesh. Admin can register endpoints manually, sidecars auto-report local Ollama instances, and the dashboard displays registry and resource data. Model routing decisions and task execution are separate phases (19, 20).

</domain>

<decisions>
## Implementation Decisions

### Registration workflow
- Dual registration: sidecars auto-report local Ollama during heartbeat, plus admin can manually register remote endpoints via HTTP API
- Auto-reported endpoints are trusted immediately (no approval step) — consistent with existing sidecar trust model
- Hub auto-discovers available models by querying Ollama's /api/tags after registration — no manual model listing
- Model availability is binary (available or not) — no warm/cold VRAM tracking

### Health check behavior
- Hub polls Ollama endpoints directly on a timer (not relying on sidecar heartbeat for health)
- Health checks apply to both auto-reported and manually-registered endpoints

### Resource reporting
- Resource metrics are ephemeral — rebuilt from live reports as sidecars reconnect, not persisted in DETS
- When a sidecar stops reporting, clear its resource data after a timeout (show as unknown, not stale)

### Dashboard presentation
- Table view for the LLM registry — one row per endpoint showing host, port, models, health status
- Resource utilization bars (CPU, RAM, etc.) shown alongside endpoint status per host
- Fleet-level model summary at top ("3 hosts have llama3, 1 has codellama") plus per-endpoint model detail
- Dashboard controls for adding/removing endpoints — not API-only

### Claude's Discretion
- Health check polling interval and failure threshold (how many misses before unhealthy)
- Recovery behavior (immediate vs probation after coming back online)
- Deregistration handling when tasks are in-flight (drain vs block)
- Which specific resource metrics to collect (CPU/RAM/GPU/VRAM mix)
- Resource reporting transport mechanism (piggyback on heartbeat vs separate message)
- Exact dashboard layout and component design within table-based approach

</decisions>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 18-llm-registry-host-resources*
*Context gathered: 2026-02-12*
