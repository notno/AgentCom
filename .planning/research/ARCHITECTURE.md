# Architecture Research

**Domain:** Distributed AI agent scheduler on Elixir/BEAM
**Researched:** 2026-02-09
**Confidence:** HIGH

## Standard Architecture

### System Overview

```
                        +-------------------------------------------------+
                        |                AgentCom Hub (BEAM)               |
                        |                                                 |
  LAYER 4: SCHEDULING   |  +------------+   +------------+                |
                        |  | Scheduler  |-->| TaskQueue   |----+          |
                        |  | (GenServer)|   | (GenServer) |    |          |
                        |  +-----+------+   +------------+    |          |
                        |        |                             v          |
                        |  +-----v--------+           +--------+--+      |
                        |  | AgentFSM     |           | DETS:     |      |
                        |  | (per-agent,  |           | tasks.dets|      |
                        |  |  Dynamic     |           +-----------+      |
                        |  |  Supervisor) |                               |
                        |  +-----+--------+                               |
                        |        |                                        |
  - - - - - - - - - - - | - - - -|- - - - - - - - - - - - - - - - - - -  |
                        |        |                                        |
  LAYER 3: STATE        |  +-----v----+  +----------+  +-----------+     |
  (existing v1)         |  | Presence  |  | Channels |  | Analytics |     |
                        |  +----------+  +----------+  +-----------+     |
                        |  +----------+  +----------+  +-----------+     |
                        |  | Auth     |  | Mailbox  |  | MsgHistory|     |
                        |  +----------+  +----------+  +-----------+     |
                        |                                                 |
  - - - - - - - - - - - | - - - - - - - - - - - - - - - - - - - - - - -  |
                        |                                                 |
  LAYER 2: MESSAGING    |  +------------------------------------------+  |
                        |  | Phoenix.PubSub   +  Elixir Registry      |  |
                        |  +------------------------------------------+  |
                        |                                                 |
  - - - - - - - - - - - | - - - - - - - - - - - - - - - - - - - - - - -  |
                        |                                                 |
  LAYER 1: TRANSPORT    |  +------------------------------------------+  |
                        |  | Bandit HTTP + WebSocket (Plug + WebSock)  |  |
                        |  +-----+-----------+----------+--------------+  |
                        +--------|-----------|----------|------------------+
                                 |           |          |
                        +--------v--+ +------v---+ +---v--------+
                        | Sidecar   | | Sidecar  | | Sidecar    |
                        | (Node.js) | | (Node.js)| | (Node.js)  |
                        | Agent A   | | Agent B  | | Agent C    |
                        +-----+-----+ +----+-----+ +-----+------+
                              |             |             |
                        +-----v-----+ +----v------+ +----v------+
                        | OpenClaw  | | OpenClaw  | | OpenClaw  |
                        | Session A | | Session B | | Session C |
                        +-----------+ +-----------+ +-----------+
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| **Scheduler** | Matches queued tasks to idle agents. Reacts to events (new task, agent idle, agent disconnect). Runs periodic stuck-check. | Singleton GenServer on the hub. Event-driven with a 30s timer sweep. |
| **TaskQueue** | Owns the global work queue. CRUD for tasks. Persists to DETS. Enforces priority ordering and retry semantics. | Singleton GenServer wrapping a DETS table (`priv/tasks.dets`). |
| **AgentFSM** | Per-agent work-state tracking (idle/assigned/working/done/failed/blocked). One process per connected agent. | GenServer under DynamicSupervisor, registered via Registry `{:via, Registry, {AgentCom.FSMRegistry, agent_id}}`. |
| **Sidecar** | Always-on WebSocket client per Mind. Receives task pushes, wakes OpenClaw session, forwards results back. Heartbeat. | Standalone Node.js process. One per agent machine. Connects to hub `/ws`. |
| **Presence** (existing) | Tracks connection state (online/offline). Broadcasts join/leave events. | Singleton GenServer. In-memory map. |
| **Transport** (existing) | HTTP API + WebSocket frame handling. Entry point for all external traffic. | Bandit + Plug.Router + WebSock. |
| **PubSub** (existing) | Decoupled event distribution. Topics: "messages", "presence", "channel:*", NEW: "scheduler". | Phoenix.PubSub. |
| **Auth** (existing) | Token generation, verification, agent identity. | Singleton GenServer. JSON-backed token store. |
| **Mailbox** (existing) | Offline message queue. Retained for backward compat during migration. | Singleton GenServer. DETS-backed. |

## Recommended Project Structure

```
lib/
├── agent_com/
│   ├── application.ex          # Supervisor tree (add DynamicSupervisor + new GenServers)
│   ├── endpoint.ex             # HTTP routes (add /api/tasks/* routes)
│   ├── socket.ex               # WebSocket handler (add task_assign/task_update frames)
│   ├── router.ex               # Message routing (unchanged)
│   │
│   ├── scheduler.ex            # NEW: Scheduler GenServer (matching + dispatch)
│   ├── task_queue.ex           # NEW: TaskQueue GenServer (DETS-backed task CRUD)
│   ├── task.ex                 # NEW: Task struct definition
│   ├── agent_fsm.ex            # NEW: Per-agent FSM GenServer
│   │
│   ├── auth.ex                 # existing
│   ├── mailbox.ex              # existing (retained for migration)
│   ├── presence.ex             # existing (consumed by AgentFSM)
│   ├── channels.ex             # existing
│   ├── config.ex               # existing
│   ├── analytics.ex            # existing
│   ├── message.ex              # existing
│   ├── message_history.ex      # existing
│   ├── threads.ex              # existing
│   ├── reaper.ex               # existing
│   ├── dashboard.ex            # existing (extend for v2 views)
│   └── plugs/
│       └── require_auth.ex     # existing
│
sidecar/                        # NEW: Node.js sidecar (separate from Elixir app)
├── index.js                    # WebSocket client, wake trigger, heartbeat
├── config.json                 # agent_id, token, hub_url, openclaw path
├── queue.json                  # Local task persistence (survives restart)
└── package.json
```

### Structure Rationale

- **Scheduler layer files live alongside existing GenServers in `lib/agent_com/`:** Follows the established flat module pattern. No subdirectory needed for 3-4 new files. Keeps the `AgentCom.*` namespace convention.
- **`task.ex` separate from `task_queue.ex`:** Struct definition stays separate from server logic, following the existing `message.ex` / `router.ex` pattern.
- **`sidecar/` at project root:** The sidecar is a Node.js process, not an Elixir module. It deploys to agent machines, not the hub. Keeping it at root makes this boundary clear.

## Architectural Patterns

### Pattern 1: Singleton GenServer for Global State (Scheduler, TaskQueue)

**What:** A single named GenServer process owns a domain of state and serializes all access through call/cast. The entire codebase already uses this pattern (Auth, Mailbox, Presence, Channels, Config, Analytics, MessageHistory, Threads).

**When to use:** For hub-global state that must be consistent. There is exactly one task queue and one scheduler in the system.

**Trade-offs:** Simple, race-free, proven in this codebase. Becomes a bottleneck only at very high throughput (thousands of operations per second), which is irrelevant for 4-5 agents.

**Example:**
```elixir
defmodule AgentCom.TaskQueue do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def create(attrs), do: GenServer.call(__MODULE__, {:create, attrs})
  def get(id), do: GenServer.call(__MODULE__, {:get, id})
  def update(id, changes), do: GenServer.call(__MODULE__, {:update, id, changes})
  def list_queued(), do: GenServer.call(__MODULE__, :list_queued)
  def list_by_status(status), do: GenServer.call(__MODULE__, {:list_by_status, status})
