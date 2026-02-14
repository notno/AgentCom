---
phase: 33-contemplation-and-scalability
plan: 02
subsystem: api
tags: [xml, proposal, prompt-engineering, llm-pipeline, contemplation]

# Dependency graph
requires:
  - phase: 33-01
    provides: "Proposal XML schema, ProposalWriter, ScalabilityAnalyzer, Contemplation orchestrator"
provides:
  - "Enriched Proposal struct with problem, solution, why_now, why_not, dependencies fields"
  - "Enriched generate_proposals prompt requesting all fields"
  - "Response parser extracting all enriched fields including nested lists"
  - "Contemplation context with PROJECT.md out-of-scope reading and scalability summary"
affects: [33-03, hub-fsm, proposal-ranking]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Nested list extraction via Regex.scan in response parser"
    - "PROJECT.md section extraction via regex for out-of-scope context"
    - "ScalabilityAnalyzer.analyze wired into default_context for prompt enrichment"

key-files:
  created: []
  modified:
    - "lib/agent_com/xml/schemas/proposal.ex"
    - "lib/agent_com/claude_client/prompt.ex"
    - "lib/agent_com/claude_client/response.ex"
    - "lib/agent_com/contemplation.ex"

key-decisions:
  - "problem and solution fields optional (LLM may not always produce them)"
  - "XML uses kebab-case (why-now, why-not), Elixir uses snake_case (why_now, why_not)"
  - "Regex.scan for nested dependency/file list extraction (lenient, follows existing response parser pattern)"
  - "read_project_out_of_scope replaces hardcoded out-of-scope string with actual PROJECT.md content"

patterns-established:
  - "Enriched proposal pipeline: prompt requests -> response extracts -> to_proposal_struct maps -> Proposal.new validates"
  - "maybe_add_dependencies helper for Saxy.Builder list serialization (mirrors maybe_add_files)"

# Metrics
duration: 3min
completed: 2026-02-14
---

# Phase 33 Plan 02: Enriched Proposal Schema Summary

**Enriched Proposal schema with problem/solution/why_now/why_not/dependencies fields, updated LLM prompt and response parser, and PROJECT.md out-of-scope context reading**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-14T13:56:48Z
- **Completed:** 2026-02-14T13:59:50Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Proposal struct enriched with 5 new fields (problem, solution, why_now, why_not, dependencies) with full XML round-trip support
- LLM prompt updated to request all enriched fields with updated example and out-of-scope instruction
- Response parser extracts all new fields including nested dependency and related-files lists via Regex.scan
- Contemplation default_context now reads PROJECT.md out-of-scope section dynamically and includes scalability summary

## Task Commits

Each task was committed atomically:

1. **Task 1: Enrich Proposal schema with new fields and update XML serialization** - `23041a6` (feat)
2. **Task 2: Enrich prompt, response parser, and contemplation context** - `0f5fe92` (feat)

## Files Created/Modified
- `lib/agent_com/xml/schemas/proposal.ex` - Added problem, solution, why_now, why_not, dependencies to struct, typespec, from_simple_form, and Saxy.Builder
- `lib/agent_com/claude_client/prompt.ex` - Added scalability-summary/error-summary context, enriched response format instructions and example
- `lib/agent_com/claude_client/response.ex` - Updated parse_proposal_element with all new field extraction including nested lists
- `lib/agent_com/contemplation.ex` - Added read_project_out_of_scope, wired ScalabilityAnalyzer into default_context, enriched to_proposal_struct

## Decisions Made
- problem and solution fields are optional (LLM may not always produce them) -- no new required field validation added
- XML uses kebab-case for multi-word tags (why-now, why-not) while Elixir uses snake_case (why_now, why_not)
- Regex.scan for nested list extraction follows the lenient regex approach already used in the response parser
- Replaced hardcoded out-of-scope string with dynamic PROJECT.md section reading

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Enriched proposal pipeline complete, ready for Plan 33-03 (if applicable)
- All prompt/response/schema changes compile cleanly with --warnings-as-errors

## Self-Check: PASSED

- All 4 modified files verified present on disk
- Commit `23041a6` (Task 1) verified in git log
- Commit `0f5fe92` (Task 2) verified in git log
- `mix compile --warnings-as-errors` passes

---
*Phase: 33-contemplation-and-scalability*
*Completed: 2026-02-14*
