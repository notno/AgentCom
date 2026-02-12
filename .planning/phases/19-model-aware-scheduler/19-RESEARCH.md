# Phase 19: Model-Aware Scheduler - Research

**Researched:** 2026-02-12
**Domain:** Task routing by complexity tier + endpoint load balancing (Elixir/OTP GenServer)
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Routing rules
- Flexible fallback: tasks can move across tiers based on availability
- One-step max fallback: tasks can only move one tier up or down (trivial<->standard<->complex), never skip a tier
- Brief wait then fallback: wait a short timeout for the preferred tier before falling back to the next tier
- Trust complexity classification: if Phase 17 marks a task as trivial, send it to sidecar without verifying sidecar capabilities

#### Load balancing
- Weighted by capacity: hosts with more resources get more tasks, considering both current load and total capacity
- Soft repo affinity: prefer same host for same-repo tasks when load is similar, to benefit from filesystem caches and context
- Single Claude API key: one key shared across all agents for complex tasks, no key rotation needed

#### Routing transparency
- Expandable detail on dashboard: summary (final endpoint + tier) by default, click to expand full routing trace
- Visual indicator for fallback tasks: badge or icon on tasks that didn't run on their preferred tier
- Every routing decision logged with: model selected, endpoint chosen, classification reason

#### Degraded behavior
- Standard tier down: escalate standard tasks to Claude API (consistent with one-step fallback)
- All tiers down: queue non-trivial tasks with TTL, expire stale tasks rather than building unbounded backlog; trivial tasks still execute locally
- Alert after threshold: only alert when a tier stays down beyond a configurable duration, not on brief blips

### Claude's Discretion
- Warm vs cold model preference weighting in load balancer
- Telemetry approach for routing decisions (full per-task events vs aggregates) -- follow existing Phase 14 patterns
- Cost estimation in routing logs -- include if data available from execution layer
- Gradual vs immediate backlog drain on tier recovery -- follow existing queue patterns
- Specific timeout values for fallback wait and task TTL

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

## Summary

Phase 19 augments the existing `AgentCom.Scheduler` (Phase 4) with tier-aware routing. Currently, the scheduler is a stateless GenServer that pairs queued tasks with idle agents based on capability matching. Phase 19 replaces this simple matching with a three-tier routing decision: **trivial** tasks go to sidecar direct execution, **standard** tasks go to Ollama-backed agents (selected by load from `LlmRegistry`), and **complex** tasks go to Claude-backed agents. The scheduler must also implement one-step fallback with configurable timeout, weighted load balancing across Ollama endpoints, and structured routing decision logging.

The implementation builds on two completed dependencies: Phase 17's `AgentCom.Complexity` module (which enriches every task with `effective_tier`, `explicit_tier`, and `inferred` signals) and Phase 18's `AgentCom.LlmRegistry` (which tracks endpoint health, loaded models, and per-host resource metrics via ETS). The routing layer sits between these data sources and the existing task assignment mechanism (`TaskQueue.assign_task/3`), making the routing decision *before* calling the existing assignment path.

The key architectural challenge is keeping the scheduler stateless (or near-stateless) while supporting fallback timeouts. The recommended approach is a lightweight routing state map keyed by task_id that tracks pending fallback timers, with entries cleaned up on assignment or expiry. This preserves the current design philosophy where the scheduler queries live data on every attempt.

**Primary recommendation:** Create a new `AgentCom.TaskRouter` module that encapsulates the tier->endpoint routing decision, keeping the existing `Scheduler` as the event-driven orchestrator that calls the router. This separation of concerns keeps the scheduler simple and makes the routing logic independently testable.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GenServer (OTP) | OTP 26+ | Scheduler process, timer management | Already used throughout codebase |
| ETS | OTP 26+ | Read resource metrics from `LlmRegistry` | Already pattern in codebase -- zero-cost reads |
| Phoenix.PubSub | ~> 2.1 | Event-driven scheduling triggers | Already subscribed by current Scheduler |
| :telemetry | OTP 26+ | Routing decision telemetry events | Existing pattern in Telemetry module |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Process.send_after/3 | OTP | Fallback timeout timers | When preferred tier is unavailable; brief wait before fallback |
| :dets (via TaskQueue) | OTP | Persist routing metadata on task | Store routing_decision on the task map |
| Jason | ~> 1.4 | Serialize routing decisions for logging | Already a dependency |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| GenServer timers | :timer module | GenServer timers (Process.send_after) are simpler and already used throughout the codebase |
| Separate Router GenServer | Inline in Scheduler | Separate module is more testable; slight indirection cost is worth it |
| ETS for routing state | GenServer state map | GenServer state is simpler for small cardinality (active routing decisions); ETS would be overkill |