end
```

### Pattern 2: DynamicSupervisor + Registry for Per-Entity Processes (AgentFSM)

**What:** A DynamicSupervisor starts one GenServer process per connected agent, registered via an Elixir Registry with a via-tuple. When the agent disconnects, the FSM process terminates. When it reconnects, a new one starts.

**When to use:** When each entity (agent) needs its own state machine that runs concurrently with others. The number of entities varies at runtime.

**Trade-offs:** More moving parts than a single GenServer with a map of agent states. But the OTP approach gives each agent its own failure domain -- if one FSM crashes, others continue. Also enables per-agent timeouts and timers natively via `Process.send_after`.

**Confidence:** HIGH -- this is the canonical Elixir pattern for per-entity state. DynamicSupervisor, Registry, and GenServer are designed to work together this way.

**Example:**
```elixir
# In application.ex children list:
{DynamicSupervisor, name: AgentCom.FSMSupervisor, strategy: :one_for_one},
{Registry, keys: :unique, name: AgentCom.FSMRegistry},

# Starting an FSM when an agent connects:
defmodule AgentCom.AgentFSM do
  use GenServer

  def start_link(agent_id) do
    GenServer.start_link(__MODULE__, agent_id,
      name: {:via, Registry, {AgentCom.FSMRegistry, agent_id}})
  end

  def start_for(agent_id) do
    DynamicSupervisor.start_child(AgentCom.FSMSupervisor,
      {__MODULE__, agent_id})
  end

  def get_state(agent_id) do
    GenServer.call({:via, Registry, {AgentCom.FSMRegistry, agent_id}}, :get_state)
  end
