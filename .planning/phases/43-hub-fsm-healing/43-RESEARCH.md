# Phase 43: Hub FSM Healing - Research

**Researched:** 2026-02-14
**Domain:** Elixir GenServer FSM state extension, health aggregation, automated remediation
**Confidence:** HIGH

## Summary

Phase 43 adds a 5th state `:healing` to the existing 4-state Hub FSM (`hub_fsm.ex`). The codebase already has all the health signal sources needed: `Alerter` (7 alert rules including stuck_tasks and tier_down), `MetricsCollector` (queue depth, agent utilization, error rates), `LlmRegistry` (endpoint health), and `AgentFSM` (agent states). The healing state follows the exact same async `Task.start` pattern used by `:improving` and `:contemplating` states, making this a well-understood extension rather than a new pattern.

The main work is: (1) a `HealthAggregator` module that unifies existing health signals into a structured report, (2) a `Healing` module with prioritized remediation actions, (3) FSM state/transition additions with a dedicated 5-minute watchdog, and (4) cooldown + attempt-limiting to prevent healing storms.

**Primary recommendation:** Follow the established async cycle pattern (Task.start -> send message -> transition to :resting) and lean heavily on existing APIs (Alerter.active_alerts, TaskQueue.reclaim_task, LlmRegistry.list_endpoints) rather than building new health-checking infrastructure.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Add `:healing` to `@valid_transitions`: any state -> `:healing`, `:healing` -> `:resting`
- Healing preempts other states -- if infrastructure is broken, executing goals is pointless
- Always exits to `:resting` (not directly to executing) for clean health re-evaluation
- Same async Task pattern as improving/contemplating -- proven pattern from v1.3
- Delegate merge conflict fixing to OpenClaw agent -- not auto-fix. Hub detects, creates task, agent fixes
- 5-minute watchdog + 5-minute cooldown + 3-attempt limit -- triple safety net against healing storms
- Healing NEVER heals itself recursively -- if healing crashes, OTP supervisor restarts the FSM

### Claude's Discretion
- HealthAggregator internal structure and polling strategy
- Remediation action ordering within priority tiers
- Specific exponential backoff parameters for Ollama recovery
- Healing history storage format (ETS vs DETS)
- Dashboard visualization of healing state

### Deferred Ideas (OUT OF SCOPE)
- Healing self-healing (recursive) -- infinite recursion risk
- Healing playbook system (AGENT-V2-02) -- deferred to v2
- Distributed healing consensus -- one hub, one decision-maker
</user_constraints>

## Standard Stack

### Core (Already in Project)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GenServer (OTP) | Elixir 1.14+ | FSM state machine | Already used by HubFSM, proven pattern |
| Task.start | OTP | Async healing cycle | Same pattern as improving/contemplating |
| Process.send_after | OTP | Watchdog timer, cooldown timer | Already used for tick and watchdog in HubFSM |
| ETS | OTP | Healing history storage | Matches History module pattern, fast reads |
| Phoenix.PubSub | 2.x | Broadcast healing events | Already used for hub_fsm, alerts, metrics |
| :telemetry | 1.x | Healing telemetry events | Already used throughout codebase |

### Existing Modules to Consume (Not Create)
| Module | API | What Healing Uses It For |
|--------|-----|--------------------------|
| `AgentCom.Alerter` | `active_alerts/0` | Stuck tasks, no agents online, tier down alerts |
| `AgentCom.MetricsCollector` | `snapshot/0` | Queue depth, error rates, agent utilization |
| `AgentCom.LlmRegistry` | `list_endpoints/0` | Endpoint health status |
| `AgentCom.AgentFSM` | `list_all/0` | Agent states (offline detection) |
| `AgentCom.TaskQueue` | `list/1`, `reclaim_task/1` | Stuck task identification and requeue |
| `AgentCom.GoalBacklog` | `submit/1` | Create remediation goals/tasks |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| ETS for healing history | DETS | ETS is simpler, faster, matches History pattern; healing history is transient |
| Polling health in HealthAggregator | PubSub subscription | Polling is simpler and avoids race conditions; health check is infrequent |
| Custom health check logic | Reuse Alerter rules directly | Alerter already detects stuck_tasks and tier_down -- aggregate its output |

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  hub_fsm.ex                    # Modified: add :healing state + transitions
  hub_fsm/
    predicates.ex               # Modified: add should_heal? evaluation
    history.ex                  # Unchanged (already records any transitions)
    healing.ex                  # NEW: remediation actions
  health_aggregator.ex          # NEW: unified health signal module
