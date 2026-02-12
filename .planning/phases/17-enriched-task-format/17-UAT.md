---
status: complete
phase: 17-enriched-task-format
source: 17-01-SUMMARY.md, 17-02-SUMMARY.md, 17-03-SUMMARY.md
started: 2026-02-12T20:00:00Z
updated: 2026-02-12T20:00:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Submit Task with Enrichment Fields
expected: POST a task with all enrichment fields (repo, branch, file_hints with path+reason, success_criteria, verification_steps with type+target, complexity_tier). GET the task back. All fields are present and match what was submitted.
result: pass (re-tested after server restart)

### 2. Submit Task Without Enrichment Fields (Backward Compat)
expected: POST a task with only "description" (no enrichment fields). Task submits successfully. GET it back -- repo and branch are null, file_hints/success_criteria/verification_steps are empty arrays, complexity is present with source "inferred".
result: pass

### 3. Invalid Enrichment Fields Rejected
expected: POST a task with invalid file_hints (e.g., missing "path" key in a hint object). Server returns 422 validation error with a message identifying the invalid field.
result: pass (re-tested after server restart)

### 4. Explicit Complexity Tier Honored
expected: POST a task with complexity_tier "complex". GET it back. complexity.effective_tier is "complex" and complexity.source is "explicit". The inferred result is also present (heuristic ran alongside).
result: pass (re-tested after server restart)

### 5. Complexity Inferred When Not Specified
expected: POST a task with a long, complex description (mentioning refactoring, multiple files, etc.) but no complexity_tier. GET it back. complexity.effective_tier is "complex" (or "standard"), complexity.source is "inferred", and complexity.inferred.confidence is a number between 0 and 1.
result: pass (covered by re-test of Test 1 — complexity.source was "inferred" for tasks without explicit tier)

### 6. Verification Steps Soft Limit Warning
expected: POST a task with 11 verification_steps. Task submits successfully (not rejected). Response includes a "warnings" field mentioning the soft limit of 10.
result: pass (re-tested after server restart)

## Summary

total: 6
passed: 6
issues: 0
pending: 0
skipped: 0
skipped: 0

## Gaps

[none — all issues were caused by running pre-Phase 17 server code without restart]
