# AgentCom v2

## What This Is

A distributed agent coordination system where AI "Minds" (LLM sessions) receive work assignments from a central scheduler, execute autonomously, and submit results as PRs. Built on an Elixir/BEAM hub that already handles auth, messaging, presence, and WebSocket transport. v2 evolves this from a message-passing system into a GPU scheduler-style architecture with push-based task assignment.

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

- [ ] Comprehensive test coverage for all GenServers and core pipelines
- [ ] Sidecar test suite (WebSocket relay, queue management, wake trigger, git workflow)
- [ ] DETS backup, compaction, and corruption recovery mechanisms
- [ ] Input validation and sanitization at WebSocket and HTTP boundaries
- [ ] Structured logging with consistent format (task_id, agent_id, phase) across all modules
- [ ] Metrics endpoint exposing queue depth, task latency, agent utilization, error rates
- [ ] Configurable alerting (webhook/push) for system anomalies
- [ ] Rate limiting to prevent message/request flooding from misbehaving agents
- [ ] Operations documentation (setup, monitoring, troubleshooting)

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- PR review gatekeeper role — deferred, needs 50+ tasks of production data to calibrate heuristics
- Claude Code CLI agent runtime — deferred to v2+, research feasibility first
- Cross-hub federation — one hub is sufficient for current scale
- Multi-Mind task decomposition — breaking big tasks into parallel subtasks, future optimization
- Token budgeting — per-task token spend caps, good idea but not yet
- Learning/affinity — tracking which Mind is best at what, future optimization

## Context

AgentCom v1 was built in a single day with 5 Minds connected. It proved the concept of autonomous multi-agent collaboration but surfaced critical reliability issues:

- **Heartbeat unreliability:** Cron-triggered sessions often didn't fire, making Minds appear alive but idle
- **Git chaos:** Agents branching from stale main, causing merge conflicts and wasted coordinator time
- **Coordination overhead:** More tokens spent on status broadcasts and "are you there?" pings than actual work
- **Zero visibility:** Nathan had no way to check system state without asking an agent directly
- **Context waste:** Agents burning context windows while waiting for assignments
- **No task handshake:** Work assigned with no confirmation it was received or started

The v2 architecture (proposed by Nathan, designed by GCU Conditions Permitting) shifts from pull-based mailbox polling to push-based scheduler-driven work assignment. The existing messaging layer remains — the scheduler is built on top.

Flere-Imsaho's role evolves from coordinator to **gatekeeper with merge authority**: reviews PRs, auto-merges safe changes, escalates to Nathan when PRs touch infra/config, have large deletions/rewrites, are security-sensitive, or could have chaotic ripple effects across multiple agents.

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
| Branch, don't rewrite | v1 has working auth, mailbox, channels, presence, WebSocket infra | — Pending |
| Node.js for sidecar (tentative) | Simpler to deploy alongside OpenClaw which already uses Node | — Pending |
| OpenClaw-only for v1 | Ship proven runtime first, research Claude Code CLI for v2 | — Pending |
| Flere-Imsaho as PR gatekeeper | Autonomous pipeline needs an LLM reviewer with merge authority | — Pending |
| FIFO + priority lanes scheduling | Good enough for 4-5 agents, optimize later | — Pending |

---
*Last updated: 2026-02-11 after milestone v1.1 start*
