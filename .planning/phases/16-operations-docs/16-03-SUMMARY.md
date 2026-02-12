---
phase: 16-operations-docs
plan: 03
subsystem: docs
tags: [documentation, operations, troubleshooting, metrics, alerting, dets, jq]

# Dependency graph
requires:
  - phase: 16-01
    provides: ExDoc configuration, architecture overview, placeholder files for daily-operations.md and troubleshooting.md
  - phase: 14-metrics-alerting
    provides: MetricsCollector snapshot shape and Alerter rules referenced in daily operations guide
  - phase: 13-structured-logging
    provides: LoggerJSON format and telemetry events documented in log reading section
  - phase: 10-dets-backup
    provides: DetsBackup API and 9 DETS tables documented in troubleshooting guide
provides:
  - Daily operations guide covering dashboard, metrics, logs, alerts, maintenance, and API reference
  - Troubleshooting guide with 10 symptom-based failure modes and inline log diagnosis
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns: [symptom-based troubleshooting organization, inline jq queries in diagnosis steps, API quick reference tables grouped by function]

key-files:
  created: []
  modified:
    - docs/daily-operations.md
    - docs/troubleshooting.md

key-decisions:
  - "API quick reference grouped by function (not auth requirement) for faster lookup"
  - "Troubleshooting organized by symptom with inline log queries (not separate log interpretation section)"

patterns-established:
  - "Symptom-based troubleshooting: What you see -> Why -> Diagnosis steps -> Fix"
  - "Inline jq queries alongside each diagnosis step for immediate actionability"
  - "Cross-reference backtick links to module docs throughout prose"

# Metrics
duration: 5min
completed: 2026-02-12
---

# Phase 16 Plan 03: Daily Operations and Troubleshooting Summary

**Daily operations guide with dashboard/metrics/logs/alerts/maintenance documentation and symptom-based troubleshooting guide covering 10 failure modes with inline jq diagnosis queries**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-12T11:37:05Z
- **Completed:** 2026-02-12T11:42:12Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Daily operations guide covering dashboard overview, metrics interpretation (5 key metrics), structured log reading with 6 jq queries, all 5 alert rules with lifecycle and threshold configuration, routine maintenance (backup, compaction, log rotation, tokens, runtime config), and complete API quick reference (60+ endpoints)
- Troubleshooting guide with 10 symptom-based failure modes (4 HIGH, 3 MEDIUM, 3 LOW), each with inline log lines and jq queries, cross-references to module docs, and step-by-step diagnosis paths
- All 9 DETS tables enumerated by name with owner modules in the corruption troubleshooting section
- Both guides cross-reference architecture overview and each other for navigation

## Task Commits

Each task was committed atomically:

1. **Task 1: Create daily operations guide** - `c35d35e` (feat)
2. **Task 2: Create troubleshooting guide** - `be6fb9a` (feat)

## Files Created/Modified
- `docs/daily-operations.md` - Dashboard, metrics, logs, alerts, maintenance, API quick reference (471 lines)
- `docs/troubleshooting.md` - 10 symptom-based failure modes with inline diagnosis (439 lines)

## Decisions Made
- API quick reference table organized by function (task management, agent management, communication, system admin, configuration, rate limiting, monitoring, WebSocket) rather than by auth requirement -- operators look for "what can I do" not "what requires auth"
- Troubleshooting follows locked decision: symptom-based organization with log interpretation inline (not a separate section)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 16 (Operations Docs) is complete with all 4 guide files:
  - `docs/architecture.md` (Plan 01)
  - `docs/setup.md` (Plan 02)
  - `docs/daily-operations.md` (Plan 03)
  - `docs/troubleshooting.md` (Plan 03)
- `mix docs` generates a complete documentation site with all guides in the "Operations Guide" sidebar group
- All module cross-references resolve without warnings

## Self-Check: PASSED

- All 2 modified files verified on disk (daily-operations.md, troubleshooting.md)
- Both task commits verified in git history (c35d35e, be6fb9a)
- `mix docs` generates without errors or warnings
- 16-03-SUMMARY.md exists

---
*Phase: 16-operations-docs*
*Completed: 2026-02-12*
