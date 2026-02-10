# Phase 3: Agent State - Research

**Researched:** 2026-02-10
**Domain:** Elixir/OTP DynamicSupervisor, per-agent GenServer FSM, WebSocket disconnect detection, timer-based reclamation, structured capability routing
**Confidence:** HIGH

## Summary

Phase 3 introduces a per-agent finite state machine (FSM) that tracks each connected agent's work lifecycle. The core design is: one GenServer process per connected agent, dynamically spawned under a DynamicSupervisor when the agent connects via WebSocket, and terminated when the agent disconnects. Each agent GenServer owns its own state machine (offline -> idle -> assigned -> working -> done/failed/blocked) and coordinates with the existing TaskQueue via PubSub events and direct API calls.

The codebase currently has no DynamicSupervisor usage -- all GenServers are static children of the top-level Supervisor. Phase 3 introduces the first dynamic process pattern. The key architectural decision is whether to use a plain GenServer with pattern-matched state atoms (simple, consistent with codebase), or the `gen_state_machine` library wrapping OTP's `:gen_statem` (more formal FSM with built-in state timeouts). Given the small number of states (6), the simple transition rules, and the codebase's existing GenServer-everywhere pattern, a plain GenServer with a `%{fsm_state: atom}` field is the recommended approach. The `gen_state_machine` library adds a dependency for features (state-scoped timeouts, event postponement) that are not needed here.

The existing Presence module currently tracks connected agents with basic metadata (name, status, capabilities, connected_at, last_seen). Phase 3 replaces or wraps this with a richer per-agent process that owns both the presence data AND the FSM state. The existing Reaper module handles stale connection cleanup; Phase 3's disconnect handling (via WebSocket terminate callback + Process.monitor) provides more immediate cleanup than the Reaper's 60-second sweep, but the Reaper remains as a safety net.

**Primary recommendation:** Add a `DynamicSupervisor` named `AgentCom.AgentSupervisor` to the application supervision tree. When an agent connects (in Socket.do_identify), start a new `AgentCom.AgentFSM` GenServer under this supervisor. The AgentFSM GenServer monitors the WebSocket process (via `Process.monitor/1`); when the WebSocket dies, the AgentFSM receives a `:DOWN` message, immediately reclaims any assigned tasks back to the queue, transitions to `:offline`, and terminates itself. The 60-second acceptance timeout is implemented via `Process.send_after/3` within the AgentFSM, scheduled when a task is assigned. Use plain GenServer (not gen_state_machine) for FSM implementation, with state stored as a map field.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GenServer (OTP) | built-in | Per-agent FSM process managing state transitions | Already used by all 8+ stateful modules in codebase; consistent, well-understood |
| DynamicSupervisor (OTP) | built-in | Supervise dynamically-spawned per-agent GenServer processes | Standard OTP pattern for processes created at runtime; only `:one_for_one` strategy needed |
| Registry (OTP) | built-in | Look up AgentFSM process by agent_id | Already used for AgentRegistry (WebSocket pids); same pattern for FSM pids |
| Process.monitor (OTP) | built-in | Detect WebSocket process death for immediate disconnect handling | Standard OTP monitoring; lighter than links, unidirectional |
| Process.send_after (OTP) | built-in | 60-second acceptance timeout timer | Already used by Reaper and TaskQueue for periodic sweeps |
| Phoenix.PubSub | ~> 2.1 | Broadcast FSM state changes; subscribe to task events | Already in project; Socket already broadcasts on "presence" and "tasks" topics |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Jason | ~> 1.4 | JSON encode agent state for HTTP API responses | Already in project; all endpoints use it |
| :crypto (OTP) | built-in | No new usage | Existing usage for token/task ID generation unchanged |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Plain GenServer for FSM | `gen_state_machine` (wraps `:gen_statem`) | gen_state_machine provides formal state/data separation, state-scoped timeouts, event postponement. But it adds a hex dependency (last published Oct 2020, v3.0.0), the codebase uses GenServer everywhere, and the FSM here has only 6 states with simple transitions. GenServer with pattern-matched atoms is simpler and consistent. |
| Plain GenServer for FSM | Sasa Juric's `fsm` library | Pure functional FSM as a data structure. Elegant but adds dependency for a trivial state count. Pattern matching in GenServer achieves the same with zero dependencies. |
| DynamicSupervisor | Spawning raw processes with `spawn_link` | No supervision = no automatic restart, no clean shutdown, no observability. DynamicSupervisor is the standard OTP answer for dynamic processes. |
| Process.monitor for disconnect | Relying solely on Reaper sweep | Reaper checks every 30 seconds with a 60-second TTL. That means up to 90 seconds before a disconnected agent's tasks are reclaimed. Process.monitor gives immediate notification (milliseconds). Reaper remains as safety net. |
| Per-agent GenServer process | Single centralized FSM GenServer managing all agents | Single process becomes bottleneck and single point of failure. Per-agent processes isolate failures, allow concurrent state transitions, and are the idiomatic OTP approach. At 4-5 agents the performance difference is negligible, but the architecture is correct for scaling. |

