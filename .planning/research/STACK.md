# Stack Research

**Domain:** Distributed AI agent scheduler (v2 scheduler layer for existing Elixir/BEAM hub)
**Researched:** 2026-02-09
**Confidence:** MEDIUM-HIGH

## Scope

This document covers only the **new v2 stack additions** -- scheduler, task queue, agent state machines, Node.js sidecars, and process management. The existing Elixir/BEAM stack (Bandit, Plug, Phoenix PubSub, WebSock, Jason, DETS persistence) is documented in `.planning/codebase/STACK.md` and is not re-researched here.

---

## Recommended Stack

### Hub-Side: Scheduler & Task Queue (Elixir)

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| GenServer (stdlib) | Elixir 1.14+ / OTP 26+ | Task queue process, scheduler process | Already the dominant pattern in the codebase. DETS-backed GenServer is proven here (mailbox, channels, config all use it). Adding Oban would require Ecto + a database engine -- a massive dependency increase for a 4-5 agent system. GenServer + DETS is the right tool at this scale. | HIGH |
| DynamicSupervisor (stdlib) | Elixir 1.14+ / OTP 26+ | Supervise per-agent FSM processes | Standard OTP pattern for dynamic child processes. Each connected agent gets an AgentFSM GenServer started via `DynamicSupervisor.start_child/2`. Automatic cleanup on crash. Already used conceptually in the codebase (Registry for per-agent WebSocket processes). | HIGH |
| Registry (stdlib) | Elixir 1.14+ / OTP 26+ | Name and look up per-agent FSM processes by agent_id | Already in use for WebSocket process lookup. Extend with a second Registry for FSM processes. Via-tuple pattern (`{:via, Registry, {AgentCom.FSMRegistry, agent_id}}`) gives O(1) lookup without manual PID tracking. | HIGH |
| `:gen_statem` (OTP stdlib) | OTP 26+ | Agent state machine behaviour | Use raw `:gen_statem` instead of GenStateMachine wrapper. The GenStateMachine hex package has not been updated in 5+ years, has unresolved issues, and the Elixir community now recommends using `:gen_statem` directly (the logging issues that motivated the wrapper were fixed in Elixir core). `:gen_statem` provides state timeouts, state-enter callbacks, and clean state/data separation -- all needed for agent lifecycle management. | HIGH |
| Process.send_after (stdlib) | Elixir 1.14+ | Periodic scheduler ticks, stuck-task detection | Simpler and more testable than `:timer` for periodic work. The scheduler fires on events (new task, agent idle) but also needs a periodic sweep (every 30s per the v2 plan) for stuck assignments. `Process.send_after(self(), :tick, 30_000)` in a GenServer is the standard pattern. | HIGH |
| Phoenix.PubSub | ~> 2.1 (already dep) | Event broadcasting for scheduler triggers | Already a dependency. Scheduler subscribes to events like `{:agent_idle, agent_id}`, `{:task_created, task_id}`, `{:agent_disconnected, agent_id}`. No new dependency needed. | HIGH |

### Hub-Side: Persistence

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| DETS (OTP stdlib) | OTP 26+ | Task queue persistence | Consistent with v1 architecture (mailbox, channels, config all use DETS). For 4-5 agents and dozens of tasks, DETS is sufficient. Avoids introducing Ecto + database engine. The task queue GenServer holds state in memory (ETS or map) and persists to DETS on writes, same pattern as existing modules. | HIGH |

### Sidecar: Node.js WebSocket Client

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| ws | ^8.18.0 | WebSocket client connection to hub | De facto Node.js WebSocket library. 35M+ weekly npm downloads. Already a dependency in the project (`package.json` has `ws@8.19.0`). Lightweight, no unnecessary abstractions. Battle-tested. | HIGH |
| Custom reconnect wrapper over ws | N/A (hand-rolled) | Exponential backoff reconnection | Do NOT use `reconnecting-websocket` (unmaintained, last publish 6 years ago, version 4.4.0). Do NOT use `ws-reconnect` (minimal maintenance, small user base). The reconnection logic is ~50 lines of code: exponential backoff (1s, 2s, 4s... cap 60s), `close` event handler, `setTimeout` with jitter. Rolling your own on top of `ws` is safer than depending on an abandoned library for a critical always-on process. | HIGH |
| Node.js built-in fs | N/A (stdlib) | Local task queue persistence (queue.json) | Use `fs.writeFileSync` / `fs.readFileSync` for the local `queue.json` file. No need for a database or library. The sidecar stores at most a handful of pending tasks. Atomic writes via write-to-temp-then-rename pattern for crash safety. | HIGH |
| child_process (Node.js stdlib) | N/A (stdlib) | Spawn `openclaw cron wake` on task arrival | `child_process.execFile()` to trigger OpenClaw. No shell injection risk (execFile, not exec). Capture stdout/stderr for logging. | HIGH |

