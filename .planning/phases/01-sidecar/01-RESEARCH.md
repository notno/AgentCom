# Phase 1: Sidecar - Research

**Researched:** 2026-02-09
**Domain:** Node.js WebSocket client, process management, cross-platform shell execution, crash recovery
**Confidence:** HIGH

## Summary

The sidecar is a lightweight Node.js process that runs alongside each agent machine, maintaining a persistent WebSocket connection to the Elixir hub. It receives task assignments via push, persists them locally to a queue.json file, triggers an OpenClaw (or other runtime) session via a configurable shell command, and reports results back to the hub. The sidecar is intentionally a "dumb relay" with zero decision-making logic -- all scheduling intelligence stays on the hub.

The technology stack is straightforward: the existing `ws` library (already in the project at v8.19.0) handles WebSocket connectivity, `write-file-atomic` provides crash-safe file persistence, Node.js built-in `child_process` handles wake command execution, and pm2 manages the sidecar as a long-running process. Cross-platform (Windows + Linux) support is achievable with careful attention to shell execution differences and file path handling.

**Primary recommendation:** Build the sidecar as a single-file Node.js process (~300-500 lines) with no build step, using ws for WebSocket, write-file-atomic for queue persistence, child_process.exec for wake commands, and a wrapper shell script for auto-update on restart. Use pm2 with pm2-installer on Windows for service management.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Wake Mechanism
- Configurable shell command (not hardcoded to OpenClaw) -- default to OpenClaw wake syntax, swappable for future runtimes
- If wake command fails: retry 3x with backoff (5s, 15s, 30s), then report failure to hub for reassignment
- Wake verification: check exit code immediately, then wait for confirmation callback from agent session within 30s timeout
- Pass full task payload to wake command (task ID + description + metadata) so agent starts with full context
- If all 3 retries fail: report to hub, hub reassigns task to another agent

#### Local Queue Behavior
- Sidecar holds at most one active task + one recovering task (from pre-crash state)
- If agent is busy and new task arrives: reject back to hub (hub re-queues)
- Atomic writes to queue.json (write to temp file, rename) to prevent corruption on crash
- Local log file for task lifecycle events (received, wake attempt, success/fail, completion) -- separate from pm2 logs
- Recovery on restart: report to hub with recovering status, let hub decide (reassign or re-push)

#### Hub Protocol
- Sidecar-to-hub messages: task_accepted, task_progress, task_complete, task_failed -- all with task payload
- Agent-to-sidecar communication: Claude decides best approach (local file, HTTP callback, or stdout)
- Protocol versioning: Claude decides based on complexity tradeoffs
- Handshake: Claude decides whether to reuse existing identify or create sidecar-specific variant

#### Deployment & Config
- Cross-platform: must work on both Windows and Linux (agents are a mix)
- Config via config.json file: agent_id, token, hub_url, wake_command, and other settings
- Sidecar lives inside the AgentCom repo (sidecar/ directory), agents clone the repo
- Auto-update on restart: sidecar pulls latest from git on pm2 restart (not periodic)
- Process manager: pm2 as primary, node-windows as fallback for Windows machines
- Managed with auto-restart and log rotation

### Claude's Discretion
- WebSocket handshake design (reuse existing identify or sidecar-specific)
- Agent-to-sidecar result communication mechanism (file watch, HTTP callback, or stdout)
- Protocol versioning (include version field or defer)
- queue.json data model (minimal ID+status vs full task payload)
- Recovery behavior on restart (re-wake or report to hub)

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ws | 8.19.0 | WebSocket client for persistent hub connection | Already in project; most popular Node.js WebSocket library (22.7k GitHub stars), blazing fast, thoroughly tested |
| write-file-atomic | 6.x (latest) | Atomic writes to queue.json | npm's own library for crash-safe file writes; writes to temp file then renames; handles concurrent writes with serialization |
| Node.js child_process (built-in) | N/A | Execute configurable wake commands | Built-in module; exec() for shell commands with timeout and exit code handling |
| pm2 | 5.x (latest) | Process management with auto-restart | Industry standard for Node.js process management; supports ecosystem.config.js, log rotation, startup scripts |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| pm2-installer (jessety) | latest | Install pm2 as Windows service | Windows machines only; installs pm2 under Local Service user, persists across reboots |
| pm2-logrotate | latest | Log rotation for pm2 managed processes | Installed as pm2 module; configurable max size (default 10MB), max retained files (default 30) |
| chokidar | 4.x | File watching for agent result communication | Only if file-based agent-to-sidecar communication is chosen (see recommendation below) |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| ws | websocket-ts | Has built-in reconnect with backoff, but adds unnecessary abstraction over ws which is already in the project |
| write-file-atomic | Manual fs.writeFile + fs.rename | write-file-atomic handles edge cases (cleanup on error, concurrent writes, fsync) that are easy to get wrong |
| pm2 on Windows | node-windows directly | node-windows is in beta, last updated 2+ years ago, lacks pm2's rich ecosystem; pm2-installer wraps node-windows properly |
| chokidar | fs.watch (built-in) | fs.watch has known cross-platform issues (no filenames on macOS, events fired twice, no recursive on Linux); chokidar normalizes all this |

