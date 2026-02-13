# Phase 22: Self-Verification Loop - Research

**Researched:** 2026-02-12
**Domain:** Build-verify-fix feedback loop for agent task execution with configurable retry budgets
**Confidence:** HIGH

## Summary

Phase 22 implements the self-verification loop (VERIFY-03): when verification fails after task completion, the sidecar feeds failure details back to the LLM and retries the fix, looping until checks pass or a retry budget is exhausted. This is the final piece of the "smart agent" pipeline -- Phases 20 (execution) and 21 (verification) provide the infrastructure; Phase 22 closes the feedback loop.

The implementation surface is entirely sidecar-side (Node.js). The sidecar already has: (1) an execution engine with three executors (`OllamaExecutor`, `ClaudeExecutor`, `ShellExecutor`) via `dispatcher.js`, (2) a verification runner (`verification.js`) that produces structured reports with per-check pass/fail + output, and (3) a WebSocket connection for streaming progress events. The self-verification loop wraps the execute-verify sequence in a bounded retry loop, feeding verification failure details into the LLM prompt for corrective action.

The hub-side changes are minimal: accepting a `max_verification_retries` field on task submission, passing it through `task_assign`, and displaying per-iteration verification history in the dashboard. The verification report structure already supports `run_number` (designed in Phase 21 for exactly this purpose), and `Verification.Store` already keys reports by `{task_id, run_number}` to support multi-run history.

**Primary recommendation:** Implement a `VerificationLoop` module in the sidecar that wraps `dispatch()` + `runVerification()` in a bounded loop. On verification failure, construct a corrective prompt containing the original task, the LLM's previous output, and the structured failure details (which checks failed, stdout/stderr output). Re-invoke the same executor with this corrective prompt. Each iteration produces a verification report with incrementing `run_number`. Stream retry progress events to the dashboard. Terminate when all checks pass or `max_verification_retries` is exhausted, submitting the final (possibly partial) report.

## Standard Stack

### Core (already in project, no new deps)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Node.js `child_process.spawn` | built-in | Re-invoke LLM executors (Claude CLI, shell) for corrective retries | Already used by ClaudeExecutor and ShellExecutor |
| Node.js `http` | built-in | Re-invoke Ollama for corrective retries | Already used by OllamaExecutor |
| `ws` | ^8.19.0 | Stream retry progress events to hub | Already a dependency |
| `sidecar/verification.js` | project code | Run verification checks after each execution attempt | Phase 21 implementation, fully functional |
| `sidecar/lib/execution/dispatcher.js` | project code | Dispatch to correct executor based on routing decision | Phase 20 implementation |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `sidecar/lib/execution/progress-emitter.js` | project code | Batch progress events for WebSocket | Stream retry iteration events |
| `sidecar/lib/execution/cost-calculator.js` | project code | Track cumulative cost across retries | Sum costs from all iterations |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Re-invoking the same executor | Spawning a new Claude Code session per retry | Same executor reuse is simpler and maintains the existing dispatch pattern; new session per retry would add overhead but avoid state contamination -- however, each `claude -p` invocation is already stateless |
| Feeding full verification output to LLM | Feeding only failed check summaries | Full output gives the LLM maximum context for fix decisions; summary-only would save tokens but risks missing diagnostic information in stdout/stderr |
| Sidecar-only retry loop | Hub-orchestrated retry (hub sends new task_assign per retry) | Sidecar-only keeps retry latency low (no round-trip to hub), keeps retry logic co-located with execution, and avoids complex hub-side state management. Hub-orchestrated would give the hub visibility but adds significant complexity for minimal benefit since the sidecar already streams progress events |

**Installation:** No new npm packages needed. All capabilities come from existing project code and Node.js built-ins.

## Architecture Patterns

