---
phase: 01-sidecar
plan: 03
subsystem: sidecar
tags: [websocket, node, task-lifecycle, queue, chokidar, child-process, wake-command, file-watcher]

# Dependency graph
requires:
  - phase: 01-sidecar
    plan: 01
    provides: "HubConnection class with WebSocket connect, identify, reconnect, heartbeat, logging, config loader"
  - phase: 01-sidecar
    plan: 02
    provides: "Hub-side task_assign push, task lifecycle message handlers (task_accepted, task_complete, task_failed)"
provides:
  - "Queue manager with atomic persistence to queue.json via write-file-atomic"
  - "task_assign handler: accept when idle, reject when busy, persist-before-ack pattern"
  - "Task lifecycle senders: sendTaskAccepted, sendTaskComplete, sendTaskFailed, sendTaskRejected"
  - "Wake command execution with template variable interpolation (TASK_ID, TASK_JSON, TASK_DESCRIPTION)"
  - "Wake retry logic: 3 attempts at 5s/15s/30s backoff, then task_failed to hub"
  - "Confirmation timeout: 30s wait for .started file after successful wake"
  - "Chokidar result file watcher for .started (confirmation) and .json (result) files"
  - "Task status flow: accepted -> waking -> waking_confirmation -> working -> removed"
affects: [01-04, 02-task-queue, 05-smoke-test]

# Tech tracking
tech-stack:
  added: []
  patterns: [atomic-queue-persistence, wake-command-with-retry, result-file-watching, persist-before-ack]

key-files:
  created: []
  modified:
    - sidecar/index.js

key-decisions:
  - "Persist task to queue.json BEFORE sending task_accepted to hub (crash-safe ordering)"
  - "Wake command skipped gracefully when wake_command not configured (agent self-start mode)"
  - "Confirmation timeout treated as failure (not retry) to avoid infinite wake loops"
  - "Result file cleanup happens after hub notification (not before) to prevent data loss"

patterns-established:
  - "Persist-before-ack: always write to disk before confirming receipt to remote system"
  - "Template interpolation: ${TASK_ID}, ${TASK_JSON}, ${TASK_DESCRIPTION} in wake command"
  - "File-based agent communication: .started for confirmation, .json for results"
  - "Status flow tracking: each task status transition persisted to queue.json"

# Metrics
duration: 11min
completed: 2026-02-10
---

# Phase 1 Plan 3: Task Lifecycle Handling Summary

**Atomic queue persistence with write-file-atomic, configurable wake command with 3x retry at 5s/15s/30s, chokidar result file watching for .started confirmation and .json results, and task_complete/task_failed reporting to hub**

## Performance

- **Duration:** 11 min
- **Started:** 2026-02-10T05:56:46Z
- **Completed:** 2026-02-10T06:08:10Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- Queue manager with atomic persistence to queue.json using write-file-atomic; loads on startup for crash recovery, saves on shutdown
- task_assign handler that persists BEFORE acknowledging (crash-safe), rejects when busy with reason sent to hub
- Wake command execution with template variable interpolation, cross-platform shell support (shell: true, windowsHide: true)
- Retry logic: 3 attempts with 5s/15s/30s backoff delays, then task_failed with "wake_failed_after_3_attempts" reason
- Confirmation timeout: waits 30s (configurable) for .started file from agent, fails task on timeout
- Chokidar file watcher on results directory with awaitWriteFinish (500ms stability threshold) for .started and .json files
- Task lifecycle sender methods on HubConnection for all task message types
- Full task status flow: accepted -> waking -> waking_confirmation -> working -> removed from queue

## Task Commits

Each task was committed atomically:

1. **Task 1: Add queue manager and task_assign handler** - `a8cae2d` (feat)
2. **Task 2: Add wake command execution with retry and result file watching** - `0cb1f05` (feat)

**Plan metadata:** (pending final commit)

## Files Created/Modified
- `sidecar/index.js` - Extended from 328 to 718 lines: queue manager, wake command execution with retry, result file watcher, task lifecycle senders, confirmation timeout handling

## Decisions Made
- Persist task to queue.json BEFORE sending task_accepted to hub -- if crash occurs between accept and persist, the task is lost from sidecar perspective; persist-first ensures hub acknowledgment reflects actual persisted state
- Wake command skipped gracefully when wake_command is not configured in config.json -- allows agents that self-start to still use the sidecar for queue management without a wake step
- Confirmation timeout treated as terminal failure (sends task_failed to hub) rather than triggering additional retries -- prevents infinite wake loops when agent is fundamentally unable to start
- Result file cleanup (unlink) happens after hub notification (sendTaskComplete/sendTaskFailed) -- ensures result data is not lost if hub notification fails

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Full task lifecycle is implemented: receive -> persist -> wake -> confirm -> watch -> report -> cleanup
- Recovery behavior (Plan 04) can now build on the queue.active/recovering data model and the established status flow
- The result file watcher is running from startup, ready for any agent runtime that writes .started and .json files
- Hub-side handlers (Plan 02) are already in place for all message types the sidecar now sends

## Self-Check: PASSED

- [x] sidecar/index.js exists (718 lines)
- [x] Commit a8cae2d found (Task 1)
- [x] Commit 0cb1f05 found (Task 2)
- [x] writeFileAtomic pattern present in index.js
- [x] chokidar.watch pattern present in index.js
- [x] RETRY_DELAYS = [5000, 15000, 30000] present
- [x] task_assign handler present
- [x] All imports resolve (ws, write-file-atomic, child_process, chokidar)
- [x] Syntax check passes (node -c)

---
*Phase: 01-sidecar*
*Completed: 2026-02-10*