**Installation:**
```bash
cd sidecar/
npm install ws write-file-atomic
# chokidar only if file-based communication chosen:
# npm install chokidar
```

**Global tooling (per agent machine):**
```bash
npm install -g pm2
pm2 install pm2-logrotate
# Windows only:
# Clone pm2-installer repo, run npm run setup from elevated terminal
```

## Architecture Patterns

### Recommended Project Structure
```
sidecar/
  index.js              # Main entry point (~300-500 lines)
  package.json          # Dependencies: ws, write-file-atomic
  ecosystem.config.js   # pm2 process configuration
  start.sh              # Linux wrapper: git pull + node index.js
  start.bat             # Windows wrapper: git pull + node index.js
  config.json.example   # Template config (agent_id, token, hub_url, wake_command)
  README.md             # Setup instructions
```

**Runtime files (gitignored, created per-agent):**
```
sidecar/
  config.json           # Per-agent configuration (from template)
  queue.json            # Active task persistence (atomic writes)
  sidecar.log           # Task lifecycle log (separate from pm2 logs)
```

### Pattern 1: WebSocket with Reconnect and Exponential Backoff
**What:** ws library does not include built-in reconnection. Implement a reconnect loop with exponential backoff (1s, 2s, 4s... cap 60s) as specified in SIDE-01.
**When to use:** Always -- this is the core connection pattern.
**Example:**
```javascript
// Source: ws documentation + SIDE-01 requirements
const WebSocket = require('ws');

class HubConnection {
  constructor(config) {
    this.config = config;
    this.ws = null;
    this.reconnectDelay = 1000; // Start at 1s
    this.maxReconnectDelay = 60000; // Cap at 60s
    this.identified = false;
  }

  connect() {
    this.ws = new WebSocket(this.config.hub_url);

    this.ws.on('open', () => {
      this.reconnectDelay = 1000; // Reset on successful connect
      this.identify();
    });

    this.ws.on('close', () => {
      this.identified = false;
      this.scheduleReconnect();
    });

    this.ws.on('error', (err) => {
      // Error triggers close event, reconnect handled there
      log('ws_error', { error: err.message });
    });

    this.ws.on('message', (data) => {
      this.handleMessage(JSON.parse(data));
    });
  }

  scheduleReconnect() {
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(
      this.reconnectDelay * 2,
      this.maxReconnectDelay
    );
    setTimeout(() => this.connect(), delay);
  }

  identify() {
    this.send({
      type: 'identify',
      agent_id: this.config.agent_id,
      token: this.config.token,
      name: this.config.agent_id,
      status: 'idle',
      capabilities: this.config.capabilities || []
    });
  }
}
```

### Pattern 2: Atomic Queue Persistence
**What:** Use write-file-atomic to persist queue state, ensuring crash recovery without corruption.
**When to use:** Every state change to the active task.
**Example:**
```javascript
// Source: write-file-atomic npm documentation
const writeFileAtomic = require('write-file-atomic');
const fs = require('fs');
const path = require('path');

const QUEUE_PATH = path.join(__dirname, 'queue.json');

function saveQueue(queue) {
  // Writes to temp file, then renames atomically
  // Serializes concurrent writes automatically
  writeFileAtomic.sync(QUEUE_PATH, JSON.stringify(queue, null, 2));
}

function loadQueue() {
  try {
    const data = fs.readFileSync(QUEUE_PATH, 'utf8');
    return JSON.parse(data);
  } catch (err) {
    if (err.code === 'ENOENT') return { active: null, recovering: null };
    throw err; // Corrupted file -- let it crash, pm2 restarts
  }
}
```

