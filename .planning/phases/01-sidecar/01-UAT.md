---
status: complete
phase: 01-sidecar
source: [01-01-SUMMARY.md, 01-02-SUMMARY.md, 01-03-SUMMARY.md, 01-04-SUMMARY.md]
started: 2026-02-09T23:00:00Z
updated: 2026-02-10T00:50:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Sidecar Starts and Connects to Hub
expected: Copy config.json.example to config.json with valid credentials. Run `node sidecar/index.js`. Console shows startup and "identified" event. Hub presence shows agent connected.
result: pass

### 2. Config Missing Error
expected: Delete or rename config.json. Run `node sidecar/index.js`. Should print a helpful error message pointing to config.json.example and exit with code 1 (not a crash/stacktrace).
result: pass

### 3. Reconnect with Exponential Backoff
expected: Start sidecar connected to hub. Stop the hub (Ctrl+C the mix process). Sidecar should log reconnect attempts with increasing delays: ~1s, ~2s, ~4s, ~8s... Restart the hub. Sidecar should reconnect and re-identify automatically.
result: pass

### 4. Graceful Shutdown
expected: Start sidecar connected to hub. Press Ctrl+C. Sidecar should log a "shutdown" event and exit cleanly (exit code 0, no error stacktrace). Hub presence should show agent disconnected.
result: pass

### 5. Push Task to Sidecar via Admin Endpoint
expected: With hub running and sidecar connected, POST to /api/admin/push-task with agent_id and description. Should return JSON with status "pushed" and a generated task_id. Sidecar console should show task received.
result: pass

### 6. Task Persisted to queue.json
expected: After pushing a task, check sidecar/queue.json. Should contain the task with task_id, description, and status. File should be valid JSON.
result: pass

### 7. Sidecar Rejects Task When Busy
expected: While a task is active, push another task. Sidecar should log "task_rejected" with reason "busy". The new task should NOT appear in queue.json.
result: pass

### 8. Wake Command Executes
expected: Set wake_command to observable echo command. Push a task. Sidecar should log wake attempt. Task status in queue.json should progress to "waking".
result: pass

### 9. Crash Recovery Reports to Hub
expected: Push a task so queue.json has an active task. Kill sidecar process. Restart sidecar. Should log "recovery_found", then "recovery_reported" after connecting. Hub should show task_recovering message.
result: pass

### 10. pm2 Starts and Auto-Restarts Sidecar
expected: pm2 start ecosystem.config.js. pm2 status shows agentcom-sidecar as online. Kill node process, pm2 auto-restarts it.
result: pass

### 11. Hub Compiles Without Errors
expected: mix compile from repo root succeeds without errors. Existing functionality works alongside new task protocol handlers.
result: pass

## Summary

total: 11
passed: 11
issues: 0
pending: 0
skipped: 0

## Gaps

[none]
