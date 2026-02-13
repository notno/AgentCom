# Phase 28: Pipeline Dependencies - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Extend TaskQueue and Scheduler to support task dependencies. Tasks gain optional `depends_on` (list of prerequisite task IDs) and `goal_id` (parent goal reference). Scheduler filters out tasks whose dependencies are incomplete. This enables goal decomposition to produce dependency graphs with parallel and sequential tasks.
</domain>

<decisions>
## Implementation Decisions

### Task Struct Extension
- Add `depends_on`: list of task IDs that must complete before this task can be scheduled
- Add `goal_id`: reference to parent goal (for goal-level progress tracking)
- Both fields optional -- existing tasks continue working unchanged (backward compatible)

### Scheduler Filter
- ~15-line addition to try_schedule_all after existing paused-repo filter
- For each candidate task, check if all depends_on tasks have status "completed"
- O(d) check per task where d is typically 0-3 dependencies
- No graph library needed -- each task knows its predecessors

### Goal Progress Tracking
- TaskQueue can aggregate completion status by goal_id
- Enables "3 of 7 tasks complete for Goal X" reporting
- GoalBacklog (Phase 27) subscribes to task completion events and updates goal progress

### Claude's Discretion
- Whether depends_on validation should check task existence at submission time
- How circular dependencies are detected (if at all -- decomposition should prevent them)
- Whether to add an API endpoint for querying tasks by goal_id
</decisions>

<specifics>
## Specific Ideas

- Minimal change to core pipeline -- this is a filter addition, not a rewrite
- Test with a simple 3-task chain: A -> B -> C (B depends on A, C depends on B)
- Verify that independent tasks (no depends_on) schedule normally -- no regression
</specifics>

<constraints>
## Constraints

- Must not break existing task submission or scheduling
- Backward compatible -- tasks without depends_on behave exactly as before
- Extends existing TaskQueue DETS schema (add fields, don't restructure)
</constraints>