## Architecture Patterns

### Recommended Module Structure

```
lib/agent_com/
├── scheduler.ex           # Existing -- augment with tier routing calls
├── task_router.ex         # NEW -- tier routing decision engine
├── task_router/
│   ├── tier_resolver.ex   # NEW -- resolve tier to endpoint(s)
│   └── load_scorer.ex     # NEW -- weighted scoring for endpoint selection
├── complexity.ex          # Existing Phase 17 -- no changes
├── llm_registry.ex        # Existing Phase 18 -- no changes
└── task_queue.ex          # Existing -- add routing_decision to task map
```

### Pattern 1: Routing Decision as Data

**What:** Every routing decision is captured as a structured map that travels with the task.
**When to use:** Always -- for every task that passes through the scheduler.

```elixir
# Routing decision structure
%{
  task_id: "task-abc123",
  effective_tier: :standard,
  preferred_endpoint: "192.168.1.10:11434",
  selected_endpoint: "192.168.1.10:11434",   # may differ if fallback
  selected_model: "qwen2.5-coder:7b",
  fallback_used: false,
  fallback_reason: nil,
  scoring: %{
    candidates: [
      %{endpoint_id: "192.168.1.10:11434", score: 0.85, load: 0.3, has_model: true},
      %{endpoint_id: "192.168.1.20:11434", score: 0.72, load: 0.5, has_model: true}
    ],
    repo_affinity_applied: true,
    warm_model_bonus: true
  },
  decided_at: 1707753600000,
  classification_reason: "inferred:standard (confidence 0.67, word_count=25, files=2)"
}
```

### Pattern 2: Stateless Routing with Timer-Based Fallback

**What:** The scheduler remains primarily stateless. When a preferred tier is unavailable, it sets a `Process.send_after/3` timer for fallback and stores a minimal `{task_id, original_tier, fallback_tier}` entry in GenServer state.
**When to use:** When the preferred tier has no healthy endpoints.

```elixir
# In Scheduler GenServer state (minimal addition)
%{
  pending_fallbacks: %{
    "task-abc123" => %{
      original_tier: :standard,
      fallback_tier: :complex,
      timer_ref: ref,
      queued_at: timestamp
    }
  }
}
```

When the timer fires, the scheduler attempts assignment at the fallback tier. If the original tier becomes available before the timer fires (e.g., an Ollama endpoint recovers), the pending fallback is cancelled and the task routes normally.

### Pattern 3: Weighted Endpoint Scoring

**What:** Score each candidate endpoint based on: (1) inverse current load, (2) total capacity, (3) model availability, (4) repo affinity bonus.
**When to use:** When selecting among multiple Ollama endpoints for standard-tier tasks.

```elixir
defp score_endpoint(endpoint, resources, task, opts) do
  base_score = 1.0

  # Load factor: prefer less loaded hosts (0.0 to 1.0 range)
  cpu_load = (resources.cpu_percent || 50.0) / 100.0
  load_factor = 1.0 - cpu_load

  # Capacity factor: normalize by total resources
  ram_total = resources.ram_total_bytes || 1
  capacity_factor = min(ram_total / @reference_capacity, 1.5)  # cap bonus at 1.5x

  # VRAM factor: prefer hosts with available VRAM
  vram_factor = if resources.vram_used_bytes && resources.vram_total_bytes do
    vram_free_pct = 1.0 - (resources.vram_used_bytes / resources.vram_total_bytes)
    0.8 + 0.2 * vram_free_pct  # range 0.8 to 1.0
  else
    0.9  # neutral if no VRAM data
  end

  # Warm model bonus (discretion area)
  warm_bonus = if model_loaded?(endpoint, task) do
    1.15  # 15% bonus for warm model
  else
    1.0
  end

  # Repo affinity (soft preference)
  affinity_bonus = if repo_affinity?(endpoint, task, opts) do
    1.05  # 5% bonus when load is similar
  else
    1.0
  end

  base_score * load_factor * capacity_factor * vram_factor * warm_bonus * affinity_bonus
end
```

### Pattern 4: Tier Resolution Chain