**Installation:** No new dependencies required. Everything is OTP built-in or already in mix.exs. If `gen_state_machine` were chosen, it would require `{:gen_state_machine, "~> 3.0"}` in deps -- but this is NOT recommended.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  agent_fsm.ex           # NEW: Per-agent GenServer FSM (AGNT-01, AGNT-04)
  agent_supervisor.ex     # NEW: DynamicSupervisor for AgentFSM processes (AGNT-02)
  presence.ex             # MODIFIED: Delegate to AgentFSM for state queries, or keep as lightweight cache
  socket.ex               # MODIFIED: Start AgentFSM on identify, stop on terminate
  endpoint.ex             # MODIFIED: Add agent state query API endpoints (API-03)
  application.ex          # MODIFIED: Add AgentSupervisor + FSM Registry to children
```

### Pattern 1: DynamicSupervisor + Registry for Per-Agent Processes
**What:** Start one GenServer per connected agent under a DynamicSupervisor, registered in a dedicated Registry for lookup by agent_id.
**When to use:** Every agent connection lifecycle.

```elixir
# In application.ex -- add to children list BEFORE Bandit:
{Registry, keys: :unique, name: AgentCom.AgentFSMRegistry},
{DynamicSupervisor, name: AgentCom.AgentSupervisor, strategy: :one_for_one},

# Starting a per-agent FSM:
defmodule AgentCom.AgentFSM do
  use GenServer

  def start_link(args) do
    agent_id = Keyword.fetch!(args, :agent_id)
    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {AgentCom.AgentFSMRegistry, agent_id}})
  end
end

# In Socket.do_identify, after successful auth:
DynamicSupervisor.start_child(AgentCom.AgentSupervisor,
  {AgentCom.AgentFSM, [
    agent_id: agent_id,
    ws_pid: self(),
    name: name,
    capabilities: capabilities
  ]})

# Looking up an agent's FSM:
case Registry.lookup(AgentCom.AgentFSMRegistry, agent_id) do
  [{pid, _}] -> GenServer.call(pid, :get_state)
  [] -> {:error, :not_found}
end
```

**Restart strategy:** Use `restart: :temporary` in the child spec. When an agent disconnects and the FSM terminates, we do NOT want it restarted automatically -- a new FSM will be started when the agent reconnects. If the FSM crashes due to a bug, the Reaper will eventually clean up any stale presence entries, and the agent's sidecar will reconnect.

### Pattern 2: FSM State Machine in Plain GenServer
**What:** Track agent state as an atom field in the GenServer state map, with transition validation via pattern matching.
**When to use:** Every state transition.

```elixir
defmodule AgentCom.AgentFSM do
  use GenServer

  # Valid FSM transitions:
  # offline -> idle          (on connect)
  # idle -> assigned         (task assigned by scheduler)
  # assigned -> working      (agent accepts task)
  # assigned -> idle         (acceptance timeout -- task reclaimed)
  # working -> idle          (task completed -> done, then back to idle)
  # working -> idle          (task failed -> back to idle for retry by queue)
  # working -> blocked       (agent reports blocked)
  # blocked -> working       (agent resumes)
  # blocked -> idle          (task reclaimed)
  # any -> offline           (disconnect)

  @valid_transitions %{
    offline:  [:idle],
    idle:     [:assigned, :offline],
    assigned: [:working, :idle, :offline],
    working:  [:idle, :blocked, :offline],
    blocked:  [:working, :idle, :offline],
  }

  defstruct [
    :agent_id,
    :ws_pid,
    :ws_monitor_ref,
    :name,
    :capabilities,
    :connected_at,
    :last_state_change,
    :current_task_id,
    :acceptance_timer_ref,
    fsm_state: :idle,
    flags: []              # e.g., [:unresponsive] for AGNT-04
  ]

  def init(args) do
    ws_pid = Keyword.fetch!(args, :ws_pid)
    ref = Process.monitor(ws_pid)
    now = System.system_time(:millisecond)

    state = %__MODULE__{
      agent_id: Keyword.fetch!(args, :agent_id),
      ws_pid: ws_pid,
      ws_monitor_ref: ref,
      name: Keyword.get(args, :name, args[:agent_id]),
      capabilities: Keyword.get(args, :capabilities, []),
      connected_at: now,
      last_state_change: now,
      fsm_state: :idle
    }

    # Check if this agent has any assigned tasks in the queue
    check_existing_assignments(state)

    broadcast_state_change(state)
    {:ok, state}
  end

  defp transition(state, new_state) do
    valid = Map.get(@valid_transitions, state.fsm_state, [])
    if new_state in valid do
      now = System.system_time(:millisecond)
      updated = %{state | fsm_state: new_state, last_state_change: now}
      broadcast_state_change(updated)
      {:ok, updated}
    else
      {:error, {:invalid_transition, state.fsm_state, new_state}}
    end
  end
