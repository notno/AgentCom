# Phase 4: Scheduler - Research

**Researched:** 2026-02-10
**Domain:** Elixir/OTP event-driven scheduler, PubSub-based task matching, capability routing, stuck assignment detection
**Confidence:** HIGH

## Summary

Phase 4 is the integration point that ties Phases 1-3 together. The scheduler's job is simple but critical: when a task needs an agent, or an agent needs a task, make the match automatically. The core design is a single GenServer (`AgentCom.Scheduler`) that subscribes to PubSub events from both the TaskQueue ("tasks" topic) and Presence ("presence" topic), reacting to three trigger events: (1) new task submitted, (2) agent becomes idle, (3) agent connects. On each trigger, the scheduler queries for idle agents with matching capabilities and queued tasks, then calls the existing `TaskQueue.assign_task/3` and pushes the assignment to the agent's WebSocket via the existing `{:push_task, task}` message path.

The codebase already has all the building blocks. TaskQueue broadcasts `:task_submitted`, `:task_reclaimed`, and `:task_retried` events on the "tasks" PubSub topic. Presence broadcasts `:agent_joined` on the "presence" topic. AgentFSM provides `list_all/0` for finding idle agents and `get_capabilities/1` for capability matching. TaskQueue provides `dequeue_next/1` for getting the highest-priority queued task and `assign_task/3` for performing the assignment. Socket already has the `{:push_task, task}` handler for pushing assignments to sidecars. The scheduler just needs to listen for events and orchestrate these existing APIs.

The one gap is capability matching: tasks currently have no `needed_capabilities` field. The task struct in TaskQueue must be extended to include `needed_capabilities` (a list of capability name strings). When present, the scheduler matches task `needed_capabilities` against agent capabilities using exact string match (SCHED-02). When absent or empty, any idle agent qualifies. The stuck assignment sweep (SCHED-03) is a 30-second timer that scans for assigned tasks with no progress update for 5 minutes, reclaiming them back to the queue -- similar to the existing overdue sweep in TaskQueue but with a different trigger condition (stale progress vs. deadline expiry).

**Primary recommendation:** Create a single `AgentCom.Scheduler` GenServer that subscribes to PubSub "tasks" and "presence" topics on init. On each trigger event (task_submitted, task_reclaimed, task_retried, agent_joined, agent idle transition), call a `try_schedule/0` function that: (1) finds all idle agents via `AgentFSM.list_all/0`, (2) finds the next queued task via `TaskQueue.dequeue_next/1`, (3) filters agents by capability match, (4) assigns the task to the first matching idle agent. Run `try_schedule/0` in a loop until either no queued tasks remain or no idle agents are available. Add a 30-second stuck assignment sweep via `Process.send_after/3`. Extend the task struct with an optional `needed_capabilities` field. Add the Scheduler to the application supervision tree after TaskQueue.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GenServer (OTP) | built-in | Scheduler process that listens to events and orchestrates matching | Consistent with every stateful module in the codebase (Auth, Mailbox, TaskQueue, AgentFSM, etc.) |
| Phoenix.PubSub | ~> 2.1 | Subscribe to "tasks" and "presence" topics for event-driven scheduling | Already in project; TaskQueue broadcasts on "tasks", Presence broadcasts on "presence" |
| Process.send_after (OTP) | built-in | 30-second stuck assignment sweep timer | Same pattern used by Reaper (30s sweep) and TaskQueue (30s overdue sweep) |
| Registry (OTP) | built-in | Look up agent WebSocket pid for task push delivery | Already used (AgentRegistry for WebSocket pids, AgentFSMRegistry for FSM pids) |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Logger (OTP) | built-in | Log scheduling decisions and stuck assignment reclamation | Standard logging pattern in codebase |
| Jason | ~> 1.4 | Already in project | No new usage for scheduler |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Single GenServer scheduler | GenStage/Flow pipeline | GenStage adds a dependency and pipeline abstraction overhead for what is a simple event-handler pattern. At 4-5 agents with tasks completing every few minutes, a single GenServer comfortably handles the throughput. GenStage would be justified at 50+ agents with sub-second task arrival rates. |
| PubSub subscription for events | Polling AgentFSM.list_all and TaskQueue.dequeue_next every N seconds | Polling wastes CPU and adds latency (avg latency = poll_interval/2). PubSub events trigger scheduling within milliseconds. The 30s sweep is only a safety net, not the primary mechanism. |
| Single scheduler process | Per-agent scheduler processes | Unnecessary complexity. The scheduler's job is global matching (which task goes to which agent), not per-agent. A single process ensures consistent assignment decisions without coordination overhead. |