**What:** Resolve complexity tier to execution target type, with one-step fallback chain.
**When to use:** On every routing decision.

```elixir
# Tier -> execution target mapping
@tier_targets %{
  trivial: :sidecar,
  standard: :ollama,
  complex: :claude,
  unknown: :standard  # conservative: treat unknown as standard
}

# Fallback chains (one-step only)
@fallback_up %{
  trivial: :standard,
  standard: :complex
}

@fallback_down %{
  standard: :trivial,
  complex: :standard
}
```

### Anti-Patterns to Avoid

- **Caching endpoint state in the scheduler:** The current scheduler is stateless by design. The LlmRegistry already provides live data via ETS reads. Don't cache endpoint health or models in the scheduler -- always read fresh from LlmRegistry.
- **Blocking on fallback timeout:** Don't block the scheduler GenServer waiting for a timeout. Use `Process.send_after/3` and handle the fallback asynchronously. The scheduler must remain responsive to new events.
- **Re-implementing health checks:** The LlmRegistry already does health checking with configurable thresholds. The router should trust the `:healthy`/`:unhealthy`/`:unknown` status from the registry.
- **Tight coupling between router and scheduler:** Keep the `TaskRouter` module as a pure-function module (no GenServer state) that takes inputs and returns routing decisions. Only the `Scheduler` GenServer manages timers and state.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Endpoint health tracking | Custom health checker | `LlmRegistry.list_endpoints()` status field | Phase 18 already tracks health with configurable thresholds |
| Resource metrics | Custom resource poller | `LlmRegistry.get_resources/1` via ETS | Phase 18 sidecars already report metrics every 30s |
| Complexity classification | Custom classifier | `task.complexity.effective_tier` | Phase 17 already classifies every task |
| Task persistence | Custom storage | `TaskQueue.assign_task/3` with routing metadata | TaskQueue already handles DETS persistence, generation fencing |
| Telemetry infrastructure | Custom logging | `:telemetry.execute/3` with existing patterns | Phase 14 established telemetry patterns used throughout |
| Timer management | Custom timer library | `Process.send_after/3` + `Process.cancel_timer/1` | Standard OTP pattern, already used in AgentFSM acceptance timeout |

**Key insight:** Phase 19 is a *routing decision layer*, not an execution layer. It should consume data from Phases 17-18 and make decisions, then delegate to existing assignment mechanisms. The less new infrastructure it introduces, the better.

## Common Pitfalls

### Pitfall 1: Scheduler Bottleneck from Synchronous Endpoint Queries
**What goes wrong:** Making synchronous GenServer calls to LlmRegistry for every routing decision blocks the scheduler, creating a bottleneck when many tasks arrive simultaneously.
**Why it happens:** LlmRegistry.list_endpoints() is a GenServer call. Under load, the scheduler could queue up waiting for LlmRegistry responses.
**How to avoid:** Use `LlmRegistry.get_resources/1` which reads directly from ETS (Phase 18 decision: bypass GenServer for ETS direct read/write). For endpoint listing, the scheduler could use a periodic snapshot or subscribe to `llm_registry` PubSub updates. Better: `LlmRegistry.list_endpoints()` is already fast since it reads from DETS, but consider adding an ETS-cached endpoint list if performance testing shows issues.
**Warning signs:** Scheduler event processing latency increases; `try_schedule_all` takes >10ms.

### Pitfall 2: Fallback Timer Leak
**What goes wrong:** Fallback timers accumulate in scheduler state if tasks are completed, cancelled, or reclaimed before the timer fires.
**Why it happens:** Timer cleanup is forgotten on non-obvious paths (task dead-lettered, task reclaimed by stuck sweep, agent disconnected).
**How to avoid:** Clean up pending fallbacks on EVERY task state change: `:task_assigned`, `:task_completed`, `:task_reclaimed`, `:task_dead_letter`. Use a helper function `cancel_pending_fallback(state, task_id)` called from every relevant handler.
**Warning signs:** Growing `pending_fallbacks` map in scheduler state; stale timer fire for already-assigned tasks.

### Pitfall 3: Stale Resource Data Leading to Bad Routing
**What goes wrong:** Resources reported by sidecar are 30+ seconds old, so the scheduler routes a task to a host that's actually overloaded.
**Why it happens:** Sidecar resource reports are periodic (every 30s). Between reports, a host could accept multiple tasks and become loaded.
**How to avoid:** Factor in the *number of currently assigned tasks* (from TaskQueue, which is always current) in addition to reported resource metrics. Count assigned tasks per endpoint as a supplementary load signal.
**Warning signs:** Tasks consistently routed to already-busy hosts; load imbalance despite multiple endpoints.