### Recommended Module Structure
```
sidecar/
  lib/
    execution/
      verification-loop.js   # NEW: Bounded execute-verify-fix loop
      dispatcher.js           # Existing: routes to correct executor
      claude-executor.js      # Existing: invoke Claude CLI
      ollama-executor.js      # Existing: call Ollama HTTP
      shell-executor.js       # Existing: run shell commands
      cost-calculator.js      # Existing: compute costs
      progress-emitter.js     # Existing: batch WS events
  verification.js             # Existing: run verification checks
  index.js                    # Modified: call verification-loop instead of direct dispatch
```

### Pattern 1: Bounded Execute-Verify-Fix Loop
**What:** A new `VerificationLoop` module that wraps `dispatch()` + `runVerification()` in a bounded retry loop. Each iteration: execute task -> run verification -> if failed and retries remain, construct corrective prompt -> repeat.
**When to use:** For all tasks that have `verification_steps` and a non-zero `max_verification_retries` value. Tasks with `skip_verification: true` or empty `verification_steps` bypass the loop entirely (single execution, no verification).
**Why:** This is the core of Phase 22 -- the build-verify-fix pattern.

```javascript
// sidecar/lib/execution/verification-loop.js
'use strict';

const { dispatch } = require('./dispatcher');
const { runVerification } = require('../../verification');
const { log } = require('../log');

/**
 * Execute a task with a bounded verify-fix loop.
 *
 * Flow per iteration:
 *   1. dispatch(task) -> executionResult
 *   2. runVerification(task) -> verificationReport
 *   3. If report.status === 'pass' or 'skip' or 'auto_pass' -> done
 *   4. If retries remain -> build corrective prompt -> goto 1
 *   5. If budget exhausted -> done with partial report
 *
 * @param {object} task - Task from task_assign
 * @param {object} config - Sidecar config
 * @param {function} onProgress - Progress event callback
 * @returns {Promise<VerificationLoopResult>}
 */
async function executeWithVerification(task, config, onProgress) {
  const maxRetries = task.max_verification_retries || 0;
  const reports = [];
  let lastExecResult = null;
  let cumulativeCost = { tokens_in: 0, tokens_out: 0, cost_usd: 0 };

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const isRetry = attempt > 0;

    if (isRetry) {
      // Build corrective prompt from previous failure
      const lastReport = reports[reports.length - 1];
      task = buildCorrectiveTask(task, lastExecResult, lastReport, attempt);

      onProgress({
        type: 'status',
        message: `Verification retry ${attempt}/${maxRetries}: fixing ${countFailures(lastReport)} failed checks...`
      });
    }

    // Step 1: Execute
    const execResult = await dispatch(task, config, onProgress);
    lastExecResult = execResult;
    accumulateCost(cumulativeCost, execResult);

    // Step 2: Verify (only if execution succeeded)
    if (execResult.status === 'success') {
      const report = await runVerification(task, config);
      report.run_number = attempt + 1;
      reports.push(report);

      // Step 3: Check result
      if (report.status === 'pass' || report.status === 'skip' || report.status === 'auto_pass') {
        return buildLoopResult(execResult, reports, cumulativeCost, 'verified');
      }

      // Step 4: If this was the last attempt, submit with partial report
      if (attempt === maxRetries) {
        return buildLoopResult(execResult, reports, cumulativeCost, 'partial_pass');
      }
      // Otherwise, loop continues with corrective prompt
    } else {
      // Execution itself failed -- no point verifying
      return buildLoopResult(execResult, reports, cumulativeCost, 'execution_failed');
    }
  }
}
```

### Pattern 2: Corrective Prompt Construction
**What:** When verification fails, construct a new prompt that includes: (a) the original task description, (b) what the LLM produced, (c) which verification checks failed with their stdout/stderr output, and (d) an instruction to fix the specific failures.
**When to use:** Before each retry iteration.
**Why:** The LLM needs failure context to make targeted corrections rather than starting from scratch. Industry research (Anthropic, Gantz AI) shows that "the best form of feedback is providing clearly defined rules for an output, then explaining which rules failed and why."

