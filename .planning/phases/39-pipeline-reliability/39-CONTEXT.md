# Phase 39: Pipeline Reliability — Discussion Context

## Approach

Fix the silent failure modes in the task execution pipeline. Priority order: fail-fast for missing wake_command (PIPE-07), then wake ack (PIPE-01), then timeouts (PIPE-02), then stuck task recovery (PIPE-03), then generation counters (PIPE-04), then reconnect recovery (PIPE-05). PIPE-06 (per-iteration budget check) deferred to Phase 41.

### PIPE-07: No-wake-command fail-fast (HIGHEST PRIORITY)
- `sidecar/index.js` lines 96-104: if no `wake_command` and no `routing_decision`, immediately fail task with clear error
- Currently sets status to 'working' and does nothing — permanent hang

### PIPE-01: Wake failure recovery
- Sidecar sends `wake_result` message (success/failure) within 10s of wake attempt
- Hub starts timer on assignment; if no `wake_result` received, requeue task
- Reuse/extend existing `acceptance_timeout` mechanism

### PIPE-02: Task-level timeout
- Wrap `executeWithVerification` in `Promise.race` with configurable deadline
- Default: 30min for agentic tasks, 10min for simple tasks (from complexity tier)
- On timeout: kill execution, report `timeout` failure, requeue if retries remain

### PIPE-03: Stuck task detection + auto-requeue
- Extend existing scheduler stuck sweep
- Add retry counter to task schema
- Dead-letter after 3 retries (configurable)
- Reduce stuck threshold from 5min to configurable (default 10min)

### PIPE-04: Idempotent requeue with generation counters
- Add `assignment_generation` field to task schema
- Increment on each assign
- Sidecar checks generation before executing — skip if stale
- Hub checks generation before accepting results — discard if stale

### PIPE-05: Sidecar reconnect state recovery
- On WebSocket reconnect, sidecar sends `state_report` with current status
- Hub reconciles: continue waiting, accept late result, or requeue

### PIPE-06: Per-iteration budget check
- DEFERRED to Phase 41 (needs agentic loop to exist)

## Key Decisions

- **PIPE-06 deferred to Phase 41** — depends on the agentic loop existing
- **Fix PIPE-07 first** — it's the most critical existing bug (silent task hang)
- **Generation counters prevent ghost results** — important for robustness when tasks get requeued

## Files to Modify

### Sidecar (JavaScript)
- `sidecar/index.js` — wake fail-fast, wake ack, reconnect state report, generation check
- `sidecar/lib/wake.js` — wake result reporting
- `sidecar/lib/execution/dispatcher.js` — task-level timeout wrapper

### Hub (Elixir)
- `lib/agent_com/scheduler.ex` — wake ack timeout, stuck sweep improvements
- `lib/agent_com/task_queue.ex` — generation counter, retry counter, dead-letter
- `lib/agent_com/agent_fsm.ex` — reconnect state reconciliation
- `lib/agent_com/endpoint.ex` — state_report WebSocket handler

## Risks

- MEDIUM — touches both hub and sidecar, cross-cutting changes
- WebSocket protocol changes need careful coordination
- Generation counter adds complexity to task lifecycle

## Success Criteria

1. Task with missing/failing wake_command immediately fails (not silently stuck)
2. Agentic task exceeding 30min deadline is killed and requeued
3. Task stuck >10min with offline agent is automatically requeued
4. Sidecar reconnecting after disconnect reports state, hub reconciles
5. Task exhausting iteration budget saves partial results with partial_pass status