### Sidecar: Process Management

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| pm2 | ^6.0.14 | Keep sidecar processes alive, auto-restart, log management | Cross-platform (Windows + Linux), built-in log rotation, restart on crash, startup script generation. The v2 plan calls for multiple sidecars per machine. pm2 handles this natively (`pm2 start sidecar/index.js --name "gcu-sidecar"`). Simpler than systemd for a multi-platform setup running on Tailscale. | HIGH |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| `mix test` | Hub-side testing | Standard Elixir test runner. Test scheduler, task queue, FSM in isolation. |
| `pm2 logs` | Sidecar log inspection | Real-time log tailing across all sidecar processes. |
| `pm2 monit` | Sidecar resource monitoring | CPU/memory per sidecar process. Answers the v2 open question about resource usage. |

---

## Installation

### Hub-Side (Elixir)

No new dependencies required. All recommended technologies are OTP/Elixir stdlib:

```elixir
# mix.exs -- NO CHANGES NEEDED for scheduler layer
# :gen_statem, DynamicSupervisor, Registry, Process.send_after are all stdlib
# Phoenix.PubSub is already a dependency
# DETS is OTP stdlib
```

If you later decide to adopt Oban for task persistence (see Alternatives below), you would add:

```elixir
# ONLY if migrating to Oban later:
{:oban, "~> 2.20"},
{:ecto_sql, "~> 3.11"},
{:ecto_sqlite3, "~> 0.17"}  # or {:postgrex, "~> 0.19"} for PostgreSQL
```

### Sidecar (Node.js)

