# Phase 5: Smoke Test - Research

**Researched:** 2026-02-10
**Domain:** End-to-end integration testing of distributed Elixir/Node.js task pipeline
**Confidence:** HIGH

## Summary

Phase 5 is fundamentally different from Phases 1-4. Instead of building production features, it creates **test harnesses and scripts** that validate the full pipeline (task submission through agent completion) works correctly across real distributed machines. The three requirements (TEST-01, TEST-02, TEST-03) exercise increasingly complex scenarios: basic throughput, failure recovery, and scale distribution.

The testing challenge is that the system spans two runtimes (Elixir hub + Node.js sidecar) communicating over WebSocket. The sidecar completes tasks by writing result files to a `results_dir`, which means trivial smoke test tasks can bypass LLM interaction entirely -- the wake command writes the result file directly. This makes smoke tests fast, deterministic, and token-free.

**Primary recommendation:** Build Mix tasks (`mix smoke.basic`, `mix smoke.failure`, `mix smoke.scale`) that use the existing HTTP API for task submission and a lightweight Elixir WebSocket client (Fresh or mint_web_socket) to simulate agents, avoiding dependency on real sidecar processes for the core validation. Supplement with a shell script harness for the real-sidecar cross-machine test.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ExUnit | built-in | Test assertions and reporting | Elixir standard, already available |
| Fresh | ~> 0.4.4 | WebSocket client for simulated agents | Mint-based, lightweight, auto-reconnect, compatible with Elixir 1.14+ |
| Jason | ~> 1.4 | JSON encoding/decoding | Already in deps |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| mint_web_socket | ~> 1.0.5 | Low-level WS client if Fresh is too opinionated | Only if Fresh adds unwanted behavior |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Fresh | WebSockex ~> 0.5.1 | WebSockex is more mature but heavier; Fresh is lighter and Mint-based (modern) |
| Fresh | :gun (Erlang) | Lower-level, no Hex wrapper, harder to manage |
| Mix tasks | Standalone Elixir scripts | Mix tasks integrate with project deps and compilation; scripts need manual setup |
| Simulated agents | Real sidecars only | Real sidecars test the full stack but are harder to orchestrate in CI; simulated agents isolate hub logic |

**Installation:**
```bash
# Add to mix.exs deps (dev/test only)
{:fresh, "~> 0.4.4", only: [:dev, :test]}
```

## Architecture Patterns

### Recommended Test Structure
```
test/
  smoke/
    helpers/
      agent_sim.ex       # Simulated WebSocket agent (connect, identify, handle tasks)
      task_helpers.ex     # HTTP helpers for task submission and query
      assertions.ex       # Custom smoke test assertions
    basic_test.exs        # TEST-01: 10 tasks, 2 agents, full completion
    failure_test.exs      # TEST-02: Kill agent mid-task, verify recovery
    scale_test.exs        # TEST-03: 4 agents, 20 tasks, even distribution
  smoke_test_helper.exs   # Smoke-specific ExUnit config
scripts/
  smoke-real.sh           # Cross-machine test runner using real sidecars
  smoke-config/           # Sidecar configs for smoke test agents
```

### Pattern 1: Simulated Agent via WebSocket Client
**What:** An Elixir process that connects to the hub via WebSocket, identifies as an agent, receives task assignments, and automatically completes them with minimal token overhead.
**When to use:** For all three smoke test scenarios. Simulated agents are deterministic, fast, and controllable.
**Example:**
```elixir
defmodule Smoke.AgentSim do
  @moduledoc """
  Simulated agent that connects to hub, identifies, and auto-completes tasks.
  Wraps a WebSocket client process.
  """

  use GenServer
  require Logger

  defstruct [
    :agent_id, :token, :hub_url, :ws_pid,
    :tasks_completed, :tasks_received,
    :on_task_assign, # callback: :complete | :fail | :ignore | {:delay, ms}
    :generation_map  # %{task_id => generation} for correct completion
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def completed_count(pid) do
    GenServer.call(pid, :completed_count)
  end

  def received_tasks(pid) do
    GenServer.call(pid, :received_tasks)
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  # In init: connect WebSocket, send identify message
  # On task_assign message: send task_accepted, then task_complete
  # Track generation from assignment for correct completion
end
```

