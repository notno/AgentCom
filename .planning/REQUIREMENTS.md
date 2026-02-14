# Requirements: AgentCom v2

**Defined:** 2026-02-12
**Core Value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.

## v1.3 Requirements

Requirements for v1.3 Hub FSM Loop of Self-Improvement. Each maps to roadmap phases.

### Hub FSM

- [x] **FSM-01**: Hub runs a 4-state FSM (Executing, Improving, Contemplating, Resting) as a singleton GenServer
- [x] **FSM-02**: FSM transitions are driven by queue state AND external events (git pushes, PR merges, backlog changes)
- [x] **FSM-03**: Hub FSM can be paused/resumed via API
- [x] **FSM-04**: FSM transition history is logged and queryable
- [x] **FSM-05**: Dashboard shows current FSM state, transition timeline, and state durations
- [x] **FSM-06**: Hub exposes a GitHub webhook endpoint for push and PR merge events
- [x] **FSM-07**: Git push/PR merge on active repos wakes FSM from Resting to Improving
- [x] **FSM-08**: Goal backlog changes wake FSM from Resting to Executing

### Goal Management

- [x] **GOAL-01**: Centralized goal backlog with DETS persistence and priority ordering (urgent/high/normal/low)
- [x] **GOAL-02**: Goals can be submitted via HTTP API, CLI tool, and internal generation
- [x] **GOAL-03**: Hub decomposes goals into enriched tasks via Claude Code CLI (elephant carpaccio slicing)
- [x] **GOAL-04**: Decomposition is grounded in actual file tree (validates referenced files exist)
- [x] **GOAL-05**: Each goal has a lifecycle (submitted -> decomposing -> executing -> verifying -> complete/failed)
- [x] **GOAL-06**: Hub monitors child task completion and drives Ralph-style inner loop per goal
- [x] **GOAL-07**: Goal completion verified by LLM judging success criteria, max 2 retry attempts
- [x] **GOAL-08**: Goals carry success criteria defined at submission time
- [x] **GOAL-09**: Goal decomposition produces a dependency graph -- independent tasks marked for parallel execution, dependent tasks carry depends_on references

### Claude API Client

- [x] **CLIENT-01**: Claude Code CLI wrapper GenServer (`claude -p`) with invocation rate limiting and serialization
- [x] **CLIENT-02**: Structured prompt/response handling for decomposition, verification, and improvement identification

### Self-Improvement

- [x] **IMPR-01**: Deterministic codebase scanning identifies test gaps, documentation gaps, and dead dependencies
- [x] **IMPR-02**: LLM-assisted code review via git diff analysis identifies refactoring and simplification opportunities
- [x] **IMPR-03**: Improvement scanning cycles through repos in priority order (uses RepoRegistry)
- [x] **IMPR-04**: Improvement history tracks changes to prevent Sisyphus loops (oscillation detection)
- [x] **IMPR-05**: File-level cooldowns prevent re-scanning recently improved files

### Cost and Safety

- [x] **COST-01**: CostLedger GenServer tracks cumulative Claude Code CLI invocations per hour/day/session
- [x] **COST-02**: Per-state token budgets are configurable (Executing, Improving, Contemplating)
- [x] **COST-03**: Hub FSM checks budget before every API call; transitions to Resting if budget exhausted
- [x] **COST-04**: Cost telemetry emitted via :telemetry and wired to existing Alerter

### Tiered Autonomy

- [ ] **AUTO-01**: Completed tasks classified by risk tier based on complexity, files touched, and lines changed
- [ ] **AUTO-02**: Default mode is PR-only (no auto-merge until pipeline proven reliable)
- [ ] **AUTO-03**: Tier thresholds configurable via Config GenServer

### Pipeline Dependencies

- [x] **PIPE-01**: Tasks support a depends_on field linking to prerequisite task IDs
- [x] **PIPE-02**: Scheduler filters out tasks whose dependencies are incomplete
- [x] **PIPE-03**: Tasks carry a goal_id linking them to their parent goal

### Pre-Publication Cleanup

- [x] **CLEAN-01**: Regex-based scanning detects leaked tokens/API keys across registered repos
- [x] **CLEAN-02**: Scanning detects and replaces hardcoded IPs/hostnames with placeholders
- [x] **CLEAN-03**: Workspace files (SOUL.md, USER.md, etc.) removed from git and added to .gitignore
- [x] **CLEAN-04**: Personal references (names, local paths) identified with recommended replacements

### Scalability

- [ ] **SCALE-01**: Hub produces scalability analysis report from existing ETS metrics (throughput, utilization, bottlenecks)
- [ ] **SCALE-02**: Report recommends whether to add machines vs agents based on current constraints

### Contemplation

