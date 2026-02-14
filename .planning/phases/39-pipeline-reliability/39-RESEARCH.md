# Phase 39: Pipeline Reliability - Research

**Researched:** 2026-02-14
**Domain:** Task pipeline fault tolerance (Elixir GenServer + Node.js sidecar)
**Confidence:** HIGH

## Summary

Phase 39 fixes the silent failure modes in the task execution pipeline. The codebase already has most of the infrastructure needed -- generation counters exist in TaskQueue, the stuck sweep runs every 30s in Scheduler, and the sidecar has crash recovery with a `recovering` slot. The work is primarily about closing gaps: the no-wake-command hang (line 98-103 in index.js), adding execution timeouts to `executeWithVerification`, improving the stuck sweep with agent-offline awareness, and adding reconnect state reporting.

No new libraries are needed. All changes are to existing modules in the Elixir hub and Node.js sidecar. The generation counter fencing (TASK-05) is already implemented -- we extend it rather than build from scratch.

**Primary recommendation:** Fix PIPE-07 (no-wake fail-fast) first as it is the most critical existing bug, then layer on the remaining reliability features in order of impact.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Fix PIPE-07 (no-wake fail-fast) first -- most critical existing bug
- PIPE-06 (per-iteration budget check) deferred to Phase 41
- Generation counters prevent ghost results
- Priority order: PIPE-07 -> PIPE-01 -> PIPE-02 -> PIPE-03 -> PIPE-04 -> PIPE-05

### Claude's Discretion
- Implementation details within each requirement
- Test structure and organization

### Deferred Ideas (OUT OF SCOPE)
- PIPE-06: Per-iteration budget check (deferred to Phase 41, needs agentic loop)
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir GenServer | OTP 26+ | Hub-side task queue, scheduler, agent FSM | Already in use, process timers for timeouts |
| Node.js ws | 8.x | Sidecar WebSocket client | Already in use for hub communication |
| Promise.race | Native | Execution timeout wrapper | Built-in, no dependencies needed |
| Process.send_after | OTP | Timer-based deadline enforcement | Erlang/OTP standard for GenServer timeouts |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| chokidar | 3.x | File watching (already used for result files) | Existing, no changes needed |

### Alternatives Considered
None -- all work is in existing modules with existing dependencies.

## Architecture Patterns

### Current Task Lifecycle (before Phase 39)
```
Hub: submit -> queued -> assigned -> [sidecar works] -> completed/failed
                                  -> [stuck 5min] -> reclaimed -> queued

Sidecar: task_assign -> accepted -> waking -> working -> task_complete/task_failed
                                 -> [no wake_command] -> HANGS FOREVER (BUG)
```

### Target Task Lifecycle (after Phase 39)
```
Hub: submit -> queued -> assigned -> [sidecar works] -> completed/failed
                                  -> [wake_result: failed] -> failed (retry/dead-letter)
                                  -> [execution timeout] -> failed (retry/dead-letter)
                                  -> [stuck 10min + agent offline] -> reclaimed -> queued
                                  -> [reconnect] -> state_report -> continue/requeue

Sidecar: task_assign -> accepted -> [no wake_command, no routing] -> FAIL FAST
                                 -> waking -> wake_result -> working -> task_complete
                                 -> [timeout] -> task_failed (timeout)
                                 -> [reconnect] -> state_report
```

### Pattern 1: Fail-Fast on Missing Prerequisites
**What:** Check preconditions before entering a work state; fail immediately with clear error rather than hanging.
**When to use:** When a required configuration (wake_command) is missing and no alternative execution path exists.
**Current code (BUG at sidecar/index.js:96-104):**
```javascript
// CURRENT: silently enters 'working' and hangs forever
if (!wakeCommand) {
    task.status = 'working';
    saveQueue(QUEUE_PATH, _queue);
    return;
}
```
**Fix:**
```javascript
// FIXED: fail immediately with clear error
if (!wakeCommand && (!routing || !routing.target_type || routing.target_type === 'wake')) {
    log('error', 'wake_command_missing', { task_id: task.task_id });
    task.status = 'failed';
    saveQueue(QUEUE_PATH, _queue);
    hub.sendTaskFailed(task.task_id, 'no_wake_command_configured');
    _queue.active = null;
    saveQueue(QUEUE_PATH, _queue);
    return;
}
```

