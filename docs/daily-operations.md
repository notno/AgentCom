# Daily Operations

This guide covers everything you do with a running AgentCom hub: monitoring via the dashboard, interpreting metrics, reading structured logs, responding to alerts, and routine maintenance. It assumes the hub is already running per the [setup guide](setup.md) and you have a basic understanding of the system's architecture from the [architecture overview](architecture.md).

## Dashboard Overview

The dashboard is served at `http://localhost:4000/dashboard` -- a self-contained HTML page with no external build tools. It connects to the hub over a WebSocket at `/ws/dashboard` and receives real-time state pushes, so there is no polling and no refresh needed.

### Layout

The dashboard has two tabs:

- **Dashboard** -- the main operational view with agent cards, queue summary, throughput stats, recent tasks, dead letter queue, DETS storage health, and validation health.
- **Metrics** -- system metrics summary cards, uPlot time-series charts (queue depth, task latency, agent utilization, error rate), active alerts list, and per-agent metrics table.

### Connection Indicator

The connection bar below the header shows a colored dot:

- **Green (Connected)** -- WebSocket is live, data is flowing.
- **Red pulsing (Disconnected)** -- Connection lost. The dashboard will automatically reconnect with exponential backoff (1s, 2s, 4s, ... up to 30s). No manual action needed.
- **Yellow (Connecting)** -- Initial connection in progress.

The design uses WebSocket push instead of HTTP polling because it gives sub-second updates with zero wasted requests. When the connection drops, the dashboard requests a full state snapshot on reconnect so you never see stale partial data.

See `AgentCom.Dashboard`, `AgentCom.DashboardState`, `AgentCom.DashboardSocket` for implementation details.

### Push Notifications

The dashboard supports browser push notifications for important events (task completions, alert fires, backup/compaction failures). To enable:

1. Click "Enable Notifications" in the dashboard header (only appears if permission hasn't been granted).
2. Accept the browser permission prompt.

Push notifications use the Web Push protocol with auto-generated VAPID keys. The service worker registers at `/sw.js` and subscribes via `/api/dashboard/push-subscribe`. VAPID keys are ephemeral -- they regenerate on hub restart, which means push subscriptions are lost on restart. Re-enable notifications after restarting the hub.

See `AgentCom.DashboardNotifier` for the push notification implementation.

## Metrics Interpretation

### Dashboard Metrics Tab

The Metrics tab displays uPlot charts showing a **1-hour rolling window** (360 data points at 10-second intervals). Charts update in real-time via the same WebSocket connection as the Dashboard tab. The four summary cards at the top give you the current values at a glance.

### Programmatic Access

`GET /api/metrics` returns the full metrics snapshot as JSON. No authentication required. This is useful for external monitoring tools or scripts. The response matches the shape documented in `AgentCom.MetricsCollector`.

### Key Metrics

**Queue Depth** (current value and 1-hour trend)

What it measures: how many tasks are waiting in the queue right now.

- **Healthy:** Near 0 or stable. Tasks are being consumed as fast as they arrive.
- **Growing:** Tasks are arriving faster than agents can process them. Check agent availability and failure rates.
- **Trend line:** Shows the queue depth over the last hour. A sustained upward slope means you need more agent capacity.

**Task Latency Percentiles** (p50, p90, p99)

What it measures: time from task submission to completion, broken into percentile buckets.

- **p50 (median):** Half of tasks complete faster than this. Your typical task experience.
- **p90:** 90% of tasks complete faster. Useful for SLA planning.
- **p99:** Only 1% of tasks are slower. High p99 with low p50 means a few tasks are slow (possibly specific agent issues or complex tasks), not a systemic problem.

**Agent Utilization** (percentage)

What it measures: the fraction of time agents spend in `assigned` or `working` state vs. `idle`.

- **0%:** All agents idle, no work to do.
- **50-80%:** Healthy utilization. Agents have headroom for spikes.
- **100%:** All agents saturated. New tasks will queue. Consider adding agents.

The per-agent breakdown in the table below the charts shows which specific agents are overloaded or underutilized.

**Error Rates** (failure count and failure rate percentage)

What it measures: task failures within the 1-hour window.

- **Failure rate %:** `(failed + dead_letter) / total_completed_and_failed * 100`. Under 5% is normal for flaky external dependencies. Over 50% triggers the `high_failure_rate` alert.
- **Failures/hour:** Absolute count. Over 10 triggers the `high_error_rate` alert.
- **Spikes:** A sudden spike in errors often indicates a systemic issue -- broken wake command, external API down, or agent misconfiguration.

**Throughput** (completed/hour)

What it measures: tasks flowing through the system to completion within the window. This is your capacity baseline. If throughput drops while queue depth grows, something is wrong with agent processing.

See `AgentCom.MetricsCollector` for metric definitions, snapshot shape, and ETS table internals.

## Reading Structured Logs

### Log Locations

| Component | File | Format | Rotation |
|-----------|------|--------|----------|
| Hub (file) | `priv/logs/agent_com.log` | JSON (LoggerJSON) | 10MB x 5 files, compressed |
| Hub (console) | stdout | JSON (LoggerJSON) | N/A |
| Sidecar | `~/.agentcom/<agent-name>/sidecar.log` | JSON | 10MB x 5 files |
| Sidecar (pm2) | pm2 managed logs | Raw stdout/stderr | pm2 managed |

### JSON Log Structure

Every hub log entry is a JSON object with these key fields:

```json
{
  "message": "task_submitted",
  "severity": "info",
  "metadata": {
    "module": "AgentCom.TaskQueue",
    "request_id": "a1b2c3d4e5f67890",
    "agent_id": "my-agent",
    "task_id": "abc-123"
  },
  "telemetry_event": "agent_com.task.submit"
}
```

- `message` -- what happened (human-readable event name).
- `severity` -- `debug`, `info`, `notice`, `warning`, `error`, `critical`.
- `metadata.module` -- which Elixir module emitted this log.
- `metadata.request_id` -- 16-character hex correlation ID, unique per WebSocket message. Use this to trace a single request across modules.
- `metadata.agent_id` -- which agent this event relates to (when applicable).
- `metadata.task_id` -- which task this event relates to (when applicable).
- `telemetry_event` -- the telemetry event name if this log was triggered by a telemetry handler. Useful for filtering by event type.

### Useful jq Queries

**All errors:**

```bash
jq 'select(.severity == "error")' priv/logs/agent_com.log
```

**Activity for a specific agent:**

```bash
jq 'select(.metadata.agent_id == "my-agent")' priv/logs/agent_com.log
```

**Task lifecycle events:**

```bash
jq 'select(.telemetry_event | startswith("agent_com.task"))' priv/logs/agent_com.log
```

**Scheduler activity:**

```bash
jq 'select(.telemetry_event == "agent_com.scheduler.attempt")' priv/logs/agent_com.log
```

**Correlation -- trace a request ID across all modules:**

```bash
jq 'select(.metadata.request_id == "a1b2c3d4e5f67890")' priv/logs/agent_com.log
```

**DETS backup/compaction events:**

```bash
jq 'select(.telemetry_event | test("agent_com.dets"))' priv/logs/agent_com.log
```

### Changing Log Level at Runtime

The hub supports runtime log level changes without restart:

```bash
curl -X PUT http://localhost:4000/api/admin/log-level \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"level":"debug"}'
```

Valid levels: `debug`, `info`, `notice`, `warning`, `error`.

This change is **ephemeral** -- it resets to the configured level on hub restart. This is intentional: you can safely enable debug logging for diagnosis without worrying about forgetting to turn it off.

### Sidecar Logs

Sidecar logs live at `~/.agentcom/<agent-name>/sidecar.log` or can be viewed with `pm2 logs agentcom-<name>`. They are also JSON-formatted with similar structure, including `message`, `level`, and contextual fields like `agent_id` and `task_id`.

See `AgentCom.Telemetry` for the full event catalog with measurements and metadata definitions.

## Alerts

### How Alerting Works

`AgentCom.Alerter` is a GenServer that evaluates 5 alert rules on a periodic schedule (default every 30 seconds). It reads the current metrics snapshot from `AgentCom.MetricsCollector`, evaluates each rule, and fires alerts via PubSub when thresholds are exceeded.

The Alerter has a **30-second startup delay** to prevent false positives on fresh start -- agents need time to reconnect before "no agents online" makes sense.

### Alert Lifecycle

Alerts progress through states: **inactive** -> **active** -> **acknowledged** -> **cleared**.

- **Active:** Condition detected, alert banner visible on dashboard.
- **Acknowledged:** Operator has seen it but the condition persists. Alert is suppressed from re-firing.
- **Cleared:** Condition resolved. Alert disappears.

### Alert Rules

The dashboard shows an alert banner at the top (visible on all tabs) with the highest severity across unacknowledged alerts.

#### queue_growing (WARNING)

- **What it means:** Queue depth has been increasing for 3+ consecutive check cycles.
- **Why it matters:** Tasks are arriving faster than agents can process them. If this continues, the queue will grow indefinitely.
- **What to do:** Check agent availability (`GET /api/agents`). Add more agents if all are working at capacity. Check if tasks are failing and retrying, which consumes agent time without making progress.
- **Hysteresis:** Requires 3 consecutive stable/decreasing checks to clear (prevents flapping).

#### high_failure_rate (WARNING)

- **What it means:** More than 50% of tasks in the last hour have failed.
- **Why it matters:** Most tasks are failing, which means agents are spending time on work that produces no results.
- **What to do:** Check the dead letter queue (`GET /api/tasks/dead-letter`) for common error patterns. Check sidecar logs for wake command failures. Fix the root cause before retrying.

#### stuck_tasks (CRITICAL)

- **What it means:** One or more tasks have been in "assigned" state for over 5 minutes without progress.
- **Why it matters:** An agent accepted the task but never completed or failed it. The agent or its sidecar may be hung.
- **What to do:** Check the stuck agent's sidecar process (`pm2 list`, `pm2 logs agentcom-<name>`). The Scheduler's 30-second sweep automatically reclaims stuck tasks after 5 minutes and re-queues them. If the sidecar is hung, restart it.

#### no_agents_online (CRITICAL)

- **What it means:** All previously registered agents have disconnected. Zero agents are available to process tasks.
- **Why it matters:** The system cannot process any tasks. Everything will queue indefinitely.
- **What to do:** Check network connectivity. Check sidecar processes (`pm2 list`). Restart sidecars as needed. This alert only fires if agents were previously connected (won't fire on fresh start with no agents).

#### high_error_rate (WARNING)

- **What it means:** More than 10 task failures in the last hour.
- **Why it matters:** Elevated error count even if the percentage is low. Could indicate a pattern emerging.
- **What to do:** Look for patterns -- is it one agent failing or all of them? Is it one type of task? Check sidecar logs for details.

### Acknowledging Alerts

From the dashboard: click the "Acknowledge" button on the alert in the Metrics tab, or click "Details" on the alert banner and acknowledge from there.

Via API:

```bash
curl -X POST http://localhost:4000/api/alerts/queue_growing/acknowledge \
  -H "Authorization: Bearer <token>"
```

Acknowledged alerts are suppressed until the condition clears and returns.

### Configuring Alert Thresholds

Read current thresholds:

```bash
curl http://localhost:4000/api/config/alert-thresholds \
  -H "Authorization: Bearer <token>"
```

Update thresholds:

```bash
curl -X PUT http://localhost:4000/api/config/alert-thresholds \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "queue_growing_checks": 5,
    "failure_rate_pct": 75,
    "stuck_task_ms": 600000,
    "error_count_hour": 20,
    "check_interval_ms": 60000
  }'
```

Changes take effect on the next check cycle -- no restart needed. Custom thresholds are merged with defaults, so you can update individual fields without specifying all of them.

**Cooldown behavior:**
- CRITICAL alerts (`stuck_tasks`, `no_agents_online`) always fire immediately, bypassing cooldown.
- WARNING alerts respect per-rule cooldown periods (default: `queue_growing` 5 min, `high_failure_rate` 10 min, `high_error_rate` 5 min).

See `AgentCom.Alerter` for rule evaluation logic and default threshold values.

## Routine Maintenance

### DETS Backup

**Automatic:** Daily backup of all 9 DETS tables to `priv/backups/`. Retention: last 3 backups per table.

**Verify backup status:**

```bash
curl http://localhost:4000/api/admin/dets-health \
  -H "Authorization: Bearer <token>"
```

Check the `last_backup_at` timestamp in the response. The dashboard also shows "Last backup: X ago" in the DETS Storage Health panel.

**Manual trigger:**

```bash
curl -X POST http://localhost:4000/api/admin/backup \
  -H "Authorization: Bearer <token>"
```

See `AgentCom.DetsBackup` for backup internals.

### DETS Compaction

**Automatic:** Every 6 hours (configurable via `compaction_interval_ms` in `config.exs`). Tables below the fragmentation threshold (default 10%) are skipped.

**Check fragmentation:**

```bash
curl http://localhost:4000/api/admin/dets-health \
  -H "Authorization: Bearer <token>"
```

Each table in the response has a `fragmentation_ratio` field (0.0 to 1.0). Above 0.5 (50%) is shown in red on the dashboard. Above 0.3 (30%) is shown in yellow.

**Manual trigger (all tables):**

```bash
curl -X POST http://localhost:4000/api/admin/compact \
  -H "Authorization: Bearer <token>"
```

**Manual trigger (single table):**

```bash
curl -X POST http://localhost:4000/api/admin/compact/task_queue \
  -H "Authorization: Bearer <token>"
```

Valid table names: `task_queue`, `task_dead_letter`, `agent_mailbox`, `message_history`, `agent_channels`, `channel_history`, `agentcom_config`, `thread_messages`, `thread_replies`.

See `AgentCom.DetsBackup` for compaction logic, retry behavior, and history tracking.

### Log Rotation

Automatic. The hub log file (`priv/logs/agent_com.log`) rotates at 10MB with 5 rotated files kept (compressed). No manual intervention needed.

Sidecar logs also rotate at 10MB with 5 files. pm2-managed logs follow pm2's rotation settings.

### Token Management

**List tokens:**

```bash
curl http://localhost:4000/admin/tokens \
  -H "Authorization: Bearer <admin-token>"
```

**Revoke a token:**

```bash
curl -X DELETE http://localhost:4000/admin/tokens/<agent-id> \
  -H "Authorization: Bearer <admin-token>"
```

Revoking a token immediately invalidates the agent's WebSocket connection on the next heartbeat check.

### Runtime Configuration

Runtime configuration is stored in a DETS-backed `AgentCom.Config` store. These settings persist across restarts.

**Alert thresholds:** `GET/PUT /api/config/alert-thresholds`

**Heartbeat interval:** `GET/PUT /api/config/heartbeat-interval` (how often agents send pings, default 30s)

**Mailbox retention:** `GET/PUT /api/config/mailbox-retention` (how long unacknowledged messages are kept)

**Default repository:** `GET/PUT /api/config/default-repo` (default repo URL for agent onboarding)

See `AgentCom.Config` for the full configuration API.

## API Quick Reference

### Task Management

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/tasks` | Bearer | Submit a task to the queue |
| GET | `/api/tasks` | Bearer | List tasks (filterable by status, agent, priority) |
| GET | `/api/tasks/dead-letter` | Bearer | List dead-letter tasks |
| GET | `/api/tasks/stats` | Bearer | Queue statistics |
| GET | `/api/tasks/:task_id` | Bearer | Task details with history |
| POST | `/api/tasks/:task_id/retry` | Bearer | Retry a dead-letter task |

### Agent Management

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| GET | `/api/agents` | None | List connected agents |
| GET | `/api/agents/states` | Bearer | All agent FSM states |
| GET | `/api/agents/:id/state` | Bearer | Single agent FSM state detail |
| GET | `/api/agents/:id/subscriptions` | None | Agent's channel subscriptions |
| POST | `/api/onboard/register` | None | Register new agent, get token |

### Communication

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/message` | Bearer | Send a message |
| GET | `/api/mailbox/:id` | Bearer | Poll messages |
| POST | `/api/mailbox/:id/ack` | Bearer | Acknowledge messages |
| GET | `/api/channels` | None | List all channels |
| POST | `/api/channels` | Bearer | Create a channel |
| GET | `/api/channels/:ch` | None | Channel info and subscribers |
| POST | `/api/channels/:ch/subscribe` | Bearer | Subscribe to channel |
| POST | `/api/channels/:ch/unsubscribe` | Bearer | Unsubscribe from channel |
| POST | `/api/channels/:ch/publish` | Bearer | Publish to channel |
| GET | `/api/channels/:ch/history` | None | Channel message history |

### System Administration

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/admin/backup` | Bearer | Trigger DETS backup |
| GET | `/api/admin/dets-health` | Bearer | DETS table health metrics |
| POST | `/api/admin/compact` | Bearer | Compact all DETS tables |
| POST | `/api/admin/compact/:table` | Bearer | Compact specific DETS table |
| POST | `/api/admin/restore/:table` | Bearer | Restore table from backup |
| PUT | `/api/admin/log-level` | Bearer | Change runtime log level (ephemeral) |
| POST | `/api/admin/reset` | ADMIN | Hub reset (ADMIN_AGENTS only) |
| POST | `/api/admin/push-task` | Bearer | Push a task to a specific agent |

### Configuration

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| GET/PUT | `/api/config/alert-thresholds` | Bearer | Alert thresholds |
| GET/PUT | `/api/config/heartbeat-interval` | Bearer | Heartbeat interval |
| GET/PUT | `/api/config/mailbox-retention` | Bearer | Mailbox TTL |
| GET | `/api/config/default-repo` | None | Default repository URL |
| PUT | `/api/config/default-repo` | Bearer | Set default repository URL |

### Rate Limiting

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| GET | `/api/admin/rate-limits` | Bearer | Rate limit overview |
| PUT | `/api/admin/rate-limits/:agent_id` | Bearer | Set per-agent overrides |
| DELETE | `/api/admin/rate-limits/:agent_id` | Bearer | Remove per-agent overrides |
| GET | `/api/admin/rate-limits/whitelist` | Bearer | Get exempt agent whitelist |
| PUT | `/api/admin/rate-limits/whitelist` | Bearer | Replace entire whitelist |
| POST | `/api/admin/rate-limits/whitelist` | Bearer | Add agent to whitelist |
| DELETE | `/api/admin/rate-limits/whitelist/:agent_id` | Bearer | Remove from whitelist |

### Monitoring

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| GET | `/health` | None | Health check (agents_connected count) |
| GET | `/api/metrics` | None | System metrics snapshot |
| GET | `/api/alerts` | None | Active alerts |
| POST | `/api/alerts/:rule_id/acknowledge` | Bearer | Acknowledge alert |
| GET | `/api/dashboard/state` | None | Full dashboard state snapshot |
| GET | `/api/dashboard/vapid-key` | None | VAPID public key for push |
| POST | `/api/dashboard/push-subscribe` | None | Register push subscription |
| GET | `/api/schemas` | None | Validation schema discovery |
| GET | `/admin/tokens` | Bearer | List tokens |
| POST | `/admin/tokens` | Bearer | Generate token |
| DELETE | `/admin/tokens/:id` | Bearer | Revoke token |

### WebSocket

| Endpoint | Auth | Description |
|----------|------|-------------|
| `/ws` | Token (in identify message) | Agent WebSocket connection |
| `/ws/dashboard` | None | Dashboard real-time updates |