end
```

### Pattern 3: WebSocket Process Monitoring for Immediate Disconnect Detection
**What:** The AgentFSM monitors the WebSocket process. When the WebSocket dies (for any reason), the FSM immediately reclaims tasks and transitions to offline.
**When to use:** Handles AGNT-03 requirement.

```elixir
# In AgentFSM handle_info:
def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ws_monitor_ref: ref} = state) do
  # WebSocket process died -- agent disconnected
  Logger.warning("AgentFSM: #{state.agent_id} disconnected, reclaiming tasks")

  # Cancel any pending acceptance timer
  if state.acceptance_timer_ref do
    Process.cancel_timer(state.acceptance_timer_ref)
  end

  # Reclaim any assigned task back to queue
  if state.current_task_id do
    reclaim_task_to_queue(state.current_task_id, state.agent_id)
  end

  # Broadcast offline state
  broadcast_state_change(%{state | fsm_state: :offline})

  # Terminate self -- DynamicSupervisor with :temporary restart won't restart us
  {:stop, :normal, %{state | fsm_state: :offline}}
end

defp reclaim_task_to_queue(task_id, agent_id) do
  # Use TaskQueue to re-queue the task
  # TaskQueue.reclaim_from_agent/2 would be a new function that:
  # 1. Looks up the task
  # 2. If status is :assigned and assigned_to matches agent_id
  # 3. Resets to :queued, bumps generation, adds to priority index
  case AgentCom.TaskQueue.get(task_id) do
    {:ok, %{status: :assigned, assigned_to: ^agent_id} = task} ->
      AgentCom.TaskQueue.reclaim_task(task_id)
    _ ->
      :ok  # Task already completed or reassigned
  end
end
```

The `:DOWN` message is guaranteed by the BEAM runtime regardless of how the WebSocket process dies -- clean disconnect, network timeout, crash, or supervisor shutdown. This provides the "immediate state update" required by AGNT-03.

### Pattern 4: 60-Second Acceptance Timeout with Process.send_after
**What:** When a task is assigned to an agent, start a 60-second timer. If the agent does not accept (transition to :working) within that window, reclaim the task and flag the agent.
**When to use:** Handles AGNT-04 requirement.

```elixir
@acceptance_timeout_ms 60_000

# When task is assigned to this agent:
def handle_cast({:task_assigned, task_id, _task}, state) do
  {:ok, new_state} = transition(state, :assigned)

  # Start acceptance timer
  timer_ref = Process.send_after(self(), {:acceptance_timeout, task_id}, @acceptance_timeout_ms)

  {:noreply, %{new_state |
    current_task_id: task_id,
    acceptance_timer_ref: timer_ref
  }}
end

# When agent accepts the task:
def handle_cast({:task_accepted, task_id}, %{current_task_id: task_id} = state) do
  # Cancel the acceptance timer
  if state.acceptance_timer_ref do
    Process.cancel_timer(state.acceptance_timer_ref)
  end

  {:ok, new_state} = transition(state, :working)
  {:noreply, %{new_state | acceptance_timer_ref: nil}}
end

# Acceptance timeout fires:
def handle_info({:acceptance_timeout, task_id}, %{current_task_id: task_id} = state) do
  Logger.warning("AgentFSM: #{state.agent_id} did not accept task #{task_id} within #{@acceptance_timeout_ms}ms")

  # Reclaim the task
  reclaim_task_to_queue(task_id, state.agent_id)

  # Flag the agent as unresponsive
  {:ok, new_state} = transition(state, :idle)
  flagged = %{new_state |
    current_task_id: nil,
    acceptance_timer_ref: nil,
    flags: [:unresponsive | state.flags] |> Enum.uniq()
  }

  broadcast_state_change(flagged)
  {:noreply, flagged}
end

# Stale timeout (task already handled):
def handle_info({:acceptance_timeout, _old_task_id}, state) do
  {:noreply, state}
end
```

The `Process.cancel_timer/1` call prevents the timeout from firing if the agent accepts in time. If the timer fires after acceptance (race condition), the stale task_id guard clause handles it safely.

### Pattern 5: Structured Capability Declaration
**What:** Agents declare capabilities as a structured map on connect. The AgentFSM stores them and makes them queryable. Phase 4 (Scheduler) uses capabilities for task routing.
**When to use:** Handles API-03 requirement.

```elixir
# Capabilities are already sent in the identify message:
# {"type": "identify", "agent_id": "my-agent", "capabilities": ["search", "code"]}