- [ ] **CONTEMP-01**: In Contemplating state, hub generates structured feature proposals from codebase analysis
- [ ] **CONTEMP-02**: Proposals written as XML files in proposals directory for human review

### Document Format

- [x] **FORMAT-01**: All new machine-consumed documents (goals, task context, scan results, FSM state) use XML format
- [ ] **FORMAT-02**: ~~Existing .planning/ artifacts converted from markdown to XML~~ DESCOPED -- GSD stays markdown

### Dashboard

- [x] **DASH-01**: Dashboard shows Hub FSM state, goal progress, and goal backlog depth
- [x] **DASH-02**: Dashboard shows hub CLI invocation tracking separate from task execution costs

## Future Requirements

Deferred to future releases. Tracked but not in current roadmap.

### Tiered Autonomy (future)

- **AUTO-04**: Auto-merge enabled for tier-1 improvements after 20+ successful PR-only cycles
- **AUTO-05**: Machine learning on merge outcomes to adjust tier thresholds

### Learning and Affinity

- **LEARN-01**: Hub tracks which agent performs best at which task types
- **LEARN-02**: Scheduler uses performance history for agent-task affinity matching

### PR Review Gatekeeper

- **GATE-01**: Flere-Imsaho role reviews PRs before merge with LLM analysis
- **GATE-02**: Merge/escalation heuristics calibrated from 50+ tasks of production data

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Agent-to-agent delegation | Bypasses central scheduler, creates untrackable work |
| Fully autonomous multi-agent orchestration | Ralph pattern is monolithic by design; hub is the single brain |
| LLM-based complexity pre-classifier | Burns tokens to route tokens; decomposition prompt handles atomic goals |
| Dynamic goal priority rebalancing by LLM | Non-deterministic scheduling; priority is human-set or rule-based |
| Cross-repo goal dependencies | DAG complexity out of scope; decompose to per-repo goals |
| Autonomous deployment/release | Auto-merge to branch acceptable; deployment is human decision |
| Persistent LLM conversation memory | Fresh context per call (Ralph pattern); state in DETS not LLM memory |
| Real-time FSM streaming to external systems | Dashboard uses PubSub; HTTP GET endpoint sufficient for external polling |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| FORMAT-01 | Phase 24 | Done |
| FORMAT-02 | Phase 24 | Descoped |
| COST-01 | Phase 25 | Done |
| COST-02 | Phase 25 | Done |
| COST-03 | Phase 25 | Done |
| COST-04 | Phase 25 | Done |
| CLIENT-01 | Phase 26 | Done |
| CLIENT-02 | Phase 26 | Done |
| GOAL-01 | Phase 27 | Done |
| GOAL-02 | Phase 27 | Done |
| GOAL-05 | Phase 27 | Done |
| GOAL-08 | Phase 27 | Done |
| PIPE-01 | Phase 28 | Done |
| PIPE-02 | Phase 28 | Done |
| PIPE-03 | Phase 28 | Done |
| FSM-01 | Phase 29 | Done |
| FSM-02 | Phase 29 | Done |
| FSM-03 | Phase 29 | Done |
| FSM-04 | Phase 29 | Done |
| FSM-05 | Phase 29 | Done |
| GOAL-03 | Phase 30 | Done |
| GOAL-04 | Phase 30 | Done |
| GOAL-06 | Phase 30 | Done |
| GOAL-07 | Phase 30 | Done |
| GOAL-09 | Phase 30 | Done |
| FSM-06 | Phase 31 | Pending |
| FSM-07 | Phase 31 | Pending |
| FSM-08 | Phase 31 | Pending |
| IMPR-01 | Phase 32 | Done |
| IMPR-02 | Phase 32 | Done |
| IMPR-03 | Phase 32 | Done |
| IMPR-04 | Phase 32 | Done |
| IMPR-05 | Phase 32 | Done |
| CONTEMP-01 | Phase 33 | Pending |
| CONTEMP-02 | Phase 33 | Pending |
| SCALE-01 | Phase 33 | Pending |
| SCALE-02 | Phase 33 | Pending |
| AUTO-01 | Phase 34 | Pending |
| AUTO-02 | Phase 34 | Pending |
| AUTO-03 | Phase 34 | Pending |
| CLEAN-01 | Phase 35 | Done |
| CLEAN-02 | Phase 35 | Done |
| CLEAN-03 | Phase 35 | Done |
| CLEAN-04 | Phase 35 | Done |
| DASH-01 | Phase 36 | Done |
| DASH-02 | Phase 36 | Done |

**Coverage:**
- v1.3 requirements: 46 total
- Mapped to phases: 46
- Unmapped: 0

---
*Requirements defined: 2026-02-12*
*Last updated: 2026-02-13 after roadmap creation*
