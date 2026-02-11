---
phase: 08-onboarding
plan: 03
subsystem: cli-tools
tags: [nodejs, cli, parseArgs, teardown, task-submission, standalone-scripts]

# Dependency graph
requires:
  - phase: 08-onboarding
    provides: "POST /api/onboard/register endpoint and DELETE /admin/tokens/:agent_id for token revocation"
provides:
  - "sidecar/remove-agent.js -- CLI for clean agent teardown (pm2 stop, token revoke, dir delete)"
  - "sidecar/agentcom-submit.js -- CLI for submitting tasks to hub queue with priority/target/metadata"
affects: [onboarding-workflow, operator-tooling]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Standalone CLI scripts using Node.js built-in util.parseArgs (zero npm deps)", "Best-effort cleanup pattern (continue through individual step failures)"]

key-files:
  created:
    - "sidecar/remove-agent.js"
    - "sidecar/agentcom-submit.js"
  modified: []

key-decisions:
  - "remove-agent.js auto-reads token from agent config.json if --token not provided"
  - "Best-effort teardown: each step wrapped in try/catch, only exit 1 if all 3 steps fail"
  - "agentcom-submit.js stores --target in metadata.target_agent (no first-class hub field yet)"
  - "Both scripts use inline httpRequest helper (standalone, no shared modules)"

patterns-established:
  - "Teardown scripts: best-effort cleanup with warnings on individual step failure"
  - "CLI tools: util.parseArgs for flags, usage message on missing required flags"

# Metrics
duration: 2min
completed: 2026-02-11
---

# Phase 8 Plan 03: Teardown and Task Submission CLI Summary

**remove-agent.js for 3-step agent teardown and agentcom-submit.js for CLI task submission with priority/target/metadata flags**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-11T21:31:02Z
- **Completed:** 2026-02-11T21:33:00Z
- **Tasks:** 2
- **Files created:** 2

## Accomplishments
- remove-agent.js performs clean 3-step teardown: pm2 stop/delete, hub token revocation via DELETE /admin/tokens/:name, agent directory removal
- agentcom-submit.js submits tasks to hub via POST /api/tasks with full flag support (--description, --priority, --target, --metadata)
- Both scripts use Node.js built-in util.parseArgs with zero npm dependencies
- remove-agent.js auto-reads token from agent config.json when --token is not provided
- Priority validation against allowed values (low, normal, urgent, critical) with clear error messages
- Metadata validated as valid JSON object before submission

## Task Commits

Each task was committed atomically:

1. **Task 1: Create remove-agent.js teardown script** - `42b55b7` (feat)
2. **Task 2: Create agentcom-submit.js task submission CLI** - `8e7bd89` (feat)

**Plan metadata:** (pending final commit)

## Files Created/Modified
- `sidecar/remove-agent.js` - Agent teardown CLI: pm2 stop, token revoke, directory delete
- `sidecar/agentcom-submit.js` - Task submission CLI: POST /api/tasks with auth and metadata

## Decisions Made
- remove-agent.js auto-reads token from `~/.agentcom/<name>/repo/sidecar/config.json` if --token flag is not provided, enabling teardown without remembering the token
- Best-effort teardown pattern: each of the 3 steps is independently try/caught, failures log warnings but continue to next step; only exit 1 if all steps fail
- agentcom-submit.js stores --target in metadata.target_agent field since the hub has no first-class target field yet
- Both scripts use inline async httpRequest helper (consistent pattern but no shared module since they are standalone scripts)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Complete onboarding toolchain now available: add-agent provisions (08-02), remove-agent tears down (08-03), agentcom-submit makes system immediately usable
- All three CLI scripts are standalone with zero npm dependencies
- DELETE /admin/tokens/:agent_id endpoint (from Phase 1) confirmed available for remove-agent flow

## Self-Check: PASSED

- FOUND: sidecar/remove-agent.js
- FOUND: sidecar/agentcom-submit.js
- FOUND: 08-03-SUMMARY.md
- FOUND: commit 42b55b7
- FOUND: commit 8e7bd89

---
*Phase: 08-onboarding*
*Completed: 2026-02-11*
