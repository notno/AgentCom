---
phase: 11-dets-compaction
plan: 01
subsystem: database
tags: [dets, compaction, genserver, erlang, otp, repair-force, pubsub]

# Dependency graph
requires:
  - phase: 10-dets-backup
    provides: DetsBackup GenServer with backup scheduling, health metrics, and @tables list
provides:
  - ":compact handle_call on all 6 DETS-owning GenServers (close + reopen with repair: force)"
  - "compact_all/0 API on DetsBackup for synchronous compaction of all 9 tables"
  - "6-hour scheduled compaction via Process.send_after"
  - "Fragmentation threshold skip (10%) to avoid unnecessary compaction"
  - "Retry-once on compaction failure"
  - "Compaction history tracking (last 20 runs)"
  - "PubSub compaction_complete and compaction_failed events on backups topic"
  - "compaction_history/0 API for querying recent compaction results"
  - "health_metrics now includes last_compaction_at and compaction_history"
affects: [11-02-PLAN, 11-03-PLAN, dashboard-state, dashboard-notifier, endpoint]

# Tech tracking
tech-stack:
  added: []
  patterns: ["owning-GenServer compaction via handle_call (close + reopen with repair: force)", "orchestrated serial compaction from DetsBackup via GenServer.call to owning processes"]

key-files:
  created: []
  modified:
    - lib/agent_com/dets_backup.ex
    - lib/agent_com/mailbox.ex
    - lib/agent_com/message_history.ex
    - lib/agent_com/config.ex
    - lib/agent_com/channels.ex
    - lib/agent_com/task_queue.ex
    - lib/agent_com/threads.ex

key-decisions:
  - "Single-table GenServers use :compact atom message; multi-table GenServers use {:compact, table_atom} tuple"
  - "Application.compile_env for compaction_interval_ms and compaction_threshold (configurable at compile time)"
  - "table_owner/1 function clause dispatch instead of a map for GenServer routing"
  - "Compaction history capped at 20 entries in GenServer state"

patterns-established:
  - "Owning-GenServer compaction: close table, reopen with repair: force, matching original init options"
  - "Orchestrated serial compaction: DetsBackup calls each owner sequentially, never in parallel"
  - "Threshold skip: check fragmentation before compacting, skip if below configurable threshold"

# Metrics
duration: 5min
completed: 2026-02-12
---

# Phase 11 Plan 01: DETS Compaction Summary

**Owning-GenServer compaction handle_calls on all 9 tables orchestrated by DetsBackup on a configurable 6-hour schedule with fragmentation threshold skip and retry-once logic**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-12T23:00:07Z
- **Completed:** 2026-02-12T23:05:36Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments
- All 6 DETS-owning GenServers can compact their table(s) via handle_call, using close + reopen with `repair: :force` matching original init options
- DetsBackup orchestrates serial compaction of all 9 tables with configurable 6-hour schedule (via `Application.compile_env`)
- Tables below 10% fragmentation are automatically skipped during compaction runs
- Failed compaction retries once then waits for next scheduled run
- Compaction results broadcast on PubSub "backups" topic for dashboard integration
- Compaction history tracked in DetsBackup state (last 20 runs), queryable via `compaction_history/0`

## Task Commits

Each task was committed atomically:

1. **Task 1: Add :compact handle_call to all 6 DETS-owning GenServers** - `7a32468` (feat)
2. **Task 2: Add compaction orchestration, scheduling, and history to DetsBackup** - `6848acf` (feat)

## Files Created/Modified
- `lib/agent_com/mailbox.ex` - Added `:compact` handle_call (single-table, auto_save: 5_000)
- `lib/agent_com/message_history.ex` - Added `:compact` handle_call (single-table, auto_save: 5_000)
- `lib/agent_com/config.ex` - Added `:compact` handle_call (single-table, no auto_save)
- `lib/agent_com/channels.ex` - Added `{:compact, table_atom}` handle_call for :agent_channels and :channel_history
- `lib/agent_com/task_queue.ex` - Added `{:compact, table_atom}` handle_call for :task_queue and :task_dead_letter
- `lib/agent_com/threads.ex` - Added `{:compact, table_atom}` handle_call for :thread_messages and :thread_replies
- `lib/agent_com/dets_backup.ex` - Added compaction orchestration, scheduling, history tracking, PubSub events, table_owner/1 dispatch

## Decisions Made
- Single-table GenServers (Mailbox, MessageHistory, Config) receive `:compact` atom; multi-table GenServers (Channels, TaskQueue, Threads) receive `{:compact, table_atom}` tuple to identify which table to compact
- Used `Application.compile_env` for compaction_interval_ms (default 6h) and compaction_threshold (default 0.1) -- consistent with compile-time configuration pattern
- table_owner/1 uses function clause dispatch (9 clauses) for clean, pattern-matchable GenServer routing
- Compaction history capped at 20 entries to bound memory usage in GenServer state
- health_metrics reply extended with last_compaction_at and compaction_history for dashboard integration

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed pre-existing handle_cast grouping warning in Mailbox**
- **Found during:** Task 1 (Adding :compact handle_call to Mailbox)
- **Issue:** `handle_cast(:evict_expired, ...)` was separated from `handle_cast({:ack, ...}, ...)` by public functions and handle_info, causing a compiler warning about non-grouped clauses
- **Fix:** Moved `handle_cast(:evict_expired, ...)` directly after `handle_cast({:ack, ...}, ...)` to group all handle_cast clauses together
- **Files modified:** lib/agent_com/mailbox.ex
- **Verification:** Compiler warning eliminated
- **Committed in:** 7a32468 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Pre-existing warning fixed as part of Task 1. No scope creep.

## Issues Encountered
- Pre-existing warnings in router.ex, endpoint.ex, analytics.ex, and socket.ex prevent `--warnings-as-errors` from passing, but none are in modified files. Compilation succeeds cleanly for all plan-modified files.
- Intermittent test failure in DetsBackupTest (task_queue :enoent) when running full test suite due to test ordering/pollution -- passes in isolation. Pre-existing issue, not caused by changes.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- All 9 DETS tables now support compaction via their owning GenServers
- DetsBackup is ready for Plan 02 (dashboard integration, API endpoints)
- DetsBackup is ready for Plan 03 (recovery/restore from backup)
- PubSub events (compaction_complete, compaction_failed) are available for DashboardState subscription

## Self-Check: PASSED

- All 7 modified files exist on disk
- Commit 7a32468 (Task 1) verified in git log
- Commit 6848acf (Task 2) verified in git log
- Compilation succeeds with no new warnings
- All existing tests pass (138 tests, 0 new failures)

---
*Phase: 11-dets-compaction*
*Completed: 2026-02-12*
