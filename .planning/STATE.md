# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-12)

**Core value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.
**Current focus:** v1.2 Smart Agent Pipeline -- Phase 18 LLM Registry and Host Resources

## Current Position

Phase: 18 of 22 (LLM Registry and Host Resources)
Plan: 2 of 4
Status: Executing
Last activity: 2026-02-12 -- Completed 18-02 (sidecar resource metrics and reporting)

Progress: [██░░░░░░░░] 20%

## Performance Metrics

**Velocity:**
- Total plans completed: 56 (19 v1.0 + 32 v1.1 + 5 v1.2)
- Average duration: 5 min
- Total execution time: 3.8 hours

**By Phase (v1.1 recent):**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 09-testing | 7 | 33 min | 5 min |
| 10-dets-backup | 3 | 8 min | 3 min |
| 11-dets-compaction | 3 | 15 min | 5 min |
| 12-input-validation | 3 | 13 min | 4 min |
| 13-structured-logging | 4 | 38 min | 10 min |
| 14-metrics-alerting | 4 | 17 min | 4 min |
| 15-rate-limiting | 4 | 25 min | 6 min |
| 16-operations-docs | 4 | 14 min | 4 min |

**Recent Trend:**
- Last 5 plans: 18-02 (2 min), 18-01 (4 min), 17-03 (4 min), 17-02 (4 min), 17-01 (4 min)
- Trend: Stable

*Updated after each plan completion*
| Phase 17 P01 | 4min | 1 task (TDD) | 2 files |
| Phase 17 P02 | 4min | 2 tasks | 6 files |
| Phase 17 P03 | 4min | 2 tasks | 6 files |
| Phase 18 P01 | 4min | 1 task (TDD) | 2 files |
| Phase 18 P02 | 2min | 2 tasks | 2 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
v1.1 decisions archived to .planning/milestones/v1.1-ROADMAP.md (100 decisions across 32 plans).

**v1.2 decisions:**
- 17-01: Keywords as strong signals in heuristic -- override word-count majority voting (short "refactor auth" = complex)
- 17-01: Majority-vote for non-keyword signals with conservative tie-breaking toward :standard
- 17-01: Empty params classify as :unknown with 0.0 confidence
- 17-02: Enrichment validation as separate pass after schema validation (not mixed into validate_against_schema)
- 17-02: Soft limit for verification steps set at 10 (warning, not error)
- 17-02: Complexity field stored as nil placeholder -- Plan 03 wires module
- 17-03: Complexity.build called for every submission (heuristic always runs for observability)
- 17-03: Enrichment fields propagated with additive-only pattern and safe defaults at every pipeline stage
- 17-03: TaskQueue emits disagreement telemetry with task_id context for pipeline-level observability
- 18-01: 30s health check interval matching sidecar heartbeat cadence
- 18-01: 2 consecutive failures before marking unhealthy (tolerance for transient blips)
- 18-01: Immediate recovery on first successful health check (no probation)
- 18-01: host:port as canonical endpoint ID for deduplication across auto/manual registration
- 18-01: report_resources/get_resources bypass GenServer for ETS direct read/write (zero-cost)
- 18-02: CPU percent from os.loadavg[0] / core count (simple, cross-platform, 1-min average)
- 18-02: VRAM from Ollama /api/ps size_vram sum (no nvidia-smi dependency)
- 18-02: Separate resource_report WS message type rather than piggybacking on ping
- 18-02: 5-second initial report delay after identify for connection stabilization

### Pending Todos

1. Investigate reusing existing agents by name during onboarding (area: api)
2. Analyze scalability bottlenecks and machine vs agent scaling tradeoffs (area: architecture)
3. Pipeline phase discussions and research ahead of execution (area: planning)
4. Pre-publication repo cleanup synthesized from agent audits (area: general)
5. Multi-project fallback queue for idle agent utilization (area: architecture)

### Blockers/Concerns

- [Tech debt]: Elixir version bump (1.14 to 1.17+) recommended for :gen_statem logger fix
- [Tech debt]: Sidecar queue.json atomicity -- fs.writeFileSync has partial-write-on-crash risk
- [Tech debt]: VAPID keys ephemeral -- push subscriptions lost on hub restart
- [Tech debt]: Analytics and Threads modules orphaned (not exposed via API)
- [Research flag]: Phase 18 -- Ollama health check intervals and Tailscale mesh latency need empirical validation
- [Research flag]: Phase 20 -- Ollama streaming behavior, Claude API integration, timeout tuning need validation
- [Research flag]: Phase 22 -- Self-verification feedback loop patterns and retry budgets need deeper investigation

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 1 | Fix pre-existing compilation warnings | 2026-02-12 | 898d665 | [1-fix-pre-existing-compilation-warnings](./quick/1-fix-pre-existing-compilation-warnings/) |

## Session Continuity

Last session: 2026-02-12
Stopped at: Completed 18-02-PLAN.md (sidecar resource metrics). Ready for 18-03.
Resume file: None
