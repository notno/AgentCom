---
phase: 34-tiered-autonomy
plan: 01
subsystem: classification
tags: [risk-tier, pure-function, config-driven, telemetry, tdd]

requires:
  - phase: 14-complexity
    provides: "AgentCom.Complexity module with effective_tier classification"
provides:
  - "AgentCom.RiskClassifier.classify/2 pure function for risk tier classification"
  - "Config defaults for all risk_ prefixed threshold keys"
  - "Telemetry event [:agent_com, :risk, :classified]"
affects: [34-02-sidecar-integration, endpoint, task-queue, pr-creation]

tech-stack:
  added: []
  patterns: [gather-signals-then-classify, config-driven-thresholds, dual-key-verification-report]

key-files:
  created:
    - lib/agent_com/risk_classifier.ex
    - test/agent_com/risk_classifier_test.exs
  modified:
    - lib/agent_com/config.ex
    - lib/agent_com/telemetry.ex

key-decisions:
  - "Tier 1 boundary uses strict less-than for lines (<20) and less-than-or-equal for files (<=3)"
  - "Config defaults registered in Config GenServer @defaults map (not module-local fallbacks)"
  - "Verification report nil treated as passed (no verification = ok by default)"
  - "Protected path matching via String.contains? for prefix-style matching"

patterns-established:
  - "risk_ prefix namespace for all risk classification config keys"
  - "Dual string/atom key support for verification_report status checking"

duration: 3min
completed: 2026-02-14
---

# Phase 34 Plan 01: RiskClassifier Summary

**Pure function RiskClassifier.classify/2 with 3-tier classification (escalate/review/auto-merge-candidate) driven by diff metadata, complexity tier, and configurable thresholds**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-14T04:25:26Z
- **Completed:** 2026-02-14T04:28:43Z
- **Tasks:** 1 (TDD: RED-GREEN-REFACTOR)
- **Files modified:** 4

## Accomplishments
- RiskClassifier.classify/2 correctly classifies tasks into tiers 1, 2, and 3
- Protected paths (config/, rel/, .github/, Dockerfile, mix.exs, mix.lock) and auth paths trigger Tier 3
- Failed verification triggers Tier 3 with dual string/atom key support
- All Tier 1 criteria must simultaneously pass (complexity, lines, files, tests, no new files, verification)
- Missing/empty diff metadata safely defaults to Tier 2
- All thresholds configurable via Config GenServer with 8 new risk_ prefixed keys
- 33 test cases covering all tiers, edge cases, config boundaries, and telemetry

## Task Commits

Each task was committed atomically:

1. **Task 1 RED: RiskClassifier failing tests** - `d7d6f5c` (test)
2. **Task 1 GREEN: RiskClassifier implementation** - `f028402` (feat)

_TDD task: RED committed first with 33 failing tests, GREEN committed with implementation passing all 33._

## Files Created/Modified
- `lib/agent_com/risk_classifier.ex` - Pure function module: classify/2 entry point, signal gathering, tier computation, reason building
- `test/agent_com/risk_classifier_test.exs` - 33 test cases across 9 describe blocks
- `lib/agent_com/config.ex` - Added 8 risk_ prefixed defaults to @defaults map
- `lib/agent_com/telemetry.ex` - Added [:agent_com, :risk, :classified] event to catalog and handler attachment

## Decisions Made
- Registered all risk config defaults in Config GenServer @defaults map rather than module-local fallbacks -- ensures Config.get/1 always returns sensible values even without DETS storage
- Tier 1 uses strict less-than (<) for lines threshold and less-than-or-equal (<=) for files threshold, matching the plan specification
- Verification report nil treated as passed -- tasks without verification should not be penalized with Tier 3
- Protected path matching uses String.contains?/2 for prefix-style matching so "config/" catches "config/dev.exs"

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- RiskClassifier module ready for Plan 02 sidecar integration
- classify/2 API accepts task map + diff_meta map, returns classification with tier/reasons/auto_merge_eligible/signals
- Config keys are hot-reloadable via Config.put/2 for threshold tuning

## Self-Check: PASSED

All files verified present. All commit hashes verified in git log.

---
*Phase: 34-tiered-autonomy*
*Completed: 2026-02-14*
