# Troubleshooting

This guide is organized by **what you see** (the symptom), not by what component broke. Find the symptom that matches your situation, follow the diagnosis steps, and apply the fix. Each entry includes the relevant log lines and `jq` queries inline so you can diagnose without switching between documents.

For background on how the system's components interact, see the [architecture overview](architecture.md). For understanding metrics and alert meanings, see the [daily operations guide](daily-operations.md).

## How to Use This Guide

1. **Find your symptom** in the headings below. Symptoms are grouped by priority: HIGH (system-impacting), MEDIUM (degraded functionality), LOW (cosmetic or minor).
2. **Follow the diagnosis steps** in order. Each step narrows the cause.
3. **Apply the fix.** Each entry ends with the corrective action and a cross-reference to the relevant module docs for deeper investigation.

## HIGH Priority Failures

These affect core task processing or data integrity. Address immediately.

### Tasks Stuck in Pending

**What you see:** Tasks show "queued" on the dashboard indefinitely and are never assigned to any agent. The queue depth grows but no tasks transition to "assigned" status.

**Why this happens:** The `AgentCom.Scheduler` needs both queued tasks AND idle agents to make assignments. If either is missing, tasks sit in the queue. The Scheduler also checks capability matching -- a task with `needed_capabilities` that no agent declares will never be assigned even if agents are idle.

**Diagnosis steps:**

1. **Check agent availability.** Are any agents connected and idle?

   ```bash
   curl http://localhost:4000/api/agents
   ```

   Look for agents with `fsm_state: "idle"`. If none are idle, all agents are either working, offline, or not connected.

2. **Check capability match.** Compare the task's `needed_capabilities` with each agent's `capabilities`.

   ```bash
   curl http://localhost:4000/api/tasks?status=queued
   ```

   If tasks require capabilities like `["code_review"]` but no connected agent declares that capability, tasks will queue forever.

3. **Check scheduler logs.** Look at what the Scheduler sees on each attempt:

   ```bash
   jq 'select(.telemetry_event == "agent_com.scheduler.attempt") | {idle: .measurements.idle_agents, queued: .measurements.queued_tasks}' priv/logs/agent_com.log
   ```

   If `idle_agents` is consistently 0, the problem is agent availability -- see "Agent Shows Offline" below. If `idle_agents > 0` but tasks are not assigned, it is a capability mismatch or the Scheduler process may need restart.

4. **Check if Scheduler is running.** In rare cases (crash without supervisor restart), the Scheduler may not be running:

   ```bash
   jq 'select(.telemetry_event == "agent_com.scheduler.attempt")' priv/logs/agent_com.log | tail -5
   ```

   If there are no recent scheduler attempt entries, the Scheduler may be stuck.

**Fix:** Connect more agents with the required capabilities. Fix capability declarations in agent `config.json`. If the Scheduler appears stuck, restart the hub (`Ctrl+C` in iex, then `iex -S mix`).

See `AgentCom.Scheduler` for scheduling logic and capability matching.

### Agent Shows Offline / Keeps Disconnecting

**What you see:** An agent appears briefly on the dashboard and then disappears, or never appears at all. The agent count fluctuates, and the sidecar may report connection errors.

**Why this happens:** Multiple possible causes spanning authentication, network, process lifecycle, and heartbeat timeouts. The hub's `AgentCom.Reaper` evicts agents whose heartbeat is stale for more than 60 seconds.

**Diagnosis steps:**

1. **Check sidecar is running:**

   ```bash
   pm2 list
   ```

   Look for `agentcom-<name>` and its status. If it shows "errored" or "stopped", the sidecar process crashed.

2. **Check sidecar logs for connection errors:**

   ```bash
   pm2 logs agentcom-<name>
   ```

   Or check the sidecar log file directly:

   ```bash
   jq 'select(.level == "error")' ~/.agentcom/<name>/sidecar.log
   ```

