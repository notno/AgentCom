# Phase 9: Testing Infrastructure - Context

**Gathered:** 2026-02-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Comprehensive test coverage for all GenServer modules, core pipelines, and Node.js sidecar -- with test isolation infrastructure, helpers/factories, and GitHub Actions CI. This phase delivers the testing foundation that all subsequent hardening phases depend on.

</domain>

<decisions>
## Implementation Decisions

### Test Isolation Strategy
- Standard Elixir approach: sequential tests (`async: false`) with shared global GenServer names
- State reset via setup/teardown blocks between tests -- no GenServer name injection refactoring
- DETS paths in `Config` and `Threads` must be refactored to use temp directories during tests (targeted fix, not full name injection)
- Full test factory module with convenience functions: `create_agent()`, `submit_task()`, `connect_websocket()`, etc.

### Coverage Priorities
- Tiered by risk: deep tests for critical path (TaskQueue, AgentFSM, Scheduler, Auth, Socket), basic tests for lower-risk modules (Analytics, Threads, MessageHistory)
- Two levels of integration tests:
  - Internal API tests calling GenServer functions directly (fast, thorough)
  - One full WebSocket end-to-end test for the complete task lifecycle (realistic)
- Failure path integration tests: timeout, crash, retry, dead-letter

### Sidecar Testing Approach
- Unit tests with mocked WebSocket for individual modules (queue, git workflow, wake trigger)
- One integration test against real Elixir hub for the connection flow
- Git workflow tests use real temp git repos (not mocked git commands)

### Test Execution & CI
- Test file organization mirrors source structure (standard Elixir convention)
- GitHub Actions CI runs both Elixir (`mix test`) and Node.js sidecar tests on push/PR
- CI only -- no pre-commit hooks (agents shouldn't be slowed by test runs)

### Claude's Discretion
- DETS state reset approach (fresh temp dir per module vs shared with table clearing)
- Node.js test framework choice (built-in `node:test` vs Jest)
- Which edge cases from pitfalls research warrant dedicated test cases vs coverage through normal tests
- WebSocket test client implementation (`:gun`, custom GenServer, or `WebSockAdapter`)

</decisions>

<specifics>
## Specific Ideas

- Research identified unprotected `String.to_integer` calls in `endpoint.ex` (lines 215, 352-358, 438-441) and infinite recursion risk in `Threads.walk_to_root/1` -- these should inform test cases
- Hardcoded DETS paths: `Config.data_dir/0` (config.ex:61-65) and `Threads.dets_path/1` (threads.ex:137-141) need `Application.get_env` refactoring for test safety

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 09-testing*
*Context gathered: 2026-02-11*