```javascript
/**
 * Build a corrective task by augmenting the original description
 * with failure details from the verification report.
 */
function buildCorrectiveTask(originalTask, execResult, lastReport, attempt) {
  const failedChecks = lastReport.checks.filter(c => c.status !== 'pass');

  const failureContext = failedChecks.map(check => {
    return `- ${check.type} (${check.target}): ${check.status.toUpperCase()}\n  Output: ${truncate(check.output, 500)}`;
  }).join('\n');

  const correctivePrompt = [
    `VERIFICATION RETRY ${attempt}: Your previous work failed verification checks.`,
    '',
    'FAILED CHECKS:',
    failureContext,
    '',
    'ORIGINAL TASK:',
    originalTask.description,
    '',
    'YOUR PREVIOUS OUTPUT:',
    truncate(execResult.output, 1000),
    '',
    'Fix the failing verification checks. Focus on the specific failures above.',
    'Do not re-implement working parts -- only fix what is broken.'
  ].join('\n');

  return {
    ...originalTask,
    description: correctivePrompt,
    _original_description: originalTask._original_description || originalTask.description,
    _verification_attempt: attempt
  };
}
```

### Pattern 3: Cumulative Verification Reports
**What:** Each retry iteration produces a verification report with incrementing `run_number`. All reports are collected and the final submission includes the complete history.
**When to use:** For every verification loop execution.
**Why:** Success Criterion 3 requires "each verification retry iteration is visible in the task result (attempt count, which checks passed/failed per iteration)." The Phase 21 Verification.Store already keys by `{task_id, run_number}`.

```javascript
// Final submission includes all iteration reports
function buildLoopResult(execResult, reports, cumulativeCost, status) {
  const latestReport = reports[reports.length - 1] || null;

  return {
    ...execResult,
    // Override cost with cumulative totals
    tokens_in: cumulativeCost.tokens_in,
    tokens_out: cumulativeCost.tokens_out,
    estimated_cost_usd: cumulativeCost.cost_usd,
    // Verification data
    verification_report: latestReport,
    verification_history: reports,       // All iteration reports
    verification_status: status,         // 'verified' | 'partial_pass' | 'execution_failed'
    verification_attempts: reports.length,
    max_verification_retries: reports.length - 1
  };
}
```

### Pattern 4: Streaming Retry Progress Events
**What:** Each retry iteration streams progress events through the existing WebSocket `task_progress` channel with new event types: `verification_retry_start`, `verification_check_result`, `verification_retry_complete`.
**When to use:** During every retry iteration.
**Why:** Success Criterion 3 requires iteration visibility. The dashboard can display real-time retry progress without polling.

```javascript
// New execution_event types for verification loop:
{
  event_type: 'verification_retry_start',
  text: 'Verification retry 1/3: fixing 2 failed checks...',
  attempt: 1,
  max_retries: 3
}

{
  event_type: 'verification_check_result',
  text: 'test_passes: FAIL - 1 test, 1 failure',
  check_type: 'test_passes',
  check_status: 'fail',
  attempt: 1
}

{
  event_type: 'verification_retry_complete',
  text: 'Retry 1/3 complete: 2 passed, 1 failed',
  attempt: 1,
  passed: 2,
  failed: 1,
  status: 'fail'
}
```

### Pattern 5: Executor-Specific Corrective Re-Invocation
**What:** Each executor type needs a slightly different approach for corrective retries. Claude and Ollama LLM executors can accept a corrective prompt. ShellExecutor cannot self-correct (no LLM to feed back to).
**When to use:** Determining which executors support the retry loop.

| Executor | Supports Retry Loop | Corrective Mechanism | Notes |
|----------|-------------------|---------------------|-------|
| `ClaudeExecutor` | Yes | New `claude -p` invocation with corrective prompt | Each invocation is stateless; corrective prompt includes failure context |
| `OllamaExecutor` | Yes | New `/api/chat` call with corrective messages | Add failure context as follow-up user message in chat history |
| `ShellExecutor` | No | N/A | Shell commands are deterministic -- re-running the same command will produce the same result. Skip retry loop for trivial-tier tasks |

