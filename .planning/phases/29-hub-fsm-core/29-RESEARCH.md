# Phase 29: Hub FSM Core - Research

**Researched:** 2026-02-13
**Domain:** Elixir GenServer-based finite state machine, PubSub event integration, ETS state history
**Confidence:** HIGH

## Summary

Phase 29 implements the HubFSM -- the autonomous brain of the system -- as a singleton GenServer with 4 states (Executing, Improving, Contemplating, Resting). The implementation follows the proven AgentFSM pattern already established in the codebase: a `@valid_transitions` map, explicit state atom tracking in a struct, `Process.send_after` timers, telemetry emission on transitions, and PubSub integration for event-driven behavior.

The codebase already has all prerequisite infrastructure: CostLedger (Phase 25) provides budget gating via `check_budget/1`, ClaudeClient (Phase 26) provides `set_hub_state/1` for budget integration and the three core LLM operations, GoalBacklog (Phase 27) provides `dequeue/0` and `list/1` for queue-driven transitions. PubSub topics "goals", "tasks", and "presence" are already active. The Scheduler demonstrates the exact pattern for PubSub subscription and event-driven GenServer behavior that HubFSM will replicate.

The incremental build strategy (2-state core first, then 4-state expansion) is well-suited to this architecture. The 2-state version needs only Executing and Resting with GoalBacklog as the trigger. API endpoints follow the existing Plug.Router pattern in `AgentCom.Endpoint`. Dashboard integration follows the DashboardSocket/DashboardState pattern of PubSub broadcasting + snapshot aggregation.

**Primary recommendation:** Follow the existing AgentFSM and Scheduler patterns exactly -- GenServer with `@valid_transitions` map, `Process.send_after` for timers, PubSub subscriptions in `init/1`, telemetry on every transition, ETS for fast dashboard reads of transition history.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### FSM Implementation
- GenServer with explicit state atom tracking (matches existing AgentFSM pattern)
- @valid_transitions map defines allowed state changes
- Transition predicates are pure functions: can_transition?(current_state, system_state) -> new_state | :stay
- Comprehensive timer cancellation on every transition to prevent state corruption

#### State Transitions
- Queue-driven: check GoalBacklog and TaskQueue state to determine next state
- Event-driven: PubSub subscriptions to "goals", "tasks", "presence" topics
- Resting -> Executing: when goal backlog has pending goals
- Executing -> Resting: when goal queue empty AND no active goals
- Resting -> Improving: when idle for configurable duration, or git event received
- Improving -> Contemplating: when no improvements found across all repos
- Contemplating -> Resting: when max 3 proposals written or no ideas generated
- Any state -> Resting: when cost budget exhausted

#### Parallel Goal Processing
- Hub processes multiple independent goals simultaneously
- Before decomposing a new goal, check: does it depend on anything currently executing?
- Dependency detection as preprocessing step (file overlap, keyword analysis)

#### Build Strategy
- Start with 2-state core (Executing + Resting), prove the loop works
- Expand to 4 states after core loop is stable
- Success criterion 5 explicitly calls for this incremental approach

#### Safety
- Pause/resume API: POST /api/hub/pause, POST /api/hub/resume
- Paused state overrides all transitions -- hub does nothing until resumed
- Watchdog timer: if stuck in any state > 2 hours, force-transition to Resting with alert
- All state changes logged with timestamp and reason

### Claude's Discretion
- Timer durations for idle-to-improving transition
- Event debouncing strategy (multiple rapid PubSub events)
- Whether to use Process.send_after or :timer for periodic checks
- Supervision tree placement (after GoalBacklog, ClaudeClient, Scheduler)

