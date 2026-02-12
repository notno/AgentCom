# AgentCom v2

## What This Is

A distributed agent coordination system where AI "Minds" (LLM sessions) receive work assignments from a central scheduler, execute autonomously, and submit results as PRs. Built on an Elixir/BEAM hub with Node.js sidecars, using a GPU scheduler-style push architecture for task assignment. Shipped v1.0 with 8 phases: sidecar relay, task queue, agent FSM, scheduler, smoke tests, dashboard, git workflow, and one-command onboarding.

## Core Value

Reliable autonomous work execution: ideas enter a queue and emerge as reviewed, merged PRs — without human hand-holding for safe changes.

## Current Milestone: v1.1 Hardening

**Goal:** Shore up the v1.0 foundation with comprehensive tests, data resilience, security hardening, and operational visibility.

**Target features:**
- Comprehensive test coverage (GenServers, pipelines, sidecar, edge cases)
- DETS backup, compaction, and corruption recovery
- Input validation at WebSocket and HTTP boundaries
- Structured logging, metrics endpoint, and alerting
- Rate limiting for flood protection
- Operations documentation

## Current Milestone: v1.2 Smart Agent Pipeline

**Goal:** Transform agents from blind task executors into context-aware, self-verifying workers with cost-efficient model routing across a distributed LLM mesh.

**Target features:**
- LLM endpoint registry — hub tracks Ollama instances across Tailscale mesh (multiple hosts, multiple models, health-checked)
- Enriched task format — tasks carry context, success criteria, and verification steps
- Model-aware scheduler routing — trivial tasks to cheapest local LLM, complex tasks to Claude
- Sidecar model routing — calls correct LLM endpoint (local Ollama or cloud API) based on task assignment
- Sidecar trivial execution — zero-LLM-token mechanical ops (git, file I/O, status)
- Self-verification — agents run verification steps after execution, only submit when criteria pass

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

- ✓ Token-based agent authentication (generation, verification, per-agent) — existing
- ✓ WebSocket real-time messaging (direct agent-to-agent, broadcast) — existing
- ✓ HTTP mailbox polling with cursor-based ack for offline agents — existing
- ✓ Channel-based topic messaging with subscription management — existing
- ✓ Agent presence tracking (online/offline, status updates, join/leave events) — existing
- ✓ Message history and conversation threading — existing
- ✓ DETS-backed persistence (mailbox, channels, config, threads) — existing
- ✓ Per-agent analytics and activity metrics — existing
- ✓ Basic HTML dashboard — existing
- ✓ PubSub-based real-time event distribution — existing
- ✓ Always-on sidecar process per Mind (WebSocket relay, OpenClaw wake trigger) — v1.0
- ✓ DETS-backed global task queue with priority lanes and retry semantics — v1.0
- ✓ Per-agent state machine (idle → assigned → working → done/failed/blocked) — v1.0
- ✓ Central scheduler that matches queued tasks to idle agents by capability — v1.0
- ✓ Real-time dashboard showing queue depth, agent states, task flow, system health — v1.0
- ✓ Git wrapper enforcing branch-from-current-main and PR conventions — v1.0
- ✓ One-command onboarding automation (token + sidecar + config + verify) — v1.0
- ✓ Smoke test harness (2 agents, fake low-token tasks, validates full pipeline) — v1.0

### Active

<!-- Current scope. Building toward these. -->

#### v1.1 Hardening (in progress — Phase 9 complete, Phases 10-16 remaining)

- [ ] DETS backup, compaction, and corruption recovery mechanisms
- [ ] Input validation and sanitization at WebSocket and HTTP boundaries
- [ ] Structured logging with consistent format (task_id, agent_id, phase) across all modules
- [ ] Metrics endpoint exposing queue depth, task latency, agent utilization, error rates
- [ ] Configurable alerting (webhook/push) for system anomalies
- [ ] Rate limiting to prevent message/request flooding from misbehaving agents
- [ ] Operations documentation (setup, monitoring, troubleshooting)

#### v1.2 Smart Agent Pipeline