```bash
# In sidecar/ directory
npm init -y
npm install ws@^8.18.0

# Process management (install globally on each agent machine)
npm install -g pm2@latest
```

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not Alternative |
|----------|-------------|-------------|---------------------|
| Agent state machine | `:gen_statem` (OTP stdlib) | `gen_state_machine` hex package (v3.0.0) | Unmaintained for 5+ years. Unresolved issues and PRs. The logging fix that motivated its creation was merged into Elixir core. Community consensus (Feb 2025 Elixir Forum): use `:gen_statem` directly. |
| Agent state machine | `:gen_statem` (OTP stdlib) | Plain GenServer with case/cond state dispatch | GenServer conflates "state" (data the process holds) with "state" (which mode it's in). `:gen_statem` cleanly separates state (idle/working/assigned) from data (current task, session info). State timeouts are built in -- critical for "assigned but not working for 5 minutes" detection. |
| Task queue | GenServer + DETS | Oban v2.20.3 (with SQLite3 or PostgreSQL) | Oban requires Ecto + a database adapter. The current codebase has zero Ecto dependency. Adding Ecto + ecto_sqlite3 + Oban adds ~15 transitive dependencies and a migration system. Oban's strengths (multi-node coordination, crash-safe job persistence, retries, scheduling) are valuable for high-scale systems -- but AgentCom has 4-5 agents, one hub, and the existing DETS pattern is proven. Oban is the right upgrade path if the system scales beyond ~20 agents or needs multi-hub. |
| Task queue | GenServer + DETS | Honeydew (hex) | Abandoned. Last commit years ago. Not compatible with modern Elixir/OTP versions. |
| WebSocket reconnect | Custom wrapper over ws | `reconnecting-websocket` (npm v4.4.0) | Last published 6 years ago. Not maintained. The sidecar is the most critical always-on component in v2 -- do not depend on abandoned libraries for its core connectivity. |
| WebSocket reconnect | Custom wrapper over ws | `ws-reconnect` (npm) | Small user base, minimal maintenance. Not worth the dependency for ~50 lines of reconnection logic. |
| Process management | pm2 | systemd | systemd is Linux-only. The project runs across Windows + Linux machines on Tailscale. pm2 is cross-platform and has built-in Node.js-specific features (cluster mode, log rotation, startup scripts). |
| Process management | pm2 | Docker | Adds containerization overhead to what is a single-file Node.js process. The sidecar is meant to be lightweight. Docker would be appropriate if the sidecar grows into a multi-service system, but for a WebSocket relay + process spawner, pm2 is the right weight class. |
| Periodic scheduling | Process.send_after | `node-cron` / `:timer` | For Elixir-side periodic ticks, `Process.send_after` is idiomatic and testable. For Node.js sidecar heartbeats, `setInterval` is sufficient -- no cron library needed for a 30-second ping. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `gen_state_machine` hex package | Unmaintained 5+ years. Community has moved on. Adds unnecessary dependency for something OTP provides natively. | `:gen_statem` (OTP stdlib) |
| Oban (for now) | Requires Ecto + database adapter. Massive dependency increase for a 4-5 agent system. The codebase has no Ecto -- introducing it changes the entire persistence story. | GenServer + DETS (consistent with v1 patterns) |
| `reconnecting-websocket` npm | Last published 2018. Unmaintained. Critical path dependency for sidecar connectivity. | Custom ~50 line reconnect wrapper over `ws` |
| Redis / RabbitMQ / Kafka | External service dependencies. AgentCom runs on Tailscale across personal machines. No need for message broker infrastructure at this scale. | Phoenix.PubSub (already in use, in-process) |
| Ecto | No database exists in v1. Adding Ecto means adding migrations, a database engine, connection pooling, and schema modules. This is the right move only if you outgrow DETS (>1000 tasks, need queries, need transactions). | DETS for persistence, ETS for hot state |
| Socket.IO | Heavy abstraction layer. The hub already speaks raw WebSocket via Bandit/WebSock. The sidecar needs a raw WebSocket client, not a framework. | `ws` npm package |

---

## Stack Patterns by Variant

**If staying at 4-5 agents (current plan):**
- Use GenServer + DETS for task queue (consistent with v1)
- Use `:gen_statem` for agent FSMs
- Use DynamicSupervisor + Registry for FSM lifecycle
- Use pm2 for sidecar management
- This is the recommended path

**If scaling to 10-20+ agents:**
- Consider migrating task queue to Oban + SQLite3 (via ecto_sqlite3)
- SQLite3 is embedded (no server process), but gives you SQL queries, transactions, and Oban's retry/scheduling semantics
- This is a natural evolution, not a rewrite -- the GenServer interface stays the same, only the backing store changes

**If scaling to multi-hub / multi-node:**
- Oban + PostgreSQL becomes necessary (SQLite doesn't support concurrent writers from multiple nodes)
- `:pg` (OTP process groups) for cross-node FSM coordination
- Horde or Pogo for distributed supervisor
- This is explicitly out of scope per the v2 plan

---

## Version Compatibility

| Component | Compatible With | Notes |
|-----------|-----------------|-------|
| Elixir ~> 1.14 (project requirement) | OTP 24-26 | Current project specifies `elixir: "~> 1.14"` in mix.exs. `:gen_statem` available since OTP 19. Consider bumping to `~> 1.17` to get OTP 27 support and the gen_statem logging fixes that eliminate need for GenStateMachine wrapper. |
| Elixir 1.19.5 (latest stable) | OTP 26-28 | If upgrading Elixir, 1.19 is the latest stable with OTP 27/28 support. |
| ws@^8.18.0 | Node.js 18+ | ws 8.x dropped support for Node.js <18. Verify Node.js version on agent machines. |
| pm2@^6.0.14 | Node.js 18+ | pm2 6.x is the latest major. Supports Node.js 18+. |
| Phoenix.PubSub ~> 2.1 | Elixir 1.14+ | Already a dependency. No version change needed. |
| Bandit ~> 1.0 | Elixir 1.14+ | Already a dependency. Handles the WebSocket upgrade for sidecar connections. |

---

## Elixir Version Recommendation

The project currently requires `elixir: "~> 1.14"`. Consider bumping to `"~> 1.17"` before starting v2 work:

- **Why:** Elixir 1.17+ includes the `:gen_statem` logger translation fix that makes the GenStateMachine wrapper unnecessary. On Elixir 1.14-1.16, raw `:gen_statem` error messages may not format cleanly in Elixir Logger.
- **Impact:** Low risk. The codebase uses standard OTP patterns with no version-specific features.
- **OTP:** Bumping to Elixir 1.17+ drops OTP 24 support but gains OTP 27 support. OTP 26+ is recommended.
- **Confidence:** MEDIUM (based on Elixir Forum discussion, not directly verified in Elixir changelog)

---

## Key Decision: Why NOT Oban

This deserves explicit justification because Oban is the default recommendation for Elixir job queues in 2025-2026.

**Oban is the right tool when you have:**
- An existing Ecto/database setup
- Multi-node deployments needing coordinated job execution
- Hundreds or thousands of jobs per minute
- Need for scheduled/recurring jobs with cron-like semantics
- Complex retry policies, rate limiting, job dependencies

**AgentCom does NOT have:**
- Any Ecto dependency (zero database)
- Multi-node deployment (single hub on one machine)
- High job throughput (4-5 agents, maybe 20 tasks/day)
- Need for scheduled recurring jobs (scheduler is event-driven)

**What AgentCom DOES have:**
- A proven DETS + GenServer persistence pattern used across 6 modules
- A team (of AI agents) already familiar with that pattern
- A constraint to keep the system lightweight and deployable on a personal machine

**Verdict:** Build the task queue as a GenServer + DETS (matching the existing codebase pattern), with a clean interface that could be swapped to an Oban backend later if needed. The `TaskQueue` GenServer should expose a clean API (`create_task/1`, `claim_task/1`, `complete_task/2`, `fail_task/2`) that abstracts the backing store.

---

## Sources

- [GenStateMachine v3.0.0 hexdocs](https://hexdocs.pm/gen_state_machine/GenStateMachine.html) -- verified version, feature set (HIGH confidence)
- [Elixir Forum: Use GenStateMachine or :gen_statem?](https://elixirforum.com/t/use-genstatemachine-or-gen-statem/69441) -- community consensus to use raw :gen_statem (MEDIUM confidence, forum discussion)
- [Elixir compatibility and deprecations](https://hexdocs.pm/elixir/compatibility-and-deprecations.html) -- Elixir 1.19.5 latest, OTP version matrix (HIGH confidence, official docs)
- [DynamicSupervisor docs](https://hexdocs.pm/elixir/DynamicSupervisor.html) -- per-agent process pattern (HIGH confidence, official docs)
- [Oban v2.20.3 hexdocs](https://hexdocs.pm/oban/Oban.html) -- requires Ecto repo, supports PostgreSQL/MySQL/SQLite3 (HIGH confidence, official docs)
- [Oban hex.pm](https://hex.pm/packages/oban) -- latest version 2.20.3, Jan 22 2026 (HIGH confidence, package registry)
- [ws npm package](https://github.com/websockets/ws) -- v8.19.0, 35M weekly downloads (HIGH confidence, official repo)
- [reconnecting-websocket npm](https://www.npmjs.com/package/reconnecting-websocket) -- v4.4.0, published 6 years ago, unmaintained (HIGH confidence, npm registry)
- [pm2 npm](https://www.npmjs.com/package/pm2) -- v6.0.14, active maintenance (HIGH confidence, npm registry)
- [pm2 vs systemd comparison](https://cryeffect.net/2025/pm2/) -- cross-platform advantages (MEDIUM confidence, blog post)
- [Elixir distributed task patterns](https://hexdocs.pm/elixir/distributed-tasks.html) -- GenServer + DETS patterns (HIGH confidence, official docs)
- [WebSocket reconnection with exponential backoff](https://dev.to/hexshift/robust-websocket-reconnection-strategies-in-javascript-with-exponential-backoff-40n1) -- implementation patterns (MEDIUM confidence, tutorial)
- [ecto_sqlite3 adapter](https://github.com/elixir-sqlite/ecto_sqlite3) -- embedded SQLite for future Oban migration path (HIGH confidence, official repo)
- [Oban Starts Where Tasks End](https://oban.pro/articles/oban-starts-where-tasks-end) -- GenServer vs Oban tradeoffs (MEDIUM confidence, vendor article)

---

*Stack research for: AgentCom v2 scheduler layer*
*Researched: 2026-02-09*