```

### Pattern 1: Async Healing Cycle (matches improving/contemplating)
**What:** Spawn a Task when entering :healing, send completion message back to FSM
**When to use:** Always -- this is the locked decision from CONTEXT.md
**Example (from existing codebase):**
```elixir
# In do_transition/3 when new_state == :healing
if new_state == :healing do
  pid = self()
  Task.start(fn ->
    result = AgentCom.HubFSM.Healing.run_healing_cycle()
    send(pid, {:healing_cycle_complete, result})
  end)
end
```

### Pattern 2: Health Aggregation (gather-and-classify)
**What:** Poll all existing health sources, classify into structured report with severity
**When to use:** On every tick evaluation and at healing cycle start
**Example:**
```elixir
defmodule AgentCom.HealthAggregator do
  def assess() do
    alerts = safe_call(fn -> AgentCom.Alerter.active_alerts() end, [])
    metrics = safe_call(fn -> AgentCom.MetricsCollector.snapshot() end, %{})
    endpoints = safe_call(fn -> AgentCom.LlmRegistry.list_endpoints() end, [])
    agents = safe_call(fn -> AgentCom.AgentFSM.list_all() end, [])

    issues = classify_issues(alerts, metrics, endpoints, agents)
    %{healthy: issues == [], issues: issues, timestamp: now()}
  end
end
```

### Pattern 3: Remediation with Priority Order
**What:** Execute remediation actions in priority order, log each action and outcome
**When to use:** Inside the healing cycle Task
**Example:**
```elixir
def run_healing_cycle() do
  health = HealthAggregator.assess()
  actions = plan_remediation(health.issues)

  results = Enum.map(actions, fn action ->
    result = execute_action(action)
    log_action(action, result)
    result
  end)

  %{actions_taken: length(results), issues_found: length(health.issues)}
end
```

### Pattern 4: Watchdog with Dedicated Timer
**What:** 5-minute timer specific to healing state (separate from 2-hour global watchdog)
**When to use:** On entry to :healing state
**Example:**
```elixir
# In do_transition when entering :healing
healing_watchdog_ref = Process.send_after(self(), :healing_watchdog, 300_000)

# In handle_info
def handle_info(:healing_watchdog, %{fsm_state: :healing} = state) do
  Logger.critical("healing_watchdog_timeout")
  updated = do_transition(state, :resting, "healing watchdog: 5-minute timeout")
  {:noreply, updated}