**Installation:** No new dependencies required. Everything is OTP built-in or already in mix.exs.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  scheduler.ex          # NEW: Event-driven task-to-agent matching GenServer
  task_queue.ex         # MODIFIED: Add needed_capabilities field to task struct
  endpoint.ex           # MODIFIED: Add needed_capabilities to task submission API
  application.ex        # MODIFIED: Add Scheduler to supervision tree
```

### Pattern 1: Event-Driven Scheduler via PubSub Subscription
**What:** The scheduler subscribes to PubSub topics and reacts to events that indicate scheduling opportunities (new task, idle agent, agent connected).
**When to use:** This is the core scheduling pattern for SCHED-01 and SCHED-04.

```elixir
defmodule AgentCom.Scheduler do
  use GenServer
  require Logger

  @stuck_sweep_interval_ms 30_000
  @stuck_threshold_ms 300_000  # 5 minutes

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Subscribe to task events (task_submitted, task_reclaimed, task_retried)
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    # Subscribe to presence events (agent_joined, agent_left)
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")

    # Start stuck assignment sweep
    Process.send_after(self(), :sweep_stuck, @stuck_sweep_interval_ms)

    {:ok, %{}}
  end

  # React to task events that create scheduling opportunities
  @impl true
  def handle_info({:task_event, %{event: event}}, state)
      when event in [:task_submitted, :task_reclaimed, :task_retried] do
    try_schedule_all()
    {:noreply, state}
  end

  # React to agent joining (SCHED-01: agent connects)
  def handle_info({:agent_joined, _info}, state) do
    try_schedule_all()
    {:noreply, state}
  end

  # Ignore other PubSub events
  def handle_info({:task_event, _}, state), do: {:noreply, state}
  def handle_info({:agent_left, _}, state), do: {:noreply, state}
  def handle_info({:status_changed, _}, state), do: {:noreply, state}
end
```

**Key insight:** The scheduler does not need to maintain its own state about agents or tasks. It queries AgentFSM and TaskQueue on every scheduling attempt, ensuring it always works with current data. State lives in the source-of-truth modules (TaskQueue and AgentFSM).

### Pattern 2: Capability Matching with Exact String Match
**What:** Tasks declare `needed_capabilities` (list of strings). Agents declare capabilities on connect (normalized to `[%{name: "cap_name"}]` by AgentFSM). The scheduler matches by checking that every needed capability exists in the agent's capability set.
**When to use:** Every scheduling decision (SCHED-02).

```elixir
defp agent_matches_task?(agent, task) do
  needed = task.needed_capabilities || []

  # Empty needed_capabilities means any agent qualifies
  if needed == [] do
    true
  else
    agent_cap_names = Enum.map(agent.capabilities || [], fn
      %{name: name} -> name
      cap when is_binary(cap) -> cap
      _ -> nil
    end) |> Enum.reject(&is_nil/1)

    # Every needed capability must be present in agent capabilities
    Enum.all?(needed, fn cap -> cap in agent_cap_names end)
  end
end
```

**Note on SCHED-02 "exact string match":** The requirement says "exact string match" for capability matching. This means `"code"` matches `"code"` but not `"Code"` or `"coding"`. The sidecar sends capabilities as strings (e.g., `["search", "code"]`). The task submitter specifies `needed_capabilities` as strings (e.g., `["code"]`). Both sides must agree on the canonical capability names. No fuzzy matching, no substring matching, no wildcard support. This is intentional for v1 simplicity.

### Pattern 3: Greedy Schedule Loop
**What:** When triggered, the scheduler attempts to assign as many tasks as possible in a single pass, not just one.
**When to use:** Every scheduling trigger.

```elixir
defp try_schedule_all do
  case try_schedule_one() do
    :assigned -> try_schedule_all()  # Keep going -- more tasks may match more agents
    :no_match -> :ok                 # No idle agents or no queued tasks
  end
