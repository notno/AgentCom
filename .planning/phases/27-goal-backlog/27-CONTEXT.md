# Phase 27: Goal Backlog - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

DETS-backed GoalBacklog GenServer for centralized goal storage with lifecycle tracking, priority ordering, and multi-source intake. Goals are higher-level than tasks -- a goal decomposes into 1-N tasks. Follows the established TaskQueue/RepoRegistry GenServer + DETS pattern.
</domain>

<decisions>
## Implementation Decisions

### Goal Structure
- Unique goal ID (UUID or sequential)
- Description, success criteria (required at submission)
- Priority lanes: urgent/high/normal/low (same pattern as TaskQueue)
- Lifecycle: submitted -> decomposing -> executing -> verifying -> complete/failed
- Tracks child task IDs after decomposition
- Source field: api/cli/internal (for tracking where goals come from)

### Multi-Source Input
- HTTP API endpoint: POST /api/goals with description + success_criteria + priority
- CLI tool: `agentcom-submit-goal.js` (Node.js, follows existing sidecar CLI pattern)
- Internal generation: HubFSM (Phase 29) and SelfImprovement (Phase 32) create goals programmatically

### Parallel Goal Processing
- Goals are independent by default -- multiple can execute simultaneously
- Before decomposing a new goal, preprocessing step checks: "does this depend on anything currently executing or in the backlog?"
- Dependency detection at Claude's discretion (keyword matching, file overlap, explicit user annotation)

### PubSub Integration
- Publish on "goals" topic for state changes
- FSM-08 requirement: goal backlog changes wake FSM from Resting to Executing

### Claude's Discretion
- Goal ID format (UUID vs sequential with prefix)
- DETS key structure (single key vs per-goal keys)
- Dependency detection approach between goals
- API response format
- CLI tool design
</decisions>

<specifics>
## Specific Ideas

- Goal struct should carry enough context for decomposition (repo, file hints, relevant modules)
- Consider a `tags` field for categorization (refactor, feature, docs, test, etc.)
- Goal backlog stats endpoint for dashboard (Phase 36)
</specifics>

<constraints>
## Constraints

- Register DETS table with DetsBackup from day one
- Follow existing validation patterns (add schemas to Validation.Schemas)
- Goal lifecycle events must trigger PubSub for FSM consumption
</constraints>