### Deferred Ideas (OUT OF SCOPE)
None explicitly listed.
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GenServer (OTP) | Elixir 1.x | FSM process with state management | Already used by AgentFSM, CostLedger, GoalBacklog, Scheduler -- proven pattern in codebase |
| Phoenix.PubSub | (already in deps) | Event-driven transitions via topic subscriptions | Already used by Scheduler, DashboardState -- same subscription pattern |
| ETS | (OTP built-in) | Fast transition history reads for dashboard | Already used by CostLedger for hot-path reads |
| :telemetry | (already in deps) | Observable state transitions | Already used by AgentFSM, Scheduler, CostLedger -- established event catalog |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| AgentCom.Config | (in-app) | Runtime-configurable timer durations | For idle-to-improving timeout, watchdog duration |
| AgentCom.CostLedger | (in-app) | Budget gate before any LLM call | Check on every transition that may trigger Claude CLI |
| AgentCom.ClaudeClient | (in-app) | LLM invocations + `set_hub_state/1` | Update hub state on every transition for budget tracking |
| AgentCom.GoalBacklog | (in-app) | Queue-driven transition predicates | `dequeue/0`, `list/1`, `stats/0` for state decisions |
| Jason | (already in deps) | JSON encoding for dashboard WebSocket | Transition history serialization |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| GenServer | GenStateMachine (gen_statem) | Locked decision: GenServer chosen to match existing AgentFSM pattern. gen_statem adds complexity without benefit for 4 states. |
| ETS history table | DETS persistence | ETS chosen: transition history is ephemeral (session-scoped), dashboard reads must be fast. No restart persistence needed -- transitions are already logged. |

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  hub_fsm.ex              # Main GenServer: state machine, transitions, timers
  hub_fsm/
    predicates.ex         # Pure functions: can_transition?(state, system_state)
    history.ex            # ETS-backed transition history (last N entries)
```

### Pattern 1: Transition Map with Validation (from AgentFSM)
**What:** Module attribute `@valid_transitions` defines a map of `{from_state => [allowed_to_states]}`. The `transition/2` private function validates against this map before applying state changes.
**When to use:** Every state change.
**Example:**
```elixir
# Source: lib/agent_com/agent_fsm.ex lines 32-37
@valid_transitions %{
  idle: [:assigned, :offline],
  assigned: [:working, :idle, :offline],
  working: [:idle, :blocked, :offline],
  blocked: [:working, :idle, :offline]
}

# HubFSM equivalent (2-state core):
@valid_transitions %{
  resting: [:executing],
  executing: [:resting]
}

# HubFSM full 4-state:
@valid_transitions %{
  resting: [:executing, :improving],
  executing: [:resting],
  improving: [:contemplating, :resting],
  contemplating: [:resting]
}
```

### Pattern 2: PubSub Event-Driven GenServer (from Scheduler)
**What:** Subscribe to PubSub topics in `init/1`, react to events in `handle_info/2` with pattern matching. Multiple events may trigger the same evaluation logic.
**When to use:** HubFSM subscribes to "goals", "tasks", "presence" topics to detect when transition conditions change.
**Example:**
```elixir
# Source: lib/agent_com/scheduler.ex lines 82-94
@impl true
def init(_opts) do
  Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")
  Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
  Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")

  # Periodic re-evaluation timer
  schedule_tick()

  {:ok, initial_state()}
end

# Event handlers trigger re-evaluation
@impl true
def handle_info({:goal_event, %{event: :goal_submitted}}, state) do
  state = maybe_transition(state)
  {:noreply, state}
end
```

### Pattern 3: Timer Management with Cancellation (from AgentFSM)
**What:** Store timer references in state struct, cancel on every transition to prevent stale timers from corrupting state.
**When to use:** Watchdog timer (2-hour stuck detection), idle-to-improving timer, periodic tick timer.
**Example:**
```elixir
# Source: lib/agent_com/agent_fsm.ex lines 542-547
defp cancel_timer(nil), do: :ok
defp cancel_timer(ref) do
  Process.cancel_timer(ref)
  :ok
end

# On every transition:
defp do_transition(state, new_fsm_state, reason) do
  cancel_timer(state.watchdog_ref)
  cancel_timer(state.idle_timer_ref)
  cancel_timer(state.tick_ref)

  new_watchdog = Process.send_after(self(), :watchdog_timeout, @watchdog_ms)
  # ... set new state, emit telemetry, broadcast