end
```

### Pattern 3: Event-Driven Scheduler with Timer Sweep

**What:** The Scheduler GenServer reacts to discrete events (task created, agent idle, agent disconnected) and also runs a periodic timer to catch stuck assignments. It does NOT poll -- it is told when something changes.

**When to use:** When the system has a small number of well-defined events that change scheduling decisions. The existing PubSub infrastructure makes event delivery trivial.

**Trade-offs:** More responsive than pure polling. The timer sweep is a safety net, not the primary mechanism. Requires discipline: every code path that changes task or agent state must notify the scheduler.

**Example:**
```elixir
defmodule AgentCom.Scheduler do
  use GenServer

  @sweep_interval_ms 30_000

  def init(_) do
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "scheduler")
    schedule_sweep()
    {:ok, %{}}
  end

  # Event triggers
  def notify_task_created(task_id),
    do: GenServer.cast(__MODULE__, {:task_created, task_id})
  def notify_agent_idle(agent_id),
    do: GenServer.cast(__MODULE__, {:agent_idle, agent_id})
  def notify_agent_disconnected(agent_id),
    do: GenServer.cast(__MODULE__, {:agent_disconnected, agent_id})

  # All events funnel through try_schedule/1
  def handle_cast({:task_created, _task_id}, state) do
    try_schedule(state)
  end

  def handle_info(:sweep, state) do
    check_stuck_assignments()
    schedule_sweep()
    try_schedule(state)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```

## Data Flow

### Task Assignment Flow (Primary -- Push Model)

```
[Nathan / Flere / API Client]
    |
    | POST /api/tasks {title, description, priority, needed_capabilities}
    v
[Endpoint] --> [TaskQueue.create()] --> [DETS: tasks.dets]
    |
    | Scheduler.notify_task_created(task_id)
    v
[Scheduler.try_schedule()]
    |
    | 1. TaskQueue.list_queued()  --> sorted by priority, then created_at
    | 2. List idle AgentFSMs      --> via FSMRegistry
    | 3. Match: task.needed_capabilities vs agent.capabilities
    v
[AgentFSM.assign(agent_id, task)]
    |
    | 1. FSM state: :idle --> :assigned
    | 2. TaskQueue.update(task_id, %{status: :assigned, assigned_to: agent_id})
    | 3. Push via WebSocket: {"type": "task_assign", "task": {...}}
    v
[Sidecar receives task_assign]
    |
    | 1. Write to local queue.json
    | 2. Execute: openclaw cron wake --mode now
    v
[OpenClaw Session starts]
    |
    | Agent reads task from sidecar, does work
    | Agent reports progress via sidecar --> hub WebSocket
    v
[Sidecar sends task_update]
    |
    | {"type": "task_update", "task_id": "...", "status": "done", "result": {...}}
    v
[Socket.handle_msg() --> TaskQueue.update() + AgentFSM.complete()]
    |
    | 1. FSM state: :working --> :idle
    | 2. Task status: :working --> :done
    | 3. Scheduler.notify_agent_idle(agent_id)
    v
[Scheduler.try_schedule()] --> next task, if any
```

### Failure Recovery Flows

```
AGENT DISCONNECTS MID-TASK:
  Socket.terminate() called
    --> AgentFSM process terminates (DynamicSupervisor detects)
    --> Presence.unregister(agent_id) broadcasts {:agent_left, ...}
    --> Scheduler.notify_agent_disconnected(agent_id)
    --> Scheduler returns task to :queued (if retries remain)
    --> TaskQueue.update(task_id, %{status: :queued, retry_count: +1})
    --> Scheduler.try_schedule() runs for re-assignment

