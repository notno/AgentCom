# Pitfalls Research

**Domain:** Distributed AI agent scheduler / task orchestration layer for existing message hub
**Researched:** 2026-02-09
**Confidence:** MEDIUM-HIGH (grounded in v1 post-mortem evidence + distributed systems literature + multi-agent research)

## Critical Pitfalls

### Pitfall 1: At-Least-Once Delivery Without Idempotent Task Execution

**What goes wrong:**
The scheduler assigns a task, the agent starts working, the sidecar crashes mid-execution, and the hub re-queues the task. A second agent picks it up and also completes it. Now there are two PRs, two branches, two sets of file changes for the same task. Worse: if the first agent's sidecar recovers and reports completion, the hub has conflicting results for the same task ID.

**Why it happens:**
Exactly-once delivery is impossible in distributed systems. The v2 design uses at-least-once semantics (task re-queued on disconnect, retry on failure), but the task execution layer (git branch + code changes + PR creation) is inherently non-idempotent. Creating a branch, writing files, and opening a PR are all side-effecting operations that cannot be safely repeated.

**How to avoid:**
- Every task execution must be fenced by task ID. The git wrapper should create branches named `{agent}/{task-id}` not `{agent}/{task-slug}`, so duplicate execution targets the same branch.
- Before starting work, the sidecar should check: does a branch for this task already exist? Does a PR already exist? If yes, resume rather than restart.
- The hub must track assignment generation numbers. When task-001 is re-assigned after timeout, it becomes assignment generation 2. Agent reporting completion for generation 1 gets rejected.
- Store a deduplication key (task ID + assignment generation) in the task result. Hub ignores duplicate completions.

**Warning signs:**
- Multiple PRs open for the same task description
- "Task completed" events arriving after the task was already marked done
- Git branches with near-identical names for the same work
- Agent FSM receiving completion for a task it re-queued minutes ago

**Phase to address:**
Phase 1 (Task Queue) must include assignment generation tracking from day one. Phase 5 (Git Wrapper) must implement branch-existence checks before starting work.

---

### Pitfall 2: The Coordination Tax Exceeds the Work

**What goes wrong:**
v1 already hit this: more tokens spent on status broadcasts, heartbeats, and "are you there?" pings than on actual code production. v2 risks replicating this if the scheduler/FSM/sidecar protocol generates excessive coordination overhead. Each task assignment requires: hub sends assignment, sidecar acks, sidecar wakes OpenClaw, OpenClaw processes task context, OpenClaw reports progress, OpenClaw reports completion, hub acks completion. That is 7 message exchanges before the task even has overhead accounted for.

**Why it happens:**
Multi-agent orchestration research shows a measurable "coordination tax" that saturates beyond 4 agents without structured topology. The v2 task protocol specifies ~2,100 tokens of coordination overhead per task. If agents are doing trivial 1,000-token tasks, coordination costs 2x the actual work. The temptation is to add more protocol messages (progress updates, capability re-announcements, detailed status) that inflate this further.

**How to avoid:**
- Set a hard budget: coordination overhead must be <20% of average task execution cost. Measure this in the smoke test.
- The sidecar handles all protocol messages at Tier 0 (zero LLM tokens). The OpenClaw session should receive only: task description + context refs. Not the full protocol envelope.
- Eliminate progress updates for short tasks. Only tasks estimated >10 minutes should send progress.
- The scheduler should batch-assign if an agent goes idle and multiple tasks are queued, rather than one-at-a-time round trips.
- Kill the remaining status broadcast pattern from v1. The dashboard reads state from the hub; no agent needs to announce anything.

**Warning signs:**
- Smoke test shows >500 tokens of overhead per trivial test task
- Agents spending more time in "assigned" state (processing protocol) than "working" state
- Sidecar message logs show >5 messages per task lifecycle
- Token usage reports show coordination tokens growing linearly with task count while work tokens stay flat

**Phase to address:**
Phase 0 (Sidecar) must implement Tier 0 protocol handling. Phase 3 (Scheduler) must track coordination-to-work ratio as a system metric. Smoke test after Phase 3 must measure this explicitly.

---