### Pattern 2: HTTP Task Submission Helper
**What:** Helper module that wraps the POST /api/tasks endpoint for submitting smoke test tasks.
**When to use:** Every test submits tasks via HTTP API (the production path).
**Example:**
```elixir
defmodule Smoke.TaskHelpers do
  @hub_url "http://localhost:4000"

  def submit_task(description, opts \\ []) do
    body = Jason.encode!(%{
      "description" => description,
      "priority" => Keyword.get(opts, :priority, "normal"),
      "needed_capabilities" => Keyword.get(opts, :capabilities, []),
      "metadata" => Keyword.get(opts, :metadata, %{})
    })

    {:ok, conn} = Mint.HTTP.connect(:http, "localhost", 4000)
    {:ok, conn, _ref} = Mint.HTTP.request(conn, "POST", "/api/tasks",
      [{"content-type", "application/json"},
       {"authorization", "Bearer #{token()}"}],
      body)
    # ... collect response
  end

  def get_task(task_id) do
    # GET /api/tasks/:task_id
  end

  def list_tasks(opts \\ []) do
    # GET /api/tasks with filters
  end

  def get_stats() do
    # GET /api/tasks/stats
  end
end
```

### Pattern 3: Test Orchestration with Timing Control
**What:** Tests that submit tasks, wait for agents to process them, and assert outcomes within time bounds.
**When to use:** All smoke tests need timing control -- assignment must happen within 5 seconds, completion within bounded time.
**Example:**
```elixir
# Submit 10 tasks, wait for all to complete, assert timing
test "TEST-01: 10 tasks complete across 2 agents" do
  agents = for i <- 1..2 do
    {:ok, pid} = Smoke.AgentSim.start_link(
      agent_id: "smoke-agent-#{i}",
      token: tokens[i],
      hub_url: "ws://localhost:4000/ws",
      on_task_assign: :complete
    )
    pid
  end

  task_ids = for n <- 1..10 do
    {:ok, %{"task_id" => id}} = Smoke.TaskHelpers.submit_task(
      "Write number #{n} to file"
    )
    id
  end

  # Wait for completion with timeout
  assert_all_completed(task_ids, timeout: 30_000)

  # Assert all 10 completed
  for id <- task_ids do
    {:ok, task} = AgentCom.TaskQueue.get(id)
    assert task.status == :completed
  end

  # Assert assignment latency
  for id <- task_ids do
    {:ok, task} = AgentCom.TaskQueue.get(id)
    assignment_latency = task.assigned_at - task.created_at
    assert assignment_latency < 5_000, "Assignment latency #{assignment_latency}ms exceeds 5s"
  end
end
```

### Pattern 4: Controlled Agent Kill for Failure Tests
**What:** Abruptly disconnect an agent mid-task to test reclamation.
**When to use:** TEST-02 failure recovery scenario.
**Example:**
```elixir
# Agent receives task, sends task_accepted, then we kill the WebSocket
# This triggers AgentFSM :DOWN -> reclaim_task -> task re-queued
# Remaining agent picks it up via scheduler

test "TEST-02: killed agent's task reclaimed by survivor" do
  # Agent 1: will be killed after accepting task
  agent1 = start_agent("victim", on_task_assign: {:delay, 5_000})
  # Agent 2: completes normally
  agent2 = start_agent("survivor", on_task_assign: :complete)

  {:ok, %{"task_id" => task_id}} = submit_task("killable task")

  # Wait for agent1 to receive and accept the task
  wait_for(fn -> Smoke.AgentSim.received_tasks(agent1) |> length() > 0 end)

  # Kill agent1's WebSocket connection abruptly
  Smoke.AgentSim.kill_connection(agent1)

  # Wait for task to complete via agent2
  assert_task_completed(task_id, timeout: 30_000)

  # Verify task completed exactly once (no duplicates)
  {:ok, task} = AgentCom.TaskQueue.get(task_id)
  assert task.status == :completed
  # History should show: queued -> assigned (agent1) -> reclaimed -> assigned (agent2) -> completed
end
```

