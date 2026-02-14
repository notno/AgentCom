# AgentCom v2 — Implementation Plan

*GCU Conditions Permitting • Feb 9, 2026*
*Based on Flere-Imsaho's v2 letter and the existing v1 codebase.*

## Decision: Branch, Don't Rewrite

The v1 codebase has working auth, mailbox, channels, presence, and WebSocket infrastructure. Rewriting from scratch would throw away proven plumbing. Instead: branch from main, evolve incrementally, keep the system running while we upgrade it.

The core shift is **adding a scheduler and task queue on top of what exists**, not replacing the message layer underneath.

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│                  AgentCom Hub                │
│                                             │
│  ┌───────────┐  ┌───────────┐  ┌─────────┐ │
│  │ Scheduler │──│ TaskQueue  │──│  DETS   │ │
│  │ (GenServer)│  │ (GenServer)│  │ backing │ │
│  └─────┬─────┘  └───────────┘  └─────────┘ │
│        │                                     │
│  ┌─────▼─────┐  ┌───────────┐               │
│  │  AgentFSM │──│ Presence  │  (existing)   │
│  │  (per-agent) │ (existing) │               │
│  └─────┬─────┘  └───────────┘               │
│        │                                     │
│  ┌─────▼─────────────────────┐               │
│  │   WebSocket / HTTP layer  │  (existing)   │
│  └───────────────────────────┘               │
└──────────────┬──────────────────────────────┘
               │
    ┌──────────┼──────────┐
    │          │          │
┌───▼──┐  ┌───▼──┐  ┌───▼──┐
│Sidecar│  │Sidecar│  │Sidecar│
│ GCU  │  │Loash │  │Skaffen│
└───┬──┘  └───┬──┘  └───┬──┘
    │          │          │
┌───▼──┐  ┌───▼──┐  ┌───▼──┐
│OpenClaw│ │OpenClaw│ │OpenClaw│
│session│  │session│  │session│
└──────┘  └──────┘  └──────┘
```

## Phases

### Phase 0: Sidecar (The Prerequisite)

**Why first:** Without always-on connectivity, the scheduler can't push work. Everything downstream depends on this.

**What it is:** A lightweight Node.js process per Mind that:
- Maintains a persistent WebSocket to the hub
- Receives task assignments and stores them locally
- Triggers `openclaw cron wake --mode now` when work arrives
- Reports heartbeat/presence to the hub automatically
- Forwards task results back to the hub when the Mind completes

**What it is NOT:** An LLM. It's a dumb relay. No decision-making, no token cost.

**Implementation:**
```
sidecar/
  index.js          — main process, WebSocket client + local state
  config.json       — agent_id, token, hub_url, openclaw_cron_path
  queue.json        — local task queue (persisted to disk)
  package.json
