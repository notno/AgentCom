# Phase 42: Agent Self-Management - Research

**Researched:** 2026-02-14
**Domain:** pm2 process management, Node.js child_process, WebSocket command protocol
**Confidence:** HIGH

## Summary

Phase 42 adds pm2 self-awareness and hub-commanded restart capability to the sidecar. The sidecar needs to know its own pm2 process name, query its status, and perform graceful restarts on hub command. This is a small, well-scoped feature touching 4 files.

The approach is straightforward: use `child_process.execSync` to call `pm2 jlist` for status queries, read process name from environment variable or discover via PID matching, and handle a new `restart_sidecar` WebSocket message type. Graceful restart means finishing any active task, notifying the hub, then calling `process.exit(0)` so pm2 auto-restarts.

**Primary recommendation:** Use `PM2_PROCESS_NAME` env var (set in ecosystem.config.js) as the primary process name source, with `pm2 jlist` + PID matching as fallback. No npm dependencies needed -- `child_process.execSync` and `pm2 jlist` JSON output are sufficient.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Sidecar reads its own pm2 process name from `PM2_PROCESS_NAME` env var (set in ecosystem.config.js)
- If not set, discovers via `pm2 jlist` and matches by PID
- New `sidecar/lib/pm2-manager.js` with `getStatus()`, `getInfo()`, `gracefulRestart()`
- `gracefulRestart()` finishes current task, sends `agent_restarting` status to hub, calls `process.exit(0)`
- New WebSocket message type: `restart_sidecar`
- Hub sends `{type: "restart_sidecar", reason: "..."}` to specific agent
- Sidecar restarts only itself -- no peer restarts
- Graceful shutdown -- always finish current task before restarting
- pm2 auto-restart handles the actual restart -- sidecar just exits cleanly
- Env var for process name -- simpler than pm2 API discovery

### Claude's Discretion
- None specified -- approach is fully locked in CONTEXT.md

### Deferred Ideas (OUT OF SCOPE)
- None specified
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| child_process (Node.js built-in) | N/A | Execute `pm2 jlist` for process discovery | Built-in, no dependencies needed |
| pm2 (CLI) | Already installed globally | Process management, restart, status | Already in use for sidecar management |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| None | - | - | No additional deps needed |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `pm2 jlist` CLI | pm2 programmatic API (`pm2.connect()`) | Programmatic API adds pm2 as npm dependency (~15MB), CLI is already available and sufficient for infrequent status checks |
| `process.exit(0)` | `pm2.restart()` programmatic | Programmatic restart requires pm2 npm package; clean exit + pm2 auto-restart is simpler and already configured |

**Installation:**
```bash
# No new packages needed
```

## Architecture Patterns

### Recommended Project Structure
```
sidecar/
├── lib/
│   ├── pm2-manager.js        # NEW: pm2 awareness and restart
│   ├── queue.js               # Existing
│   ├── wake.js                # Existing
│   └── ...
├── index.js                   # Modified: handle restart_sidecar message
├── ecosystem.config.js        # Modified: add PM2_PROCESS_NAME env var
└── test/
    └── pm2-manager.test.js    # NEW: unit tests
```

### Pattern 1: Environment Variable + Fallback Discovery
**What:** Primary identification via `PM2_PROCESS_NAME` env var, fallback to PID-based discovery via `pm2 jlist`
**When to use:** Always -- env var is fast (no subprocess), fallback handles manual `node index.js` starts
**Example:**
```javascript
// pm2-manager.js
const { execSync } = require('child_process');

function getProcessName() {
  // Primary: env var set by ecosystem.config.js
  if (process.env.PM2_PROCESS_NAME) {
    return process.env.PM2_PROCESS_NAME;
  }

  // Fallback: discover via pm2 jlist and PID matching
  try {
    const output = execSync('pm2 jlist', { encoding: 'utf8', timeout: 5000 });
    const processes = JSON.parse(output);
    const self = processes.find(p => p.pid === process.pid);
    return self ? self.name : null;
  } catch (err) {
    return null; // Not running under pm2
  }
}
```

### Pattern 2: Graceful Restart with Task Completion
**What:** Wait for active task to finish before restarting, with a timeout safety valve
**When to use:** When hub commands a restart while sidecar is executing a task
**Example:**
```javascript
async function gracefulRestart(hub, queue, reason) {
  // If executing a task, wait for completion (with timeout)
  if (queue.active && queue.active.status === 'working') {
    // Set a flag so task completion triggers restart
    _pendingRestart = { reason };
    return; // Restart will happen after task completes
  }

  // No active task -- restart immediately
  hub.send({ type: 'agent_restarting', reason });
  // Small delay for message to flush
  setTimeout(() => process.exit(0), 500);
}
```

### Pattern 3: Hub-Side Message Dispatch
**What:** Add `restart_sidecar` to the hub's WebSocket push capabilities
**When to use:** When hub (or healing state, or admin) needs to restart a specific sidecar
**Example:**
```elixir
# In socket.ex handle_info
def handle_info({:restart_sidecar, reason}, state) do
  push = %{
    "type" => "restart_sidecar",
    "reason" => reason
  }
  {:push, {:text, Jason.encode!(push)}, state}
end
```

