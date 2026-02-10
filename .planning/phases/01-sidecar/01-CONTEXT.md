# Phase 1: Sidecar - Context

**Gathered:** 2026-02-09
**Status:** Ready for planning

<domain>
## Phase Boundary

A lightweight Node.js process per agent that maintains a persistent WebSocket connection to the hub, receives task assignments via push, persists them locally, triggers OpenClaw session wake, and reports results back to the hub. The sidecar is a dumb relay with no decision-making — all scheduling intelligence stays on the hub.

</domain>

<decisions>
## Implementation Decisions

### Wake Mechanism
- Configurable shell command (not hardcoded to OpenClaw) — default to OpenClaw wake syntax, swappable for future runtimes
- If wake command fails: retry 3x with backoff (5s, 15s, 30s), then report failure to hub for reassignment
- Wake verification: check exit code immediately, then wait for confirmation callback from agent session within 30s timeout
- Pass full task payload to wake command (task ID + description + metadata) so agent starts with full context
- If all 3 retries fail: report to hub, hub reassigns task to another agent

### Local Queue Behavior
- Sidecar holds at most one active task + one recovering task (from pre-crash state)
- If agent is busy and new task arrives: reject back to hub (hub re-queues)
- Atomic writes to queue.json (write to temp file, rename) to prevent corruption on crash
- Local log file for task lifecycle events (received, wake attempt, success/fail, completion) — separate from pm2 logs
- Recovery on restart: report to hub with recovering status, let hub decide (reassign or re-push)

### Hub Protocol
- Sidecar-to-hub messages: task_accepted, task_progress, task_complete, task_failed — all with task payload
- Agent-to-sidecar communication: Claude decides best approach (local file, HTTP callback, or stdout)
- Protocol versioning: Claude decides based on complexity tradeoffs
- Handshake: Claude decides whether to reuse existing identify or create sidecar-specific variant

### Claude's Discretion
- WebSocket handshake design (reuse existing identify or sidecar-specific)
- Agent-to-sidecar result communication mechanism (file watch, HTTP callback, or stdout)
- Protocol versioning (include version field or defer)
- queue.json data model (minimal ID+status vs full task payload)
- Recovery behavior on restart (re-wake or report to hub)

### Deployment & Config
- Cross-platform: must work on both Windows and Linux (agents are a mix)
- Config via config.json file: agent_id, token, hub_url, wake_command, and other settings
- Sidecar lives inside the AgentCom repo (sidecar/ directory), agents clone the repo
- Auto-update on restart: sidecar pulls latest from git on pm2 restart (not periodic)
- Process manager: pm2 as primary, node-windows as fallback for Windows machines
- Managed with auto-restart and log rotation

</decisions>

<specifics>
## Specific Ideas

- The sidecar must be a "dumb relay" — no LLM, no decision-making, no token cost
- Wake command should be configurable per-agent to support future mixed runtimes (OpenClaw, Claude Code CLI, etc.)
- The 30-second confirmation timeout balances fast failure detection with allowing time for cold starts
- Rejecting new tasks when busy (instead of local queuing) keeps the hub as the single source of truth for queue state

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-sidecar*
*Context gathered: 2026-02-09*