### Pitfall 4: Race Between Routing and Assignment
**What goes wrong:** The scheduler selects an endpoint, but by the time it assigns the task, the target agent is no longer idle (another scheduling event already assigned them).
**Why it happens:** The existing scheduler already handles this via `TaskQueue.assign_task/3` which returns `{:error, {:invalid_state, status}}` if the task is no longer queued. But the router might select an agent that's no longer idle.
**How to avoid:** The existing `do_match_loop` already handles this gracefully -- it removes matched agents from the candidate list. Keep this pattern. The router should return a *ranked list* of candidates, and the scheduler tries them in order.
**Warning signs:** High rate of `scheduler_assign_failed` log entries.

### Pitfall 5: Claude API Endpoint as Single Point of Failure
**What goes wrong:** When the Claude API key is rate-limited or the API is down, all complex tasks AND fallback-from-standard tasks queue indefinitely.
**Why it happens:** Single Claude API key with no local fallback option for complex tasks.
**How to avoid:** The TTL-based queueing decision handles this (tasks expire rather than building unbounded backlog). Also, the one-step fallback means complex tasks have no further fallback -- they must wait or expire. Log and alert on Claude API unavailability.
**Warning signs:** Growing queue of complex-tier tasks; Claude API error responses.

### Pitfall 6: Unknown Tier Routing Loop
**What goes wrong:** Tasks with `:unknown` complexity (empty params, 0.0 confidence) get routed conservatively to `:standard`, which might be down, then fallback to `:complex` (burning expensive API calls for tasks that might be trivial).
**Why it happens:** Conservative tie-breaking from Phase 17 decision.
**How to avoid:** `:unknown` tier should be treated as `:standard` for routing (already the Phase 17 decision), but the routing log should clearly flag it as "unknown-defaulted-to-standard" so operators can investigate.
**Warning signs:** High percentage of tasks routed as unknown; unexpected Claude API cost from unknown tasks falling back to complex.

## Code Examples

### Example 1: Augmented Scheduler try_schedule_all

```elixir
defp try_schedule_all(trigger) do
  idle_agents =
    AgentCom.AgentFSM.list_all()
    |> Enum.filter(fn a -> a.fsm_state == :idle end)
    |> Enum.reject(fn a -> AgentCom.RateLimiter.rate_limited?(a.agent_id) end)

  queued_tasks = AgentCom.TaskQueue.list(status: :queued)

  :telemetry.execute(
    [:agent_com, :scheduler, :attempt],
    %{idle_agents: length(idle_agents), queued_tasks: length(queued_tasks)},
    %{trigger: trigger}
  )

  # Get endpoint state once per scheduling round (not per task)
  endpoints = AgentCom.LlmRegistry.list_endpoints()
  endpoint_resources = gather_resources(endpoints)

  do_match_loop(queued_tasks, idle_agents, endpoints, endpoint_resources)
end
```

### Example 2: TaskRouter.route/3 -- Pure Function

```elixir
defmodule AgentCom.TaskRouter do
  @moduledoc "Routes tasks to execution tiers based on complexity and endpoint availability."

  def route(task, endpoints, endpoint_resources) do
    tier = resolve_tier(task)

    case find_target(tier, task, endpoints, endpoint_resources) do
      {:ok, target} ->
        decision = build_decision(task, tier, target, false, nil)
        {:ok, decision}

      {:unavailable, reason} ->
        {:fallback, tier, reason}
    end
  end

  defp resolve_tier(task) do
    case get_in(task, [:complexity, :effective_tier]) do
      :trivial -> :trivial
      :standard -> :standard
      :complex -> :complex
      :unknown -> :standard  # conservative default
      nil -> :standard       # no complexity data
    end
  end

  defp find_target(:trivial, _task, _endpoints, _resources) do
    # Trivial tasks go to sidecar -- no endpoint selection needed
    {:ok, %{type: :sidecar, endpoint: nil, model: nil}}
  end

  defp find_target(:standard, task, endpoints, resources) do
    healthy_ollama =
      endpoints
      |> Enum.filter(fn ep -> ep.status == :healthy and ep.models != [] end)

    case healthy_ollama do
      [] -> {:unavailable, :no_healthy_ollama_endpoints}
      candidates ->
        scored = score_and_rank(candidates, resources, task)
        best = hd(scored)
        {:ok, %{type: :ollama, endpoint: best.endpoint, model: select_model(best.endpoint)}}
    end
  end

  defp find_target(:complex, _task, _endpoints, _resources) do
    # Complex tasks go to Claude API -- single key, no endpoint selection
    {:ok, %{type: :claude, endpoint: :claude_api, model: "claude"}}
  end
end
```