3. **Check for authentication errors:**

   ```bash
   jq 'select(.type == "error" and .error == "invalid_token")' ~/.agentcom/<name>/sidecar.log
   ```

   If you see `invalid_token`, the sidecar's token does not match what the hub has in `priv/tokens.json`. Re-register the agent or update the sidecar's `config.json`.

4. **Check for Reaper eviction** (stale heartbeat -- agent connected but stopped sending pings):

   ```bash
   jq 'select(.message == "reaper_evict_stale") | {agent: .agent_id, stale_ms: .stale_ms}' priv/logs/agent_com.log
   ```

   If you see evictions with `stale_ms` over 60000, the sidecar is connected but not sending heartbeat pings. This usually means the sidecar process is alive but the event loop is blocked (hung wake command, CPU-bound operation, or network issue between sidecar and hub).

5. **Check for WebSocket close reasons** on the hub side:

   ```bash
   jq 'select(.telemetry_event == "agent_com.agent.disconnect") | {agent: .metadata.agent_id, reason: .metadata.reason}' priv/logs/agent_com.log
   ```

**Fix:** Restart sidecar (`pm2 restart agentcom-<name>`). If token error, re-register the agent (`node sidecar/add-agent.js --hub http://localhost:4000 --name <name>`) or fix the token in `~/.agentcom/<name>/config.json`. If the agent's config was lost entirely (machine reimaged, moved to new machine), use `--rejoin` to re-provision without re-registering:

```bash
node sidecar/add-agent.js --hub http://localhost:4000 --name <name> --rejoin --token <token>
```