end

defp try_schedule_one do
  # 1. Get all idle agents
  idle_agents = AgentCom.AgentFSM.list_all()
                |> Enum.filter(fn a -> a.fsm_state == :idle end)

  if idle_agents == [] do
    :no_match
  else
    # 2. Get next queued task (highest priority)
    case AgentCom.TaskQueue.dequeue_next() do
      {:error, :empty} ->
        :no_match

      {:ok, task} ->
        # 3. Find first idle agent that matches capabilities
        matching_agent = Enum.find(idle_agents, fn agent ->
          agent_matches_task?(agent, task)
        end)

        case matching_agent do
          nil ->
            :no_match  # No agent has the needed capabilities

          agent ->
            do_assign(task, agent)
            :assigned
        end
    end
  end
end
```

**Why greedy:** A single task_submitted event fires, but there might be 3 idle agents and 3 queued tasks. Scheduling one and waiting for another event wastes time. Loop until no more matches can be made.

### Pattern 4: Task Push via Existing Socket Infrastructure
**What:** After `TaskQueue.assign_task/3`, look up the agent's WebSocket pid in Registry and send `{:push_task, task_data}`. The existing `Socket.handle_info({:push_task, task}, state)` handler pushes the task_assign JSON to the sidecar, which also notifies AgentFSM.
**When to use:** Every successful assignment.

```elixir
defp do_assign(task, agent) do
  # 1. Assign in TaskQueue (updates status, bumps generation)
  case AgentCom.TaskQueue.assign_task(task.id, agent.agent_id) do
    {:ok, assigned_task} ->
      # 2. Push to agent's WebSocket
      task_data = %{
        task_id: assigned_task.id,
        description: assigned_task.description,
        metadata: assigned_task.metadata,
        generation: assigned_task.generation
      }

      case Registry.lookup(AgentCom.AgentRegistry, agent.agent_id) do
        [{pid, _}] ->
          send(pid, {:push_task, task_data})
          Logger.info("Scheduler: assigned task #{task.id} to #{agent.agent_id}")
        [] ->
          Logger.warning("Scheduler: agent #{agent.agent_id} WebSocket not found after assignment")
      end

    {:error, reason} ->
      Logger.warning("Scheduler: failed to assign task #{task.id}: #{inspect(reason)}")
  end
end
```

**Note:** The `Socket.handle_info({:push_task, task}, state)` handler already calls `AgentCom.AgentFSM.assign_task(state.agent_id, task_id)`, so the FSM transition from idle to assigned happens automatically via the existing Socket handler. The scheduler does NOT need to call AgentFSM.assign_task directly.

### Pattern 5: Agent-Becomes-Idle Detection
**What:** When an agent completes or fails a task, AgentFSM transitions to `:idle`. The scheduler needs to detect this to assign the next task (SCHED-01: "agent becomes idle").
**When to use:** Trigger for scheduling after task completion.

The current flow is:
1. Socket receives `task_complete` -> calls `TaskQueue.complete_task` -> broadcasts `:task_completed` on "tasks" topic
2. Socket calls `AgentFSM.task_completed` -> FSM transitions to `:idle`

The `:task_completed` event on the "tasks" topic is the signal. But this event means the TASK completed, not that an AGENT became idle. However, a completed task means the agent that was working on it is now idle, so the scheduler should react to `:task_completed` (and `:task_failed`) as scheduling triggers -- the agent that was working on the completed/failed task is now idle and available.

Alternatively, AgentFSM could broadcast on a new "scheduler" topic when it transitions to `:idle`. But this adds coupling between AgentFSM and the scheduler. The simpler approach: the scheduler reacts to `:task_completed` and `:task_retried` events on the existing "tasks" topic, because after any task completion/failure/retry, there is likely an idle agent available.

```elixir
# React to task completion -- the agent that completed it is now idle
def handle_info({:task_event, %{event: :task_completed}}, state) do
  try_schedule_all()
  {:noreply, state}
