# Phase 33: Contemplation and Scalability - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Hub generates structured feature proposals during Contemplating state and scalability analysis reports from existing metrics. Max 3 proposals per contemplation cycle.
</domain>

<decisions>
## Implementation Decisions

### Contemplation (Feature Proposals)
- Hub enters Contemplating when Improving finds nothing to improve
- Analyzes codebase structure, backlog patterns, known tech debt
- Generates max 3 proposals per cycle, then transitions to Resting
- Proposals written as XML files in a `proposals/` directory
- Human reviews and optionally promotes to goal backlog
- Not self-executing -- contemplation produces documents, not tasks

### Proposal Structure
- Problem statement, proposed solution, estimated complexity, dependencies
- Grounded in actual codebase (file references, module analysis)
- Includes "why now" and "why not" sections
- Scope-constrained: proposals must be achievable in one milestone phase

### Scalability Analysis
- Read existing ETS metrics (queue depth, latency, agent utilization)
- Analyze trends: is throughput growing? Are agents saturated?
- Produce structured report recommending machines vs agents
- No LLM needed for basic stats -- pure metric analysis
- Optional: Claude Code analysis for recommendations on complex bottlenecks

### Claude's Discretion
- Proposal XML schema design
- Scalability report format (XML, markdown, or both)
- How to identify "interesting" features to propose (what makes a good proposal)
- Whether to integrate with existing tech debt list from PROJECT.md
</decisions>

<specifics>
## Specific Ideas

- Contemplation should read PROJECT.md Out of Scope section to avoid proposing excluded features
- Proposals should reference research sources when possible
- Scalability report could recommend specific next purchases (GPU machine, more RAM, etc.)
</specifics>

<constraints>
## Constraints

- Depends on Phase 26 (ClaudeClient), Phase 29 (HubFSM Contemplating state)
- Max 3 proposals per cycle (hard limit to prevent unbounded contemplation)
- Proposals are passive -- human must promote to goal backlog
- Scalability analysis uses existing MetricsCollector data, no new instrumentation
</constraints>
