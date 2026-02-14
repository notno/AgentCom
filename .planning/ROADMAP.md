# Roadmap: AgentCom v2

## Milestones

- [x] **v1.0 Core Architecture** - Phases 1-8 (shipped 2026-02-11)
- [x] **v1.1 Hardening** - Phases 9-16 (shipped 2026-02-12)
- [x] **v1.2 Smart Agent Pipeline** - Phases 17-23 (shipped 2026-02-12)
- [ ] **v1.3 Hub FSM Loop of Self-Improvement** - Phases 24-36 (in progress)

## Phases

<details>
<summary>v1.0 Core Architecture (Phases 1-8) - SHIPPED 2026-02-11</summary>

| Phase | Name | What It Delivered |
|-------|------|-------------------|
| 1 | Sidecar | Always-on Node.js WebSocket relay, wake trigger, queue management |
| 2 | Task Queue | DETS-backed persistent queue with priority lanes, retries, dead-letter |
| 3 | Agent State | Per-agent FSM (idle/assigned/working/blocked/offline) |
| 4 | Scheduler | Event-driven task-to-agent matcher with capability routing |
| 5 | Smoke Test | End-to-end validation with 2 simulated agents |
| 6 | Dashboard | Real-time HTML dashboard with WebSocket updates, health monitoring, push notifications |
| 7 | Git Workflow | Branch-from-main enforcement, PR submission automation |
| 8 | Onboarding | One-command agent provisioning, Culture ship names, teardown & submit CLIs |

48 commits, 65 files, +12,858 LOC across 2 days.

</details>

<details>
<summary>v1.1 Hardening (Phases 9-16) - SHIPPED 2026-02-12</summary>

| Phase | Name | What It Delivered |
|-------|------|-------------------|
| 9 | Testing Infrastructure | DETS isolation, test factories, WS client, GenServer + integration tests, CI pipeline |
| 10 | DETS Backup + Monitoring | Automated backup with 3-backup retention, health endpoint, dashboard visibility |
| 11 | DETS Compaction + Recovery | Scheduled compaction, corruption detection, backup-based recovery, degraded mode |
| 12 | Input Validation | 27 schemas (15 WS + 12 HTTP), violation tracking, escalating disconnect backoff |
| 13 | Structured Logging + Telemetry | LoggerJSON with dual output, 22 telemetry events, token redaction, sidecar structured logs |
| 14 | Metrics + Alerting | ETS-backed metrics (queue depth, latency percentiles, utilization), 5 alert rules, dashboard charts |
| 15 | Rate Limiting | Token bucket with 3-tier classification, progressive backoff, admin overrides, DETS persistence |
| 16 | Operations Documentation | ExDoc with Mermaid diagrams, setup guide, daily operations, troubleshooting procedures |

153 commits, 195 files, +35,732 LOC across 4 days.

</details>

<details>
<summary>v1.2 Smart Agent Pipeline (Phases 17-23) - SHIPPED 2026-02-12</summary>

| Phase | Name | What It Delivered |
|-------|------|-------------------|
| 17 | Enriched Task Format | Structured context, success criteria, verification steps, complexity classification with heuristic inference |
| 18 | LLM Registry + Host Resources | Ollama endpoint registry with health checks, model discovery, host CPU/RAM/VRAM reporting |
| 19 | Model-Aware Scheduler | Complexity-based tier routing (trivial/standard/complex), load-balanced endpoint scoring, fallback chains |
| 20 | Sidecar Execution | Three executors (Ollama, Claude, Shell) with cost tracking, streaming progress, per-model cost estimation |
| 21 | Verification Infrastructure | Deterministic mechanical checks (file_exists, test_passes, git_clean, command_succeeds) with structured reports |
| 22 | Self-Verification Loop | Build-verify-fix pattern with corrective prompts, configurable retry budget, cumulative cost tracking |
| 23 | Multi-Repo Registry + Workspace Switching | Priority-ordered repo list, scheduler filtering, nil-repo inheritance, sidecar workspace isolation |

136 commits, 147 files, +26,075 LOC across 1 day.

</details>

### v1.3 Hub FSM Loop of Self-Improvement (In Progress)

**Milestone Goal:** Make the hub an autonomous thinker that cycles through executing goals, improving codebases, contemplating future features, and resting -- with Ralph-style inner loops and LLM-powered decomposition.

