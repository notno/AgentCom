---
phase: 30-goal-decomposition-and-inner-loop
plan: 01
subsystem: orchestration
tags: [dag, topological-sort, file-tree, path-wildcard, kahn-algorithm]

requires:
  - phase: 28-task-queue-and-goal-backlog
    provides: "TaskQueue for dependency-validated task submission"
provides:
  - "FileTree.gather/1 for cross-platform repository file listing"
  - "FileTree.validate_references/2 for catching hallucinated file paths"
  - "DagValidator.validate/1 for dependency graph validation"
  - "DagValidator.topological_order/1 for task submission ordering"
  - "DagValidator.resolve_indices_to_ids/2 for index-to-ID mapping"
affects: [30-02, 30-03, goal-orchestrator, decomposer, verifier]

tech-stack:
  added: []
  patterns: [kahns-algorithm, path-expand-windows-compat, mapset-lookup]

key-files:
  created:
    - lib/agent_com/goal_orchestrator/file_tree.ex
    - lib/agent_com/goal_orchestrator/dag_validator.ex
    - test/agent_com/goal_orchestrator/file_tree_test.exs
    - test/agent_com/goal_orchestrator/dag_validator_test.exs

key-decisions:
  - "Path.expand before Path.wildcard for Windows cross-platform compatibility"
  - "Forward-only dependency constraint: task N can only depend on tasks 1..N-1"
  - "Kahn's algorithm via list-based queue (not :queue) for simplicity"

patterns-established:
  - "Pure library modules under goal_orchestrator/ (no GenServer, no PubSub)"
  - "Path.expand normalization for all filesystem operations on Windows"

duration: 7min
completed: 2026-02-14
---

# Phase 30 Plan 01: FileTree and DagValidator Summary

**Cross-platform file tree gathering with Path.expand normalization and Kahn's algorithm DAG validation for task dependency ordering**

## Performance

- **Duration:** 7 min
- **Started:** 2026-02-14T03:09:18Z
- **Completed:** 2026-02-14T03:15:53Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- FileTree.gather/1 lists repository files cross-platform using Path.expand + Path.wildcard, excluding noise directories
- FileTree.validate_references/2 catches LLM-hallucinated file paths in task descriptions via regex + MapSet lookup
- DagValidator.validate/1 enforces index range, forward-only deps, and acyclicity via Kahn's algorithm
- DagValidator.topological_order/1 provides correct task submission ordering for TaskQueue
- DagValidator.resolve_indices_to_ids/2 maps 1-based planning indices to actual task IDs

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement FileTree module** - `f04b309` (feat)
2. **Task 2: Implement DagValidator module** - `fd0b687` (feat)

## Files Created/Modified
- `lib/agent_com/goal_orchestrator/file_tree.ex` - Cross-platform file tree gathering and reference validation
- `lib/agent_com/goal_orchestrator/dag_validator.ex` - DAG cycle detection, index validation, topological ordering
- `test/agent_com/goal_orchestrator/file_tree_test.exs` - 9 tests for gather/1 and validate_references/2
- `test/agent_com/goal_orchestrator/dag_validator_test.exs` - 14 tests for validate/1, topological_order/1, resolve_indices_to_ids/2

## Decisions Made
- **Path.expand for Windows compatibility:** Path.wildcard fails with mixed separators from System.tmp_dir!/Path.join on Windows. Path.expand normalizes to forward slashes and lowercase drive letter, fixing glob resolution.
- **Forward-only dependency constraint:** Tasks can only depend on earlier-indexed tasks (dep < task_idx), ensuring the LLM produced a valid ordering without needing full cycle detection for most cases.
- **List-based Kahn's queue:** Used simple list pattern matching instead of :queue module for readability; task counts are small enough that O(n) append is negligible.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Path.wildcard Windows cross-platform fix**
- **Found during:** Task 1 (FileTree implementation)
- **Issue:** Path.wildcard returns empty list on Windows when path contains mixed separators (backslash from System.tmp_dir! + forward slash from Path.join)
- **Fix:** Added Path.expand call before Path.wildcard to normalize all separators to forward slashes
- **Files modified:** lib/agent_com/goal_orchestrator/file_tree.ex
- **Verification:** All 9 FileTree tests pass on Windows
- **Committed in:** f04b309 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Essential for cross-platform correctness. No scope creep.

## Issues Encountered
- Pre-existing compilation error: `handle_github_event/4` undefined in endpoint.ex (from phase 31 commit). Linter auto-resolved by adding the function definition during file save.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- FileTree and DagValidator ready for GoalOrchestrator.Decomposer (Plan 30-02)
- Both modules are pure functions with no GenServer dependencies
- All 23 tests pass with async: true

## Self-Check: PASSED

- All 4 created files verified on disk
- Both task commits (f04b309, fd0b687) verified in git log

---
*Phase: 30-goal-decomposition-and-inner-loop*
*Completed: 2026-02-14*
