# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-12)

**Core value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.
**Current focus:** v1.2 Smart Agent Pipeline -- Phase 20 In Progress

## Current Position

Phase: 21 of 22 (Verification Infrastructure)
Plan: 4 of 4
Status: Phase Complete
Last activity: 2026-02-12 -- Completed 21-04 Store Wiring Gap Closure

Progress: [█████░░░░░] 50%

## Performance Metrics

**Velocity:**
- Total plans completed: 67 (19 v1.0 + 32 v1.1 + 16 v1.2)
- Average duration: 5 min
- Total execution time: 4.3 hours

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
- Last 5 plans: 21-04 (2 min), 20-01 (2 min), 19-04 (6 min), 19-03 (5 min), 19-02 (7 min)
- Trend: Stable

*Updated after each plan completion*
| Phase 17 P01 | 4min | 1 task (TDD) | 2 files |
| Phase 17 P02 | 4min | 2 tasks | 6 files |
| Phase 17 P03 | 4min | 2 tasks | 6 files |
| Phase 18 P01 | 4min | 1 task (TDD) | 2 files |
| Phase 18 P02 | 2min | 2 tasks | 2 files |
| Phase 18 P03 | 11min | 2 tasks | 8 files |
| Phase 18 P04 | 8min | 3 tasks (1 checkpoint) | 4 files |
| Phase 19 P01 | 4min | 1 task (TDD) | 4 files |
| Phase 21 P01 | 3min | 2 tasks (TDD) | 4 files |
| Phase 21 P02 | 3min | 2 tasks | 2 files |
| Phase 19 P02 | 7min | 2 tasks | 4 files |
| Phase 21 P03 | 5min | 2 tasks | 8 files |
| Phase 19 P04 | 6min | 2 tasks | 3 files |
| Phase 19 P03 | 5min | 2 tasks | 4 files |
| Phase 20 P01 | 2min | 1 task (TDD) | 4 files |
| Phase 20 P02 | 2min | 2 tasks | 2 files |
| Phase 20 P03 | 4min | 2 tasks | 5 files |
| Phase 21 P04 | 2min | 2 tasks (gap closure) | 2 files |

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
- 18-03: Snapshot route before :id route to prevent parameter capture
- 18-03: resource_report is fire-and-forget (no reply) like task_progress
- 18-03: :number validation type accepts both integer and float
- 18-03: LlmRegistry tests use supervisor stop/restart for compatibility
- 18-04: Table view for endpoints (not cards) per locked decision
- 18-04: Resource bars inline per host row (CPU=blue, RAM=purple, VRAM=amber)
- 18-04: Strip http:// prefix from host input to prevent malformed health check URLs
- 18-VERIFY: Warm/cold model distinction accepted as gap -- binary availability sufficient, deferred per locked design decision
- 19-01: 15% warm model bonus for endpoints with task model loaded (discretion area)
- 19-01: 5% repo affinity bonus simplified for Phase 19 (resource metadata repo field)
- 19-01: Neutral defaults for missing resource data (cpu=50%, vram=0.9, capacity=1.0)
- 19-01: 16GB reference capacity for normalization, capped at 1.5x
- 19-01: Classification reason format: "source:tier (confidence X, word_count=Y, files=Z)"
- 19-02: Capability matching fallback when TaskRouter returns fallback signal (backward compatible with no LLM endpoints)
- 19-02: Store routing_decision before assign_task to ensure persistence even if assignment fails
- 19-02: Emit routing telemetry for both successful routes and fallback decisions (full observability)
- 19-02: Prefer endpoint-matching agent for :ollama target, fall back to any capable agent
- 19-02: Single pending fallback per task_id to prevent timer accumulation
- 21-01: Unique DETS table atom per Store instance for safe test parallelism
- 21-01: Status priority: error > timeout > fail > pass (error always wins)
- 21-01: Empty reports (skip/auto_pass/timeout) use run_number 0 as sentinel
- 21-02: execSync for check execution (synchronous, sequential, simple)
- 21-02: Promise.race for global timeout with clearTimeout on completion
- 21-02: verification_report as top-level WS field in task_complete (not nested in result)
- 21-02: Git push skipped when verification fails/errors (broken code stays local)
- 21-02: Test auto-detection priority: mix.exs > package.json > Makefile
- 21-03: verification_report stored directly on task map (no separate Store lookup for API/dashboard)
- 21-03: Verification.Store.save called inline in complete_task (Store starts before TaskQueue)
- 21-03: Dashboard Verify column replaces unused PR column in recent tasks table
- 21-03: details/summary HTML for expandable check results (no JavaScript handlers needed)
- 19-04: Defensive safe_to_string serialization for routing_decision atom/binary/nil fields
- 19-04: routing_decision included in completion ring buffer for dashboard recent task display
- 19-04: Routing stats computed from live TaskQueue data (not in-memory counters)
- 19-04: CSS class toggle for expandable routing detail (consistent with verify details pattern)
- 19-03: Tier-down alert tracks tier_down_since timestamp, only fires after duration exceeds configurable threshold (not on brief blips)
- 19-03: TTL sweep exempts trivial-tier tasks from expiry (execute locally regardless of tier availability)
- 19-03: expire_task moves queued tasks to dead_letter with reason "ttl_expired" (reuses existing mechanism)
- 19-03: Fallback timeout reads Config.get(:fallback_wait_ms) at timer creation time (runtime configurable)
- 20-01: Sonnet baseline (_claude_equivalent) for Ollama savings comparison
- 20-01: Prefix match after exact match for model variants with tags (e.g. claude-sonnet-4.5:latest)
- 20-01: First token flushes immediately, subsequent tokens batched until interval fires
- 20-01: Ollama models with zero tokens return null equivalent_claude_cost_usd (no savings to show)
- [Phase 20]: format_routing_decision_for_ws follows safe_to_string pattern from endpoint.ex/dashboard_state.ex
- [Phase 20]: execution_event PubSub broadcast is conditional (only when field present) for backward compatibility
- [Phase 20]: execution metadata flows through existing result map in task_complete (no structural change)
- [Phase 20]: Lazy-load executors inside dispatch switch cases to avoid module load ordering issues
- [Phase 20]: Dispatcher is single point for cost calculation -- executors return raw token counts
- [Phase 20]: ShellExecutor treats non-zero exit code as failure (triggers retry mechanism)
- [Phase 20]: ClaudeExecutor uses content_block_delta events for streaming text deltas
- [Phase 20]: ProgressEmitter onFlush receives event arrays, iterated for individual WS sends
- 21-04: Configurable :name opt with __MODULE__ default for Store (production uses module name, tests use unique atoms)
- 21-04: Guard-based dispatch for save/2: is_binary(task_id) routes to registered name, is_pid routes directly
- 21-04: No changes to task_queue.ex needed -- existing call site already correct, gap was Store-side only

