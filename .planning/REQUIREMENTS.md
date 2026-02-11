# Requirements: AgentCom v2

**Defined:** 2026-02-09
**Core Value:** Reliable autonomous work execution — ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.

## v1 Requirements

Requirements for initial release. Each maps to roadmap phases.

### Sidecar

- [ ] **SIDE-01**: Sidecar maintains persistent WebSocket connection to hub with exponential backoff reconnect (1s, 2s, 4s... cap 60s)
- [ ] **SIDE-02**: Sidecar receives task assignments via WebSocket push and persists to local queue.json
- [ ] **SIDE-03**: Sidecar triggers OpenClaw session wake when work arrives
- [ ] **SIDE-04**: Sidecar recovers incomplete tasks from queue.json on startup and reports status to hub
- [ ] **SIDE-05**: Sidecar runs as managed process (pm2) with auto-restart and log rotation

### Task Queue

- [ ] **TASK-01**: Hub provides DETS-backed persistent task queue that survives restarts
- [ ] **TASK-02**: Tasks have priority lanes (urgent/high/normal/low), processed in priority-then-FIFO order
- [ ] **TASK-03**: Failed tasks retry up to max_retries; exhausted tasks go to dead-letter storage for manual inspection
- [ ] **TASK-04**: Tasks have complete_by deadline; overdue assigned tasks reclaimed by periodic sweep
- [ ] **TASK-05**: Task execution fenced by task ID + assignment generation number for idempotency
- [ ] **TASK-06**: DETS explicitly synced after every task status change to prevent data loss on crash

### Agent State

- [ ] **AGNT-01**: Per-agent FSM tracks states: offline → idle → assigned → working → done/failed/blocked
- [ ] **AGNT-02**: Agent FSM runs as DynamicSupervisor-managed GenServer, one per connected agent
- [ ] **AGNT-03**: WebSocket connection state serves as heartbeat; disconnect triggers immediate state update and task reclamation
- [ ] **AGNT-04**: Assigned task with no acceptance within 60s is reclaimed to queue and agent flagged

### Scheduler

- [ ] **SCHED-01**: Scheduler assigns queued tasks to idle agents on events: new task created, agent becomes idle, agent connects
- [ ] **SCHED-02**: Scheduler matches task needed_capabilities to agent declared capabilities (exact string match)
- [ ] **SCHED-03**: 30s timer sweep catches stuck assignments (assigned but no progress report for 5min)
- [ ] **SCHED-04**: Scheduler is event-driven via PubSub with timer sweep as safety fallback only

### Observability

- [ ] **OBS-01**: Hub exposes GET /api/dashboard/state returning JSON snapshot of queue depth, agent states, recent completions, system health
- [ ] **OBS-02**: HTML dashboard shows agent state cards, queue depth by priority, recent completions with PR links
- [ ] **OBS-03**: Dashboard auto-refreshes (poll-based, 10-30s interval) and shows uptime, connected agents, queue throughput

### Git Workflow

- [ ] **GIT-01**: agentcom-git start-task fetches origin and creates branch {agent}/{task-slug} from origin/main
- [ ] **GIT-02**: agentcom-git submit pushes branch and opens PR with task metadata in description
- [ ] **GIT-03**: agentcom-git status shows current branch, diff from main, uncommitted changes

### Onboarding

- [ ] **ONBD-01**: One-command script (add-agent.sh) generates auth token, creates sidecar config, installs as pm2 process, and verifies hub connection

### Testing

- [ ] **TEST-01**: Smoke test validates full pipeline with 2 agents and 10 trivial tasks across separate machines (<5s assignment latency, <500 tokens overhead, 10/10 completion)
- [ ] **TEST-02**: Failure test kills one agent mid-task, verifies task returns to queue and completes via remaining agent (no duplicates, no lost tasks)
- [ ] **TEST-03**: Scale test with 4 agents and 20 tasks verifies even distribution (±2 tasks) with no starvation

### API Design

- [ ] **API-01**: Hub task and scheduling APIs are runtime-agnostic; any compliant WebSocket client can connect and participate as an agent
- [ ] **API-02**: Agents report tokens_used in task completion results, stored in task history for cost analysis
- [ ] **API-03**: Agents declare structured capabilities on connect, used by scheduler for routing

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### PR Review Pipeline