### Pattern 2: Promise.race for Execution Timeout
**What:** Wrap async execution in `Promise.race` against a timeout promise to enforce wall-clock deadline.
**When to use:** Wrapping `executeWithVerification` in the sidecar's `executeTask` method.
**Example:**
```javascript
const TIMEOUT_MS = task.complexity?.effective_tier === 'trivial' ? 600000 : 1800000; // 10min or 30min
const timeoutPromise = new Promise((_, reject) =>
    setTimeout(() => reject(new Error('execution_timeout')), TIMEOUT_MS)
);
const result = await Promise.race([
    executeWithVerification(task, config, onProgress),
    timeoutPromise
]);
```

### Pattern 3: Agent-Aware Stuck Detection
**What:** Enhance the existing stuck sweep to check agent online status before reclaiming.
**When to use:** In `Scheduler.sweep_stuck` handler.
**Example:**
```elixir
# Current: reclaim if updated_at > 5 minutes ago
# Enhanced: reclaim if updated_at > threshold AND agent is offline/unresponsive
case AgentCom.AgentFSM.get_state(task.assigned_to) do
  {:error, :not_found} ->
    # Agent offline -- reclaim immediately if stale
    AgentCom.TaskQueue.reclaim_task(task.id)
  {:ok, %{fsm_state: :working}} ->
    # Agent online and working -- extend patience (use longer threshold)
    :ok
  _ ->
    # Agent in unexpected state -- reclaim if stale
    AgentCom.TaskQueue.reclaim_task(task.id)
end
```

### Pattern 4: Reconnect State Recovery
**What:** On WebSocket reconnect, sidecar sends a `state_report` message with its current task status; hub reconciles.
**When to use:** After successful `identify` in sidecar's `HubConnection`.
**Example (sidecar side):**
```javascript
// In HubConnection, after 'identified' message received:
if (_queue.active) {
    this.send({
        type: 'state_report',
        task_id: _queue.active.task_id,
        status: _queue.active.status,
        generation: _queue.active.generation
    });
}
```

### Anti-Patterns to Avoid
- **Silent state transitions with no error reporting:** The current no-wake-command bug. Always report failures to the hub.
- **Unbounded execution without timeouts:** The current `executeWithVerification` has no wall-clock limit. Always wrap in Promise.race.
- **Reclaiming tasks from actively-working online agents:** The stuck sweep should check agent liveness before reclaiming.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Execution timeout | Custom timer management | Promise.race with setTimeout | Built-in, clean cancellation semantics |
| Generation fencing | New fencing mechanism | Existing TaskQueue generation counter | Already implemented (TASK-05), just extend |
| Stuck detection | New monitoring system | Existing Scheduler stuck sweep | Already runs every 30s, just enhance the logic |
| Crash recovery | New persistence | Existing queue.json + recovering slot | Already handles sidecar crash, just add state_report |

**Key insight:** 90% of the infrastructure already exists. This phase is about closing gaps, not building new systems.

## Common Pitfalls

### Pitfall 1: Race Between Timeout and Completion
**What goes wrong:** Task completes just as timeout fires. Both `task_complete` and `task_failed(timeout)` are sent to hub.
**Why it happens:** Promise.race doesn't cancel the losing promise.
**How to avoid:** Use an `AbortController` or completion flag. After timeout fires, set a flag so the normal completion path is suppressed. After normal completion, clear the timeout.
**Warning signs:** Hub receives both task_complete and task_failed for same task_id with same generation.

### Pitfall 2: Stale Generation After Requeue
**What goes wrong:** Task is requeued (generation bumped), but old sidecar still sends results with old generation.
**Why it happens:** Sidecar doesn't know the task was requeued while it was disconnected.
**How to avoid:** Already handled by generation fencing in TaskQueue.complete_task. Hub rejects stale generation. Sidecar should also check generation in state_report response.
**Warning signs:** Frequent `stale_generation` errors in hub logs.

