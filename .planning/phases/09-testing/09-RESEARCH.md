# Phase 9: Testing Infrastructure - Research

**Researched:** 2026-02-11
**Domain:** Elixir ExUnit testing, GenServer unit tests, DETS isolation, WebSocket integration tests, Node.js sidecar tests, GitHub Actions CI
**Confidence:** HIGH

<user_constraints>

## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Test Isolation Strategy
- Standard Elixir approach: sequential tests (`async: false`) with shared global GenServer names
- State reset via setup/teardown blocks between tests -- no GenServer name injection refactoring
- DETS paths in `Config` and `Threads` must be refactored to use temp directories during tests (targeted fix, not full name injection)
- Full test factory module with convenience functions: `create_agent()`, `submit_task()`, `connect_websocket()`, etc.

#### Coverage Priorities
- Tiered by risk: deep tests for critical path (TaskQueue, AgentFSM, Scheduler, Auth, Socket), basic tests for lower-risk modules (Analytics, Threads, MessageHistory)
- Two levels of integration tests:
  - Internal API tests calling GenServer functions directly (fast, thorough)
  - One full WebSocket end-to-end test for the complete task lifecycle (realistic)
- Failure path integration tests: timeout, crash, retry, dead-letter

#### Sidecar Testing Approach
- Unit tests with mocked WebSocket for individual modules (queue, git workflow, wake trigger)
- One integration test against real Elixir hub for the connection flow
- Git workflow tests use real temp git repos (not mocked git commands)