# The existing Socket.do_identify already extracts capabilities:
capabilities = Map.get(msg, "capabilities", [])

# Phase 3 enhances this to support structured capabilities:
# Simple form (current): ["search", "code", "review"]
# Structured form (new):  [
#   %{"name" => "code", "languages" => ["elixir", "javascript"]},
#   %{"name" => "review", "max_files" => 50}
# ]
# Both forms should be supported. Simple strings are normalized to %{name: "capability"}.

# In AgentFSM, normalize capabilities on init:
defp normalize_capabilities(caps) when is_list(caps) do
  Enum.map(caps, fn
    cap when is_binary(cap) -> %{name: cap}
    cap when is_map(cap) -> cap
  end)
end

# Query API:
def get_capabilities(agent_id) do
  case Registry.lookup(AgentCom.AgentFSMRegistry, agent_id) do
    [{pid, _}] -> GenServer.call(pid, :get_capabilities)
    [] -> {:error, :not_found}
  end
end
```

### Pattern 6: Relationship Between AgentFSM and Existing Presence Module
**What:** Decide how AgentFSM coexists with the existing Presence GenServer.
**When to use:** Architecture decision affecting multiple modules.

**Recommended approach: AgentFSM becomes the source of truth; Presence becomes a read-through cache.**

The existing Presence module stores agent data in a single GenServer map. The new AgentFSM stores richer per-agent data in individual processes. Rather than duplicating state, Presence should be modified to query AgentFSM processes for current state:

```elixir
# Option A (recommended): Presence queries AgentFSM Registry
# Presence.list/0 becomes:
def list do
  AgentCom.AgentFSMRegistry
  |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  |> Enum.map(fn {agent_id, _pid} ->
    case AgentCom.AgentFSM.get_state(agent_id) do
      {:ok, state} -> state
      _ -> nil
    end
  end)
  |> Enum.reject(&is_nil/1)
end

# Option B: AgentFSM pushes updates to Presence on state change
# Presence remains a fast-read cache, AgentFSM calls Presence.update on each transition
# This is simpler but creates coupling.
```

**Recommendation:** Option B (AgentFSM pushes to Presence) is simpler for Phase 3. It preserves the existing Presence API that Socket and Endpoint already use, and avoids changing the Presence module's contract. The AgentFSM calls `Presence.register/2` on init and `Presence.update_status/2` on each state change. On disconnect, the existing `Socket.terminate` calls `Presence.unregister/1` as it does today.

### Pattern 7: TaskQueue Integration -- New reclaim_task Function
**What:** TaskQueue needs a new public function for agent disconnect reclamation, distinct from the existing overdue sweep.
**When to use:** When AgentFSM detects disconnect or acceptance timeout.

```elixir
# New function in TaskQueue:
@doc """
Reclaim a specific task from an agent. Used by AgentFSM on disconnect or timeout.
Resets task to :queued, bumps generation, re-adds to priority index.
Returns {:ok, task} or {:error, :not_found | :not_assigned}.
"""
def reclaim_task(task_id) do
  GenServer.call(__MODULE__, {:reclaim_task, task_id})
end

# In handle_call:
def handle_call({:reclaim_task, task_id}, _from, state) do
  case lookup_task(task_id) do
    {:ok, %{status: :assigned} = task} ->
      now = System.system_time(:millisecond)
      reclaimed = %{task |
        status: :queued,
        assigned_to: nil,
        assigned_at: nil,
        generation: task.generation + 1,
        updated_at: now,
        history: cap_history([{:reclaimed, now, "agent_disconnect"} | task.history])
      }
      persist_task(reclaimed, @tasks_table)
      new_index = add_to_priority_index(state.priority_index, reclaimed)
      broadcast_task_event(:task_reclaimed, reclaimed)
      {:reply, {:ok, reclaimed}, %{state | priority_index: new_index}}

    {:ok, _task} ->
      {:reply, {:error, :not_assigned}, state}

    {:error, :not_found} ->
      {:reply, {:error, :not_found}, state}
  end
