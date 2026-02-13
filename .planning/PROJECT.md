# AgentCom v2

## What This Is

A distributed agent coordination system where AI "Minds" (LLM sessions) receive work assignments from a central scheduler, execute autonomously using the right LLM backend for each task's complexity, self-verify their work against structured criteria, and submit results as PRs. Built on an Elixir/BEAM hub with Node.js sidecars, using a GPU scheduler-style push architecture with model-aware routing across a distributed LLM mesh.

## Core Value

Reliable autonomous work execution: ideas enter a queue and emerge as reviewed, merged PRs — without human hand-holding for safe changes.

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
- ✓ Comprehensive test infrastructure with DETS isolation, test factories, CI pipeline — v1.1
- ✓ DETS backup, compaction, corruption recovery with degraded mode — v1.1
- ✓ Input validation at all 27 entry points with schema-as-data and violation tracking — v1.1
- ✓ Structured JSON logging with 22 telemetry events and token redaction — v1.1
- ✓ Metrics endpoint with queue depth, latency percentiles, agent utilization, error rates — v1.1
- ✓ Configurable alerter with 5 rules, cooldowns, dashboard integration — v1.1
- ✓ Token bucket rate limiting with per-action granularity and progressive backoff — v1.1
- ✓ Operations documentation (setup, monitoring, troubleshooting) with ExDoc — v1.1
- ✓ LLM endpoint registry with health checking across Tailscale mesh — v1.2
- ✓ Enriched task format with context, success criteria, and verification steps — v1.2
- ✓ Model-aware scheduler routing (complexity-based local vs cloud) — v1.2
- ✓ Sidecar model routing to correct LLM endpoint per task assignment — v1.2
- ✓ Sidecar trivial execution for zero-LLM-token mechanical ops — v1.2
- ✓ Agent self-verification against task criteria before submission — v1.2
- ✓ Multi-repo registry with workspace switching and scheduler filtering — v1.2

### Active

<!-- Current scope. Building toward these. -->

## Current Milestone: v1.3 Hub FSM Loop of Self-Improvement

**Goal:** Make the hub an autonomous thinker that cycles through executing goals, improving codebases, contemplating future features, and resting — with Ralph-style inner loops and LLM-powered decomposition.

**Target features:**
- Hub FSM with 4 states (Executing, Improving, Contemplating, Resting) and queue-driven transitions
- Centralized goal backlog with multiple input channels (API, CLI, file)
- LLM-powered goal decomposition (Claude API) into enriched tasks for existing pipeline
- Ralph-style inner loops with success criteria verification per goal
- Autonomous codebase improvement scanning across repos in priority order
- Tiered autonomy (small improvements auto-merge, larger ones create PRs)
- Future feature contemplation and proposal writing
- Pre-publication repo cleanup (token scrubbing, IP removal, workspace files, personal refs)
- Scalability analysis (bottlenecks, machine vs agent scaling tradeoffs)
- Pipeline pipelining (front-loading discussion/research for parallel execution)

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- PR review gatekeeper role — deferred, needs 50+ tasks of production data to calibrate heuristics
- Claude Code CLI agent runtime — deferred to v2+, research feasibility first
- Cross-hub federation — one hub is sufficient for current scale
- Multi-Mind task decomposition — breaking big tasks into parallel subtasks, future optimization
- Token budgeting — per-task token spend caps, good idea but not yet
- Learning/affinity — tracking which Mind is best at what, future optimization
- Database migration (DETS to SQLite/Postgres) — DETS works at current scale, migration rewrites 6 GenServers
- Full Prometheus/Grafana stack — overkill for 5-agent system, built-in metrics sufficient
- Distributed rate limiting (Redis/Mnesia) — single BEAM node, no benefit
- LiteLLM/OpenAI gateway proxy — AgentCom routes tasks, not tokens
- LLM-based complexity classifier — burns tokens to save tokens, needs production data first
- Dynamic model loading/unloading — operational complexity, models should be pre-loaded by operator
- Streaming LLM output through hub — adds latency for zero coordination value
- Agent-to-agent delegation — bypasses central scheduler
- Warm/cold model VRAM distinction — binary availability sufficient for routing (REG-03 accepted tech debt)

