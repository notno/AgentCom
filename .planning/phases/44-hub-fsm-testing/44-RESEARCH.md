# Phase 44: Hub FSM Testing - Research

**Researched:** 2026-02-14
**Domain:** Elixir integration testing (GenServer + Plug.Test)
**Confidence:** HIGH

## Summary

Phase 44 tests the complete HubFSM 5-state machine including healing cycles and HTTP control endpoints. The existing codebase already has established patterns for both GenServer integration tests (hub_fsm_test.exs) and HTTP endpoint tests (webhook_endpoint_test.exs) using Plug.Test. No new libraries or external dependencies are needed.

The key challenge is testing the healing state with real conditions (stuck tasks, health aggregation) without depending on external services (Ollama endpoints, git operations). The healing cycle spawns an async Task, so tests need to either send the `{:healing_cycle_complete, result}` message directly or use `force_transition/2` to control state.

**Primary recommendation:** Follow existing test patterns exactly. Use DetsHelpers for isolation, manual `send(pid, :tick)` for FSM control, Plug.Test for HTTP endpoints, and `force_transition/2` + direct message sending for healing state tests.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Real conditions, not mocks -- insert actual stuck tasks, real agent states
- Manual tick control -- `hub_fsm_tick_enabled: false` for deterministic tests
- Plug.Test for HTTP endpoints -- standard Elixir pattern, no HTTP server needed
- DetsHelpers isolation -- each test gets clean DETS state

### Claude's Discretion
- Test file organization (one file vs two)
- Specific assertion styles
- Helper function design

### Deferred Ideas (OUT OF SCOPE)
- None specified
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ExUnit | built-in | Test framework | Elixir standard |
| Plug.Test | built-in | HTTP request simulation | Standard for Plug-based apps |
| DetsHelpers | internal | DETS isolation per test | Project pattern from v1.1 |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Jason | existing | JSON encoding/decoding | HTTP response assertions |
| Process | built-in | Timer/message control | Manual tick, healing watchdog |

## Architecture Patterns

### Pattern 1: GenServer Integration Test (existing)
**What:** Stop/restart named GenServer from supervisor with DetsHelpers isolation
**When to use:** Testing HubFSM state transitions, healing cycles
**Example:** See `test/agent_com/hub_fsm_test.exs` -- setup block terminates child, clears history, restarts child

### Pattern 2: Plug.Test Endpoint Test (existing)
**What:** Build conn with Plug.Test.conn, pipe through endpoint, assert response
**When to use:** Testing HTTP hub endpoints
**Example:** See `test/agent_com/webhook_endpoint_test.exs` -- `Plug.Test.conn(:get, path) |> call_endpoint()`

### Pattern 3: Manual Tick Control
**What:** `hub_fsm_tick_enabled: false` in test.exs, then `send(Process.whereis(HubFSM), :tick)` for deterministic control
**When to use:** All FSM transition tests
**Example:** Already used in existing hub_fsm_test.exs

### Pattern 4: Force Transition for State Setup
**What:** `HubFSM.force_transition(:healing, "test setup")` to reach specific states quickly
**When to use:** Testing healing exit, watchdog, HTTP state endpoint in non-resting states

### Pattern 5: Direct Message for Cycle Completion
**What:** `send(pid, {:healing_cycle_complete, result})` to simulate healing cycle completion
**When to use:** Testing healing -> resting transition, cooldown behavior

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| DETS isolation | Custom temp dirs | DetsHelpers.full_test_setup/0 | Handles all 12 DETS paths + server restarts |
| Auth tokens | Manual token creation | AgentCom.Auth.generate/1 | Existing pattern from webhook tests |
| HTTP testing | httpc/hackney calls | Plug.Test.conn + endpoint.call | No server needed, synchronous |
| FSM state setup | Multiple ticks | force_transition/2 | Deterministic, no timing issues |

## Common Pitfalls

### Pitfall 1: ETS Table Ownership
**What goes wrong:** HubFSM owns the History ETS table. Terminating HubFSM destroys the table.
**Why it happens:** ETS tables are owned by the creating process.
**How to avoid:** Don't call History.clear() after terminating HubFSM in on_exit. The existing test already handles this correctly.