### Pending Todos

1. Analyze scalability bottlenecks and machine vs agent scaling tradeoffs (area: architecture)
2. Pipeline phase discussions and research ahead of execution (area: planning)
3. Pre-publication repo cleanup synthesized from agent audits (area: general)
4. Multi-project fallback queue for idle agent utilization (area: architecture)
5. Dashboard task submission UI (area: ui)

### Blockers/Concerns

- [Tech debt]: Elixir version bump (1.14 to 1.17+) recommended for :gen_statem logger fix
- [Tech debt]: Sidecar queue.json atomicity -- fs.writeFileSync has partial-write-on-crash risk
- [Tech debt]: VAPID keys ephemeral -- push subscriptions lost on hub restart
- [Tech debt]: Analytics and Threads modules orphaned (not exposed via API)
- [Research flag]: Phase 20 -- Ollama streaming behavior, Claude API integration, timeout tuning need validation
- [Research flag]: Phase 22 -- Self-verification feedback loop patterns and retry budgets need deeper investigation

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 1 | Fix pre-existing compilation warnings | 2026-02-12 | 898d665 | [1-fix-pre-existing-compilation-warnings](./quick/1-fix-pre-existing-compilation-warnings/) |

## Session Continuity

Last session: 2026-02-12
Stopped at: Completed 21-04-PLAN.md (Store Wiring Gap Closure)
Resume file: None