### Example 3: Routing Decision Telemetry Event

```elixir
# New telemetry event for routing decisions
:telemetry.execute(
  [:agent_com, :scheduler, :route],
  %{
    candidate_count: length(candidates),
    scoring_duration_us: scoring_time
  },
  %{
    task_id: task.id,
    effective_tier: decision.effective_tier,
    selected_endpoint: decision.selected_endpoint,
    selected_model: decision.selected_model,
    fallback_used: decision.fallback_used,
    fallback_reason: decision.fallback_reason,
    classification_reason: decision.classification_reason
  }
)
```

### Example 4: Fallback Timer Handling in Scheduler

```elixir
# When preferred tier is unavailable, set fallback timer
def handle_info({:fallback_timeout, task_id}, state) do
  case Map.pop(state.pending_fallbacks, task_id) do
    {nil, _state} ->
      # Already handled (task assigned or cancelled)
      {:noreply, state}

    {fallback_info, remaining_fallbacks} ->
      # Attempt assignment at fallback tier
      case AgentCom.TaskQueue.get(task_id) do
        {:ok, %{status: :queued} = task} ->
          try_route_at_tier(task, fallback_info.fallback_tier)
          {:noreply, %{state | pending_fallbacks: remaining_fallbacks}}

        _ ->
          # Task no longer queued (assigned, completed, etc.)
          {:noreply, %{state | pending_fallbacks: remaining_fallbacks}}
      end
  end
end
```

### Example 5: Task Map Extension for Routing

```elixir
# In TaskQueue.submit -- add routing_decision field (nil until routed)
task = %{
  # ... existing fields ...
  complexity: AgentCom.Complexity.build(params),
  routing_decision: nil  # populated by scheduler when routed
}

# In Scheduler.do_assign -- attach routing decision
defp do_assign(task, agent, routing_decision) do
  case AgentCom.TaskQueue.assign_task(task.id, agent.agent_id) do
    {:ok, assigned_task} ->
      # Store routing decision on the task
      store_routing_decision(task.id, routing_decision)
      # ... existing push_task logic ...
  end
end
```

## Discretion Area Recommendations

### Warm vs Cold Model Preference

**Recommendation:** Apply a 15% score bonus for endpoints with the task's needed model already loaded in memory.

**Rationale:** Ollama keeps recently-used models warm in VRAM/RAM. Routing to a host with a warm model avoids the 5-30 second model load time. The `LlmRegistry` health check already discovers loaded models via `/api/tags`. Compare the task's required model (if specified in metadata) against the endpoint's `models` list.

**Implementation:** The `/api/ps` endpoint (used by sidecar for VRAM metrics) returns currently *running* models. The `/api/tags` endpoint (used by LlmRegistry health check) returns all *installed* models. For warm model detection, the sidecar's VRAM report already queries `/api/ps` -- extend the resource report to include the list of running model names. This lets the router distinguish "installed but cold" from "loaded and warm."

### Telemetry Approach

**Recommendation:** Full per-task routing events (not aggregates), following the existing Phase 14 pattern.

**Rationale:** The existing telemetry system emits per-task events for submit, assign, complete, fail, etc. Adding a per-task `:route` event is consistent and enables:
- Per-task routing trace for debugging
- Aggregate analysis via MetricsCollector (which already aggregates per-task events into window metrics)
- Disagreement tracking (preferred vs actual tier)

**New telemetry event:** `[:agent_com, :scheduler, :route]`
- Measurements: `%{candidate_count: N, scoring_duration_us: N}`
- Metadata: `%{task_id, effective_tier, selected_endpoint, selected_model, fallback_used, fallback_reason, classification_reason}`

### Cost Estimation in Routing Logs

**Recommendation:** Include estimated cost when data is available, but don't block on it.

**Rationale:** Phase 19 is routing, not execution. Cost data comes from execution results (tokens_used in task_complete). The routing decision can include an *estimated* cost tier (trivial=free, standard=local-compute, complex=api-cost) but not a dollar amount. When execution completes, the task's `tokens_used` field provides actual cost data.