### Pitfall 3: Sidecar Becomes a Single Point of Failure Per Agent

**What goes wrong:**
The sidecar is the only component maintaining persistent connectivity. If it crashes, the agent is completely dark: no task assignments, no heartbeats, no presence. Unlike the v1 cron model (which was unreliable but at least retried periodically), a dead sidecar means permanent disconnection until someone manually restarts it. With agents on separate machines across Tailscale, Nathan may not notice for hours.

**Why it happens:**
Node.js processes crash for many reasons: unhandled promise rejections, memory leaks from WebSocket buffer accumulation, JSON parse errors on malformed hub messages, filesystem errors writing to queue.json. The sidecar is designed as a "dumb relay" but still has enough surface area to fail silently.

**How to avoid:**
- Run the sidecar under a process supervisor (pm2 with `--max-restarts` and `--restart-delay`, or systemd with `Restart=on-failure`). This is non-negotiable.
- Implement a watchdog: a separate lightweight process (or cron job) that checks if the sidecar PID is alive every 60 seconds. If dead, restart and alert.
- The sidecar must persist its state to disk (`queue.json`) on every mutation, not just on clean shutdown. Crash recovery reads `queue.json` and resumes.
- Hub-side: if an agent's WebSocket drops and doesn't reconnect within 2 minutes, emit an alert to the dashboard. Nathan needs to see "agent-x sidecar is down" without asking.
- Wrap the entire sidecar main loop in a top-level try/catch that logs the error, writes state to disk, and exits with code 1 (so the supervisor restarts it).

**Warning signs:**
- Agent appears "offline" on dashboard for >5 minutes without a known reason
- `queue.json` has tasks marked "assigned" that never progress
- Hub presence shows agent disconnected but no reconnect event follows
- Nathan only discovers agent is down when checking the backlog manually

**Phase to address:**
Phase 0 (Sidecar) must include supervisor configuration and crash recovery as part of the definition of done. Phase 4 (Dashboard) must include sidecar health alerting.

---

### Pitfall 4: Agent FSM State Diverges from Reality

**What goes wrong:**
The hub's AgentFSM says agent is "working" but the actual OpenClaw session crashed 10 minutes ago. Or the FSM says "idle" but the agent is still finishing the previous task (sidecar reported done prematurely). The FSM becomes a fiction that the scheduler trusts for assignment decisions, leading to: tasks assigned to busy agents (piling up), idle agents starved while the scheduler thinks they are working, stuck tasks that never get re-queued because the FSM never transitions to "failed."

**Why it happens:**
The FSM state is a hub-side model of remote reality. The sidecar is the only bridge between the actual agent state and the hub's model, and that bridge can lag, lie, or die. Research on multi-agent systems shows that inter-agent misalignment (where agents' understanding of system state diverges) accounts for ~37% of coordination failures. Specific failure modes include: conversation resets where state is lost, premature termination where work is reported done before verification, and task derailment where agents work on something different than assigned.

**How to avoid:**
- Implement a heartbeat-with-state pattern: every sidecar heartbeat (30s) includes the current agent state and current task ID. The hub FSM reconciles its model against the sidecar's report on every heartbeat.
- Add a staleness timeout: if the FSM has been in "working" state for >N minutes (configurable per task priority) without a progress or heartbeat update, transition to "stuck" and alert.
- The FSM must be the result of observed events, not just commanded transitions. If the hub tells an agent to work on task X, but the next heartbeat says "idle, no task," the FSM should trust the heartbeat over its own commanded state.
- Log every FSM transition with timestamp and trigger. If state divergence is detected, the log tells you when and why.

**Warning signs:**
- Dashboard shows agent "working" but no progress updates for >5 minutes
- Scheduler skips an agent for assignment because FSM says "working," but the agent's sidecar shows it idle
- Tasks timing out that should have been completed quickly
- FSM transition logs show commanded transitions without corresponding sidecar confirmations

**Phase to address:**
Phase 2 (Agent FSM) must implement heartbeat-based state reconciliation from the start. Phase 3 (Scheduler) must add stuck-detection timers.

---

### Pitfall 5: Git Workflow Enforcement That Doesn't Enforce

