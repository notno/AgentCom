---
phase: 20-sidecar-execution
plan: 03
subsystem: sidecar
tags: [execution-engine, ollama, claude-code, shell-executor, streaming, ndjson, retry-logic, cost-tracking]

# Dependency graph
requires:
  - phase: 20-sidecar-execution
    provides: "calculateCost and ProgressEmitter from Plan 01"
  - phase: 20-sidecar-execution
    provides: "routing_decision in task_assign and execution_event in task_progress from Plan 02"
  - phase: 19-model-aware-scheduler
    provides: "routing_decision with target_type, selected_endpoint, selected_model"
  - phase: 17-task-complexity
    provides: "complexity.effective_tier for fallback inference"
provides:
  - "dispatch function routing tasks to OllamaExecutor, ClaudeExecutor, or ShellExecutor"
  - "OllamaExecutor with streaming NDJSON from /api/chat, retry 1-2x, token collection"
  - "ClaudeExecutor invoking claude -p with stream-json, retry 2-3x with exponential backoff"
  - "ShellExecutor with configurable timeout, streaming stdout/stderr, retry 1x"
  - "executeTask method on HubConnection for Phase 20 direct execution path"
  - "Conditional dispatch in handleTaskAssign: routing_decision present -> executeTask, absent -> wakeAgent"
affects: [20-sidecar-execution, dashboard, sidecar]

# Tech tracking
tech-stack:
  added: []
  patterns: [strategy-pattern-executor-dispatch, lazy-require-for-executors, ndjson-buffer-split-streaming, sigterm-sigkill-timeout-escalation]

key-files:
  created:
    - sidecar/lib/execution/dispatcher.js
    - sidecar/lib/execution/ollama-executor.js
    - sidecar/lib/execution/claude-executor.js
    - sidecar/lib/execution/shell-executor.js
  modified:
    - sidecar/index.js

key-decisions:
  - "Lazy-load executors inside dispatch switch cases to avoid module load ordering issues"
  - "ProgressEmitter onFlush receives event arrays (matching existing API), iterated for individual WS sends"
  - "ShellExecutor treats non-zero exit code as failure (triggers retry)"
  - "ClaudeExecutor uses content_block_delta event type for streaming text deltas"
  - "Dispatcher computes cost after executor returns (single cost calculation point)"

patterns-established:
  - "Executor interface: async execute(task, config, onProgress) -> {status, output, model_used, tokens_in, tokens_out, error}"
  - "Lazy-require inside switch for optional module loading"
  - "NDJSON buffer+split pattern for streaming HTTP responses"
  - "SIGTERM then SIGKILL after 5s grace for process timeout escalation"

# Metrics
duration: 4min
completed: 2026-02-12
---

# Phase 20 Plan 03: Execution Engine Summary

**Three-tier execution engine with Ollama NDJSON streaming, Claude Code CLI invocation, and shell command runner -- all with per-tier retry logic, progress streaming, and cost tracking**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-12T22:35:14Z
- **Completed:** 2026-02-12T22:39:33Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- OllamaExecutor streams NDJSON from /api/chat with buffer+split pattern, collects prompt_eval_count/eval_count tokens, retries 1-2x
- ClaudeExecutor invokes `claude -p --output-format stream-json`, parses content_block_delta events, retries 2-3x with exponential backoff (2s/4s/8s)
- ShellExecutor runs commands via spawn with configurable per-task timeout, SIGTERM->SIGKILL escalation, and streaming stdout/stderr
- Dispatcher routes tasks by routing_decision.target_type with fallback inference from complexity.effective_tier
- index.js conditionally dispatches to executeTask (Phase 20 path) or wakeAgent (legacy path) based on routing_decision presence
- All executors emit progress events via onProgress callback, streamed to hub through ProgressEmitter with 100ms batching

## Task Commits

Each task was committed atomically:

1. **Task 1: Dispatcher, OllamaExecutor, and ShellExecutor** - `61e5849` (feat)
2. **Task 2: ClaudeExecutor and index.js integration** - `01d5496` (feat)

## Files Created/Modified
- `sidecar/lib/execution/dispatcher.js` - Routes tasks to correct executor via target_type, computes cost after execution
- `sidecar/lib/execution/ollama-executor.js` - Streams Ollama /api/chat NDJSON, collects token counts, retries 1-2x
- `sidecar/lib/execution/claude-executor.js` - Invokes Claude Code CLI with stream-json, captures usage stats, retries 2-3x with backoff
- `sidecar/lib/execution/shell-executor.js` - Runs shell commands via spawn with configurable timeout and streaming stdout/stderr
- `sidecar/index.js` - Added routing_decision to task object, executeTask method, conditional dispatch logic

## Decisions Made
- Lazy-load executors inside dispatch switch cases rather than top-level requires -- avoids module load ordering issues when not all executors exist yet
- ProgressEmitter onFlush callback receives event arrays (matching existing Plan 01 API), each event sent as individual WS message
- ShellExecutor treats non-zero exit code as failure, triggering the retry mechanism
- ClaudeExecutor parses content_block_delta events for text streaming (matching Claude Code stream-json output format)
- Dispatcher is the single point for cost calculation -- executors return raw token counts, dispatcher calls calculateCost once

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Changed dispatcher to lazy-load executors**
- **Found during:** Task 1 (Dispatcher creation)
- **Issue:** Dispatcher top-level requires claude-executor.js which does not exist until Task 2, causing MODULE_NOT_FOUND on load
- **Fix:** Changed executor requires from top-level to lazy-loaded inside switch cases
- **Files modified:** sidecar/lib/execution/dispatcher.js
- **Verification:** `node -e "require('./sidecar/lib/execution/dispatcher')"` loads without error
- **Committed in:** 61e5849 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Necessary fix for module load ordering. No scope creep. Lazy loading is actually a better pattern for this use case.

## Issues Encountered

None beyond the auto-fixed deviation above.

## User Setup Required

None - no external service configuration required. Claude Code CLI must be installed on sidecar hosts intended for complex task execution, but this is an existing requirement documented in the error message.

## Next Phase Readiness
- All four execution modules ready: dispatcher, OllamaExecutor, ClaudeExecutor, ShellExecutor
- index.js integration complete with backward-compatible fallback to wakeAgent
- Progress streaming infrastructure in place via ProgressEmitter
- Ready for Plan 04 (dashboard integration for execution streaming display)
- All 16 Plan 01 tests continue passing (no regressions)

## Self-Check: PASSED

- FOUND: sidecar/lib/execution/dispatcher.js
- FOUND: sidecar/lib/execution/ollama-executor.js
- FOUND: sidecar/lib/execution/claude-executor.js
- FOUND: sidecar/lib/execution/shell-executor.js
- FOUND: sidecar/index.js
- FOUND: .planning/phases/20-sidecar-execution/20-03-SUMMARY.md
- FOUND: commit 61e5849
- FOUND: commit 01d5496
- All 16 Plan 01 tests pass (no regressions)
- All 18 verification checks pass

---
*Phase: 20-sidecar-execution*
*Completed: 2026-02-12*