### Anti-Patterns to Avoid
- **pm2 npm package as dependency:** Adds ~15MB, requires `pm2.connect()`/`pm2.disconnect()` lifecycle. CLI calls are simpler for infrequent operations.
- **SIGKILL or process.kill:** Don't force-kill. Always `process.exit(0)` for clean shutdown via existing graceful shutdown handler.
- **Restarting during task without notification:** Always notify hub before restarting so it can track agent state.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Process restart | Custom fork/exec restart | `process.exit(0)` + pm2 autorestart | pm2 handles PID management, log rotation, restart counting |
| Process status | Custom `/proc` parsing | `pm2 jlist` JSON output | Cross-platform, includes uptime/memory/restart count |

**Key insight:** pm2 already handles process lifecycle. The sidecar just needs to trigger a clean exit and let pm2 do what it does best.

## Common Pitfalls

### Pitfall 1: pm2 not in PATH
**What goes wrong:** `execSync('pm2 jlist')` throws ENOENT
**Why it happens:** pm2 installed globally but PATH not set in pm2 child process environment
**How to avoid:** Catch the error and return null/unknown status. Sidecar still works without pm2 awareness.
**Warning signs:** Error logs showing "pm2: command not found"

### Pitfall 2: Restart during task loses work
**What goes wrong:** Sidecar exits mid-LLM-call, task is lost
**Why it happens:** Immediate `process.exit(0)` without waiting for task completion
**How to avoid:** Check `_queue.active` before restarting. If task is active, defer restart until task completes or set a timeout (e.g., 2 minutes).
**Warning signs:** Tasks stuck in "working" state after sidecar restart

### Pitfall 3: Restart loop
**What goes wrong:** Hub sends restart, sidecar restarts, reconnects, hub sends restart again
**Why it happens:** Hub doesn't track that restart was already commanded
**How to avoid:** Hub should track restart_commanded state per agent, clear on reconnect. Sidecar should ignore duplicate restart commands.
**Warning signs:** Rapid restart count climbing in pm2

### Pitfall 4: WebSocket message not flushed before exit
**What goes wrong:** `agent_restarting` message never reaches hub
**Why it happens:** `process.exit(0)` called immediately after `ws.send()`
**How to avoid:** Use `setTimeout(() => process.exit(0), 500)` to give the WebSocket time to flush. The existing graceful shutdown pattern already does this.
**Warning signs:** Hub doesn't see `agent_restarting` status

## Code Examples

### pm2 jlist output format
```json
[
  {
    "pid": 12345,
    "name": "agentcom-sidecar",
    "pm2_env": {
      "status": "online",
      "pm_uptime": 1707900000000,
      "restart_time": 3,
      "unstable_restarts": 0
    },
    "monit": {
      "memory": 52428800,
      "cpu": 1.5
    }
  }
]
```

### Handling restart_sidecar in sidecar index.js
```javascript
// In handleMessage switch:
case 'restart_sidecar':
  log('info', 'restart_commanded', { reason: msg.reason });
  pm2Manager.gracefulRestart(this, _queue, msg.reason);
  break;
```

### Hub-side: sending restart to specific agent
```elixir
# In endpoint.ex or healing module:
def restart_agent(agent_id, reason) do
  case Presence.get_pid(agent_id) do
    nil -> {:error, :not_connected}
    pid ->
      send(pid, {:restart_sidecar, reason})
      :ok
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| pm2 programmatic API | pm2 CLI (`jlist`) | Always | CLI is simpler for status queries, no npm dependency |
| Manual restart via `pm2 restart` | Hub-commanded restart via WebSocket | This phase | Enables autonomous healing |

## Open Questions

1. **Restart timeout for active tasks**
   - What we know: Graceful restart should wait for task completion
   - What's unclear: How long to wait before force-restarting anyway? CONTEXT.md says "finish current task" but tasks could run for 30+ minutes.
   - Recommendation: Wait up to 2 minutes, then force restart. The task will be recovered on reconnect via existing crash recovery logic.

2. **Hub-side API endpoint for manual restart**
   - What we know: Hub sends `restart_sidecar` via WebSocket
   - What's unclear: Should there be an HTTP API endpoint (e.g., `POST /api/admin/agents/:id/restart`) for dashboard/admin use?
   - Recommendation: Add it -- simple 5-line endpoint that calls `send(pid, {:restart_sidecar, reason})`. Useful for healing state and manual intervention.

## Sources

### Primary (HIGH confidence)
- AgentCom codebase: `sidecar/index.js`, `sidecar/ecosystem.config.js`, `lib/agent_com/socket.ex` -- current architecture patterns
- pm2 CLI documentation -- `pm2 jlist` outputs JSON array of process objects

### Secondary (MEDIUM confidence)
- pm2 ecosystem file documentation -- env var injection is well-documented

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - no new dependencies, using existing pm2 CLI and Node.js builtins
- Architecture: HIGH - follows existing sidecar patterns (message handler switch, lib/ modules)
- Pitfalls: HIGH - well-understood domain, small surface area

**Research date:** 2026-02-14
**Valid until:** 2026-03-14 (stable domain, pm2 and Node.js child_process are mature)