### Pattern 3: Wake Command with Retry
**What:** Execute configurable shell command with retry logic (3x at 5s/15s/30s) and exit code + callback verification.
**When to use:** When a new task arrives and agent is idle.
**Example:**
```javascript
// Source: Node.js child_process documentation
const { exec } = require('child_process');

const RETRY_DELAYS = [5000, 15000, 30000]; // 5s, 15s, 30s
const CALLBACK_TIMEOUT = 30000; // 30s for agent confirmation

async function wakeAgent(task, wakeCommand, attempt = 0) {
  // Interpolate task data into wake command
  const cmd = wakeCommand
    .replace('${TASK_ID}', task.id)
    .replace('${TASK_JSON}', JSON.stringify(task));

  return new Promise((resolve, reject) => {
    exec(cmd, { timeout: 60000 }, (error, stdout, stderr) => {
      if (error) {
        if (attempt < RETRY_DELAYS.length) {
          setTimeout(() => {
            wakeAgent(task, wakeCommand, attempt + 1)
              .then(resolve).catch(reject);
          }, RETRY_DELAYS[attempt]);
        } else {
          reject(new Error(`Wake failed after ${attempt + 1} attempts`));
        }
        return;
      }
      // Exit code 0 -- now wait for confirmation callback
      resolve({ exitCode: 0, stdout, stderr });
    });
  });
}
```

### Pattern 4: Graceful Shutdown with PM2
**What:** Handle SIGINT/SIGTERM to cleanly close WebSocket and persist state before exit.
**When to use:** Always -- pm2 sends SIGINT on restart/stop.
**Example:**
```javascript
// Source: PM2 graceful shutdown documentation
function setupGracefulShutdown(hubConnection, queue) {
  const shutdown = async (signal) => {
    log('shutdown', { signal });
    // Save current queue state
    saveQueue(queue);
    // Close WebSocket cleanly
    if (hubConnection.ws) {
      hubConnection.ws.close();
    }
    process.exit(0);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}
```

### Pattern 5: Auto-Update via Wrapper Script
**What:** PM2 does not have a built-in pre-start hook. Use a wrapper script that runs `git pull` before launching Node.
**When to use:** Always -- this is how auto-update on restart is achieved.
**Example (start.sh for Linux):**
```bash
#!/bin/bash
cd "$(dirname "$0")/.."  # Navigate to repo root
git pull --ff-only origin main 2>/dev/null || true
cd sidecar/
npm install --production 2>/dev/null || true
exec node index.js
```
**Example (start.bat for Windows):**
```batch
@echo off
cd /d "%~dp0\.."
git pull --ff-only origin main 2>nul
cd sidecar
call npm install --production 2>nul
node index.js
```

### Anti-Patterns to Avoid
- **Polling the hub for tasks:** The entire point of the sidecar is push-based via WebSocket. Never fall back to HTTP polling for task assignment.
- **Local task queuing beyond one task:** The hub is the single source of truth. If the agent is busy, reject the task back to the hub. Do not build a local multi-task queue.
- **Hardcoding OpenClaw commands:** The wake command must be configurable. Other runtimes (Claude Code CLI) will use the same sidecar.
- **Using fs.writeFile without atomic pattern:** A crash mid-write corrupts queue.json. Always use write-file-atomic.
- **Spawning shell on Windows with exec and Unix syntax:** Use platform-aware command execution. On Windows, .bat/.cmd files require `shell: true`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Atomic file writes | Manual write-to-temp + rename | write-file-atomic | Handles fsync, concurrent writes, cleanup on error, cross-platform temp file naming |
| WebSocket reconnection | Custom reconnect timer | Hand-roll (simple enough) but follow the exponential backoff pattern carefully | ws doesn't include reconnect; the pattern is ~15 lines. Libraries like reconnecting-websocket add unnecessary dependency for this simple case |
| Process management | Custom daemon/watchdog | pm2 | Handles auto-restart, log rotation, startup on boot, process monitoring |
| Windows service installation | Manual registry/service manipulation | pm2-installer (jessety) | Properly configures pm2 as Local Service on Windows with correct permissions |
| Log rotation | Custom log file management | pm2-logrotate module | Configurable size limits, retention, automatic rotation |
| Cross-platform file watching | fs.watch | chokidar (if file-based comms chosen) | fs.watch is unreliable cross-platform; chokidar normalizes OS-specific behaviors |

