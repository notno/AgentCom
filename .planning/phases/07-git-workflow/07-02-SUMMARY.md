---
phase: 07-git-workflow
plan: 02
subsystem: git-workflow
tags: [git, sidecar, lifecycle-hooks, child_process, spawnSync, backward-compat]

# Dependency graph
requires:
  - phase: 07-git-workflow
    plan: 01
    provides: "agentcom-git CLI tool with start-task, submit, status commands"
  - phase: 01-sidecar
    provides: "Sidecar index.js with handleTaskAssign and handleResult lifecycle"
provides:
  - "Automatic git branch creation on task assignment (sidecar calls start-task)"
  - "Automatic PR creation on task completion (sidecar calls submit before hub notification)"
  - "PR URL propagation from sidecar to hub in task_complete message"
  - "Graceful degradation: git failures produce warnings, never block agent wake or task reporting"
  - "Opt-in git workflow via repo_dir config field (backward-compatible)"
affects: [08-onboarding]

# Tech tracking
tech-stack:
  added: []
  patterns: [spawnSync for synchronous child process IPC, JSON-over-stdio for CLI communication, opt-in feature gating via config field presence, graceful degradation with warning fields]

key-files:
  created: []
  modified:
    - sidecar/index.js
    - sidecar/config.json.example

key-decisions:
  - "spawnSync instead of execSync for runGitCommand -- eliminates nested try/catch anti-pattern, cleaner error handling"
  - "Git workflow opt-in via repo_dir presence -- empty/missing means completely skipped, zero impact on existing sidecars"
  - "start-task failure sets git_warning on task object but still wakes agent -- agent can work without git branching"
  - "submit failure still reports task_complete to hub -- just omits pr_url, no data loss"
  - "repo_dir resolved against __dirname if relative -- consistent with log_file and results_dir patterns"

patterns-established:
  - "Feature gating via config field presence: if (_config.repo_dir) guards all git operations"
  - "Warning-not-failure pattern: git_warning field on task object for non-fatal git issues"
  - "PR URL propagation: result.pr_url set by sidecar, forwarded in task_complete to hub"

# Metrics
duration: 5min
completed: 2026-02-11
---

# Phase 7 Plan 2: Sidecar Git Integration Summary

**Sidecar lifecycle hooks calling agentcom-git for automatic branch creation on task assignment and PR submission on task completion, with opt-in gating and graceful degradation**

## Performance

- **Duration:** 5 min (execution) + checkpoint pause for human verification
- **Started:** 2026-02-11T08:40:23Z
- **Completed:** 2026-02-11T20:08:03Z
- **Tasks:** 2 (1 auto + 1 human-verify checkpoint)
- **Files modified:** 2

## Accomplishments
- Wired agentcom-git start-task into handleTaskAssign: branch created before agent is woken
- Wired agentcom-git submit into handleResult: PR created and URL captured before hub notification
- Updated config.json.example with repo_dir, reviewer, and hub_api_url fields
- Added loadConfig defaults for new optional fields (backward-compatible)
- Refactored runGitCommand from execSync to spawnSync for cleaner error handling (post-checkpoint)

## Task Commits

Each task was committed atomically:

1. **Task 1: Add runGitCommand helper and wire git lifecycle into sidecar** - `bd6d57a` (feat)
2. **Post-checkpoint refactor: Replace execSync with spawnSync in runGitCommand** - `3405dc3` (refactor)
3. **Task 2: Verify git workflow pipeline** - checkpoint:human-verify (approved)

**Plan metadata:** `d0da2e7` (docs: complete plan)

## Files Created/Modified
- `sidecar/index.js` - Added runGitCommand helper (spawnSync-based), git lifecycle hooks in handleTaskAssign and handleResult, config defaults for git fields
- `sidecar/config.json.example` - Added repo_dir, reviewer, hub_api_url fields

## Decisions Made
- Used spawnSync instead of execSync for runGitCommand -- avoids nested try/catch since spawnSync returns status/stdout/stderr without throwing, making error path cleaner
- Git workflow is entirely opt-in via repo_dir config field presence -- sidecars without repo_dir skip all git operations with zero overhead
- start-task failure produces git_warning field on task object but does NOT prevent agent wake -- agent can still work, just without a dedicated branch
- submit failure does NOT prevent task_complete reporting to hub -- PR URL is simply omitted from the result
- New config fields (repo_dir, reviewer, hub_api_url) default to empty string, not added to required array

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Replaced execSync with spawnSync in runGitCommand**
- **Found during:** Post-Task 1 review (checkpoint pause)
- **Issue:** execSync throws on non-zero exit, requiring nested try/catch (outer for execution failure, inner for JSON parse of error stdout) -- anti-pattern
- **Fix:** Switched to spawnSync which returns result object with status/stdout/stderr without throwing, single clean error path
- **Files modified:** sidecar/index.js
- **Verification:** Code review confirmed cleaner control flow, same behavior
- **Committed in:** `3405dc3`

---

**Total deviations:** 1 auto-fixed (1 bug/code quality)
**Impact on plan:** Improvement to error handling pattern. No scope creep.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required. Users need to add `repo_dir`, `hub_api_url`, and optionally `reviewer` fields to their `sidecar/config.json` when deploying the git workflow feature.

## Next Phase Readiness
- Full git workflow pipeline is complete: task_assign -> start-task -> wake agent -> agent works -> submit -> PR -> task_complete with pr_url
- Phase 8 (onboarding/docs) can reference the git workflow configuration
- The git workflow is production-ready for agents that have gh CLI authenticated

## Self-Check: PASSED

- [x] sidecar/index.js exists
- [x] sidecar/config.json.example exists
- [x] Commit bd6d57a exists in git log
- [x] Commit 3405dc3 exists in git log
- [x] 07-02-SUMMARY.md created

---
*Phase: 07-git-workflow*
*Completed: 2026-02-11*