**Phase Numbering:**
- Integer phases (24, 25, 26...): Planned milestone work
- Decimal phases (25.1, 25.2): Urgent insertions (marked with INSERTED)

- [x] **Phase 24: Document Format Conversion** - Convert machine-consumed planning artifacts to XML (shipped 2026-02-13)
- [x] **Phase 25: Cost Control Infrastructure** - CostLedger GenServer with per-state budgets and telemetry (shipped 2026-02-13)
- [x] **Phase 26: Claude API Client** - CLI-based ClaudeClient GenServer with budget-gated invocation, prompt templates, and response parsing (shipped 2026-02-14)
- [x] **Phase 27: Goal Backlog** - DETS-backed goal storage with multi-source intake and lifecycle (shipped 2026-02-13)
- [x] **Phase 28: Pipeline Dependencies** - Task dependency graph with scheduler filtering (shipped 2026-02-13)
- [x] **Phase 29: Hub FSM Core** - 4-state autonomous brain with queue-driven transitions (shipped 2026-02-13)
- [x] **Phase 30: Goal Decomposition and Inner Loop** - LLM-powered goal-to-task transformation with Ralph-style verification (shipped 2026-02-13)
  Plans:
  - [x] 30-01-PLAN.md -- FileTree and DagValidator utility modules
  - [x] 30-02-PLAN.md -- Decomposer and Verifier LLM pipeline modules
  - [x] 30-03-PLAN.md -- GoalOrchestrator GenServer and HubFSM integration
- [x] **Phase 31: Hub Event Wiring** - GitHub webhooks and external event triggers for FSM transitions (shipped 2026-02-13)
- [x] **Phase 32: Improvement Scanning** - Deterministic and LLM-assisted codebase improvement identification (shipped 2026-02-13)
- [x] **Phase 33: Contemplation and Scalability** - Feature proposal generation and bottleneck analysis (shipped 2026-02-14)
- [x] **Phase 34: Tiered Autonomy** - Risk-based PR classification with configurable thresholds (shipped 2026-02-13)
- [x] **Phase 35: Pre-Publication Cleanup** - Secret scanning, IP replacement, workspace file management (shipped 2026-02-13)
- [x] **Phase 36: Dashboard and Observability** - Goal progress, cost tracking, and FSM visibility panels (shipped 2026-02-13)

## Phase Details

### Phase 24: Document Format Conversion
**Goal**: Machine-consumed planning/context documents use XML format for structured parsing
**Depends on**: Nothing (independent, sets convention for all new v1.3 documents)
**Requirements**: FORMAT-01, FORMAT-02
**Success Criteria** (what must be TRUE):
  1. All new machine-consumed documents (goal definitions, task context, scan results, FSM state snapshots) are authored in XML format
  2. Existing .planning/ artifacts that are machine-consumed are converted from markdown to XML with equivalent information
  3. Human-facing documents (README, changelogs) remain in markdown
**Plans:** 2 plans
Plans:
- [x] 24-01-PLAN.md -- XML infrastructure: Saxy dep, encode/decode API, SAX parser, 5 schema structs
- [x] 24-02-PLAN.md -- TDD: encode/decode round-trip tests for all schema types

### Phase 25: Cost Control Infrastructure
**Goal**: The hub tracks and enforces API spending limits before any autonomous LLM call is made
**Depends on**: Nothing (must exist before Phase 26)
**Requirements**: COST-01, COST-02, COST-03, COST-04
**Success Criteria** (what must be TRUE):
  1. CostLedger GenServer tracks cumulative Claude API spend with per-hour, per-day, and per-session breakdowns
  2. Per-state token budgets (Executing, Improving, Contemplating) are configurable via the existing Config GenServer
  3. Any code path that would call the Claude API checks the CostLedger budget first and transitions HubFSM to Resting if budget is exhausted
  4. Cost telemetry events are emitted via :telemetry and trigger existing Alerter rules when thresholds are approached
**Plans:** 3 plans
Plans:
- [x] 25-01-PLAN.md -- CostLedger GenServer with dual-layer DETS+ETS store, supervision tree, DetsBackup
- [x] 25-02-PLAN.md -- Telemetry events, Alerter rule 7, DetsHelpers test isolation
- [x] 25-03-PLAN.md -- TDD: comprehensive CostLedger test suite

