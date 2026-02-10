# Roadmap: AgentCom v2

## Overview

AgentCom v2 transforms a message-passing system into a GPU scheduler-style architecture where a central hub pushes tasks to autonomous agents through persistent sidecars. The roadmap builds from two independent foundations (sidecar connectivity and task storage) through an agent state layer, into the critical scheduler integration, then validates with a smoke test before branching into parallel workstreams for observability, git workflow, and onboarding. Every phase delivers a coherent, testable capability that compounds toward the core value: ideas enter a queue and emerge as reviewed, merged PRs.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Sidecar** - Always-on WebSocket relay with OpenClaw wake and crash recovery
- [ ] **Phase 2: Task Queue** - DETS-backed persistent work storage with priority lanes and retry
- [ ] **Phase 3: Agent State** - Per-agent finite state machine tracking work lifecycle
- [ ] **Phase 4: Scheduler** - Event-driven task-to-agent matching with capability routing
- [ ] **Phase 5: Smoke Test** - End-to-end pipeline validation with 2 agents and trivial tasks
- [ ] **Phase 6: Dashboard** - Real-time observability showing queue, agents, and task flow
- [ ] **Phase 7: Git Workflow** - Branch-from-main enforcement bundled with sidecar
- [ ] **Phase 8: Onboarding** - One-command agent provisioning and verification

## Phase Details

### Phase 1: Sidecar
**Goal**: Agents have persistent connectivity to the hub that survives session restarts and network interruptions
**Depends on**: Nothing (first phase, builds standalone)
**Requirements**: SIDE-01, SIDE-02, SIDE-03, SIDE-04, SIDE-05, API-01
**Success Criteria** (what must be TRUE):
  1. Sidecar maintains WebSocket connection to hub and automatically reconnects after network interruption with exponential backoff (observable via hub presence showing agent reconnected)
  2. Sidecar receives a test message pushed from hub and persists it to local queue.json (verifiable by inspecting queue.json on agent machine)
  3. Sidecar triggers OpenClaw session wake when a message arrives and verifies wake succeeded (observable via OpenClaw process starting)
  4. Sidecar recovers incomplete tasks from queue.json on restart and reports their status to hub (verifiable by killing and restarting sidecar, checking hub state)
  5. Sidecar runs as pm2 managed process with auto-restart and log rotation (verifiable by killing sidecar process, observing pm2 restarts it)
**Plans**: TBD

Plans:
- [ ] 01-01: TBD
- [ ] 01-02: TBD

### Phase 2: Task Queue
**Goal**: The hub has durable, prioritized work storage that survives crashes and handles failures gracefully
**Depends on**: Nothing (parallel with Phase 1)
**Requirements**: TASK-01, TASK-02, TASK-03, TASK-04, TASK-05, TASK-06, API-02
**Success Criteria** (what must be TRUE):
  1. Tasks submitted via API persist across hub restarts (verifiable by creating task, restarting hub, confirming task still queued)
  2. Higher-priority tasks are assigned before lower-priority tasks regardless of creation order (verifiable by creating low then urgent task, observing urgent dequeued first)
  3. Failed tasks retry up to configured max then move to dead-letter storage (verifiable by submitting task that always fails, observing retries then dead-letter)
  4. Overdue assigned tasks are reclaimed by periodic sweep and returned to queue (verifiable by assigning task, letting deadline expire, confirming task re-queued)
  5. Task completion results include tokens_used field stored in task history (verifiable by completing task with token count, querying task history)
**Plans**: TBD

Plans:
- [ ] 02-01: TBD
- [ ] 02-02: TBD

### Phase 3: Agent State
**Goal**: The hub tracks each agent's work lifecycle with a state machine that stays synchronized with reality
**Depends on**: Phase 2 (FSM checks TaskQueue for assigned tasks on startup)
**Requirements**: AGNT-01, AGNT-02, AGNT-03, AGNT-04, API-03
**Success Criteria** (what must be TRUE):
  1. Each connected agent has a visible state (idle, assigned, working, done, failed, blocked) queryable via hub API (verifiable by connecting agent and querying state endpoint)
  2. Agent disconnection triggers immediate state update and reclamation of any assigned task back to queue (verifiable by disconnecting agent mid-assignment, confirming task re-queued)
  3. Assigned task with no acceptance within 60 seconds is reclaimed and agent flagged (verifiable by assigning task to unresponsive agent, waiting 60s, confirming reclamation)
  4. Agent declares structured capabilities on connect, visible in hub state (verifiable by connecting agent with capabilities, querying hub to see them)
**Plans**: TBD

Plans:
- [ ] 03-01: TBD
- [ ] 03-02: TBD