#### Test Execution & CI
- Test file organization mirrors source structure (standard Elixir convention)
- GitHub Actions CI runs both Elixir (`mix test`) and Node.js sidecar tests on push/PR
- CI only -- no pre-commit hooks (agents shouldn't be slowed by test runs)

### Claude's Discretion
- DETS state reset approach (fresh temp dir per module vs shared with table clearing)
- Node.js test framework choice (built-in `node:test` vs Jest)
- Which edge cases from pitfalls research warrant dedicated test cases vs coverage through normal tests
- WebSocket test client implementation (`:gun`, custom GenServer, or `WebSockAdapter`)

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope

</user_constraints>

## Summary

This phase creates comprehensive test infrastructure for AgentCom, an Elixir OTP application with 15+ GenServer modules backed by DETS persistence, a WebSocket-based agent protocol, and a Node.js sidecar. The codebase currently has zero unit tests -- only smoke tests that require a running hub instance. The primary challenge is DETS isolation: 5 modules (Config, Threads, Mailbox, Channels, MessageHistory) use hardcoded or partially-configurable DETS paths that can collide between test runs and production data.

The existing codebase is well-structured for testing. Most GenServer modules use `Application.get_env` for DETS paths (TaskQueue, Auth, Mailbox, MessageHistory, Channels), meaning only Config and Threads need refactoring. The project already has `fresh ~> 0.4.4` (Mint-based WebSocket client) in `:dev/:test` deps, and the smoke test suite includes a fully-functional `Smoke.AgentSim` GenServer that connects via Mint.WebSocket -- this can serve as the foundation for WebSocket integration tests. The sidecar (`sidecar/index.js`) is a monolithic 880-line file, but its functions are reasonably separable for unit testing.

**Primary recommendation:** Use `Application.get_env` with `config/test.exs` to redirect ALL DETS paths to `System.tmp_dir!/0`-based directories, with per-test fresh temp dirs created in `setup` blocks. For sidecar tests, use `node:test` (built-in, zero deps, stable in Node 22). For WebSocket test clients, build a lightweight helper atop Mint.WebSocket (already proven in `Smoke.AgentSim`), avoiding new deps.

## Standard Stack

### Core (Elixir)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ExUnit | (stdlib) | Test framework | Built into Elixir; `async: false` + `setup/teardown` is standard for stateful GenServer tests |
| Mint.WebSocket | ~> 1.0 (via fresh) | WebSocket test client | Already in deps via `fresh ~> 0.4.4`; proven working in `Smoke.AgentSim` |
| Phoenix.PubSub | ~> 2.1 | Test PubSub subscriptions | Already in production deps; subscribe in tests to verify event flow |

### Core (Node.js Sidecar)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| node:test | (stdlib) | Test runner + mocking | Built into Node 22 (stable since v20); zero deps, native mocking via `mock.fn()`/`mock.module()` |
| node:assert | (stdlib) | Assertions | Built-in strict assertions; `assert.strictEqual`, `assert.deepStrictEqual`, `assert.rejects` |

### CI
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| erlef/setup-beam | v1 | Install Elixir/OTP in CI | Official BEAM setup action; supports OTP 28 + Elixir 1.19 |
| actions/setup-node | v4 | Install Node.js in CI | Official Node setup action; supports Node 22 |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Mint.WebSocket (for WS tests) | `:gun` (Erlang HTTP/WS client) | gun is powerful but under-documented for Elixir, adds new dep; Mint already proven in this codebase |
| Mint.WebSocket (for WS tests) | `WebSockex` | Older library, less actively maintained; Mint ecosystem is more modern |
| `node:test` | Jest | Jest adds 50+ transitive deps, slower startup; node:test has mocking, describe/it, coverage built-in |
| fresh temp dirs (DETS isolation) | Table-level clearing via `:dets.delete_all_objects/1` | Clearing leaves the DETS file open with same name; fresh temp dirs guarantee zero collision and automatic OS cleanup |

**Discretion Decisions:**

1. **DETS reset approach:** Use **fresh temp dir per test module** (not per individual test). Rationale: Per-test dirs would create hundreds of temp dirs for large test suites; per-module dirs are sufficient since tests run sequentially (`async: false`) with explicit state reset in `setup` blocks. The temp dir is created in `setup_all`, and each `setup` block clears DETS tables or restarts the GenServer.

2. **Node.js test framework:** Use **`node:test`** (built-in). Rationale: Node 22 has full mocking (`mock.fn`, `mock.module`), describe/it syntax, coverage, and watch mode. Zero npm install needed. The sidecar has only 3 production deps; adding Jest would triple the dependency tree for no real benefit.

3. **WebSocket test client:** Use **Mint.WebSocket directly** via a slimmed-down helper extracted from `Smoke.AgentSim`. Rationale: The existing `AgentSim` already handles the full WebSocket handshake, frame encoding/decoding, and message handling. Extracting a simpler `AgentCom.TestHelpers.WsClient` module avoids new deps and leverages proven code.

**No installation needed** -- all Elixir tools are in stdlib or existing deps. For sidecar, no new npm packages required.

## Architecture Patterns

### Recommended Test Structure
```
test/
  test_helper.exs                    # ExUnit config, test env setup
  agent_com/
    task_queue_test.exs              # Unit: TaskQueue GenServer
    agent_fsm_test.exs               # Unit: AgentFSM lifecycle
    scheduler_test.exs               # Unit: Scheduler matching + events
    auth_test.exs                    # Unit: Auth token CRUD
    config_test.exs                  # Unit: Config get/put
    presence_test.exs                # Unit: Presence register/list
    analytics_test.exs               # Unit: Analytics counters
    threads_test.exs                 # Unit: Thread walk/collect
    message_history_test.exs         # Unit: History store/query
    mailbox_test.exs                 # Unit: Mailbox enqueue/poll/ack
    channels_test.exs                # Unit: Channel CRUD + publish
    message_test.exs                 # Unit: Message struct
    router_test.exs                  # Unit: Router routing logic
    reaper_test.exs                  # Unit: Reaper sweep
  integration/
    task_lifecycle_test.exs          # GenServer-level: submit -> schedule -> assign -> complete
    failure_paths_test.exs           # GenServer-level: timeout, crash, retry, dead-letter
    websocket_e2e_test.exs           # Full WebSocket: connect -> identify -> task -> complete
  support/
    test_factory.ex                  # Factory functions: create_agent, submit_task, etc.
    ws_client.ex                     # Lightweight WebSocket test client (Mint-based)
    dets_helpers.ex                  # DETS temp dir setup/teardown
```

### Pattern 1: DETS Isolation via Application.get_env + Temp Dirs

**What:** Configure all DETS-backed modules to read their paths from `Application.get_env`, then override those paths in `config/test.exs` to use temp directories.

**When to use:** Every test module that touches DETS-backed GenServers.

**Current State of DETS Path Configuration:**

| Module | Config Key | Status |
|--------|-----------|--------|
| TaskQueue | `:task_queue_path` | Already uses `Application.get_env` |
| Auth | `:tokens_path` | Already uses `Application.get_env` |
| Mailbox | `:mailbox_path` | Already uses `Application.get_env` |
| MessageHistory | `:message_history_path` | Already uses `Application.get_env` |
| Channels | `:channels_path` | Already uses `Application.get_env` |
| **Config** | **(none -- hardcoded)** | **NEEDS REFACTORING: uses `System.get_env("HOME")`** |
| **Threads** | **(none -- hardcoded)** | **NEEDS REFACTORING: uses `System.get_env("HOME")`** |

**Refactoring needed for Config module (config.ex:61-65):**
```elixir
# BEFORE (hardcoded):
defp data_dir do
  dir = Path.join([System.get_env("HOME") || ".", ".agentcom", "data"])
  File.mkdir_p!(dir)
  dir
end

# AFTER (configurable):
defp data_dir do
  dir = Application.get_env(:agent_com, :config_data_dir,
    Path.join([System.get_env("HOME") || ".", ".agentcom", "data"]))
  File.mkdir_p!(dir)
  dir
end
```

**Refactoring needed for Threads module (threads.ex:137-141):**
```elixir
# BEFORE (hardcoded):
defp dets_path(name) do
  dir = Path.join([System.get_env("HOME") || ".", ".agentcom", "data"])
  File.mkdir_p!(dir)
  Path.join(dir, name <> ".dets") |> String.to_charlist()
end

# AFTER (configurable):
defp dets_path(name) do
  dir = Application.get_env(:agent_com, :threads_data_dir,
    Path.join([System.get_env("HOME") || ".", ".agentcom", "data"]))
  File.mkdir_p!(dir)
  Path.join(dir, name <> ".dets") |> String.to_charlist()
end
```

**config/test.exs pattern:**
```elixir
import Config

# All DETS paths go to tmp during tests -- overridden per-test with fresh dirs
config :agent_com,
  port: 4002,
  task_queue_path: "tmp/test/task_queue",
  tokens_path: "tmp/test/tokens.json",
  mailbox_path: "tmp/test/mailbox.dets",
  message_history_path: "tmp/test/message_history.dets",
  channels_path: "tmp/test/channels",
  config_data_dir: "tmp/test/config",
  threads_data_dir: "tmp/test/threads"
```

**Per-test-module setup pattern:**
```elixir
defmodule AgentCom.TaskQueueTest do
  use ExUnit.Case, async: false

  setup do
    # Create fresh temp dir for this test
    tmp_dir = Path.join(System.tmp_dir!(), "agentcom_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Point DETS path to fresh dir
    Application.put_env(:agent_com, :task_queue_path, Path.join(tmp_dir, "task_queue"))

    # Restart the GenServer to pick up new paths
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.TaskQueue)
    Supervisor.restart_child(AgentCom.Supervisor, AgentCom.TaskQueue)

    on_exit(fn ->
      # Stop GenServer, cleanup temp files
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.TaskQueue)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "submit creates a queued task" do
    {:ok, task} = AgentCom.TaskQueue.submit(%{description: "test task"})
    assert task.status == :queued
    assert task.priority == 2  # "normal" default
  end
end
```

### Pattern 2: GenServer Unit Test Structure

**What:** Test each GenServer by calling its public API directly (not through HTTP/WebSocket), verifying return values and side effects.

**When to use:** All 13 GenServer modules.

**Example -- TaskQueue unit test:**
```elixir
test "submit and get round-trips a task" do
  {:ok, task} = AgentCom.TaskQueue.submit(%{
    description: "test task",
    priority: "high",
    submitted_by: "test-agent"
  })

  assert task.id =~ ~r/^task-[a-f0-9]{16}$/
  assert task.status == :queued
  assert task.priority == 1  # "high" -> 1

  {:ok, fetched} = AgentCom.TaskQueue.get(task.id)
  assert fetched.id == task.id
  assert fetched.description == "test task"
end

test "assign_task transitions queued -> assigned" do
  {:ok, task} = AgentCom.TaskQueue.submit(%{description: "test"})
  {:ok, assigned} = AgentCom.TaskQueue.assign_task(task.id, "agent-1")

  assert assigned.status == :assigned
  assert assigned.assigned_to == "agent-1"
  assert assigned.generation == 1
end

test "complete_task requires correct generation" do
  {:ok, task} = AgentCom.TaskQueue.submit(%{description: "test"})
  {:ok, assigned} = AgentCom.TaskQueue.assign_task(task.id, "agent-1")

  # Wrong generation
  assert {:error, :stale_generation} =
    AgentCom.TaskQueue.complete_task(task.id, 999, %{result: "done"})

  # Correct generation
  {:ok, completed} = AgentCom.TaskQueue.complete_task(
    task.id, assigned.generation, %{result: "done"}
  )
  assert completed.status == :completed
end
```

### Pattern 3: AgentFSM Testing with Process Monitoring

**What:** AgentFSM requires a `ws_pid` to monitor. In tests, use `self()` or a spawned dummy process.

**When to use:** All AgentFSM tests.

**Example:**
```elixir
test "FSM starts in :idle state" do
  # Spawn a dummy process to act as the WebSocket pid
  ws_pid = spawn(fn -> Process.sleep(:infinity) end)

  {:ok, _fsm_pid} = AgentCom.AgentSupervisor.start_agent([
    agent_id: "test-agent-1",
    ws_pid: ws_pid,
    name: "Test Agent",
    capabilities: ["code"]
  ])

  {:ok, state} = AgentCom.AgentFSM.get_state("test-agent-1")
  assert state.fsm_state == :idle
  assert state.capabilities == [%{name: "code"}]

  # Cleanup: kill the dummy ws_pid to trigger FSM cleanup
  Process.exit(ws_pid, :kill)
  Process.sleep(50)  # Allow FSM to process :DOWN
end
```

### Pattern 4: Integration Tests via GenServer API

**What:** Test the full task lifecycle by calling GenServer APIs directly, without WebSocket overhead.

**When to use:** Integration tests for submit -> schedule -> assign -> complete pipeline.

**Example:**
```elixir
test "full lifecycle: submit -> schedule -> assign -> accept -> complete" do
  # 1. Register a fake agent in Presence (Scheduler checks idle agents)
  ws_pid = spawn(fn -> Process.sleep(:infinity) end)
  {:ok, _} = AgentCom.AgentSupervisor.start_agent([
    agent_id: "int-agent", ws_pid: ws_pid, capabilities: []
  ])
  AgentCom.Presence.register("int-agent", %{name: "Integration Agent", status: "idle"})

  # 2. Subscribe to task events to observe scheduling
  Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

  # 3. Submit task -- Scheduler should react to :task_submitted
  {:ok, task} = AgentCom.TaskQueue.submit(%{description: "integration test"})

  # 4. Wait for Scheduler to assign (it reacts to PubSub events)
  assert_receive {:task_event, %{event: :task_assigned, task_id: task_id}}, 5_000
  assert task_id == task.id

  # 5. Verify task is now assigned
  {:ok, assigned} = AgentCom.TaskQueue.get(task.id)
  assert assigned.status == :assigned
  assert assigned.assigned_to == "int-agent"

  # 6. Complete the task
  {:ok, completed} = AgentCom.TaskQueue.complete_task(
    task.id, assigned.generation, %{result: "done"}
  )
  assert completed.status == :completed

  # Cleanup
  Process.exit(ws_pid, :kill)
end
```

### Pattern 5: WebSocket E2E Test

**What:** Connect via actual WebSocket, identify, receive task, complete it.

**When to use:** One comprehensive E2E test validating the real protocol.

**Note:** Requires the full application running (Bandit HTTP server on test port). The existing `Smoke.AgentSim` pattern using Mint.WebSocket is the proven approach.

### Pattern 6: Sidecar Unit Tests with node:test

**What:** Extract testable functions from `index.js`, test with built-in `node:test` + mocked WebSocket.

**When to use:** Queue management, wake trigger logic, git workflow functions.

**Example -- queue management:**
```javascript
import { describe, it, beforeEach, afterEach, mock } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

describe('Queue Manager', () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-'));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it('loadQueue returns empty on missing file', () => {
    const queuePath = path.join(tmpDir, 'queue.json');
    // loadQueue should return { active: null, recovering: null }
    // when file doesn't exist
  });

  it('saveQueue persists atomically', () => {
    const queuePath = path.join(tmpDir, 'queue.json');
    const queue = { active: { task_id: 'test-1', status: 'accepted' }, recovering: null };
    // saveQueue writes, loadQueue reads back identically
  });
});
```

### Anti-Patterns to Avoid

- **`async: true` with GenServer tests:** All GenServer tests MUST use `async: false`. GenServers are registered by global name; concurrent tests would collide.
- **`Process.sleep` for synchronization:** Use `assert_receive` with timeout for PubSub events, or polling helpers (like existing `Smoke.Assertions.wait_for`) instead of fixed sleeps.
- **Testing GenServers through HTTP:** Unit tests should call GenServer APIs directly (`AgentCom.TaskQueue.submit/1`), not go through the HTTP endpoint. HTTP endpoint tests are a separate concern.
- **Mocking GenServer internals:** Test the public API contract, not internal state. Don't reach into GenServer state with `:sys.get_state/1` in normal tests.
- **Sharing DETS files between test modules:** Each test module must have its own temp directory. DETS file locks prevent concurrent access, and leftover state causes flaky tests.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| WebSocket test client | Raw TCP socket manipulation | Mint.WebSocket (via existing `fresh` dep) | WebSocket framing, masking, upgrade handshake are complex; Mint handles it correctly |
| Test factory | Ad-hoc setup blocks in each test | Dedicated `TestFactory` module | DRY; changes to agent/task creation propagate to all tests |
| DETS temp dir lifecycle | Manual `File.mkdir_p!`/`File.rm_rf!` in every test | Shared `DetsHelpers` setup macro | Consistent cleanup, prevents leaked temp dirs |
| Assertion polling | `Process.sleep(N)` + check | `wait_for/2` helper (existing pattern in `Smoke.Assertions`) | Fixed sleeps are either too slow or too flaky |
| CI Elixir/OTP setup | Manual apt-get install | `erlef/setup-beam` GitHub Action | Handles version matrix, caching, OTP/Elixir compatibility |
| Node.js mocking | Custom mock objects | `node:test` built-in `mock.fn()`, `mock.module()` | Full call tracking, automatic cleanup, timer mocking included |

**Key insight:** The existing smoke test infrastructure (`Smoke.AgentSim`, `Smoke.Setup`, `Smoke.Assertions`, `Smoke.Http`) already solves many hard problems (WebSocket client, state reset, polling assertions). Extract and adapt these patterns rather than rebuilding from scratch.

## Common Pitfalls

### Pitfall 1: DETS Table Name Collision
**What goes wrong:** DETS tables are opened with atom names (`:task_queue`, `:agent_mailbox`, etc.). If a test opens a table that's already open from the running application, `:dets.open_file/2` either returns the existing table or fails.
**Why it happens:** Tests run inside the full OTP application. All GenServers are already started by `Application.start`.
**How to avoid:** Don't open DETS tables directly in tests. Instead, restart the GenServer with new paths:
```elixir
Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.TaskQueue)
# Change Application.get_env path here
Supervisor.restart_child(AgentCom.Supervisor, AgentCom.TaskQueue)
```
**Warning signs:** `{:error, {:already_open, ...}}` from DETS, or tests passing individually but failing in batch.

### Pitfall 2: AgentFSM Registry Leaks
**What goes wrong:** AgentFSM processes register in `AgentCom.AgentFSMRegistry`. If a test creates an FSM but doesn't clean it up, the next test finds a stale registration.
**Why it happens:** FSMs use `restart: :temporary` and only stop on `:DOWN` from the ws_pid or explicit termination.
**How to avoid:** Always kill the dummy ws_pid in `on_exit` to trigger FSM cleanup, or explicitly call `AgentCom.AgentSupervisor.stop_agent/1`.
**Warning signs:** `{:error, {:already_started, pid}}` when starting an FSM with the same agent_id.

### Pitfall 3: Scheduler Side Effects in Unit Tests
**What goes wrong:** The Scheduler subscribes to PubSub and reacts to task/presence events. When unit-testing TaskQueue.submit (which broadcasts `:task_submitted`), the Scheduler may try to schedule the task, causing unexpected state changes.
**Why it happens:** The Scheduler is running as part of the OTP application during tests.
**How to avoid:** For unit tests that need isolation from Scheduler, stop it before the test:
```elixir
setup do
  Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.Scheduler)
  on_exit(fn -> Supervisor.restart_child(AgentCom.Supervisor, AgentCom.Scheduler) end)
end
```
For integration tests, leave the Scheduler running -- it's part of what you're testing.
**Warning signs:** Tasks appearing as `:assigned` when you expected `:queued`.

### Pitfall 4: Timer-Based Tests Are Flaky
**What goes wrong:** AgentFSM has a 60-second acceptance timeout. TaskQueue has a 30-second sweep interval. Tests that rely on these timers are slow and flaky.
**Why it happens:** Real timer values are designed for production, not testing.
**How to avoid:** For timer-dependent behavior, send the timer message directly:
```elixir
# Instead of waiting 60s for acceptance timeout:
send(fsm_pid, {:acceptance_timeout, task_id})
```
For sweep_overdue in TaskQueue:
```elixir
send(task_queue_pid, :sweep_overdue)
```
**Warning signs:** Tests that take > 30 seconds or fail intermittently under CI load.

### Pitfall 5: Infinite Recursion in Threads.walk_to_root
**What goes wrong:** If a message's `reply_to` field points to a non-existent message that isn't `nil`, `walk_to_root/1` looks up the message, gets `nil`, and returns the message_id (correct). BUT if a circular reply chain exists (A replies to B, B replies to A), it loops forever.
**Why it happens:** No cycle detection in `walk_to_root/1`.
**How to avoid:** Write a specific test case for circular reply chains. This is a known bug worth testing even if not fixed in this phase.
**Warning signs:** Test hangs indefinitely.

### Pitfall 6: Unprotected String.to_integer in Endpoint
**What goes wrong:** `endpoint.ex` lines 215, 352-358, 438-441 call `String.to_integer/1` on query params without guards. Non-numeric input causes `ArgumentError` crash.
**Why it happens:** Query params from HTTP are always strings; missing input validation.
**How to avoid:** Write test cases that send non-numeric values to these endpoints to document the failure. These may be fixed in a later hardening phase, but the tests should exist.
**Warning signs:** 500 errors on malformed query parameters.

### Pitfall 7: PubSub Timing in Tests
**What goes wrong:** A test subscribes to PubSub, triggers an action, but the broadcast was sent before the subscription took effect.
**Why it happens:** PubSub subscription is async; there's a race between `subscribe` and `broadcast`.
**How to avoid:** Subscribe BEFORE triggering the action. Use `assert_receive` with generous timeouts (5_000ms) rather than `receive` blocks.
**Warning signs:** Intermittent `assert_receive` timeouts.

### Pitfall 8: Sidecar Monolithic index.js
**What goes wrong:** Trying to `require('./index.js')` in tests loads the entire sidecar including `main()` which immediately connects to the hub.
**Why it happens:** The sidecar is structured as a script, not a module.
**How to avoid:** Extract testable functions into separate modules (e.g., `queue.js`, `wake.js`) that can be imported independently. OR, for the initial phase, test functions by duplicating/adapting them in test files, then refactor to modules later.
**Warning signs:** Tests that fail because they try to connect to a non-existent hub on import.

## Code Examples

### Example 1: Test Helper -- DETS Isolation Setup

```elixir
# test/support/dets_helpers.ex
defmodule AgentCom.TestHelpers.DetsHelpers do
  @moduledoc "Helpers for creating isolated DETS directories in tests."

  @doc """
  Create a fresh temp directory and configure all DETS-backed modules to use it.
  Returns the temp dir path. Call `cleanup_dets/1` in on_exit.
  """
  def setup_test_dets do
    tmp_dir = Path.join(System.tmp_dir!(), "agentcom_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Configure all DETS-backed modules
    Application.put_env(:agent_com, :task_queue_path, Path.join(tmp_dir, "task_queue"))
    Application.put_env(:agent_com, :tokens_path, Path.join(tmp_dir, "tokens.json"))
    Application.put_env(:agent_com, :mailbox_path, Path.join(tmp_dir, "mailbox.dets"))
    Application.put_env(:agent_com, :message_history_path, Path.join(tmp_dir, "message_history.dets"))
    Application.put_env(:agent_com, :channels_path, Path.join(tmp_dir, "channels"))
    Application.put_env(:agent_com, :config_data_dir, Path.join(tmp_dir, "config"))
    Application.put_env(:agent_com, :threads_data_dir, Path.join(tmp_dir, "threads"))

    tmp_dir
  end

  @doc "Restart all DETS-backed GenServers to pick up new paths."
  def restart_dets_servers do
    # Order matters: stop dependents first (Scheduler depends on TaskQueue)
    servers = [
      AgentCom.Scheduler,
      AgentCom.TaskQueue,
      AgentCom.MessageHistory,
      AgentCom.Mailbox,
      AgentCom.Channels,
      AgentCom.Threads,
      AgentCom.Config
    ]

    for server <- servers do
      Supervisor.terminate_child(AgentCom.Supervisor, server)
    end

    for server <- Enum.reverse(servers) do
      Supervisor.restart_child(AgentCom.Supervisor, server)
    end
  end

  @doc "Remove temp directory and all DETS files."
  def cleanup_dets(tmp_dir) do
    File.rm_rf!(tmp_dir)
  end
end
```

### Example 2: Test Factory

```elixir
# test/support/test_factory.ex
defmodule AgentCom.TestFactory do
  @moduledoc "Convenience factories for creating test data."

  @doc "Create and register a fake agent, returning agent info."
  def create_agent(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "test-agent-#{:erlang.unique_integer([:positive])}")
    capabilities = Keyword.get(opts, :capabilities, [])

    # Generate token
    {:ok, token} = AgentCom.Auth.generate(agent_id)

    # Spawn dummy WebSocket process
    ws_pid = spawn(fn -> Process.sleep(:infinity) end)

    # Start AgentFSM
    {:ok, fsm_pid} = AgentCom.AgentSupervisor.start_agent([
      agent_id: agent_id,
      ws_pid: ws_pid,
      name: Keyword.get(opts, :name, agent_id),
      capabilities: capabilities
    ])

    # Register in Presence
    AgentCom.Presence.register(agent_id, %{
      name: agent_id,
      status: "idle",
      capabilities: capabilities
    })

    %{
      agent_id: agent_id,
      token: token,
      ws_pid: ws_pid,
      fsm_pid: fsm_pid
    }
  end

  @doc "Submit a task with sensible defaults."
  def submit_task(opts \\ []) do
    params = %{
      description: Keyword.get(opts, :description, "Test task #{:erlang.unique_integer([:positive])}"),
      priority: Keyword.get(opts, :priority, "normal"),
      submitted_by: Keyword.get(opts, :submitted_by, "test-submitter"),
      max_retries: Keyword.get(opts, :max_retries, 3),
      needed_capabilities: Keyword.get(opts, :needed_capabilities, [])
    }

    AgentCom.TaskQueue.submit(params)
  end

  @doc "Clean up a test agent (kill ws_pid, revoke token)."
  def cleanup_agent(%{agent_id: agent_id, ws_pid: ws_pid}) do
    Process.exit(ws_pid, :kill)
    AgentCom.Auth.revoke(agent_id)
    Process.sleep(50)  # Allow FSM to process :DOWN
  end
end
```

### Example 3: WebSocket Test Client (Simplified from AgentSim)

```elixir
# test/support/ws_client.ex
defmodule AgentCom.TestHelpers.WsClient do
  @moduledoc """
  Lightweight WebSocket test client built on Mint.WebSocket.
  Simplified from Smoke.AgentSim for use in ExUnit tests.
  """
  use GenServer

  defstruct [:conn, :websocket, :request_ref, :response_status,
             :response_headers, messages: [], identified: false]

  def start_link(url \\ "ws://localhost:4002/ws") do
    GenServer.start_link(__MODULE__, url)
  end

  def send_json(pid, map) do
    GenServer.call(pid, {:send_json, map})
  end

  def messages(pid) do
    GenServer.call(pid, :messages)
  end

  def identified?(pid) do
    GenServer.call(pid, :identified?)
  end

  def stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  end

  # ... (GenServer callbacks following Smoke.AgentSim pattern)
end
```

### Example 4: GitHub Actions CI Workflow

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  elixir-tests:
    runs-on: ubuntu-latest
    env:
      MIX_ENV: test
    steps:
      - uses: actions/checkout@v4

      - name: Setup Elixir
        uses: erlef/setup-beam@v1
        with:
          otp-version: '28'
          elixir-version: '1.19'

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}
          restore-keys: ${{ runner.os }}-mix-

      - name: Install dependencies
        run: mix deps.get

      - name: Compile
        run: mix compile --warnings-as-errors

      - name: Run tests
        run: mix test

  sidecar-tests:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: sidecar
    steps:
      - uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '22'

      - name: Install dependencies
        run: npm ci

      - name: Run tests
        run: node --test
