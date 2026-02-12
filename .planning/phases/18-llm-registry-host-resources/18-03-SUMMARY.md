---
phase: 18-llm-registry-host-resources
plan: 03
subsystem: api
tags: [websocket, http, supervisor, validation, ollama, registry, wiring]

# Dependency graph
requires:
  - "18-01: LlmRegistry GenServer with DETS persistence and ETS resource metrics"
provides:
  - "LlmRegistry GenServer started in supervisor tree (before DashboardState)"
  - "WebSocket ollama_report handler triggering auto-registration"
  - "WebSocket resource_report handler storing metrics via LlmRegistry ETS"
  - "Auto-registration from identify message when ollama_url present"
  - "HTTP GET/POST/DELETE /api/admin/llm-registry admin routes"
  - "HTTP GET /api/admin/llm-registry/snapshot for full registry view"
  - "Validation schemas for ollama_report, resource_report WS types"
  - "Validation schema for post_llm_registry HTTP body"
  - ":number type support in validation module"
affects: [18-04-dashboard-llm-registry]

# Tech tracking
tech-stack:
  added: []
  patterns: [supervisor wiring for DETS GenServer, :number validation type for numeric fields]

key-files:
  created: []
  modified:
    - lib/agent_com/application.ex
    - lib/agent_com/socket.ex
    - lib/agent_com/endpoint.ex
    - lib/agent_com/validation/schemas.ex
    - lib/agent_com/validation.ex
    - test/agent_com/llm_registry_test.exs
    - test/agent_com/validation_test.exs
    - test/support/dets_helpers.ex

key-decisions:
  - "Snapshot route defined before :id route to prevent 'snapshot' being captured as parameter"
  - "resource_report returns {:ok, state} with no reply (fire-and-forget like task_progress)"
  - ":number validation type accepts both integer and float (Elixir is_number guard)"
  - "LlmRegistry tests refactored to use Supervisor stop/restart for supervisor compatibility"

patterns-established:
  - "Snapshot-before-parameterized pattern: static path routes defined before :id routes to avoid capture"
  - ":number type for validation schemas accepting integer or float"

# Metrics
duration: 11min
completed: 2026-02-12
---

# Phase 18 Plan 03: HTTP API, WS Handlers, and Supervisor Wiring Summary

**LlmRegistry wired into supervisor tree with WebSocket handlers for sidecar auto-reporting, HTTP admin CRUD routes, and validation schemas for all new message types including :number type support**

## Performance

- **Duration:** 11 min
- **Started:** 2026-02-12T20:36:06Z
- **Completed:** 2026-02-12T20:46:51Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments
- LlmRegistry GenServer starts automatically in the supervisor tree before DashboardState
- WebSocket handles ollama_report (auto-registers endpoint) and resource_report (stores metrics) messages
- Identify message auto-registers Ollama endpoint when ollama_url field is present
- Five HTTP admin routes: list all, get snapshot, get by id, register (POST), remove (DELETE)
- Validation schemas for 17 WS message types (added ollama_report, resource_report) and post_llm_registry HTTP body
- New :number validation type supporting both integer and float values
- All 337 tests pass (0 regressions)

## Task Commits

Each task was committed atomically:

1. **Task 1: WS handlers, HTTP routes, supervisor entry** - `8f83d96` (feat)
2. **Task 2: Validation schemas** - `f425745` (feat)
3. **Test infrastructure hardening** - `783353f` (fix)

## Files Created/Modified
- `lib/agent_com/application.ex` - Added LlmRegistry to supervisor children
- `lib/agent_com/socket.ex` - Added ollama_report, resource_report handlers and identify auto-registration
- `lib/agent_com/endpoint.ex` - Added 5 HTTP admin routes for LLM registry CRUD + snapshot
- `lib/agent_com/validation/schemas.ex` - Added ollama_report, resource_report WS schemas, post_llm_registry HTTP schema, ollama_url length limit
- `lib/agent_com/validation.ex` - Added :number type validation (is_number guard)
- `test/agent_com/llm_registry_test.exs` - Refactored to use supervisor stop/restart for compatibility
- `test/agent_com/validation_test.exs` - Updated known_types assertion from 15 to 17
- `test/support/dets_helpers.ex` - Added LlmRegistry and DetsBackup to restart cycle with try/catch resilience

