---
phase: 30-goal-decomposition-and-inner-loop
plan: 02
subsystem: orchestration
tags: [decomposer, verifier, llm, dag, goal-lifecycle, task-submission]

requires:
  - phase: 26-claude-client
    provides: ClaudeClient.decompose_goal/2 and verify_completion/2 GenServer calls
  - phase: 27-goal-backlog
    provides: GoalBacklog with lifecycle state machine
  - phase: 28-pipeline-dependencies
    provides: TaskQueue.submit/1 with goal_id and depends_on fields
  - phase: 30-01
    provides: FileTree.gather/1, DagValidator.validate/1, DagValidator.topological_order/1
provides:
  - Decomposer.decompose/1 full pipeline from goal to submitted tasks
  - Verifier.verify/2 verification pipeline with retry count enforcement
  - Verifier.create_followup_tasks/2 targeted gap-closing task creation
affects: [30-03-goal-orchestrator-genserver, hub-fsm-executing-tick]

tech-stack:
  added: []
  patterns:
    - "Pipeline-as-with-chain for multi-step orchestration with early exit"
    - "Public helper extraction for unit-testable pure logic in integration modules"
    - "Priority integer-to-string mapping via module attribute constant map"

key-files:
  created:
    - lib/agent_com/goal_orchestrator/decomposer.ex
    - lib/agent_com/goal_orchestrator/verifier.ex
    - test/agent_com/goal_orchestrator/decomposer_test.exs
    - test/agent_com/goal_orchestrator/verifier_test.exs
  modified: []

key-decisions:
  - "Used RepoRegistry.list_repos/0 (not list/0) with fallback to File.cwd! for repo path resolution"
  - "Public helper functions (build_context, validate_task_count, build_submit_params, priority_to_string, build_results_summary, build_followup_params, bump_priority) extracted for unit testability"
  - "Verifier retry max at 2 (module attribute @max_retries) per user constraint"

patterns-established:
  - "Decomposer with-chain: resolve_repo -> gather_tree -> build_context -> call_claude -> validate_count -> validate_dag -> validate_refs -> submit"
  - "Verifier gap-to-followup-task pattern: critical gaps get priority bump, minor gaps keep goal priority"

duration: 8min
completed: 2026-02-14
---

# Phase 30 Plan 02: Decomposer and Verifier Summary

**Decomposer pipeline (repo resolve through topological task submission with LLM retry) and Verifier pipeline (result gathering, LLM verification, gap-based follow-up tasks with 2-retry cap)**

## Performance

- **Duration:** 8 min
- **Started:** 2026-02-14T03:09:57Z
- **Completed:** 2026-02-14T03:17:41Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Decomposer.decompose/1 implements full 8-step pipeline: repo path resolution, file tree gathering, context building, LLM call with retry on transient errors, task count validation, DAG validation with re-prompt, file reference validation with strip-fallback, and topological task submission
- Verifier.verify/2 gathers task results, calls ClaudeClient.verify_completion/2, and enforces max 2 retry cycles before returning :needs_human_review
- Verifier.create_followup_tasks/2 creates targeted gap-closing tasks with priority bump for critical-severity gaps
- 39 unit tests covering all public helper functions across both modules (20 decomposer + 19 verifier)

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement Decomposer module** - `9fb4246` (feat)
2. **Task 2: Implement Verifier module** - `4ee8c80` (feat)

## Files Created/Modified
- `lib/agent_com/goal_orchestrator/decomposer.ex` - Full decomposition pipeline: context building, LLM call with retry, DAG/file validation, topological task submission
- `lib/agent_com/goal_orchestrator/verifier.ex` - Verification pipeline: result gathering, LLM call, pass/fail/needs_human_review, follow-up task creation
- `test/agent_com/goal_orchestrator/decomposer_test.exs` - 20 tests for build_context, validate_task_count, build_submit_params, priority_to_string
- `test/agent_com/goal_orchestrator/verifier_test.exs` - 19 tests for build_results_summary, build_followup_params, bump_priority, retry boundaries

## Decisions Made
- Used `RepoRegistry.list_repos/0` instead of plan's `list/0` (which does not exist) -- Rule 1 bug fix
- Extracted all pure logic into public helper functions for unit testability without mocking ClaudeClient or TaskQueue
- Verifier max retries set as module attribute `@max_retries 2` for easy adjustment

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Used RepoRegistry.list_repos/0 instead of non-existent list/0**
- **Found during:** Task 1 (Decomposer implementation)
- **Issue:** Plan referenced `AgentCom.RepoRegistry.list/0` but the actual API is `list_repos/0`
- **Fix:** Used `list_repos/0` in resolve_repo_path/1
- **Files modified:** lib/agent_com/goal_orchestrator/decomposer.ex
- **Committed in:** 9fb4246

---

**Total deviations:** 1 auto-fixed (1 bug fix)
**Impact on plan:** Necessary correction for compilation. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Decomposer and Verifier modules ready for GoalOrchestrator GenServer (Plan 30-03) to call
- GoalOrchestrator will call Decomposer.decompose/1 during goal dequeue and Verifier.verify/2 when all tasks complete
- 62 total tests pass across the goal_orchestrator directory

## Self-Check: PASSED

All 4 created files verified on disk. Both task commits (9fb4246, 4ee8c80) verified in git log. 62 tests pass across goal_orchestrator directory. Compilation clean with --warnings-as-errors.

---
*Phase: 30-goal-decomposition-and-inner-loop*
*Completed: 2026-02-14*
