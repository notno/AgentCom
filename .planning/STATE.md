# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-13)

**Core value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.
**Current focus:** v1.3 Hub FSM Loop of Self-Improvement -- Phase 24

## Current Position

Phase: 24 of 36 (Document Format Conversion)
Plan: 24-01 complete, executing 24-02
Status: Executing
Last activity: 2026-02-13 -- Plan 24-01 XML infrastructure complete (Saxy, 5 schemas, encode/decode API)

Progress: [██████░░░░░░░] 50% (1/2 plans)

## Performance Metrics

**Velocity:**
- Total plans completed: 76 (19 v1.0 + 32 v1.1 + 25 v1.2)
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

### Decisions (v1.3)

- Convention-based XML validation via Elixir structs (not XSD) -- internal-only docs don't need formal schemas
- Custom Saxy.Builder protocol implementations for list fields -- @derive doesn't handle nested lists
- SimpleForm-based parsing with shared Parser helpers -- simpler than raw SAX for small flat docs

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

Last session: 2026-02-13
Stopped at: Phase 24 Wave 1 complete, executing Wave 2 (TDD tests)
Resume file: None