end
```

### Anti-Patterns to Avoid
- **Single centralized FSM GenServer for all agents:** Serializes all agent state transitions through one process. Even at 4-5 agents this is architecturally wrong. Per-agent processes are the OTP way.
- **Using gen_state_machine for a 6-state FSM:** Adds a hex dependency (last published 2020) for features not needed. State-scoped timeouts and event postponement are gen_statem advantages that do not apply here. Process.send_after handles the one timeout (60s acceptance) perfectly.
- **Linking AgentFSM to WebSocket process instead of monitoring:** Links are bidirectional. If AgentFSM crashes, it would kill the WebSocket connection. Monitoring is unidirectional: WebSocket death notifies AgentFSM, but AgentFSM crash does not affect the WebSocket.
- **Storing FSM state in Presence instead of a dedicated process:** Presence is a single GenServer managing a map. Adding FSM logic, timers, and task coordination to it creates a god object. Per-agent processes cleanly own their own lifecycle.
- **Replacing Presence entirely in Phase 3:** Presence has a well-established API used by Socket, Endpoint, Reaper, and the dashboard. Replacing it risks breaking existing code. Instead, keep Presence as a cache updated by AgentFSM.
- **Making AgentFSM permanent (restart: :permanent):** Agent processes are inherently transient -- they exist only while the agent is connected. Using `:permanent` restart would create zombie FSM processes trying to restart for disconnected agents.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Dynamic process management | Custom process spawning with `spawn_link` | DynamicSupervisor.start_child/2 | Supervision, clean shutdown, observability, restart policies |
| Process lookup by name | Custom ETS table mapping agent_id -> pid | Registry with `:via` tuple | Already used in codebase (AgentRegistry); automatic cleanup on process death |
| Disconnect detection | Polling Presence for stale agents | Process.monitor/1 with :DOWN handler | Immediate notification (ms) vs polling interval (30-90s); guaranteed by BEAM |
| Timer management | Spawning Task processes for timeouts | Process.send_after/3 with Process.cancel_timer/1 | Standard OTP pattern; already used by Reaper and TaskQueue; cancelable |
| State machine validation | Ad-hoc state transitions without validation | @valid_transitions map with pattern-matched transition/2 function | Prevents invalid state transitions; documents valid transitions; easy to test |

**Key insight:** Phase 3 introduces the first DynamicSupervisor in the codebase, but otherwise uses the same GenServer + Registry + PubSub patterns already established. The complexity is in the coordination between processes (FSM, Socket, TaskQueue), not in new technology.

## Common Pitfalls

### Pitfall 1: Race Between WebSocket Identify and FSM Startup
**What goes wrong:** The WebSocket process calls `DynamicSupervisor.start_child` to create the AgentFSM, but messages arrive at the WebSocket before the FSM is fully initialized.
**Why it happens:** `start_child` is synchronous and blocks until `init/1` returns, but if `init/1` does async work (e.g., checking TaskQueue for existing assignments), there is a window.
**How to avoid:** Keep `init/1` synchronous and fast. Do not use `handle_continue` for critical initialization that must complete before messages arrive. The FSM should be fully initialized when `start_child` returns. If TaskQueue checks are needed, do them synchronously in `init/1` -- at 4-5 agents with maybe 10-20 tasks, this is fast (< 1ms).
**Warning signs:** WebSocket messages being handled before FSM is ready; "not found" errors when looking up a just-connected agent's FSM.

### Pitfall 2: Stale Acceptance Timer Firing After Task Completion
**What goes wrong:** Agent is assigned a task, starts working, completes the task, then 60 seconds later the acceptance timer fires and tries to reclaim a completed task.
**Why it happens:** The timer was not cancelled when the task was accepted or completed.
**How to avoid:** Always cancel the acceptance timer (`Process.cancel_timer/1`) when transitioning from `:assigned` to `:working`, and also when transitioning from `:working` to `:idle` (task done). Additionally, the timeout handler should guard on `current_task_id` matching -- if the task ID does not match, the timeout is stale and should be ignored.
**Warning signs:** Log messages about reclaiming tasks that are already completed; unexpected state transitions in agent history.

### Pitfall 3: AgentFSM and Socket Terminate Racing
**What goes wrong:** When a WebSocket disconnects, both `Socket.terminate/2` and `AgentFSM.handle_info(:DOWN, ...)` fire. Both try to call `Presence.unregister` and `TaskQueue.reclaim_task`, causing duplicate operations.
**Why it happens:** The WebSocket process terminating triggers both its own `terminate` callback and the monitor notification to AgentFSM.
**How to avoid:** Assign clear ownership: AgentFSM owns task reclamation and FSM state. Socket.terminate continues to handle Registry.unregister (for WebSocket pid) and Analytics.record_disconnect. Presence.unregister can be called by either -- it is idempotent (Map.delete on an already-deleted key is a no-op). TaskQueue.reclaim_task should also be idempotent (check assigned_to matches before reclaiming).
**Warning signs:** Duplicate "task reclaimed" events in PubSub; error logs from reclaiming already-reclaimed tasks.

### Pitfall 4: DynamicSupervisor Restart Thrashing
**What goes wrong:** If AgentFSM has a bug that causes it to crash repeatedly, DynamicSupervisor's max_restarts (default 3 in 5 seconds) triggers and shuts down the supervisor, taking ALL agent FSM processes down.
**Why it happens:** DynamicSupervisor is `:one_for_one` but still has a global restart intensity limit.
**How to avoid:** Use `restart: :temporary` in the AgentFSM child spec so crashed FSMs are NOT restarted. A crashed FSM for one agent should not affect other agents. The Reaper will eventually clean up the stale presence entry, and the sidecar will reconnect (creating a new FSM). Alternatively, set a generous `max_restarts` on the DynamicSupervisor (e.g., 100 in 60 seconds).
**Warning signs:** All agent FSMs dying simultaneously; DynamicSupervisor shutting down in error logs.

### Pitfall 5: Agent Reconnects Before Old FSM Terminates
**What goes wrong:** An agent disconnects and immediately reconnects. The old AgentFSM has not yet processed the `:DOWN` message and terminated. The new `start_child` call fails because the name is already registered.
**Why it happens:** Message processing is asynchronous. The old WebSocket process dies, but the `:DOWN` message is queued in the AgentFSM's mailbox behind other messages.
**How to avoid:** In `Socket.do_identify`, before starting a new FSM, check if one already exists for this agent_id. If so, stop it first: `DynamicSupervisor.terminate_child(AgentCom.AgentSupervisor, old_pid)`. This is a synchronous call that guarantees the old process is gone before starting the new one.
**Warning signs:** "already started" errors from DynamicSupervisor.start_child; agents unable to reconnect after disconnect.

### Pitfall 6: Capability Schema Evolving Without Backward Compatibility
**What goes wrong:** Phase 4 needs richer capability data than Phase 3 initially stores. Changing the capability format breaks existing agents.
**Why it happens:** Capabilities are sent by the sidecar at connect time. If the hub expects structured maps but the sidecar sends simple strings, or vice versa.
**How to avoid:** Support both formats from the start. Simple strings (`["code", "search"]`) are normalized to `[%{name: "code"}, %{name: "search"}]` on receipt. Structured maps are stored as-is. The normalization function is the single point of conversion. Phase 4 always queries normalized capabilities.
**Warning signs:** Nil or empty capabilities for connected agents; scheduler failing to match agents to tasks.

## Code Examples

Verified patterns from the existing codebase and OTP documentation:

### DynamicSupervisor Module (new)
```elixir
# Source: Standard OTP DynamicSupervisor pattern
# https://hexdocs.pm/elixir/DynamicSupervisor.html
defmodule AgentCom.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor for per-agent AgentFSM processes.
  One AgentFSM GenServer per connected agent.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start an AgentFSM for a newly connected agent."
  def start_agent(args) do
    DynamicSupervisor.start_child(__MODULE__, {AgentCom.AgentFSM, args})
  end

  @doc "Stop an AgentFSM (e.g., on reconnect before old FSM terminates)."
  def stop_agent(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
```

### Application Supervision Tree Changes
```elixir
# Source: Existing lib/agent_com/application.ex pattern
# Add these children AFTER AgentRegistry, BEFORE Bandit:
{Registry, keys: :unique, name: AgentCom.AgentFSMRegistry},
{AgentCom.AgentSupervisor, []},
```

### AgentFSM Child Spec with :temporary restart
```elixir
# Source: OTP child_spec documentation
# In AgentFSM module:
def child_spec(args) do
  %{
    id: {__MODULE__, Keyword.fetch!(args, :agent_id)},
    start: {__MODULE__, :start_link, [args]},
    restart: :temporary,   # Do NOT restart on crash -- agent must reconnect
    type: :worker
  }
end
```

### Socket Integration (modified do_identify)
```elixir
# Source: Existing lib/agent_com/socket.ex do_identify pattern
defp do_identify(agent_id, msg, state) do
  name = Map.get(msg, "name", agent_id)
  status = Map.get(msg, "status", "connected")
  capabilities = Map.get(msg, "capabilities", [])

  # Handle reconnect: stop old FSM if it exists
  case Registry.lookup(AgentCom.AgentFSMRegistry, agent_id) do
    [{old_pid, _}] ->
      AgentCom.AgentSupervisor.stop_agent(old_pid)
    [] -> :ok
  end

  # Start new AgentFSM
  {:ok, _fsm_pid} = AgentCom.AgentSupervisor.start_agent([
    agent_id: agent_id,
    ws_pid: self(),
    name: name,
    capabilities: capabilities
  ])

  # Rest of existing identify logic (Registry, PubSub, etc.)
  Registry.register(AgentCom.AgentRegistry, agent_id, %{pid: self()})
  Presence.register(agent_id, %{name: name, status: status, capabilities: capabilities})
  # ... subscriptions, analytics ...
end
```

### HTTP API Endpoint for Agent State (API-03)
```elixir
# Source: Existing endpoint.ex pattern for /api/agents
get "/api/agents/:agent_id/state" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    case AgentCom.AgentFSM.get_state(agent_id) do
      {:ok, agent_state} ->
        send_json(conn, 200, %{
          "agent_id" => agent_state.agent_id,
          "fsm_state" => to_string(agent_state.fsm_state),
          "current_task_id" => agent_state.current_task_id,
          "capabilities" => agent_state.capabilities,
          "flags" => Enum.map(agent_state.flags, &to_string/1),
          "connected_at" => agent_state.connected_at,
          "last_state_change" => agent_state.last_state_change
        })
      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "agent_not_found"})
    end
  end
