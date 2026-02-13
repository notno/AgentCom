# Phase 32: Improvement Scanning - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Hub autonomously identifies codebase improvements during Improving state. Three scanning layers: deterministic tools (Credo, Dialyzer), deterministic analysis (test gaps, doc gaps, dead deps), and LLM-assisted review (git diff analysis). Scans repos in priority order. Anti-Sisyphus protections: improvement history, file cooldowns, oscillation detection.
</domain>

<decisions>
## Implementation Decisions

### Three Scanning Layers
1. **Elixir tool integration**: Run `mix credo` and `mix dialyzer` on Elixir repos. Parse structured output for actionable findings.
2. **Deterministic analysis**: Test coverage gaps (modules without test files), documentation gaps (modules without @moduledoc), dead dependencies (deps in mix.exs not used in code).
3. **LLM-assisted review**: Send git diff (recent changes) + file context to Claude Code CLI. Ask for refactoring, simplification, and improvement opportunities.

### Scanning Strategy
- Cycle through repos in priority order (RepoRegistry)
- Per repo: run deterministic scans first (no LLM cost), then LLM scans
- Convert findings to goals in GoalBacklog (each finding becomes a goal with success criteria)
- Rate limit: configurable max findings per scan cycle

### Anti-Sisyphus Protections (Pitfall #2)
- Improvement history in DETS: track what was changed, when, by which scan
- File-level cooldowns: after improving file X, don't re-scan X for configurable period (default 24h)
- Anti-oscillation: if consecutive improvements to same file have inverse patterns, block and alert
- Improvement budget: max N findings per scan cycle (prevent unbounded goal creation)

### Claude's Discretion
- Credo/Dialyzer output parsing strategy
- Finding priority classification (which findings become goals first)
- LLM prompt design for improvement identification
- Cooldown duration defaults
- How to detect oscillation patterns
</decisions>

<specifics>
## Specific Ideas

- SelfImprovement module as a library (not GenServer) -- called by HubFSM during Improving state
- Findings should include estimated effort/complexity for tiered autonomy (Phase 34)
- Consider tracking "improvement value" -- did the improvement actually make things better?
</specifics>

<constraints>
## Constraints

- Depends on Phase 26 (ClaudeClient for LLM scans), Phase 29 (HubFSM Improving state)
- Credo and Dialyzer must be available in the project's mix.exs
- Anti-oscillation detection is mandatory (Pitfall #2 prevention)
- Self-generated improvement goals default to "low" priority in GoalBacklog
</constraints>
