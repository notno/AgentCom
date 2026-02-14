# Phase 37: CI Fix - Research

**Researched:** 2026-02-14
**Domain:** CI pipeline / Git workflow / Elixir compilation
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **Pull then push** -- pull remote first to ensure clean merge, then push local fixes
- **Scope is minimal** -- just unblock CI, don't refactor or clean up

### Claude's Discretion
(none specified)

### Deferred Ideas (OUT OF SCOPE)
(none specified)
</user_constraints>

## Summary

CI is **already passing** on remote `main` as of commit `3d73a0c` (the most recent push). The conflict markers in `endpoint.ex` were resolved in commit `60c94cd` and pushed as part of a batch that includes the merge at `87f1916`. The latest CI run (ID `22021239093`) shows 828 tests, 0 failures, and `mix compile --warnings-as-errors` exits cleanly.

The only remaining work is pushing the 1 local commit (`0a97f11`, docs: front-load phase discussions) that is ahead of `origin/main`. This commit contains only `.planning/` markdown files, so it carries zero risk of breaking CI.

**Primary recommendation:** Push the single local commit to `origin/main` and verify CI stays green. Phase 37 may already be complete.

## Current CI State (Verified)

### Latest CI Run: PASSING
| Job | Status | Duration | Commit |
|-----|--------|----------|--------|
| `elixir-tests` | Pass | 44s | `3d73a0c` |
| `sidecar-tests` | Pass | 7s | `3d73a0c` |

**Test results:** 828 tests, 0 failures (6 excluded)
**Compilation:** `mix compile --warnings-as-errors` exits 0, no source warnings

### Previous CI Run: FAILED (now resolved)
| Job | Status | Failure | Commit |
|-----|--------|---------|--------|
| `elixir-tests` | Fail | 1 test failure | `34c4ee7` |
| `sidecar-tests` | Pass | -- | `34c4ee7` |

**Failure:** `ScalabilityAnalyzerTest` "nil snapshot uses empty defaults" -- asserts `result.current_state == :healthy` but got `:critical`. This test is environment-dependent (calls `fetch_snapshot()` which reads live system state when passed `nil`). It passed on the next run without any code change to the analyzer.

## Git State (Verified)

### Remote vs Local
- **Remote `origin/main`:** `3d73a0c` (dashboard: fix auth)
- **Local `main`:** `0a97f11` (docs: front-load phase discussions) -- **1 commit ahead**
- **Local ahead commits:** Only `.planning/` markdown files (CONTEXT.md files for v1.4 phases)
- **Remote ahead of local:** 0 commits (already fetched and confirmed)

### Conflict Markers
- `endpoint.ex`: **0 conflict markers** (verified with grep)
- `git diff --check origin/main`: **clean** (no whitespace or conflict issues)

## CI Workflow Structure

**File:** `.github/workflows/ci.yml`

### Job: `elixir-tests`
1. `actions/checkout@v4`
2. `erlef/setup-beam@v1` -- OTP 28, Elixir 1.19
3. `actions/cache@v4` -- caches `deps/` and `_build/`
4. `mix deps.get`
5. `mix compile --warnings-as-errors`
6. `mix test --exclude skip --exclude smoke`

### Job: `sidecar-tests`
1. `actions/checkout@v4`
2. `actions/setup-node@v4` -- Node.js 22
3. `npm ci` (in `sidecar/` directory)
4. `npm test`

### Triggers
- Push to `main`
- Pull requests targeting `main`

## Known Warnings (non-blocking)

These appear during `mix test` compilation of test files (not `mix compile`), so they do NOT trigger `--warnings-as-errors`:

1. **`test/agent_com/channels_test.exs:18`** -- unused default arg in private `make_msg/2`
2. **`test/agent_com/reaper_test.exs:4`** -- unused alias `Reaper`
3. **`test/agent_com/agent_fsm_test.exs:15`** -- unused alias `TestFactory`

These are test-only warnings and do not block CI. The `--warnings-as-errors` flag applies only to the `mix compile` step (source code), not the test compilation.

## Common Pitfalls

### Pitfall 1: Flaky ScalabilityAnalyzer Test
**What goes wrong:** `analyze(nil)` calls `fetch_snapshot()` which reads live system state. In CI, if the application supervision tree is in an unexpected state, the snapshot can return values that trigger `:critical` instead of `:healthy`.
**Why it happens:** The test assumes nil input produces healthy defaults, but nil actually means "read from the running system."
**How to avoid:** This is out of scope for Phase 37 (minimal fix only), but worth noting for future phases. The test passed on the latest run.
**Warning signs:** Intermittent test failures in `ScalabilityAnalyzerTest` with no code changes.

### Pitfall 2: Assuming CI Is Still Broken
**What goes wrong:** The phase description and discussion context describe CI as broken, but CI has been fixed by commits already pushed to remote.
**Why it happens:** The discussion happened before the most recent pushes landed.
**How to avoid:** Always verify current CI status with `gh run list` before taking action.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| CI status checking | Manual git log inspection | `gh run list` / `gh run view` | Authoritative, shows actual pass/fail |
| Conflict detection | Manual file searching | `git diff --check` | Catches all conflict markers reliably |

## Architecture Patterns

### CI Verification Sequence
```bash
# 1. Check current CI status
gh run list --limit 3

# 2. Verify no conflict markers
git diff --check origin/main

# 3. Push local commits
git push origin main

# 4. Monitor new CI run
gh run watch
```

## Success Criteria Status

| Criterion | Status | Evidence |
|-----------|--------|----------|
| `git diff --check` shows zero conflict markers | **ALREADY MET** | Verified locally, 0 markers in endpoint.ex |
| `mix compile --warnings-as-errors` exits 0 | **ALREADY MET** | CI run 22021239093 compiled 82 files, 0 warnings |
| `mix test --exclude skip --exclude smoke` exits 0 | **ALREADY MET** | CI run 22021239093: 828 tests, 0 failures |

## Open Questions

1. **Is the ScalabilityAnalyzer test flaky?**
   - What we know: It failed on `34c4ee7`, passed on `3d73a0c` with no code change to the analyzer
   - What's unclear: Whether this will fail again intermittently
   - Recommendation: Out of scope for Phase 37. If it flakes again, it should be addressed in a testing reliability phase.

2. **Should the 1 local commit be pushed?**
   - What we know: It contains only `.planning/` CONTEXT.md files, zero risk to CI
   - Recommendation: Push it as part of Phase 37 execution to ensure local and remote are in sync

## Sources

### Primary (HIGH confidence)
- `gh run list --limit 5` -- verified CI run history, latest run passing
- `gh run view 22021239093` -- confirmed 828 tests, 0 failures, compile clean
- `gh run view 22021079728 --log-failed` -- confirmed single test failure (ScalabilityAnalyzer)
- `git log --oneline origin/main..HEAD` -- confirmed 1 commit ahead
- `git diff --check origin/main` -- confirmed no conflict markers
- `.github/workflows/ci.yml` -- verified CI configuration

## Metadata

**Confidence breakdown:**
- CI state: HIGH -- verified directly from GitHub Actions
- Git state: HIGH -- verified with git commands after fresh fetch
- Risk assessment: HIGH -- only 1 docs-only commit to push

**Research date:** 2026-02-14
**Valid until:** 2026-02-21 (CI state changes with every push)
