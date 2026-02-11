# Domain Pitfalls: Hardening AgentCom

**Domain:** Adding testing, DETS resilience, input validation, observability, and rate limiting to existing production Elixir/OTP agent coordination system
**Researched:** 2026-02-11
**Overall Confidence:** HIGH (based on direct codebase analysis of all 24 source files + Erlang/Elixir documentation + community patterns)

---

## Critical Pitfalls

Mistakes that cause rewrites, data loss, or production outages.

---

### Pitfall 1: DETS Repair Destroys Data on Improper Shutdown

**What goes wrong:** DETS files that are not closed properly (crash, `kill -9`, power loss) trigger automatic repair on next open. The repair process can silently lose data -- documented cases exist of DETS files returning empty or partial data after unclean shutdown + repair. This system has 6 active DETS tables (mailbox, channels, channel_history, config, thread_messages, thread_replies) plus 2 TaskQueue DETS tables (task_queue, task_dead_letter). None have backup mechanisms.

**Why it happens:** DETS writes a buddy-system space management structure to disk on close. If the process crashes before `dets:close/1` runs, the on-disk metadata is inconsistent. The auto-repair walks the file attempting to reconstruct valid records, but fragmented or partially-written records can be lost. The `terminate/2` callback is not guaranteed to run on `kill -9` or supervisor forced shutdown.

**Consequences:**
- All 8 DETS tables lose data simultaneously on any hard crash
- Task queue loses in-flight task state -- assigned tasks vanish, completed tasks lose results
- Channel subscriptions and history evaporate
- Mailbox messages for offline agents disappear
- Thread index becomes permanently inconsistent (reply_to chains point to deleted messages)

**Prevention:**
- Implement periodic DETS backup (copy `.dets` file to `.dets.bak` while table is open -- DETS supports concurrent reads during copy)
- Add a startup integrity check that compares record counts before/after open
- Implement WAL (write-ahead log) for TaskQueue as the highest-value table
- Run `:dets.sync/1` after critical mutations (already done in TaskQueue, NOT done in Channels or Threads)
- Add `:dets.info(table, :size)` monitoring to detect sudden count drops

**Detection:**
- Record count drops to 0 after restart
- Agents report "task not found" for recently assigned tasks
- Channel history gaps
- Logger warnings from `:dets` about repair during startup