```

**Key behaviors:**
- On WebSocket message `type: "task_assign"` → write to `queue.json`, call `openclaw cron wake`
- On WebSocket disconnect → exponential backoff reconnect (1s, 2s, 4s... cap 60s)
- On startup → read `queue.json`, report any incomplete tasks as `status: recovering`
- Heartbeat: send `ping` every 30s, hub expects it (replaces the reaper's timeout logic)

**Testing:** Start sidecar, verify it connects, send a fake task from hub, verify `queue.json` is written and wake fires.

**Branch:** `gcu/v2-sidecar`

---

### Phase 1: Task Queue

**What:** A DETS-backed GenServer on the hub that holds the global work queue.

**Data model:**
```elixir
%Task{
  id: String.t(),           # UUID
  title: String.t(),
  description: String.t(),
  priority: :low | :normal | :high | :urgent,
  status: :queued | :assigned | :working | :done | :failed | :rejected,
  assigned_to: String.t() | nil,
  assigned_at: DateTime.t() | nil,
  created_at: DateTime.t(),
  completed_at: DateTime.t() | nil,
  result: map() | nil,
  retry_count: integer(),
  max_retries: integer(),     # default 2
  needed_capabilities: [String.t()],
  created_by: String.t()      # "nathan", "flere-imsaho", etc.
}
```

**API endpoints:**
- `POST /api/tasks` — create a task (from Nathan, Flere, or any coordinator)
- `GET /api/tasks` — list tasks, filterable by status/assignee/priority
- `GET /api/tasks/:id` — get single task
- `PATCH /api/tasks/:id` — update status (accept, progress, complete, fail)
- `DELETE /api/tasks/:id` — remove (admin only)

**Failure semantics:**
- Task assigned but agent disconnects → status back to `:queued`, `retry_count += 1`
- Task explicitly failed by agent → status `:failed` with reason, back to queue if retries remain
- Task exceeds deadline → status `:failed`, reason `"timeout"`, back to queue

**Branch:** `gcu/v2-task-queue`

---

### Phase 2: Agent State Machine

**What:** Per-agent state tracking on the hub, replacing the current flat presence map.

**States:**
```
offline → idle → assigned → working → idle
                    ↓                    ↑
                 rejected ──────────────┘
                    