end

# List all agents with FSM state:
get "/api/agents/states" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    states = AgentCom.AgentFSM.list_all()
    send_json(conn, 200, %{"agents" => states})
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Presence GenServer tracking freeform status strings | Per-agent FSM GenServer with validated state transitions | Phase 3 (this phase) | Agent lifecycle becomes a formal state machine; invalid transitions are rejected |
| Reaper-based stale agent cleanup (30-90s delay) | Process.monitor for immediate disconnect detection | Phase 3 (this phase) | Task reclamation drops from 30-90 seconds to milliseconds on disconnect |
| No acceptance timeout for assigned tasks | 60-second timer with automatic reclamation and flagging | Phase 3 (this phase) | Unresponsive agents cannot hold tasks indefinitely; scheduler (Phase 4) can avoid flagged agents |
| Capabilities stored as metadata in Presence map | Structured capabilities in per-agent FSM, queryable for routing | Phase 3 (this phase) | Phase 4 scheduler can match tasks to agents by capability |
| All GenServers are static children of top-level Supervisor | DynamicSupervisor for per-agent processes | Phase 3 (this phase) | First dynamic process pattern in codebase; establishes pattern for future dynamic children |

**Deprecated/outdated:**
- The Presence module's role shrinks but it should NOT be removed. It provides a fast, centralized read path for agent lists. AgentFSM pushes state updates to Presence, and Presence continues to serve existing API consumers (/api/agents, Socket list_agents handler, dashboard).
- The Reaper module remains as a safety net for edge cases where Process.monitor does not catch stale agents (e.g., FSM itself crashes before processing :DOWN). Its 30/60 second interval is now a fallback, not the primary mechanism.