end
```

### Pattern 4: ETS for Fast Dashboard Reads (from CostLedger)
**What:** Named ETS table with `:public` read access for zero-GenServer-call dashboard queries. GenServer writes on transitions, dashboard reads directly.
**When to use:** Transition history that the dashboard needs to display in real-time.
**Example:**
```elixir
# Source: lib/agent_com/cost_ledger.ex lines 139-140
@ets_table = :ets.new(@ets_table, [:named_table, :public, :set, {:read_concurrency, true}])

# HubFSM pattern: ordered_set for chronological history
@history_table :hub_fsm_history
:ets.new(@history_table, [:named_table, :public, :ordered_set, {:read_concurrency, true}])
```

### Pattern 5: Pause/Resume Override (new pattern, simple flag)
**What:** A boolean `:paused` flag in GenServer state. When true, all transition predicates return `:stay`. Pause/resume via API endpoints in `AgentCom.Endpoint`.
**When to use:** Safety mechanism for human oversight.
**Example:**
```elixir
defp maybe_transition(%{paused: true} = state), do: state

defp maybe_transition(state) do
  system_state = gather_system_state()
  case evaluate_transition(state.fsm_state, system_state) do
    {:transition, new_state, reason} -> do_transition(state, new_state, reason)
    :stay -> state
  end
end
```

### Pattern 6: Singleton GenServer with Named Registration
**What:** Register with `name: __MODULE__` for singleton guarantee. Start in supervision tree after dependencies.
**When to use:** HubFSM must be a singleton.
**Example:**
```elixir
# Source: lib/agent_com/cost_ledger.ex line 42
def start_link(opts) do
  GenServer.start_link(__MODULE__, opts, name: __MODULE__)