This skips registration (avoids the 409 conflict) and sets up the sidecar fresh with the existing token. See the [setup guide](setup.md#reconnecting-an-existing-agent) for details on finding your token.

If Reaper eviction, check whether the sidecar process is blocked or network connectivity is intermittent.

See `AgentCom.Auth`, `AgentCom.Reaper`, `AgentCom.Presence` for authentication, eviction, and presence tracking.

### DETS Corruption / Table Unavailable

**What you see:** API calls return errors for task or message operations, the dashboard shows errors or missing data, and the hub logs contain DETS read/write errors.

**Why this happens:** DETS files can become corrupted from unclean shutdown (kill -9, power loss), disk full conditions, or concurrent non-OTP access to `.dets` files. DETS is an Erlang built-in disk storage -- it is reliable under normal OTP shutdown but does not have write-ahead logging, so abrupt termination can leave files in an inconsistent state.

**All 9 DETS tables** (any can be affected independently):

| Table | Owner Module | Purpose |
|-------|-------------|---------|
| `task_queue` | `AgentCom.TaskQueue` | Active tasks (queued, assigned, completed) |
| `task_dead_letter` | `AgentCom.TaskQueue` | Failed tasks that exhausted retries |
| `agent_mailbox` | `AgentCom.Mailbox` | Per-agent message mailbox |
| `message_history` | `AgentCom.MessageHistory` | Queryable message archive |
| `agent_channels` | `AgentCom.Channels` | Channel metadata and subscriptions |
| `channel_history` | `AgentCom.Channels` | Channel message history |
| `agentcom_config` | `AgentCom.Config` | Runtime key-value configuration |
| `thread_messages` | `AgentCom.Threads` | Thread message tracking |
| `thread_replies` | `AgentCom.Threads` | Thread reply chains |

**Diagnosis steps:**

1. **Check DETS health via API:**

   ```bash
   curl http://localhost:4000/api/admin/dets-health \
     -H "Authorization: Bearer <token>"
   ```

   Look for tables with `status: "unavailable"` or error states.

2. **Check hub logs for corruption events:**

   ```bash
   jq 'select(.message == "dets_corruption_detected") | {table: .table, action: .action}' priv/logs/agent_com.log
   ```

3. **Check auto-restore results.** `AgentCom.DetsBackup` automatically detects corruption (via `{:corruption_detected, table, reason}` casts) and attempts to restore from the latest backup:

   ```bash
   jq 'select(.message | test("dets_auto_restore"))' priv/logs/agent_com.log
   ```

   If you see `dets_auto_restore_complete`, the table was automatically recovered. If you see `dets_auto_restore_failed`, manual intervention is needed.

**Manual recovery:**

1. **Restore from backup:**

   ```bash
   curl -X POST http://localhost:4000/api/admin/restore/task_queue \
     -H "Authorization: Bearer <token>"
   ```

   Replace `task_queue` with the affected table name. This stops the owning GenServer, replaces the corrupted file with the latest backup, restarts the GenServer, and verifies data integrity.

2. **If no backup exists:** `AgentCom.DetsBackup` enters degraded mode -- it deletes the corrupted file, and the GenServer restarts with an empty table. Data is lost, but the system continues operating. You will see this in logs:

   ```bash
   jq 'select(.message == "dets_degraded_mode")' priv/logs/agent_com.log
   ```

3. **Verify recovery:**

   ```bash
   curl http://localhost:4000/api/admin/dets-health \
     -H "Authorization: Bearer <token>"
   ```

   All tables should show `status: "ok"`.

**Prevention:** Always shut down the hub cleanly (`Ctrl+C` in iex, or `System.stop()` in the REPL). Regular backups happen automatically (daily), but verify via the health endpoint that `last_backup_at` is recent.

See `AgentCom.DetsBackup` for backup, restore, and auto-recovery logic.

### Queue Backlog Growing

**What you see:** The `queue_growing` alert fires. The queue depth metric on the Metrics tab shows a sustained upward trend. The dashboard header shows an increasing "Queued" count.

**Why this happens:** Task inflow exceeds agent processing capacity. This can be because agents are saturated, agents are offline, or tasks are failing and consuming retry capacity.

**Diagnosis steps:**

1. **Check current metrics:**

   ```bash
   curl http://localhost:4000/api/metrics
   ```

   Look at `queue_depth.current` (how many waiting now) and `queue_depth.trend` (recent history). A sustained upward trend confirms the backlog.

2. **Check agent utilization.** Are all agents working at maximum capacity?

   ```bash
   curl http://localhost:4000/api/agents
   ```

   If all agents show `fsm_state: "working"` or `"assigned"`, they are saturated.

3. **Check failure rate.** Are tasks failing and retrying, consuming agent time without completing work?

   ```bash
   jq 'select(.telemetry_event == "agent_com.task.complete" or .telemetry_event == "agent_com.task.fail") | {event: .telemetry_event, task: .metadata.task_id}' priv/logs/agent_com.log | tail -20
   ```

   If you see a high ratio of `task.fail` to `task.complete`, failing tasks are the bottleneck.

4. **Check dead letter queue growth:**

   ```bash
   curl http://localhost:4000/api/tasks/dead-letter \
     -H "Authorization: Bearer <token>"
   ```

   Growing dead letter means tasks are exhausting retries. Fix the root cause before the failure rate overwhelms processing.

**Fix:** Add more agents (`node sidecar/add-agent.js --hub http://localhost:4000 --name new-agent`). Fix failing wake commands to reduce wasted retries. Reduce task submission rate if the system is overloaded. Consider adjusting task priorities so critical tasks are processed first.

See `AgentCom.MetricsCollector` for metric definitions and `AgentCom.Scheduler` for scheduling.

## MEDIUM Priority Failures

These degrade functionality but the system continues operating.

### Stuck Tasks (Assigned but Not Completing)

**What you see:** The `stuck_tasks` alert fires (CRITICAL severity). Tasks show "assigned" status on the dashboard for more than 5 minutes without transitioning to "completed" or "failed".

**Why this happens:** An agent's sidecar accepted the task but the wake command is hung, crashing silently, or the sidecar lost its WebSocket connection after accepting the assignment. The agent FSM is in "working" state but no completion message ever arrives.

**Diagnosis steps:**

1. **Identify the stuck task and assigned agent:**

   ```bash
   curl "http://localhost:4000/api/tasks?status=assigned" \
     -H "Authorization: Bearer <token>"
   ```

   Note the `agent_id` for each stuck task.

2. **Check the assigned agent's sidecar logs:**

   ```bash
   pm2 logs agentcom-<agent-name>
   ```

   Look for wake command output, errors, or hung processes.

3. **Check agent FSM state:**

   ```bash
   curl http://localhost:4000/api/agents
   ```

   Look for the agent's `fsm_state`. If it shows "working" for an extended period, the sidecar is not reporting back.

4. **Wait for automatic reclaim.** The Scheduler's 30-second sweep automatically reclaims tasks assigned for longer than 5 minutes (configurable via `stuck_task_ms` alert threshold). The task will be re-queued and assigned to another agent.

   ```bash
   jq 'select(.telemetry_event == "agent_com.task.reclaim") | {task: .metadata.task_id, agent: .metadata.agent_id}' priv/logs/agent_com.log
   ```

**Fix:** Wait for auto-reclaim (it will happen within the next sweep cycle). If the agent is consistently stuck, restart its sidecar (`pm2 restart agentcom-<name>`). If the wake command is consistently failing, fix the command in the agent's `config.json`.

See `AgentCom.Scheduler` for reclaim logic and `AgentCom.AgentFSM` for state machine transitions.

### High Failure Rate

**What you see:** The `high_failure_rate` or `high_error_rate` alert fires. The dead letter queue grows on the dashboard. The error rate chart on the Metrics tab shows elevated values.

**Why this happens:** Wake commands are broken, agents are producing invalid results, or an external dependency that agents rely on is down. When a task fails, it retries up to 3 times before moving to dead letter.

**Diagnosis steps:**

1. **Check dead letter queue for common error patterns:**

   ```bash
   curl http://localhost:4000/api/tasks/dead-letter \
     -H "Authorization: Bearer <token>"
   ```

   Look at the `last_error` field. Are all errors the same? That indicates a systemic issue. Are errors different per agent? That indicates an agent-specific problem.

2. **Check sidecar logs for wake command failures:**

   ```bash
   jq 'select(.message | test("wake.*error|wake.*fail"))' ~/.agentcom/<name>/sidecar.log
   ```

   Look for exit codes, stderr output, or timeout messages.

3. **Check error distribution.** Is it one agent failing or all of them?

   ```bash
   jq 'select(.telemetry_event == "agent_com.task.fail") | .metadata.agent_id' priv/logs/agent_com.log | sort | uniq -c | sort -rn
   ```

   This shows which agents have the most failures.

**Fix:** Fix the root cause in the wake command or agent configuration. Once fixed, retry dead-letter tasks from the dashboard (click "Retry" button) or via API:

```bash
curl -X POST http://localhost:4000/api/tasks/<task_id>/retry \
  -H "Authorization: Bearer <token>"
```

See `AgentCom.TaskQueue` for task lifecycle and dead letter management.

### Dashboard Not Updating

**What you see:** The dashboard shows stale data. The connection dot in the connection bar shows "Disconnected" (red, pulsing). Metrics charts stop updating.

**Why this happens:** The browser's WebSocket connection to `/ws/dashboard` was lost. This can be caused by a proxy or firewall terminating idle WebSocket connections, the hub crashing, or `AgentCom.DashboardState` not broadcasting updates.

**Diagnosis steps:**

1. **Check browser console** (F12 -> Console tab) for WebSocket errors. Common errors include "WebSocket connection to ws://... failed" or CORS issues.

2. **Check if the hub is alive:**

   ```bash
   curl http://localhost:4000/health
   ```

   If this returns `{"status":"ok","agents_connected":N}`, the hub is running. The WebSocket connection may just need a page refresh.

3. **If health check fails**, the hub is down. Check for a crash dump:

   ```bash
   ls -la erl_crash.dump
   ```

   If present, the BEAM VM crashed (usually out of memory or a fatal error). Check the dump for the crash reason.

4. **If health returns OK but dashboard is stale**, try refreshing the page. The dashboard auto-reconnects with exponential backoff, but a manual refresh forces an immediate new connection and full state snapshot.

**Fix:** Refresh the browser. If the hub crashed, restart with `iex -S mix` and examine the crash dump for root cause (OOM, disk full, or other BEAM-level errors).

See `AgentCom.DashboardSocket` for WebSocket connection handling and `AgentCom.DashboardState` for state broadcasting.

## LOW Priority Failures

These are inconveniences that do not affect core task processing.

### Logs Not Appearing or Wrong Format

**What you see:** The log file at `priv/logs/agent_com.log` is empty, not in JSON format, or is missing expected fields like `metadata.module` or `telemetry_event`.

**Diagnosis:**

1. Check if the `priv/logs/` directory exists. It is created on application startup. If missing, the hub may not have started correctly.

2. Check `config/config.exs` for the logger configuration. LoggerJSON must be configured as a formatter.

3. Check the current log level. If set too high (e.g., `error`), info and warning messages are suppressed. Set to debug for maximum verbosity:

   ```bash
   curl -X PUT http://localhost:4000/api/admin/log-level \
     -H "Authorization: Bearer <token>" \
     -H "Content-Type: application/json" \
     -d '{"level":"debug"}'
   ```

**Fix:** Restart the hub (`iex -S mix`). This creates `priv/logs/` if missing and reinitializes the logger. Verify LoggerJSON is listed in `mix.exs` dependencies.

### Push Notifications Not Working

**What you see:** No browser notifications appear for alerts or task events, even though notifications are enabled in the dashboard.

**Diagnosis:**

1. Check the browser console (F12) for push subscription errors. Common issues: `Registration failed - push service error` or `DOMException: Registration failed`.

2. Verify the VAPID key endpoint works:

   ```bash
   curl http://localhost:4000/api/dashboard/vapid-key
   ```

   This should return `{"vapid_public_key":"..."}`. If it returns an error, `AgentCom.DashboardNotifier` may not be running.

3. Check that browser notification permission is granted. In Chrome: Settings -> Privacy and Security -> Site Settings -> Notifications. The dashboard URL must show "Allow".

**Fix:** VAPID keys auto-generate on first hub start. If the hub was restarted, push subscriptions are invalidated (VAPID keys are ephemeral). Refresh the dashboard page and re-enable notifications. If permission was denied, clear the permission in browser settings and try again.

### Compaction Not Running / High Fragmentation

**What you see:** The DETS health panel on the dashboard shows fragmentation ratios above 50% (displayed in red) for one or more tables. The expected 6-hour compaction does not seem to be reducing fragmentation.

**Diagnosis:**

1. Check DETS health for fragmentation ratios and last compaction timestamp:

   ```bash
   curl http://localhost:4000/api/admin/dets-health \
     -H "Authorization: Bearer <token>"
   ```

   Look at `last_compaction_at` -- has 6 hours actually elapsed since last compaction? Also check `compaction_history` for recent run results.

2. Check if tables were skipped due to being below the default threshold (10%). A table must have at least 10% fragmentation for automatic compaction to trigger.

3. Check for compaction errors in logs:

   ```bash
   jq 'select(.message | test("dets_compaction"))' priv/logs/agent_com.log
   ```

**Fix:** Trigger manual compaction for all tables or a specific table:

```bash
# All tables
curl -X POST http://localhost:4000/api/admin/compact \
  -H "Authorization: Bearer <token>"

# Single table
curl -X POST http://localhost:4000/api/admin/compact/task_queue \
  -H "Authorization: Bearer <token>"
```

If you need more frequent compaction, adjust `compaction_interval_ms` in `config/config.exs` and restart. The compaction threshold (`compaction_threshold`, default 0.1) can also be adjusted to trigger compaction at lower fragmentation levels.

See `AgentCom.DetsBackup` for compaction scheduling, threshold logic, and retry behavior.