### Anti-Patterns to Avoid
- **Retrying shell tasks:** ShellExecutor runs deterministic commands. If `npm test` fails, re-running the same command will fail again. Only LLM-backed executors (Claude, Ollama) can meaningfully self-correct. The verification loop should skip retries for `sidecar` target_type.
- **Starting from scratch each retry:** The corrective prompt should reference what failed, not re-state the entire problem. "Fix the test failure in line 42" is better than "Implement feature X from scratch."
- **Retrying on execution failure:** If the executor itself fails (API error, CLI crash), that is not a verification failure. The existing executor retry logic (Phase 20) handles infrastructure failures. The verification loop only triggers on successful execution + failed verification.
- **Feeding the entire verification report to the LLM:** Reports can be very large (full test suite output). Truncate check outputs to a reasonable size (500-1000 chars) to avoid context exhaustion.
- **Losing the original task description:** Each corrective prompt must preserve the original task description. Without it, the LLM loses context about what it was supposed to build, leading to drift.
- **Infinite token accumulation:** Track cumulative tokens across all retry iterations. The total cost should be visible on the task result.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Verification execution | Custom check runner for retry loop | `runVerification()` from `verification.js` | Already handles all 4 check types, global timeout, structured report |
| Task execution | Custom LLM invocation for retries | `dispatch()` from `dispatcher.js` | Already handles all 3 executor types with retry logic, cost calculation |
| Progress event streaming | Custom WebSocket handling for retry events | `ProgressEmitter` from `progress-emitter.js` | Already batches events at 100ms intervals |
| Report persistence | Custom storage for retry history | `Verification.Store` with `{task_id, run_number}` key | Already designed for multi-run history (Phase 21) |
| Cost calculation | Manual token/cost tracking | `cost-calculator.js` | Already computes cost from model + token counts |

**Key insight:** Phase 22 is a composition problem. The execution engine (Phase 20) and verification engine (Phase 21) are fully implemented. Phase 22 wraps them in a bounded loop and adds the corrective prompt construction. No new infrastructure is needed.

## Common Pitfalls

### Pitfall 1: Context Window Exhaustion on Retries
**What goes wrong:** Each retry appends more context (failure details, previous output) to the prompt. After 2-3 retries, the prompt exceeds the model's context window, causing truncation or API errors.
**Why it happens:** Corrective prompts accumulate: original task + attempt 1 output + attempt 1 failures + attempt 2 output + attempt 2 failures...
**How to avoid:** Only include the LATEST failure in the corrective prompt, not the full history. Include the original task description and the most recent attempt's failures. Truncate long outputs (test stderr, etc.) to 500-1000 characters. The verification history is tracked externally in the report, not in the prompt.
**Warning signs:** Token count growing linearly with attempt number. API errors on retry 3+.

### Pitfall 2: Oscillating Fixes (Fix A Breaks B, Fix B Breaks A)
**What goes wrong:** The LLM fixes check A but introduces a regression in check B. Next retry fixes B but breaks A. The loop oscillates without making progress.
**Why it happens:** The LLM makes localized fixes without understanding global impact. Each corrective prompt only shows what failed, not what was passing.
**How to avoid:** Include BOTH failed and passed checks in the corrective prompt. Show "These checks PASSED (keep them passing): ..." and "These checks FAILED (fix these): ...". This gives the LLM the full picture. Also: the run-all-checks strategy from Phase 21 (no fail-fast) means the LLM always sees the complete verification state.
**Warning signs:** Check pass/fail status alternating between iterations.

### Pitfall 3: Retry Loop for ShellExecutor (Deterministic Commands)
**What goes wrong:** A trivial task runs a shell command, verification fails, and the retry loop re-runs the same shell command. It fails identically because shell commands are deterministic.
**Why it happens:** The verification loop treats all executor types uniformly.
**How to avoid:** Skip the verification retry loop for `sidecar` target_type. ShellExecutor tasks are deterministic -- no LLM to feed corrections to. Report the verification failure immediately without retries.
**Warning signs:** Identical verification failures across all retry iterations for trivial tasks.