end
```

### Anti-Patterns to Avoid
- **Healing that heals itself:** If healing crashes, let OTP supervisor handle it. Never re-enter :healing from :healing.
- **Blocking the FSM process:** Always use Task.start for remediation work. The FSM GenServer must remain responsive.
- **Direct state jumps from healing:** Always exit to :resting first, let normal tick evaluation re-assess.
- **Custom health polling:** Don't duplicate what Alerter and MetricsCollector already track. Aggregate their output.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Stuck task detection | Custom task scanner | `Alerter.active_alerts()` filtering for `:stuck_tasks` | Alerter already checks this every 30s with configurable threshold |
| Endpoint health monitoring | Custom HTTP health checker | `LlmRegistry.list_endpoints()` status field | Registry already tracks healthy/unhealthy per endpoint |
| Agent offline detection | Custom heartbeat system | `AgentFSM.list_all()` with state filter | AgentFSM already tracks :offline state |
| Task requeue | Custom DETS manipulation | `TaskQueue.reclaim_task/1` | Existing API handles generation bumping and state transitions |
| Alert lifecycle | Custom alert tracking | `Alerter.active_alerts/0` and `Alerter.acknowledge/1` | Full lifecycle already implemented |

**Key insight:** The entire health monitoring infrastructure exists from v1.1-v1.2. Healing is the *remediation* layer on top, not a replacement for detection.

## Common Pitfalls

### Pitfall 1: Healing Storm (Oscillation)
**What goes wrong:** Healing detects issues, takes action, action doesn't fully resolve, healing re-triggers immediately in a tight loop
**Why it happens:** No cooldown between healing cycles, or cooldown too short
**How to avoid:** Triple safety net: 5-minute post-healing cooldown, 3-attempt limit within 10 minutes, healing always exits to :resting for full re-evaluation
**Warning signs:** Multiple healing transitions in history within minutes

### Pitfall 2: Blocking the FSM GenServer
**What goes wrong:** Remediation actions (especially Ollama health checks or mix compile) take too long and block the FSM tick
**Why it happens:** Running remediation inline instead of in an async Task
**How to avoid:** All remediation runs in Task.start, never in the GenServer process. The 5-minute watchdog catches any stuck healing tasks.
**Warning signs:** FSM stops responding to pause/resume/get_state calls

### Pitfall 3: Race Between Healing and Normal Tick
**What goes wrong:** Tick evaluation triggers transition while healing cycle is still running
**Why it happens:** Predicates don't account for :healing state
**How to avoid:** Predicates.evaluate(:healing, _) always returns :stay. Only the healing cycle completion message or watchdog can exit :healing.
**Warning signs:** Unexpected transitions from :healing to states other than :resting

### Pitfall 4: Cascading Failures in Remediation
**What goes wrong:** Healing tries to requeue tasks, but TaskQueue is also broken. Healing tries to check endpoints, but LlmRegistry is down.
**Why it happens:** Remediation calls GenServers that may themselves be unhealthy
**How to avoid:** Wrap every remediation action in try/catch. Log failures but continue to next action. Never let one action failure abort the entire cycle.
**Warning signs:** Healing cycle crashes repeatedly (visible in OTP supervisor restart logs)

### Pitfall 5: Stale Cooldown State on FSM Restart
**What goes wrong:** FSM restarts (OTP supervisor), loses in-memory cooldown state, healing re-triggers immediately
**Why it happens:** Cooldown tracked in GenServer state which is lost on restart
**How to avoid:** Accept this as acceptable behavior -- if FSM crashed and restarted, re-evaluating health is appropriate. The 3-attempt limit within the new process lifetime provides sufficient protection.
**Warning signs:** Not really a problem if accepted by design

## Code Examples

### Existing: Async Cycle Pattern (from hub_fsm.ex)
```elixir
# Lines 563-570 of hub_fsm.ex -- improving cycle spawn
if new_state == :improving do
  pid = self()
  Task.start(fn ->
    result = AgentCom.SelfImprovement.run_improvement_cycle()
    send(pid, {:improvement_cycle_complete, result})
  end)
end
```

### Existing: Alerter stuck_tasks Detection (from alerter.ex)
```elixir
# Lines 385-417 of alerter.ex -- evaluate_stuck_tasks
defp evaluate_stuck_tasks(thresholds) do
  assigned_tasks = AgentCom.TaskQueue.list(status: :assigned)
  stuck_tasks = Enum.filter(assigned_tasks, fn task ->
    updated_at = task.updated_at || task.assigned_at || 0
    now - updated_at > threshold_ms
  end)
  # Returns {:triggered, :critical, message, %{task_ids: ...}}
