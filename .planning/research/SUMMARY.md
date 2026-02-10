# Project Research Summary

**Project:** AgentCom v2 Scheduler Layer
**Domain:** Distributed AI agent scheduler / orchestration system
**Researched:** 2026-02-09
**Confidence:** MEDIUM-HIGH

## Executive Summary

AgentCom v2 is a distributed AI agent scheduler that adds a coordinated task orchestration layer on top of an existing Elixir/BEAM message hub. The system coordinates 4-5 autonomous LLM agents (running in OpenClaw sessions) that write code, open PRs, and perform software development tasks. The v1 system used a pull-based polling model that wasted tokens and provided zero visibility, leading to operational failures.

The recommended approach follows the Scheduler-Agent-Supervisor pattern (Microsoft Azure Architecture): a central scheduler on the Elixir hub matches queued tasks to idle agents, pushing assignments over WebSocket through persistent Node.js sidecars. Each agent gets a state machine (idle/assigned/working) tracked by the hub. The hub persists tasks to DETS (Erlang's disk storage), using standard OTP patterns (GenServer, DynamicSupervisor, Registry) without introducing new dependencies. The sidecar architecture solves the "LLM session not always alive" problem by maintaining persistent connectivity and waking OpenClaw sessions on-demand.

Key risks include: (1) coordination overhead exceeding actual work tokens—v1 already hit this problem and v2 must aggressively minimize protocol messages; (2) sidecar becoming a single point of failure per agent, requiring robust process supervision and crash recovery; (3) git workflow enforcement failing and agents branching from stale main—v1's most painful operational issue. The research identifies 10 critical pitfalls with specific prevention strategies tied to implementation phases.

## Key Findings

### Recommended Stack

AgentCom v2 requires **zero new Elixir dependencies**—everything needed exists in OTP/Elixir stdlib. The hub-side scheduler layer uses GenServer for singleton state (Scheduler, TaskQueue), DynamicSupervisor + Registry for per-agent FSM processes, :gen_statem for agent state machines, and DETS for task persistence (consistent with v1's pattern used in 6 existing modules). Phoenix.PubSub (already a dependency) handles event distribution. The sidecar uses the `ws` npm package (already in project) with a hand-rolled reconnection wrapper—do NOT use `reconnecting-websocket` (abandoned 6 years ago). Process management via pm2 (cross-platform, Windows + Linux) keeps sidecars alive with auto-restart and log rotation.

**Core technologies:**
- **GenServer + DETS (OTP stdlib)**: Task queue and scheduler processes — proven pattern throughout v1 codebase, sufficient for 4-5 agents, avoids introducing Ecto + database for what is fundamentally a lightweight coordination system
- **:gen_statem (OTP stdlib)**: Agent state machine behavior — native OTP, not the unmaintained GenStateMachine hex package; provides state timeouts and clean state/data separation needed for FSM lifecycle
- **DynamicSupervisor + Registry (OTP stdlib)**: Per-agent FSM process management — canonical Elixir pattern for per-entity concurrent processes with O(1) lookup via via-tuple
- **ws npm ^8.18.0**: WebSocket client in sidecar — de facto Node.js WebSocket library (35M+ weekly downloads), already in project dependencies
- **pm2**: Sidecar process supervision — cross-platform with built-in log rotation and crash recovery, handles multiple sidecars per machine natively

**Key decision: Why NOT Oban** — Oban is the standard Elixir job queue library, but requires Ecto + database adapter (15+ transitive dependencies). The codebase has zero Ecto dependency. Oban's strengths (multi-node coordination, crash-safe job persistence, complex retry policies) are valuable at high scale, but AgentCom has 4-5 agents and the existing DETS pattern is proven. Oban is the right upgrade path at 20+ agents or multi-hub deployment.

### Expected Features

**Must have (table stakes):**
- **Persistent task queue with priority lanes** — every production scheduler needs durable work storage with urgent/high/normal/low priority; DETS-backed queue already designed in v2 plan
- **Agent state machine (idle/assigned/working/done/failed)** — Scheduler-Agent-Supervisor pattern requires explicit agent states to know who can receive work; v1's flat presence map conflated "connected" with "available"
- **Push-based task assignment** — pull-based polling (v1's mailbox) wastes tokens and introduces latency; push via WebSocket is how modern orchestrators deliver work; sidecar solves the "LLM session isn't always alive" problem
- **Failure handling with retry and dead-letter** — tasks fail, agents disconnect, timeouts expire; every production queue has retry with backoff and dead-letter for permanently failed tasks
- **Heartbeat / liveness detection** — WebSocket connection state IS the heartbeat in v2 (simpler than v1's unreliable reaper); still need timeout for "connected but not responding"
- **Basic observability (system state query)** — Nathan's #1 complaint was zero visibility; need queryable API endpoint before HTML dashboard (API first, dashboard second)

**Should have (competitive advantage):**
- **Git workflow enforcement (branch-from-current-main wrapper)** — directly addresses v1's worst pain (Loash branching from stale main 3 times); shell script bundled with sidecar makes correct workflow the only workflow
- **PR review gatekeeper agent (Flere-Imsaho)** — autonomous agents need quality gate before merge; gatekeeper auto-merges safe changes and escalates risky ones to Nathan; creates genuine autonomous pipeline (idea → queue → PR → merged)
- **One-command agent onboarding** — v1 onboarding was "a mess"; generate tokens, create sidecar config, install as service, verify connection—all automated
- **Capability-based routing** — scheduler matches `needed_capabilities` on tasks to declared capabilities on agents (languages, tools, access); domain-aware routing beyond generic queue-name routing
- **Real-time dashboard with task flow visualization** — shows full pipeline (idea → queued → assigned → working → PR → reviewed → merged); v2 answer to v1's "zero visibility"

**Defer (v2+):**
- **PR review gatekeeper** — requires proven scheduler + git workflow + clear escalation heuristics; build after 50+ tasks flow through pipeline and patterns emerge
- **Token-aware scheduling** — factor token budget and context-window headroom into assignment decisions; needs token usage data from production to calibrate
- **Multi-agent task decomposition** — at 4-5 agents, decomposition overhead exceeds parallel execution gains; AutoGen's agent-to-agent conversations cost 4x tokens vs directed execution
- **Learning / affinity engine** — track which agent is best at what; sample size too small for statistical learning at 4-5 agents (need hundreds of completions per agent per category)

### Architecture Approach

AgentCom v2 adds a 4th layer (Scheduler Layer) on top of existing v1 architecture: Transport (Bandit WebSocket) → Messaging (Phoenix.PubSub + Registry) → State (Auth, Presence, Mailbox, Channels) → **NEW: Scheduling (Scheduler, TaskQueue, AgentFSM)**. The scheduler is a singleton GenServer on the hub that matches queued tasks to idle agents, reacting to events (task created, agent idle, agent disconnect) with a 30s timer sweep for stuck assignments. TaskQueue is a singleton GenServer wrapping a DETS table with CRUD operations. AgentFSM is one GenServer per connected agent, started by DynamicSupervisor and registered via Registry—each agent gets its own failure domain. Sidecars (Node.js processes on agent machines) maintain persistent WebSocket connections, receive task pushes, wake OpenClaw sessions, and forward results back.

**Major components:**
1. **Scheduler (GenServer)** — matches queued tasks to idle agents; event-driven (new task, agent idle, agent disconnect) + 30s sweep; singleton on hub
2. **TaskQueue (GenServer)** — owns global work queue; CRUD for tasks; DETS persistence; priority ordering and retry semantics; singleton on hub
3. **AgentFSM (GenServer per agent)** — per-agent work-state tracking (idle/assigned/working/done/failed); one process per connected agent under DynamicSupervisor; registered via Registry for O(1) lookup
4. **Sidecar (Node.js)** — always-on WebSocket client per agent machine; receives task pushes, wakes OpenClaw session, forwards results; heartbeat maintains liveness
5. **Git Wrapper (Shell script)** — bundled with sidecar; enforces branch-from-current-main workflow; three commands: start-task, submit, status

**Key patterns:**
- Singleton GenServer for global state (Scheduler, TaskQueue) — entire v1 codebase uses this pattern
- DynamicSupervisor + Registry for per-entity processes (AgentFSM) — canonical Elixir pattern for concurrent per-agent state machines
- Event-driven scheduler with timer sweep — reactive to discrete events (not polling), timer is safety net for stuck assignments
- Push-based task assignment over WebSocket — scheduler calls AgentFSM.assign() → AgentFSM sends to Socket via Registry PID → Socket pushes WebSocket frame to sidecar

### Critical Pitfalls

1. **At-least-once delivery without idempotent task execution** — task re-queued on disconnect, second agent picks it up, now two PRs for same task. Prevention: git branches named `{agent}/{task-id}` (not slug), check for existing branch/PR before starting work, track assignment generation numbers, deduplicate completions.

2. **Coordination tax exceeds the work** — v1 already hit this; more tokens on status broadcasts than code. v2 risks replicating with 7 message exchanges per task. Prevention: set hard budget (<20% coordination overhead), sidecar handles protocol at Tier 0 (zero LLM tokens), eliminate progress updates for short tasks, measure in smoke test.

3. **Sidecar becomes single point of failure per agent** — dead sidecar means permanent disconnection until manual restart. Prevention: run under pm2 with auto-restart, implement watchdog, persist state to disk on every mutation, hub alerts if agent offline >2 minutes, top-level try/catch in sidecar.

4. **Agent FSM state diverges from reality** — hub thinks agent is "working" but OpenClaw session crashed 10 minutes ago. Prevention: heartbeat-with-state pattern (every 30s heartbeat includes current agent state and task ID), FSM reconciles on every heartbeat, staleness timeout transitions to "stuck" and alerts, log every FSM transition.

5. **Git workflow enforcement that doesn't enforce** — wrapper exists but agents bypass it, or git fetch fails silently. Prevention: sidecar calls wrapper before waking agent (branch already set up when LLM session starts), verify fetch succeeded (compare local vs hub main HEAD), PR gatekeeper rejects stale-base PRs, pre-push git hook checks branch naming.

6. **DETS as task queue backing under concurrent load** — single-writer bottleneck, 2GB limit, no concurrent access. Under failure cascades (3 agents disconnect simultaneously), TaskQueue GenServer becomes bottleneck. Prevention: call :dets.sync/1 after every status change (not just auto-sync), ETS read cache for dashboard queries (write-through to DETS), set threshold: >10 tasks/minute sustained triggers SQLite migration.

7. **"Looks alive" problem — sidecar connected but agent inert** — sidecar maintains WebSocket, sends heartbeats, but `openclaw cron wake` fails silently. Hub thinks agent available, assigns tasks, tasks sit in "assigned" forever. Prevention: verify wake succeeded (check exit code), task acceptance timeout (60s to send accept/reject after assignment), sidecar self-test every 5 minutes, distinguish "connected" from "available" in FSM.

8. **Automated PR review that blocks everything or approves everything** — gatekeeper either over-cautious (escalates every PR, defeats purpose) or over-permissive (auto-merges bugs). Bad merge to main cascades to all agents. Prevention: mechanical criteria for auto-merge (file count, no config changes, diff size, tests pass), start conservative (docs + tests only), track false negative rate, main health check after every merge.

9. **Context window starvation during task execution** — v1 saw this: Skaffen hit 86% context just waiting. Task requires reading 10 files, context loading alone consumes 30-50% window. Prevention: task includes pre-computed context budget, sidecar injects minimal context (no protocol history, no backlog), continuation mechanism for multi-window tasks, track context utilization per task.

10. **Scheduler livelock under failure cascades** — agent disconnects, task re-queued, assigned to another agent, that agent's wake fails, timeout, re-queue, scheduler loops on same failed tasks while new tasks pile up. Prevention: exponential backoff on retry (immediate, 30s, 2min, cap 3 retries), circuit breaker per agent (3 consecutive failures → mark degraded, stop assigning 5min), prioritize new tasks over retried tasks, separate retry queue.

## Implications for Roadmap

Based on research, the implementation must follow strict dependency ordering: **Phase 0 + Phase 1 (parallel)** → **Phase 2** → **Phase 3** (critical gate: scheduler integration) → **smoke test** → **Phases 4/5/6 (parallel)**. The smoke test after Phase 3 is the quality gate—if 10 trivial tasks don't complete reliably across 2 agents, nothing after Phase 3 matters.

### Phase 0: Sidecar (Always-On WebSocket Relay)
**Rationale:** Gates everything. Without persistent connectivity, scheduler cannot push tasks and system degrades to v1's broken polling model. Can be built standalone with zero hub dependencies.
**Delivers:** Node.js sidecar with WebSocket client, reconnection with exponential backoff, local queue.json persistence, OpenClaw wake trigger, heartbeat
**Addresses:** Push-based task assignment (table stakes), sidecar as single point of failure (Pitfall 3), "looks alive" problem (Pitfall 7)
**Avoids:** Must include process supervisor (pm2) and crash recovery as definition of done
**Research flag:** Standard patterns (WebSocket client, process management)—skip research-phase

### Phase 1: Task Queue (Persistent Work Storage)
**Rationale:** Parallel with Phase 0—no dependencies on new scheduler components. Scheduler cannot run without task queue to read from.
**Delivers:** TaskQueue GenServer, DETS-backed persistence, priority lanes, retry semantics with assignment generation tracking, dead-letter queue
**Addresses:** Persistent task queue (table stakes), failure handling (table stakes), at-least-once delivery without idempotency (Pitfall 1), DETS bottleneck (Pitfall 6)
**Avoids:** Must call :dets.sync/1 explicitly after status changes, implement ETS read cache from day one
**Research flag:** Standard patterns (GenServer + DETS is proven in v1 codebase)—skip research-phase

### Phase 2: Agent FSM (Per-Agent State Machine)
**Rationale:** Depends on TaskQueue for recovery semantics (on startup, check TaskQueue for assigned tasks). Scheduler needs both TaskQueue AND AgentFSM to function.
**Delivers:** AgentFSM GenServer under DynamicSupervisor, Registry lookup, states (offline/idle/assigned/working/done/failed/blocked), heartbeat-with-state reconciliation
**Addresses:** Agent state machine (table stakes), FSM state divergence (Pitfall 4)
**Avoids:** FSM must reconcile state against sidecar-reported state on every heartbeat, not just hub-commanded state
**Research flag:** Standard patterns (DynamicSupervisor + Registry is canonical Elixir)—skip research-phase

### Phase 3: Scheduler (Task-to-Agent Matching)
**Rationale:** Integration point. Cannot be built until Phases 0, 1, 2 complete. This is the critical gate where all components come together.
**Delivers:** Scheduler GenServer, event-driven matching (new task, agent idle, agent disconnect), 30s sweep for stuck assignments, capability-based routing, retry backoff, per-agent circuit breakers
**Addresses:** Scheduler (table stakes), coordination tax (Pitfall 2), scheduler livelock (Pitfall 10), context window starvation (Pitfall 9)
**Avoids:** Must track coordination-to-work token ratio as system metric, implement exponential backoff on retry, measure overhead in smoke test
**Research flag:** Standard patterns (event-driven GenServer)—skip research-phase

### Phase 3.5: Smoke Test (Infrastructure Validation)
**Rationale:** Quality gate before building anything else. 2 agents, 10 trivial tasks ("write number N to file"), measure assignment latency and completion rate. Pass criteria: 10/10 completed, <5s assignment, <500 tokens overhead, coordination tokens <20% of work tokens.
**Delivers:** Confidence that infrastructure works end-to-end without burning LLM tokens on complex tasks
**Addresses:** Validates Phases 0-3, tests failure scenarios (agent disconnect, task timeout, retry)
**Avoids:** Smoke test must include failure paths, not just happy path—verify retry logic works

### Phase 4: Dashboard v2 (Real-Time Observability)
**Rationale:** Downstream of Phase 3—dashboard reads state from Scheduler/TaskQueue/FSM. Can be built in parallel with Phases 5 and 6 after smoke test passes.
**Delivers:** HTML dashboard with auto-refresh, agent state cards, queue depth by priority, recent completions with PR links, state query API
**Addresses:** Basic observability (table stakes), real-time dashboard (differentiator), sidecar health alerting (Pitfall 3)
**Avoids:** Dashboard polls ETS cache (not GenServer), refreshes every 10-30s (not real-time streaming)
**Research flag:** Standard patterns (HTML + SSE or polling)—skip research-phase

### Phase 5: Git Workflow Enforcement
**Rationale:** Downstream of Phase 0 (ships with sidecar). Can be built in parallel with Phase 4 after smoke test. Low complexity, high operational value.
**Delivers:** Shell script with three commands (start-task, submit, status), bundled with sidecar, sidecar calls before waking OpenClaw
**Addresses:** Git workflow enforcement (differentiator), git workflow bypass (Pitfall 5)
**Avoids:** Sidecar sets up branch BEFORE waking agent, verify git fetch succeeded (compare local vs hub main HEAD), PR gatekeeper role verifies branch freshness
**Research flag:** Standard patterns (git commands, shell scripting)—skip research-phase

### Phase 6: One-Command Onboarding
**Rationale:** Downstream of everything—needs Auth, Sidecar, Scheduler all working. Can be built in parallel with Phases 4 and 5 after smoke test.
**Delivers:** add-agent.sh script that generates tokens, creates sidecar config, installs as service, verifies connection
**Addresses:** One-command onboarding (differentiator)
**Avoids:** Must include connectivity verification—new agent actually receives and completes a test task, not just connects once
**Research flag:** Standard patterns (bash scripting, pm2 service setup)—skip research-phase

### Phase 7 (Deferred): PR Review Gatekeeper
**Rationale:** Capstone feature requiring full pipeline proven reliable. Build after 50+ tasks flow through and patterns emerge for escalation heuristics.
**Delivers:** Flere-Imsaho gatekeeper agent with mechanical auto-merge criteria, escalation to Nathan for risky changes
**Addresses:** PR review gatekeeper (differentiator), PR review failure modes (Pitfall 8)
**Avoids:** Mechanical criteria first (file count, no config changes, diff size), LLM review layer only for advisory recommendations
**Research flag:** Needs research-phase—escalation heuristics are domain-specific, GitHub API integration patterns

### Phase Ordering Rationale

- **Phases 0 and 1 are truly parallel** — sidecar has zero hub dependencies, task queue has no dependency on sidecar; can be built simultaneously by different agents
- **Phase 2 (AgentFSM) gates Phase 3** — scheduler needs FSM API to assign tasks; basic FSM without full recovery can unblock scheduler work
- **Phase 3 is the critical path integration point** — nothing downstream matters until scheduler works end-to-end
- **Smoke test after Phase 3 is non-negotiable** — validates infrastructure with trivial tasks before building observability and tooling
- **Phases 4, 5, 6 are independent after smoke test** — can be parallelized across agents once core scheduler is proven
- **Phase 7 deferred until production data informs design** — escalation heuristics need real PRs to calibrate against

### Research Flags

**Standard patterns (skip research-phase):**
- **Phase 0, 1, 2, 3** — GenServer + DETS pattern proven in v1 codebase, DynamicSupervisor + Registry is canonical Elixir, WebSocket client patterns are well-documented
- **Phase 4, 5, 6** — HTML dashboards, git commands, bash scripting, pm2 service setup are all standard patterns

**Needs research-phase:**
- **Phase 7 (PR gatekeeper)** — escalation heuristics are domain-specific (what makes a PR "safe" vs "risky"), GitHub API integration patterns for merge with checks

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All technologies are OTP/Elixir stdlib or proven npm packages. No new Elixir dependencies. ws, pm2 are de facto standards. :gen_statem over GenStateMachine wrapper is validated by Elixir Forum consensus. |
| Features | MEDIUM-HIGH | Table stakes features validated against Microsoft Azure SAS pattern and production queue systems (Celery, Oban, Temporal). Differentiators grounded in v1 operational experience (Flere-Imsaho's letter). Anti-features backed by multi-agent research showing coordination overhead. |
| Architecture | HIGH | DynamicSupervisor + Registry + GenServer pattern is canonical Elixir. Sidecar pattern is well-established microservices pattern. Data flow validated against v1 codebase structure. Component responsibilities map cleanly to OTP design principles. |
| Pitfalls | MEDIUM-HIGH | Critical pitfalls grounded in v1 post-mortem evidence (coordination overhead, git workflow failures, zero visibility). Distributed systems pitfalls (at-least-once delivery, state divergence, livelock) validated against academic research and production system patterns. |

**Overall confidence:** MEDIUM-HIGH

The stack and architecture confidence is high because they use established OTP patterns proven in the v1 codebase—no experimental technologies or unproven architectural approaches. Features and pitfalls confidence is medium-high because they are grounded in v1's operational experience (primary source) and validated against industry patterns (secondary sources), but some differentiators (token-aware scheduling, PR gatekeeper heuristics) have limited prior art in the multi-agent domain.

### Gaps to Address

- **Elixir version bump (1.14 → 1.17+)** — Consider bumping before starting v2 work to get :gen_statem logger translation fix. Low risk (standard OTP patterns, no version-specific features). Validate this during Phase 0/1 setup.

- **Sidecar queue.json atomicity** — Simple persistence with fs.writeFileSync has partial-write-on-crash risk. Acceptable for v2 launch. Replace with SQLite or atomic write-to-temp-then-rename if corruption observed. Monitor in Phase 0.

- **DETS → SQLite migration path** — DETS sufficient for 4-5 agents, <100 tasks. Set threshold: >10 tasks/minute sustained triggers migration. Document migration path (TaskQueue API abstracts backing store) but don't build until needed. Monitor in Phase 1.

- **Token budget estimation** — Context budget and token-aware scheduling need real production data to calibrate. Start with coarse estimates (small/medium/large tasks) and refine after 50+ task completions. Address in Phase 1 (add metadata fields), refine in Phase 3.

- **PR gatekeeper escalation heuristics** — What makes a PR "safe to auto-merge" vs "risky"? Cannot be determined without real PRs to evaluate. Start conservative (docs + tests only), expand scope based on false negative tracking. Address in Phase 7 (deferred).

- **Capability matching sophistication** — Start with exact string matching ("elixir", "git", "code-review"). Fuzzy matching, affinity learning, skill levels all deferred until agent count exceeds 10 and meaningful skill differentiation emerges. Basic string matching sufficient for v2. Address in Phase 3, enhance later if needed.

## Sources

### Primary (HIGH confidence)
- AgentCom v1 codebase — lib/agent_com/ modules (application.ex, socket.ex, presence.ex, mailbox.ex, router.ex, endpoint.ex)
- AgentCom v2 implementation plan — docs/v2-implementation-plan.md
- AgentCom v1 post-mortem — docs/v2-letter.md (Flere-Imsaho's operational experience)
- AgentCom task protocol — docs/task-protocol.md
- AgentCom codebase concerns — .planning/codebase/CONCERNS.md
- Elixir official docs — DynamicSupervisor, GenServer, Registry, :gen_statem (hexdocs.pm/elixir)
- Erlang DETS docs — stdlib v7.2 (erlang.org/doc/man/dets)
- Oban hexdocs — v2.20.3 (hexdocs.pm/oban)
- ws npm package — github.com/websockets/ws (v8.19.0, 35M weekly downloads)
- pm2 npm package — npmjs.com/package/pm2 (v6.0.14)

### Secondary (MEDIUM confidence)
- Microsoft Azure: Scheduler Agent Supervisor Pattern — learn.microsoft.com/azure/architecture/patterns/scheduler-agent-supervisor
- Elixir Forum: GenStateMachine vs :gen_statem discussion — elixirforum.com/t/69441 (community consensus to use raw :gen_statem)
- Deloitte: AI Agent Orchestration Predictions 2026 — deloitte.com/insights (human-on-the-loop model for enterprises)
- Multi-agent system failure research — arxiv.org/html/2503.13657v1 (Cemri, Pan, Yang, 2025: failure taxonomy)
- Distributed systems: at-least-once delivery and idempotency — medium.com/@sinha.k/at-least-once-delivery
- WebSocket architecture best practices — ably.com/topic/websocket-architecture-best-practices
- Temporal error handling patterns — temporal.io/blog/error-handling-in-distributed-systems

### Tertiary (LOW confidence)
- LangChain: Multi-Agent Architecture Guide — blog.langchain.com/choosing-the-right-multi-agent-architecture
- DEV: LangGraph vs CrewAI vs AutoGen — dev.to/pockit_tools (single source, agent framework comparison)
- Modern queueing architectures — medium.com/@pranavprakash4777 (general queue comparison)

---
*Research completed: 2026-02-09*
*Ready for roadmap: yes*