### Pitfall 4: Cumulative Cost Explosion
**What goes wrong:** Each retry invokes the LLM again, potentially with a larger prompt (corrective context). With max 3 retries, a complex Claude task could cost 4x the original execution.
**Why it happens:** LLM invocations are the expensive part. Each retry is another full execution.
**How to avoid:** (1) Track cumulative cost across iterations and include it in the final result. (2) Consider whether to use the `effort` parameter (for Claude models that support it) on retries to reduce cost. (3) The configurable `max_verification_retries` lets submitters control the budget. (4) Default to a low retry count (2-3) to keep costs bounded. (5) Stream cost updates per iteration so the dashboard shows running totals.
**Warning signs:** Task cost being 3-4x the expected single-execution cost.

### Pitfall 5: Race Between Verification Timeout and Retry Budget
**What goes wrong:** Verification has a global timeout (120s default). If the first verification run takes 100s, subsequent retries' verifications have very little timeout budget left.
**Why it happens:** The global `verification_timeout_ms` applies per verification run, not across all retries. But if verification consistently takes a long time, the total elapsed time for the retry loop can be very large.
**How to avoid:** Each verification run gets its own fresh timeout budget (the `verification_timeout_ms` from the task). The retry loop itself does not have a separate timeout -- it is bounded by `max_verification_retries` count, not time. Document this clearly: retry budget is measured in attempts, not seconds.
**Warning signs:** Very long total task execution times when max retries are hit.

### Pitfall 6: Legacy Path (handleResult) Does Not Support Self-Verification
**What goes wrong:** The file-based `handleResult` path (legacy wake-agent flow) runs verification once but cannot do the retry loop because it does not re-invoke the agent.
**Why it happens:** `handleResult` reads a result file written by an external agent. The sidecar cannot "re-ask" the external agent to fix failures.
**How to avoid:** The self-verification loop ONLY applies to the Phase 20 `executeTask` path where the sidecar directly controls execution. The legacy `handleResult` path continues to run verification once (as implemented in Phase 21) but does not retry. Document this limitation clearly.
**Warning signs:** Confusion about why some tasks get retries and others do not.

## Code Examples

### Integration Point: index.js executeTask Modification

The current `executeTask` method in `index.js` (lines 633-679) calls `dispatch()` directly and sends the result. Phase 22 replaces this with a call to the verification loop:

```javascript
// BEFORE (Phase 20):
async executeTask(task) {
  const { dispatch } = require('./lib/execution/dispatcher');
  // ... setup ...
  const result = await dispatch(task, _config, (event) => emitter.emit(event));
  // ... send result ...
}

// AFTER (Phase 22):
async executeTask(task) {
  const { executeWithVerification } = require('./lib/execution/verification-loop');
  // ... setup ...
  const result = await executeWithVerification(task, _config, (event) => emitter.emit(event));
  // ... send result (now includes verification_report and verification_history) ...
}
```

### Corrective Prompt Structure for Claude/Ollama

```javascript
// For ClaudeExecutor (single prompt string):
const correctivePrompt = `
VERIFICATION RETRY ${attempt}/${maxRetries}: Your previous work failed verification checks.

FAILED CHECKS:
- test_passes (mix test): FAIL
  Output: ** (MatchError) no match of right-hand side value: {:error, :not_found}
    test/agent_com/new_feature_test.exs:15: (test)
    1 test, 1 failure

PASSED CHECKS (keep these passing):
- file_exists (lib/agent_com/new_feature.ex): PASS
- git_clean (.): PASS

ORIGINAL TASK:
${originalDescription}

Fix the failing verification checks. Focus specifically on the test failure above.
Do not modify code that makes the passing checks work.
`;

// For OllamaExecutor (chat messages array):
const messages = [
  { role: 'system', content: '...' },  // Original system prompt
  { role: 'user', content: originalDescription },
  { role: 'assistant', content: previousOutput },
  { role: 'user', content: `Verification failed. Fix these issues:\n${failureContext}` }
];
```

### Hub-Side Schema Extension

