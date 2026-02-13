# Phase 30: Goal Decomposition and Inner Loop - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

LLM-powered goal decomposition via Claude Code CLI. Goals become 3-8 enriched tasks with dependency graphs. Ralph-style inner loop: decompose -> submit -> monitor -> verify completion. File-tree grounding prevents hallucinated tasks.
</domain>

<decisions>
## Implementation Decisions

### Decomposition via Claude Code CLI
- Hub calls ClaudeClient (Phase 26) which spawns `claude -p`
- Prompt includes: goal description, success criteria, file tree listing, codebase context
- Output format at Claude's discretion during planning (JSON, XML, or structured text)
- Post-decomposition validation: check that referenced files/modules actually exist

### Elephant Carpaccio Slicing
- Each task should be completable in one agent context window (15-30 min of work)
- Typical decomposition: 3-8 tasks per goal
- If LLM returns fewer than 2 tasks, the goal might be atomic -- submit as single task
- If LLM returns more than 10 tasks, consider it a smell -- may need goal refinement

### Dependency Graph
- Decomposition produces parallel + sequential markers
- Independent tasks get no depends_on (can run simultaneously via Phase 28)
- Sequential tasks carry depends_on references to their prerequisites
- Graph is a DAG -- no cycles (decomposition prompt should enforce this)

### File-Tree Grounding (Pitfall #5 Prevention)
- Before calling Claude, gather: `ls -R lib/` + `ls -R sidecar/` output
- Include in prompt: "These are the ONLY files that exist. Do NOT reference files not in this list."
- Post-decomposition: validate every file path mentioned in task descriptions exists
- If validation fails, re-prompt with specific "file X does not exist" feedback

### Ralph Inner Loop
- Goal lifecycle: submitted -> decomposing -> executing -> verifying -> complete/failed
- After decomposition: submit all tasks to TaskQueue with goal_id and depends_on
- Monitor: subscribe to PubSub task completion events, aggregate by goal_id
- When all tasks complete: run goal-level verification
- If verification fails: redecompose with gap context (max 2 retries)

### Goal Completion Verification
- Call ClaudeClient with: original goal + success criteria + task results
- Claude judges: "Are all success criteria met based on these task outcomes?"
- If gaps identified: create follow-up tasks to address gaps (not full redecomposition)
- Max 2 verification-retry cycles per goal, then mark as needs_human_review

### Claude's Discretion
- Decomposition prompt template design
- Output format (JSON/XML/structured text)
- Verification prompt design
- How to handle partial decomposition failures
- Task description detail level
</decisions>

<specifics>
## Specific Ideas

- First 10-20 decompositions should be reviewed by Nathan to calibrate prompt quality
- Consider storing decomposition prompts and responses for debugging
- Goal verification should include both LLM judgment AND mechanical checks (tests pass, files exist)
</specifics>

<constraints>
## Constraints

- Depends on Phase 26 (ClaudeClient), Phase 27 (GoalBacklog), Phase 28 (Pipeline Dependencies), Phase 29 (HubFSM)
- Must produce enriched tasks compatible with existing v1.2 task format
- File-tree grounding is mandatory (Pitfall #5 prevention)
- Max 2 verification retries to prevent infinite loops
</constraints>