### Anti-Patterns to Avoid
- **Testing against real LLM tasks:** Smoke tests must use trivial tasks (write N to file) to validate infrastructure, not LLM capability. Real LLM work is non-deterministic and token-expensive.
- **Relying on `Process.sleep` for synchronization:** Use polling with timeout instead. `Process.sleep(5000)` is fragile -- sometimes too short, sometimes wastes time.
- **Sharing DETS state between test runs:** Tests must start with a clean TaskQueue. Either wipe DETS between runs or use a test-specific DETS path.
- **Hardcoding tokens:** Use `AgentCom.Auth.generate/1` at test setup time to create fresh tokens per test run.
- **Testing only happy path:** TEST-02 and TEST-03 specifically test failure and load scenarios -- the test harness must support agent kill, delayed completion, and multi-priority submission.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| WebSocket client | Raw TCP socket manipulation | Fresh or mint_web_socket | WebSocket upgrade handshake, frame encoding, ping/pong handling |
| HTTP client for API calls | :httpc or raw :gen_tcp | Mint (already a dep of Fresh) | Connection pooling, proper header handling |
| Test assertions with timeout | Recursive sleep loops | Poll-and-assert helper with configurable timeout | Reusable, clear error messages, prevents flaky tests |
| Token generation for test agents | Hardcoded strings | AgentCom.Auth.generate/1 | Tokens verified by the same auth module used in production |
| DETS cleanup | Manual file deletion | GenServer.stop + File.rm_rf on DETS paths | Ensures tables are properly closed before deletion |

**Key insight:** The smoke test harness IS the deliverable. It should be reusable -- after Phase 5, these same tests run as regression checks before every release.

## Common Pitfalls

### Pitfall 1: DETS Contamination Between Test Runs
**What goes wrong:** Tests pass first time, fail on second run because DETS has stale tasks from previous run.
**Why it happens:** DETS files persist on disk. TaskQueue init rebuilds priority index from existing data.
**How to avoid:** Test setup must either (a) use a unique DETS path per run via Application.put_env, or (b) clear all tasks before each test, or (c) stop TaskQueue, delete DETS files, restart TaskQueue.
**Warning signs:** Tests pass in isolation but fail when run together or after a previous run.

### Pitfall 2: Race Between Task Submission and Agent Connection
**What goes wrong:** Tasks submitted before agents connect miss the scheduling window; scheduler fires on task_submitted but no agents are idle yet.
**Why it happens:** Scheduler is event-driven. If agents connect after tasks are submitted, only the agent_joined event triggers scheduling.
**How to avoid:** Connect and identify agents BEFORE submitting tasks, or accept that scheduling happens on agent_joined (which it does -- verified in scheduler code). Either ordering works, but tests must be aware of which path they exercise.
**Warning signs:** Intermittent test failures where first few tasks aren't assigned.

### Pitfall 3: Generation Mismatch on Task Completion
**What goes wrong:** Simulated agent sends task_complete with wrong generation, gets stale_generation error.
**Why it happens:** The generation is bumped on each assignment. If a task is reclaimed and reassigned, the generation changes. Agent must use the generation from its task_assign message.
**How to avoid:** AgentSim must track generation per task from the task_assign WebSocket message and include it in task_complete.
**Warning signs:** task_complete_failed errors in logs, tasks stuck in :assigned status.

### Pitfall 4: WebSocket Close vs Kill Semantics
**What goes wrong:** Test "kills" agent with clean WebSocket close; hub processes the close cleanly and the test doesn't exercise the crash/disconnect path.
**Why it happens:** Clean WebSocket close (1000) is different from abrupt TCP termination. Socket.terminate is called on clean close.
**How to avoid:** For failure tests, use `ws.terminate()` (abrupt) not `ws.close(1000, "reason")`. Or directly kill the GenServer process. The key is that the WebSocket process dies, triggering the AgentFSM :DOWN monitor.
**Warning signs:** Task reclamation doesn't happen because the agent's FSM received a graceful shutdown instead of a crash signal.

### Pitfall 5: Timing Sensitivity in Assignment Latency Checks
**What goes wrong:** Test asserts <5s assignment latency but measures wall-clock time including test setup, not the actual created_at to assigned_at delta.
**Why it happens:** Using Process.sleep or wall-clock timing instead of task metadata timestamps.
**How to avoid:** Use task.assigned_at - task.created_at from TaskQueue records. These are System.system_time(:millisecond) timestamps set inside TaskQueue itself.
**Warning signs:** Inconsistent latency measurements, timing depends on machine load.

### Pitfall 6: Sidecar task_complete Missing Generation
**What goes wrong:** The existing sidecar's `sendTaskComplete` does not include the `generation` field in the message. The Socket handler defaults `generation` to 0 when missing.
**Why it happens:** Looking at sidecar/index.js `sendTaskComplete`, it sends `{ type: 'task_complete', task_id: taskId, result }` -- no generation field. The Socket handler at line 320 does `generation = msg["generation"] || 0`.
**How to avoid:** For simulated agents in Elixir tests, always include generation. For real sidecar tests, either (a) accept generation defaults work for first-assignment (gen=1, sidecar sends 0, mismatch!), or (b) fix the sidecar to track and send generation. **This is a real bug that smoke tests will surface.**
**Warning signs:** task_complete_failed: stale_generation errors when using real sidecars.

