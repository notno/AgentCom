---
phase: 05-smoke-test
plan: 01
subsystem: testing
tags: [websocket, mint, fresh, smoke-test, dets, httpc, genserver]

# Dependency graph
requires:
  - phase: 01-sidecar
    provides: "Sidecar task lifecycle (task_assign, task_complete, task_failed)"
  - phase: 02-task-queue
    provides: "TaskQueue DETS persistence with generation fencing"
  - phase: 03-agent-state
    provides: "AgentFSM process monitoring and task reclamation"
  - phase: 04-scheduler
    provides: "Event-driven task-to-agent matching"
provides:
  - "Fixed sidecar generation tracking in sendTaskComplete and sendTaskFailed"
  - "Smoke.AgentSim GenServer for simulated WebSocket agents via Mint.WebSocket"
  - "Smoke.Http helpers for HTTP task submission and query via :httpc"
  - "Smoke.Assertions polling helpers with configurable timeout"
  - "Smoke.Setup for DETS cleanup and auth token management"
  - "Fresh ~> 0.4.4 and Mint.WebSocket as dev/test dependencies"
affects: [05-smoke-test]

# Tech tracking
tech-stack:
  added: [fresh 0.4.4, mint 1.7.1, mint_web_socket 1.0.5, castore 1.0.17]
  patterns: [mint-websocket-genserver-wrapper, httpc-api-helpers, polling-assertions]

key-files:
  created:
    - test/smoke_test_helper.exs
    - test/smoke/helpers/agent_sim.ex
    - test/smoke/helpers/http_helpers.ex
    - test/smoke/helpers/assertions.ex
    - test/smoke/helpers/setup.ex
  modified:
    - sidecar/index.js
    - mix.exs
    - mix.lock

key-decisions:
  - "Used Mint.HTTP + Mint.WebSocket directly for AgentSim instead of Fresh wrapper (Full control over connection lifecycle, clean kill support)"
  - "Used :httpc for HTTP helpers (built-in, no extra deps, sufficient for test usage)"
  - "Generation tracked in Map keyed by task_id (supports edge case of multiple concurrent tasks)"

patterns-established:
  - "Smoke test helpers in test/smoke/helpers/ with Smoke.* namespace"
  - "AgentSim GenServer pattern: connect, identify, handle task_assign, auto-complete/fail"
  - "Polling assertions with deadline-based timeout (not Process.sleep)"

# Metrics
duration: 5min
completed: 2026-02-10
---

# Phase 5 Plan 1: Smoke Test Infrastructure Summary

**Fixed sidecar generation bug and built complete smoke test infrastructure with simulated WebSocket agent, HTTP helpers, and DETS cleanup utilities**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-10T23:06:57Z
- **Completed:** 2026-02-10T23:12:09Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments
- Fixed critical sidecar bug: sendTaskComplete and sendTaskFailed now include generation from task_assign message (prevents stale_generation errors)
- Built Smoke.AgentSim GenServer that connects via Mint.WebSocket, identifies, receives tasks, and auto-completes with correct generation tracking
- Built Smoke.Http helpers using :httpc for task submission and query against the HTTP API
- Built Smoke.Assertions with polling wait_for and assert_all_completed with configurable timeouts
- Built Smoke.Setup for clean DETS reset, token generation, and agent cleanup between test runs
- Added Fresh ~> 0.4.4 (dev/test) bringing Mint.WebSocket as a transitive dependency

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix sidecar generation bug and add Fresh dependency** - `b40ae8b` (fix)
2. **Task 2: Create smoke test helper modules and ExUnit configuration** - `aacfa41` (feat)

## Files Created/Modified
- `sidecar/index.js` - Added taskGenerations Map, generation in sendTaskComplete/sendTaskFailed/handleTaskAssign/handleTaskContinue/handleTaskReassign
- `mix.exs` - Added {:fresh, "~> 0.4.4", only: [:dev, :test]}, added :inets to extra_applications
- `mix.lock` - Updated with fresh, mint, mint_web_socket, castore
- `test/smoke_test_helper.exs` - ExUnit configuration with :inets startup for smoke tests
- `test/smoke/helpers/agent_sim.ex` - Simulated WebSocket agent GenServer using Mint.HTTP + Mint.WebSocket
- `test/smoke/helpers/http_helpers.ex` - HTTP task submission and query helpers using :httpc
- `test/smoke/helpers/assertions.ex` - Polling assertions (assert_all_completed, assert_task_completed, wait_for)
- `test/smoke/helpers/setup.ex` - DETS cleanup, token generation, agent cleanup

## Decisions Made
- **Mint.WebSocket over Fresh wrapper:** Fresh uses :gen_statem internally and manages its own process lifecycle, making it awkward to wrap in a separate GenServer. Mint.HTTP + Mint.WebSocket (transitive deps of Fresh) provide full control over the connection, enabling clean send/receive and abrupt kill for failure testing.
- **:httpc over Mint for HTTP:** :httpc is built into Erlang/OTP and sufficient for test helper usage. No extra dependency needed since :inets is added to extra_applications.
- **Map-based generation tracking in sidecar:** Using a Map keyed by task_id (rather than a single field) supports edge cases where multiple tasks may be tracked during recovery scenarios.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- All 5 smoke test helper modules are ready for Plan 2 (smoke test scenarios)
- Sidecar generation bug is fixed -- real sidecars can now complete tasks correctly
- AgentSim supports all required behaviors: :complete, :fail, :ignore, {:delay, ms}
- kill_connection/1 enables failure testing by abruptly closing the TCP connection

## Self-Check: PASSED

- All 9 files verified present on disk
- Commit b40ae8b verified (Task 1: sidecar generation fix + Fresh)
- Commit aacfa41 verified (Task 2: smoke test helpers)
- mix compile passes with no errors
- Generation tracking verified in sidecar/index.js (sendTaskComplete, sendTaskFailed)
- Fresh dependency verified in mix.exs and deps tree

---
*Phase: 05-smoke-test*
*Completed: 2026-02-10*