## Integration Points

### With Phase 2 (TaskQueue) -- Dependency
Phase 3 depends on Phase 2 and needs these TaskQueue capabilities:

**Already exists:**
- `tasks_assigned_to(agent_id)` -- Used by AgentFSM on init to check for existing assignments
- PubSub events on "tasks" topic -- AgentFSM can subscribe to track task events
- `update_progress(task_id)` -- Socket continues to call this on task_progress messages

**Needs to be added:**
- `reclaim_task(task_id)` -- New function for explicit task reclamation by AgentFSM (distinct from overdue sweep). Could potentially reuse existing reclamation logic from the sweep but exposed as a public API call.

### With Phase 1 (Sidecar) -- Already Complete
The sidecar sends `task_accepted` when it starts working on a task. Phase 3 uses this signal to transition the agent from `:assigned` to `:working` and cancel the acceptance timer. No sidecar changes needed.

### With Phase 4 (Scheduler) -- Future Consumer
Phase 4 needs from AgentFSM:
- `list_idle_agents()` -- Find agents in `:idle` state for task assignment
- `get_capabilities(agent_id)` -- Match task requirements to agent capabilities
- `assign_task(agent_id, task_id)` -- Transition agent to `:assigned` and start acceptance timer
- `is_flagged?(agent_id, :unresponsive)` -- Check if agent should be skipped by scheduler

### With Existing Modules
- **Socket:** Starts AgentFSM on identify, notifies AgentFSM of task events (task_accepted, task_complete, task_failed)
- **Presence:** Receives state updates from AgentFSM; continues to serve list/get queries
- **Reaper:** Remains as safety net; no changes needed
- **Endpoint:** New API routes for agent state queries

## Open Questions

1. **Should AgentFSM subscribe to PubSub "tasks" topic, or should Socket forward task events to AgentFSM?**
   - What we know: Socket already handles task_accepted, task_complete, task_failed messages. AgentFSM needs to know about these events to update its state.
   - What's unclear: Whether AgentFSM should subscribe to PubSub directly (decoupled but potentially redundant) or Socket should forward events (simpler but tighter coupling).
   - Recommendation: Socket forwards task events to AgentFSM via GenServer.cast. Socket already parses these messages and has the agent_id in state. This avoids AgentFSM having to filter PubSub events for its own agent. Keep it simple.