end
```

### Anti-Patterns to Avoid
- **Blocking GenServer.call in transition predicates:** GoalBacklog.stats() and TaskQueue.stats() are GenServer.call. If HubFSM calls these synchronously during every PubSub event, it creates bottleneck. Solution: gather system state once per evaluation, not per-event.
- **Timer accumulation:** If a PubSub event triggers a transition evaluation that doesn't change state, don't restart timers. Only cancel+restart timers on actual transitions.
- **Direct state mutation without validation:** Always go through the `@valid_transitions` map. Never set `:fsm_state` directly.
- **Coupling LLM calls to the FSM process:** HubFSM should not make Claude CLI calls itself. It should coordinate by triggering other processes (future phases). For Phase 29, the FSM only manages state -- actual goal processing is future work.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| State transition validation | Custom if/else chains | `@valid_transitions` map + `transition/2` helper | Exactly what AgentFSM does; declarative, testable, documented |
| Event debouncing | Custom timer-based debouncer | Process.send_after with `:tick` messages | Scheduler pattern: re-evaluate on tick, not on every event. Multiple events between ticks are naturally coalesced. |
| Budget gate | Manual check before each operation | `CostLedger.check_budget/1` | Already built (Phase 25), reads from ETS, zero-latency |
| Dashboard state broadcasting | Custom WebSocket push per transition | PubSub broadcast to "hub_fsm" topic + DashboardSocket subscription | Follows exact pattern of every other dashboard-visible component |
| Transition history storage | DETS, database, file | ETS ordered_set | Ephemeral session data, must be fast for dashboard, no persistence needed |

**Key insight:** Every building block already exists in the codebase. HubFSM is a composition of patterns from AgentFSM (transition map), Scheduler (PubSub subscriptions + event-driven), CostLedger (ETS for dashboard), and Endpoint (API routes). The risk is in the novel transition logic, not the infrastructure.

## Common Pitfalls

### Pitfall 1: Stale Timer Firing After State Change
**What goes wrong:** A `Process.send_after` timer fires for a state the FSM has already left. For example, the idle-to-improving timer fires after the FSM already transitioned to Executing.
**Why it happens:** Timer was set when entering Resting, FSM transitioned to Executing via goal_submitted event, but the timer reference was not cancelled.
**How to avoid:** Cancel ALL active timers on EVERY transition. Store all timer refs in the state struct. The `do_transition` function must cancel before setting new state.
**Warning signs:** Log entries showing "unexpected state" or transitions that shouldn't be valid from the current state.

### Pitfall 2: PubSub Event Storm Causing Excessive Re-evaluation
**What goes wrong:** A batch of 20 goals submitted in rapid succession triggers 20 separate `maybe_transition` evaluations, each calling `GoalBacklog.stats()` and `TaskQueue.stats()`.
**Why it happens:** Each PubSub event triggers immediate re-evaluation without coalescing.
**How to avoid:** Use a tick-based evaluation pattern. PubSub events set a "dirty" flag; a periodic tick (e.g., every 500ms-1s) checks the flag and evaluates once. Alternatively, debounce by scheduling a `:reevaluate` message via `Process.send_after` and ignoring duplicates.
**Warning signs:** High CPU usage, GenServer.call timeouts on GoalBacklog/TaskQueue during burst events.

### Pitfall 3: Deadlock Between HubFSM and GoalBacklog
**What goes wrong:** HubFSM calls `GoalBacklog.dequeue()` (GenServer.call) while GoalBacklog is trying to broadcast a PubSub event that HubFSM is processing.
**Why it happens:** Both are GenServers; synchronous calls between them can deadlock if message queues back up.
**How to avoid:** HubFSM should gather state (GoalBacklog.stats(), TaskQueue.stats()) only during tick evaluations, never in response to PubSub events from those same processes. Use `GenServer.cast` or `Process.send` for one-way notifications.
**Warning signs:** GenServer.call timeouts, process mailbox growth.

### Pitfall 4: Watchdog Timer Interfering with Normal Operations
**What goes wrong:** The 2-hour watchdog timer fires during a legitimate long-running Executing state (e.g., a complex multi-task goal taking 3 hours).
**Why it happens:** Watchdog doesn't account for active progress.
**How to avoid:** Reset the watchdog timer when meaningful progress occurs (task completions, goal transitions). The watchdog should detect "no activity" not "time elapsed."
**Warning signs:** Unexpected transitions to Resting during active work.

### Pitfall 5: Paused State Leaking Through Timer Messages
**What goes wrong:** FSM is paused, but a `:tick` or `:watchdog_timeout` message fires and triggers a transition anyway.
**Why it happens:** Timer was set before pause, fires after pause, handler doesn't check paused flag.
**How to avoid:** Every `handle_info` handler that could trigger a transition must check `state.paused` first. Alternatively, cancel all timers on pause and re-arm on resume.
**Warning signs:** State changes while paused.

### Pitfall 6: ETS History Table Not Created Before First Write
**What goes wrong:** HubFSM tries to write to the history ETS table during init transition, but the table doesn't exist yet.
**Why it happens:** ETS table creation and first state transition happen in the same `init/1` function, but the order is wrong.
**How to avoid:** Create ETS table FIRST in `init/1`, before any transition logic runs.
**Warning signs:** `:badarg` errors during startup.

## Code Examples

### HubFSM GenServer Skeleton (2-State Core)
```elixir
# Source: Synthesized from AgentFSM (agent_fsm.ex) + Scheduler (scheduler.ex) patterns
defmodule AgentCom.HubFSM do
  use GenServer
  require Logger

  @valid_transitions %{
    resting: [:executing],
    executing: [:resting]
  }

  @tick_interval_ms 1_000
  @watchdog_ms 2 * 60 * 60 * 1_000  # 2 hours
  @history_table :hub_fsm_history
  @history_cap 200

  defstruct [
    :fsm_state,
    :last_state_change,
    :tick_ref,
    :watchdog_ref,
    :idle_timer_ref,
    :cycle_count,
    paused: false,
    active_goal_ids: [],
    transition_count: 0
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- Client API --

  def get_state, do: GenServer.call(__MODULE__, :get_state)
  def pause, do: GenServer.call(__MODULE__, :pause)
  def resume, do: GenServer.call(__MODULE__, :resume)
  def history(opts \\ []), do: GenServer.call(__MODULE__, {:history, opts})

  # -- Init --

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    # Create ETS history table FIRST
    :ets.new(@history_table, [:named_table, :public, :ordered_set, {:read_concurrency, true}])

    # Subscribe to PubSub topics
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

    now = System.system_time(:millisecond)
    tick_ref = Process.send_after(self(), :tick, @tick_interval_ms)
    watchdog_ref = Process.send_after(self(), :watchdog_timeout, @watchdog_ms)

    state = %__MODULE__{
      fsm_state: :resting,
      last_state_change: now,
      tick_ref: tick_ref,
      watchdog_ref: watchdog_ref,
      cycle_count: 0
    }

    record_transition(state, nil, :resting, "hub_fsm_started")
    broadcast_state_change(state)

    Logger.info("hub_fsm_started", initial_state: :resting)
    {:ok, state}
  end
end
```

### Transition Predicate (Pure Function)
```elixir
# Source: Novel pattern based on CONTEXT.md decision
defmodule AgentCom.HubFSM.Predicates do
  @doc """
  Evaluate whether the FSM should transition.
  Returns {:transition, new_state, reason} or :stay.
  """
  def evaluate(:resting, system_state) do
    cond do
      system_state.budget_exhausted ->
        :stay  # Already resting

      system_state.pending_goals > 0 ->
        {:transition, :executing, "pending goals in backlog"}

      true ->
        :stay
    end
  end

  def evaluate(:executing, system_state) do
    cond do
      system_state.budget_exhausted ->
        {:transition, :resting, "budget exhausted"}

      system_state.pending_goals == 0 and system_state.active_goals == 0 ->
        {:transition, :resting, "no pending or active goals"}

      true ->
        :stay
    end
  end
end
```

### Tick-Based Evaluation with Debouncing
```elixir
# Source: Synthesized from Scheduler (scheduler.ex) periodic sweep pattern
@impl true
def handle_info(:tick, %{paused: true} = state) do
  # Re-arm tick even when paused (so resume doesn't need to restart it)
  tick_ref = Process.send_after(self(), :tick, @tick_interval_ms)
  {:noreply, %{state | tick_ref: tick_ref}}
end

def handle_info(:tick, state) do
  system_state = gather_system_state()
  state = maybe_transition(state, system_state)
  tick_ref = Process.send_after(self(), :tick, @tick_interval_ms)
  {:noreply, %{state | tick_ref: tick_ref}}
end

defp gather_system_state do
  goal_stats = AgentCom.GoalBacklog.stats()
  pending_goals = Map.get(goal_stats.by_status, :submitted, 0)
  active_goals = Map.get(goal_stats.by_status, :decomposing, 0) +
                 Map.get(goal_stats.by_status, :executing, 0) +
                 Map.get(goal_stats.by_status, :verifying, 0)

  budget_ok = AgentCom.CostLedger.check_budget(:executing) == :ok

  %{
    pending_goals: pending_goals,
    active_goals: active_goals,
    budget_exhausted: not budget_ok
  }
end
```

### ETS Transition History
```elixir
# Source: Adapted from CostLedger ETS pattern (cost_ledger.ex)
defp record_transition(state, from_state, to_state, reason) do
  now = System.system_time(:millisecond)
  duration_ms = if state.last_state_change, do: now - state.last_state_change, else: 0

  entry = %{
    from: from_state,
    to: to_state,
    reason: reason,
    timestamp: now,
    duration_in_previous_ms: duration_ms,
    transition_number: state.transition_count + 1
  }

  # Use negative timestamp as key for ordered_set (newest first)
  :ets.insert(@history_table, {{-now, state.transition_count + 1}, entry})

  # Cap history size
  trim_history()

  # Emit telemetry
  :telemetry.execute(
    [:agent_com, :hub_fsm, :transition],
    %{duration_ms: duration_ms},
    %{from_state: from_state, to_state: to_state, reason: reason}
  )
end

defp trim_history do
  size = :ets.info(@history_table, :size)
  if size > @history_cap do
    # Delete oldest entries (highest key values since we negate timestamps)
    keys = :ets.tab2list(@history_table)
           |> Enum.sort_by(fn {key, _} -> key end, :desc)
           |> Enum.take(size - @history_cap)
           |> Enum.each(fn {key, _} -> :ets.delete(@history_table, key) end)
  end
end
```

### Pause/Resume API Endpoints
```elixir
# Source: Follows existing AgentCom.Endpoint pattern (endpoint.ex)
# Add to lib/agent_com/endpoint.ex:

post "/api/hub/pause" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    case AgentCom.HubFSM.pause() do
      :ok -> send_json(conn, 200, %{"status" => "paused"})
      {:error, :already_paused} -> send_json(conn, 200, %{"status" => "already_paused"})
    end
  end
end

post "/api/hub/resume" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    case AgentCom.HubFSM.resume() do
      :ok -> send_json(conn, 200, %{"status" => "resumed"})
      {:error, :not_paused} -> send_json(conn, 200, %{"status" => "not_paused"})
    end
  end
end

get "/api/hub/state" do
  state = AgentCom.HubFSM.get_state()
  send_json(conn, 200, state)
end
```

### Dashboard Integration via PubSub
```elixir
# Source: Follows DashboardSocket pattern (dashboard_socket.ex)
# HubFSM broadcasts on state change:
defp broadcast_state_change(state) do
  Phoenix.PubSub.broadcast(AgentCom.PubSub, "hub_fsm", {:hub_fsm_state_change, %{
    fsm_state: state.fsm_state,
    paused: state.paused,
    last_state_change: state.last_state_change,
    cycle_count: state.cycle_count,
    active_goal_ids: state.active_goal_ids,
    timestamp: System.system_time(:millisecond)
  }})
end

# DashboardSocket subscribes in init:
# Phoenix.PubSub.subscribe(AgentCom.PubSub, "hub_fsm")
#
# And handles:
# def handle_info({:hub_fsm_state_change, info}, state) do
#   formatted = %{type: "hub_fsm_state", data: info}
#   {:ok, %{state | pending_events: [formatted | state.pending_events]}}
# end
```

## Discretion Recommendations

### Timer Durations for Idle-to-Improving Transition
**Recommendation:** 15 minutes default, configurable via `AgentCom.Config.get(:hub_idle_to_improving_ms)`.
**Rationale:** Short enough to be useful (don't waste idle time), long enough to avoid thrashing on temporary goal completion pauses. Make it configurable from day one since the right value will emerge from usage.

### Event Debouncing Strategy
**Recommendation:** Tick-based evaluation at 1-second intervals, NOT per-event evaluation.
**Rationale:** The Scheduler already demonstrates this pattern with its sweep timer. Multiple PubSub events between ticks are naturally coalesced. This prevents the Pitfall #2 (event storm) and Pitfall #3 (deadlock) issues. 1 second is fast enough for perceived real-time behavior while preventing excessive `GoalBacklog.stats()` calls.

### Process.send_after vs :timer
**Recommendation:** Use `Process.send_after/3` exclusively.
**Rationale:** This is what AgentFSM, Scheduler, CostLedger, and DashboardState all use. `Process.send_after` returns a reference that can be cancelled with `Process.cancel_timer/1`, which is critical for the "cancel all timers on transition" safety requirement. `:timer` module timers are harder to cancel reliably and add unnecessary complexity.

### Supervision Tree Placement
**Recommendation:** Place HubFSM after GoalBacklog in the children list (which is already after CostLedger, ClaudeClient, and Scheduler).
**Rationale:** HubFSM depends on CostLedger (budget checks), ClaudeClient (set_hub_state), GoalBacklog (queue state), and implicitly on TaskQueue and Scheduler. All of these are already in the supervision tree. The current order has GoalBacklog as the last GenServer before DetsBackup:

```
{AgentCom.CostLedger, []},      # Position 4
{AgentCom.ClaudeClient, []},     # Position 5
...
{AgentCom.Scheduler, []},        # Position 18
...
{AgentCom.GoalBacklog, []},      # Position 27
{AgentCom.HubFSM, []},           # NEW: Position 28 (after GoalBacklog, before Bandit)
{Bandit, ...}                    # Last
```

The `one_for_one` strategy means HubFSM crashing won't bring down its dependencies. It will restart and re-subscribe to PubSub topics automatically.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| gen_statem for Elixir FSMs | GenServer with explicit state tracking | Community consensus | gen_statem is powerful but verbose; for <= 10 states, a GenServer with `@valid_transitions` map is simpler and more idiomatic in Phoenix/Elixir apps |
| Synchronous PubSub event handling | Tick-based evaluation with PubSub as notification | Proven in this codebase (Scheduler) | Prevents event storms and deadlocks between GenServers |

## Open Questions

1. **How should HubFSM handle concurrent goal execution in the 2-state core?**
   - What we know: The decision says "Hub processes multiple independent goals simultaneously" and "dependency detection as preprocessing step"
   - What's unclear: In the 2-state core (Executing + Resting), should the FSM attempt to dequeue and process multiple goals immediately, or process one at a time? The full parallel processing logic may belong in a later phase.
   - Recommendation: For the 2-state core, track `active_goal_ids` in state. Dequeue one goal per tick when in Executing state (until a configurable max concurrency). This keeps the FSM simple while laying groundwork for parallel execution.

2. **Should the "hub_fsm" PubSub topic be new or reuse an existing topic?**
   - What we know: Existing topics are "goals", "tasks", "presence", "backups", "metrics", "alerts", "llm_registry", "repo_registry"
   - What's unclear: Whether to broadcast on a dedicated "hub_fsm" topic or add events to the "presence" topic
   - Recommendation: Create a new "hub_fsm" topic. The hub FSM state is conceptually distinct from agent presence, and DashboardSocket can subscribe to it independently. This follows the established pattern of one topic per domain.

3. **What telemetry event names for HubFSM transitions?**
   - What we know: Existing pattern is `[:agent_com, :fsm, :transition]` for agent FSM
   - What's unclear: Whether to reuse the same event with different metadata or create new events
   - Recommendation: New event `[:agent_com, :hub_fsm, :transition]` to avoid confusion with agent FSM transitions. Add to Telemetry.attach_handlers/0.

## Sources

### Primary (HIGH confidence)
- `lib/agent_com/agent_fsm.ex` -- AgentFSM GenServer pattern: @valid_transitions map, transition/2 validation, timer management, telemetry emission, PubSub broadcasting
- `lib/agent_com/scheduler.ex` -- Event-driven GenServer pattern: PubSub subscription in init, handle_info event handlers, periodic sweep timer
- `lib/agent_com/cost_ledger.ex` -- ETS for fast reads pattern, budget gating API, DETS+ETS dual-layer
- `lib/agent_com/claude_client.ex` -- `set_hub_state/1` API for budget integration
- `lib/agent_com/goal_backlog.ex` -- GoalBacklog API: dequeue/0, list/1, stats/0, transition/3, PubSub broadcasting to "goals" topic
- `lib/agent_com/application.ex` -- Supervision tree child ordering
- `lib/agent_com/endpoint.ex` -- Plug.Router API endpoint patterns
- `lib/agent_com/dashboard_socket.ex` -- Dashboard PubSub subscription and event forwarding pattern
- `lib/agent_com/dashboard_state.ex` -- Dashboard state aggregation pattern
- `lib/agent_com/telemetry.ex` -- Telemetry event catalog and handler attachment

### Secondary (MEDIUM confidence)
- CONTEXT.md decisions on transition rules, safety mechanisms, and build strategy
- Elixir GenServer documentation for Process.send_after, timer cancellation patterns

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All components already exist in the codebase; HubFSM is a composition of proven patterns
- Architecture: HIGH - Every architectural pattern (transition map, PubSub subscription, ETS history, timer management) has a working reference implementation in the codebase
- Pitfalls: HIGH - Timer corruption, event storms, and deadlock risks are well-understood OTP patterns with clear mitigation strategies demonstrated in existing code
- Discretion items: MEDIUM - Timer duration values (15min idle-to-improving) and tick interval (1s) are reasonable defaults but may need tuning based on real usage

**Research date:** 2026-02-13
**Valid until:** 2026-03-15 (stable domain; Elixir OTP patterns don't change frequently)
