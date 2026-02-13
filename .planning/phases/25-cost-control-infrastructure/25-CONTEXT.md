# Phase 25: Cost Control Infrastructure - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

CostLedger GenServer tracking Claude Code CLI invocations and throughput. The hub uses Claude Code Max plan ($200/month) not per-token API -- so cost tracking is about invocation counts and usage limits, not dollar amounts. Must exist before the Hub FSM makes its first Claude Code call.
</domain>

<decisions>
## Implementation Decisions

### Cost Model
- Hub uses `claude -p` CLI (Claude Code Max subscription), not Messages API
- Track invocations per hour/day/session rather than token costs
- Max plan has usage limits -- CostLedger enforces configurable invocation budgets
- Per-state budgets: configurable limits for Executing, Improving, Contemplating states

### Budget Enforcement
- Synchronous check before every Claude Code invocation -- CostLedger.check_budget/1 returns :ok or :budget_exhausted
- If budget exhausted, caller knows to transition FSM to Resting
- Hard caps in code, not in prompts -- the LLM cannot be trusted to self-limit

### Telemetry
- Emit :telemetry events for each invocation: [:agent_com, :hub, :claude_call]
- Wire into existing Alerter with new rule for hub invocation rate
- Track invocation duration (CLI spawn time) for performance monitoring

### Persistence
- DETS-backed for invocation history (survives hub restart)
- ETS for hot-path budget checks (fast reads)
- Register with DetsBackup from day one

### Claude's Discretion
- Specific budget defaults per state
- Invocation history retention period
- Whether to track per-goal or per-state granularity
- Reset schedule (daily? rolling window?)
</decisions>

<specifics>
## Specific Ideas

- Budget format: {state, max_invocations_per_hour, max_invocations_per_day}
- Consider a "burst" allowance for Executing state (goal decomposition might need several calls quickly)
- Dashboard panel showing invocation rate over time (feeds into Phase 36)
</specifics>

<constraints>
## Constraints

- Must be production-ready before Phase 26 (ClaudeClient) ships
- Cannot depend on any other v1.3 phase
- Must follow existing GenServer + DETS patterns (TaskQueue, RepoRegistry)
</constraints>
