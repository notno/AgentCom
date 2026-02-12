# Phase 12: Input Validation - Context

**Gathered:** 2026-02-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Schema validation at all WebSocket and HTTP entry points. Malformed payloads receive structured error responses — no GenServer crashes. All validation logic lives in a single reusable Validation module called by both WebSocket and HTTP handlers.

</domain>

<decisions>
## Implementation Decisions

### Error response format
- Claude's discretion on JSON shape (flat vs field-level detail) — pick what fits existing protocol
- Echo back offending fields in error responses so agents can debug what they sent wrong
- Claude's discretion on WebSocket error frame type (reuse existing "error" type or new "validation_error")
- Claude's discretion on HTTP status code (400 vs 422)

### Validation strictness
- **Unknown fields: accept and pass through** — most permissive, enables extensibility without hub changes
- **Strict types** — string where integer expected is a validation error, no coercion
- Claude's discretion on required vs optional fields — determine per field based on whether a wrong default would be worse than a missing value
- Claude's discretion on string length limits — set reasonable limits where they matter

### Schema evolution
- Claude's discretion on versioned vs evolve-in-place schemas
- Claude's discretion on schema source (code vs JSON Schema files)
- Claude's discretion on handling unknown message types
- **Schema discovery endpoint** — GET /api/schemas returns supported message types and their schemas, so agents can introspect

### Rejection behavior
- **Escalating response for repeat offenders** — after 10 validation failures in 1 minute, temporarily disconnect the agent
- **Exponential backoff on reconnect** — first disconnect: 30s cooldown, second: 1 min, third: 5 min. Prevents tight reconnect-fail loops.
- **Dashboard visibility** — show validation error counts per agent, recent failures, and any disconnected-for-violations agents

### Claude's Discretion
- Error response JSON structure
- WebSocket error frame type
- HTTP status codes for validation failures
- Required vs optional field determination per message type
- String length limits
- Schema versioning strategy
- Schema source (code vs data files)
- Unknown message type handling

</decisions>

<specifics>
## Specific Ideas

- Schema discovery endpoint (GET /api/schemas) should be useful for v1.2 when agents need to introspect what enriched task fields are supported
- Validation should be forward-compatible with v1.2 enriched task format — unknown fields pass through, so new task fields (context, criteria, verification_steps) won't require validation module updates

</specifics>

<deferred>
## Deferred Ideas

- Rate limiting on validation failures — Phase 15 handles rate limiting separately, though the escalating disconnect provides basic protection
- Structured logging of validation events — Phase 13 will add structured logging; validation can emit events that Phase 13 formats

</deferred>

---

*Phase: 12-input-validation*
*Context gathered: 2026-02-11*