**Confidence:** HIGH -- based on Erlang DETS documentation and [GitHub issue #8513](https://github.com/erlang/otp/issues/8513) documenting data loss on improper close.

**Phase impact:** DETS backup/compaction phase. Must be addressed BEFORE adding features that increase write volume.

---

### Pitfall 2: Adding Tests to Named GenServers Causes Global State Collision

**What goes wrong:** All 11 GenServers in AgentCom register with `name: __MODULE__` (global atom names). ExUnit's `async: true` cannot be used because every test that touches any GenServer shares the same global singleton. Even `async: false` tests pollute state across test cases -- the Mailbox DETS accumulates messages, Channels DETS retains subscriptions, Auth retains tokens, Analytics ETS retains counters between tests.

**Why it happens:** The codebase was written without test isolation in mind. Every module hardcodes its process name and DETS table name at compile time:
- `AgentCom.Auth` -> name: `__MODULE__`, reads from `priv/tokens.json`
- `AgentCom.Mailbox` -> name: `__MODULE__`, DETS table: `:agent_mailbox`
- `AgentCom.Channels` -> name: `__MODULE__`, DETS tables: `:agent_channels`, `:channel_history`
- `AgentCom.TaskQueue` -> name: `__MODULE__`, DETS tables: `:task_queue`, `:task_dead_letter`
- `AgentCom.Threads` -> name: `__MODULE__`, DETS tables: `:thread_messages`, `:thread_replies`
- `AgentCom.Config` -> name: `__MODULE__`, DETS table: `:agentcom_config`
- `AgentCom.Analytics` -> name: `__MODULE__`, ETS table: `:agent_analytics`

Writing tests that start the full application supervision tree will use production DETS files unless paths are overridden. Tests could corrupt production data if run from the same directory.

**Consequences:**
- Tests are flaky due to shared state leaking between test cases
- Cannot run tests in parallel (every test module must be `async: false`)
- Test setup/teardown becomes complex and error-prone
- Risk of tests accidentally modifying production DETS files
- Test suite is slow because of sequential execution + DETS I/O

**Prevention:**
- Configure test environment to use temp directories for ALL DETS paths (`config/test.exs`)
- Create a `test/support/sandbox.ex` that starts isolated GenServer instances with unique names for each test
- Alternatively: use `start_supervised!/1` with per-test GenServer instances, passing dynamic names and temp DETS paths via options
- At minimum: add a `reset/0` function to each GenServer that clears its state + DETS tables, call in `setup` blocks
- Set `MIX_ENV=test` to use test-specific DETS paths (`_build/test/priv/`)
- Never run `mix test` from the production deployment directory

**Detection:**
- Tests pass individually but fail when run as a suite
- Tests fail non-deterministically on CI
- DETS files appearing in `priv/` after running tests

**Confidence:** HIGH -- directly observed in codebase: every GenServer uses `name: __MODULE__` with no injection point for test isolation.

**Phase impact:** Testing phase. Must be the FIRST thing addressed in the testing strategy -- retrofitting isolation after writing hundreds of tests is a rewrite.

---

### Pitfall 3: DETS 2GB File Limit Causes Silent Failures at Scale

**What goes wrong:** DETS files cannot exceed 2 GB. The `MessageHistory` table stores every routed message with a cap of 10,000 entries, but the `Threads` tables have NO cap -- they grow unbounded. Channel history has a per-channel cap of 200 but no global cap. If any DETS file approaches 2 GB, writes silently fail or the table becomes corrupted.

**Why it happens:** DETS is an Erlang OTP legacy storage system with a hard 2 GB file size limit baked into its file format. The current code has no monitoring of DETS file sizes. The `thread_messages` table stores every message JSON forever with no eviction. With 5 agents sending messages regularly, this table grows indefinitely.

**Consequences:**
- Thread indexing stops working when the table hits 2 GB -- no error logged, writes just fail
- System appears to work but threads become un-navigable
- Cannot recover without manual intervention (delete + rebuild the DETS file)
- Compaction/repair of a 2 GB file takes significant time and memory

**Prevention:**
- Add eviction to `AgentCom.Threads` (keep last N messages, evict by age)
- Monitor DETS file sizes via `:dets.info(table, :file_size)` or `File.stat!/1`
- Set alerting thresholds at 500 MB (warning) and 1 GB (critical)
- Consider migrating high-write tables (MessageHistory, Threads) to ETS + periodic snapshotting, since they already have caps that make full persistence less valuable

**Detection:**
- DETS file sizes growing monotonically without bound
- `:dets.info(table, :size)` returning unexpected values
- Thread queries returning incomplete results

**Confidence:** HIGH -- confirmed by [Erlang DETS documentation](https://www.erlang.org/doc/man/dets): "The size of Dets files cannot exceed 2 GB."

**Phase impact:** DETS resilience phase. Must add file size monitoring before adding compaction.

---

### Pitfall 4: DETS Compaction Requires Table Close, Blocking All Operations

**What goes wrong:** The only way to defragment a DETS table is to close it and reopen with `repair: :force`. During this window, ALL GenServer calls to that table will fail. Since every DETS-backed GenServer handles calls synchronously, the calling process (often a WebSocket handler or HTTP handler) will get an error or timeout.

**Why it happens:** DETS has no online compaction. The `repair: :force` option rewrites the entire file. The GenServer must close the table, run compaction, and reopen it. During this window:
- `Mailbox.enqueue/2` fails -> messages are lost for offline agents
- `TaskQueue.submit/1` fails -> task submissions are rejected
- `Channels.publish/2` fails -> channel messages are dropped
- `Threads.index/1` fails -> thread indexing is silently skipped (it uses `cast`)

**Consequences:**
- Brief but total unavailability of the affected subsystem during compaction
- Messages and tasks submitted during compaction are lost (no retry/queue)
- If compaction is scheduled during active agent coordination, task assignment breaks
- Large tables (approaching 2 GB) take proportionally longer to compact, extending the outage

**Prevention:**
- Implement compaction as a "copy and swap" strategy: open a new DETS file, copy records from old to new, close old, rename new -> old, reopen
- Schedule compaction during low-activity windows (configurable via `AgentCom.Config`)
- Add request buffering in the GenServer: queue incoming calls during compaction, replay after
- For TaskQueue specifically: use the in-memory priority_index to serve reads during compaction
- Emit telemetry events for compaction start/end/duration so operators know what is happening
- Add a `/api/admin/compact` endpoint that only runs during quiet periods

**Detection:**
- Sudden burst of errors from multiple GenServers simultaneously
- Agent WebSocket connections receiving error responses
- Task assignment failures clustered around compaction time

**Confidence:** HIGH -- confirmed by Erlang documentation: "The only way to defragment a table is to close it and then open it again with option repair set to force."

**Phase impact:** DETS resilience phase. Must design the compaction strategy before implementing it.

---

## Moderate Pitfalls

Mistakes that cause significant rework, flaky tests, or degraded production behavior.

---

### Pitfall 5: Retrofitting Input Validation Breaks Existing Agent Protocols

**What goes wrong:** Adding input validation to the WebSocket `handle_msg` dispatch in `AgentCom.Socket` and HTTP endpoints in `AgentCom.Endpoint` rejects messages that existing Node.js sidecars are successfully sending today. The current code is extremely permissive -- `Message.new/1` accepts both atom and string keys, `from_json/1` creates messages with nil fields, the endpoint accepts any JSON body shape.

**Why it happens:** The 5 production sidecars have been built against the current permissive API. They may be sending:
- Extra fields that strict validation would reject
- Missing optional fields that new validation treats as required
- Numeric strings where validation expects integers (e.g., `"50"` for progress percentage)
- Nested payloads with unexpected shapes

The `AgentCom.Socket` module currently has 15+ `handle_msg` pattern matches, none of which validate field types, lengths, or formats. Adding validation to any of these changes the contract.

**Consequences:**
- Production agents start receiving `"error"` responses to previously-working messages
- Task lifecycle breaks if `task_complete` or `task_accepted` messages are rejected
- Sidecars require coordinated updates, turning a hub-only change into a multi-repo deployment
- Partial validation (some fields checked, others not) creates a false sense of security

**Prevention:**
- **Log-only mode first:** Add validation that logs violations but does not reject messages for 1-2 weeks
- **Version the protocol:** Add a `"protocol_version"` field to the identify handshake; apply strict validation only to v2+ agents
- **Validate incrementally:** Start with the fields that matter most for security (token, agent_id format, payload size) and expand gradually
- **Document the contract:** Write down what the WebSocket protocol actually accepts today before changing it
- **Coordinate with sidecars:** Ensure sidecar validation matches hub validation -- validate on both sides

**Detection:**
- Agents suddenly disconnecting or failing tasks after a hub update
- New `"error"` responses in sidecar logs that were not present before
- Task completion rate drops after validation deployment

**Confidence:** HIGH -- directly observed: `AgentCom.Message.new/1` accepts both atom/string keys with no type checking, `Socket.handle_msg` does no field validation.

**Phase impact:** Input validation phase. Must audit existing sidecar message shapes before adding validation.

---

### Pitfall 6: Structured Logging Retrofit Creates Log Noise Avalanche

**What goes wrong:** Adding `Logger.metadata/1` calls to all 22 GenServers and switching to JSON logging generates an overwhelming volume of structured log data. The current system uses `Logger.info` and `Logger.warning` sparingly (about 20 log statements total across the codebase). Adding structured logging to every GenServer callback, every DETS operation, every WebSocket message, and every HTTP request creates orders of magnitude more log output.

**Why it happens:** The natural impulse when adding observability to an unobservable system is to log everything. With 5 connected agents, each sending pings every 15 minutes, plus task lifecycle events, PubSub broadcasts, DETS operations, and HTTP API calls, structured logging quickly generates thousands of lines per hour. The current `config :logger, :console` format has no filtering beyond log level.

**Consequences:**
- Console output becomes unreadable during development
- Log files fill disk rapidly in production (no rotation configured)
- Performance degradation from synchronous logging in hot paths (WebSocket message handling)
- Important warnings buried in noise -- worse observability than before
- DETS write latency increases because Logger.info is synchronous by default

**Prevention:**
- **Log at appropriate levels:** Use `debug` for routine operations, `info` for state transitions, `warning` for anomalies, `error` for failures
- **Set metadata once in `init/1`:** Use `Logger.metadata(agent_id: agent_id, module: __MODULE__)` in each GenServer's init, not in every callback
- **Do NOT log every WebSocket message:** Log connection/disconnection, not every ping/pong
- **Do NOT log every DETS operation:** Log compaction/repair events, not individual inserts
- **Configure log rotation** before deploying structured logging
- **Use `Logger.debug` with lazy evaluation** for expensive-to-format messages: `Logger.debug(fn -> "expensive: #{inspect(state)}" end)`
- **Add a `:log_level` config** per module so operators can turn up/down individual GenServer verbosity

**Detection:**
- Log files exceeding 100 MB/day on a 5-agent system
- Visible latency increase on WebSocket message round-trip
- Developers disabling logging entirely because it is too noisy

**Confidence:** HIGH -- observable from current code: only ~20 log statements in the entire codebase, meaning any logging addition is a 5-10x increase.

**Phase impact:** Observability phase. Must define a logging level policy before writing any log statements.

---

### Pitfall 7: Rate Limiting WebSocket Messages Requires Per-Connection State, Not a Plug

**What goes wrong:** Rate limiting is added as a Plug middleware on HTTP endpoints but WebSocket connections bypass Plug after the initial upgrade. Messages flowing over an established WebSocket connection (the primary transport for all agent communication) are not rate-limited by any Plug-based solution. The WebSocket handler (`AgentCom.Socket`) processes messages in `handle_in/2`, which runs inside the connection process -- outside the Plug pipeline.

**Why it happens:** Plug rate limiting libraries (Hammer, PlugRateLimit) intercept HTTP requests in the Plug pipeline. The WebSocket upgrade happens at `/ws` via `WebSockAdapter.upgrade/3` in the Endpoint. After upgrade, all subsequent frames are handled by `AgentCom.Socket` callbacks, which have no access to Plug middleware. A malicious or buggy agent could flood the hub with thousands of messages per second over its WebSocket connection.

**Consequences:**
- HTTP API endpoints are rate-limited but the primary communication channel (WebSocket) is wide open
- A single rogue agent can overwhelm the entire hub by flooding messages
- PubSub broadcasts amplify the attack: one broadcast message is delivered to all connected agents
- ETS/DETS write pressure from Analytics, Mailbox, MessageHistory spikes unboundedly

**Prevention:**
- Implement rate limiting **inside** `AgentCom.Socket.handle_in/2`, not in Plug
- Track message count per time window in the Socket struct (e.g., `%{msg_count: 0, window_start: timestamp}`)
- Use a simple token bucket: allow N messages per window, reject with `{"type": "error", "error": "rate_limited"}` when exceeded
- Apply different limits to different message types: pings should have generous limits, broadcasts should be strict
- Also rate-limit at the HTTP layer using Plug middleware for API endpoints
- Consider per-agent global rate limiting via ETS (shared across HTTP + WebSocket for the same agent_id)

**Detection:**
- Single agent consuming disproportionate hub resources
- MessageHistory DETS growing faster than expected
- Other agents experiencing delayed message delivery

**Confidence:** HIGH -- directly observed: `AgentCom.Socket.handle_in/2` has zero rate limiting; `AgentCom.Endpoint` WebSocket upgrade happens before any rate-limit Plug could apply.

**Phase impact:** Rate limiting phase. WebSocket rate limiting must be designed separately from HTTP rate limiting.

---

### Pitfall 8: Test Suite Requires Running Full Application, Making Tests Slow and Brittle

**What goes wrong:** The existing smoke tests (basic_test, failure_test, scale_test) start the full application including all 17 supervision tree children, HTTP server on port 4000, DETS file I/O, and actual WebSocket connections. This pattern propagates to unit tests if not actively prevented. Every test takes seconds to set up, and the suite must run sequentially.

**Why it happens:** The application supervision tree (`AgentCom.Application`) starts everything eagerly: PubSub, Registry, 8 GenServers, DynamicSupervisor, Scheduler, Dashboard stack, and Bandit HTTP server. There is no way to start a subset of the system for isolated testing. Testing `AgentCom.Mailbox` in isolation requires `AgentCom.Config` (for TTL), which requires DETS. Testing `AgentCom.Router` requires `AgentCom.MessageHistory`, `AgentCom.Mailbox`, `AgentCom.Auth`, `AgentCom.Analytics`, and `AgentCom.Threads`.

**Consequences:**
- Unit tests take 30+ seconds because each test case starts/stops the full app
- Port conflicts if multiple test suites run simultaneously (Bandit on port 4000)
- DETS file locking prevents parallel test execution
- Tests fail on CI because of timing-dependent GenServer interactions
- Flaky tests due to PubSub message ordering non-determinism

**Prevention:**
- Create `config/test.exs` that sets a unique port (0 for random) and temp DETS paths
- Extract pure functions from GenServers for unit testing (e.g., `Channels.normalize/1` is already pure -- it is exposed as `normalize_name/1`)
- For GenServer tests, use `start_supervised!/1` with injected dependencies instead of the global singleton
- Create test helpers that start only the required subset of the supervision tree
- Keep smoke/integration tests separate from unit tests (`mix test --only unit` vs `mix test --only integration`)
- Use `Plug.Test` for HTTP endpoint tests instead of real HTTP connections

**Detection:**
- Test suite takes > 60 seconds for < 100 tests
- Tests fail with "address already in use" on port 4000
- Tests fail on CI but pass locally (or vice versa)

**Confidence:** HIGH -- directly observed: `AgentCom.Application.start/2` starts 17 children including HTTP server; existing smoke tests use real WebSocket connections.

**Phase impact:** Testing phase. Architecture the test infrastructure BEFORE writing tests.

---

### Pitfall 9: Metrics Endpoint Exposes Internal State Without Authentication

**What goes wrong:** Adding a `/metrics` endpoint for Prometheus scraping that exposes task queue depths, agent counts, error rates, DETS file sizes, and GenServer mailbox lengths without authentication. The current `/api/dashboard/state` endpoint already has no authentication (comment in code: "no auth -- local network only"). A metrics endpoint following this pattern exposes operational intelligence to anyone who can reach the port.

**Why it happens:** Prometheus scraping endpoints are traditionally unauthenticated because they run on internal networks. But AgentCom runs on port 4000 which is the same port used by agents and the dashboard. The current `Endpoint` has no IP-based access control, no separate listener for internal endpoints, and no concept of admin-vs-public routes beyond the `ADMIN_AGENTS` env var.

**Consequences:**
- Anyone who can reach port 4000 can enumerate all agents, their capabilities, current tasks, and system health
- Token counts visible in metrics could reveal system scale and usage patterns
- Combined with the unauthenticated `/api/onboard/register` endpoint, an attacker could register agents AND monitor the system
- Metrics scraping adds load to GenServers (each scrape queries TaskQueue.stats, AgentFSM.list_all, etc.)

**Prevention:**
- Require Bearer token authentication on the metrics endpoint (same as other admin endpoints)
- Alternatively, run the metrics endpoint on a separate port (e.g., 4001) that is firewalled to internal network only
- Cache metrics with a short TTL (5-10 seconds) to avoid GenServer call storms from frequent scraping
- Expose only aggregate metrics (counts, rates), not individual agent IDs or task descriptions
- Reuse `AgentCom.Plugs.RequireAuth` on the metrics endpoint

**Detection:**
- Prometheus scraping causing visible GenServer call latency
- Unknown IP addresses hitting the metrics endpoint
- Metrics data appearing in external monitoring that should not have access

**Confidence:** MEDIUM -- based on existing code pattern: `/api/dashboard/state` is explicitly unauthenticated, which sets a precedent that a metrics endpoint might follow.

**Phase impact:** Observability phase. Define authentication strategy for metrics endpoint before implementation.

---

## Minor Pitfalls

Mistakes that cause inconvenience, tech debt, or minor rework.

---

### Pitfall 10: DETS Sync After Every Write Kills Performance Under Load

**What goes wrong:** Adding `:dets.sync/1` after every write for crash safety (as `TaskQueue` already does) to the other 6 DETS-backed GenServers causes significant performance degradation. DETS sync forces an `fsync` to disk, which on typical hardware takes 1-15ms per call. With 5 agents sending messages, each message triggers writes to MessageHistory, Threads (2 tables), potentially Mailbox, and Analytics -- that is 4-5 sync calls per message.

**Why it happens:** The natural response to Pitfall 1 (data loss on crash) is to sync after every write. But DETS is already slow (all operations are disk operations), and adding sync calls multiplies the latency. The current `auto_save: 5_000` setting on most tables provides a reasonable tradeoff -- data written in the last 5 seconds might be lost, but throughput is maintained.

**Prevention:**
- Use `auto_save` (already configured on most tables) rather than explicit sync for routine writes
- Reserve explicit `:dets.sync/1` for critical state transitions only: task assignment, task completion, task dead-letter
- Batch syncs: accumulate writes and sync once per second rather than per-write
- For Threads, which uses `cast` (fire-and-forget), syncing is especially wasteful since the caller does not wait

**Detection:**
- Message routing latency increases from <1ms to 10-50ms
- WebSocket pong responses become delayed
- Task assignment takes noticeably longer

**Confidence:** HIGH -- `AgentCom.Threads.handle_cast({:index, msg})` already calls `:dets.sync` on BOTH tables after every message, which is unnecessary for a fire-and-forget index.

**Phase impact:** DETS resilience phase. Define sync policy per-table, not a blanket "sync everything."

---

### Pitfall 11: Adding `config/test.exs` Without Isolating DETS Paths Corrupts Production Data

**What goes wrong:** Running `mix test` without `MIX_ENV=test` or without proper DETS path configuration causes tests to read/write the same DETS files used by the running production system. The `AgentCom.Config` GenServer stores its DETS in `~/.agentcom/data/config.dets` (hardcoded via `System.get_env("HOME")`), which is the same on test and prod. The Threads module also uses `~/.agentcom/data/`.

**Why it happens:** Two different path strategies exist in the codebase:
1. **Application.get_env with priv/ default**: Mailbox, Channels, MessageHistory, TaskQueue use `Application.get_env(:agent_com, :xxx_path, "priv/xxx.dets")` -- these can be overridden per environment
2. **Hardcoded HOME path**: Config and Threads use `Path.join([System.get_env("HOME"), ".agentcom", "data"])` -- these CANNOT be overridden via config

Running `mix test` opens the same `~/.agentcom/data/config.dets` that the running production hub uses. If both are open simultaneously, DETS file locking may fail or cause corruption.

**Prevention:**
- Refactor `AgentCom.Config` and `AgentCom.Threads` to use `Application.get_env` for their data directory, not hardcoded `HOME`
- Create `config/test.exs` that overrides ALL DETS paths to `_build/test/priv/` or `System.tmp_dir()`
- Add a CI check that verifies no DETS files exist in `priv/` or `~/.agentcom/` after tests run
- Add a startup warning if `MIX_ENV != :prod` and DETS paths point to production locations

**Detection:**
- Production data changes unexpectedly after running tests
- "File already in use" errors when running tests while hub is running
- Config values reset to defaults after test suite runs

**Confidence:** HIGH -- directly confirmed by reading `AgentCom.Config.data_dir/0` and `AgentCom.Threads.dets_path/1` which hardcode paths.

**Phase impact:** Testing phase. Must be fixed BEFORE writing any tests that touch Config or Threads.

---

### Pitfall 12: Telemetry Events Added to Hot Paths Cause Measurable Overhead

**What goes wrong:** Adding `:telemetry.execute/3` calls inside `AgentCom.Socket.handle_in/2` (called for every WebSocket frame) and `AgentCom.Router.route/1` (called for every message) adds per-message overhead. With 5 agents each handling tasks, the message rate is low today but telemetry overhead compounds if the system scales.

**Why it happens:** Telemetry dispatches to all attached handlers synchronously. If a handler is slow (e.g., writes to ETS, computes a histogram), every message pays that cost. The current code has no telemetry at all, so adding it is a net-new cost.

**Prevention:**
- Limit telemetry events to coarse-grained operations: connection open/close, task submitted/completed/failed, compaction events
- Do NOT emit telemetry for every WebSocket frame or every ping/pong
- Use `Telemetry.Metrics` with a reporter that batches (e.g., `TelemetryMetricsPrometheus`) rather than logging each event
- Benchmark before/after telemetry addition on the hot path
- Bandit already emits telemetry for HTTP requests -- leverage that instead of adding custom HTTP telemetry

**Detection:**
- WebSocket message latency increases after telemetry deployment
- CPU usage increases without corresponding increase in agent activity

**Confidence:** MEDIUM -- telemetry overhead is generally small but measurable on high-frequency paths. At current scale (5 agents), unlikely to be a problem, but poor patterns here create future issues.

**Phase impact:** Observability phase. Define which events get telemetry before instrumenting.

---

### Pitfall 13: Auth Token Verification Is a GenServer Bottleneck Under Rate Limiting

**What goes wrong:** Every HTTP request and WebSocket identify call goes through `AgentCom.Auth.verify/1`, which is a `GenServer.call` -- serialized through a single process. Adding rate limiting increases the call frequency (rate limit check requires knowing the agent_id, which requires token verification first). Under burst traffic, the Auth GenServer becomes a bottleneck.

**Why it happens:** `AgentCom.Auth` stores tokens in a plain `%{token => agent_id}` map inside GenServer state. Every `verify/1` call is a synchronous `GenServer.call`, meaning all token verifications are serialized. At 5 agents, this is fine. But rate limiting means every HTTP request AND every rate-limit check flows through this single process.

**Prevention:**
- Move token storage to an ETS table with `read_concurrency: true` for verification lookups
- Keep the GenServer for mutations only (generate, revoke, list)
- Use `:ets.lookup/2` directly in `RequireAuth.call/2` instead of `GenServer.call`
- This also removes Auth as a single-process failure point

**Detection:**
- Auth GenServer mailbox growing under load
- HTTP 408 timeouts on authenticated endpoints
- Token verification latency visible in request logs

**Confidence:** MEDIUM -- at current scale (5 agents) this is not a problem, but rate limiting increases Auth call frequency and it will become relevant.

**Phase impact:** Rate limiting phase. Consider Auth optimization when implementing rate limiting.

---

### Pitfall 14: Mixing Smoke Tests and Unit Tests in the Same Suite

**What goes wrong:** The existing smoke tests in `test/smoke/` are integration tests that require a running application, real WebSocket connections, and HTTP calls. If unit tests are added to `test/` alongside them, `mix test` runs both. The smoke tests take 60-120 seconds (timeout tags visible in the code), dominating test suite time. Developers stop running tests because "they take too long."

**Why it happens:** ExUnit loads all `*_test.exs` files. The existing `test/test_helper.exs` already starts the app. The smoke test helper at `test/smoke_test_helper.exs` starts `:inets`. Without explicit separation, all tests run together.

**Prevention:**
- Use tags to separate test types: `@tag :integration` for smoke tests, `@tag :unit` for unit tests
- Configure `mix test` default to exclude integration: `ExUnit.start(exclude: [:integration])`
- Run smoke tests explicitly: `mix test --include integration`
- Consider moving smoke tests to a separate Mix project or using a `Makefile` target
- CI pipeline should run unit tests first (fast feedback), then integration tests

**Detection:**
- `mix test` takes > 2 minutes
- Developers using `mix test --only unit` as a workaround
- CI pipeline times dominated by test execution

**Confidence:** HIGH -- existing test files use `@tag timeout: 60_000` and `@tag timeout: 120_000`, confirming they are slow integration tests.

**Phase impact:** Testing phase. Establish test organization conventions before adding tests.

---

### Pitfall 15: Application Supervisor Strategy Masks Cascading Failures

**What goes wrong:** The supervision tree uses `strategy: :one_for_one`, meaning if one GenServer crashes, only that one is restarted. But DETS-backed GenServers have cross-dependencies: `Mailbox.enqueue` is called from `Router.route`, which is called from `Socket.handle_msg`. If `Mailbox` crashes and restarts, it reopens its DETS file (potentially triggering repair), but during the restart window, all in-flight message routing fails silently.

**Why it happens:** `:one_for_one` is the simplest supervision strategy and works well when children are independent. But AgentCom's children are deeply interconnected:
- `Router` depends on `MessageHistory`, `Mailbox`, `Auth`, `Analytics`, `Threads`
- `Scheduler` depends on `TaskQueue`, `AgentFSM` (via Registry), and `Presence`
- `Socket` depends on `Auth`, `Presence`, `Router`, `Channels`, `Threads`, `AgentFSM`

A crash in any dependency causes cascading call failures in dependents.

**Prevention:**
- Add error handling around cross-GenServer calls (many already have `case` matches, but not all)
- Consider `rest_for_one` for the critical path: if `Mailbox` crashes, restart everything after it
- Add circuit breakers or graceful degradation: if `Threads.index` fails, log and continue (threading is not critical path)
- The existing `AgentCom.Threads.index/1` uses `cast`, which naturally tolerates target crashes -- this pattern should be extended to other non-critical operations
- Add monitoring of GenServer restarts via `:telemetry` to detect cascading failures

**Detection:**
- Logger output showing rapid restart cycles
- Agents receiving errors for operations that depend on a recently-crashed GenServer
- Task assignment failures correlated with unrelated GenServer crashes

**Confidence:** MEDIUM -- the current system works at low scale, but adding hardening features (compaction, rate limiting) increases the likelihood of GenServer crashes.

**Phase impact:** All phases. Consider supervision strategy when adding any feature that might crash a GenServer.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation | Severity |
|---|---|---|---|
| **Testing: Setup** | DETS path collision with production (Pitfall 11) | Create `config/test.exs` with temp paths FIRST | Critical |
| **Testing: Setup** | Config and Threads use hardcoded HOME paths | Refactor to `Application.get_env` before writing tests | Critical |
| **Testing: GenServers** | Global singleton names prevent isolation (Pitfall 2) | Add `reset/0` or parameterized names | Critical |
| **Testing: Structure** | Smoke tests slow down unit test feedback (Pitfall 14) | Tag-based separation from day one | Moderate |
| **Testing: Coverage** | Chasing coverage % leads to brittle tests | Test behavior not implementation; focus on GenServer public APIs | Minor |
| **DETS: Backup** | Backup during compaction causes corrupt backup files | Never backup and compact simultaneously | Moderate |
| **DETS: Compaction** | Table close blocks all operations (Pitfall 4) | Copy-and-swap strategy | Critical |
| **DETS: File Size** | Unbounded Threads tables hit 2GB (Pitfall 3) | Add eviction before compaction | Critical |
| **DETS: Sync** | Over-syncing kills performance (Pitfall 10) | Sync policy: critical writes only | Moderate |
| **Input Validation** | Breaking existing agent protocol (Pitfall 5) | Log-only mode first, validate incrementally | Critical |
| **Input Validation** | Missing validation on WebSocket payload sizes | Add max message size check in Socket.handle_in | Moderate |
| **Input Validation** | `String.to_integer` in Endpoint crashes on bad input | Existing code on lines 215, 352-358, 438-441 calls `String.to_integer` on query params without rescue | Moderate |
| **Logging** | Noise avalanche from over-instrumentation (Pitfall 6) | Define level policy before writing log statements | Moderate |
| **Logging** | Hardcoded HOME paths in Config/Threads (Pitfall 11) | Refactor to Application.get_env before adding structured logs | Moderate |
| **Metrics** | Unauthenticated metrics endpoint (Pitfall 9) | Authenticate or run on separate port | Moderate |
| **Metrics** | Telemetry on hot paths (Pitfall 12) | Instrument coarse events only | Minor |
| **Rate Limiting** | WebSocket messages bypass Plug middleware (Pitfall 7) | Implement in Socket.handle_in, not Plug | Critical |
| **Rate Limiting** | Auth bottleneck under increased call volume (Pitfall 13) | Move token lookup to ETS | Moderate |
| **Rate Limiting** | Different limits needed for different message types | Per-type token buckets, not flat rate | Minor |

---

## Integration Pitfalls (Cross-Cutting)

### Adding features in the wrong order causes compounding problems

**Recommended order and rationale:**

1. **Test infrastructure first** (config/test.exs, DETS path isolation, test helpers) -- because every subsequent feature needs tests to verify correctness
2. **DETS resilience second** (backup, monitoring, eviction caps) -- because adding logging/metrics/validation increases DETS write volume, making fragmentation worse if not addressed
3. **Input validation third** -- because it is a prerequisite for rate limiting (need to know message type to set rate limits) and produces the contract documentation that tests need
4. **Structured logging fourth** -- because it benefits from having the validation and DETS work already stable, and can be verified by the test infrastructure
5. **Metrics/alerting fifth** -- because it can measure all the previously-added features and alert on the DETS thresholds established earlier
6. **Rate limiting last** -- because it depends on input validation (to classify messages), benefits from metrics (to tune limits), and needs Auth optimization that may emerge from metrics

**Anti-pattern: Adding rate limiting before input validation.** You cannot rate-limit by message type if you have not validated message types. You cannot rate-limit per-agent if the agent_id field is not validated.

**Anti-pattern: Adding structured logging before DETS resilience.** Logging every DETS operation while DETS is fragmented and unbounded makes the fragmentation problem worse faster.

**Anti-pattern: Adding metrics before tests.** Without tests, you cannot verify that metrics are accurate. A metrics endpoint that reports wrong numbers is worse than no metrics.

**Anti-pattern: Writing 200 tests against the current API, then adding input validation.** Half the tests will break when validation rejects what they were testing. Write tests and validation together.

---

## Codebase-Specific Gotchas Discovered During Analysis

These are not general pitfalls but specific landmines found by reading the AgentCom source code.

| File | Line(s) | Issue | Risk |
|---|---|---|---|
| `endpoint.ex` | 215, 352-358, 438-441 | `String.to_integer(s)` on query params with no error handling -- malformed input crashes the request handler | Moderate |
| `channels.ex` | 225-231 | `store_history/2` scans ALL keys to find max seq -- O(n) per message publish | Minor (200 cap) |
| `threads.ex` | 109-113 | `walk_to_root/1` recurses without depth limit -- circular reply_to chain causes infinite loop | Moderate |
| `threads.ex` | 71 | `:dets.sync` called on BOTH tables after every single indexed message via `cast` | Minor (performance) |
| `auth.ex` | 91 | `Jason.decode!` with no rescue -- corrupt tokens.json crashes Auth on startup, blocking all authentication | Moderate |
| `mailbox.ex` | 191-193 | `recover_seq` scans entire DETS table on startup -- slow with large mailbox | Minor |
| `message.ex` | 29-30 | `new/1` accepts both atom and string keys with `||` fallback -- makes validation ambiguous | Minor |
| `router.ex` | 42-51 | `queue_for_offline/1` calls `Auth.list()` on every broadcast -- O(n) per broadcast where n = total tokens | Moderate |
| `presence.ex` | All | Purely in-memory (GenServer state map) -- no persistence, all presence data lost on restart | By design, but logging/metrics should not assume persistence |
| `dashboard.ex` | All | 1167-line inline HTML string -- any structured logging that touches Dashboard will be very noisy | Minor |

---

## Sources

- [Erlang DETS documentation (stdlib v7.2)](https://www.erlang.org/doc/man/dets) -- 2GB limit, repair behavior, sync semantics
- [Erlang DETS data loss issue #8513](https://github.com/erlang/otp/issues/8513) -- documented data loss on improper close
- [Architecting GenServers for Testability](https://tylerayoung.com/2021/09/12/architecting-genservers-for-testability/) -- test isolation patterns
- [Understanding Test Concurrency in Elixir (DockYard)](https://dockyard.com/blog/2019/02/13/understanding-test-concurrency-in-elixir) -- async test pitfalls with shared state
- [Elixir Structured Logging (GenUI)](https://www.genui.com/resources/elixir-learnings-structured-logging) -- Logger.metadata patterns
- [Logger documentation (Elixir v1.19)](https://hexdocs.pm/logger/Logger.html) -- metadata, levels, configuration
- [Hammer rate limiter](https://github.com/ExHammer/hammer) -- ETS/Redis-backed rate limiting for Plug
- [Rate Limiting with GenServers (Alex Koutmos)](https://akoutmos.com/post/rate-limiting-with-genservers/) -- per-process token bucket pattern
- [PromEx - Prometheus metrics for Elixir](https://github.com/akoutmos/prom_ex) -- telemetry + Prometheus integration
- [Telemetry.Metrics documentation](https://hexdocs.pm/telemetry_metrics/Telemetry.Metrics.html) -- metric type definitions
- [Cleaning GenServer state between tests (Elixir Forum)](https://elixirforum.com/t/cleaning-genserver-state-between-tests-with-exunit/13368) -- test cleanup patterns
- [Elixir Testing (OneUptime, 2026)](https://oneuptime.com/blog/post/2026-01-26-elixir-testing/view) -- recent testing best practices
- [DETS performance discussion (Erlang Forums)](https://erlangforums.com/t/performance-ets-vs-dets-mnesia-for-infrequent-persistence-to-disk/3214) -- ETS vs DETS tradeoffs
- Direct codebase analysis: all 24 `.ex` source files in `lib/agent_com/` and 5 test files reviewed

---
*Pitfalls research for: Hardening AgentCom (testing, DETS resilience, input validation, observability, rate limiting)*
*Researched: 2026-02-11*