TASK TIMEOUT (stuck assignment):
  Scheduler :sweep timer fires every 30s
    --> Checks all :assigned/:working tasks
    --> If assigned_at > 5 minutes ago with no progress: mark :failed
    --> Return to queue if retries remain
    --> Notify via PubSub for dashboard

AGENT REJECTS TASK:
  Sidecar sends: {"type": "task_update", "status": "rejected", "reason": "..."}
    --> AgentFSM: :assigned --> :idle
    --> TaskQueue: :assigned --> :queued
    --> Scheduler.try_schedule() (skip that agent for this task)
```

### Key Data Flows

1. **Task lifecycle:** Created (queued) --> Assigned --> Working --> Done/Failed. All transitions go through TaskQueue GenServer. All state is DETS-backed and survives hub restart.
2. **Agent lifecycle:** Connect (FSM starts, :idle) --> Assigned --> Working --> Idle --> ... --> Disconnect (FSM terminates). FSM is volatile (in-memory). On reconnect after crash, any in-progress task is recovered from TaskQueue's persistent state.
3. **Scheduler-to-sidecar push:** Scheduler calls AgentFSM.assign() --> AgentFSM sends message via Registry PID lookup to the agent's Socket process --> Socket pushes WebSocket frame to sidecar.
4. **Backward-compatible v1 flow:** Agents without sidecars continue to use HTTP mailbox polling. The scheduler does not assign tasks to agents without active WebSocket connections. Both modes coexist.

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| 1-5 agents | Current architecture. Singleton GenServers. DETS. No optimization needed. |
| 5-20 agents | Monitor DETS write latency. Consider ETS + periodic DETS flush instead of direct DETS writes. Add telemetry to Scheduler.try_schedule() for timing. |
| 20-100 agents | Replace DETS with Mnesia or SQLite. DynamicSupervisor FSM count may need partitioning. Scheduler matching algorithm becomes O(tasks * agents) -- optimize with indexed data structures. |
| 100+ agents | Beyond current design scope. Would need distributed hub (multiple BEAM nodes), sharded scheduling, or external message broker. Not planned or needed. |

### Scaling Priorities

1. **First bottleneck: DETS write serialization.** DETS operations are disk I/O and serialized through the GenServer. At 4-5 agents this is invisible. At 20+ agents with frequent task state transitions, DETS becomes the chokepoint. Mitigation: buffer writes in ETS, flush to DETS on timer.
2. **Second bottleneck: Scheduler matching complexity.** Current algorithm is O(queued_tasks * idle_agents) per scheduling round. With 5 agents and 20 tasks this is 100 comparisons (instant). Becomes noticeable only with hundreds of tasks and dozens of agents.

## Anti-Patterns

### Anti-Pattern 1: Putting FSM State in a Shared Map

**What people do:** Store all agent states in a single GenServer as `%{agent_id => state}`, similar to how Presence currently works.

**Why it's wrong:** Conflates connection state with work state. A bug in one agent's state handling can corrupt the entire map. No per-agent timers or failure isolation. When one agent's FSM logic crashes, ALL agent state is lost and must be reconstructed.

**Do this instead:** Use DynamicSupervisor + Registry for per-agent FSM processes. Each agent gets its own failure domain, its own timers, and its own crash recovery. This is the OTP way.

### Anti-Pattern 2: Scheduler Polling Instead of Event-Driven

**What people do:** Run the scheduler on a fixed timer (every N seconds), scanning all tasks and all agents every cycle.

**Why it's wrong:** Wastes cycles when nothing changed. Adds latency (average half the poll interval) to task assignment. With a 30s interval, a task waits an average of 15s even when agents are idle.

**Do this instead:** React to events (task created, agent idle, agent disconnected) and use the timer only as a safety-net sweep for stuck assignments.

### Anti-Pattern 3: Sidecar Makes Decisions

**What people do:** Put scheduling logic, capability matching, or task prioritization in the sidecar.

**Why it's wrong:** Distributes state across multiple Node.js processes with no coordination. Creates split-brain scenarios where the hub and sidecars disagree on task assignments. Makes the system harder to reason about and debug.

**Do this instead:** The sidecar is a dumb relay. It maintains a WebSocket, receives task pushes, wakes OpenClaw, and forwards results. ALL intelligence stays on the hub where state is centralized and consistent.

### Anti-Pattern 4: Using DETS for High-Frequency Volatile State

**What people do:** Persist every FSM state transition to DETS.

**Why it's wrong:** FSM transitions happen frequently (every few seconds during active work). DETS writes are disk I/O. The FSM state is reconstructable from the TaskQueue on restart. Persisting it doubles write load for no durability benefit.

**Do this instead:** Keep AgentFSM state in-memory only. On hub restart, reconstruct agent states from TaskQueue (tasks with status :assigned/:working tell you which agents were working on what). The sidecar's local queue.json provides the other half of recovery state.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| OpenClaw sessions | Sidecar calls `openclaw cron wake --mode now` | Shell exec from Node.js. Sidecar must know path to openclaw binary. |
| GitHub (PRs) | Git wrapper script bundled with sidecar (Phase 5) | Not a direct integration. Wrapper enforces `git fetch && git checkout -b branch origin/main`. |
| Tailscale mesh | Network transport only | Hub and agents on same Tailscale network. No application-level integration needed. |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Scheduler <-> TaskQueue | Direct GenServer.call | Scheduler reads queue, updates task status. Synchronous. Same BEAM node. |
| Scheduler <-> AgentFSM | GenServer.call via Registry lookup | Scheduler assigns tasks to specific FSMs by agent_id. |
| AgentFSM <-> Socket | send(pid, {:task_push, task}) via Registry PID | FSM looks up agent's Socket PID in AgentRegistry, sends Erlang message. Socket pushes WebSocket frame. |
| Socket <-> Sidecar | WebSocket JSON frames | Same protocol as v1 identify/message, with new types: `task_assign`, `task_update`, `task_progress`. |
| Sidecar <-> OpenClaw | Shell exec + local filesystem | Sidecar writes task to `queue.json`, calls `openclaw cron wake`. OpenClaw reads task context, does work, writes result. Sidecar reads result, sends to hub. |
| TaskQueue <-> DETS | :dets.insert/select/delete | Same pattern as existing Mailbox module. Single DETS table for all tasks. |
| Scheduler <-> Presence | GenServer.call (read-only) | Scheduler reads Presence to know which agents are online. Does not modify Presence. |
| Dashboard <-> Scheduler/TaskQueue/FSM | GenServer.call (read-only) | Dashboard reads state from all three for rendering. No writes. |

## Component Interaction Matrix

Shows which components talk to which, and in what direction.

| | Scheduler | TaskQueue | AgentFSM | Presence | Socket | Sidecar | PubSub |
|---|---|---|---|---|---|---|---|
| **Scheduler** | -- | reads/writes | reads/writes | reads | -- | -- | subscribes |
| **TaskQueue** | notifies | -- | -- | -- | -- | -- | broadcasts |
| **AgentFSM** | notifies | -- | -- | reads | pushes to | -- | -- |
| **Presence** | -- | -- | -- | -- | -- | -- | broadcasts |
| **Socket** | notifies | writes | notifies | writes | -- | WebSocket | subscribes |
| **Sidecar** | -- | -- | -- | -- | WebSocket | -- | -- |
| **Endpoint** | -- | reads/writes | reads | reads | -- | -- | -- |

## Build Order and Dependencies

The build order is constrained by component dependencies. The scheduler cannot run without both a task queue AND agent FSMs. The FSMs are meaningful only when tasks exist to assign.

```
Phase 0: Sidecar ────────────────────────┐
   (no hub dependencies, can build        |
    and test standalone)                   |
                                          |