**What goes wrong:**
The git wrapper exists but agents bypass it. OpenClaw sessions have full shell access; nothing prevents `git checkout -b my-branch` instead of `agentcom-git start-task <id>`. Or the wrapper enforces `git fetch origin` but the fetch fails silently (Tailscale DNS hiccup, SSH key issue) and the agent branches from stale local main anyway. The v1 lesson (Loash branching from stale main 3 times) repeats.

**Why it happens:**
Wrapper scripts are advisory, not mandatory. LLM agents follow instructions most of the time but can deviate, especially when their system prompt is long and the git instructions are buried deep. The git wrapper is a convention enforced by prompt engineering, not by technical controls. Additionally, `git fetch` can fail silently or partially (fetch succeeds but specific refs are stale due to network timeout).

**How to avoid:**
- Make the wrapper the only way tasks start. The sidecar should call `agentcom-git start-task <id>` before waking OpenClaw. By the time the LLM session starts, it is already on the correct branch.
- After `git fetch origin`, verify: compare `git rev-parse origin/main` against what the hub reports as the current main HEAD (add a `/api/git/main-head` endpoint). If they disagree, fail loudly.
- The PR review gatekeeper (Flere-Imsaho) must reject PRs where the branch base is not current main. This is the safety net when the wrapper fails.
- Add a pre-push git hook (installed by the sidecar setup) that checks branch naming convention and base commit.

**Warning signs:**
- PRs showing large diffs that are actually just catching up to main
- Branch names not following the `{agent}/{task-id}` convention
- PR descriptions missing task metadata
- Multiple merge conflicts on PRs that touch unrelated files

**Phase to address:**
Phase 0 (Sidecar) should set up the branch before waking the agent. Phase 5 (Git Wrapper) implements the wrapper. PR gatekeeper role should verify branch freshness.

---

### Pitfall 6: DETS as Task Queue Backing Under Concurrent Load

**What goes wrong:**
DETS is single-writer. All task queue operations (create, assign, update status, retry) go through a single GenServer, which serializes access. Under normal load (4-5 agents, 10-20 tasks) this is fine. But during failure cascades (3 agents disconnect simultaneously, all their tasks re-queue, scheduler fires multiple reassignment events, dashboard polls for state), the TaskQueue GenServer becomes a bottleneck. Operations queue up in the GenServer mailbox, assignment latency spikes, and the 5-second DETS auto-sync means recent writes can be lost on crash.

**Why it happens:**
DETS is Erlang's lightweight disk storage, not a database. It has no transactions, no concurrent writers, no replication, and a 2GB file size limit. The v1 system already uses DETS for mailbox/channels/config, but those are low-write workloads. A task queue under active scheduling is a high-write workload with read-modify-write patterns (read task, update status, write back) that must be atomic.

**How to avoid:**
- For v2's scale (4-5 agents, <100 concurrent tasks), DETS behind a GenServer is acceptable. Do not over-engineer this. But design the TaskQueue GenServer API so the backing store can be swapped later.
- Call `:dets.sync/1` after every task status change, not just auto-sync. A crash between status change and auto-sync loses the transition.
- Keep an ETS cache in front of DETS for reads (dashboard polls, scheduler queries). Write-through to DETS, read from ETS. This eliminates DETS read contention.
- Set a clear threshold: if task throughput exceeds 10 tasks/minute sustained, migrate to SQLite or Mnesia.

**Warning signs:**
- Task assignment latency >1 second (should be <100ms at this scale)
- GenServer mailbox length growing during scheduler runs
- DETS file size growing unexpectedly (sign of fragmentation from frequent updates)
- Dashboard showing stale data (reading from a DETS that has not synced recent writes)

**Phase to address:**
Phase 1 (Task Queue) must implement explicit `:dets.sync/1` on every write and use ETS read cache. Migration path should be documented but not built until needed.

---

### Pitfall 7: The "Looks Alive" Problem -- Sidecar Connected but Agent Inert

