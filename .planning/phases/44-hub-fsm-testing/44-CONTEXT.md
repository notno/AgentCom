# Phase 44: Hub FSM Testing — Discussion Context

## Approach

Build integration tests for all 5 FSM states using real conditions (not mocks). Test full cycles, healing remediation, HTTP endpoints, and watchdog timeouts.

### Full Cycle Integration Tests
- New `test/agent_com/hub_fsm_integration_test.exs`
- Uses `hub_fsm_tick_enabled: false` and manual `send(pid, :tick)` for deterministic control
- DetsHelpers for isolated test environment

### Test Scenarios

**FSM Cycle Tests (TEST-01):**
- resting → executing → resting (basic goal execution cycle)
- resting → improving → contemplating → resting (improvement then contemplation)
- resting → improving → executing → resting (improvement discovers urgent work)
- Verify cycle_count increments, transition_count tracks, history records all transitions

**Healing Tests (TEST-02) — real conditions:**
- Insert stuck tasks into TaskQueue (assigned >10min ago, agent offline)
- Trigger tick → verify FSM enters :healing
- Verify TaskQueue.requeue called on stuck tasks
- Verify dead-letter after 3 retries (insert task with retry_count: 3)
- Verify healing exits to :resting
- Verify cooldown prevents immediate re-entry to :healing
- Verify watchdog timeout forces exit after 5 minutes

**HTTP Endpoint Tests (TEST-03):**
- `GET /api/hub/state` → returns JSON with `fsm_state`, `paused`, `cycle_count`
- `POST /api/hub/pause` (with auth) → returns ok, FSM paused
- `POST /api/hub/pause` (no auth) → returns 401
- `POST /api/hub/resume` → returns ok, FSM resumed
- `POST /api/hub/resume` (not paused) → returns error
- `GET /api/hub/history?limit=10` → returns transition entries

**Watchdog Tests (TEST-04):**
- Force FSM into :healing
- Do NOT send healing_cycle_complete
- Advance time or wait for watchdog timer
- Verify forced transition to :resting
- Verify critical alert fired

## Key Decisions

- **Real conditions, not mocks** — insert actual stuck tasks, real agent states. Tests validate the full stack.
- **Manual tick control** — `hub_fsm_tick_enabled: false` for deterministic tests
- **Plug.Test for HTTP endpoints** — standard Elixir pattern, no HTTP server needed
- **DetsHelpers isolation** — each test gets clean DETS state

## Files to Create

- NEW: `test/agent_com/hub_fsm_integration_test.exs` — cycle and healing tests
- NEW: `test/agent_com/hub_endpoint_test.exs` — HTTP endpoint tests (or add to existing endpoint test file)

## Dependencies

- **Phase 43** — Healing state must exist to test it

## Risks

- LOW — testing infrastructure already established in v1.1
- Healing tests with real conditions may be slower (DETS setup/teardown)
- Watchdog test needs to either use short timeout or mock timer

## Success Criteria

1. Tests exercise full FSM cycles (resting → executing → resting, etc.)
2. Tests trigger healing with real stuck tasks, verify remediation fires, confirm exit to resting
3. HTTP endpoints return correct responses with proper auth
4. Watchdog timeout test verifies forced transition after timeout
