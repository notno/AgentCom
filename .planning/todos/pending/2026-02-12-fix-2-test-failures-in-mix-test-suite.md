---
created: 2026-02-12T12:30:00Z
title: Fix 2 test failures in mix test suite
area: testing
files:
  - test/dets_backup_test.exs:20-26
  - test/integration/failure_paths_test.exs:140-162,225
---

## Problem

`mix test --exclude smoke --exclude skip` reports 2 failures out of 279 tests:

### 1. DetsBackupTest — backup_all creates backup files and returns results
- File: test/dets_backup_test.exs:20
- Error: `{:error, %{reason: :enoent, table: :task_queue}}` instead of `{:ok, info}`
- Likely cause: DETS table `:task_queue` not opened/initialized in test setup. The backup tries to sync/copy a table file that doesn't exist in the test environment.

### 2. FailurePathsTest — agent crash during task execution causes task reclaim
- File: test/integration/failure_paths_test.exs:140
- Error: `(exit) exited in: GenServer.call(#PID<0.4135.0>, :get_state, 5000) ** (EXIT) normal`
- Occurs in `wait_for_fsm_gone/2` (line 225) — polling for FSM process to terminate, but the GenServer exits normally before the poll completes.
- Likely cause: Race condition — FSM terminates between the alive? check and the GenServer.call.

### Also noted: test file pattern warnings
Several helper/support files don't match `:test_load_filters` — harmless but noisy. Could be silenced by adjusting test config patterns.

## Solution

1. **DetsBackupTest**: Ensure test setup opens (or mocks) the required DETS tables before calling backup_all. May need DetsHelpers to initialize all expected tables.
2. **FailurePathsTest**: Use `Process.alive?` check before `GenServer.call` in `do_poll_fsm_gone`, or rescue the exit and treat it as "gone." The FSM disappearing is the success condition.
3. **Warnings**: Add `test_load_filters` or rename files to suppress pattern warnings (low priority).