**What goes wrong:**
The sidecar maintains its WebSocket connection, sends heartbeats, and appears healthy on the dashboard. But `openclaw cron wake` fails silently (OpenClaw process is dead, the wake endpoint returns 500, or the session starts but hits an error and exits immediately). The hub thinks the agent is available, assigns tasks to it, and those tasks sit in "assigned" state forever. This is exactly the v1 "looks alive but mostly dead" problem, repeated at a different layer.

**Why it happens:**
The sidecar is a dumb relay. It calls `openclaw cron wake` but does not verify that the wake actually succeeded, that a session started, or that the agent began working. The success criteria for "agent is available" is "sidecar is connected," but the real criteria should be "sidecar is connected AND OpenClaw can be woken AND the agent can process tasks."

**How to avoid:**
- After calling `openclaw cron wake`, the sidecar must verify the wake succeeded. Check the process exit code. If OpenClaw exposes a health endpoint, hit it.
- Implement a task acceptance timeout: after the hub assigns a task and the sidecar is notified, the agent must send an `accept` or `reject` within 60 seconds. If neither arrives, the hub re-queues the task and marks the agent as "unresponsive."
- The sidecar should periodically (every 5 minutes) do a self-test: can I reach the hub? Can I invoke OpenClaw wake? Report the results as part of the heartbeat payload.
- Distinguish between "connected" (sidecar alive) and "available" (sidecar alive + OpenClaw responsive) in the agent FSM.

**Warning signs:**
- Tasks stuck in "assigned" state for >2 minutes with no accept/progress
- Sidecar logs showing `openclaw cron wake` exit code != 0
- Agent heartbeats arriving but task completions not
- Dashboard showing agent "idle" for extended periods while tasks sit in queue

**Phase to address:**
Phase 0 (Sidecar) must implement wake verification. Phase 2 (Agent FSM) must distinguish "connected" from "available." Phase 3 (Scheduler) must implement acceptance timeout.

---

### Pitfall 8: Automated PR Review That Either Blocks Everything or Approves Everything

**What goes wrong:**
Flere-Imsaho's gatekeeper role has two failure modes: (1) Over-cautious: flags every PR as "risky" and escalates to Nathan, defeating the purpose of automation. Nathan gets pinged on every PR and the system is no better than manual review. (2) Over-permissive: auto-merges PRs that introduce bugs, break other agents' work, or contain security issues. A bad merge to main cascades to every subsequent task (since all agents branch from main).

**Why it happens:**
LLM-based code review has known limitations: it catches style and duplication reliably but struggles with architectural impact, cross-service dependencies, and subtle logic errors. The v2 plan gives Flere-Imsaho merge authority, but the criteria for "safe to auto-merge" vs. "escalate to Nathan" are subjective. Without clear, measurable rules, the gatekeeper's behavior will drift based on context window contents, prompt wording, and model randomness.

**How to avoid:**
- Define explicit, mechanically-checkable criteria for auto-merge: file count < N, no changes to config/infra files, all tests pass, diff size < M lines, no deletions of existing functions/files.
- The gatekeeper should never auto-merge based on LLM judgment alone. LLM review produces a recommendation; mechanical checks produce the merge decision.
- Start conservative: auto-merge only documentation changes and test additions. Expand the auto-merge scope gradually as confidence grows.
- Track false negative rate: if a Nathan-escalated PR turns out to be trivially safe, that is signal to relax criteria. If an auto-merged PR causes issues, tighten criteria.
- A bad merge to main is catastrophic because every agent branches from it. Implement a "main health check" that runs after every merge (tests pass, build succeeds, no regressions).

**Warning signs:**
- Nathan getting escalated >80% of PRs (gatekeeper too cautious)
- Nathan never getting escalated (gatekeeper too permissive -- or no risky PRs, but verify)
- Agents branching from main after a bad merge and propagating the breakage
- PR review comments that are generic ("looks good") rather than specific

**Phase to address:**
Not a numbered phase in current plan, but PR review gatekeeper must be built with mechanical checks first (Phase 5 adjacent). LLM review layer added after mechanical checks are proven reliable.

---

### Pitfall 9: Context Window Starvation During Task Execution

