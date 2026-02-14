---
phase: 26-claude-api-client
plan: 03
subsystem: testing
tags: [exunit, tdd, prompt-tests, response-tests, genserver-tests, budget-gating]

# Dependency graph
requires:
  - phase: 26-claude-api-client
    plan: 01
    provides: "ClaudeClient GenServer with public API and CostLedger integration"
  - phase: 26-claude-api-client
    plan: 02
    provides: "Prompt.build/2 and Response.parse/3 implementations"
provides:
  - "43-test suite covering Prompt templates, Response parsing, and GenServer budget gating"
  - "Error handling for missing CLI binary (Cli.invoke rescue)"
  - "Defense-in-depth Task.exit handling in ClaudeClient GenServer"
affects: [27-goal-decomposer, 29-hub-fsm]

# Tech tracking
tech-stack:
  added: []
  patterns: [dets-isolated-genserver-tests, canned-json-xml-response-fixtures, async-true-for-stateless-modules]

key-files:
  created:
    - test/agent_com/claude_client_test.exs
    - test/agent_com/claude_client/prompt_test.exs
    - test/agent_com/claude_client/response_test.exs
  modified:
    - lib/agent_com/claude_client.ex
    - lib/agent_com/claude_client/cli.ex

key-decisions:
  - "rescue in Cli.invoke for System.cmd :enoent -- prevents GenServer crash when CLI binary unavailable"
  - "Canned JSON+XML strings as test fixtures -- mimics real --output-format json output without CLI dependency"
  - "async: true for Prompt and Response unit tests, async: false for GenServer integration tests"

patterns-established:
  - "ClaudeClient test pattern: override cli_path to non-existent binary, test budget gating and error paths"
  - "Response test pattern: construct JSON wrapper with XML content, verify parse/3 produces typed maps"

# Metrics
duration: 4min
completed: 2026-02-14
---

# Phase 26 Plan 03: ClaudeClient Test Suite Summary

**43-test TDD suite for Prompt templates, Response parsing (JSON+XML), and GenServer budget gating with CLI error handling fix**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-14T00:14:56Z
- **Completed:** 2026-02-14T00:19:08Z
- **Tasks:** 2 (RED: tests, GREEN: source fixes)
- **Files modified:** 5

## Accomplishments
- 18 Prompt.build/2 tests covering all 3 template types, XML escaping, string/atom key support, and graceful missing-key handling
- 18 Response.parse/3 tests covering all error paths (empty, exit code, bad JSON, missing XML, unknown type) and success paths for all 3 prompt types including markdown fence stripping and plain text fallback
- 7 GenServer integration tests covering budget gating, set_hub_state transitions, invalid state rejection, and CLI error handling
- Discovered and fixed missing error handling in Cli.invoke (System.cmd :enoent crash) and ClaudeClient (unhandled Task.exit)

## Task Commits

Each task was committed atomically:

1. **Task 1: Write comprehensive test suite (RED)** - `9663224` (test)
2. **Task 2: Fix CLI error handling bugs (GREEN)** - `eeb3c66` (fix)

## Files Created/Modified
- `test/agent_com/claude_client/prompt_test.exs` - 18 unit tests for Prompt.build/2 template output
- `test/agent_com/claude_client/response_test.exs` - 18 unit tests for Response.parse/3 with all error/success paths
- `test/agent_com/claude_client_test.exs` - 7 integration tests for GenServer budget gating and CLI errors
- `lib/agent_com/claude_client/cli.ex` - Added rescue clause for System.cmd errors (:enoent, generic exceptions)
- `lib/agent_com/claude_client.ex` - Added {:exit, reason} handler in Task.yield/shutdown case

## Decisions Made
- Rescue in Cli.invoke instead of just relying on Task.async crash handling -- provides cleaner error tuples and proper logging
- Canned JSON+XML strings as fixtures rather than mocking -- tests the real parse pipeline without external dependencies
- async: true for stateless Prompt/Response tests, async: false for GenServer tests sharing global state

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed missing error handling for CLI binary not found**
- **Found during:** Task 1 (test writing -- CLI non-existent binary test)
- **Issue:** Cli.invoke had no rescue clause; System.cmd raises ErlangError(:enoent) when binary missing, crashing the Task and propagating through GenServer.call as an unhandled exit
- **Fix:** Added rescue clauses in Cli.invoke for ErlangError and generic exceptions, wrapping as {:error, {:cli_error, reason}}. Also added {:exit, reason} handler in ClaudeClient.handle_call for defense in depth.
- **Files modified:** lib/agent_com/claude_client/cli.ex, lib/agent_com/claude_client.ex
- **Verification:** All 43 tests pass, including the non-existent binary test
- **Committed in:** eeb3c66

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Essential fix for production reliability -- prevents GenServer crash when Claude CLI is not installed or path is misconfigured.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- ClaudeClient module fully tested: prompt templates, response parsing, GenServer integration, and error handling
- Phase 26 complete -- all 3 plans executed (GenServer, Prompt/Response, Tests)
- Ready for Phase 27 (GoalDecomposer) which will use ClaudeClient.decompose_goal

## Self-Check: PASSED

- All 5 key files verified present on disk
- Commit `9663224` verified in git log
- Commit `eeb3c66` verified in git log
- `mix compile --warnings-as-errors` passes cleanly
- 43 tests pass with 0 failures

---
*Phase: 26-claude-api-client*
*Completed: 2026-02-14*