### Pitfall 2: Healing Cycle Async Task
**What goes wrong:** Healing cycle runs in a spawned Task that calls HealthAggregator.assess(), which calls real services.
**Why it happens:** `do_transition` spawns `Task.start(fn -> Healing.run_healing_cycle() end)` when entering :healing.
**How to avoid:** For healing tests, use `force_transition/2` to enter healing, then manually send `{:healing_cycle_complete, result}` to control the exit. Don't let the real healing cycle run (it would try to call Alerter, LlmRegistry, etc.).

### Pitfall 3: Watchdog Timer in Tests
**What goes wrong:** Healing watchdog is 5 minutes (300,000ms) -- too long for tests.
**Why it happens:** `@healing_watchdog_ms 300_000` is a module attribute.
**How to avoid:** For watchdog test, use `send(pid, :healing_watchdog)` directly instead of waiting. The handler checks `fsm_state == :healing` and force-transitions to resting.

### Pitfall 4: Auth for HTTP Endpoints
**What goes wrong:** POST /api/hub/pause and /api/hub/resume require auth.
**Why it happens:** RequireAuth plug checks Bearer token.
**How to avoid:** Generate token with `AgentCom.Auth.generate("test-agent")` and add header. GET endpoints (state, history) don't require auth.

### Pitfall 5: Process.sleep Timing
**What goes wrong:** Tests use Process.sleep(100) which can be flaky.
**Why it happens:** GenServer.call is synchronous but send() is async.
**How to avoid:** Use GenServer.call (get_state, force_transition) which are synchronous. Only need sleep after send() for tick/watchdog messages.

## Code Examples

### Setup Block (existing pattern)
```elixir
setup do
  tmp_dir = DetsHelpers.full_test_setup()
  try do
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.HubFSM)
  catch
    :exit, _ -> :ok
  end
  History.init_table()
  History.clear()
  {:ok, _pid} = Supervisor.restart_child(AgentCom.Supervisor, AgentCom.HubFSM)
  on_exit(fn ->
    try do
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.HubFSM)
    catch
      :exit, _ -> :ok
    end
    DetsHelpers.full_test_teardown(tmp_dir)
  end)
  {:ok, tmp_dir: tmp_dir}
end
```

### Healing State Test Pattern
```elixir
test "healing cycle completes and exits to resting" do
  pid = Process.whereis(HubFSM)
  :ok = HubFSM.force_transition(:healing, "test healing")
  assert HubFSM.get_state().fsm_state == :healing

  # Simulate healing completion
  send(pid, {:healing_cycle_complete, %{issues_found: 1, actions_taken: 1}})
  Process.sleep(100)

  assert HubFSM.get_state().fsm_state == :resting
end
```

### HTTP Endpoint Test Pattern
```elixir
defp call_endpoint(conn) do
  AgentCom.Endpoint.call(conn, AgentCom.Endpoint.init([]))
end

test "GET /api/hub/state returns FSM state" do
  conn = Plug.Test.conn(:get, "/api/hub/state") |> call_endpoint()
  assert conn.status == 200
  body = Jason.decode!(conn.resp_body)
  assert body["fsm_state"] == "resting"
end
```

## Open Questions

None -- all patterns are well-established in the existing codebase.

## Sources

### Primary (HIGH confidence)
- `test/agent_com/hub_fsm_test.exs` -- existing FSM test patterns
- `test/agent_com/webhook_endpoint_test.exs` -- existing Plug.Test patterns
- `lib/agent_com/hub_fsm.ex` -- FSM implementation with all handlers
- `lib/agent_com/hub_fsm/healing.ex` -- healing cycle implementation
- `lib/agent_com/health_aggregator.ex` -- health assessment source
- `lib/agent_com/endpoint.ex` -- HTTP hub endpoints (lines 1445-1565)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all internal, no new dependencies
- Architecture: HIGH -- exact patterns exist in codebase
- Pitfalls: HIGH -- identified from reading actual code

**Research date:** 2026-02-14
**Valid until:** 2026-03-14