```elixir
# In validation/schemas.ex - add to submit schema optional fields:
"max_verification_retries" => :integer

# In task_queue.ex - add to task struct initialization:
max_verification_retries:
  Map.get(params, :max_verification_retries,
    Map.get(params, "max_verification_retries", 0)),

# In socket.ex - pass through in task_assign message:
# (already passes all task fields)
```

### Hub-Side Verification History Persistence

```elixir
# In task_queue.ex complete_task handler:
# Currently persists single verification_report.
# Phase 22 adds verification_history (list of reports).

verification_history = Map.get(result_params, :verification_history,
  Map.get(result_params, "verification_history", []))

# Persist each report in history to Verification.Store
for report <- verification_history do
  AgentCom.Verification.Store.save(task_id, report)
end
```

### Dashboard Verification History Display

```elixir
# Extend existing renderVerifyBadge to show attempt count
# When verification_attempts > 1, show "2/3 attempts" badge
# Expand to show per-attempt check results
```

## Integration Points

### Where the Verification Loop Fits in the Pipeline

```
Task Assigned to Sidecar
    |
    v
Phase 20: executeTask()
    |
    v
[Phase 22: VerificationLoop]  -- THIS PHASE
    |
    +---> dispatch() (Phase 20 executor)
    |         |
    |         v
    +---> runVerification() (Phase 21)
    |         |
    |         v
    +---> Pass? --> Done (submit verified result)
    |         |
    |         v (fail)
    +---> Retries left? --> Build corrective prompt --> Loop back to dispatch()
    |         |
    |         v (no retries left)
    +---> Submit with partial-pass report
    |
    v
sendTaskComplete (with verification_report + history)
    |
    v
Hub: TaskQueue.complete_task -> Store.save (per-iteration reports)
    |
    v
Dashboard: show iteration history
```

### Key Integration Points

| Integration | What Changes | How |
|-------------|-------------|-----|
| `index.js` `executeTask()` | Call `executeWithVerification` instead of `dispatch` | Replace direct dispatch call with verification loop |
| `index.js` `handleResult()` | No change | Legacy path runs verification once, no retry loop |
| `index.js` `sendTaskComplete()` | Pass through `verification_history` array | Already extracts `verification_report` as top-level field; add `verification_history` |
| Task submit schema | Add optional `max_verification_retries` integer field | Validation schema, task struct init, task_assign passthrough |
| `socket.ex` task_assign | Pass `max_verification_retries` to sidecar | Already passes all task fields in msg |
| `task_queue.ex` complete_task | Persist verification_history reports to Store | Loop over history array, call Store.save for each |
| `dashboard.ex` | Show attempt count and per-iteration results | Extend renderVerifyBadge with iteration display |
| `DashboardSocket` | Handle new progress event types for retry | Already handles all execution_event types |
| `Verification.Store` | No change needed | Already supports `{task_id, run_number}` keys |
| `verification.js` | Add run_number parameter to runVerification | Caller passes iteration number; currently hardcoded to 1 |

## Discretion Recommendations

### 1. Default max_verification_retries: 0 (opt-in)
**Recommendation:** Default to 0 retries (no self-verification loop). Task submitters opt in by specifying `max_verification_retries: 2` or `3`.
**Rationale:** Backward compatibility -- existing tasks should not suddenly start retrying. The cost implications of automatic retries (2-4x execution cost) mean this should be an explicit choice. A default of 0 means Phase 22 is zero-impact on existing tasks.

### 2. Recommended max_verification_retries cap: 5
**Recommendation:** Allow up to 5 retries but recommend 2-3 in documentation.
**Rationale:** Industry research (Anthropic, Gantz AI) shows diminishing returns after 3 attempts. If the LLM cannot fix the issue in 3 tries, a 4th try is unlikely to help. The cap of 5 provides headroom for edge cases while preventing runaway costs. A hard cap prevents configuration mistakes (e.g., `max_verification_retries: 100`).

### 3. Skip verification loop for ShellExecutor
**Recommendation:** When `target_type === 'sidecar'`, skip the verification retry loop entirely. Run verification once (as today), report results, no retries.
**Rationale:** Shell commands are deterministic. Re-running the same command after a verification failure will produce identical results because there is no LLM to make corrective changes. Retrying would waste time without progress.