### Pitfall 3: Reconnect During Active Execution
**What goes wrong:** Sidecar reconnects and sends state_report for a task that's actively being executed. Hub requeues it. Old execution completes and sends results with stale generation.
**Why it happens:** Hub doesn't distinguish "reconnecting while working" from "reconnecting after crash."
**How to avoid:** Hub should check if the task is still assigned to this agent. If assigned and generation matches, continue waiting. Only requeue if agent was offline long enough.
**Warning signs:** Tasks being executed twice with conflicting results.

### Pitfall 4: Timer Leak on Sidecar Shutdown
**What goes wrong:** Execution timeout timer outlives the execution, causing unexpected failure reports.
**Why it happens:** `setTimeout` in Promise.race isn't cleaned up on normal completion.
**How to avoid:** Always `clearTimeout` the deadline timer when execution completes normally.
**Warning signs:** Memory leaks, phantom timeout errors after tasks complete.

## Code Examples

### Existing Generation Counter Usage (TaskQueue)
```elixir
# Already implemented in TaskQueue:
# - assign_task bumps generation
# - complete_task requires matching generation
# - fail_task requires matching generation
# - reclaim_task bumps generation
# This is the foundation for PIPE-04 (idempotent requeue)
```

### Existing Stuck Sweep (Scheduler)
```elixir
# Current implementation (scheduler.ex lines 193-215):
# - Runs every 30s
# - Threshold: 5 minutes (300_000ms)
# - Reclaims ALL stale assigned tasks regardless of agent status
# Phase 39 changes:
# - Reduce threshold to configurable (default 10min)
# - Check agent online status before reclaiming
# - Differentiate: agent offline = reclaim, agent online + working = extend patience
```

### Existing Recovery Flow (Sidecar)
```javascript
// Current crash recovery (index.js lines 1090-1097):
// - On startup, if queue.active exists, move to recovering slot
// - After identify, send task_recovering message
// Phase 39 adds:
// - state_report message on reconnect (not just crash recovery)
// - Hub reconciliation logic for state_report
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Silent hang on no wake_command | Fail-fast with error | Phase 39 | Tasks don't silently disappear |
| 5-min blind stuck sweep | Agent-aware stuck detection | Phase 39 | Reduced false reclaims |
| No execution timeout | Promise.race deadline | Phase 39 | Runaway tasks killed |
| Crash-only recovery | Reconnect state recovery | Phase 39 | Graceful reconnect handling |

## Open Questions

1. **Stuck threshold tuning**
   - What we know: Current threshold is 5 minutes. Context says 10 minutes for offline agents.
   - What's unclear: Should we have different thresholds for different task complexity tiers?
   - Recommendation: Start with single 10-minute threshold, add tier-based tuning in v2 if needed.

2. **Wake result protocol**
   - What we know: PIPE-01 requires a `wake_result` message within 10s.
   - What's unclear: Is the 10s timeout from the sidecar's perspective (after wake command exits) or from the hub's perspective (after task_assign)?
   - Recommendation: Hub starts timer on task_assign. Sidecar sends wake_result after wake command exits. Hub timer covers both "wake command slow" and "sidecar didn't send wake_result."

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `sidecar/index.js` (1126 lines) - full task lifecycle, wake command flow, recovery
- Codebase analysis: `lib/agent_com/task_queue.ex` (1129 lines) - generation fencing, retry/dead-letter, overdue sweep
- Codebase analysis: `lib/agent_com/scheduler.ex` (673 lines) - stuck sweep, fallback routing
- Codebase analysis: `lib/agent_com/agent_fsm.ex` (604 lines) - state transitions, acceptance timeout, disconnect handling
- Codebase analysis: `lib/agent_com/socket.ex` (705 lines) - WebSocket protocol, task lifecycle messages
- Codebase analysis: `sidecar/lib/execution/verification-loop.js` (250 lines) - executeWithVerification, no timeout
- Codebase analysis: `sidecar/lib/wake.js` (48 lines) - wake command execution, retry delays

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - no new dependencies, all existing modules
- Architecture: HIGH - patterns derived from existing codebase analysis
- Pitfalls: HIGH - race conditions and edge cases identified from code review

**Research date:** 2026-02-14
**Valid until:** 2026-03-14 (30 days, stable internal codebase)
