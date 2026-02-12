# Phase 20: Sidecar Execution - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Sidecars execute tasks using the LLM backend the hub assigned — local Ollama for standard work, Claude API for complex work, or local shell commands for trivial work — and report what model and tokens were used. Verification and retry loops are separate phases (21, 22).

</domain>

<decisions>
## Implementation Decisions

### Execution feedback
- LLM response tokens stream to the dashboard in real-time as they're generated
- Trivial task stdout also streams to dashboard — consistent experience across all execution types
- Claude's Discretion: streaming path (hub relay vs direct sidecar-to-dashboard) — pick based on existing architecture
- Claude's Discretion: whether to store full LLM response or just extracted result — pick based on storage implications

### Failure behavior
- Ollama failure: sidecar retries 1-2 times locally, then reports failure to hub for reassignment to a different endpoint
- Claude API failure: retry 2-3 times with exponential backoff, then mark task as failed (no downgrade to lesser model — complex tasks need Claude)
- Trivial shell failure: retry once before reporting (covers transient issues like file locks)
- All retry attempts and failure events stream to dashboard in real-time (e.g., "Ollama retry 1/2...", "backing off 5s...")

### Cost visibility
- Per-task cost breakdown: model used, tokens in/out, estimated cost in dollars
- Ollama tasks show equivalent Claude API cost — demonstrates savings from running locally
- No spending guardrails at sidecar level — that's the hub/scheduler's responsibility
- Claude API calls go through Claude Code, which handles key management — sidecar doesn't manage API keys directly

### Trivial execution boundaries
- Anything with a specific shell command qualifies for trivial execution — not limited to git/file ops
- Timeout is configurable per-task — a file rename and a test suite have different needs
- Claude's Discretion: sandboxing/isolation approach — pick based on existing sidecar execution model
- Claude's Discretion: stdout/stderr capture strategy — pick based on what's most useful for downstream processing

</decisions>

<specifics>
## Specific Ideas

- Claude API interaction happens through Claude Code (not raw API calls) — key management is already handled
- Streaming should feel consistent across all three execution types (LLM tokens, shell stdout, progress events)
- Dashboard should make retry/failure activity visible as it happens, not just in final results

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 20-sidecar-execution*
*Context gathered: 2026-02-12*