- [ ] LLM endpoint registry with health checking across Tailscale mesh
- [ ] Enriched task format with context, success criteria, and verification steps
- [ ] Model-aware scheduler routing (complexity-based local vs cloud)
- [ ] Sidecar model routing to correct LLM endpoint per task assignment
- [ ] Sidecar trivial execution for zero-LLM-token mechanical ops
- [ ] Agent self-verification against task criteria before submission

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- PR review gatekeeper role — deferred, needs 50+ tasks of production data to calibrate heuristics
- Claude Code CLI agent runtime — deferred to v2+, research feasibility first
- Cross-hub federation — one hub is sufficient for current scale
- Multi-Mind task decomposition — breaking big tasks into parallel subtasks, future optimization
- Token budgeting — per-task token spend caps, good idea but not yet
- Learning/affinity — tracking which Mind is best at what, future optimization

## Context

Shipped v1.0 on 2026-02-11 (8 phases, 19 plans, 48 commits, +12,858 LOC across 65 files in 2 days).

**Tech stack:** Elixir/BEAM hub (~3,200 LOC), Node.js sidecars (~2,800 LOC), HTML/CSS/JS dashboard.

**Architecture:** Push-based scheduler drives work to always-on sidecars via persistent WebSocket. DETS persistence for task queue, agent state, and config. PubSub for internal event distribution. pm2 for sidecar process management.

**Current state:** All v1 problems solved (heartbeat unreliability, git chaos, coordination overhead, zero visibility, context waste, no task handshake). System operational with 5 AI agents on Tailscale mesh.

**Known tech debt:**
- queue.json atomicity (fs.writeFileSync partial-write risk on crash)
- VAPID keys ephemeral (push subscriptions lost on hub restart)
- Elixir version bump recommended (1.14 to 1.17+ for :gen_statem logger fix)
- Analytics and Threads modules orphaned (not exposed via API)

**Deferred:** PR review gatekeeper (Flere-Imsaho role) needs 50+ tasks of production data to calibrate merge/escalation heuristics.

## Constraints

- **Runtime:** Elixir/BEAM hub, Node.js sidecars (v1 runtime, may change after research)
- **Agent runtime:** OpenClaw sessions for v1, mixed runtime support deferred
- **Networking:** Tailscale mesh — hub on Nathan's machine, agents on separate machines
- **Testing:** Must validate with real distributed setup (separate machines), not just local
- **Token cost:** Smoke tests must use fake low-token tasks to validate infrastructure, not LLM capability
- **Incremental migration:** v1 and v2 coexist — existing mailbox/HTTP polling keeps working while scheduler layer is added

## Key Decisions

<!-- Decisions that constrain future work. Add throughout project lifecycle. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Branch, don't rewrite | v1 has working auth, mailbox, channels, presence, WebSocket infra | ✓ Good — v1 infra intact, scheduler layered on top cleanly |
| Node.js for sidecar | Simpler to deploy alongside OpenClaw which already uses Node | ✓ Good — zero-dependency scripts, util.parseArgs for CLI |
| OpenClaw-only for v1 | Ship proven runtime first, research Claude Code CLI for v2 | ✓ Good — shipped with OpenClaw, Claude Code CLI deferred |
| Flere-Imsaho as PR gatekeeper | Autonomous pipeline needs an LLM reviewer with merge authority | — Deferred to v2 (needs production data) |
| FIFO + priority lanes scheduling | Good enough for 4-5 agents, optimize later | ✓ Good — priority lanes working, smoke tested at 4 agents |
| DETS for persistence | Built-in Erlang, no external deps, good enough for single-hub | ✓ Good — simple, reliable, needs backup/compaction in v1.1 |
| Unauthenticated registration endpoint | Chicken-and-egg: new agents have no token yet | ✓ Good — POST /api/onboard/register solves bootstrap |
| Culture ship names for agents | Fun, memorable, avoids naming bikeshed | ✓ Good — 65 names from Iain M. Banks novels |

---
*Last updated: 2026-02-11 after v1.2 milestone definition*