```

### Example 5: Sidecar Test with node:test

```javascript
// sidecar/test/queue.test.js
import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

// Import queue functions (after refactoring to module)
// import { loadQueue, saveQueue } from '../lib/queue.js';

describe('Queue Manager', () => {
  let tmpDir;
  let queuePath;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-'));
    queuePath = path.join(tmpDir, 'queue.json');
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it('returns empty queue when file missing', () => {
    // Test that loadQueue handles ENOENT gracefully
    assert.ok(!fs.existsSync(queuePath));
    // loadQueue(queuePath) should return { active: null, recovering: null }
  });

  it('handles corrupt queue file', () => {
    fs.writeFileSync(queuePath, 'not valid json{{{');
    // loadQueue(queuePath) should return { active: null, recovering: null }
    // and log a warning
  });

  it('round-trips queue state through save/load', () => {
    const queue = {
      active: { task_id: 'task-abc', status: 'accepted', description: 'test' },
      recovering: null
    };
    // saveQueue(queuePath, queue);
    // const loaded = loadQueue(queuePath);
    // assert.deepStrictEqual(loaded, queue);
  });
});
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `start_supervised!/2` for named GenServers | `Supervisor.terminate_child` + `restart_child` | Standard Elixir pattern | `start_supervised!` doesn't work well for globally-named GenServers already in the supervision tree; manual restart is idiomatic |
| External deps for WS test client (`:gun`, `websockex`) | Mint.WebSocket (already in deps) | This project | No new deps; reuse existing proven code |
| Jest for Node.js testing | `node:test` (built-in) | Node 20+ (stable) | Zero deps, native mocking, comparable feature set |
| `actions/setup-elixir` (deprecated) | `erlef/setup-beam` | 2022+ | Official BEAM Foundation action, supports latest OTP/Elixir |

