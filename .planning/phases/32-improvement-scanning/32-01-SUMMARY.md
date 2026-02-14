---
phase: 32-improvement-scanning
plan: 01
subsystem: self-improvement
tags: [dets, finding-struct, cooldown, oscillation-detection, improvement-history]

# Dependency graph
requires:
  - phase: 26-goal-backlog
    provides: "GoalBacklog DETS pattern and DetsBackup registration"
provides:
  - "AgentCom.SelfImprovement.Finding struct with 8 typed fields"
  - "AgentCom.SelfImprovement.ImprovementHistory DETS-backed persistence"
  - "File cooldown detection (configurable, default 24h)"
  - "Anti-oscillation detection via inverse-pattern matching"
  - "DetsBackup registration for :improvement_history table"
affects: [32-02, 32-03, 32-04, 34-tiered-autonomy]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Library-owned DETS table pattern (non-GenServer)", "@library_tables list in DetsBackup for sync-only compaction"]

key-files:
  created:
    - lib/agent_com/self_improvement/finding.ex
    - lib/agent_com/self_improvement/improvement_history.ex
  modified:
    - lib/agent_com/dets_backup.ex

key-decisions:
  - "Library-owned DETS with @library_tables pattern for non-GenServer table compaction"
  - "Direct ImprovementHistory.init() calls in DetsBackup restore instead of dynamic owner.init()"
  - "Config.get fail-open with catch :exit fallback for cooldown configuration"

patterns-established:
  - "@library_tables: DetsBackup pattern for tables owned by library modules (not GenServers)"
  - "Inverse-pair oscillation detection: consecutive description comparison against known antonym pairs"

# Metrics
duration: 3min
completed: 2026-02-14
---

# Phase 32 Plan 01: Data Structures and Persistence Summary

**Finding struct with 8 enforced fields and DETS-backed ImprovementHistory with cooldown/oscillation anti-Sisyphus protections**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-14T03:11:15Z
- **Completed:** 2026-02-14T03:14:25Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Finding struct provides uniform interface for all scanners (Credo, Dialyzer, deterministic, LLM) with scan_type, severity, effort, and scanner fields
- ImprovementHistory DETS persistence with file cooldowns (default 24h) and inverse-pattern oscillation detection
- DetsBackup updated to 13 tables with new @library_tables pattern for non-GenServer-owned DETS tables

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Finding struct and ImprovementHistory module** - `0373e54` (feat)
2. **Task 2: Register :improvement_history in DetsBackup** - `160fc2b` (feat)

## Files Created/Modified
- `lib/agent_com/self_improvement/finding.ex` - Common finding struct with 8 enforced fields and Jason.Encoder derivation
- `lib/agent_com/self_improvement/improvement_history.ex` - DETS-backed history with init/close/record/cooldown/oscillation/filter APIs
- `lib/agent_com/dets_backup.ex` - Updated @tables (13), @library_tables, table_owner, get_table_path, compact_table, perform_restore

## Decisions Made
- **@library_tables pattern:** Created a separate module attribute for non-GenServer DETS table owners. Compaction uses :dets.sync directly; restore uses close/copy/init instead of Supervisor terminate/restart.
- **Direct module call in restore:** Used `AgentCom.SelfImprovement.ImprovementHistory.init()` instead of dynamic `owner.init()` to avoid compilation warnings from modules that only have `init/1`.
- **Config.get fail-open:** Cooldown reads from Config GenServer with `catch :exit` fallback to 24h default, matching the Alerter/DashboardState pattern.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed dynamic owner.init() compilation warnings**
- **Found during:** Task 2 (DetsBackup registration)
- **Issue:** Dynamic call `owner.init()` triggered compilation warnings for all possible modules returned by table_owner/1, since GenServer modules only have `init/1` not `init/0`
- **Fix:** Replaced dynamic `owner.init()` with direct `AgentCom.SelfImprovement.ImprovementHistory.init()` call in the library table restore path
- **Files modified:** lib/agent_com/dets_backup.ex
- **Verification:** mix compile --warnings-as-errors passes
- **Committed in:** 160fc2b (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Essential fix for clean compilation. No scope creep.

## Issues Encountered
- Pre-existing compilation error in lib/agent_com/goal_orchestrator/decomposer.ex (placeholder file) -- not related to this plan's changes. Both new modules compile cleanly.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Finding struct ready for use by all scanners (32-02 CredoScanner, DialyzerScanner, DeterministicScanner; 32-03 LlmScanner)
- ImprovementHistory ready for filtering in SelfImprovement orchestrator (32-04)
- DetsBackup handles backup/recovery/compaction of the new table

---
*Phase: 32-improvement-scanning*
*Completed: 2026-02-14*
