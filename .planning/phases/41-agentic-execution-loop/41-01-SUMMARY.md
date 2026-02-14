---
phase: 41-agentic-execution-loop
plan: 01
subsystem: execution
tags: [ollama, react-loop, tool-calling, parser, qwen3]

requires:
  - phase: 40-sidecar-tool-infrastructure
    provides: tool-registry, tool-executor, sandbox
provides:
  - 3-layer tool call output parser (native, JSON, XML)
  - Multi-turn agentic ReAct loop in OllamaExecutor
  - Non-streaming _chatOnce method for tool-calling
affects: [41-02, 41-03]

tech-stack:
  added: []
  patterns: [react-loop, 3-layer-parser, argument-coercion]

key-files:
  created:
    - sidecar/lib/execution/tool-call-parser.js
    - sidecar/test/execution/tool-call-parser.test.js
  modified:
    - sidecar/lib/execution/ollama-executor.js

key-decisions:
  - "3-layer parser priority: native tool_calls > JSON-in-content > XML-in-content"
  - "Argument coercion for Qwen3 string types (booleans, integers)"
  - "Nudge mechanism with max 2 nudges for empty responses"

patterns-established:
  - "ReAct loop pattern: call -> parse -> execute -> feed back -> repeat"
  - "Non-streaming _chatOnce for tool-calling interactions"

duration: 5min
completed: 2026-02-14
---

# Phase 41 Plan 01: ReAct Loop Core Summary

**3-layer tool call parser with argument coercion and multi-turn ReAct loop in OllamaExecutor**

## Performance

- **Duration:** 5 min
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Built parseToolCalls() with 3-layer extraction (native, JSON-in-content, XML-in-content)
- Implemented argument coercion for Qwen3 8B string type quirks
- Added _chatOnce() for non-streaming Ollama calls with 120s timeout
- Built _agenticLoop() with multi-turn ReAct: Ollama call -> parse -> execute tools -> feed results back
- Agentic routing in execute() based on routing_decision.agentic flag
- 33 parser unit tests covering all layers, priority, edge cases

## Task Commits

1. **Task 1: 3-layer tool call output parser** - `8374db1` (feat)
2. **Task 2: ReAct loop in OllamaExecutor** - `1eac25a` (feat)

## Files Created/Modified
- `sidecar/lib/execution/tool-call-parser.js` - 3-layer output parser with argument coercion
- `sidecar/test/execution/tool-call-parser.test.js` - 33 unit tests for parser
- `sidecar/lib/execution/ollama-executor.js` - _chatOnce, _agenticLoop, agentic routing

## Decisions Made
- 3-layer parser priority: native > JSON > XML (if native exists, skip content parsing)
- Argument coercion handles string "true"/"false" -> boolean, string integers for known params
- Nudge mechanism: max 2 user-role nudges for empty/malformed responses before termination

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## Next Phase Readiness
- Ready for Plan 41-02 (safety guardrails) and Plan 41-03 (system prompt, dashboard streaming)
- _agenticLoop provides the foundation both plans extend

---
*Phase: 41-agentic-execution-loop*
*Completed: 2026-02-14*