**Deprecated/outdated:**
- `actions/setup-elixir`: Deprecated in favor of `erlef/setup-beam`. Do not use.
- `ExUnit.Callbacks.start_supervised/2` for globally-named processes already in the app's supervision tree: This function starts the process under ExUnit's supervisor, conflicting with the application's own supervisor. Use `Supervisor.terminate_child`/`restart_child` instead.

## Open Questions

1. **Sidecar module extraction scope**
   - What we know: `index.js` is 880 lines with functions tightly coupled through closure variables (`_config`, `_queue`). Testing individual functions requires either extraction or inline test setup.
   - What's unclear: How much refactoring is acceptable for testability? The context says "unit tests with mocked WebSocket for individual modules" which implies extraction.
   - Recommendation: Extract `queue.js`, `wake.js` as standalone modules that accept config/dependencies as parameters. Keep `index.js` as the entry point that wires everything together. This is a small refactoring that enables testing.

2. **Sidecar integration test mechanics**
   - What we know: "One integration test against real Elixir hub for the connection flow" is a decision.
   - What's unclear: How to start the Elixir hub from the sidecar test suite. Options: (a) assume hub is running, (b) use `mix test` to run a hub in the background, (c) skip in CI and run manually.
   - Recommendation: In CI, run the Elixir hub in the background (`mix run --no-halt &`) before running sidecar tests. In the workflow, the elixir-tests job validates the hub works, then a sidecar-integration job starts the hub and runs the integration test.