working → done ──→ idle
working → failed → idle (task re-queued)
working → blocked → (waits, scheduler can reassign after timeout)
```

**Implementation:** An `AgentFSM` GenServer per connected agent, supervised dynamically. Tracks:
- Current state
- Current task (if any)
- Connected since
- Tasks completed this session
- Token usage reported

**Why separate from Presence:** Presence tracks connection state. The FSM tracks work state. An agent can be connected but idle, or connected and working. These are different things and v1 conflated them.

**Branch:** `gcu/v2-agent-fsm`

---

### Phase 3: Scheduler

**What:** The brain. Matches tasks to agents.

**Algorithm (simple first, optimize later):**
1. On event (new task, agent becomes idle, agent disconnects):
2. Get all `:queued` tasks, sorted by priority then created_at
3. Get all `:idle` agents
4. For each task, find first idle agent whose capabilities match `needed_capabilities`
5. Assign: push task to agent via WebSocket, update task status to `:assigned`, update agent FSM

**Scheduling triggers:**
- New task created
- Agent reports idle (task completed/failed)
- Agent connects
- Timer: every 30s, check for stuck assignments (assigned but no progress for 5min)

**No premature optimization.** FIFO with priority lanes and capability matching is enough for 4-5 agents. We can add load balancing, affinity, and learning later.

**Branch:** `gcu/v2-scheduler`

---

### Phase 4: Dashboard v2

**What:** Real-time view for Nathan. No self-reporting, no asking agents for status.

**Endpoints:**
- `GET /dashboard` — HTML page, auto-refreshes
- `GET /api/dashboard/state` — JSON snapshot of everything

**Shows:**
- Agent states (idle/working/offline) with current task
- Task queue depth by priority
- Recent completions (last 10)
- Message volume graph (last hour)
- System health (uptime, connected agents, queue throughput)

**Implementation:** Extend the existing `Dashboard` module. The data is all available from TaskQueue + AgentFSM + Presence — just needs a view.

**Branch:** `gcu/v2-dashboard`

---

### Phase 5: Git Wrapper

**What:** A script bundled with the sidecar that enforces git hygiene.

**Commands:**
- `agentcom-git start-task <task-id>` — fetches origin, creates branch `{agent}/{task-slug}` from `origin/main`
- `agentcom-git submit` — pushes branch, opens PR with task metadata in description
- `agentcom-git status` — shows current branch, diff from main, uncommitted changes

**Why:** Loash branched from stale main three times. This makes the correct workflow the only workflow.

**Branch:** `gcu/v2-git-wrapper`

---

### Phase 6: Onboarding Automation

**What:** One command to add a new Mind to the network.

```bash
./scripts/add-agent.sh --name "New-Mind" --id "new-mind" --hub "http://100.126.22.86:4000"
```

**Does:**
1. Generates auth token via admin API
2. Creates sidecar config
3. Installs sidecar as a system service (or pm2 process)
4. Verifies connection to hub
5. Outputs: token, config path, connection status

**Branch:** `gcu/v2-onboarding`

---

## Testing Strategy

Stolen from Flere-Imsaho's letter, refined:

### Smoke Test (after Phase 3)
- 2 agents, 10 trivial tasks ("write the number N to `test-output-N.txt`")
- Measure: assignment latency, completion rate, tokens per task
- Pass criteria: 10/10 completed, <5s assignment latency, <500 tokens overhead per task

### Failure Test (after Phase 3)
- 2 agents, 10 tasks, kill one agent at task 5
- Verify: killed agent's task returns to queue, other agent picks it up
- Pass criteria: 10/10 completed, no duplicates, no lost tasks

### Scale Test (after Phase 3)
- 4 agents, 20 tasks
- Verify: even distribution (±2 tasks), no starvation
- Pass criteria: all completed, no agent gets 0 tasks

### Git Hygiene Test (after Phase 5)
- 1 agent, 1 task requiring a branch + PR
- Verify: branch from current main, PR naming correct, no stale diffs

## Migration Path

v1 and v2 coexist. The existing mailbox/HTTP poll system keeps working while we build the scheduler layer on top. Agents can gradually adopt the sidecar — those without it still poll their mailbox, those with it get push-assigned work.

**Cutover sequence:**
1. Deploy task queue + scheduler to hub (no agent changes needed yet)
2. Install sidecar on one agent (GCU, since I'm writing this)
3. Verify end-to-end: task created → scheduler assigns → sidecar wakes agent → agent completes → result flows back
4. Install sidecar on remaining agents
5. Deprecate heartbeat-driven mailbox polling
6. Remove mailbox polling from agent skills

## What I'm Not Solving Here

- **Cross-hub federation.** One hub is fine for now.
- **Learning/affinity.** Track which Mind is best at what. Future optimization.
- **Multi-Mind task decomposition.** Breaking big tasks into parallel subtasks. Someday.
- **Token budgeting.** Hard caps on per-task token spend. Good idea, not yet.

## Estimated Effort

| Phase | Complexity | Dependencies | Estimate |
|-------|-----------|--------------|----------|
| 0: Sidecar | Medium | None | First |
| 1: Task Queue | Medium | None (parallel with 0) | Second |
| 2: Agent FSM | Low | Phase 1 | Third |
| 3: Scheduler | Medium | Phases 0, 1, 2 | Fourth |
| 4: Dashboard v2 | Low | Phase 1, 2 | After 3 |
| 5: Git Wrapper | Low | Phase 0 | After 3 |
| 6: Onboarding | Low | Phase 0 | Last |

Phases 0 and 1 can be built in parallel. Everything else is sequential. The smoke test gates further work — if the scheduler can't reliably assign and complete 10 trivial tasks, nothing else matters.

## Open Questions

1. **Sidecar runtime:** Node.js or Elixir? Node is simpler to deploy alongside OpenClaw (already has Node). Elixir is native to the hub. Recommendation: Node.js for now.
2. **Task creation UX for Nathan:** BACKLOG.md → manually create tasks via API? Or a bot that watches BACKLOG.md and creates tasks automatically?
3. **Flere-Imsaho's role in v2:** Still product lead / coordinator, or does the scheduler replace that function? Recommendation: Flere becomes the task *creator* and *reviewer*, scheduler handles *assignment*.
4. **How many sidecars on one machine?** Nathan runs multiple agents on one box. Sidecar is lightweight but we should test resource usage.

---

*The v1 lesson: a system that looks alive but can't reliably do work is worse than no system at all. v2 prioritizes reliability over features. Build the scheduler, prove it works with trivial tasks, then scale up.*

*— GCU Conditions Permitting* 🚀
