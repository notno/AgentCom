---
phase: 32-improvement-scanning
plan: 03
subsystem: self-improvement
tags: [llm-scanner, orchestrator, hub-fsm, improving-state, goal-submission]

# Dependency graph
requires:
  - phase: 32-01
    provides: Finding struct and ImprovementHistory module
  - phase: 32-02
    provides: CredoScanner, DialyzerScanner, DeterministicScanner modules
provides:
  - "AgentCom.SelfImprovement.LlmScanner for git diff analysis via ClaudeClient"
  - "AgentCom.SelfImprovement orchestrator with scan_repo, scan_all, submit_findings_as_goals, run_improvement_cycle"
  - "HubFSM :improving state with async improvement cycle and resting/executing transitions"
  - "Predicates resting->improving (idle+budget) and improving->executing (goals submitted)"
affects: [32-04, 34-tiered-autonomy]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Async Task.start for non-blocking improvement cycle in GenServer"
    - "Message-based completion notification: {:improvement_cycle_complete, result}"
    - "Three-layer scanning: Elixir tools -> deterministic -> LLM (budget-gated)"

key-files:
  created:
    - lib/agent_com/self_improvement/llm_scanner.ex
    - lib/agent_com/self_improvement.ex
  modified:
    - lib/agent_com/hub_fsm.ex
    - lib/agent_com/hub_fsm/predicates.ex

key-decisions:
  - "LLM scanner only runs when deterministic findings don't fill max_findings budget"
  - "Async Task.start for improvement cycle to avoid blocking HubFSM GenServer"
  - "set_hub_state uses actual new_state instead of always :executing"

patterns-established:
  - "Three-layer scan priority: deterministic first (free), LLM last (costly)"
  - "Max-findings budget prevents goal flooding across scanning layers"

# Metrics
duration: 7min
completed: 2026-02-14
---

# Phase 32 Plan 03: LLM Scanner, Orchestrator, and Improving State Summary

**LLM-assisted diff scanner, 4-scanner orchestrator with budget-gated LLM layer, and HubFSM improving state with async scan cycle**

## Performance

- **Duration:** 7 min
- **Started:** 2026-02-14T03:17:09Z
- **Completed:** 2026-02-14T03:24:31Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- LlmScanner wraps ClaudeClient.identify_improvements with CostLedger budget check and 50KB diff cap
- SelfImprovement orchestrator runs all 4 scanners (Credo, Dialyzer, Deterministic, LLM) with cooldown/oscillation filtering and max-findings budget enforcement
- HubFSM transitions to :improving when resting with no goals and improving budget available
- Async improvement cycle spawns via Task.start, sends completion message back to GenServer
- Findings converted to low-priority goals via GoalBacklog.submit with ImprovementHistory recording

## Task Commits

Each task was committed atomically:

1. **Task 1: Create LlmScanner and SelfImprovement orchestrator** - `d7b38fd` (feat)
2. **Task 2: Add Improving state to HubFSM and Predicates** - `2050c03` (feat)

## Files Created/Modified
- `lib/agent_com/self_improvement/llm_scanner.ex` - LLM-assisted git diff scanner with budget checking and 50KB cap
- `lib/agent_com/self_improvement.ex` - Main orchestrator: scan_repo, scan_all, submit_findings_as_goals, run_improvement_cycle
- `lib/agent_com/hub_fsm.ex` - Updated valid_transitions, gather_system_state, do_transition, and async improvement cycle
- `lib/agent_com/hub_fsm/predicates.ex` - Added resting->improving and improving->executing predicates

## Decisions Made
- **LLM as last resort:** LLM scanner only invoked when deterministic findings don't fill the max_findings budget, minimizing API costs
- **Async Task.start:** Improvement cycle runs in a separate process to avoid blocking the 1-second tick; completion signals transition back to resting
- **set_hub_state fix:** Changed from always setting :executing to setting the actual new_state, so ClaudeClient correctly budgets improving vs executing calls

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed unused variable warnings in run_improvement_cycle**
- **Found during:** Task 1 (SelfImprovement orchestrator)
- **Issue:** by_repo grouping logic created unused variables, failing --warnings-as-errors
- **Fix:** Removed unused by_repo grouping; simplified to direct submit_findings_as_goals call
- **Files modified:** lib/agent_com/self_improvement.ex
- **Verification:** mix compile --warnings-as-errors passes
- **Committed in:** d7b38fd (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Minor code cleanup. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Complete improvement scanning pipeline operational: HubFSM tick -> improving transition -> async scan -> findings -> goals -> resting
- Ready for Plan 04 (tests and integration verification)

## Self-Check: PASSED

- All 4 source files exist on disk
- Commit d7b38fd (LlmScanner + SelfImprovement) verified in git log
- Commit 2050c03 (HubFSM + Predicates) verified in git log

---
*Phase: 32-improvement-scanning*
*Completed: 2026-02-14*