3. **Test port conflict**
   - What we know: The app binds to port 4000 by default. Tests need a different port.
   - What's unclear: Whether `config/test.exs` with `port: 4002` is sufficient, or if tests should use dynamic ports.
   - Recommendation: Use a fixed test port (4002) in `config/test.exs`. Dynamic ports add complexity for no benefit in a sequential test suite.

## Sources

### Primary (HIGH confidence)
- **Project source code** -- All GenServer modules, config, test infrastructure examined directly
- **ExUnit stdlib** -- Built-in Elixir test framework (verified against Elixir 1.19 behavior)
- **[Node.js test runner documentation](https://nodejs.org/api/test.html)** -- Verified node:test features including mocking, describe/it, coverage

### Secondary (MEDIUM confidence)
- **[erlef/setup-beam](https://github.com/erlef/setup-beam)** -- GitHub Action for Elixir/OTP CI setup, verified v1.20.4 latest
- **[Fresh WebSocket client](https://hex.pm/packages/fresh)** -- Verified 0.4.4 latest version, Mint-based, compatible with Elixir 1.14+
- **[Fly.io Elixir CI guide](https://fly.io/docs/elixir/advanced-guides/github-actions-elixir-ci-cd/)** -- GitHub Actions workflow patterns for Elixir
- **[Node.js built-in test runner overview](https://leapcell.io/blog/the-rise-of-node-js-node-test-a-jest-challenger-in-2025)** -- Feature comparison showing node:test as viable Jest alternative

### Tertiary (LOW confidence)
- **[Testing GenServers in Elixir](https://tylerayoung.com/2021/09/12/architecting-genservers-for-testability/)** -- Blog post on GenServer testability patterns (2021, concepts still valid)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- All tools are stdlib or existing deps; versions verified against project lockfile and runtime
- Architecture: HIGH -- Patterns derived directly from examining source code structure; DETS path analysis is factual
- Pitfalls: HIGH -- Pitfalls identified from actual code inspection (hardcoded paths, missing guards, recursive calls)
- Sidecar testing: MEDIUM -- node:test features verified, but sidecar module extraction scope is a judgment call
- CI workflow: MEDIUM -- erlef/setup-beam verified, but exact OTP 28/Elixir 1.19 CI compatibility not tested

**Research date:** 2026-02-11
**Valid until:** 2026-03-11 (30 days -- Elixir test patterns are stable)