## Context

Shipped v1.0 on 2026-02-11 (8 phases, 19 plans, 48 commits, +12,858 LOC across 65 files in 2 days).
Shipped v1.1 on 2026-02-12 (8 phases, 32 plans, 153 commits, +35,732 LOC across 195 files in 4 days).
Shipped v1.2 on 2026-02-12 (7 phases, 25 plans, 136 commits, +26,075 LOC across 147 files in 1 day).

**Tech stack:** Elixir/BEAM hub (~22,000 LOC), Node.js sidecars (~4,500 LOC), HTML/CSS/JS dashboard, ExDoc documentation.

**Architecture:** Push-based scheduler with model-aware routing drives work to always-on sidecars via persistent WebSocket. Tasks carry structured context, success criteria, and complexity classification. Scheduler routes by complexity tier: trivial to local shell, standard to Ollama endpoints, complex to Claude API. Sidecars execute via three backends and self-verify against mechanical checks before submission. DETS persistence for task queue, agent state, LLM registry, repo registry, and config with automated backup/compaction/recovery. ETS-backed metrics, rate limiting, and validation tracking. PubSub for internal event distribution. pm2 for sidecar process management. LoggerJSON for structured observability.

**Current state:** All v1.0, v1.1, and v1.2 features shipped. System delivers a complete smart agent pipeline from task submission through complexity-routed execution to self-verified completion. Operational with 5 AI agents on Tailscale mesh.

**Known tech debt:**
- REG-03: Warm/cold model distinction deferred (binary availability used instead)
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
| DETS for persistence | Built-in Erlang, no external deps, good enough for single-hub | ✓ Good — backup/compaction/recovery added in v1.1 |
| Unauthenticated registration endpoint | Chicken-and-egg: new agents have no token yet | ✓ Good — POST /api/onboard/register solves bootstrap |
| Culture ship names for agents | Fun, memorable, avoids naming bikeshed | ✓ Good — 65 names from Iain M. Banks novels |
| Pure Elixir validation (no Ecto) | Flat JSON validation doesn't need ORM overhead | ✓ Good — pattern matching + guards, schema-as-data for introspection |
| ETS for hot-path data (metrics, rate limits, validation) | Concurrent read access without GenServer bottleneck | ✓ Good — zero-cost reads, GenServer handles writes |
| LoggerJSON with dual output | Structured JSON for machines, readable for humans | ✓ Good — stdout + rotating file, token redaction built in |
| Lazy token bucket rate limiting | Zero background cost per agent, compute on access | ✓ Good — integer precision, monotonic time, progressive backoff |
| ExDoc for operations docs | Built-in Elixir tooling, Mermaid support via CDN | ✓ Good — zero build step, cross-references to module docs |
| Binary model availability (not warm/cold) | Warm/cold VRAM tracking adds complexity without routing benefit at current scale | ✓ Good — scheduler routes successfully on binary availability |
| Complexity heuristic with keyword override | Short commands like "refactor auth" must route to complex tier | ✓ Good — keyword signals override word-count majority voting |
| Three-executor sidecar architecture | Clean separation: OllamaExecutor, ClaudeExecutor, ShellExecutor | ✓ Good — dispatcher selects per routing_decision, cost calc centralized |
| Build-verify-fix retry pattern | Safe default: 0 retries, opt-in with max 5 cap | ✓ Good — corrective prompts include pass+fail checks to prevent regression |
| Single DETS key for repo ordering | Atomic reordering without multi-key consistency issues | ✓ Good — ordered list under :repos key, priority preserved |

---
*Last updated: 2026-02-12 after v1.3 milestone start*
