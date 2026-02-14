---
phase: 34-tiered-autonomy
plan: 02
subsystem: classification
tags: [risk-tier, sidecar-integration, endpoint, pr-labels, diff-metadata]

requires:
  - phase: 34-tiered-autonomy
    provides: "AgentCom.RiskClassifier.classify/2 pure function"
provides:
  - "POST /api/tasks/:task_id/classify endpoint for risk tier classification"
  - "gatherDiffMeta CLI command in agentcom-git.js for diff metadata collection"
  - "Risk classification section in PR body with tier label and reasons"
  - "risk:tier-N GitHub labels on agent-created PRs"
  - "End-to-end flow: verification -> gather diff -> classify -> submit PR with classification"
affects: [auto-merge, dashboard-risk-view, task-analytics]

tech-stack:
  added: []
  patterns: [classify-before-submit, fail-safe-tier2-default, diff-meta-gathering]

key-files:
  created: []
  modified:
    - lib/agent_com/endpoint.ex
    - sidecar/agentcom-git.js
    - sidecar/index.js

key-decisions:
  - "gatherDiffMeta as CLI command (gather-diff-meta) in agentcom-git.js, invoked via runGitCommand -- follows existing child-process spawn pattern"
  - "classifyTask helper uses Node.js built-in http/https module (no new dependencies) with 10s timeout"
  - "Classification failure always defaults to Tier 2 -- never blocks PR creation"
  - "risk_classification included in task_complete WebSocket message for hub-side storage"

patterns-established:
  - "Risk tier labels (risk:tier-1/2/3) as GitHub PR labels for filtering"
  - "Diff metadata gathering as pre-PR-creation step in task completion flow"

duration: 4min
completed: 2026-02-14
---

# Phase 34 Plan 02: Sidecar Risk Classification Integration Summary

**End-to-end risk classification wired into task completion flow: sidecar gathers diff metadata, hub classifies via RiskClassifier, PRs get tier labels and classification sections**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-14T04:31:39Z
- **Completed:** 2026-02-14T04:35:58Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- POST /api/tasks/:task_id/classify endpoint accepts diff metadata and returns risk tier JSON
- gatherDiffMeta collects lines added/deleted, files changed/added, and test existence from git diff
- generatePrBody includes "Risk Classification" section with tier label and reasons when classification provided
- submit function creates risk:tier-N GitHub labels on PRs
- Task completion flow: verification -> gather diff meta -> classify via hub API -> submit PR with classification
- Classify failure gracefully defaults to Tier 2 without blocking PR creation
- risk_classification included in task_complete WebSocket message for hub storage

## Task Commits

Each task was committed atomically:

1. **Task 1: Add classify endpoint and sidecar diff gathering** - `6f56d04` (feat)
2. **Task 2: Wire classification into task completion flow** - `fda67c4` (feat)

## Files Created/Modified
- `lib/agent_com/endpoint.ex` - Added POST /api/tasks/:task_id/classify route with auth, calls RiskClassifier.classify/2
- `sidecar/agentcom-git.js` - Added gatherDiffMeta function + CLI command, enhanced generatePrBody with risk section, submit with risk:tier-N label
- `sidecar/index.js` - Added classifyTask HTTP helper, wired diff gathering and classification into handleResult between verification and git submit

## Decisions Made
- gatherDiffMeta implemented as a CLI command (`gather-diff-meta`) in agentcom-git.js rather than a directly importable function, since index.js accesses agentcom-git.js via child process spawn through runGitCommand
- classifyTask helper uses Node.js built-in http/https modules (matching existing sidecar patterns, no new npm dependencies)
- Classification HTTP call has 10-second timeout to prevent blocking the task completion flow
- All classification failures (network error, HTTP error, parse error, timeout) default to Tier 2 -- fail-safe design ensures PRs are always created

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Risk classification is fully wired end-to-end from sidecar to hub to PR
- PRs now carry risk:tier-N labels for GitHub-based filtering and review prioritization
- Foundation ready for future auto-merge logic (Tier 1 auto_merge_eligible flag already computed but not acted on)
- Dashboard can display risk classification data from task_complete messages

## Self-Check: PASSED

All files verified present. All commit hashes verified in git log.

---
*Phase: 34-tiered-autonomy*
*Completed: 2026-02-14*