## Decisions Made
- Snapshot route placed before :id route to avoid "snapshot" being captured as parameter (same pattern as tasks/dead-letter before tasks/:task_id)
- resource_report is fire-and-forget (no reply) matching existing task_progress pattern
- :number type accepts both integer and float -- needed because CPU percent is float, byte counts could be either
- LlmRegistry tests refactored from standalone GenServer.start_link to Supervisor.terminate_child/restart_child for compatibility with supervisor tree

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] LlmRegistry test supervisor conflict**
- **Found during:** Task 1
- **Issue:** Adding LlmRegistry to supervisor tree caused 107 test failures -- LlmRegistry tests manually stopped/started the GenServer, conflicting with supervisor management and cascading to DetsHelpers restart cycle
- **Fix:** Refactored LlmRegistry tests to use Supervisor.terminate_child/restart_child. Added LlmRegistry to DetsHelpers restart cycle with try/catch resilience for edge cases.
- **Files modified:** test/agent_com/llm_registry_test.exs, test/support/dets_helpers.ex
- **Verification:** All 337 tests pass (0 failures, down from 107)
- **Committed in:** 8f83d96 (Task 1 commit)

**2. [Rule 3 - Blocking] Missing :number validation type**
- **Found during:** Task 2
- **Issue:** resource_report schema uses :number type for CPU/RAM/VRAM fields, but validation module only supported :string, :integer, :positive_integer, :map, :boolean, :any
- **Fix:** Added :number type to validate_type, valid_type?, format_type_name in validation.ex and format_type in schemas.ex
- **Files modified:** lib/agent_com/validation.ex, lib/agent_com/validation/schemas.ex
- **Verification:** Compiles cleanly, all tests pass
- **Committed in:** f425745 (Task 2 commit)

**3. [Rule 1 - Bug] Validation test asserting wrong schema count**
- **Found during:** Task 2
- **Issue:** Existing test asserted 15 WS message types, now 17 with ollama_report and resource_report
- **Fix:** Updated assertion from 15 to 17 and added new types to expected list
- **Files modified:** test/agent_com/validation_test.exs
- **Verification:** Test passes
- **Committed in:** f425745 (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (1 bug, 2 blocking)
**Impact on plan:** All fixes necessary for correctness and test compatibility. No scope creep.

## Issues Encountered
None beyond the deviations documented above.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- LlmRegistry fully wired: supervisor, WS handlers, HTTP admin routes, validation schemas
- Plan 04 (dashboard) can read from GET /api/admin/llm-registry/snapshot for real-time registry view
- All 8 LlmRegistry public API functions are accessible via WS and HTTP transport

## Self-Check: PASSED

- [x] lib/agent_com/application.ex exists (LlmRegistry in supervisor)
- [x] lib/agent_com/socket.ex exists (ollama_report, resource_report handlers)
- [x] lib/agent_com/endpoint.ex exists (HTTP admin routes)
- [x] lib/agent_com/validation/schemas.ex exists (new WS + HTTP schemas)
- [x] lib/agent_com/validation.ex exists (:number type support)
- [x] test/agent_com/llm_registry_test.exs exists (supervisor-compatible)
- [x] test/agent_com/validation_test.exs exists (17 types assertion)
- [x] test/support/dets_helpers.ex exists (LlmRegistry in restart cycle)
- [x] 18-03-SUMMARY.md exists
- [x] Commit 8f83d96 (Task 1) exists
- [x] Commit f425745 (Task 2) exists
- [x] Commit 783353f (test infrastructure) exists

---
*Phase: 18-llm-registry-host-resources*
*Completed: 2026-02-12*
