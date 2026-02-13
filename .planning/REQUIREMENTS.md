# Requirements: AgentCom v2

**Defined:** 2026-02-12
**Core Value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.

## v1.3 Requirements

Requirements for v1.3 Hub FSM Loop of Self-Improvement. Each maps to roadmap phases.

### Hub FSM

- [ ] **FSM-01**: Hub runs a 4-state FSM (Executing, Improving, Contemplating, Resting) as a singleton GenServer
- [ ] **FSM-02**: FSM transitions are driven by queue state AND external events (git pushes, PR merges, backlog changes)
- [ ] **FSM-03**: Hub FSM can be paused/resumed via API
- [ ] **FSM-04**: FSM transition history is logged and queryable
- [ ] **FSM-05**: Dashboard shows current FSM state, transition timeline, and state durations
- [ ] **FSM-06**: Hub exposes a GitHub webhook endpoint for push and PR merge events
- [ ] **FSM-07**: Git push/PR merge on active repos wakes FSM from Resting to Improving
- [ ] **FSM-08**: Goal backlog changes wake FSM from Resting to Executing

### Goal Management

- [ ] **GOAL-01**: Centralized goal backlog with DETS persistence and priority ordering (urgent/high/normal/low)
- [ ] **GOAL-02**: Goals can be submitted via HTTP API, CLI tool, and internal generation
- [ ] **GOAL-03**: Hub decomposes goals into enriched tasks via Claude Code CLI (elephant carpaccio slicing)
- [ ] **GOAL-04**: Decomposition is grounded in actual file tree (validates referenced files exist)
- [ ] **GOAL-05**: Each goal has a lifecycle (submitted -> decomposing -> executing -> verifying -> complete/failed)
- [ ] **GOAL-06**: Hub monitors child task completion and drives Ralph-style inner loop per goal
- [ ] **GOAL-07**: Goal completion verified by LLM judging success criteria, max 2 retry attempts
- [ ] **GOAL-08**: Goals carry success criteria defined at submission time
- [ ] **GOAL-09**: Goal decomposition produces a dependency graph -- independent tasks marked for parallel execution, dependent tasks carry depends_on references

### Claude API Client

- [ ] **CLIENT-01**: Claude Code CLI wrapper GenServer (`claude -p`) with invocation rate limiting and serialization
- [ ] **CLIENT-02**: Structured prompt/response handling for decomposition, verification, and improvement identification

### Self-Improvement

- [ ] **IMPR-01**: Deterministic codebase scanning identifies test gaps, documentation gaps, and dead dependencies
- [ ] **IMPR-02**: LLM-assisted code review via git diff analysis identifies refactoring and simplification opportunities
- [ ] **IMPR-03**: Improvement scanning cycles through repos in priority order (uses RepoRegistry)
- [ ] **IMPR-04**: Improvement history tracks changes to prevent Sisyphus loops (oscillation detection)
- [ ] **IMPR-05**: File-level cooldowns prevent re-scanning recently improved files

### Cost and Safety

- [ ] **COST-01**: CostLedger GenServer tracks cumulative Claude Code CLI invocations per hour/day/session
- [ ] **COST-02**: Per-state token budgets are configurable (Executing, Improving, Contemplating)
- [ ] **COST-03**: Hub FSM checks budget before every API call; transitions to Resting if budget exhausted
- [ ] **COST-04**: Cost telemetry emitted via :telemetry and wired to existing Alerter

### Tiered Autonomy

- [ ] **AUTO-01**: Completed tasks classified by risk tier based on complexity, files touched, and lines changed
- [ ] **AUTO-02**: Default mode is PR-only (no auto-merge until pipeline proven reliable)
- [ ] **AUTO-03**: Tier thresholds configurable via Config GenServer

### Pipeline Dependencies

- [ ] **PIPE-01**: Tasks support a depends_on field linking to prerequisite task IDs
- [ ] **PIPE-02**: Scheduler filters out tasks whose dependencies are incomplete
- [ ] **PIPE-03**: Tasks carry a goal_id linking them to their parent goal

### Pre-Publication Cleanup

- [ ] **CLEAN-01**: Regex-based scanning detects leaked tokens/API keys across registered repos
- [ ] **CLEAN-02**: Scanning detects and replaces hardcoded IPs/hostnames with placeholders
- [ ] **CLEAN-03**: Workspace files (SOUL.md, USER.md, etc.) removed from git and added to .gitignore
- [ ] **CLEAN-04**: Personal references (names, local paths) identified with recommended replacements

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

- [ ] **DASH-01**: Dashboard shows Hub FSM state, goal progress, and goal backlog depth
- [ ] **DASH-02**: Dashboard shows hub CLI invocation tracking separate from task execution costs

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
| COST-01 | Phase 25 | Pending |
| COST-02 | Phase 25 | Pending |
| COST-03 | Phase 25 | Pending |
| COST-04 | Phase 25 | Pending |
| CLIENT-01 | Phase 26 | Pending |
| CLIENT-02 | Phase 26 | Pending |
| GOAL-01 | Phase 27 | Pending |
| GOAL-02 | Phase 27 | Pending |
| GOAL-05 | Phase 27 | Pending |
| GOAL-08 | Phase 27 | Pending |
| PIPE-01 | Phase 28 | Pending |
| PIPE-02 | Phase 28 | Pending |
| PIPE-03 | Phase 28 | Pending |
| FSM-01 | Phase 29 | Pending |
| FSM-02 | Phase 29 | Pending |
| FSM-03 | Phase 29 | Pending |
| FSM-04 | Phase 29 | Pending |
| FSM-05 | Phase 29 | Pending |
| GOAL-03 | Phase 30 | Pending |
| GOAL-04 | Phase 30 | Pending |
| GOAL-06 | Phase 30 | Pending |
| GOAL-07 | Phase 30 | Pending |
| GOAL-09 | Phase 30 | Pending |
| FSM-06 | Phase 31 | Pending |
| FSM-07 | Phase 31 | Pending |
| FSM-08 | Phase 31 | Pending |
| IMPR-01 | Phase 32 | Pending |
| IMPR-02 | Phase 32 | Pending |
| IMPR-03 | Phase 32 | Pending |
| IMPR-04 | Phase 32 | Pending |
| IMPR-05 | Phase 32 | Pending |
| CONTEMP-01 | Phase 33 | Pending |
| CONTEMP-02 | Phase 33 | Pending |
| SCALE-01 | Phase 33 | Pending |
| SCALE-02 | Phase 33 | Pending |
| AUTO-01 | Phase 34 | Pending |
| AUTO-02 | Phase 34 | Pending |
| AUTO-03 | Phase 34 | Pending |
| CLEAN-01 | Phase 35 | Pending |
| CLEAN-02 | Phase 35 | Pending |
| CLEAN-03 | Phase 35 | Pending |
| CLEAN-04 | Phase 35 | Pending |
| DASH-01 | Phase 36 | Pending |
| DASH-02 | Phase 36 | Pending |

**Coverage:**
- v1.3 requirements: 46 total
- Mapped to phases: 46
- Unmapped: 0

---
*Requirements defined: 2026-02-12*
*Last updated: 2026-02-13 after roadmap creation*
