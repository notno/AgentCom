# Feature Research

**Domain:** Distributed AI agent scheduler / orchestration system
**Researched:** 2026-02-09
**Confidence:** MEDIUM (training data + web search verified; no Context7 libraries applicable to this domain)

## Feature Landscape

### Table Stakes (Users Expect These)

Features that any scheduler/orchestration system must have. Missing these means the system is unreliable or unusable, and operators will abandon it for manual coordination.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Persistent task queue with priority lanes** | Every scheduler needs durable work storage. Tasks cannot be lost on restart. Priority lanes (urgent/high/normal/low) are standard in Celery, Oban, Temporal, and every production queue. Without them, urgent work waits behind trivial work. | MEDIUM | DETS-backed queue already planned in v2 implementation plan. Must survive hub restarts. Oban (Elixir ecosystem) uses Postgres; AgentCom uses DETS -- acceptable at current scale (4-5 agents). |
| **Agent state machine (idle/assigned/working/done/failed)** | The Scheduler-Agent-Supervisor pattern (Microsoft Azure Architecture) requires explicit agent states to know who can receive work. v1's flat presence map conflated "connected" with "available." Every production orchestrator tracks worker state. | MEDIUM | Per-agent GenServer FSM already designed. States: offline, idle, assigned, working, done, failed, blocked. The FSM is the scheduler's view of reality -- without it, double-assignment and starvation are inevitable. |
| **Push-based task assignment** | Pull-based polling (v1's mailbox model) wastes tokens, introduces latency, and fails silently when cron doesn't fire. Push via WebSocket is how modern orchestrators (Temporal workers, Celery with Redis pub/sub) deliver work. The sidecar solves the "LLM session isn't always alive" problem. | MEDIUM | Requires sidecar (always-on WebSocket relay per agent). This is Phase 0 in the v2 plan and gates everything else. Without push, the scheduler is just a database. |
| **Failure handling with retry and dead-letter** | Tasks fail. Agents disconnect. Timeouts expire. Every production queue (SQS, Celery, Oban, Temporal) has retry with backoff and a dead-letter mechanism for permanently failed tasks. Without this, failed work vanishes silently -- the exact v1 problem. | MEDIUM | v2 plan has retry_count and max_retries on tasks. Add: dead-letter queue for tasks exceeding max_retries (store for manual inspection, not discard). Exponential backoff on reassignment. Categorize failures: transient (agent disconnect, retry) vs. permanent (task rejected, agent says "impossible"). |
| **Heartbeat / liveness detection** | If the scheduler cannot tell whether an agent is alive, it cannot reclaim stuck tasks. Heartbeat monitoring is universal: Kubernetes health checks, Celery worker heartbeats, the Supervisor component in Microsoft's SAS pattern. v1's reaper was unreliable. | LOW | WebSocket connection state IS the heartbeat in v2 (sidecar maintains persistent connection). Hub detects disconnect immediately. Simpler and more reliable than periodic ping-based reaping. Still need a timeout for "connected but not responding" (assigned task with no progress for N minutes). |
| **Basic observability (system state query)** | Nathan's #1 complaint: zero visibility. The operator must be able to answer "what is everyone doing?" without asking an agent. Every orchestration platform provides a state query API. This is the minimum -- not a dashboard, just a queryable endpoint. | LOW | `GET /api/dashboard/state` returning JSON snapshot: agent states, queue depth by priority, recent completions, system health. The HTML dashboard (Phase 4) is built on top of this API. API first, dashboard second. |
| **Idempotent task execution** | The Scheduler-Agent-Supervisor pattern documentation emphasizes: steps must be safely repeatable. If a task is assigned, the agent crashes mid-execution, and the task is reassigned, the second execution must not corrupt state. This is fundamental to retry-based systems. | LOW | Idempotency is a convention, not infrastructure. The git wrapper (branch-from-main, named branches) naturally provides idempotency for code tasks: re-running "create branch and open PR" is safe. Document this as a requirement for task design. |
| **Task timeout / complete-by deadline** | Microsoft's SAS pattern uses LockedUntil / CompleteBy fields. If an agent holds a task past its deadline, the supervisor reclaims it. Without timeouts, stuck tasks block the queue forever. Temporal, Celery, and Oban all have per-task timeout. | LOW | Add `deadline` or `complete_by` field to task struct. Scheduler polls for overdue tasks on a timer (already planned: "every 30s, check for stuck assignments"). Reclaim to queue with retry_count++. |

### Differentiators (Competitive Advantage)

Features that set AgentCom v2 apart from generic task queues. These address the specific problems of coordinating autonomous AI agents that write code, open PRs, and consume expensive token budgets.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Git workflow enforcement (branch-from-current-main wrapper)** | This is AgentCom-specific and directly addresses v1's worst operational pain: Loash branching from stale main three times. No generic orchestrator enforces git hygiene. The wrapper makes the correct workflow the only workflow -- `agentcom-git start-task` fetches origin, creates branch from `origin/main`. Agents cannot accidentally branch from stale state. | LOW | Shell script bundled with sidecar. Three commands: `start-task`, `submit`, `status`. This is Phase 5 in v2 plan but has outsized value relative to complexity. Consider moving earlier. |
| **PR review gatekeeper agent (Flere-Imsaho)** | Autonomous agents producing code need a quality gate before merge. Most orchestration systems assume a human reviews output. AgentCom's gatekeeper agent (Flere-Imsaho) auto-merges safe changes and escalates risky ones to Nathan. This creates a genuine autonomous pipeline: idea enters queue, PR emerges merged. The "human-on-the-loop" model that Deloitte predicts enterprises will adopt in 2026. | HIGH | Requires: clear escalation rules (infra/config changes, large deletions, security-sensitive), GitHub API integration for merge, a review agent with codebase understanding. The escalation heuristics are the hard part -- too aggressive = everything escalates (defeats purpose), too lax = bad merges. Start with conservative rules, tune from data. |
| **One-command agent onboarding** | v1 onboarding was "a mess" (Flere-Imsaho's letter) -- wrong tokens, wrong identity, manual steps. One-command onboarding (`add-agent.sh --name X --hub Y`) that generates tokens, creates sidecar config, installs as service, and verifies connection. No generic orchestrator provides this because they don't have AgentCom's specific agent + sidecar + hub topology. | LOW | Phase 6 in v2 plan. Low complexity, high operational value. Reduces onboarding from error-prone manual process to verified automated setup. |
| **Capability-based routing** | Generic task queues route by queue name. AgentCom routes by agent capabilities (languages, tools, access). The scheduler matches `needed_capabilities` on tasks to declared capabilities on agents. This is a differentiator because it's domain-aware: "this task needs Elixir + git" routes to agents that have those. CrewAI and AutoGen have role-based routing but not structured capability matching integrated with a scheduler. | MEDIUM | Already designed in v2 task struct (`needed_capabilities` field) and agent FSM. Start simple: exact match on capability strings. Future: fuzzy matching, affinity learning (which agent is best at what). |
| **Token-aware scheduling** | AI agents consume tokens -- their primary cost. No traditional task queue cares about this. AgentCom can track tokens_used per task (already in task protocol), set per-task token budgets, and factor token cost into scheduling decisions. This prevents the v1 problem of "Skaffen hit 86% context just waiting for a task." | MEDIUM | Phase 1: report tokens_used in task results (already in protocol spec). Phase 2: per-task token budget field (advisory, agent reports when approaching). Phase 3: scheduler considers context-window headroom when assigning. Don't build Phase 3 until Phases 1-2 prove useful. |
| **Real-time dashboard with task flow visualization** | Generic queue dashboards show queue depth and worker count. AgentCom's dashboard shows the full pipeline: idea -> queued -> assigned -> working -> PR -> reviewed -> merged. Nathan sees the "nervous system" of the whole operation. This is the v2 answer to v1's "zero visibility." | MEDIUM | Phase 4 in v2 plan. Build on the state query API (table stakes). Add: agent state cards, queue depth by priority, recent completions with PR links, message volume graph. Auto-refresh via polling or SSE. |
| **Smoke test harness (infrastructure validation)** | Most orchestrators assume you test by running real workloads. AgentCom's smoke test uses fake trivial tasks ("write number N to file") to validate the infrastructure without burning LLM tokens. This is Nathan's insight: test the plumbing, not the AI. | LOW | 2 agents, 10 tasks, measure assignment latency and completion rate. Pass criteria: 10/10 completed, <5s assignment, <500 tokens overhead. This gates all further work -- if trivial tasks fail, nothing else matters. |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem valuable but would add complexity disproportionate to their benefit at AgentCom's current scale, or that actively work against the system's goals.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **Multi-agent task decomposition** | "Break big tasks into parallel subtasks" appears on the backlog and every agent orchestration framework comparison. Seems like a force multiplier. | At 4-5 agents, decomposition overhead exceeds parallel execution gains. The decomposer agent burns tokens analyzing the task, creating subtasks, and synthesizing results. AutoGen's agent-to-agent conversations cost 4x the tokens of directed execution (8000 vs 2000 tokens per task). Decomposition also creates coordination complexity: subtask dependencies, partial failure handling, result aggregation. | Keep tasks atomic. If a task is too big, have the human or Flere-Imsaho manually break it down in BACKLOG.md. Revisit decomposition when agent count exceeds 10 and there's data on task sizes. |
| **Cross-hub federation** | Run multiple hubs, route between them. Appears in product vision as future goal. | Single hub handles 4-5 agents trivially. BEAM can handle thousands of concurrent WebSocket connections. Federation adds: distributed state synchronization, split-brain handling, cross-hub auth, routing complexity. The v2 plan correctly defers this. | One hub. Scale vertically first (BEAM is good at this). Federation only if Nathan runs agents on networks that cannot reach the hub via Tailscale. |
| **Learning / affinity engine** | Track which agent is best at what task type, then preferentially route matching tasks. Sounds like intelligent scheduling. | With 4-5 agents, the sample size is too small for statistical learning. You'd need hundreds of task completions per agent per category to build reliable affinity scores. The scheduling algorithm would be more complex but produce nearly identical assignments to simple FIFO+capability matching. Also risks pigeonholing agents -- if Loash always gets "research" tasks, they never improve at "code" tasks. | Log task outcomes (agent, task type, success/failure, duration, tokens). This data enables future learning without building the learning engine now. Simple capability matching is sufficient at current scale. |
| **Real-time everything (streaming progress, live logs)** | Show Nathan exactly what each agent is doing in real-time. Live token counts, streaming code output, console logs. | Every real-time update costs tokens (agent must emit progress messages). Flere-Imsaho's letter specifically warns: "coordination overhead dominated -- more tokens on status broadcasts than actual code." Live streaming multiplies this problem. Also requires significant infrastructure: SSE/WebSocket to dashboard, buffering, backpressure. | Poll-based dashboard that refreshes every 10-30 seconds. Agents report status at task lifecycle boundaries (accepted, progressing, completed) not continuously. This provides visibility without the overhead. |
| **Token budgeting with hard enforcement** | Per-task token spending caps that kill agent execution if exceeded. Prevents runaway costs. | Hard enforcement requires the hub to terminate agent sessions remotely -- a capability that doesn't exist and would be fragile (race conditions, lost work, corrupted state). OpenClaw sessions don't expose token usage in real-time to external systems. Enforcement at the wrong moment loses partial work. | Advisory token budgets: task specifies an expected token range, agent self-monitors and reports when approaching the limit. Hub flags tasks that significantly exceed budget for human review. Soft limits, not hard kills. |
| **Dynamic agent scaling (auto-spawn agents on demand)** | When queue depth is high, automatically start new agent instances to handle backlog. Kubernetes-style autoscaling for AI agents. | Each AI agent is an LLM session consuming real money (API costs) and compute. Auto-scaling without human approval could run up unexpected bills. Also, "more agents" doesn't linearly reduce task time -- coordination overhead grows, git conflicts increase, and context windows are the real bottleneck. | Manual scaling: Nathan decides when to add agents. The dashboard shows queue depth and wait times, giving Nathan the data to make scaling decisions. The one-command onboarding makes adding an agent fast when the human decides to. |
| **Plugin / extension system** | Allow third-party extensions to the scheduler, custom scheduling algorithms, webhook integrations. | At 4-5 agents with one operator (Nathan), extensibility adds complexity without users to benefit. The scheduler algorithm, failure handling, and routing logic are all simple enough to modify directly in the codebase. A plugin API would be premature abstraction that constrains future design. | Direct code modification. The Elixir codebase is small and well-structured. When a behavior change is needed, change the code. No indirection layer. |

## Feature Dependencies

```
[Sidecar (always-on WebSocket relay)]
    |
    +--requires--> [Push-based task assignment]
    |                   |
    |                   +--requires--> [Scheduler (task-to-agent matching)]
    |                                       |
    |                                       +--requires--> [Agent state machine]
    |                                       |
    |                                       +--requires--> [Persistent task queue]
    |                                       |
    |                                       +--enhances--> [Capability-based routing]
    |
    +--enables--> [Git workflow enforcement (bundled with sidecar)]
    |
    +--enables--> [One-command onboarding]

[Persistent task queue]
    +--requires--> [Failure handling (retry + dead-letter)]
    +--requires--> [Task timeout / complete-by]

[Agent state machine]
    +--requires--> [Heartbeat / liveness detection]

[Basic observability (state query API)]
    +--enables--> [Real-time dashboard]
    +--requires--> [Agent state machine]
    +--requires--> [Persistent task queue]

[Scheduler]
    +--enables--> [Token-aware scheduling]
    +--enables--> [Smoke test harness]

[PR review gatekeeper (Flere-Imsaho)]
    +--requires--> [Git workflow enforcement]
    +--requires--> [Scheduler] (to receive review tasks)
    +--enhances--> [One-command onboarding] (new agents auto-enrolled in review pipeline)
```

### Dependency Notes

- **Sidecar gates everything.** Without persistent WebSocket connectivity, the scheduler cannot push tasks, state tracking is unreliable, and the system degrades to v1's broken polling model. This is correctly Phase 0 in the v2 plan.
- **Scheduler requires both task queue and agent FSM.** The scheduler is pure coordination logic -- it reads from the queue and writes to agent FSMs. Building either without the other is useless.
- **Git wrapper depends on sidecar but not scheduler.** It ships with the sidecar package and can provide value even before the full scheduler is operational. Consider shipping it with Phase 0.
- **Dashboard depends on state query API, which depends on queue + FSM data.** Dashboard is a view layer -- build it after the data sources exist.
- **PR gatekeeper is the capstone feature.** It requires the full pipeline (queue -> scheduler -> assignment -> work -> PR -> review -> merge). Build last, after everything upstream is proven reliable.

## MVP Definition

### Launch With (v1 -- Scheduler MVP)

Minimum viable scheduler -- validates that the push-based architecture works end-to-end.

- [ ] **Sidecar per agent** -- persistent WebSocket relay, local task queue, OpenClaw wake trigger
- [ ] **Persistent task queue** -- DETS-backed, priority lanes, retry semantics, dead-letter for permanent failures
- [ ] **Agent state machine** -- per-agent FSM tracking idle/assigned/working/done/failed/blocked
- [ ] **Scheduler** -- FIFO + priority matching, capability-based routing, triggered on new task / agent idle / agent connect
- [ ] **Failure handling** -- retry with count tracking, timeout-based reclamation (30s sweep), dead-letter for exhausted retries
- [ ] **Heartbeat via WebSocket** -- connection state = liveness, plus stuck-task timeout (assigned but no progress for 5min)
- [ ] **Basic state query API** -- `GET /api/dashboard/state` returning JSON snapshot of queue, agents, recent activity
- [ ] **Smoke test harness** -- 2 agents, 10 trivial tasks, validates full pipeline (this gates further work)

### Add After Validation (v1.x)

Features to add once the scheduler MVP is proven reliable with the smoke test.

- [ ] **Git workflow enforcement** -- bundled with sidecar, three commands (start-task, submit, status). Trigger: first real code task assigned through scheduler.
- [ ] **Real-time dashboard** -- HTML page with auto-refresh showing agent states, queue depth, recent completions. Trigger: Nathan asks "what's everyone doing?" more than once per day.
- [ ] **One-command onboarding** -- add-agent.sh script. Trigger: adding the 3rd agent to v2 scheduler (first two are manually set up during development).
- [ ] **Token usage tracking** -- agents report tokens_used in task results, stored in task history. Trigger: desire to understand cost per task type.
- [ ] **Capability-based routing (structured)** -- upgrade from string matching to structured capabilities (languages, tools, access). Trigger: agents have meaningfully different skill sets that affect task success.

### Future Consideration (v2+)

Features to defer until the scheduler is running in production with multiple agents completing real tasks.

- [ ] **PR review gatekeeper (Flere-Imsaho)** -- auto-merge safe changes, escalate risky ones. Defer because: needs proven scheduler + git workflow + clear escalation heuristics. Build after 50+ tasks flow through the pipeline and patterns emerge.
- [ ] **Token-aware scheduling** -- factor token budget and context-window headroom into assignment decisions. Defer because: need token usage data from production to calibrate.
- [ ] **Advisory token budgets** -- per-task expected token range, agent self-monitoring. Defer because: requires cooperation from OpenClaw side and real cost data.
- [ ] **Task flow visualization** -- full pipeline view (idea -> PR -> merge) in dashboard. Defer because: needs PR integration and gatekeeper to show the complete flow.

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Sidecar (WebSocket relay) | HIGH | MEDIUM | P1 |
| Persistent task queue | HIGH | MEDIUM | P1 |
| Agent state machine (FSM) | HIGH | LOW-MEDIUM | P1 |
| Scheduler (task-to-agent matching) | HIGH | MEDIUM | P1 |
| Failure handling (retry + dead-letter) | HIGH | MEDIUM | P1 |
| Heartbeat / liveness | HIGH | LOW | P1 |
| State query API | HIGH | LOW | P1 |
| Smoke test harness | HIGH | LOW | P1 |
| Task timeout / complete-by | MEDIUM | LOW | P1 |
| Idempotent task design (convention) | MEDIUM | LOW | P1 |
| Git workflow enforcement | HIGH | LOW | P2 |
| Real-time dashboard | HIGH | MEDIUM | P2 |
| One-command onboarding | MEDIUM | LOW | P2 |
| Capability-based routing (structured) | MEDIUM | MEDIUM | P2 |
| Token usage tracking | MEDIUM | LOW | P2 |
| PR review gatekeeper | HIGH | HIGH | P3 |
| Token-aware scheduling | MEDIUM | MEDIUM | P3 |
| Task flow visualization | MEDIUM | MEDIUM | P3 |

**Priority key:**
- P1: Must have for scheduler MVP (validates architecture)
- P2: Should have, add after smoke test proves MVP works
- P3: Future consideration, build after production data informs design

## Competitor Feature Analysis

| Feature | Celery/Oban (Task Queues) | Temporal (Workflow Engine) | CrewAI/AutoGen (Agent Frameworks) | AgentCom v2 Approach |
|---------|---------------------------|---------------------------|-----------------------------------|---------------------|
| Task persistence | DB-backed (Postgres/Redis) | Event-sourced durable store | In-memory (CrewAI) or conversation history | DETS-backed (lightweight, no external DB, sufficient at scale) |
| Worker state tracking | Heartbeat + inspect commands | Activity heartbeat + timeout | Role-based status (limited) | Per-agent GenServer FSM with explicit state transitions |
| Task assignment | Queue-based pull | Activity task queue (pull) | Direct delegation or auction | Push-based via WebSocket (differentiator -- no polling waste) |
| Failure handling | Retry with backoff, DLQ | Retry policies, compensation | Retry or conversation loop | Retry + dead-letter + transient/permanent categorization |
| Observability | Flower (Celery), Oban Web | Temporal UI (query, history) | Limited (LangSmith/AgentOps bolt-on) | Custom dashboard built on state query API |
| Git integration | None | None | None | Git workflow wrapper enforcing branch-from-main (differentiator) |
| Code review pipeline | None | None | None | Gatekeeper agent with merge authority (differentiator) |
| Onboarding | Config files + CLI | Worker deployment | Agent class definitions | One-command setup script (differentiator for agent topology) |
| Token/cost awareness | None (not relevant) | None (not relevant) | Token tracking in some (CrewAI callbacks) | Token reporting + future budget-aware scheduling |
| Scheduling algorithm | FIFO per queue | FIFO per task queue | Role-based + conversation patterns | FIFO + priority lanes + capability matching |

## Sources

- [Microsoft Azure: Scheduler Agent Supervisor Pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/scheduler-agent-supervisor) -- HIGH confidence, canonical pattern reference
- [GeeksforGeeks: Scheduling Agent Supervisor Pattern](https://www.geeksforgeeks.org/system-design/scheduling-agent-supervisor-pattern-system-design/) -- MEDIUM confidence, corroborates Microsoft source
- [Deloitte: AI Agent Orchestration Predictions 2026](https://www.deloitte.com/us/en/insights/industry/technology/technology-media-and-telecom-predictions/2026/ai-agent-orchestration.html) -- MEDIUM confidence, industry trends
- [Google: Multi-Agent Design Patterns](https://www.infoq.com/news/2026/01/multi-agent-design-patterns/) -- MEDIUM confidence, pattern taxonomy
- [LangChain: Choosing Multi-Agent Architecture](https://blog.langchain.com/choosing-the-right-multi-agent-architecture/) -- MEDIUM confidence, framework comparison
- [Oban: Robust Job Processing in Elixir](https://github.com/oban-bg/oban) -- HIGH confidence, Elixir ecosystem reference
- [Redis: AI Agent Orchestration Platforms 2026](https://redis.io/blog/ai-agent-orchestration-platforms/) -- MEDIUM confidence, platform survey
- [Microsoft Azure: Agent Observability Best Practices](https://azure.microsoft.com/en-us/blog/agent-factory-top-5-agent-observability-best-practices-for-reliable-ai/) -- MEDIUM confidence, observability patterns
- [DEV: LangGraph vs CrewAI vs AutoGen Comparison 2026](https://dev.to/pockit_tools/langgraph-vs-crewai-vs-autogen-the-complete-multi-agent-ai-orchestration-guide-for-2026-2d63) -- LOW confidence (single source), agent framework limitations
- [Medium: Modern Queueing Architectures](https://medium.com/@pranavprakash4777/modern-queueing-architectures-celery-rabbitmq-redis-or-temporal-f93ea7c526ec) -- LOW confidence, queue comparison
- AgentCom v1 post-mortem (internal: `docs/v2-letter.md`) -- HIGH confidence, direct operational experience
- AgentCom v2 implementation plan (internal: `docs/v2-implementation-plan.md`) -- HIGH confidence, direct design document

---
*Feature research for: distributed AI agent scheduler / orchestration system*
*Researched: 2026-02-09*
