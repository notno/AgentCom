# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-13)

**Core value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.
**Current focus:** v1.3 Hub FSM Loop of Self-Improvement -- Phase 26 in progress

## Current Position

Phase: 31 of 36 (Hub Event Wiring)
Plan: 1/3 complete
Status: In Progress
Last activity: 2026-02-14 -- Plan 31-01 FSM Improving State + Webhook Infrastructure

Progress: [████░░░░░░░░░░] 33% (1/3 plans)

## Performance Metrics

**Velocity:**
- Total plans completed: 90 (19 v1.0 + 32 v1.1 + 25 v1.2 + 14 v1.3)
- Average duration: 4 min
- Total execution time: ~5.5 hours

**Milestones:**

| Milestone | Phases | Plans | Commits | Files | LOC | Duration |
|-----------|--------|-------|---------|-------|-----|----------|
| v1.0 | 1-8 | 19 | 48 | 65 | +12,858 | 2 days |
| v1.1 | 9-16 | 32 | 153 | 195 | +35,732 | 4 days |
| v1.2 | 17-23 | 25 | 136 | 147 | +26,075 | 1 day |
| v1.3 | 24-36 | TBD | - | - | - | In progress |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
v1.1 decisions archived to .planning/milestones/v1.1-ROADMAP.md (100 decisions across 32 plans).
v1.2 decisions archived to .planning/milestones/v1.2-ROADMAP.md (96 decisions across 25 plans).
- [Phase 28]: tasks_for_goal must scan both tasks and dead_letter tables for accurate goal_progress counts
- [Phase 29]: Tick-based evaluation at 1s intervals (not per-event) for HubFSM transitions
- [Phase 29]: Pure Predicates module separated from GenServer for testability
- [Phase 29]: ETS ordered_set with negated timestamps for newest-first History reads
- [Phase 29]: Hub FSM state/history endpoints unauthenticated (dashboard reads); pause/resume require auth
- [Phase 29]: async: true for Predicates tests (pure), async: false for History/HubFSM (shared ETS/GenServer)
- [Phase 29]: Real GenServer deps in integration tests (not mocks) -- follows existing test patterns

### Decisions (v1.3)

- Convention-based XML validation via Elixir structs (not XSD) -- internal-only docs don't need formal schemas
- Custom Saxy.Builder protocol implementations for list fields -- @derive doesn't handle nested lists
- SimpleForm-based parsing with shared Parser helpers -- simpler than raw SAX for small flat docs
- All 77 XML tests passed on first run -- Plan 01 implementation was correct, no source fixes needed in TDD phase
- CostLedger fail-open on ETS/Config unavailability -- safety during startup outweighs cost risk
- Dual-layer DETS+ETS for CostLedger: DETS durability + ETS hot-path O(1) budget checks without GenServer.call
- try/rescue around budget_exhausted telemetry so telemetry failure never blocks budget checking
- catch :exit in Alerter evaluate_hub_invocation_rate for CostLedger not-yet-started safety
- All 36 CostLedger tests passed on first run -- 25-01/02 implementation was complete, no source fixes needed in TDD phase
- GoalBacklog follows TaskQueue pattern: DETS+sync, priority index, PubSub broadcast
- Lifecycle state machine with 6 states: submitted->decomposing->executing->verifying->complete/failed
- Priority index only tracks :submitted goals; dequeue pops and transitions to :decomposing atomically
- RepoScanner as library module (not GenServer) -- stateless scanning, no supervision overhead
- Module attribute patterns with compile-time regex -- zero runtime compilation cost
- Elixir maps for scan reports (not XML) -- JSON-serializable for API consumption
- format_scan_report/1 manual atom-to-string serialization -- report maps use atom keys internally
- Reject unknown scan categories with 422 -- fail-fast API contract for consumers
- Dependency validation at submit time rejects unknown task IDs immediately (not at schedule time)
- Dependencies checked against both tasks and dead_letter tables for maximum flexibility
- goal_progress/1 as client-side aggregation over tasks_for_goal/1 (no extra GenServer call)
- Goal API routes placed after Task Queue section; stats before :goal_id to prevent parameter capture
- CLI agentcom-submit-goal.js follows agentcom-submit.js pattern: standalone, no shared modules
- Serial GenServer execution for ClaudeClient (no concurrency pool) -- one CLI invocation at a time via call queue
- Task.async + Task.yield timeout pattern wrapping System.cmd for non-blocking GenServer
- Stub Prompt/Response modules allow compilation without Plan 26-02 while preserving module boundaries
- Regex-based XML extraction (not Saxy) for LLM response parsing -- LLM output may not be valid XML; regex is more lenient
- Fallback plain text parsing when JSON decode fails -- supports --output-format text responses
- rescue in Cli.invoke for System.cmd :enoent -- prevents GenServer crash when CLI binary unavailable
- [Phase 31]: Both resting->executing and resting->improving increment cycle count (active work cycles)
- [Phase 31]: :improving exits only via budget exhaustion or watchdog timeout (not goal predicates)

### Research Findings (v1.3)

- CostLedger MUST exist before Hub FSM makes first API call (cost spiral prevention)
- Build order: ClaudeClient -> GoalBacklog -> HubFSM -> Scanning -> Cleanup
- Start with 2-state FSM (Executing + Resting), expand to 4 states after core loop proves stable
- PR-only before auto-merge (no auto-merge until pipeline proven)
- Deterministic improvement scanning before LLM scanning
- GenServer-based FSM (not gen_statem) following existing AgentFSM pattern

### Pending Todos

1. Analyze scalability bottlenecks and machine vs agent scaling tradeoffs (area: architecture)
2. Pipeline phase discussions and research ahead of execution (area: planning)
3. Pre-publication repo cleanup synthesized from agent audits (area: general)

### Blockers/Concerns

- [Tech debt]: REG-03 warm/cold model distinction deferred (binary availability used instead)
- [Tech debt]: Elixir version bump (1.14 to 1.17+) recommended for :gen_statem logger fix
- [Tech debt]: Sidecar queue.json atomicity -- fs.writeFileSync has partial-write-on-crash risk
- [Tech debt]: VAPID keys ephemeral -- push subscriptions lost on hub restart
- [Tech debt]: Analytics and Threads modules orphaned (not exposed via API)

## Session Continuity

Last session: 2026-02-14
Stopped at: Completed 31-01-PLAN.md -- FSM Improving State + Webhook Infrastructure
Resume file: None
