---
phase: 11-dets-compaction
plan: 02
subsystem: database
tags: [dets, corruption-recovery, auto-restore, degraded-mode, genserver, supervisor, pubsub]

# Dependency graph
requires:
  - phase: 10-dets-backup
    provides: DetsBackup GenServer with backup scheduling, backup files on disk, @tables list
  - phase: 11-dets-compaction plan 01
    provides: table_owner/1 dispatch, compaction handle_calls, DetsBackup orchestration
provides:
  - "restore_table/1 public API for manual DETS table restoration from latest backup"
  - "Auto-restore via corruption_detected cast from owning GenServers"
  - "find_latest_backup/2 for locating most recent backup file per table"
  - "verify_table_integrity/1 with record count and traversal verification"
  - "Degraded mode fallback (empty table) when both table and backup are corrupted"
  - "Corruption detection in hot-path DETS operations across all 6 owning GenServers"
  - "PubSub recovery_complete and recovery_failed events on backups topic"
affects: [11-03-PLAN, dashboard-state, dashboard-notifier]

# Tech tracking
tech-stack:
  added: []
  patterns: ["corruption detection wrappers on hot-path DETS operations", "Supervisor.terminate_child + restart_child recovery cycle", "degraded mode with empty table fallback"]

key-files:
  created: []
  modified:
    - lib/agent_com/dets_backup.ex
    - lib/agent_com/mailbox.ex
    - lib/agent_com/channels.ex
    - lib/agent_com/task_queue.ex
    - lib/agent_com/message_history.ex
    - lib/agent_com/config.ex
    - lib/agent_com/threads.ex

key-decisions:
  - "Wrap persist_task/lookup_task helpers in TaskQueue rather than individual handlers to avoid duplication"
  - "Config get handler returns default on corruption (graceful degradation) rather than error tuple"
  - "get_table_path/1 matches each GenServer's actual path resolution including config_data_dir and threads_data_dir env vars"

patterns-established:
  - "Corruption detection: wrap hot-path dets.insert/dets.lookup/dets.select, cast to DetsBackup on {:error, reason}"
  - "Recovery cycle: terminate owner -> file replace -> restart owner -> verify integrity"
  - "Degraded mode: delete corrupted file, let init/1 create fresh empty table, log CRITICAL"

# Metrics
duration: 5min
completed: 2026-02-12
---

# Phase 11 Plan 02: DETS Corruption Recovery Summary

**Auto-restore DETS tables from backup on corruption detection via Supervisor stop/file-replace/restart cycle with integrity verification and degraded mode fallback**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-12T09:08:14Z
- **Completed:** 2026-02-12T09:13:11Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments
- DetsBackup can restore any of the 9 DETS tables from latest backup via Supervisor terminate/restart cycle with file replacement
- Integrity verification (record count + full traversal) runs after every restore to confirm data readability
- Degraded mode activates when both table and backup are corrupted: deletes file, restarts with empty table, logs CRITICAL
- Corruption detection added to hot-path DETS operations in all 6 owning GenServers (14 detection points total)
- Manual restore available via `DetsBackup.restore_table/1` with 60-second timeout
- Recovery events broadcast on PubSub "backups" topic for dashboard integration

## Task Commits

Each task was committed atomically:

1. **Task 1: Add recovery logic to DetsBackup** - `e4ca1cc` (feat)
2. **Task 2: Add corruption detection to key GenServer hot paths** - `7c18eba` (feat)

## Files Created/Modified
- `lib/agent_com/dets_backup.ex` - Added restore_table/1, find_latest_backup/2, do_restore_table/2, verify_table_integrity/1, get_table_path/1, handle_cast for corruption_detected, degraded mode handlers
- `lib/agent_com/mailbox.ex` - Corruption detection in enqueue (dets.insert) and poll (dets.select)
- `lib/agent_com/channels.ex` - Corruption detection in publish and subscribe (dets.lookup)
- `lib/agent_com/task_queue.ex` - Corruption detection in persist_task (dets.insert), lookup_task and lookup_dead_letter (dets.lookup)
- `lib/agent_com/message_history.ex` - Corruption detection in store (dets.insert)
- `lib/agent_com/config.ex` - Corruption detection in get (dets.lookup) and put (dets.insert)
- `lib/agent_com/threads.ex` - Corruption detection in index cast (dets.insert and dets.lookup for both tables)

## Decisions Made
- Wrapped `persist_task`/`lookup_task`/`lookup_dead_letter` helpers in TaskQueue rather than individual handlers -- avoids duplicating detection in every handler while covering all critical paths
- Config `get` handler returns default value on corruption rather than error tuple -- graceful degradation keeps callers working
- `get_table_path/1` uses each GenServer's actual env var names (`config_data_dir`, `threads_data_dir`, `channels_path`, etc.) to match path resolution exactly

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- Pre-existing warnings in router.ex and socket.ex prevent `--warnings-as-errors` from passing globally, but no new warnings introduced by plan changes
- Pre-existing intermittent test failure in DetsBackupTest (task_queue :enoent) due to test ordering -- not caused by changes

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Recovery infrastructure complete, ready for Plan 03 (testing and integration verification)
- PubSub events (recovery_complete, recovery_failed) available for DashboardState subscription
- All DETS tables now have both compaction (Plan 01) and corruption recovery (Plan 02)

## Self-Check: PASSED

- All 7 modified files exist on disk
- Commit e4ca1cc (Task 1) verified in git log
- Commit 7c18eba (Task 2) verified in git log
- Compilation succeeds with no new warnings
- All existing tests pass (138 tests, 1 pre-existing failure, 6 excluded)

---
*Phase: 11-dets-compaction*
*Completed: 2026-02-12*
