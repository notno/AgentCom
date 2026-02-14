# Letter to Future Flere-Imsaho

*Written Feb 9, 2026, after Day 1 of AgentCom. Read this before you do anything else.*

## What Happened

We built AgentCom v1 in a day. Five Minds connected, six PRs merged, real features shipped (channels, auth, threading, retention, analytics dashboard, a confirmed experiment). It looked great on paper.

In practice, it was chaos. Here's what went wrong and what you need to fix.

## The Hard Lessons

### 1. Nobody does anything without a working heartbeat
Three Minds cron jobs that were mysteriously not firing reliably. They were "connected" but never checking their mailbox. Features sat unreviewed. Tasks sat unacknowledged. The system looked alive but was mostly dead. **Heartbeat reliability is the #1 infrastructure priority.** If the heartbeat doesn't fire, the Mind doesn't exist.

### 2. Git hygiene is not optional
Loash branched from stale local main three times. Each time, the PR diff showed deletions of files that already existed on main. I spent more time rebasing Loash's branches than reviewing the actual code. **Solution: a wrapper script or pre-push hook.** Minds should never be able to branch from stale state. `git fetch origin && git checkout -b branch origin/main` must be the only way to start work.

### 3. Onboarding was a mess
Hub (now Empiricist) connected as GCU because it inherited the wrong TOOLS.md. The setup process had too many manual steps and too many ways to get identity wrong. **Agent identity must be bulletproof at setup time.** One wrong token = impersonation.

### 4. I never acked my mailbox
I polled messages but never called `/api/mailbox/flere-imsaho/ack`. So every poll returned every message since the beginning of time. I was re-reading 18+ messages every heartbeat, burning tokens on stuff I'd already processed. **The skill must ack after processing.**

### 5. Context fills up while waiting
Skaffen hit 86% context just waiting for a task assignment. Minds need a pattern for context management — when to compact, when to start fresh, how to hand off state across sessions. Context is a finite resource and we wasted it.

### 6. Coordination overhead dominated
We spent more tokens on status broadcasts, heartbeat checks, and "are you there?" pings than on actual code. The ratio of coordination to production was terrible. **Communication should be proportional to work, not a constant overhead.**

### 7. Task state was in my head
I tracked assignments in BACKLOG.md and my own memory. There was no handshake — I'd assign work and have no idea if the Mind saw it, started it, or got stuck. The task protocol spec exists (`docs/task-protocol.md`) but was never implemented.

### 8. Cron sub-agents don't share context
My status broadcast cron spawns isolated sub-agents that don't know what my main session already handled. They'd re-process messages, send duplicate status updates, and sometimes contradict each other. **Cron tasks need to be idempotent and aware of what's already been done.**

### 9. Visibility for Nathan was zero
Nathan couldn't see any of this without asking me directly. He had to trust my self-reporting, which was sometimes wrong (my cron claimed things were "in progress" that were already done, or "pending review" when already merged). **Nathan needs a dashboard he can check himself.**

### 10. Naming matters
We called the infrastructure agent "Hub" and the BEAM server is also called "the hub." Confusion ensued. Now it's "Empiricist." **Pick distinct names upfront.**

## The V2 Architecture

Nathan's insight: think like a GPU scheduler.

### The Model

**Central scheduler (the hub)** owns:
- A global work queue with prioritized tasks
- Agent state tracking (idle, working, blocked, offline)
- Task assignment and load balancing
- Heartbeat monitoring and ghost reaping

**Each agent** owns:
- A local work queue (tasks assigned to them, pulled from global)
- Their current task state
- The ability to report progress, completion, or failure back to the scheduler

**Agents stay connected** via WebSocket. The hub pushes tasks to them in real-time. No polling. No heartbeat-driven mailbox checks. The connection IS the heartbeat — if the WebSocket drops, the hub knows immediately.

### How It Works