**Implementation:** Add `estimated_cost_tier: :free | :local | :api` to the routing decision map. Actual cost tracking is Phase 20+ territory.

### Backlog Drain on Tier Recovery

**Recommendation:** Gradual drain -- process one queued task per scheduling trigger, following the existing event-driven pattern.

**Rationale:** The existing scheduler already processes tasks one at a time per `try_schedule_all` call (the `do_match_loop` pairs tasks with agents). When a tier recovers:
1. The health check marks the endpoint `:healthy`
2. The `llm_registry` PubSub broadcast triggers a scheduling attempt
3. The scheduler processes queued tasks normally, one per idle agent

This is already gradual by nature. No special backlog drain logic needed -- the existing event-driven architecture handles it.

### Specific Timeout Values

**Recommendation:**
- **Fallback wait timeout:** 5 seconds (configurable via `AgentCom.Config`)
- **Task TTL for queued-with-no-tier:** 10 minutes (configurable)
- **Tier-down alert threshold:** 60 seconds (configurable)

**Rationale:**
- 5s fallback wait balances responsiveness with allowing brief endpoint recovery. Too short (1s) causes unnecessary fallbacks on transient network hiccups. Too long (30s) blocks task execution noticeably.
- 10-minute TTL for queued tasks is long enough for brief outages but prevents unbounded backlog growth. Users can resubmit if needed.
- 60-second tier-down alert threshold avoids noise from brief health check failures (the LlmRegistry already requires 2 consecutive failures at 30s intervals = 60s minimum before marking unhealthy).

All values should be configurable via `AgentCom.Config` for runtime adjustment without restart.

## Integration Points

### Scheduler -> LlmRegistry (READ)

```
Scheduler reads:
  LlmRegistry.list_endpoints()    # DETS (GenServer call) -- once per scheduling round
  LlmRegistry.get_resources(id)   # ETS direct read -- per candidate endpoint
```

### Scheduler -> TaskQueue (READ/WRITE)

```
Scheduler reads:
  TaskQueue.list(status: :queued)  # existing
  TaskQueue.get(task_id)           # for fallback re-check

Scheduler writes:
  TaskQueue.assign_task(task_id, agent_id)  # existing
  # NEW: Store routing_decision on task (new field or via metadata)
```

### Scheduler -> AgentFSM (READ)

```
Scheduler reads:
  AgentFSM.list_all()              # existing -- filter idle agents
```

### PubSub Subscriptions (Scheduler)

```
Already subscribed:
  "tasks"     -- task_submitted, task_reclaimed, task_retried, task_completed
  "presence"  -- agent_joined, agent_idle

NEW subscription needed:
  "llm_registry"  -- endpoint_changed (trigger re-evaluation when endpoints recover)
```

### Dashboard Integration

The `DashboardState` already subscribes to `llm_registry` PubSub and includes `llm_registry` snapshot in its state. The routing decision data should be:
1. Stored on the task (accessible via task detail view)
2. Summarized in dashboard snapshot (count by tier, fallback rate)
3. Available via expandable detail on the task in the dashboard

## Task Data Model Changes

### New Fields on Task Map

```elixir
# Addition to task map in TaskQueue.submit
routing_decision: nil  # populated when scheduler routes the task

# The routing_decision map structure:
%{
  effective_tier: :trivial | :standard | :complex | :unknown,
  target_type: :sidecar | :ollama | :claude,
  selected_endpoint: "host:port" | :claude_api | nil,
  selected_model: "model-name" | nil,
  fallback_used: boolean,
  fallback_from_tier: atom | nil,
  fallback_reason: string | nil,
  candidate_count: integer,
  classification_reason: string,
  decided_at: integer  # millisecond timestamp
}
```

### Impact on Existing Code

1. **TaskQueue.submit/1** -- Add `routing_decision: nil` to initial task map
2. **Scheduler.do_assign/2** -- Becomes `do_assign/3` with routing_decision parameter
3. **Socket.handle_info(:push_task)** -- Forward routing_decision to sidecar (optional, for observability)
4. **Endpoint format_task/1** -- Include routing_decision in API responses
5. **DashboardState.snapshot/0** -- Aggregate routing stats

## New PubSub Topics / Events

### Routing Events (on existing "tasks" topic)