### Phase 26: Claude API Client
**Goal**: The hub can make structured LLM calls through a rate-limited, cost-aware HTTP client
**Depends on**: Phase 25 (CostLedger for budget enforcement)
**Requirements**: CLIENT-01, CLIENT-02
**Success Criteria** (what must be TRUE):
  1. ClaudeClient GenServer sends requests to the Claude Messages API via Req with connection pooling, rate limiting (RPM tracking), and request serialization
  2. Structured prompt/response handling supports decomposition, verification, and improvement identification use cases with typed response parsing
  3. Every API call passes through CostLedger budget check before execution and reports token usage after completion
**Plans:** 3 plans
Plans:
- [x] 26-01-PLAN.md -- ClaudeClient GenServer with CostLedger integration and Cli invocation module
- [x] 26-02-PLAN.md -- Prompt template builder and Response parser for 3 use cases
- [x] 26-03-PLAN.md -- TDD test suite for ClaudeClient modules

### Phase 27: Goal Backlog
**Goal**: Users can submit goals through multiple channels and track them through a complete lifecycle
**Depends on**: Nothing (DETS pattern established by TaskQueue/RepoRegistry)
**Requirements**: GOAL-01, GOAL-02, GOAL-05, GOAL-08
**Success Criteria** (what must be TRUE):
  1. GoalBacklog GenServer persists goals in DETS with priority ordering (urgent/high/normal/low) and registered with DetsBackup
  2. Goals can be submitted via HTTP API endpoint and CLI tool, each receiving a unique goal ID
  3. Each goal carries success criteria defined at submission time and progresses through lifecycle states (submitted, decomposing, executing, verifying, complete, failed)
  4. GoalBacklog publishes PubSub events on goal state changes for downstream consumers
**Plans**: 2 plans
- [x] 27-01-PLAN.md — GoalBacklog GenServer with DETS persistence, lifecycle state machine, priority index, PubSub, DetsBackup registration
- [x] 27-02-PLAN.md — HTTP API routes, validation schemas, CLI sidecar tool (agentcom-submit-goal.js)

### Phase 28: Pipeline Dependencies
**Goal**: Tasks can declare dependency ordering so the scheduler executes them in correct sequence
**Depends on**: Nothing (extends existing TaskQueue and Scheduler)
**Requirements**: PIPE-01, PIPE-02, PIPE-03
**Success Criteria** (what must be TRUE):
  1. Tasks support an optional depends_on field containing a list of prerequisite task IDs
  2. Scheduler filters out tasks whose dependencies have not yet completed, only scheduling tasks with all dependencies satisfied
  3. Tasks carry a goal_id field linking them to their parent goal, enabling goal-level progress tracking
**Plans:** 2 plans
Plans:
- [x] 28-01-PLAN.md -- Core implementation: TaskQueue fields, scheduler filter, API layer, dependency validation
- [x] 28-02-PLAN.md -- TDD: dependency filtering, goal progress, backward compatibility tests

### Phase 29: Hub FSM Core
**Goal**: The hub operates as an autonomous 4-state brain with observable, controllable state transitions
**Depends on**: Phase 25 (CostLedger), Phase 26 (ClaudeClient), Phase 27 (GoalBacklog)
**Requirements**: FSM-01, FSM-02, FSM-03, FSM-04, FSM-05
**Success Criteria** (what must be TRUE):
  1. HubFSM runs as a singleton GenServer with 4 states (Executing, Improving, Contemplating, Resting) and transitions driven by queue state and external events
  2. FSM can be paused and resumed via API endpoint, immediately halting autonomous behavior when paused
  3. FSM transition history is logged with timestamps and queryable via API, including time spent in each state
  4. Dashboard shows current FSM state, transition timeline, and state duration metrics in real time
  5. Start with 2-state core (Executing + Resting), expand to 4 states after core loop proves stable
**Plans:** 4 plans
Plans:
- [x] 29-01-PLAN.md -- HubFSM GenServer core with 2-state transitions, predicates, ETS history, supervision tree
- [x] 29-02-PLAN.md -- API endpoints (pause/resume/state/history), dashboard integration, telemetry
- [x] 29-03-PLAN.md -- TDD test suite for predicates, history, and GenServer integration
- [x] 29-04-PLAN.md -- Gap closure: transition timeline visualization in dashboard