end
```

### Existing: Task Reclaim (from task_queue.ex)
```elixir
# TaskQueue.reclaim_task/1 -- requeues an assigned task
AgentCom.TaskQueue.reclaim_task(task_id)
```

### Existing: Valid Transitions Map (from hub_fsm.ex)
```elixir
# Current @valid_transitions -- needs :healing added
@valid_transitions %{
  resting: [:executing, :improving],
  executing: [:resting],
  improving: [:resting, :executing, :contemplating],
  contemplating: [:resting, :executing]
}
```

### New: HealthAggregator.assess/0 (Recommended Pattern)
```elixir
def assess() do
  now = System.system_time(:millisecond)
  alerts = safe_active_alerts()
  metrics = safe_metrics_snapshot()
  endpoints = safe_list_endpoints()
  agents = safe_list_agents()
  assigned_tasks = safe_list_assigned_tasks()

  issues = []
    |> maybe_add_stuck_tasks(alerts, assigned_tasks)
    |> maybe_add_offline_agents(agents, assigned_tasks)
    |> maybe_add_unhealthy_endpoints(endpoints)
    |> maybe_add_compilation_issues()
    |> Enum.sort_by(& &1.priority)

  %{
    healthy: issues == [],
    issues: issues,
    healing_needed: length(issues) > 0,
    timestamp: now
  }
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| 4-state FSM (resting/executing/improving/contemplating) | 5-state FSM (+ :healing) | Phase 43 | Autonomous infrastructure remediation |
| Manual stuck task recovery | Automated requeue via healing state | Phase 43 | No human intervention for common failures |
| Endpoint failures require restart | Automatic recovery with backoff | Phase 43 | Self-healing Ollama connectivity |
| CI failures discovered manually | Hub detects and delegates fixing | Phase 43 | Faster CI recovery |

## Open Questions

1. **Healing history retention policy**
   - What we know: ETS loses data on restart; DETS persists
   - What's unclear: Whether healing history needs to survive restarts
   - Recommendation: Use ETS like HubFSM.History -- healing history is operational, not archival. If persistence is needed later, it's a simple swap.

2. **Ollama restart command configuration**
   - What we know: HEAL-05 mentions "execute configured restart commands"
   - What's unclear: Where the restart command is configured, whether it exists
   - Recommendation: Make it configurable via `AgentCom.Config` with a nil default (skip restart attempt if not configured). Don't assume systemd/pm2 availability.

3. **Dashboard healing visualization**
   - What we know: Dashboard needs to show :healing state
   - What's unclear: How much detail to show (just state, or full action log?)
   - Recommendation: Phase 43 adds the state to existing FSM visualization. Detailed healing history panel can be added in Phase 44 testing phase or later.

## Sources

### Primary (HIGH confidence)
- `lib/agent_com/hub_fsm.ex` -- Existing 4-state FSM with tick, watchdog, async cycle patterns
- `lib/agent_com/hub_fsm/predicates.ex` -- Pure transition predicate functions
- `lib/agent_com/hub_fsm/history.ex` -- ETS-backed transition history
- `lib/agent_com/alerter.ex` -- 7 alert rules including stuck_tasks, no_agents_online, tier_down
- `lib/agent_com/metrics_collector.ex` -- ETS-backed metrics with snapshot API
- `lib/agent_com/task_queue.ex` -- Task lifecycle with reclaim_task/1, list/1, fail_task/3
- `lib/agent_com/llm_registry.ex` -- Endpoint registration and health tracking
- `lib/agent_com/agent_fsm.ex` -- Per-agent state machine with list_all/0

### Secondary (MEDIUM confidence)
- `.planning/phases/43-hub-fsm-healing/43-CONTEXT.md` -- Phase discussion decisions and approach

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries already in use, no new dependencies
- Architecture: HIGH -- follows exact patterns from existing improving/contemplating states
- Pitfalls: HIGH -- identified from direct codebase analysis, not speculation

**Research date:** 2026-02-14
**Valid until:** 2026-03-14 (stable codebase, internal project)