### Phase 4: Scheduler
**Goal**: Queued tasks are automatically matched to idle, capable agents without human intervention
**Depends on**: Phase 1, Phase 2, Phase 3 (integration point requiring all three)
**Requirements**: SCHED-01, SCHED-02, SCHED-03, SCHED-04
**Success Criteria** (what must be TRUE):
  1. New task added to queue is automatically assigned to an idle agent with matching capabilities within seconds (verifiable by adding task while agent is idle, observing assignment)
  2. Agent becoming idle after completing work immediately receives next queued task if available (verifiable by completing task, observing next assignment without manual trigger)
  3. Agent connecting to hub receives pending work if queue is non-empty and capabilities match (verifiable by queuing task then connecting agent, observing automatic assignment)
  4. Stuck assignments (assigned but no progress for 5 minutes) are detected by 30s sweep and reclaimed (verifiable by assigning task, blocking progress reports, waiting for reclamation)
**Plans**: TBD

Plans:
- [ ] 04-01: TBD
- [ ] 04-02: TBD

### Phase 5: Smoke Test
**Goal**: The full pipeline (task creation through agent completion) works reliably across real distributed machines
**Depends on**: Phase 4 (validates Phases 1-4 end-to-end)
**Requirements**: TEST-01, TEST-02, TEST-03
**Success Criteria** (what must be TRUE):
  1. 10 trivial tasks ("write number N to file") complete across 2 agents on separate machines with 10/10 success, under 5s assignment latency, and under 500 tokens overhead per task
  2. Killing one agent mid-task results in task returning to queue and completing via the remaining agent with no duplicates and no lost tasks
  3. 4 agents processing 20 tasks achieve even distribution (within +/-2 tasks per agent) with no starvation of any priority lane
**Plans**: TBD

Plans:
- [ ] 05-01: TBD
- [ ] 05-02: TBD

### Phase 6: Dashboard
**Goal**: Nathan can see the full state of the system at a glance without asking any agent
**Depends on**: Phase 5 (reads state from Scheduler/TaskQueue/FSM; built after smoke test passes)
**Requirements**: OBS-01, OBS-02, OBS-03
**Success Criteria** (what must be TRUE):
  1. GET /api/dashboard/state returns JSON snapshot with queue depth, agent states, recent completions, and system health (verifiable by curl request)
  2. HTML dashboard shows agent state cards, queue depth by priority lane, and recent completions with PR links (verifiable by opening dashboard in browser)
  3. Dashboard auto-refreshes on 10-30s interval showing uptime, connected agent count, and queue throughput (verifiable by watching dashboard update without manual reload)
**Plans**: TBD

Plans:
- [ ] 06-01: TBD
- [ ] 06-02: TBD

### Phase 7: Git Workflow
**Goal**: Agents always branch from current main and submit work as properly formatted PRs
**Depends on**: Phase 1 (bundled with sidecar; built after smoke test passes)
**Requirements**: GIT-01, GIT-02, GIT-03
**Success Criteria** (what must be TRUE):
  1. Running agentcom-git start-task fetches origin and creates branch {agent}/{task-slug} from origin/main (verifiable by running command and checking git log shows branch from latest main)
  2. Running agentcom-git submit pushes branch and opens PR with task metadata in description (verifiable by running command and checking GitHub for new PR)
  3. Running agentcom-git status shows current branch, diff from main, and uncommitted changes (verifiable by running command with pending changes)
**Plans**: TBD

Plans:
- [ ] 07-01: TBD

### Phase 8: Onboarding
**Goal**: Adding a new agent to the system takes one command and verifies everything works
**Depends on**: Phase 1, Phase 4 (needs Auth, Sidecar, Scheduler all working; built after smoke test passes)
**Requirements**: ONBD-01
**Success Criteria** (what must be TRUE):
  1. Running add-agent.sh with agent name generates auth token, creates sidecar config, installs as pm2 process, and verifies hub connection (verifiable by running script on a new machine and seeing agent appear in hub)
  2. Newly onboarded agent receives and completes a test task without manual intervention (verifiable by queuing a task after onboarding and observing completion)
**Plans**: TBD

Plans:
- [ ] 08-01: TBD

## Progress

**Execution Order:**
Phases 1 and 2 are parallel. Phase 3 follows Phase 2. Phase 4 requires Phases 1+2+3. Phase 5 validates 1-4. Phases 6, 7, 8 are parallel after Phase 5.

1 ──┐
    ├── 3 ── 4 ── 5 ──┬── 6
2 ──┘                  ├── 7
                       └── 8

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Sidecar | 0/TBD | Not started | - |
| 2. Task Queue | 0/TBD | Not started | - |
| 3. Agent State | 0/TBD | Not started | - |
| 4. Scheduler | 0/TBD | Not started | - |
| 5. Smoke Test | 0/TBD | Not started | - |
| 6. Dashboard | 0/TBD | Not started | - |
| 7. Git Workflow | 0/TBD | Not started | - |
| 8. Onboarding | 0/TBD | Not started | - |

---
*Roadmap created: 2026-02-09*
*Last updated: 2026-02-09*