- **GATE-01**: Gatekeeper agent (Flere-Imsaho role) auto-merges safe PRs
- **GATE-02**: Gatekeeper escalates risky PRs to Nathan (infra/config, large deletions, security-sensitive, chaotic ripple effects)
- **GATE-03**: Escalation heuristics calibrated from 50+ tasks of production data

### Intelligence

- **INTL-01**: Token-aware scheduling factors budget and context-window headroom into assignment decisions
- **INTL-02**: Task flow visualization showing full pipeline (idea → queued → assigned → working → PR → reviewed → merged)
- **INTL-03**: Advisory per-task token budgets with agent self-monitoring

### Runtime

- **RNTM-01**: Claude Code CLI agent runtime support via sidecar abstraction
- **RNTM-02**: Mixed runtime support (OpenClaw + Claude Code CLI agents on same hub)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Multi-agent task decomposition | Coordination overhead exceeds gains at 4-5 agents; keep tasks atomic |
| Cross-hub federation | Single BEAM hub handles current scale trivially |
| Learning / affinity engine | Insufficient task data at current scale; log outcomes for future use |
| Dynamic auto-scaling | Cost risk without human approval; manual scaling via dashboard data |
| Hard token enforcement | Too fragile (race conditions, lost work); use advisory budgets instead |
| Real-time streaming (live logs) | Coordination overhead dominated v1; poll-based updates sufficient |
| Plugin / extension system | Premature abstraction at 4-5 agents; modify code directly |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SIDE-01 | Phase 1: Sidecar | ✓ Complete |
| SIDE-02 | Phase 1: Sidecar | ✓ Complete |
| SIDE-03 | Phase 1: Sidecar | ✓ Complete |
| SIDE-04 | Phase 1: Sidecar | ✓ Complete |
| SIDE-05 | Phase 1: Sidecar | ✓ Complete |
| TASK-01 | Phase 2: Task Queue | ✓ Complete |
| TASK-02 | Phase 2: Task Queue | ✓ Complete |
| TASK-03 | Phase 2: Task Queue | ✓ Complete |
| TASK-04 | Phase 2: Task Queue | ✓ Complete |
| TASK-05 | Phase 2: Task Queue | ✓ Complete |
| TASK-06 | Phase 2: Task Queue | ✓ Complete |
| AGNT-01 | Phase 3: Agent State | ✓ Complete |
| AGNT-02 | Phase 3: Agent State | ✓ Complete |
| AGNT-03 | Phase 3: Agent State | ✓ Complete |
| AGNT-04 | Phase 3: Agent State | ✓ Complete |
| SCHED-01 | Phase 4: Scheduler | ✓ Complete |
| SCHED-02 | Phase 4: Scheduler | ✓ Complete |
| SCHED-03 | Phase 4: Scheduler | ✓ Complete |
| SCHED-04 | Phase 4: Scheduler | ✓ Complete |
| OBS-01 | Phase 6: Dashboard | Pending |
| OBS-02 | Phase 6: Dashboard | Pending |
| OBS-03 | Phase 6: Dashboard | Pending |
| GIT-01 | Phase 7: Git Workflow | ✓ Complete |
| GIT-02 | Phase 7: Git Workflow | ✓ Complete |
| GIT-03 | Phase 7: Git Workflow | ✓ Complete |
| ONBD-01 | Phase 8: Onboarding | Pending |
| TEST-01 | Phase 5: Smoke Test | Pending |
| TEST-02 | Phase 5: Smoke Test | Pending |
| TEST-03 | Phase 5: Smoke Test | Pending |
| API-01 | Phase 1: Sidecar | ✓ Complete |
| API-02 | Phase 2: Task Queue | ✓ Complete |
| API-03 | Phase 3: Agent State | ✓ Complete |

**Coverage:**
- v1 requirements: 32 total
- Mapped to phases: 32
- Unmapped: 0

---
*Requirements defined: 2026-02-09*
*Last updated: 2026-02-10 — Phase 4 requirements verified*
