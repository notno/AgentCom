---
phase: 08-onboarding
plan: 02
subsystem: cli
tags: [nodejs, cli, onboarding, pm2, culture-names, agent-provisioning]

# Dependency graph
requires:
  - phase: 08-onboarding
    provides: "POST /api/onboard/register, GET /api/config/default-repo endpoints"
  - phase: 01-sidecar
    provides: "Sidecar runtime (index.js, agentcom-git.js, ecosystem.config.js, start.sh/start.bat)"
provides:
  - "sidecar/culture-names.js -- Culture ship name list and random gcu-prefixed name generator"
  - "sidecar/add-agent.js -- One-command agent onboarding CLI (register, clone, config, install, pm2, verify)"
affects: [08-onboarding, sidecar-scripts, agent-provisioning]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Zero-dependency CLI using built-in util.parseArgs", "Step-based progress tracking with --resume for idempotent re-runs", "Per-agent ecosystem.config.js for unique pm2 process names"]

key-files:
  created:
    - "sidecar/culture-names.js"
    - "sidecar/add-agent.js"
  modified: []

key-decisions:
  - "Zero npm dependencies for CLI script -- uses built-in util.parseArgs, http/https, fs, path, os"
  - "Culture ship name collision check via GET /api/agents before registration (retry up to 10 times)"
  - "Per-agent ecosystem.config.js generated at ~/.agentcom/<name>/ecosystem.config.js with unique pm2 process name"
  - "Config written into cloned repo sidecar dir at ~/.agentcom/<name>/repo/sidecar/config.json"
  - "Test task polls every 2s for 30s -- hard failure printed if timeout with pm2 logs hint"
  - "Progress tracking via ~/.agentcom/<name>/.onboard-progress.json enables --resume across interruptions"

patterns-established:
  - "Agent install directory: ~/.agentcom/<agent-name>/ with repo/ subdirectory and logs/"
  - "Step-based CLI progress: [n/7] Step name... done/skipped/FAILED"
  - "Onboarding progress file: .onboard-progress.json tracks steps_completed array for resume"

# Metrics
duration: 3min
completed: 2026-02-11
---

# Phase 8 Plan 02: Add-Agent Script Summary

**One-command agent onboarding with Culture ship names, 7-step provisioning (register/clone/config/deps/pm2/verify), and --resume for interrupted runs**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-11T21:30:55Z
- **Completed:** 2026-02-11T21:33:47Z
- **Tasks:** 2
- **Files created:** 2

## Accomplishments
- Culture ship name generator with 65 names from Iain M. Banks' novels, gcu-prefixed
- Complete 7-step onboarding script: preflight checks, hub registration, repo clone, config generation, npm install, pm2 start, test task verification
- --resume flag with progress tracking for interrupted onboarding runs
- Zero npm dependencies in CLI script (all Node.js built-ins)
- Quick-start guide printed on successful onboarding

## Task Commits

Each task was committed atomically:

1. **Task 1: Create culture-names.js module** - `11eeafd` (feat)
2. **Task 2: Create add-agent.js onboarding script** - `d62b348` (feat)

**Plan metadata:** (pending final commit)

## Files Created/Modified
- `sidecar/culture-names.js` - 65 Culture ship names with getNames() and generateName() exports
- `sidecar/add-agent.js` - 462-line CLI script for one-command agent provisioning

## Decisions Made
- Zero npm dependencies for the CLI script -- all functionality via Node.js built-ins (util.parseArgs, http, https, fs, path, os, child_process)
- Culture ship name collision check done via GET /api/agents before registration attempt, with up to 10 retries for unique name generation
- Per-agent ecosystem.config.js generated at install directory (not using repo's hardcoded one) for unique pm2 process names
- Config written into cloned repo's sidecar directory (not a separate location) since sidecar code lives in the repo
- Test task verification uses 30-second timeout with 2-second polling interval; hard failure is non-blocking (agent is still registered and running)
- Progress tracking in ~/.agentcom/<name>/.onboard-progress.json stores steps_completed array, token, and repo_url for resume capability

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- add-agent.js ready for end-to-end testing (requires running hub instance)
- culture-names.js available for any script needing agent name generation
- Ready for Plan 03 (remove-agent script, documentation, or further onboarding tooling)

## Self-Check: PASSED

- [x] sidecar/culture-names.js exists
- [x] sidecar/add-agent.js exists
- [x] 08-02-SUMMARY.md exists
- [x] Commit 11eeafd found (Task 1)
- [x] Commit d62b348 found (Task 2)

---
*Phase: 08-onboarding*
*Completed: 2026-02-11*