### Phase 30: Goal Decomposition and Inner Loop
**Goal**: The hub transforms high-level goals into executable task graphs and drives them to verified completion
**Depends on**: Phase 26 (ClaudeClient), Phase 27 (GoalBacklog), Phase 28 (Pipeline Dependencies), Phase 29 (HubFSM)
**Requirements**: GOAL-03, GOAL-04, GOAL-06, GOAL-07, GOAL-09
**Success Criteria** (what must be TRUE):
  1. Hub decomposes goals into 3-8 enriched tasks via Claude API using elephant carpaccio slicing, grounded in actual file tree (validates referenced files exist)
  2. Decomposition produces a dependency graph where independent tasks are marked for parallel execution and dependent tasks carry depends_on references
  3. Hub monitors child task completion via PubSub and drives a Ralph-style inner loop per goal (decompose, submit, monitor, verify)
  4. Goal completion is verified by LLM judging success criteria, with max 2 retry attempts (redecompose on failure)
**Plans:** 3 plans
Plans:
- [ ] 30-01-PLAN.md -- FileTree and DagValidator utility modules
- [ ] 30-02-PLAN.md -- Decomposer and Verifier LLM pipeline modules
- [ ] 30-03-PLAN.md -- GoalOrchestrator GenServer and HubFSM integration

### Phase 31: Hub Event Wiring
**Goal**: External repository events wake the hub from rest and trigger appropriate state transitions
**Depends on**: Phase 29 (HubFSM)
**Requirements**: FSM-06, FSM-07, FSM-08
**Success Criteria** (what must be TRUE):
  1. Hub exposes a GitHub webhook endpoint that receives push and PR merge events with signature verification
  2. Git push or PR merge on an active repo wakes the FSM from Resting to Improving
  3. Goal backlog changes (new goal submitted, goal priority changed) wake the FSM from Resting to Executing
**Plans:** 3 plans
Plans:
- [x] 31-01-PLAN.md -- Foundation: HubFSM :improving state, CacheBodyReader, WebhookVerifier
- [x] 31-02-PLAN.md -- Wiring: Webhook endpoint, event history, config API
- [x] 31-03-PLAN.md -- TDD: Comprehensive test suite for webhook handling

### Phase 32: Improvement Scanning
**Goal**: The hub autonomously identifies and executes codebase improvements during idle time
**Depends on**: Phase 26 (ClaudeClient), Phase 29 (HubFSM in Improving state)
**Requirements**: IMPR-01, IMPR-02, IMPR-03, IMPR-04, IMPR-05
**Success Criteria** (what must be TRUE):
  1. Deterministic scanning identifies test gaps, documentation gaps, and dead dependencies without LLM calls
  2. LLM-assisted scanning via git diff analysis identifies refactoring and simplification opportunities
  3. Scanning cycles through repos in priority order using the existing RepoRegistry
  4. Improvement history (DETS-backed) prevents Sisyphus loops by tracking attempted improvements with anti-oscillation detection
  5. Per-file cooldowns prevent re-scanning recently improved files within a configurable window
**Plans:** 4 plans
Plans:
- [x] 32-01-PLAN.md -- Finding struct, ImprovementHistory (DETS + cooldowns + oscillation), DetsBackup registration
- [x] 32-02-PLAN.md -- CredoScanner, DialyzerScanner, DeterministicScanner (test gaps, doc gaps, dead deps)
- [x] 32-03-PLAN.md -- LlmScanner, SelfImprovement orchestrator, HubFSM Improving state
- [x] 32-04-PLAN.md -- TDD: comprehensive test suite for all SelfImprovement modules

### Phase 33: Contemplation and Scalability
**Goal**: The hub produces strategic analysis -- feature proposals from codebase insight and scalability recommendations from metrics
**Depends on**: Phase 26 (ClaudeClient), Phase 29 (HubFSM in Contemplating state)
**Requirements**: CONTEMP-01, CONTEMP-02, SCALE-01, SCALE-02
**Success Criteria** (what must be TRUE):
  1. In Contemplating state, hub generates structured feature proposals from codebase analysis and writes them as XML files in a proposals directory
  2. Hub produces a scalability analysis report from existing ETS metrics covering throughput, agent utilization, and bottlenecks
  3. Scalability report recommends whether to add machines vs agents based on current constraint analysis
**Plans:** 3 plans
Plans:
- [x] 33-01-PLAN.md -- HubFSM 4-state expansion with contemplating transitions and cycle spawn
- [x] 33-02-PLAN.md -- Proposal schema enrichment, prompt/response update, contemplation context
- [x] 33-03-PLAN.md -- TDD test suite for all contemplation and HubFSM expansion modules

