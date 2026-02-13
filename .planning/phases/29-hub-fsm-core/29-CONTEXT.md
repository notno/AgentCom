# Phase 29: Hub FSM Core - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

HubFSM singleton GenServer -- the autonomous brain. 4 states (Executing, Improving, Contemplating, Resting) with queue-driven and event-driven transitions. Pause/resume API. Transition history. Dashboard integration (state display).

Research consensus: use GenServer (not GenStateMachine) matching existing AgentFSM pattern.
</domain>

<decisions>
## Implementation Decisions

### FSM Implementation
- GenServer with explicit state atom tracking (matches existing AgentFSM pattern)
- @valid_transitions map defines allowed state changes
- Transition predicates are pure functions: can_transition?(current_state, system_state) -> new_state | :stay
- Comprehensive timer cancellation on every transition to prevent state corruption

### State Transitions
- Queue-driven: check GoalBacklog and TaskQueue state to determine next state
- Event-driven: PubSub subscriptions to "goals", "tasks", "presence" topics
- Resting -> Executing: when goal backlog has pending goals
- Executing -> Resting: when goal queue empty AND no active goals
- Resting -> Improving: when idle for configurable duration, or git event received
- Improving -> Contemplating: when no improvements found across all repos
- Contemplating -> Resting: when max 3 proposals written or no ideas generated
- Any state -> Resting: when cost budget exhausted

### Parallel Goal Processing
- Hub processes multiple independent goals simultaneously
- Before decomposing a new goal, check: does it depend on anything currently executing?
- Dependency detection as preprocessing step (file overlap, keyword analysis)

### Build Strategy
- Start with 2-state core (Executing + Resting), prove the loop works
- Expand to 4 states after core loop is stable
- Success criterion 5 explicitly calls for this incremental approach

### Safety
- Pause/resume API: POST /api/hub/pause, POST /api/hub/resume
- Paused state overrides all transitions -- hub does nothing until resumed
- Watchdog timer: if stuck in any state > 2 hours, force-transition to Resting with alert
- All state changes logged with timestamp and reason

### Claude's Discretion
- Timer durations for idle-to-improving transition
- Event debouncing strategy (multiple rapid PubSub events)
- Whether to use Process.send_after or :timer for periodic checks
- Supervision tree placement (after GoalBacklog, ClaudeClient, Scheduler)
</decisions>

<specifics>
## Specific Ideas

- FSM should emit telemetry on every state transition
- Consider a "cycle count" to track how many execute-improve-contemplate-rest cycles have run
- State history stored in ETS for fast dashboard reads (last N transitions)
</specifics>

<constraints>
## Constraints

- Depends on Phase 25 (CostLedger), Phase 26 (ClaudeClient), Phase 27 (GoalBacklog)
- Must be a singleton -- only one HubFSM process
- Must integrate with existing PubSub topics without disrupting current subscribers
- Defensive timer management to prevent Pitfall #3 (state corruption)
</constraints>