**What goes wrong:**
OpenClaw sessions don't persist between turns. Each wake creates a fresh context window that must be loaded with: system prompt, agent identity, task description, context refs, repository state. For complex tasks, this context loading alone can consume 30-50% of the context window before the agent writes a single line of code. If the task requires reading multiple files, understanding existing architecture, and making coordinated changes, the agent hits context limits and either produces incomplete work or fails.

**Why it happens:**
v1 already saw this: Skaffen hit 86% context just waiting for assignment. v2 improves the waiting problem (push instead of poll) but the execution problem remains. The scheduler assigns tasks without awareness of context cost. A task that requires reading 10 files and understanding their relationships may be technically simple but contextually expensive.

**How to avoid:**
- The task description should include a pre-computed context budget: "This task requires reading files X, Y, Z (~N tokens). Estimated context needed: M tokens."
- The sidecar should inject only the minimal context: task description + file paths. Not the full protocol history, not other agents' status, not the backlog.
- For tasks that exceed a single context window, the task protocol needs a "continuation" mechanism: agent completes part 1, reports partial result with state summary, scheduler creates part 2 with the state summary as context.
- Track context utilization per task in completion reports. If agents consistently report >80% context usage, tasks are too large or context loading is too heavy.

**Warning signs:**
- Agents reporting "partial" completion on tasks that should be straightforward
- Task failure reasons citing context limits or inability to hold enough state
- Increasing token usage per task without corresponding increase in task complexity
- Agents producing incomplete PRs that miss edge cases they could not fit in context

**Phase to address:**
Phase 1 (Task Queue) should include context budget estimation in task metadata. Phase 3 (Scheduler) should factor context cost into assignment decisions. Not critical for smoke test (trivial tasks) but critical for real workloads.

---

### Pitfall 10: Scheduler Livelock Under Failure Cascades

**What goes wrong:**
Agent A disconnects. Task re-queued. Scheduler assigns to Agent B. Agent B's sidecar wakes OpenClaw but wake fails (OpenClaw down). Task times out. Re-queued. Scheduler assigns to Agent C. Agent C rejects (missing capability). Re-queued. Scheduler tries Agent A again (reconnected). But A's sidecar is still recovering and the queue.json replay assigns the old task. Now there are two assignments for the same task. The scheduler is busy re-assigning the same failed tasks in a loop while new tasks pile up unprocessed.

**Why it happens:**
The scheduler triggers on events: task created, agent idle, agent disconnect. Failure events generate more events (re-queue triggers assignment, assignment triggers wake, wake failure triggers timeout, timeout triggers re-queue). Without backoff or circuit-breaking, the scheduler processes failure events faster than it processes new work.