### 4. Corrective prompt includes both passed and failed checks
**Recommendation:** Include both categories in the corrective prompt: "PASSED (keep passing): ..." and "FAILED (fix these): ..."
**Rationale:** Prevents oscillating fixes (Pitfall 2). The LLM needs to know what is working so it does not regress working checks while fixing broken ones.

### 5. Truncate check output to 500 characters in corrective prompt
**Recommendation:** Truncate each check's stdout/stderr to 500 characters in the corrective prompt. Full output is preserved in the verification report for human review.
**Rationale:** Prevents context window exhaustion (Pitfall 1). Test suite output can be very large (full stack traces, compilation errors). 500 characters captures the essential error message without overwhelming the prompt.

### 6. Cumulative cost tracking across iterations
**Recommendation:** Track and sum `tokens_in`, `tokens_out`, and `estimated_cost_usd` across all iterations. Report the cumulative total in the final task result.
**Rationale:** Users need to understand the true cost of a self-verifying task. A task that took 3 retries cost 4x a single execution.

### 7. One fresh verification timeout per iteration (not shared across retries)
**Recommendation:** Each call to `runVerification()` gets the full `verification_timeout_ms` budget. The retry loop is bounded by attempt count, not cumulative time.
**Rationale:** Sharing a single timeout across retries would create unpredictable behavior where early verifications eat into later iterations' budgets. Attempt-based bounding is simpler to reason about and configure.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single-shot execution with manual review | Build-verify-fix loops with programmatic verification | 2024-2025 | Dramatically higher first-time success rates for agentic coding |
| LLM self-assessment ("did I do it right?") | External mechanical verification (tests, linting, file checks) | 2025 | Eliminates the LLM's tendency to falsely claim success; objective pass/fail |
| Unbounded retry loops | Configurable iteration caps with partial result reporting | 2025-2026 | Prevents cost explosion and infinite loops while maximizing fix success |
| Full context accumulation per retry | Selective failure feedback (latest failure only) | 2025-2026 | Prevents context window exhaustion; keeps corrective prompts focused |

**Deprecated/outdated:**
- LLM self-evaluation as verification: LLMs are unreliable judges of their own work. Mechanical checks (compile, test, lint) are objective and deterministic. Industry has moved firmly toward external verification.
- Unbounded retry loops: Early agent frameworks (e.g., AutoGPT) used unbounded loops that could run indefinitely. Current best practice is configurable caps with graceful degradation.

## Open Questions

1. **Should Ollama corrective prompts use chat history or single prompt?**
   - What we know: OllamaExecutor sends a `messages` array to `/api/chat`. For retries, we could append failure context as a new user message (preserving conversation history) or construct a fresh single prompt (like Claude).
   - What's unclear: Whether Ollama models respond better to conversational correction ("You made an error, fix it") or fresh prompts with failure context. The answer may vary by model.
   - Recommendation: Use the chat history approach (append to messages array). This is natural for the `/api/chat` endpoint and preserves the model's understanding of the task without re-explaining everything. The corrective message becomes: "Verification failed. Fix these issues: [failures]."

2. **How does the verification loop interact with the existing executor retry logic?**
   - What we know: Each executor already has its own retry mechanism (OllamaExecutor: 2 retries, ClaudeExecutor: 3 retries with backoff, ShellExecutor: 1 retry). These handle infrastructure failures (API errors, timeouts).
   - What's unclear: If an executor retry fires during a verification retry, does that count toward the verification retry budget?
   - Recommendation: No. Executor retries and verification retries operate at different levels. Executor retries handle transient infrastructure failures. Verification retries handle code quality failures. They are orthogonal. A task with `max_verification_retries: 3` and a Claude executor with 3 retries could theoretically make 16 LLM calls (4 verification attempts x up to 4 executor attempts each). This is acceptable because executor retries are rare (only on API errors) and the verification retry cap bounds the total.