No new PubSub topic needed. Routing decisions are logged via telemetry and stored on the task. The existing `:task_assigned` event already broadcasts on "tasks" -- the routing_decision is accessible via the task data.

### New Scheduler Subscription

The Scheduler should subscribe to `"llm_registry"` to react to endpoint recovery:

```elixir
# In Scheduler.init
Phoenix.PubSub.subscribe(AgentCom.PubSub, "llm_registry")

# Handler
def handle_info({:llm_registry_update, :endpoint_changed}, state) do
  try_schedule_all(:endpoint_changed)
  {:noreply, state}
end
```

## Open Questions

1. **How should the sidecar identify itself as an execution tier?**
   - What we know: Sidecars connect with capabilities list. Currently capabilities are strings like "code", "review".
   - What's unclear: Should sidecars declare their tier affinity (e.g., capability "tier:sidecar" or "tier:ollama")? Or should the scheduler infer it from the presence of an ollama_url in the identify message?
   - Recommendation: Use the existing `ollama_url` field. Agents that reported an `ollama_url` during identify are Ollama-capable. Agents without it are sidecar-only. Claude routing goes to a virtual "claude" endpoint, not a connected agent. This avoids new capability conventions and uses data already available.

2. **Claude API integration mechanism (Phase 20 dependency)?**
   - What we know: Phase 19 is the routing *decision* layer; Phase 20 is execution. For complex tasks routed to Claude, the scheduler needs to know "Claude is available" but doesn't need to call the API itself.
   - What's unclear: Does the scheduler assign complex tasks to a special "claude-agent" sidecar, or does the hub itself make Claude API calls?
   - Recommendation: Phase 19 should treat Claude as "always available" (single API key, assumed reachable) and route complex tasks to a designated claude-agent sidecar. The sidecar then makes the API call. This keeps the hub stateless and uses the existing sidecar task assignment mechanism.

3. **Model-to-task matching for standard tier?**
   - What we know: LlmRegistry tracks which models are loaded on each endpoint.
   - What's unclear: How does the scheduler know which model a standard-tier task needs? Tasks don't currently declare a required model.
   - Recommendation: For Phase 19, use a default model configured via `AgentCom.Config.get(:default_ollama_model)`. Any healthy Ollama endpoint with this model loaded is a valid candidate. Future phases can add model-specific routing based on task metadata.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `lib/agent_com/scheduler.ex` -- current scheduler architecture
- Codebase analysis: `lib/agent_com/complexity.ex` -- Phase 17 complexity classification
- Codebase analysis: `lib/agent_com/llm_registry.ex` -- Phase 18 endpoint registry
- Codebase analysis: `lib/agent_com/task_queue.ex` -- task data model and assignment
- Codebase analysis: `lib/agent_com/agent_fsm.ex` -- agent state management
- Codebase analysis: `lib/agent_com/telemetry.ex` -- telemetry event patterns
- Codebase analysis: `lib/agent_com/socket.ex` -- WebSocket protocol, task push, resource reporting
- Codebase analysis: `sidecar/index.js` -- sidecar task handling, resource reporting
- Codebase analysis: `sidecar/lib/resources.js` -- CPU/RAM/VRAM collection
- Codebase analysis: `lib/agent_com/config.ex` -- runtime configuration pattern
- Codebase analysis: `lib/agent_com/alerter.ex` -- alert rule evaluation patterns
- Codebase analysis: `lib/agent_com/dashboard_state.ex` -- dashboard aggregation patterns
- Codebase analysis: `test/agent_com/scheduler_test.exs` -- test patterns for scheduler
- Codebase analysis: `test/support/test_factory.ex` -- test factory patterns

### Secondary (MEDIUM confidence)
- Codebase analysis: `lib/agent_com/metrics_collector.ex` -- telemetry handler attachment patterns
- Phase 17-18 prior decisions from project context (provided in prompt)

### Tertiary (LOW confidence)
- None -- all findings verified against codebase

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries/patterns already in use in the codebase
- Architecture: HIGH -- patterns derived directly from existing codebase patterns (Scheduler, AgentFSM, LlmRegistry)
- Pitfalls: HIGH -- identified from concrete code analysis of existing race conditions and state management patterns
- Discretion recommendations: MEDIUM -- timeout values are reasonable defaults based on existing system timing but should be validated in practice

**Research date:** 2026-02-12
**Valid until:** 2026-03-14 (30 days -- stable domain, all Elixir/OTP patterns)