### Phase 34: Tiered Autonomy
**Goal**: Completed tasks are classified by risk so the system can enforce appropriate review levels
**Depends on**: Phase 29 (HubFSM), Phase 30 (Goal Decomposition producing tasks)
**Requirements**: AUTO-01, AUTO-02, AUTO-03
**Success Criteria** (what must be TRUE):
  1. Completed tasks are classified into risk tiers based on complexity, number of files touched, and lines changed
  2. Default mode is PR-only for all tiers -- no auto-merge until pipeline reliability is proven through production data
  3. Tier thresholds are configurable via the existing Config GenServer and can be adjusted without code changes
**Plans:** 2 plans
Plans:
- [x] 34-01-PLAN.md -- TDD: RiskClassifier pure function module with Config-driven thresholds
- [x] 34-02-PLAN.md -- Sidecar diff gathering, classify endpoint, PR body enrichment

### Phase 35: Pre-Publication Cleanup
**Goal**: Repos can be scanned for sensitive content before open-sourcing, with actionable findings
**Depends on**: Nothing (independent of FSM loop, uses RepoRegistry)
**Requirements**: CLEAN-01, CLEAN-02, CLEAN-03, CLEAN-04
**Success Criteria** (what must be TRUE):
  1. Regex-based scanning detects leaked tokens, API keys, and secrets across all registered repos
  2. Scanning detects hardcoded IPs and hostnames and recommends placeholder replacements
  3. Workspace files (SOUL.md, USER.md, etc.) are identified for removal from git and addition to .gitignore
  4. Personal references (names, local paths) are identified with recommended replacements
**Plans:** 2 plans
Plans:
- [x] 35-01-PLAN.md -- Core scanner library: Patterns, FileWalker, Finding struct, RepoScanner API
- [x] 35-02-PLAN.md -- API endpoint and comprehensive test suite

### Phase 36: Dashboard and Observability
**Goal**: The autonomous hub's behavior is fully visible through the dashboard for human oversight
**Depends on**: Phase 25 (CostLedger), Phase 27 (GoalBacklog), Phase 29 (HubFSM)
**Requirements**: DASH-01, DASH-02
**Success Criteria** (what must be TRUE):
  1. Dashboard shows Hub FSM state, goal progress bars, and goal backlog depth with real-time updates
  2. Dashboard shows hub-side API cost tracking (CostLedger data) displayed separately from task execution costs (sidecar costs)
**Plans:** 2 plans
Plans:
- [x] 36-01-PLAN.md -- Backend data integration: GoalBacklog and CostLedger data in DashboardState snapshot, goals PubSub in DashboardSocket
- [x] 36-02-PLAN.md -- Frontend panels: Goal Progress panel, Cost Tracking panel, Hub FSM state duration enhancement

## Progress

**Execution Order:**
Phases execute in numeric order: 24, 25, 26... Decimal phases (if inserted) execute between their surrounding integers.

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-8 | v1.0 | 19/19 | Complete | 2026-02-11 |
| 9-16 | v1.1 | 32/32 | Complete | 2026-02-12 |
| 17-23 | v1.2 | 25/25 | Complete | 2026-02-12 |
| 24. Document Format Conversion | v1.3 | 2/2 | Complete | 2026-02-13 |
| 25. Cost Control Infrastructure | v1.3 | 3/3 | Complete | 2026-02-13 |
| 26. Claude API Client | v1.3 | 3/3 | Complete | 2026-02-14 |
| 27. Goal Backlog | v1.3 | 2/2 | Complete | 2026-02-13 |
| 28. Pipeline Dependencies | v1.3 | 2/2 | Complete | 2026-02-13 |
| 29. Hub FSM Core | v1.3 | 4/4 | Complete | 2026-02-13 |
| 30. Goal Decomposition and Inner Loop | v1.3 | 3/3 | Complete | 2026-02-13 |
| 31. Hub Event Wiring | v1.3 | 3/3 | Complete | 2026-02-13 |
| 32. Improvement Scanning | v1.3 | 4/4 | Complete | 2026-02-13 |
| 33. Contemplation and Scalability | v1.3 | 3/3 | Complete | 2026-02-14 |
| 34. Tiered Autonomy | v1.3 | 2/2 | Complete | 2026-02-13 |
| 35. Pre-Publication Cleanup | v1.3 | 2/2 | Complete | 2026-02-13 |
| 36. Dashboard and Observability | v1.3 | 2/2 | Complete | 2026-02-13 |