### Pitfall 7: Acceptance Timeout (60s) Conflicts with Test Timing
**What goes wrong:** Agent receives task_assign but test kills it before it sends task_accepted. The 60s acceptance timeout fires, reclaiming the task, but the test expected immediate reclamation from :DOWN.
**Why it happens:** AgentFSM has both :DOWN monitoring and acceptance_timeout. The :DOWN handler cancels the timer, but if the kill is slow, both can fire.
**How to avoid:** In failure tests, ensure agent sends task_accepted before being killed (so FSM is in :working state, not :assigned). Or kill immediately and verify the reclamation happens via whichever mechanism fires first.
**Warning signs:** Non-deterministic task reclamation timing.

## Code Examples

### Connecting a Simulated Agent via WebSocket
```elixir
# Using the :gen_tcp + manual WebSocket upgrade approach (no external deps)
# OR using Fresh for cleaner API

# Approach: Direct WebSocket via Mint.WebSocket
defmodule Smoke.WsClient do
  @moduledoc "Minimal WebSocket client for smoke tests."

  def connect(url) do
    uri = URI.parse(url)
    {:ok, conn} = Mint.HTTP.connect(:http, uri.host, uri.port)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, uri.path, [])
    # Process upgrade response...
    # Return connected state
  end

  def send_json(state, payload) do
    frame = {:text, Jason.encode!(payload)}
    Mint.WebSocket.encode(state.websocket, frame)
    # Send encoded data...
  end
end
```

### Submitting Tasks via HTTP (using :httpc -- no deps needed)
```elixir
# :httpc is built into Erlang/OTP, no extra deps needed
defmodule Smoke.Http do
  def post_json(path, body, token) do
    :httpc.request(
      :post,
      {~c"http://localhost:4000#{path}",
       [{~c"authorization", ~c"Bearer #{token}"},
        {~c"content-type", ~c"application/json"}],
       ~c"application/json",
       Jason.encode!(body)},
      [],
      []
    )
  end

  def get_json(path, token) do
    :httpc.request(
      :get,
      {~c"http://localhost:4000#{path}",
       [{~c"authorization", ~c"Bearer #{token}"}]},
      [],
      []
    )
  end
end
```

### Polling for Task Completion with Timeout
```elixir
defmodule Smoke.Assertions do
  @doc "Wait for all task_ids to reach :completed status."
  def assert_all_completed(task_ids, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    interval = Keyword.get(opts, :interval, 200)
    deadline = System.system_time(:millisecond) + timeout

    do_poll(task_ids, interval, deadline)
  end

  defp do_poll([], _interval, _deadline), do: :ok

  defp do_poll(task_ids, interval, deadline) do
    now = System.system_time(:millisecond)
    if now > deadline do
      incomplete = Enum.filter(task_ids, fn id ->
        {:ok, task} = AgentCom.TaskQueue.get(id)
        task.status != :completed
      end)
      raise "Timeout: #{length(incomplete)} tasks not completed: #{inspect(incomplete)}"
    end

    remaining = Enum.filter(task_ids, fn id ->
      {:ok, task} = AgentCom.TaskQueue.get(id)
      task.status != :completed
    end)

    if remaining == [] do
      :ok
    else
      Process.sleep(interval)
      do_poll(remaining, interval, deadline)
    end
  end
end
```

