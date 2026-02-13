# Phase 34: Tiered Autonomy - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Risk classification for completed tasks. Tier 1 (small, safe) vs Tier 2 (larger, needs review) vs Tier 3 (dangerous, block). Default mode is PR-only -- no auto-merge until pipeline is proven reliable through production data.
</domain>

<decisions>
## Implementation Decisions

### Risk Tiers
- Tier 1 (auto-merge candidate): trivial/standard complexity, <20 lines changed, test-covered, no new files, no config changes
- Tier 2 (PR for review): complex tasks, new files, API changes, >20 lines
- Tier 3 (block and escalate): auth code, deployment config, failed verification
- Start conservative: all tiers produce PRs (PR-only mode)
- Auto-merge enabled per-tier only after configurable success threshold (e.g., 20 successful PRs)

### Classification Logic
- Based on: complexity_tier from task, lines changed, files touched, file paths (protected path list), whether tests exist for changed files
- Pure function module (no GenServer needed)
- Configurable thresholds via Config GenServer

### PR-Only Default
- Every completed task creates a PR regardless of tier
- PR description includes risk tier classification and reasoning
- Human reviews and merges (or configures auto-merge for specific tiers later)

### Claude's Discretion
- Specific threshold values for each tier
- Protected path list (which directories/files trigger Tier 3)
- PR description template
- How to track successful PR history for auto-merge enablement
</decisions>

<specifics>
## Specific Ideas

- Risk classification feeds into dashboard (Phase 36) -- show tier distribution
- Consider a "confidence" score alongside tier classification
- Auto-merge enablement should be per-repo (some repos are safer than others)
</specifics>

<constraints>
## Constraints

- Depends on Phase 29 (HubFSM), Phase 30 (Goal Decomposition producing tasks)
- PR-only mode is the mandatory default -- no auto-merge in v1.3
- Must integrate with existing git-workflow.js sidecar tooling
- Thresholds configurable without code changes
</constraints>
