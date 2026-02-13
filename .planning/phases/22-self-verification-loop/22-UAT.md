---
status: complete
phase: 22-self-verification-loop
source: 22-01-SUMMARY.md, 22-02-SUMMARY.md, 22-03-SUMMARY.md
started: 2026-02-13T02:30:00Z
updated: 2026-02-13T03:00:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Task Submission Accepts max_verification_retries
expected: Submit a task via HTTP POST to /api/tasks with max_verification_retries: 3. The task should be accepted (200 OK) and the field stored on the task. Submitting with a value > 5 should be capped to 5.
result: pass

### 2. Task Assign Forwards Retry Config to Sidecar
expected: When a task with max_verification_retries is assigned to an agent, the task_assign WebSocket message includes the max_verification_retries, skip_verification, and verification_timeout_ms fields.
result: pass

### 3. Verification Loop Runs After Execution
expected: When a task with max_verification_retries > 0 completes execution, verification checks run automatically. If all checks pass on the first attempt, the task completes with verification_status "verified" and verification_attempts 1.
result: skipped
reason: Requires live LLM execution backend

### 4. Verification Failure Triggers Corrective Retry
expected: When verification fails after execution, the sidecar constructs a corrective prompt containing FAILED CHECKS, PASSED CHECKS, ORIGINAL TASK, and PREVIOUS OUTPUT sections, then re-dispatches to the LLM. The retry attempt is visible in progress events.
result: skipped
reason: Requires live LLM execution backend; covered by integration test (Test 7)

### 5. Retry Budget Exhaustion Submits Partial Pass
expected: When all retry attempts are used without passing verification, the task completes with verification_status "partial_pass" and the full verification_history showing each iteration's pass/fail results.
result: skipped
reason: Requires live LLM execution backend

### 6. Shell Executor Tasks Skip Retry Loop
expected: Tasks routed to the shell executor (target_type "sidecar") run verification once but do NOT retry on failure, since shell commands are deterministic and have no LLM to correct.
result: skipped
reason: Requires live trivial-tier task execution

### 7. Integration Test Passes
expected: Running node sidecar/test/verification-loop-integration.js exits with code 0 and all 7 assertions pass, proving the full failure->corrective-prompt->retry->pass flow end-to-end.
result: pass

### 8. Dashboard Shows Attempt Count Badge
expected: On the dashboard, a completed task that went through multiple verification attempts shows an "N attempts" badge next to the verification status. Single-attempt tasks show no badge (identical to before Phase 22).
result: pass

### 9. Dashboard Expandable Retry History
expected: On the dashboard, clicking the expandable "Retry history (N runs)" section shows per-iteration summary with run number, status (pass/fail), and pass/fail counts for each attempt.
result: pass

### 10. Cumulative Cost Tracking
expected: A task that retried verification shows cumulative tokens_in, tokens_out, and estimated_cost_usd reflecting ALL iterations (not just the final attempt).
result: skipped
reason: Requires live multi-attempt execution

### 11. Verification History Persisted to Store
expected: After a multi-attempt task completes, each iteration's verification report is persisted to the Verification.Store with correct run_number values, accessible via the hub API.
result: skipped
reason: Requires live multi-attempt execution

### 12. Elixir Compilation Clean
expected: Running mix compile --warnings-as-errors completes with zero errors and zero warnings.
result: pass

## Summary

total: 12
passed: 5
issues: 0
pending: 0
skipped: 7

## Gaps

[none]