end
```

### Pattern 6: Stuck Assignment Sweep (SCHED-03)
**What:** A 30-second timer scans for tasks in `:assigned` status with `updated_at` more than 5 minutes old (no progress reports). These are reclaimed back to the queue.
**When to use:** Safety net for SCHED-03.

```elixir
def handle_info(:sweep_stuck, state) do
  now = System.system_time(:millisecond)
  threshold = now - @stuck_threshold_ms

  # Find assigned tasks with no recent progress
  assigned_tasks = AgentCom.TaskQueue.list(status: :assigned)
  stuck_tasks = Enum.filter(assigned_tasks, fn task ->
    task.updated_at < threshold
  end)

  Enum.each(stuck_tasks, fn task ->
    Logger.warning("Scheduler: reclaiming stuck task #{task.id} from #{task.assigned_to} " <>
      "(no progress for #{div(now - task.updated_at, 1000)}s)")
    AgentCom.TaskQueue.reclaim_task(task.id)
  end)

  Process.send_after(self(), :sweep_stuck, @stuck_sweep_interval_ms)
  {:noreply, state}
end
```

**Relationship to existing overdue sweep:** TaskQueue already has a 30-second overdue sweep that checks `complete_by` deadlines. The stuck assignment sweep in the scheduler checks `updated_at` staleness (no progress for 5 minutes). These are complementary -- overdue is about absolute deadlines, stuck is about activity detection. Both result in task reclamation, which triggers `:task_reclaimed` on PubSub, which triggers the scheduler to try assigning the reclaimed task to another agent.

### Anti-Patterns to Avoid
- **Scheduler maintaining its own agent/task state:** The scheduler should be stateless (or nearly so). TaskQueue and AgentFSM are the sources of truth. Caching agent states in the scheduler creates inconsistency risks.
- **Scheduling on every PubSub event indiscriminately:** Not all task events are scheduling triggers. `:task_assigned` and `:task_dead_letter` should NOT trigger scheduling -- the first means a task was just assigned (no point re-scheduling), the second means the task is dead (no agent should get it).
- **Calling AgentFSM.assign_task from the scheduler:** The Socket.handle_info({:push_task, task}) already calls AgentFSM.assign_task. If the scheduler also calls it, the FSM will get a duplicate assignment notification. The scheduler should only call TaskQueue.assign_task and push to the WebSocket.
- **Blocking the scheduler GenServer on slow operations:** All operations (dequeue_next, assign_task, list_all) are GenServer calls to other processes. These are fast (<1ms) at current scale. But if TaskQueue is busy with a DETS flush, the scheduler could block. This is acceptable at current scale but would need async patterns at 50+ agents.
- **Implementing a fairness algorithm prematurely:** At 4-5 agents, round-robin or weighted fairness adds complexity without benefit. The greedy approach (assign to first matching idle agent) is sufficient. Fairness can be added in v2 if task distribution is visibly skewed.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Event-driven triggering | Custom polling loop with sleep | PubSub subscription + handle_info | PubSub is zero-latency, already used throughout codebase |
| Task priority ordering | Custom sorting in scheduler | TaskQueue.dequeue_next/1 | TaskQueue already maintains a sorted priority index |
| Agent state lookup | Custom ETS/map tracking agent states | AgentFSM.list_all/0 and get_capabilities/1 | AgentFSM is the source of truth for agent state |
| Task assignment | Custom DETS updates in scheduler | TaskQueue.assign_task/3 | TaskQueue handles generation bumping, DETS persistence, PubSub broadcast |
| WebSocket push | Custom WebSocket frame building | Send {:push_task, task} to Socket pid | Socket already has the handler and JSON encoding |
| Task reclamation | Custom reclaim logic | TaskQueue.reclaim_task/1 | Already implemented with idempotency, generation bump, priority re-indexing |

**Key insight:** The scheduler is almost purely orchestration code. It calls existing APIs on existing modules. The only new logic is: (1) capability matching, (2) deciding WHEN to schedule, and (3) the stuck assignment sweep. Everything else is delegation to Phases 1-3 infrastructure.

## Common Pitfalls

### Pitfall 1: Thundering Herd on PubSub Events
**What goes wrong:** A task is submitted, which triggers the scheduler. The scheduler assigns it, which broadcasts `:task_assigned`. If the scheduler reacts to `:task_assigned`, it triggers again unnecessarily, creating a feedback loop of scheduling attempts.
**Why it happens:** The scheduler subscribes to the "tasks" topic, which includes ALL task events.
**How to avoid:** Only react to events that create scheduling opportunities: `:task_submitted`, `:task_reclaimed`, `:task_retried`, `:task_completed`. Explicitly ignore `:task_assigned`, `:task_dead_letter`, and other events. Use a guard clause or pattern match to filter.
**Warning signs:** Excessive "no tasks to schedule" log messages; scheduler CPU usage higher than expected.

### Pitfall 2: Race Between Scheduler and Manual Push-Task
**What goes wrong:** The existing `/api/admin/push-task` endpoint manually assigns a task to a specific agent. If the scheduler also tries to assign a task to the same agent simultaneously, one assignment will fail (agent is no longer idle) and the other succeeds.
**Why it happens:** Two paths can assign tasks: the scheduler (automatic) and the admin endpoint (manual).
**How to avoid:** The admin push-task endpoint bypasses TaskQueue entirely (it creates a task object on the fly and sends it directly to the WebSocket). This is a pre-scheduler testing tool. In Phase 4, consider deprecating or removing the manual push-task endpoint in favor of using the scheduler. If both must coexist, the race is harmless -- `TaskQueue.assign_task` will fail with `{:error, {:invalid_state, :assigned}}` if the task was already assigned, and `AgentFSM.assign_task` will fail with an invalid transition if the agent is no longer idle.
**Warning signs:** Occasional "invalid_state" errors in logs when both manual and automatic assignment are used.

### Pitfall 3: dequeue_next Returns Same Task That Cannot Be Matched
**What goes wrong:** The highest-priority queued task requires a capability that no connected agent has. Every scheduling attempt dequeues this task, fails to match it, and exits the scheduling loop. Lower-priority tasks that COULD be matched never get assigned.
**Why it happens:** `dequeue_next/1` always returns the single highest-priority task. If that task cannot be matched, the scheduler stops trying.
**How to avoid:** When the top task cannot be matched, continue scanning the queue for the next task that CAN be matched. Use `TaskQueue.list(status: :queued)` to get all queued tasks sorted by priority, then iterate through them trying to match each one against available agents. Alternatively, modify `dequeue_next` to accept a capabilities filter. The simpler approach (list all queued, iterate) is sufficient at current scale (<100 queued tasks).
**Warning signs:** Tasks stuck in queued status while idle agents are available; capability mismatch logs.

### Pitfall 4: Scheduler Starts Before TaskQueue or AgentSupervisor
**What goes wrong:** The scheduler is added to the supervision tree before TaskQueue or AgentSupervisor. It tries to subscribe to PubSub or query AgentFSM before those services are ready.
**Why it happens:** Application supervision tree order matters -- children start sequentially.
**How to avoid:** Place the Scheduler after ALL its dependencies in the supervision tree children list. The order should be: PubSub -> Registry -> AgentSupervisor -> TaskQueue -> **Scheduler** -> Bandit.
**Warning signs:** Startup crashes; "no process" errors in scheduler init.

### Pitfall 5: Stuck Sweep and Overdue Sweep Overlapping
**What goes wrong:** Both the scheduler's stuck sweep (5-min no progress) and TaskQueue's overdue sweep (complete_by deadline) try to reclaim the same task simultaneously. One succeeds, the other gets `:not_assigned` error.
**Why it happens:** Two sweep timers with different trigger conditions but same reclaim path.
**How to avoid:** This is actually harmless -- `TaskQueue.reclaim_task/1` is idempotent (returns `:not_assigned` if task is already queued/completed). Both sweeps can safely race. Log at debug level, not warning, to avoid noise.
**Warning signs:** Occasional `:not_assigned` errors from reclaim -- these are expected and safe.

### Pitfall 6: Scheduler Assigns Task to Agent That Just Disconnected
**What goes wrong:** Between querying `AgentFSM.list_all()` (which shows agent as idle) and calling `TaskQueue.assign_task()`, the agent disconnects. The task is assigned to a disconnected agent.
**Why it happens:** Time-of-check-to-time-of-use (TOCTOU) race.
**How to avoid:** This is self-healing. When the agent disconnects, AgentFSM's `:DOWN` handler reclaims the task (via `TaskQueue.reclaim_task`), which broadcasts `:task_reclaimed`, which triggers the scheduler again to assign it to someone else. The TOCTOU window is milliseconds. The reclaim happens within milliseconds of disconnect. No special handling needed.
**Warning signs:** Occasional assign-then-immediate-reclaim sequences in logs -- these are harmless self-healing behavior.

### Pitfall 7: needed_capabilities Field Missing on Existing Tasks
**What goes wrong:** After adding `needed_capabilities` to the task struct, existing tasks in DETS do not have this field. Pattern matching on `task.needed_capabilities` crashes with a KeyError.
**Why it happens:** Elixir maps do not auto-populate new fields. Existing DETS records have the old schema.
**How to avoid:** Always use `Map.get(task, :needed_capabilities, [])` instead of `task.needed_capabilities` when reading the field. The `|| []` fallback handles both nil and missing-key cases. No migration needed -- just defensive reads.
**Warning signs:** KeyError crashes in capability matching; scheduler failing on old tasks.

## Code Examples

Verified patterns from the existing codebase and OTP documentation:

### Scheduler GenServer Skeleton
```elixir
# Source: Codebase conventions (GenServer pattern from task_queue.ex, reaper.ex)
defmodule AgentCom.Scheduler do
  @moduledoc """
  Event-driven task-to-agent scheduler.

  Subscribes to PubSub "tasks" and "presence" topics. When a scheduling
  opportunity arises (new task, idle agent, agent connects), matches queued
  tasks to idle agents by capability and priority.

  The scheduler is stateless -- it queries TaskQueue and AgentFSM for current
  state on every scheduling attempt. This avoids stale data and keeps the
  scheduler simple.

  ## Scheduling triggers (SCHED-01)
  - `:task_submitted` -- new task added to queue
  - `:task_reclaimed` -- stuck/failed task returned to queue
  - `:task_retried` -- dead-letter task requeued
  - `:task_completed` -- agent finished work, now idle
  - `:agent_joined` -- new agent connected with capabilities

  ## Capability matching (SCHED-02)
  - Task `needed_capabilities` matched against agent capabilities
  - Exact string match on capability names
  - Empty needed_capabilities means any agent qualifies

  ## Stuck sweep (SCHED-03)
  - 30-second timer checks for assigned tasks with no progress for 5 minutes
  - Stuck tasks reclaimed to queue, triggering re-scheduling

  ## Event-driven design (SCHED-04)
  - Primary: PubSub events trigger immediate scheduling
  - Fallback: 30-second sweep catches anything PubSub missed
  """

  use GenServer
  require Logger

  @stuck_sweep_interval_ms 30_000
  @stuck_threshold_ms 300_000  # 5 minutes

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")
    Process.send_after(self(), :sweep_stuck, @stuck_sweep_interval_ms)

    Logger.info("Scheduler: started, subscribed to tasks and presence topics")
    {:ok, %{}}
  end