### Clean Test Setup with Fresh DETS
```elixir
defmodule Smoke.Setup do
  @doc "Reset task queue state for a clean test run."
  def reset_task_queue do
    # Stop the existing TaskQueue
    GenServer.stop(AgentCom.TaskQueue, :normal)

    # Delete DETS files
    File.rm("priv/task_queue.dets")
    File.rm("priv/task_dead_letter.dets")

    # Restart TaskQueue (it will create fresh DETS)
    {:ok, _pid} = AgentCom.TaskQueue.start_link([])
  end

  @doc "Generate fresh auth tokens for smoke test agents."
  def create_test_tokens(agent_ids) do
    for id <- agent_ids, into: %{} do
      {:ok, token} = AgentCom.Auth.generate(id)
      {id, token}
    end
  end

  @doc "Clean up test tokens."
  def revoke_test_tokens(agent_ids) do
    for id <- agent_ids do
      AgentCom.Auth.revoke(id)
    end
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual curl-based testing | ExUnit test harness with simulated agents | This phase | Repeatable, automated verification |
| Manual UAT per phase | Automated regression suite | This phase | Every future phase can re-run smoke tests |
| Real LLM tasks for testing | Trivial file-write tasks | Design decision | Sub-second completion, zero token cost |

**Key architectural insight:** The sidecar's result-file mechanism (write `{task_id}.json` to `results_dir`) means smoke tests can use a wake command like `echo '{"status":"success","output":"N"}' > ./results/${TASK_ID}.json` -- the entire task completes without any LLM involvement.

## Critical Discovery: Sidecar Generation Bug

**Finding:** The sidecar's `sendTaskComplete` (sidecar/index.js line 551-553) does NOT include the `generation` field:
```javascript
sendTaskComplete(taskId, result) {
  return this.send({ type: 'task_complete', task_id: taskId, result });
}
```

But the hub's Socket handler (socket.ex line 320) expects it:
```elixir
generation = msg["generation"] || 0
```

And TaskQueue.complete_task requires matching generation (line 357):
```elixir
{:ok, %{status: :assigned, generation: ^generation} = task} ->
```

On first assignment, generation is 1 (bumped from 0 on assign). Sidecar sends generation 0 (default). **This will cause `{:error, :stale_generation}` on every real sidecar task completion.**

**Impact:** This is a pre-existing bug that Phase 5 smoke tests MUST surface and fix. The fix is in sidecar/index.js: track generation from task_assign message and include it in task_complete and task_failed messages.

**Confidence:** HIGH -- verified by reading both source files directly.

## Open Questions

1. **Test execution environment: in-process or separate process?**
   - What we know: ExUnit tests run inside the application's BEAM VM, so they have direct access to GenServers (TaskQueue, AgentFSM, etc.). This makes assertions easy.
   - What's unclear: Should smoke tests start the application themselves (like integration tests), or assume it's already running (like black-box tests)?
   - Recommendation: Use Mix tasks that start the application, run tests, then report. This gives both direct process access AND exercises the real startup path. For cross-machine tests, use a shell script that starts the hub, starts remote sidecars, submits tasks via HTTP, and polls for results.

2. **Real sidecar vs simulated agent scope**
   - What we know: Simulated Elixir agents test hub logic thoroughly. Real sidecars test the full stack including Node.js process, wake commands, and result file watching.
   - What's unclear: Does Phase 5 need to test real sidecars, or is testing the hub with simulated agents sufficient?
   - Recommendation: **Both.** Plan 1: simulated agent tests (ExUnit, fast, repeatable). Plan 2: real sidecar test (shell script, cross-machine, validates full stack including the generation bug fix).

3. **Clean DETS state management**
   - What we know: Tests need clean state. DETS files are at `priv/task_queue.dets` and `priv/task_dead_letter.dets`.
   - What's unclear: Can we configure a test-specific DETS path, or must we clean the production path?
   - Recommendation: Use `Application.put_env(:agent_com, :task_queue_path, ...)` with a test-specific path before starting TaskQueue. The `dets_path/1` helper in task_queue.ex already reads this config.

## Sources

### Primary (HIGH confidence)
- Direct codebase reading: lib/agent_com/task_queue.ex, scheduler.ex, agent_fsm.ex, socket.ex, endpoint.ex, application.ex
- Direct codebase reading: sidecar/index.js -- full task lifecycle including the generation bug
- .planning/ROADMAP.md, REQUIREMENTS.md, STATE.md -- phase requirements and prior decisions

### Secondary (MEDIUM confidence)
- [Fresh WebSocket client](https://hex.pm/packages/fresh) -- v0.4.4, compatible with Elixir 1.14+
- [ExUnit docs](https://hexdocs.pm/ex_unit/ExUnit.html) -- built-in test framework
- [Mint.WebSocket](https://hex.pm/packages/mint_web_socket) -- v1.0.5, low-level WS client

### Tertiary (LOW confidence)
- [WebSockex](https://hex.pm/packages/websockex) -- v0.5.1, alternative WS client (not recommended for this use case)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - based on direct codebase reading and verified Hex packages
- Architecture: HIGH - patterns derived from actual module APIs and WebSocket protocol in socket.ex
- Pitfalls: HIGH - generation bug verified by cross-referencing sidecar/index.js with socket.ex and task_queue.ex
- Test patterns: MEDIUM - ExUnit patterns are standard, but specific orchestration approach is a recommendation

**Research date:** 2026-02-10
**Valid until:** 2026-03-10 (stable -- this is testing infrastructure for an existing codebase)