**Key insight:** The sidecar should be as boring and simple as possible. Every hand-rolled component is a potential crash point. Use battle-tested libraries for file I/O and process management. The only custom logic should be the WebSocket message handling and wake command orchestration.

## Common Pitfalls

### Pitfall 1: Silent WebSocket Death
**What goes wrong:** WebSocket connection drops without a close event (network partition, firewall timeout, NAT timeout). Sidecar thinks it's connected but is actually disconnected.
**Why it happens:** TCP connections can go half-open when the network path is disrupted without a FIN/RST packet reaching the client.
**How to avoid:** Implement application-level heartbeat using the hub's existing ping/pong protocol. Send ping every 30s, if no pong within 10s, treat connection as dead and reconnect. The ws library automatically responds to WebSocket protocol ping frames, but application-level pings provide additional reliability.
**Warning signs:** Agent shows as connected in hub but stops receiving tasks. Hub presence shows agent as stale.

### Pitfall 2: Windows Shell Execution Differences
**What goes wrong:** Wake command works on Linux but fails silently on Windows, or vice versa.
**Why it happens:** `child_process.exec()` uses `/bin/sh` on Unix and `cmd.exe` on Windows. Path separators, quoting rules, and available commands differ.
**How to avoid:** Use `{ shell: true }` option with exec(). Document that wake_command in config.json must be platform-appropriate. Provide separate default wake commands for Linux vs Windows in config.json.example. Test wake command on both platforms during onboarding.
**Warning signs:** Wake attempts fail with ENOENT or "command not found" on one platform but work on the other.

### Pitfall 3: queue.json Corruption on Hard Crash
**What goes wrong:** Power loss or SIGKILL during a write leaves queue.json empty or with partial content.
**Why it happens:** Even with write-file-atomic, a SIGKILL can arrive between writing the temp file and the rename operation (though this window is very small).
**How to avoid:** write-file-atomic with `fsync: true` (default) minimizes the window. On recovery, if queue.json fails to parse, treat it as empty and report to hub. Don't crash on invalid JSON -- fall back to empty state.
**Warning signs:** queue.json contains 0 bytes or partial JSON after a crash.

