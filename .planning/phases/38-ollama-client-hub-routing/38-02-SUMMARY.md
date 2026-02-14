---
phase: 38-ollama-client-hub-routing
plan: 02
subsystem: llm
tags: [ollama, routing, prompt-engineering, json-parsing, qwen3]

requires:
  - phase: 38-ollama-client-hub-routing
    provides: "OllamaClient.chat/2 HTTP wrapper"
provides:
  - "Config-driven backend routing in ClaudeClient GenServer (:ollama vs :claude_cli)"
  - "Four Ollama-specific JSON prompt templates with /no_think"
  - "JSON response parsing for all 4 prompt types via parse_ollama/2"
affects: [39-pipeline-reliability, 43-hub-fsm-healing]

tech-stack:
  added: []
  patterns: ["Backend routing via config atom in GenServer state", "JSON prompt format for local LLMs", "Dual parsing (XML for Claude, JSON for Ollama)"]

key-files:
  created: []
  modified:
    - lib/agent_com/claude_client.ex
    - lib/agent_com/claude_client/prompt.ex
    - lib/agent_com/claude_client/response.ex

key-decisions:
  - "Ollama prompts use JSON output format instead of XML (more reliable with smaller models)"
  - "Catch-all build/3 delegates to build/2 for :claude_cli backward compatibility"
  - "parse_ollama/2 is separate from parse/3 (different input format, no JSON wrapper)"

patterns-established:
  - "Backend routing: config atom checked once in init, stored in state, dispatched in handle_call"
  - "Ollama prompts: step-by-step instructions + JSON output + /no_think suffix"
  - "JSON extraction: strip thinking -> strip fences -> Jason.decode -> regex fallback"

duration: 4 min
completed: 2026-02-14
---

# Phase 38 Plan 02: Hub FSM LLM Routing Swap and Prompt Adaptation Summary

**Config-driven ClaudeClient backend routing to OllamaClient with 4 JSON prompt templates and dual XML/JSON response parsing**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-14T00:03:00Z
- **Completed:** 2026-02-14T00:07:00Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- ClaudeClient GenServer routes to OllamaClient when config :llm_backend is :ollama
- Four Ollama-specific prompt templates (decompose, verify, identify_improvements, generate_proposals) with JSON output format
- Response module has parse_ollama/2 handling JSON extraction with thinking block stripping, markdown fence removal, and regex fallback
- Zero ClaudeClient.Cli calls in production code paths when :llm_backend is :ollama
- All 841 existing tests pass -- no regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Backend routing and Ollama prompt variants** - `a36695a` (feat)
2. **Task 2: Ollama response parsing** - `5754d55` (feat)

## Files Created/Modified
- `lib/agent_com/claude_client.ex` - Added backend field to state, routing in handle_call, invoke_ollama/2
- `lib/agent_com/claude_client/prompt.ex` - Four :ollama prompt clauses with JSON format and plain text helpers
- `lib/agent_com/claude_client/response.ex` - parse_ollama/2 with extract_json, strip_thinking, normalize_depends_on

## Decisions Made
- Ollama prompts use JSON instead of XML for output format (smaller models are more reliable with JSON)
- Kept existing build/2 functions for :claude_cli backward compatibility via catch-all delegation
- parse_ollama/2 is a separate public function (not delegating to parse/3) because Ollama content is not wrapped in Claude's JSON envelope

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 38 complete: hub can route LLM operations through local Ollama instead of claude -p
- Ready for Phase 39 (Pipeline Reliability) or Phase 43 (Hub FSM Healing) which depends on this routing

---
*Phase: 38-ollama-client-hub-routing*
*Completed: 2026-02-14*
