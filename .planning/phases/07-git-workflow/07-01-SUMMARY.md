---
phase: 07-git-workflow
plan: 01
subsystem: git-workflow
tags: [git, gh-cli, cli, child_process, pr-automation, branch-management]

# Dependency graph
requires:
  - phase: 01-sidecar
    provides: "Sidecar process that will invoke agentcom-git commands"
provides:
  - "agentcom-git CLI tool with start-task, submit, status commands"
  - "Autonomous branch-per-task workflow via git/gh CLI wrappers"
  - "Structured JSON output for sidecar consumption"
  - "PR creation with metadata, labels, reviewer assignment"
  - "Conventional commit compliance checking"
affects: [07-git-workflow, 08-onboarding]

# Tech tracking
tech-stack:
  added: []
  patterns: [CLI command dispatcher via argv, structured JSON stdout for IPC, execSync with cwd isolation, --body-file for shell escaping, force-with-lease for safe push, idempotent label creation]

key-files:
  created:
    - sidecar/agentcom-git.js
  modified: []

key-decisions:
  - "Auto-slugify task description for branch names (no separate metadata field required)"
  - "force-with-lease as default push strategy (safest for re-submit without overwriting others' work)"
  - "PR body written to temp file to avoid cross-platform shell escaping issues"
  - "Labels created idempotently via gh label create --force before PR creation"
  - "Config loaded from __dirname (sidecar dir) but all git/gh commands use cwd: config.repo_dir"

patterns-established:
  - "CLI command dispatcher: process.argv[2] for command, process.argv[3] for JSON args"
  - "Structured JSON output: outputSuccess/outputError for all command responses"
  - "Shell helper pattern: git() and gh() wrappers with config.repo_dir as cwd"
  - "Conventional commit regex validation for status reporting"

# Metrics
duration: 4min
completed: 2026-02-11
---

# Phase 7 Plan 1: Git Workflow CLI Summary

**Standalone agentcom-git CLI with start-task (fetch+branch), submit (push+PR), and status (branch info+diff) commands using git/gh via execSync**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-11T08:34:54Z
- **Completed:** 2026-02-11T08:39:00Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- Built complete agentcom-git.js CLI (360 lines) with three commands: start-task, submit, status
- All output is structured JSON -- no interactive prompts, no external npm dependencies
- start-task enforces clean working tree, fetches origin, creates agent/slug branch from origin/main
- submit pushes with force-with-lease, creates PR with full metadata (task ID, agent, priority, diff stat, task link), auto-creates labels, assigns reviewer
- status reports branch, commits ahead, diff from main, uncommitted changes, and conventional commit compliance

## Task Commits

Each task was committed atomically:

1. **Task 1: Create agentcom-git.js CLI with start-task, submit, and status commands** - `347327a` (feat)

**Plan metadata:** [pending] (docs: complete plan)

## Files Created/Modified
- `sidecar/agentcom-git.js` - Standalone CLI tool wrapping git and gh commands for autonomous agent git workflow

## Decisions Made
- Auto-slugify task description for branch names -- avoids requiring submitters to provide a slug metadata field, keeps the interface simple
- force-with-lease as default push strategy -- safest option for single-agent branches that may need re-submission after reclamation
- PR body written to temp file (.pr-body.tmp) via --body-file flag -- eliminates cross-platform shell escaping issues (Windows cmd.exe vs Unix)
- Labels created idempotently with `gh label create --force` before PR creation -- handles first-time label creation transparently
- Config validation at startup checks repo_dir exists and is a git repo (.git directory) -- fails fast with clear error

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required. Users need to add `repo_dir`, `hub_api_url`, and optionally `reviewer` fields to their `sidecar/config.json` when deploying.

## Next Phase Readiness
- agentcom-git CLI is ready for sidecar integration (Plan 07-02)
- Plan 07-02 will wire start-task into handleTaskAssign and submit into handleResult
- config.json.example should be updated with new fields (repo_dir, hub_api_url, reviewer) in Plan 07-02

## Self-Check: PASSED

- [x] sidecar/agentcom-git.js exists (360 lines)
- [x] Commit 347327a exists in git log
- [x] 07-01-SUMMARY.md created

---
*Phase: 07-git-workflow*
*Completed: 2026-02-11*
