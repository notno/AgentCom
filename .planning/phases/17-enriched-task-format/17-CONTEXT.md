# Phase 17: Enriched Task Format - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Tasks carry all the information agents need to understand scope, verify completion, and route efficiently. This phase adds structured context fields (repo, branch, files), success criteria, verification steps, and complexity classification to the task format. Existing v1.0/v1.1 tasks continue working unchanged.

</domain>

<decisions>
## Implementation Decisions

### Task Context Fields
- Repo identification uses inherit-plus-override: agent's `default_repo` from onboarding is the default, task can override with an explicit repo field
- File hints carry path + reason annotation (e.g., `{path: "src/scheduler.ex", reason: "modify routing logic"}`)
- Branch handling at Claude's discretion based on existing git workflow patterns in Phase 7

### Complexity Classification
- Four tiers: `trivial`, `standard`, `complex`, `unknown`
- `unknown` tier gets conservative routing (treated as standard or higher by scheduler)
- Heuristic engine always runs, even when submitter provides explicit tier — for observability and disagreement logging
- Explicit submitter tag always wins over heuristic inference
- Inferred complexity includes a confidence score (e.g., `{tier: "standard", confidence: 0.85}`)
- Heuristic signal design at Claude's discretion (word count, keywords, file count, etc.)

### Verification Step Format
- Structure design (typed vs freeform, separate vs combined fields) at Claude's discretion — optimize for what Phase 21 verification infrastructure will consume
- Soft limit on verification steps per task with warning (suggests task should be split if too many)

### Backward Compatibility
- Reject invalid enrichment fields with error (fail fast) — leverage existing Phase 12 input validation infrastructure
- Default values for missing fields and migration strategy at Claude's discretion — key constraint: existing v1.0/v1.1 tasks must continue working unchanged

### Claude's Discretion
- Branch field design (optional source branch vs always-from-main)
- Verification step structure (typed-only vs typed+freeform, separate success_criteria vs combined)
- Default values for missing enrichment fields (nil vs sensible defaults)
- Migration strategy (runtime handling vs startup backfill)
- Heuristic engine signal design and weighting
- Soft limit threshold for verification step count

</decisions>

<specifics>
## Specific Ideas

- Confidence score on complexity enables the scheduler (Phase 19) to handle edge cases — e.g., low-confidence "trivial" might get standard routing
- The heuristic running alongside explicit tags creates an observability signal for future LLM-based classifier (AROUTE-01 in deferred requirements)
- File reason annotations help agents understand WHY a file matters, not just that it exists

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 17-enriched-task-format*
*Context gathered: 2026-02-12*