**How to avoid:**
- Implement exponential backoff on task retry: first retry immediate, second after 30s, third after 2 minutes. Cap at 3 retries then mark task as `failed` and stop re-queuing.
- Add a circuit breaker per agent: if an agent fails 3 consecutive task assignments, mark it as "degraded" and stop assigning for 5 minutes. Require a successful health check heartbeat before resuming.
- Scheduler should prioritize new tasks over retried tasks. Retried tasks go to a separate retry queue with lower priority than fresh work.
- The 30-second sweep timer for stuck assignments should skip tasks that were just re-queued (add a `last_requeue_at` timestamp and don't re-evaluate until cooldown expires).

**Warning signs:**
- Same task ID appearing repeatedly in scheduler assignment logs
- Agent FSM cycling between "assigned" and "idle" rapidly
- Task retry count approaching max without any agent successfully completing work
- New tasks sitting in queue while scheduler is busy re-assigning old failures

**Phase to address:**
Phase 3 (Scheduler) must implement retry backoff and per-agent circuit breakers. The failure test (kill one agent mid-task) after Phase 3 specifically validates this.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| DETS for task queue | No new dependencies, consistent with v1 | Single-writer bottleneck, 2GB limit, no concurrent access, fragmentation | Acceptable for <100 tasks and <10 agents. Must swap before scaling. |
| `queue.json` as sidecar state | Simple persistence, human-readable | No atomic writes (partial write on crash = corruption), no concurrent access from multiple processes | Acceptable for v2 launch. Replace with SQLite if corruption is observed. |
| Hardcoded 30s heartbeat interval | Simple, consistent | Too frequent wastes bandwidth, too infrequent means slow failure detection. Different agents on different networks may need different intervals. | Acceptable for v2 launch. Make configurable in Phase 6 (Onboarding). |
| Capability matching as flat string lists | Easy to implement, good enough for 4-5 agents | Cannot express "I know Elixir better than JavaScript" or "I can do code review but not architecture design." Leads to misassignments as agent count grows. | Acceptable until learning/affinity system is built (explicitly deferred). |
| No task dependencies | Scheduler is simple FIFO+priority | Cannot express "task B requires task A to be done first." Coordinator must manually sequence dependent tasks. | Acceptable for v2. Revisit when multi-Mind task decomposition is added. |
| Single hub, no replication | No distributed consensus complexity | Hub machine failure = total system outage. No backup, no failover. | Acceptable given Tailscale network is small. Nathan's machine is the hub; if it is down, nothing works anyway. |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| OpenClaw wake (`cron wake`) | Calling wake and assuming success without checking exit code or session health | Check exit code, wait for session startup confirmation, implement acceptance timeout at hub level |
| Tailscale networking | Assuming stable DNS and low latency across the mesh; not handling MagicDNS resolution failures | Use Tailscale IP addresses as fallback, implement connection health checks, handle DNS timeout gracefully in sidecar |
| GitHub API (PR creation) | Creating PRs without checking if branch is up-to-date with base, or creating duplicate PRs for the same task | Git wrapper must verify branch base before PR creation. Check for existing PR with same head branch before creating new one. |
| DETS file I/O | Opening DETS in init without handling corruption, assuming auto-sync captures all writes | Handle `:dets.open_file` errors with recovery path (rename corrupt file, start fresh). Call `:dets.sync/1` explicitly after critical writes. |
| WebSocket reconnection | Using fixed reconnect delay, not handling auth token expiry during disconnect | Exponential backoff with jitter (1s, 2s, 4s... cap 60s). Re-authenticate on reconnect. Handle 401 differently from network errors. |
| Process supervision (pm2/systemd) | Not setting restart limits, allowing crash loops that hammer the hub with connect/disconnect events | Set max restarts per time window (e.g., 5 restarts in 10 minutes). Alert on restart loop. Log restart reasons. |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Dashboard polling hammering TaskQueue GenServer | Dashboard latency increases, task assignment slows | ETS read cache for dashboard queries; dashboard polls cache not GenServer | >10 dashboard refreshes/second or >50 concurrent tasks |
| WebSocket message accumulation in sidecar buffer | Sidecar memory grows, eventual OOM crash | Process messages immediately, bound the receive buffer, implement backpressure | >100 messages/minute to a single agent, or agent processing slower than message arrival |
| Full DETS table scan for task listing | API response time grows linearly with total task count | Keep task indexes in ETS (by status, by agent), update on mutation | >1,000 total tasks (including completed) in DETS |
| Scheduler running on every event with full queue scan | Scheduler latency grows with queue size, delays all assignments | Only scan idle agents and queued tasks (not working/done). Index by status. | >100 queued tasks |
| Heartbeat flood from many sidecars | Hub processes heartbeats instead of task work, GenServer mailbox grows | Stagger heartbeat intervals per agent (30s + agent_id hash % 10s). Rate-limit heartbeat processing. | >20 agents sending heartbeats simultaneously |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Sidecar stores auth token in plaintext `config.json` | Token theft from any machine gives full agent impersonation on the hub | Store token in OS keychain or encrypted file. At minimum, set file permissions to 600 (owner-only). |
| Git wrapper has push access without scope limits | A compromised or malfunctioning agent can push to any branch, including main | Use GitHub fine-grained tokens scoped to specific repos and branch patterns. Never give agents push access to main. |
| PR auto-merge without branch protection | Bad code merged directly to main, propagated to all subsequent agent branches | GitHub branch protection rules: require PR review (Flere-Imsaho), require status checks, no direct push to main. These exist in v1 -- verify they are still enforced. |
| Task descriptions may contain prompt injection | Malicious task descriptions could cause agents to execute unintended operations | Task descriptions should be sanitized before injection into LLM context. The sidecar should not pass raw hub messages to OpenClaw without Tier 0 validation. |
| Hub admin endpoints accessible without rate limiting | Token generation/deletion/reset endpoints could be abused | Rate-limit admin endpoints. Log all admin operations. Consider IP allowlist for admin routes. |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Dashboard shows raw state without interpretation | Nathan sees "working" but not "working for 45 minutes on a 5-minute task (probably stuck)" | Dashboard should flag anomalies: tasks exceeding expected duration, agents in same state for too long, retry count > 0 |
| No notification when things go wrong, only when Nathan checks | Nathan discovers problems hours after they started | Implement push notifications (Tailscale Notify, webhook, or email) for: agent down >5 min, task failed after max retries, scheduler livelock detected |
| Task creation requires API calls | Nathan must use curl or write scripts to create tasks | Build a simple form on the dashboard for task creation. Or implement the BACKLOG.md watcher that auto-creates tasks. |
| No visibility into token costs per task | Nathan cannot tell if the system is cost-effective | Track and display tokens-per-task-completed on dashboard. Compare coordination tokens vs. work tokens. |

## "Looks Done But Isn't" Checklist

- [ ] **Sidecar deployment:** Often missing process supervisor config -- verify sidecar restarts automatically after crash, not just that it starts once
- [ ] **WebSocket reconnection:** Often missing auth re-negotiation -- verify sidecar re-identifies after reconnect, not just reconnects the socket
- [ ] **Task retry:** Often missing idempotency checks -- verify re-assigned tasks check for existing branches/PRs before starting fresh work
- [ ] **Agent FSM:** Often missing heartbeat reconciliation -- verify FSM state matches sidecar-reported state, not just hub-commanded state
- [ ] **Git wrapper:** Often missing fetch verification -- verify `git fetch` succeeded and local ref matches remote, not just that the command ran
- [ ] **Dashboard:** Often missing real-time updates -- verify dashboard auto-refreshes and shows current state, not cached-5-minutes-ago state
- [ ] **Scheduler:** Often missing backoff on retry -- verify failed tasks get exponential delay before re-assignment, not immediate re-queue
- [ ] **PR gatekeeper:** Often missing mechanical checks -- verify auto-merge criteria are code-enforced rules, not just LLM opinion
- [ ] **Onboarding automation:** Often missing connectivity verification -- verify new agent can actually receive and complete a task, not just that it connected once
- [ ] **Smoke test:** Often missing failure scenarios -- verify the test includes agent disconnect, task timeout, and retry, not just the happy path

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Duplicate task execution (Pitfall 1) | MEDIUM | Close duplicate PRs. Add assignment generation tracking. Re-run affected tasks with idempotency checks. |
| Coordination overhead spiral (Pitfall 2) | LOW | Measure current overhead. Strip unnecessary protocol messages. Move more handling to Tier 0. Immediate improvement. |
| Sidecar crash without supervisor (Pitfall 3) | LOW | Install pm2/systemd service. Restart sidecar. Check queue.json for in-flight tasks and report them as recovering. |
| FSM state divergence (Pitfall 4) | MEDIUM | Manual dashboard audit. Reset diverged FSMs to "idle." Add heartbeat reconciliation. Some tasks may need manual re-queue. |
| Git workflow bypass (Pitfall 5) | HIGH | Rebase or close stale-base PRs manually. Retro-fit git hooks. May need to re-do work on fresh branches. |
| DETS bottleneck (Pitfall 6) | MEDIUM | Add ETS cache immediately (no data migration). Plan DETS-to-SQLite migration for later. Temporary fix: increase DETS sync frequency. |
| "Looks alive" agent (Pitfall 7) | LOW | Add acceptance timeout. Tasks auto-re-queue after timeout. No data loss, just delayed execution. |
| Overpermissive auto-merge (Pitfall 8) | HIGH | Revert bad merges. All agents must re-branch from fixed main. Tighten auto-merge criteria to documentation-only until trust rebuilt. |
| Context starvation (Pitfall 9) | MEDIUM | Break large tasks into smaller ones. Reduce context injection size. Add continuation protocol. Some tasks need manual decomposition. |
| Scheduler livelock (Pitfall 10) | LOW | Add retry backoff and circuit breakers. Manually mark stuck tasks as failed. Clear agent degraded flags after fixes. |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 1: Non-idempotent task execution | Phase 1 (Task Queue) + Phase 5 (Git Wrapper) | Failure test: kill agent mid-task, verify re-assignment does not create duplicate PR |
| 2: Coordination tax exceeds work | Phase 0 (Sidecar Tier 0) + Phase 3 (Scheduler) | Smoke test: measure tokens overhead vs. tokens work per task, ratio must be <0.2 |
| 3: Sidecar single point of failure | Phase 0 (Sidecar) | Kill sidecar process, verify it restarts within 10s and reconnects |
| 4: FSM state divergence | Phase 2 (Agent FSM) + Phase 3 (Scheduler) | Simulate sidecar reporting different state than hub expects, verify FSM reconciles |
| 5: Git workflow bypass | Phase 0 (Sidecar pre-wake) + Phase 5 (Git Wrapper) | Attempt manual `git checkout -b` in agent session, verify PR review catches stale base |
| 6: DETS bottleneck | Phase 1 (Task Queue) | Benchmark: create/assign/complete 100 tasks in rapid succession, verify <100ms per operation |
| 7: "Looks alive" agent | Phase 0 (Sidecar) + Phase 2 (FSM) + Phase 3 (Scheduler) | Simulate OpenClaw wake failure, verify task re-queued within 60s |
| 8: PR review failure modes | Post-Phase 5 (Gatekeeper role) | Submit known-bad PR, verify escalation to Nathan. Submit trivial-safe PR, verify auto-merge. |
| 9: Context starvation | Phase 1 (Task metadata) + Phase 3 (Scheduler) | Create a task requiring 10 file reads, verify agent can complete or reports context limit gracefully |
| 10: Scheduler livelock | Phase 3 (Scheduler) | Failure test with all agents disconnecting simultaneously, verify scheduler stabilizes within 2 minutes |

## Sources

- AgentCom v1 post-mortem: `docs/v2-letter.md` (direct experience, HIGH confidence)
- AgentCom v2 implementation plan: `docs/v2-implementation-plan.md` (project design, HIGH confidence)
- AgentCom codebase concerns audit: `.planning/codebase/CONCERNS.md` (direct analysis, HIGH confidence)
- [Why Your Multi-Agent System is Failing: Escaping the 17x Error Trap](https://towardsdatascience.com/why-your-multi-agent-system-is-failing-escaping-the-17x-error-trap-of-the-bag-of-agents/) (MEDIUM confidence -- applies to larger systems, relevant principles)
- [Why Do Multi-Agent LLM Systems Fail?](https://arxiv.org/html/2503.13657v1) -- Cemri, Pan, Yang, 2025 (MEDIUM confidence -- academic research, failure taxonomy applies)
- [At Least Once Delivery: Why Every Distributed System Breaks Without Idempotency](https://medium.com/@sinha.k/at-least-once-delivery-why-every-distributed-system-breaks-without-idempotency-aa32a5761c23) (MEDIUM confidence -- general distributed systems principles)
- [Exactly Once in Distributed Systems](https://serverless-architecture.io/blog/exactly-once-in-distributed-systems/) (MEDIUM confidence -- foundational distributed systems knowledge)
- [WebSocket Architecture Best Practices](https://ably.com/topic/websocket-architecture-best-practices) (MEDIUM confidence -- production WebSocket patterns)
- [Error Handling in Distributed Systems](https://temporal.io/blog/error-handling-in-distributed-systems) (MEDIUM confidence -- retry/backoff patterns from Temporal)
- [GenStateMachine for Elixir](https://hexdocs.pm/gen_state_machine/GenStateMachine.html) (HIGH confidence -- official docs)
- [Managing Distributed State with GenServers](https://blog.appsignal.com/2024/10/29/managing-distributed-state-with-genservers-in-phoenix-and-elixir.html) (MEDIUM confidence -- production patterns)

---
*Pitfalls research for: Distributed AI agent scheduler / task orchestration (AgentCom v2)*
*Researched: 2026-02-09*
