---
phase: 26-claude-api-client
plan: 02
subsystem: api
tags: [prompt-templates, response-parsing, xml-extraction, json-wrapper, claude-cli]

# Dependency graph
requires:
  - phase: 26-claude-api-client
    plan: 01
    provides: "ClaudeClient GenServer + Cli module with stub Prompt and Response modules"
provides:
  - "Prompt.build/2 with 3 template clauses (:decompose, :verify, :identify_improvements)"
  - "Response.parse/3 with JSON wrapper decoding, XML extraction, and typed map output"
  - "Full integration: Cli.invoke calls Prompt.build then Response.parse (no more stubs)"
affects: [26-03-tests, 27-goal-decomposer, 29-hub-fsm]

# Tech tracking
tech-stack:
  added: []
  patterns: [regex-xml-extraction-with-dotall, dual-key-map-access, markdown-fence-stripping]

key-files:
  created: []
  modified:
    - lib/agent_com/claude_client/prompt.ex
    - lib/agent_com/claude_client/response.ex

key-decisions:
  - "Regex-based XML extraction (not Saxy) for response parsing -- LLM output may not be valid XML; regex is more lenient"
  - "get_field/3 helper supports both atom and string map keys for prompt input flexibility"
  - "XML escaping in prompt templates prevents injection when goal/context data contains < > &"
  - "Fallback plain text parsing when JSON decode fails -- supports --output-format text responses"

patterns-established:
  - "Prompt templates as module functions with heredoc strings -- compile-time checked, testable in isolation"
  - "Response parsing pipeline: exit code -> empty check -> JSON decode -> XML extraction -> typed maps"
  - "Consistent tagged tuple error types: :empty_response, {:exit_code, N}, {:unexpected_format, term}, {:parse_error, string}"

# Metrics
duration: 2min
completed: 2026-02-14
---

# Phase 26 Plan 02: Prompt & Response Modules Summary

**Prompt template builder for 3 LLM use cases with XML-instructed responses, and Response parser handling JSON wrapper + regex XML extraction into typed Elixir maps**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-14T00:10:02Z
- **Completed:** 2026-02-14T00:12:57Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Prompt.build/2 produces structured prompts for :decompose, :verify, and :identify_improvements with XML-wrapped input data and XML response format instructions
- Response.parse/3 handles JSON wrapper from --output-format json, extracts XML blocks with markdown fence stripping, and parses into typed Elixir maps
- All error paths return consistent tagged tuples for caller pattern matching
- Cli.invoke now flows through real Prompt.build and Response.parse (stubs replaced)

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement Prompt template builder** - `4bf8266` (feat)
2. **Task 2: Implement Response parser with JSON wrapper and XML extraction** - `10f2014` (feat)

## Files Created/Modified
- `lib/agent_com/claude_client/prompt.ex` - Prompt template builder with 3 build/2 clauses, XML embedding helpers, and escape functions
- `lib/agent_com/claude_client/response.ex` - Response parser with JSON wrapper decode, regex XML extraction, and per-type element parsing

## Decisions Made
- Regex-based XML extraction instead of Saxy for response parsing -- LLM output is not guaranteed to be well-formed XML (may have preamble text, markdown fences, etc.), so regex extraction is more resilient than strict XML parsing
- Dual atom/string key support in Prompt helpers via get_field/3 -- callers may pass maps with either key type depending on source (JSON decoded = string keys, Elixir structs = atom keys)
- XML escaping in prompt templates -- prevents prompt injection when goal/context data contains XML special characters
- Plain text fallback when JSON decode fails -- allows Response.parse to handle both --output-format json and --output-format text responses

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Prompt and Response modules fully implemented, no more stubs
- ClaudeClient GenServer end-to-end pipeline complete: API call -> Prompt.build -> Cli.invoke -> Response.parse -> typed result
- Ready for Plan 26-03 (test suite) and downstream Phase 27 (GoalDecomposer) integration

## Self-Check: PASSED

- All 3 files verified present on disk
- Commit `4bf8266` verified in git log
- Commit `10f2014` verified in git log
- `mix compile --warnings-as-errors` passes cleanly

---
*Phase: 26-claude-api-client*
*Completed: 2026-02-14*