3. **Should the hub display verification_history or just the latest report?**
   - What we know: The dashboard currently shows a single verification report per task (renderVerifyBadge). Phase 22 produces multiple reports.
   - What's unclear: Whether to display the full iteration history (expandable) or just a summary ("Passed on attempt 3/3, 2 previous failures").
   - Recommendation: Show the latest report as the primary display (like today), plus an "X attempts" badge. Expand to show per-iteration summary on click. The full report details for each iteration are available in the API response for debugging.

4. **Should `max_verification_retries` have a global default configurable on the hub?**
   - What we know: Currently, it defaults to 0 (per-task opt-in).
   - What's unclear: Whether ops teams want a hub-wide default so all tasks get self-verification without submitter changes.
   - Recommendation: Start with per-task only (default 0). A hub-wide default can be added later as a configuration option if needed. This keeps Phase 22 simple and avoids surprise cost increases.

## Sources

### Primary (HIGH confidence)
- **Codebase analysis** - Direct reading of: `sidecar/index.js` (lines 209-286: handleResult, lines 633-679: executeTask), `sidecar/verification.js` (full file: check types, runVerification), `sidecar/lib/execution/dispatcher.js` (dispatch function, executor dispatch), `sidecar/lib/execution/claude-executor.js` (Claude CLI invocation, retry logic), `sidecar/lib/execution/ollama-executor.js` (Ollama streaming, retry logic), `sidecar/lib/execution/shell-executor.js` (shell execution, retry), `lib/agent_com/verification/store.ex` (DETS persistence, {task_id, run_number} keys), `lib/agent_com/verification/report.ex` (report structure), `lib/agent_com/task_queue.ex` (complete_task handler, verification_report storage), `lib/agent_com/socket.ex` (task_complete message handling), `lib/agent_com/validation/schemas.ex` (submit schema)
- **Phase 21 VERIFICATION.md** - Confirmed all verification infrastructure is in place and tested (5/5 truths verified, 393 tests passing)
- **Phase 21 RESEARCH.md** - Verification architecture decisions: run-all-checks, report structure, Store design
- **Phase 20 RESEARCH.md** - Execution engine architecture: dispatcher pattern, executor interface, progress streaming

### Secondary (MEDIUM confidence)
- [Anthropic: Building Agents with the Claude Agent SDK](https://claude.com/blog/building-agents-with-the-claude-agent-sdk) - Core feedback loop pattern: gather context -> take action -> verify work -> repeat. Rules-based feedback is most effective form.
- [Anthropic: Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) - Proactive verification over reactive retries. Git commits enable reverting bad changes.
- [Gantz AI: Why Agents Get Stuck in Loops](https://gantz.ai/blog/post/agent-loops/) - Five causes of agent loops (no failure memory, limited strategies, unclear success criteria, oscillating states, repeated tool errors). Prevention: failure memory, force diversity, hard iteration limits, partial result handling.
- **FEATURES.md Self-Verification Loop section** - Original design sketch: max 3 attempts, 120s timeout, submit partial on exhaustion

### Tertiary (LOW confidence)
- Optimal retry count (2-3 recommended) - Based on industry patterns and Anthropic guidance, not empirical data from this specific system. Should be validated with production telemetry.
- Chat history vs fresh prompt for Ollama corrections - Based on general LLM interaction patterns, not tested with specific Ollama models.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- no new dependencies; all capabilities exist in project code
- Architecture: HIGH -- verification loop is a straightforward composition of existing dispatch() + runVerification() in a bounded loop. Integration points are clear and minimal.
- Pitfalls: HIGH -- identified from direct codebase analysis (ShellExecutor determinism, context exhaustion, oscillating fixes, cumulative cost) and industry research (Anthropic, Gantz AI)
- Corrective prompt design: MEDIUM -- based on Anthropic guidance ("clearly defined rules + which rules failed and why") and industry patterns, but optimal prompt structure for this specific system needs empirical validation

**Research date:** 2026-02-12
**Valid until:** 2026-03-12 (stable domain; no external dependency version concerns)
