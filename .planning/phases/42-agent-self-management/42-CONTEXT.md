# Phase 42: Agent Self-Management — Discussion Context

## Approach

Give sidecars awareness of their own pm2 process and the ability to restart themselves on hub command.

### pm2 Self-Awareness
- Sidecar reads its own pm2 process name from `PM2_PROCESS_NAME` env var (set in ecosystem.config.js)
- If not set, discovers via `pm2 jlist` and matches by PID
- New `sidecar/lib/pm2-manager.js`:
  - `getStatus()` — returns own process status (online/stopped/errored)
  - `getInfo()` — returns process name, uptime, restart count, memory usage

### Self-Restart
- `gracefulRestart()`:
  1. If executing a task: finish current task, send `task_complete` or `task_failed`
  2. Send `agent_restarting` status to hub
  3. Call `process.exit(0)` — pm2 auto-restarts (configured with `autorestart: true`)
  4. On restart: sidecar picks up from clean state, re-identifies to hub

### Hub-Commanded Restart
- New WebSocket message type: `restart_sidecar`
- Hub sends `{type: "restart_sidecar", reason: "..."}` to specific agent
- Sidecar receives, calls `gracefulRestart()`
- Hub-side: new API endpoint or healing action to trigger restart

## Key Decisions

- **Sidecar restarts only itself** — hub commands the restart, sidecar executes on itself. No peer restarts.
- **Graceful shutdown** — always finish current task before restarting
- **pm2 auto-restart handles the actual restart** — sidecar just exits cleanly
- **Env var for process name** — simpler than pm2 API discovery

## Files to Create/Modify

- NEW: `sidecar/lib/pm2-manager.js` — pm2 awareness and restart
- `sidecar/index.js` — handle `restart_sidecar` WebSocket message, graceful shutdown
- `sidecar/ecosystem.config.js` — add `PM2_PROCESS_NAME` env var
- `lib/agent_com/endpoint.ex` — handle `restart_sidecar` WebSocket message (hub side)

## Risks

- LOW — pm2 restart is well-understood, graceful shutdown is straightforward
- Edge case: what if task is mid-LLM-call when restart is commanded? Need to handle abort.

## Success Criteria

1. Sidecar can query its own pm2 process name and running status
2. Sidecar can trigger its own graceful restart via pm2
3. Hub sends restart command over WebSocket, sidecar executes graceful pm2 restart