end
```

### Extending Task Struct with needed_capabilities
```elixir
# Source: Existing task_queue.ex submit pattern (lines 195-229)
# In handle_call({:submit, params}, ...) -- add needed_capabilities extraction:
needed_capabilities = Map.get(params, :needed_capabilities,
                       Map.get(params, "needed_capabilities", []))

task = %{
  # ... existing fields ...
  needed_capabilities: needed_capabilities,
  # ... rest of fields ...
}

# In endpoint.ex POST /api/tasks -- add to task_params:
needed_capabilities: params["needed_capabilities"] || [],
```

### Capability Matching Function
```elixir
# Source: SCHED-02 requirement + existing AgentFSM capability normalization pattern
defp agent_matches_task?(agent, task) do
  needed = Map.get(task, :needed_capabilities, [])

  if needed == [] do
    true
  else
    agent_cap_names =
      (agent.capabilities || [])
      |> Enum.map(fn
        %{name: name} -> name
        cap when is_binary(cap) -> cap
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    Enum.all?(needed, fn cap -> cap in agent_cap_names end)
  end
end
```

### Application Supervision Tree Placement
```elixir
# Source: Existing application.ex children list
# Scheduler MUST come after TaskQueue and AgentSupervisor:
children = [
  {Phoenix.PubSub, name: AgentCom.PubSub},
  {Registry, keys: :unique, name: AgentCom.AgentRegistry},
  {AgentCom.Config, []},
  {AgentCom.Auth, []},
  {AgentCom.Mailbox, []},
  {AgentCom.Channels, []},
  {AgentCom.Presence, []},
  {AgentCom.Analytics, []},
  {AgentCom.Threads, []},
  {AgentCom.MessageHistory, []},
  {AgentCom.Reaper, []},
  {Registry, keys: :unique, name: AgentCom.AgentFSMRegistry},
  {AgentCom.AgentSupervisor, []},
  {AgentCom.TaskQueue, []},
  {AgentCom.Scheduler, []},     # <-- NEW: after TaskQueue, before Bandit
  {Bandit, plug: AgentCom.Endpoint, scheme: :http, port: port()}
]
```

### Schedule Loop with Queue Iteration (Pitfall 3 Solution)
```elixir
# Source: Pattern addressing Pitfall 3 (unmatched top task blocking queue)
defp try_schedule_all do
  idle_agents = get_idle_agents()
  if idle_agents == [] do
    :ok
  else
    queued_tasks = AgentCom.TaskQueue.list(status: :queued)
    do_match_loop(queued_tasks, idle_agents)
  end
end

defp do_match_loop([], _agents), do: :ok
defp do_match_loop(_tasks, []), do: :ok
defp do_match_loop([task | rest_tasks], agents) do
  case Enum.find(agents, fn agent -> agent_matches_task?(agent, task) end) do
    nil ->
      # This task has no matching agent -- skip and try next task
      do_match_loop(rest_tasks, agents)

    agent ->
      do_assign(task, agent)
      # Remove this agent from available list and continue
      remaining_agents = Enum.reject(agents, fn a -> a.agent_id == agent.agent_id end)
      do_match_loop(rest_tasks, remaining_agents)
  end
end

defp get_idle_agents do
  AgentCom.AgentFSM.list_all()
  |> Enum.filter(fn a -> a.fsm_state == :idle end)
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual task push via /api/admin/push-task | Automated scheduler via PubSub events | Phase 4 (this phase) | Tasks assigned automatically within seconds of submission; no human intervention needed |
| No capability routing | Exact string match on needed_capabilities vs agent capabilities | Phase 4 (this phase) | Tasks routed to agents that can actually do the work |
| No stuck detection (only overdue sweep on complete_by) | 30-second sweep detecting 5-minute progress staleness | Phase 4 (this phase) | Stuck tasks reclaimed faster; does not require complete_by deadline to be set |
| Agent must be manually given work | Agent receives work automatically on connect or idle | Phase 4 (this phase) | Agents are utilized immediately; no idle waste |

**Deprecated/outdated after Phase 4:**
- `/api/admin/push-task` endpoint becomes a legacy tool. The scheduler handles all automatic assignment. The manual endpoint could remain for debugging/testing but should not be the primary assignment path.

## Integration Points

### With TaskQueue (Phase 2) -- Primary Integration
**APIs used by scheduler:**
- `TaskQueue.dequeue_next/1` -- peek at highest priority queued task
- `TaskQueue.list(status: :queued)` -- get all queued tasks for capability-aware matching (Pitfall 3)
- `TaskQueue.assign_task/3` -- assign task to agent (bumps generation, persists, broadcasts)
- `TaskQueue.reclaim_task/1` -- reclaim stuck tasks in sweep
- `TaskQueue.list(status: :assigned)` -- find assigned tasks for stuck sweep

**Events consumed from TaskQueue PubSub:**
- `:task_submitted` -- new task created, try to schedule
- `:task_reclaimed` -- task returned to queue, try to schedule
- `:task_retried` -- dead-letter task requeued, try to schedule
- `:task_completed` -- agent finished, now idle, try to schedule

**Modification needed:**
- Add `needed_capabilities` field to task struct in `submit` handler
- Add `needed_capabilities` to `format_task` in endpoint.ex
- Add `needed_capabilities` to POST /api/tasks params extraction

### With AgentFSM (Phase 3) -- Primary Integration
**APIs used by scheduler:**
- `AgentFSM.list_all/0` -- enumerate all connected agents with state
- (AgentFSM.assign_task is NOT called by scheduler -- Socket.handle_info(:push_task) calls it)

**Events consumed from Presence PubSub:**
- `:agent_joined` -- new agent connected, try to schedule

**No modifications needed to AgentFSM.**

### With Socket (Phase 1) -- Push Delivery
**APIs used by scheduler:**
- `Registry.lookup(AgentCom.AgentRegistry, agent_id)` -- find WebSocket pid
- `send(pid, {:push_task, task_data})` -- push assignment via existing handler

**No modifications needed to Socket.** The existing `handle_info({:push_task, task}, state)` handler handles everything including AgentFSM notification.

### With Endpoint (Phase 1/2) -- Task Submission
**Modification needed:**
- POST /api/tasks must accept `needed_capabilities` parameter
- format_task must include `needed_capabilities` in response

## Open Questions

1. **Should the scheduler handle the "agent becomes idle" event via PubSub or rely on task_completed?**
   - What we know: AgentFSM transitions to :idle after task_completed/task_failed. The "tasks" topic broadcasts :task_completed. There is no explicit "agent became idle" PubSub event.
   - What's unclear: Whether to add an "agent_idle" event to AgentFSM, or just react to task_completed on the tasks topic.
   - Recommendation: React to `:task_completed` on the "tasks" topic. This is already broadcast and semantically equivalent to "an agent just became idle." Adding a new PubSub topic/event creates coupling and redundancy. The scheduler can also pick up idle agents on the 30s sweep as a safety net.

2. **Should dequeue_next support capability filtering natively?**
   - What we know: `dequeue_next/1` returns the single highest-priority task. If that task has capabilities no agent can match, it blocks the queue (Pitfall 3).
   - What's unclear: Whether to modify TaskQueue or handle in scheduler.
   - Recommendation: Handle in the scheduler by using `TaskQueue.list(status: :queued)` and iterating. Modifying TaskQueue to accept a capabilities filter adds complexity to a module that should not know about agent capabilities. The scheduler is the right place for matching logic. At <100 queued tasks, iterating the full list is trivial.

3. **Should the needed_capabilities field be top-level or inside metadata?**
   - What we know: Tasks have a freeform `metadata` map. The scheduler needs a standardized capability field.
   - What's unclear: Whether to put it at top level (like `priority`, `description`) or nest inside metadata.
   - Recommendation: Top-level field on the task struct, same as `priority`, `description`, `max_retries`. This makes it a first-class scheduling concept visible in the API. Metadata is for user-defined data; needed_capabilities is system-defined routing data.

## Sources

### Primary (HIGH confidence)
- AgentCom codebase -- direct examination of task_queue.ex (709 lines), agent_fsm.ex (516 lines), socket.ex (453 lines), presence.ex (113 lines), endpoint.ex (746 lines), application.ex (37 lines), reaper.ex (63 lines)
- Phase 2 VERIFICATION.md -- confirmed TaskQueue APIs: dequeue_next, assign_task, reclaim_task, list, PubSub broadcasts on "tasks" topic
- Phase 3 VERIFICATION.md -- confirmed AgentFSM APIs: list_all, get_capabilities, assign_task, Presence.update_fsm_state
- Phase 3 RESEARCH.md -- DynamicSupervisor patterns, capability normalization, Process.monitor disconnect detection
- ROADMAP.md -- Phase 4 requirements (SCHED-01 through SCHED-04), success criteria, dependency chain
- REQUIREMENTS.md -- SCHED-01 through SCHED-04 detailed specifications

### Secondary (MEDIUM confidence)
- OTP GenServer documentation -- PubSub subscription in init, handle_info for PubSub messages, Process.send_after for periodic tasks
- Phoenix.PubSub documentation -- subscribe/broadcast semantics, topic-based filtering

### Tertiary (LOW confidence)
- None -- all findings verified against codebase and official documentation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- zero new dependencies; GenServer + PubSub + Process.send_after are all established codebase patterns
- Architecture: HIGH -- scheduler is pure orchestration calling existing APIs; all integration points verified by reading actual source code
- Pitfalls: HIGH -- race conditions (TOCTOU, thundering herd, duplicate reclaim) are well-understood OTP patterns; self-healing via PubSub event chains
- Integration points: HIGH -- every API call site verified against actual function signatures and return types in source code

**Research date:** 2026-02-10
**Valid until:** 2026-03-10 (30 days -- stable domain, pure OTP patterns, no external dependencies)