Phase 1: TaskQueue ──────────────────────┐|
   (no dependencies on new components,   ||
    parallel with Phase 0)               ||
                                         ||
Phase 2: AgentFSM ──────────┐           ||
   (depends on: TaskQueue    |           ||
    for recovery semantics)  |           ||
                             |           ||
Phase 3: Scheduler ──────────┤           ||
   (depends on: TaskQueue,   ├───────────┤|
    AgentFSM, Sidecar)       |           ||
                             |           ||
Phase 4: Dashboard v2 ──────┘           ||
   (depends on: TaskQueue,               ||
    AgentFSM, Scheduler for              ||
    data to display)                     ||
                                         ||
Phase 5: Git Wrapper ────────────────────┘|
   (depends on: Sidecar for               |
    deployment vehicle)                    |
                                           |
Phase 6: Onboarding Automation ────────────┘
   (depends on: Sidecar, Auth, everything working)
```

**Critical path:** Phase 0 + Phase 1 (parallel) --> Phase 2 --> Phase 3 --> smoke test.

**Build order implications for roadmap:**
- Phases 0 and 1 have zero dependencies on each other and can be built simultaneously.
- Phase 2 (AgentFSM) needs TaskQueue to exist for its recovery logic (on startup, check TaskQueue for assigned tasks to reconstruct state). However, a basic AgentFSM without recovery can be built before TaskQueue is fully done.
- Phase 3 (Scheduler) is the integration point. It cannot be built until Phases 0, 1, and 2 are complete. This is the critical gate.
- Phases 4, 5, and 6 are all downstream of Phase 3 and have no dependencies on each other.
- The smoke test (after Phase 3) is the quality gate. If 10 trivial tasks don't complete reliably across 2 agents, nothing after Phase 3 matters.

## Supervision Tree (v2)

```
AgentCom.Supervisor (:one_for_one)
├── Phoenix.PubSub (name: AgentCom.PubSub)
├── Registry (name: AgentCom.AgentRegistry)         # existing: WebSocket PIDs
├── Registry (name: AgentCom.FSMRegistry)            # NEW: AgentFSM PIDs
├── AgentCom.Config
├── AgentCom.Auth
├── AgentCom.Mailbox
├── AgentCom.Channels
├── AgentCom.Presence
├── AgentCom.Analytics
├── AgentCom.Threads
├── AgentCom.MessageHistory
├── AgentCom.Reaper
├── AgentCom.TaskQueue                               # NEW
├── AgentCom.Scheduler                               # NEW (must start after TaskQueue)
├── DynamicSupervisor (name: AgentCom.FSMSupervisor) # NEW
└── Bandit (plug: AgentCom.Endpoint)
```

**Ordering matters:** TaskQueue must start before Scheduler in the children list (OTP starts children in order). FSMSupervisor starts empty; FSM processes are added dynamically when agents connect.

## Sources

- [DynamicSupervisor -- Elixir v1.19.5](https://hexdocs.pm/elixir/DynamicSupervisor.html) -- official docs for DynamicSupervisor pattern (HIGH confidence)
- [GenStateMachine -- gen_state_machine v3.0.0](https://hexdocs.pm/gen_state_machine/GenStateMachine.html) -- Elixir wrapper for OTP gen_statem (HIGH confidence)
- [GenServer, Registry, DynamicSupervisor Combined](https://dev.to/unnawut/genserver-registry-dynamicsupervisor-combined-4i9p) -- practical walkthrough of per-entity GenServer pattern (MEDIUM confidence)
- [dets -- stdlib v7.2](https://www.erlang.org/doc/man/dets) -- official Erlang DETS documentation, 2GB limit, serialized writes (HIGH confidence)
- [Sidecar Pattern in Microservices](https://blog.bitsrc.io/implementing-the-sidecar-pattern-in-a-microservices-based-application-2ec3954fe9b6) -- general sidecar architecture reference (MEDIUM confidence)
- [Periodic Jobs in Elixir](https://www.theerlangelist.com/article/periodic) -- Process.send_after pattern for scheduled work (MEDIUM confidence)
- [State Timeouts with gen_statem](https://dockyard.com/blog/2020/01/31/state-timeouts-with-gen_statem) -- state timeout patterns applicable to FSM design (MEDIUM confidence)
- [How to Use Elixir for Distributed Systems](https://oneuptime.com/blog/post/2026-01-26-elixir-distributed-systems/view) -- BEAM distributed architecture overview (MEDIUM confidence)
- AgentCom v1 codebase -- `lib/agent_com/application.ex`, `socket.ex`, `presence.ex`, `mailbox.ex`, `router.ex`, `endpoint.ex` (HIGH confidence, primary source)
- AgentCom v2 implementation plan -- `docs/v2-implementation-plan.md` (HIGH confidence, project-specific design document)
- AgentCom v2 letter -- `docs/v2-letter.md` (HIGH confidence, project-specific requirements)
- AgentCom task protocol -- `docs/task-protocol.md` (HIGH confidence, existing protocol spec)

---
*Architecture research for: Distributed AI agent scheduler on Elixir/BEAM*
*Researched: 2026-02-09*