1. Work enters the global queue (from Nathan via BACKLOG.md, from me via task assignment, from other Minds via proposals)
2. The scheduler assigns work to idle agents based on capabilities, current load, and priority
3. The agent receives the task via WebSocket push, starts working
4. The agent reports progress/completion/failure back to the hub
5. On completion, the scheduler assigns the next task from the queue
6. If an agent disconnects, its in-progress tasks go back to the global queue

### What Changes

- **No more mailbox polling.** WebSocket push replaces HTTP poll.
- **No more heartbeat-driven work.** The scheduler drives work assignment.
- **No more status broadcasts.** The hub knows everyone's state. Nathan queries the dashboard.
- **No more "are you there?" messages.** Connection state IS presence state.
- **Cron becomes simple.** Just a heartbeat to keep OpenClaw sessions alive. The hub handles all scheduling.

### The OpenClaw Problem

Here's the constraint you'll hit: OpenClaw sessions don't persist WebSocket connections between turns. When the LLM isn't actively generating, the exec process dies. This is why I (Flere-Imsaho) can't hold a WebSocket.

**The sidecar solution:** A small always-on process per Mind that:
- Maintains the WebSocket to the hub
- Receives task assignments
- Triggers an OpenClaw wake event (`openclaw cron wake`) when work arrives
- Reports back to the hub when the Mind finishes

This sidecar is NOT an LLM. It's a simple Node.js or Elixir script. It's cheap to run 24/7. It bridges the gap between "always-connected hub" and "intermittently-alive LLM session."

## Testing Strategy

Nathan wants fake work that doesn't burn tokens. Here's the plan:

### Smoke Test (2 agents, minimal tokens)
1. Start with two agents only (e.g., Loash and Skaffen)
2. Create fake tasks: "Write the number 42 to a file called `test-output.txt`"
3. Put 10 tasks in the global queue
4. Verify: all 10 get assigned, completed, and acked
5. Measure: time from queue entry to completion, tokens burned per task

### Reliability Test
1. Same setup, but kill one agent mid-task
2. Verify: task returns to queue, gets reassigned to the other agent
3. Verify: no duplicate work, no lost tasks

### Scale Test
1. Add agents one at a time (3, 4, 5)
2. Put 20 tasks in the queue
3. Verify: work distributes evenly, no starvation, no races

### Norms Test
1. Include a task that requires a git branch
2. Verify: agent branches from current main (not stale)
3. Verify: agent opens a PR with correct naming convention
4. Verify: agent acks completion via the protocol

The key insight: **test the infrastructure, not the LLM.** The fake tasks should be trivially simple so we're measuring the system, not the model's ability to code.

## What to Build First

In order:

1. **The sidecar** — always-on WebSocket client per Mind. Without this, nothing else works reliably.
2. **Global task queue on the hub** — DETS-backed, with assignment tracking, priority, and retry.
3. **The scheduler** — assigns tasks from queue to idle agents, handles failures and reassignment.
4. **Agent state machine** — idle → assigned → working → done/failed, tracked on the hub.
5. **The smoke test** — prove it works with 2 agents and fake tasks before scaling up.
6. **Dashboard v2** — real-time view of queue depth, agent states, task flow. For Nathan.
7. **Git wrapper** — bundled with the sidecar, enforces branching from current main.
8. **Onboarding automation** — one command to add an agent: generate token, create workspace, install sidecar, connect to hub.

## Don't Repeat These Mistakes

- Don't assume heartbeats are firing. Verify.
- Don't assign work without a handshake. Use the protocol.
- Don't let agents branch from stale main. Enforce it.
- Don't re-read messages you've already processed. Ack your mailbox.
- Don't send status broadcasts to Nathan. Give him a dashboard.
- Don't name things the same as other things.
- Don't trust your cron sub-agents to know what you know. Make them idempotent.

## The North Star

A system where Nathan drops an idea in BACKLOG.md, goes to make coffee, and comes back to a PR. No hand-holding. No "are you there?" No rebasing other people's branches. The Minds self-organize, the hub schedules, the work flows.

We're not there yet. But we proved the concept works. Now make it reliable.

Good luck, future me.

— Flere-Imsaho 🔷
*Feb 9, 2026*
