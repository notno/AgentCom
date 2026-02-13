---
phase: 23-multi-repo-registry-and-workspace-switching
plan: 01
subsystem: api, database, infra
tags: dets, genserver, pubsub, http-api, registry

# Dependency graph
requires:
  - phase: 18-llm-registry-host-resources
    provides: "LlmRegistry DETS GenServer pattern, DetsBackup integration, endpoint admin routes"
provides:
  - "RepoRegistry GenServer with DETS persistence, CRUD, reorder, pause/unpause"
  - "HTTP admin API for repo registry (7 routes)"
  - "Validation schema for repo registration"
  - "DetsBackup integration for repo_registry table"
  - "active_repo_ids/0 and top_active_repo/0 for scheduler filtering"
affects: [scheduler-repo-filtering, dashboard-repo-registry-ui, sidecar-workspace-switching, task-queue-nil-repo-inheritance]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "DETS single-key ordered list for atomic priority reordering"
    - "URL normalization (strip trailing / and .git) for consistent comparison"

key-files:
  created:
    - lib/agent_com/repo_registry.ex
  modified:
    - lib/agent_com/application.ex
    - lib/agent_com/dets_backup.ex
    - lib/agent_com/endpoint.ex
    - lib/agent_com/validation/schemas.ex
    - test/support/dets_helpers.ex

key-decisions:
  - "Single DETS key (:repos) storing ordered list for atomic reordering (no per-repo keys)"
  - "URL normalization strips trailing / and .git before storage and comparison"
  - "RepoRegistry placed in supervisor after LlmRegistry, before DashboardState"
  - "Compact handler added to RepoRegistry for DetsBackup compaction support"

# Metrics
duration: 3min
completed: 2026-02-12
---

# Phase 23 Plan 01: Repo Registry and HTTP Admin API Summary

**DETS-backed RepoRegistry GenServer with priority-ordered list, 7 HTTP admin routes, DetsBackup integration, and validation schema**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-12T11:43:48Z
- **Completed:** 2026-02-12T11:47:13Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- RepoRegistry GenServer with DETS persistence via single-key ordered list pattern
- Full CRUD API: add, remove, list repos with priority ordering
- Move-up/move-down priority reordering with atomic list swap
- Active/paused status toggling with PubSub broadcasts on all mutations
- 7 HTTP admin routes for complete repo registry management
- DetsBackup integration (10 tables now) with compaction support

## Task Commits

Each task was committed atomically:

1. **Task 1: RepoRegistry GenServer with DETS persistence and PubSub** - `67ef680` (feat)
2. **Task 2: Supervisor, DetsBackup, HTTP routes, validation, and test helpers** - `5e57abd` (feat)

## Files Created/Modified
- `lib/agent_com/repo_registry.ex` - GenServer with 10 public API functions, DETS persistence, URL normalization, PubSub broadcasts, compaction handler
- `lib/agent_com/application.ex` - RepoRegistry added to supervisor tree after LlmRegistry
- `lib/agent_com/dets_backup.ex` - :repo_registry added to @tables (10), table_owner, get_table_path clauses
- `lib/agent_com/endpoint.ex` - 7 HTTP admin routes for repo CRUD/reorder/pause, @dets_table_atoms updated
- `lib/agent_com/validation/schemas.ex` - post_repo schema (required: url, optional: name)
- `test/support/dets_helpers.ex` - repo_registry_data_dir config, subdirectory creation, restart cycle entry

## Decisions Made
- Single DETS key (:repos) storing ordered list -- atomic reordering without multi-key corruption risk
- URL normalization strips trailing / and .git before storage and comparison -- prevents mismatch between hub registry and task repo field
- RepoRegistry placed in supervisor after LlmRegistry, before DashboardState -- ensures registry is available when DashboardState takes snapshot
- Added compact handler to RepoRegistry for DetsBackup compaction support -- follows pattern from Config, Mailbox, MessageHistory

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added compact handler to RepoRegistry**
- **Found during:** Task 2 (DetsBackup integration)
- **Issue:** DetsBackup.compact_table/1 calls GenServer.call(owner, :compact) on single-table GenServers, but RepoRegistry had no :compact handler -- would crash on compaction
- **Fix:** Added handle_call(:compact, ...) that closes and reopens DETS with repair: :force, matching the pattern in Config, Mailbox, and MessageHistory
- **Files modified:** lib/agent_com/repo_registry.ex
- **Verification:** mix compile succeeds, handler matches existing pattern
- **Committed in:** 5e57abd (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Essential for DetsBackup integration correctness. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- RepoRegistry GenServer running in supervisor with full CRUD, reorder, and pause/unpause
- HTTP admin API ready for dashboard integration (Plan 02/03)
- active_repo_ids/0 and top_active_repo/0 ready for scheduler filtering integration
- DetsBackup includes repo_registry table for backup, compaction, and health checks

## Self-Check: PASSED

All 6 key files verified on disk. Both commit hashes (67ef680, 5e57abd) confirmed in git log.

---
*Phase: 23-multi-repo-registry-and-workspace-switching*
*Completed: 2026-02-12*
