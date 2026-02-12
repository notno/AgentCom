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
result: issue
reported: "GET /api/tasks/:id response does not include enrichment fields (repo, branch, file_hints, success_criteria, verification_steps, complexity). Fields may be stored internally but format_task is not serializing them in the API response."
severity: major

### 2. Submit Task Without Enrichment Fields (Backward Compat)
expected: POST a task with only "description" (no enrichment fields). Task submits successfully. GET it back -- repo and branch are null, file_hints/success_criteria/verification_steps are empty arrays, complexity is present with source "inferred".
result: pass

### 3. Invalid Enrichment Fields Rejected
expected: POST a task with invalid file_hints (e.g., missing "path" key in a hint object). Server returns 422 validation error with a message identifying the invalid field.
result: issue
reported: "Result: 201 — it accepted it. No validation error. The invalid file_hints (missing path key) went through without complaint. Server should have returned 422 but returned 201 instead. Looks like there's no schema validation on enrichment fields — it just accepts whatever you throw at it."
severity: major

### 4. Explicit Complexity Tier Honored
expected: POST a task with complexity_tier "complex". GET it back. complexity.effective_tier is "complex" and complexity.source is "explicit". The inferred result is also present (heuristic ran alongside).
result: issue
reported: "POST 201 OK. GET: No complexity field in the response. No effective_tier, no source, no inferred sub-object. Same flat structure as before. Consistent with Test 1 — enrichment fields accepted on POST but don't appear in GET response. Either not being persisted or not being serialized back out."
severity: major

### 5. Complexity Inferred When Not Specified
expected: POST a task with a long, complex description (mentioning refactoring, multiple files, etc.) but no complexity_tier. GET it back. complexity.effective_tier is "complex" (or "standard"), complexity.source is "inferred", and complexity.inferred.confidence is a number between 0 and 1.
result: skipped
reason: Same root cause as Tests 1 and 4 — enrichment fields not in GET response. Will pass once format_task is fixed.

### 6. Verification Steps Soft Limit Warning
expected: POST a task with 11 verification_steps. Task submits successfully (not rejected). Response includes a "warnings" field mentioning the soft limit of 10.
result: issue
reported: "201 — submitted fine, but no warnings field in the response. 11 verification steps went through without any soft limit warning. No validation or warning on exceeding 10 verification steps. Consistent pattern — enrichment fields are passed through without any schema validation, limits, or warnings."
severity: major

## Summary

total: 6
passed: 1
issues: 4
pending: 0
skipped: 1
skipped: 0

## Gaps

- truth: "GET /api/tasks/:id returns all enrichment fields (repo, branch, file_hints, success_criteria, verification_steps, complexity) matching what was submitted"
  status: failed
  reason: "User reported: GET response does not include enrichment fields. Fields may be stored internally but format_task is not serializing them in the API response."
  severity: major
  test: 1
  root_cause: ""
  artifacts: []
  missing: []
  debug_session: ""
- truth: "GET /api/tasks/:id returns complexity object with effective_tier, source, and inferred sub-object when explicit complexity_tier was submitted"
  status: failed
  reason: "User reported: No complexity field in GET response. Enrichment fields accepted on POST but not serialized in GET. Same root cause as Test 1."
  severity: major
  test: 4
  root_cause: ""
  artifacts: []
  missing: []
  debug_session: ""
- truth: "POST /api/tasks with 11+ verification steps returns a warnings field about the soft limit of 10"
  status: failed
  reason: "User reported: 201 with no warnings field. 11 verification steps accepted without any soft limit warning. Enrichment validation and warnings not wired into endpoint."
  severity: major
  test: 6
  root_cause: ""
  artifacts: []
  missing: []
  debug_session: ""
- truth: "POST /api/tasks with invalid file_hints (missing path key) returns 422 validation error"
  status: failed
  reason: "User reported: Server returned 201 instead of 422. Invalid file_hints accepted without validation. Enrichment validation (validate_enrichment_fields) not being called in the endpoint."
  severity: major
  test: 3
  root_cause: ""
  artifacts: []
  missing: []
  debug_session: ""
