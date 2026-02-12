# Phase 21: Verification Infrastructure - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Deterministic mechanical verification checks that run after task execution and produce structured pass/fail reports. Four built-in check types (file_exists, test_passes, git_clean, command_succeeds) work out of the box. Mechanical checks run before any LLM-based judgment. The self-verification retry loop (build-verify-fix pattern) is Phase 22.

</domain>

<decisions>
## Implementation Decisions

### Failure behavior
- Claude's discretion on fail-fast vs run-all-checks strategy (optimize for Phase 22 retry loop having good failure context)
- Global timeout per verification run (not per-check)
- Timeout is configurable per task; Claude picks sensible default when submitter doesn't specify
- Claude's discretion on whether verification results affect task status or attach as metadata (optimize for Phase 22 integration)

### Report structure
- Each check result includes pass/fail status plus captured stdout/stderr output
- Verification reports visible inline on dashboard: green/red per check, expandable output
- Reports persisted separately from task results (queryable verification history across tasks)
- Claude's discretion on whether to include per-check timing data

### Check type semantics
- `file_exists`: checks file presence at specified path
- `test_passes`: Claude decides between auto-detect (mix.exs -> mix test) vs task-specified command
- `git_clean`: strict — no uncommitted changes AND no untracked files (fully clean)
- `command_succeeds`: always captures stdout + stderr in check result
- Claude's discretion on parameter model (typed params per check type vs single string argument)

### Extensibility
- `command_succeeds` is the escape hatch for custom checks — no plugin system
- Promote commonly-used custom patterns to built-in types in future phases if needed
- Claude's discretion on check ordering (submission order vs auto-order by type)
- Tasks can opt out with `skip_verification: true` flag
- Tasks with no verification_steps defined auto-pass (no checks = no failures, no warnings)

### Claude's Discretion
- Fail-fast vs run-all-checks on failure
- Verification impact on task status vs metadata-only
- Per-check timing in reports
- Default global timeout value
- test_passes auto-detection strategy
- Check parameter model design
- Check execution ordering

</decisions>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 21-verification-infrastructure*
*Context gathered: 2026-02-12*