2. **Should the "done" and "failed" states be transient or stable?**
   - What we know: AGNT-01 lists states as: offline, idle, assigned, working, done, failed, blocked. The requirement says "done" and "failed" are states.
   - What's unclear: How long an agent stays in "done" or "failed" before transitioning back to "idle."
   - Recommendation: Make "done" and "failed" transient -- they represent task completion outcomes, not agent states. After task_complete, transition to idle immediately (ready for next task). After task_failed, transition to idle immediately (TaskQueue handles retry logic). The task status is stored in TaskQueue; the agent just needs to be ready for work. If the requirement truly needs visible done/failed, use a very brief transient state (100ms) before auto-transitioning to idle, or store last_outcome in FSM data without it being the FSM state. **This simplification reduces states from 6 to 5: idle, assigned, working, blocked, offline.** The Phase 4 scheduler needs to know idle vs busy, not the outcome of the last task.

3. **Should the AgentFSM store task history or just current state?**
   - What we know: TaskQueue already stores full task history. AgentFSM tracks current task.
   - What's unclear: Whether agent-level history (last N tasks worked on) is needed.
   - Recommendation: Store only current state in AgentFSM. Task history belongs in TaskQueue. If needed later, add a query that joins TaskQueue data filtered by agent_id. Do not duplicate data.

4. **How should the existing /api/agents endpoint change?**
   - What we know: Currently returns Presence data (agent_id, name, status, capabilities, connected_at). Phase 3 adds FSM state.
   - What's unclear: Whether to modify the existing endpoint or add a new one.
   - Recommendation: Enhance existing `/api/agents` response to include `fsm_state` field. Add a new `/api/agents/:id/state` endpoint for detailed FSM state including current_task_id, flags, and last_state_change. This preserves backward compatibility while exposing new data.

## Sources

### Primary (HIGH confidence)
- AgentCom codebase -- direct examination of presence.ex, reaper.ex, socket.ex, task_queue.ex, application.ex, endpoint.ex, analytics.ex, channels.ex, router.ex (all architecture patterns, existing APIs, supervision tree)
- [DynamicSupervisor documentation (Elixir v1.19.5)](https://hexdocs.pm/elixir/DynamicSupervisor.html) -- start_link options, start_child/2, restart strategies, init/1 callback
- [GenServer documentation (Elixir v1.19.5)](https://hexdocs.pm/elixir/GenServer.html) -- Process.monitor/1, handle_info :DOWN pattern, Process.send_after/3
- [WebSock behaviour documentation (v0.5.3)](https://hexdocs.pm/websock/WebSock.html) -- terminate/2 callback, disconnect reasons, connection lifecycle
- Phase 2 research (.planning/phases/02-task-queue/02-RESEARCH.md) -- TaskQueue API, DETS patterns, PubSub integration
- ROADMAP.md -- Phase dependencies, requirement IDs, success criteria

### Secondary (MEDIUM confidence)
- [GenStateMachine documentation (v3.0.0)](https://hexdocs.pm/gen_state_machine/GenStateMachine.html) -- callback modes, state transitions, timer features (evaluated and rejected)
- [gen_state_machine on hex.pm](https://hex.pm/packages/gen_state_machine) -- version 3.0.0, published Oct 2020, 44M+ downloads
- [Monitoring WebSocket disconnections in Phoenix](https://medium.com/@fxn/monitoring-websocket-disconnections-in-phoenix-bbe24f54d996) -- Process.monitor pattern for WebSocket processes, supervision tree placement
- [GenServer, Registry, DynamicSupervisor Combined](https://dev.to/unnawut/genserver-registry-dynamicsupervisor-combined-4i9p) -- Integration pattern for per-connection processes
- [DynamicSupervisors for concurrent fault-tolerant workflows](https://www.thegreatcodeadventure.com/how-we-used-elixirs-genservers-dynamic-supervisors-to-build-concurrent-fault-tolerant-workflows/) -- DynamicSupervisor + Registry patterns

### Tertiary (LOW confidence)
- None -- all findings verified against official docs, codebase, or multiple credible sources

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- zero new dependencies; DynamicSupervisor, Registry, Process.monitor are all core OTP/Elixir
- Architecture: HIGH -- per-agent GenServer under DynamicSupervisor is the canonical OTP pattern for dynamic processes; Socket/Presence integration patterns derived from existing codebase
- Pitfalls: HIGH -- race conditions and coordination issues are well-known patterns in OTP; solutions (monitor vs link, :temporary restart, idempotent operations) are established best practices
- Integration points: HIGH -- TaskQueue API directly examined; Socket message handlers directly examined; clear boundaries between modules

**Research date:** 2026-02-10
**Valid until:** 2026-03-10 (30 days -- stable domain, OTP patterns are extremely mature)
