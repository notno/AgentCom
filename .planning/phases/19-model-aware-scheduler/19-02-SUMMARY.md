---
phase: 19-model-aware-scheduler
plan: 02
subsystem: scheduler
tags: [routing, scheduling, fallback-timers, pubsub, telemetry, tier-aware]

# Dependency graph
requires:
  - phase: 19-01
    provides: "TaskRouter.route/3 pure-function routing decisions"
  - phase: 18-llm-registry
    provides: "LlmRegistry.list_endpoints/0 and get_resources/1 for endpoint data"
  - phase: 17-complexity-heuristic
    provides: "Complexity.build/1 producing effective_tier for routing"
provides:
  - "Scheduler with tier-aware routing via TaskRouter.route/3 integration"
  - "TaskQueue.store_routing_decision/2 for persisting routing decisions on tasks"
  - "Fallback timer state management with cancel on assign/complete/reclaim/dead_letter"
  - "LLM registry PubSub subscription for endpoint recovery re-evaluation"
  - "Routing telemetry events: scheduler:route and scheduler:fallback"
affects: [19-03-fallback-timeouts, 19-04-dashboard-routing, 20-execution-engine]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Stateful fallback timer management with cleanup on all task lifecycle events", "Routing-then-capability-matching fallback for backward compatibility", "Routing decision propagation through assignment pipeline to WebSocket push"]

key-files:
  created: []
  modified:
    - lib/agent_com/scheduler.ex
    - lib/agent_com/task_queue.ex
    - lib/agent_com/telemetry.ex
    - test/agent_com/scheduler_test.exs

key-decisions:
  - "Capability matching fallback when TaskRouter returns fallback signal (backward compatible with no LLM endpoints)"
  - "Store routing_decision before assign_task to ensure it persists even if assignment fails"
  - "Emit routing telemetry for both successful routes and fallback decisions (full observability)"
  - "Prefer endpoint-matching agent for :ollama target, fall back to any capable agent"
  - "Single pending fallback per task_id (skip if timer already exists)"

patterns-established:
  - "Stateful scheduler: pending_fallbacks map keyed by task_id with timer_ref for cleanup"
  - "Routing-first scheduling: route via TaskRouter, then find agent matching decision"
  - "Graceful degradation: when routing fails, fall back to existing capability matching"

# Metrics
duration: 7min
completed: 2026-02-12
---

# Phase 19 Plan 02: Scheduler Routing Integration Summary

**Tier-aware scheduler routing via TaskRouter with fallback timer state management, LLM registry PubSub subscription, routing decision persistence on tasks, and routing telemetry**

## Performance

- **Duration:** 7 min
- **Started:** 2026-02-12T22:08:57Z
- **Completed:** 2026-02-12T22:16:26Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Scheduler now routes every queued task through TaskRouter.route/3 before agent matching, with endpoint data from LlmRegistry
- Routing decisions are persisted on task maps via store_routing_decision/2 and included in task_data sent to agents
- Fallback timers fire after 5s timeout with proper cleanup on assign, complete, reclaim, and dead-letter events
- LLM registry PubSub subscription triggers scheduling re-evaluation when endpoints recover or register
- Full backward compatibility: all 9 existing scheduler tests pass without modification

## Task Commits

Each task was committed atomically:

1. **Task 1: Add routing_decision field to TaskQueue and routing telemetry event** - `4dd7515` (feat)
2. **Task 2: Augment Scheduler with tier routing, fallback timers, and llm_registry subscription** - `c56409b` (feat)

## Files Created/Modified
- `lib/agent_com/scheduler.ex` - Augmented with tier-aware routing, fallback timers, LLM registry subscription, and routing telemetry
- `lib/agent_com/task_queue.ex` - Added routing_decision field on task map and store_routing_decision/2 API
- `lib/agent_com/telemetry.ex` - Registered scheduler:route and scheduler:fallback telemetry events
- `test/agent_com/scheduler_test.exs` - Added 2 new routing tests (decision stored, fallback for standard tier)

## Decisions Made
- **Capability matching fallback:** When TaskRouter returns a fallback signal (no healthy endpoints), the scheduler still tries existing capability matching as graceful degradation. This ensures backward compatibility when no LLM endpoints are registered.
- **Store before assign:** Routing decision is stored on the task via store_routing_decision/2 before calling assign_task/2, ensuring the decision persists even if assignment fails or the task is reassigned later.
- **Full routing telemetry:** Both successful routes and fallback decisions emit scheduler:route telemetry with complete metadata for observability.
- **Endpoint preference for ollama:** For :ollama target type, the scheduler prefers agents whose ollama_url host matches the selected endpoint, falling back to any capable agent if no match.
- **Single pending fallback:** Only one fallback timer per task_id to prevent timer accumulation.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed fallback test to use explicit complexity_tier**
- **Found during:** Task 2 (scheduler test writing)
- **Issue:** Test used a short description that classified as :trivial (routes to sidecar, no fallback). Needed :standard tier to trigger fallback when no Ollama endpoints exist.
- **Fix:** Used TaskQueue.submit directly with complexity_tier: "standard" parameter instead of TestFactory
- **Files modified:** test/agent_com/scheduler_test.exs
- **Verification:** Test passes, correctly verifies fallback_used: true
- **Committed in:** c56409b (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Test data correction only. No scope creep.

## Issues Encountered
None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Scheduler integration complete, ready for Plan 03 (fallback timeout refinement/testing)
- Routing decisions are available on task maps for Plan 04 (dashboard routing display)
- Full test suite passes: 393 tests, 0 failures

## Self-Check: PASSED

- All 4 modified files exist on disk
- Commit 4dd7515 (Task 1) verified in git log
- Commit c56409b (Task 2) verified in git log
- 11/11 scheduler tests pass, 47/47 TaskQueue tests pass
- Full suite: 393 tests, 0 failures, 0 warnings

---
*Phase: 19-model-aware-scheduler*
*Completed: 2026-02-12*