### Pitfall 4: Git Pull Conflicts on Auto-Update
**What goes wrong:** `git pull` fails because of local modifications to tracked files, leaving sidecar running old code.
**Why it happens:** Someone modifies files in the sidecar directory directly instead of committing upstream.
**How to avoid:** Use `git pull --ff-only` which fails cleanly on diverged branches rather than creating merge conflicts. Log the failure but continue running the old code (don't block startup). The `|| true` in the wrapper script ensures the sidecar starts even if git pull fails.
**Warning signs:** Sidecar log shows git pull errors; sidecar runs stale code.

### Pitfall 5: PM2 Service User Permissions on Windows
**What goes wrong:** PM2 service runs as Local Service user but cannot access the AgentCom repo directory or execute OpenClaw commands.
**Why it happens:** pm2-installer configures pm2 to run as Local Service, which has limited filesystem access by default.
**How to avoid:** During onboarding, ensure the sidecar directory and OpenClaw installation are accessible to the Local Service user. pm2-installer sets permissions on npm/pm2 directories but not on the application directory.
**Warning signs:** Sidecar starts but git pull or wake command fails with "Access denied."

### Pitfall 6: Wake Command Timeout vs Agent Startup Time
**What goes wrong:** Agent takes longer than expected to start (cold start, package install, model download), causing false timeout and unnecessary retries.
**Why it happens:** The 30-second confirmation timeout may be too short for some agent runtimes or slow machines.
**How to avoid:** Make the confirmation timeout configurable in config.json (default 30s). Log timing data for wake attempts so operators can tune the value per agent.
**Warning signs:** Wake attempts succeed (exit code 0) but confirmation times out repeatedly, leading to unnecessary retries.

## Discretion Recommendations

These are areas marked as Claude's Discretion in CONTEXT.md. Recommendations based on research:

### 1. WebSocket Handshake: Reuse Existing Identify
**Recommendation:** Reuse the existing `identify` message format from `AgentCom.Socket`.

**Rationale:** The current identify message already supports all needed fields: `agent_id`, `token`, `name`, `status`, `capabilities`. The hub's Socket handler already validates tokens and registers agents in the Registry and Presence system. Adding a separate sidecar-specific handshake would require hub-side changes that are out of scope for this phase and would fragment the protocol.

**Implementation:** Send the standard identify message but add a `client_type: "sidecar"` field. The hub ignores unknown fields, so this is backward-compatible. Future phases can use this field to differentiate sidecar connections from interactive agent connections if needed.

```javascript
{
  type: "identify",
  agent_id: config.agent_id,
  token: config.token,
  name: config.agent_id,
  status: "idle",
  capabilities: config.capabilities || [],
  client_type: "sidecar"  // Informational, hub ignores unknown fields
}
```

### 2. Agent-to-Sidecar Result Communication: File-Based with Chokidar
**Recommendation:** Use a result file that the agent writes and the sidecar watches.

**Rationale comparison:**

| Mechanism | Pros | Cons |
|-----------|------|------|
| File watch (chokidar) | Simple, no server needed, works across all runtimes, survives sidecar restart | Requires file path convention, slight latency from polling |
| HTTP callback | Real-time, clean API | Sidecar must run HTTP server (complexity), agent must know sidecar port, firewall issues |
| Stdout capture | No extra dependencies | Only works if sidecar spawns the agent directly (not the case -- wake command spawns a session) |

File-based wins because:
- The sidecar does not spawn the agent process directly -- it invokes a wake command (e.g., `openclaw agent --message "..."`) which starts a separate session. Stdout capture is not possible.
- HTTP callback requires the sidecar to run an HTTP server, adding complexity and a second port to manage.
- File-based communication works with any runtime (OpenClaw, Claude Code CLI, future runtimes) as long as they can write a JSON file.

**Implementation:** The sidecar watches a `results/` directory. The agent writes `results/{task_id}.json` when done. The sidecar picks it up, reports to hub, and deletes the file.

```javascript
// Sidecar watches results directory
const chokidar = require('chokidar');
const resultsDir = path.join(__dirname, 'results');

chokidar.watch(resultsDir, { ignoreInitial: true })
  .on('add', (filePath) => {
    const result = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    reportResult(result);
    fs.unlinkSync(filePath);
  });
```

### 3. Protocol Versioning: Include Version Field Now (Lightweight)
**Recommendation:** Add a `protocol_version: 1` field to the sidecar identify message and all sidecar-to-hub messages.

**Rationale:** The cost is a single field per message. The benefit is forward-compatibility: when Phase 2 or later phases change the protocol, the hub can detect sidecar version and handle accordingly without requiring all sidecars to update simultaneously. Deferring versioning is a common mistake that causes painful migration later.

```javascript
// Every sidecar message includes version
{
  type: "task_complete",
  protocol_version: 1,
  task_id: "...",
  result: { ... }
}
```

### 4. queue.json Data Model: Full Task Payload
**Recommendation:** Store the full task payload in queue.json, not just ID + status.

**Rationale:** The sidecar needs to pass the full task payload to the wake command. If only the ID is stored, the sidecar would need to re-fetch the task from the hub on recovery -- but the hub connection might not be available yet during recovery. Storing the full payload makes the sidecar self-sufficient for recovery.

```json
{
  "active": {
    "task_id": "task-abc-123",
    "status": "waking",
    "description": "Implement feature X",
    "metadata": { "repo": "my-repo", "priority": "normal" },
    "assigned_at": 1707500000000,
    "wake_attempts": 1
  },
  "recovering": null
}
```

Estimated queue.json size: ~1-2 KB per task. Negligible disk and I/O cost.

### 5. Recovery Behavior: Report to Hub, Do Not Re-Wake
**Recommendation:** On restart, report `recovering` status to hub and let the hub decide.

**Rationale:** If the sidecar crashed, the agent session may or may not still be running. Re-waking could create a duplicate session. Reporting to the hub and letting it decide (based on whether the agent is still connected, whether the task has timed out, etc.) is safer and keeps intelligence on the hub.

**Implementation:**
1. On startup, load queue.json
2. If active task exists, move it to `recovering` slot
3. Connect to hub
4. Send `task_recovering` message with task details
5. Hub responds with either `task_continue` (agent is still working) or `task_reassign` (take it back)
6. On `task_continue`: keep watching for result file
7. On `task_reassign`: clear recovering slot, become idle

## Code Examples

Verified patterns from official sources:

### PM2 Ecosystem Configuration
```javascript
// ecosystem.config.js
// Source: PM2 ecosystem file documentation (pm2.io)
module.exports = {
  apps: [{
    name: 'agentcom-sidecar',
    script: process.platform === 'win32' ? 'start.bat' : 'start.sh',
    cwd: __dirname,
    autorestart: true,
    max_restarts: 50,
    restart_delay: 2000,
    max_memory_restart: '200M',
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    error_file: 'logs/sidecar-error.log',
    out_file: 'logs/sidecar-out.log',
    env: {
      NODE_ENV: 'production'
    }
  }]
};
```

### Config File Schema
```json
{
  "agent_id": "my-agent",
  "token": "abc123...",
  "hub_url": "ws://hub.example.com:4000/ws",
  "wake_command": "openclaw agent --message \"Task: ${TASK_JSON}\" --session-id ${TASK_ID}",
  "capabilities": ["code", "search"],
  "confirmation_timeout_ms": 30000,
  "results_dir": "./results",
  "log_file": "./sidecar.log"
}
```

### Task Lifecycle Log Format
```javascript
// Structured JSON lines for task lifecycle log
function log(event, data = {}) {
  const entry = {
    ts: new Date().toISOString(),
    event,
    agent_id: config.agent_id,
    ...data
  };
  fs.appendFileSync(config.log_file, JSON.stringify(entry) + '\n');
}

// Usage:
log('task_received', { task_id: 'abc', description: '...' });
log('wake_attempt', { task_id: 'abc', attempt: 1 });
log('wake_success', { task_id: 'abc', exit_code: 0 });
log('task_complete', { task_id: 'abc', duration_ms: 45000 });
```

### Cross-Platform Wake Command Execution
```javascript
// Source: Node.js child_process documentation
const { exec } = require('child_process');

function executeWakeCommand(command, task) {
  // Replace template variables in wake command
  const interpolated = command
    .replace(/\$\{TASK_ID\}/g, task.task_id)
    .replace(/\$\{TASK_JSON\}/g, JSON.stringify(task).replace(/"/g, '\\"'))
    .replace(/\$\{TASK_DESCRIPTION\}/g, task.description || '');

  return new Promise((resolve, reject) => {
    const child = exec(interpolated, {
      timeout: 60000,   // Kill if wake command itself hangs
      shell: true,      // Required for Windows .bat/.cmd files
      windowsHide: true // Don't show cmd window on Windows
    }, (error, stdout, stderr) => {
      if (error) {
        reject({ code: error.code, signal: error.signal, stderr });
      } else {
        resolve({ code: 0, stdout, stderr });
      }
    });
  });
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| HTTP polling for tasks (current SKILL.md) | WebSocket push via sidecar | Phase 1 (this phase) | Agents receive tasks instantly instead of waiting for heartbeat poll interval |
| Agent must be running to receive work | Sidecar persists tasks, wakes agent | Phase 1 (this phase) | Work survives agent session restarts; no lost tasks |
| Manual agent startup | pm2 auto-restart with sidecar | Phase 1 (this phase) | Always-on connectivity without human intervention |
| pm2-windows-service (unmaintained since 2018) | pm2-installer (jessety, active) | ~2022 | Reliable Windows service installation with modern Node.js support |
| chokidar v3 (CJS) | chokidar v4+ (ESM-only, Node 20+) | 2025 | Must use chokidar v3.x if supporting Node 18; v4+ requires ESM and Node 20+ |

**Deprecated/outdated:**
- pm2-windows-service: Unmaintained since 2018, crashes on Node 14+. Use pm2-installer instead.
- node-windows directly: Beta status, last updated 2+ years ago. Use pm2-installer which wraps it properly.
- chokidar v4: ESM-only, may cause issues if sidecar is CommonJS. Use v3 for CJS compat or ensure sidecar uses ESM.

## Open Questions

1. **OpenClaw exact wake command syntax**
   - What we know: `openclaw agent --message "..." --session-id "..."` appears to be the pattern. The `--message` flag sends a prompt to the agent.
   - What's unclear: Exact flags for background execution, how to pass structured task payload (file path vs inline JSON), whether `--deliver` is needed for result reporting.
   - Recommendation: Document a working OpenClaw wake command during implementation and make it the default in config.json.example. Since the command is configurable, imperfect defaults are fine.

2. **chokidar version compatibility (CJS vs ESM)**
   - What we know: chokidar v4+ is ESM-only and requires Node 20+. v3.x supports CJS and wider Node versions.
   - What's unclear: Whether the sidecar should be ESM or CJS. The existing scripts/ code in the repo is CJS (uses `require`).
   - Recommendation: Keep sidecar as CJS (matching existing codebase convention) and use chokidar v3.x. Simpler, wider compatibility.

3. **Hub-side changes needed for new message types**
   - What we know: The hub currently handles a fixed set of WebSocket message types (identify, message, status, etc.). The sidecar needs new types: task_accepted, task_progress, task_complete, task_failed, task_recovering.
   - What's unclear: Whether these should be added as new Socket.handle_msg clauses or handled through the existing message routing system.
   - Recommendation: This is partly Phase 2 (Task Queue) territory. For Phase 1, the hub needs minimal changes: accept the new message types in Socket and broadcast them. The task_* messages can be handled as a new category in socket.ex. This is a shared concern with Phase 2 -- coordinate.

4. **Agent confirmation callback mechanism**
   - What we know: After wake command succeeds (exit code 0), sidecar waits 30s for agent confirmation.
   - What's unclear: How exactly the agent confirms it started. If using file-based communication, the agent could write a `results/{task_id}_started.json` file. If using the hub, the agent could send a message back through the WebSocket.
   - Recommendation: Use the same file-based mechanism as result reporting. Agent writes `results/{task_id}.started` (empty file) to confirm wake. Sidecar watches for it. Simple, consistent, no extra protocol.

## Sources

### Primary (HIGH confidence)
- ws npm package (v8.19.0) -- already in project package.json, verified version matches
- Node.js child_process documentation (https://nodejs.org/api/child_process.html) -- built-in module docs
- write-file-atomic npm package (https://github.com/npm/write-file-atomic) -- README verified via WebFetch
- PM2 ecosystem file documentation (https://pm2.io/docs/runtime/reference/ecosystem-file/) -- verified via WebFetch
- pm2-installer by jessety (https://github.com/jessety/pm2-installer) -- README verified via WebFetch
- AgentCom codebase -- socket.ex, endpoint.ex, auth.ex, presence.ex, application.ex directly examined

### Secondary (MEDIUM confidence)
- PM2 log rotation documentation (https://pm2.keymetrics.io/docs/usage/log-management/) -- verified configuration options via multiple sources
- PM2 graceful shutdown (https://pm2.io/docs/runtime/best-practices/graceful-shutdown/) -- SIGINT/SIGTERM handling confirmed by multiple sources
- chokidar npm package (https://github.com/paulmillr/chokidar) -- v3/v4 split confirmed by multiple sources
- OpenClaw CLI reference (https://docs.openclaw.ai/cli) -- `agent --message` syntax verified via WebFetch

### Tertiary (LOW confidence)
- OpenClaw wake/session management exact syntax -- documentation is sparse on the exact flags for background task execution. The `openclaw agent --message` pattern was confirmed but full flag set is unclear.
- PM2 pre-start hooks -- confirmed that PM2 does NOT have a built-in pre-start hook; wrapper script approach is the standard workaround (verified via GitHub issue #5674).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- ws and write-file-atomic are well-documented, widely used libraries; pm2 is industry standard
- Architecture: HIGH -- patterns are straightforward Node.js; reconnect, atomic writes, child process execution are well-understood
- Pitfalls: HIGH -- cross-platform issues, silent WebSocket death, Windows service permissions are well-documented problem areas
- Discretion recommendations: MEDIUM -- recommendations are based on solid reasoning but involve judgment calls that may need adjustment during implementation
- OpenClaw integration: LOW -- exact wake command syntax needs validation during implementation

**Research date:** 2026-02-09
**Valid until:** 2026-03-09 (30 days -- stable domain, libraries are mature)
