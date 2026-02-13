# Project Research Summary

**Project:** AgentCom v1.3 -- Hub FSM Loop of Self-Improvement
**Domain:** Autonomous agent orchestration with goal-driven FSM brain
**Researched:** 2026-02-12
**Confidence:** HIGH

## Executive Summary

The v1.3 milestone transforms the AgentCom hub from a reactive task processor into an autonomous thinker. The core pattern is Ralph-style continuous iteration: the hub cycles through four states (Executing, Improving, Contemplating, Resting), generating its own work through LLM-powered goal decomposition, monitoring execution through existing pipelines, and proactively scanning codebases for improvements. This builds on a proven v1.2 foundation (23 supervised GenServers, 10 DETS tables, PubSub event coordination) by adding three new GenServers (HubFSM, GoalBacklog, ClaudeClient) and one library module (SelfImprovement) without disrupting the existing task execution pipeline.

The recommended approach follows the Ralph Loop pattern: fresh context per iteration with state persisted in DETS (not LLM memory), bounded iterations (max 3 decomposition attempts per goal), and external mechanical verification (tests pass, files exist) as the ground truth with LLM verification as a semantic quality layer. Goal decomposition uses Claude API to transform high-level intent ("add rate limiting to API") into 3-8 enriched tasks following the existing v1.2 task format (complexity_tier, verification_steps, success_criteria). The hub submits decomposed tasks to the existing TaskQueue, and the existing Scheduler routes them to agents -- no changes to the core agent execution model.

The critical risks are: (1) uncontrolled API spending from autonomous LLM calls, (2) infinite improvement loops (the Sisyphus pattern where the hub oscillates between contradictory changes), (3) auto-merge introducing regressions, and (4) hallucinated tasks referencing non-existent files or modules. Mitigation requires: a CostLedger GenServer enforcing per-state token budgets before the hub makes its first API call, improvement history tracking with cooldown/deduplication to prevent oscillation, starting with PR-only mode and deferring auto-merge until the pipeline proves reliable, and grounding goal decomposition in the actual file tree. With these controls, the hub becomes a value-multiplying autonomous brain; without them, it becomes a cost-burning chaos generator.

## Key Findings

### Recommended Stack

The v1.3 stack builds on v1.2 (Elixir 1.18.1, BEAM 27.2, Bandit, Phoenix.PubSub) with minimal additions. The only new dependency is `{:req, "~> 0.5"}` for Claude API HTTP client (Req brings Finch for connection pooling). No changes to the sidecar stack (Node.js, commander.js, socket.io-client) -- sidecars remain unaware of the hub's autonomous brain.

**Core technologies:**
- **Req HTTP client**: Claude API communication from hub-side -- structured JSON requests, built-in retry/error handling, connection pooling via Finch. Replaces spawning CLI from Elixir.
- **GenServer-based FSM**: Hub FSM follows existing AgentFSM pattern (GenServer with explicit state tracking), not GenStateMachine. Rationale: existing codebase precedent, 4-state simplicity, better PubSub integration, avoids gen_statem logger compatibility issue.
- **DETS for goal persistence**: GoalBacklog uses same patterns as TaskQueue/RepoRegistry. Single `:goal_backlog` table with namespaced keys minimizes DETS proliferation.
- **PubSub for coordination**: Hub FSM subscribes to "tasks" and "presence" topics, publishes on new "hub_fsm" topic. No new transport protocols.

The stack decision is conservative: use existing patterns, minimize new dependencies, no architectural pivots. The v1.2 foundation is solid and requires only targeted extensions.

### Expected Features

**Must have (table stakes for v1.3):**
- Hub FSM with 4 states (Executing, Improving, Contemplating, Resting) -- the autonomous brain's top-level decision loop
- Goal backlog with multi-source input (API, CLI, file-watched GOALS.md, self-generated improvements) -- centralized intake for high-level intent
- LLM-powered goal decomposition (Claude API) -- bridges intent to machine-executable enriched tasks
- Ralph-style inner loop per goal (observe-act-verify at goal level) -- tracks completion across all subtasks, verifies goal-level success criteria
- Queue-driven state transitions (deterministic, testable predicates on GoalBacklog/TaskQueue state) -- not timer-only

**Should have (competitive differentiators):**
- Autonomous codebase improvement scanning (idle time -> value) -- scans repos for test gaps, duplication, doc gaps, dead code
- Tiered autonomy (auto-merge vs PR based on risk) -- small safe changes auto-merge, larger changes need review
- Goal completion verification (LLM judge) -- verifies goal's success criteria met, not just all tasks completed
- Pre-publication repo cleanup (deterministic scanning for tokens, API keys, personal info, workspace files) -- block publication if secrets found
- Pipeline pipelining (research-first decomposition) -- front-load research tasks, implementation tasks depend on research results

**Defer (v2+):**
- Fully autonomous multi-agent orchestration (delegating work between agents) -- Ralph pattern is monolithic, single brain
- Cross-repo goal dependencies (DAG scheduling across repos) -- start single-repo per goal
- Autonomous deployment/release -- human must approve deployment even with auto-merge
- Persistent LLM conversation memory -- Ralph pattern: fresh context per iteration

### Architecture Approach

The Hub FSM is a singleton GenServer orchestrator that generates goals, decomposes them via Claude API, submits tasks to the existing TaskQueue, and monitors completion via PubSub. It never executes tasks directly -- all work flows through the existing v1.2 pipeline (TaskQueue -> Scheduler -> AgentFSM -> sidecar). This preserves pipeline integrity and ensures hub-generated tasks get the same scheduling, capability matching, tier routing, and verification as human-submitted tasks.

**Major components:**
1. **AgentCom.HubFSM** (GenServer) -- The autonomous brain. Maintains FSM state (which mode), current goal tracking, timers, cycle count. Transitions driven by GoalBacklog/TaskQueue state predicates. Pauses on manual override (safety valve).
2. **AgentCom.GoalBacklog** (GenServer) -- DETS-backed goal storage with lifecycle (pending -> decomposing -> ready -> executing -> completed/failed). Goals are 1:N parent of tasks. Tracks goal-to-task relationships, task completion aggregation.
3. **AgentCom.ClaudeClient** (GenServer) -- Wraps Req for Claude Messages API. Rate limiting (RPM tracking), usage stats (input/output tokens), telemetry events. All hub-side LLM calls go through this client.
4. **AgentCom.SelfImprovement** (Module) -- Library for git-diff-based codebase scanning. Deterministic checks (test gaps, doc gaps) and LLM-assisted checks (duplication, simplification). Returns structured findings consumed by HubFSM.
5. **Pipeline DAG scheduling** (TaskQueue extension) -- Tasks gain optional `depends_on: [task_id]` field. Scheduler adds dependency filter: only schedule tasks whose dependencies are completed.

**Integration:** HubFSM added to supervision tree after GoalBacklog, ClaudeClient, Scheduler (dependency order). New `:goal_backlog` DETS table registered with DetsBackup. Dashboard extends to show hub state, goal progress, API cost tracking. Existing TaskQueue/Scheduler/AgentFSM gain small extensions (2 fields, 15 lines of filtering) but no behavioral rewrites.

### Critical Pitfalls

1. **Token Cost Spiral from Autonomous Thinking** -- Hub makes unbounded Claude API calls during contemplation/improvement. Weekend operation could burn $1,440 unattended. Prevention: CostLedger GenServer with per-state budgets ($10/hour Executing, $3/hour Improving, $2/hour Contemplating), hard caps in code not prompts, tiered model usage (Haiku for triage, Sonnet for decomposition). Must exist before FSM makes first API call.

2. **Infinite Improvement Loop (Sisyphus Pattern)** -- Hub scans, identifies improvement X, executes, next scan identifies "undo X" as improvement. Oscillates forever consuming resources. Prevention: improvement history with deduplication (DETS table tracking attempted improvements), per-file cooldown (24 hours after improving file X, don't scan X again), anti-oscillation detection (if consecutive improvements to same file have inverse diffs, block), improvement budget (max 3-5 per cycle).

3. **Hub FSM State Corruption from Concurrent Events** -- Hub is singleton receiving PubSub from entire system (high event volume). Timer-based transitions collide with event-driven transitions causing stuck states or dropped events. Prevention: consider `gen_statem` with state timeouts and postpone semantics, OR implement comprehensive timer cancellation + event queuing in GenServer. Watchdog timer to force-transition if stuck >2 hours in any state.

4. **Auto-Merge Regression Introduction** -- Small improvements auto-merge without review. Passes tests but introduces subtle regressions (semantic changes, nil-handling bugs). Prevention: never auto-merge to main directly (use integration branch), conservative size gates (<10 lines, no new files, no signature changes), start PR-only mode and add auto-merge later, auto-revert mechanism (run tests 5 minutes post-merge, revert if fail).

5. **Goal Decomposition Hallucination (Phantom Tasks)** -- LLM generates tasks referencing non-existent files/modules based on "typical Elixir project" patterns, not this specific codebase. Prevention: ground decomposition in actual file tree (feed `ls lib/` output to LLM), post-decomposition validation (check `File.exists?` for all mentioned paths), include `.planning/codebase/ARCHITECTURE.md` in every decomposition prompt with "what this project does NOT use" section.

## Implications for Roadmap

Based on research, suggested phase structure follows dependency chain and risk mitigation:

### Phase 1: Cost Control Infrastructure
**Rationale:** Must exist before any autonomous LLM calls. Building HubFSM without cost controls is unshippable.
**Delivers:** CostLedger GenServer tracking cumulative API spend per hour/day/session. Budget enforcement before every Claude API call. Telemetry integration.
**Addresses:** Pitfall 1 (cost spiral). Enables all downstream LLM-using components (decomposition, verification, scanning).
**Avoids:** Runaway weekend spending. Enables safe autonomous operation.

### Phase 2: ClaudeClient GenServer
**Rationale:** Foundation for all hub-side LLM calls. HubFSM and SelfImprovement both depend on it.
**Delivers:** Req-based HTTP client, rate limiting (RPM tracking), usage stats, structured JSON requests/responses.
**Uses:** Req (new dep), Config GenServer, CostLedger (from Phase 1).
**Implements:** Clean abstraction over Claude Messages API. `ask_json/2` for structured output.

### Phase 3: GoalBacklog GenServer
**Rationale:** HubFSM needs something to execute. Goal intake is the fuel for the FSM engine.
**Delivers:** DETS-backed goal storage, CRUD operations, status lifecycle, priority ordering, HTTP API endpoints.
**Addresses:** Table stakes: multi-source goal input. Enables manual goal submission before FSM automation.
**Avoids:** DETS proliferation (single table), backup coverage gap (register with DetsBackup from day one).

### Phase 4: HubFSM Core (2-state MVP)
**Rationale:** The orchestrator that ties everything together. Start simple (2 states: Executing, Resting) to prove core loop before adding Improving/Contemplating.
**Delivers:** GenServer with state transitions, goal-to-task decomposition via ClaudeClient, TaskQueue submission, completion monitoring via PubSub, manual pause/resume.
**Implements:** Ralph-style inner loop per goal (decompose -> submit -> monitor -> verify completion).
**Avoids:** Pitfall 3 (state corruption) via defensive timer cancellation, Pitfall 6 (supervisor ordering) via correct placement after dependencies.

### Phase 5: Goal Decomposition with Grounding
**Rationale:** Bridge intent to execution. Highest-risk feature because prompt quality determines system quality.
**Delivers:** Structured decomposition prompt grounded in file tree, post-decomposition validation (file existence checks), "elephant carpaccio" slicing (3-8 tasks per goal).
**Addresses:** Pitfall 5 (hallucinated tasks) via file tree grounding and validation.
**Avoids:** Over-decomposition (P12) via min task size heuristic.

### Phase 6: Pipeline Dependencies (DAG scheduling)
**Rationale:** Enables research-first decomposition and sequential task execution within goals.
**Delivers:** `depends_on` field in TaskQueue, dependency filter in Scheduler (15 lines), HubFSM submits tasks with dependency links.
**Addresses:** Differentiator: pipeline pipelining. Unlocks parallelizing research with other work.
**Avoids:** Branch conflicts (P14) by serializing dependent tasks.

### Phase 7: Goal Completion Verification
**Rationale:** Verify goal-level success criteria, not just task completion. Catches semantic gaps.
**Delivers:** LLM-based verification prompt, two-judge verification (LLM + mechanical checks), retry/redecompose on gaps.
**Addresses:** Ralph-style verification layer. Differentiator: goal completion verification.
**Avoids:** False positives (P8) via requiring mechanical criteria and two-judge agreement.

### Phase 8: Improvement Scanning (deterministic only)
**Rationale:** Turn idle time into value. Start with deterministic scans (test gaps, doc gaps, dead deps) to prove value before adding LLM-assisted scans.
**Delivers:** SelfImprovement module, git-diff-based scanning, finding structure, HubFSM Improving state integration.
**Addresses:** Differentiator: autonomous codebase improvement. Table stakes: Improving state.
**Avoids:** Pitfall 2 (Sisyphus loop) via improvement history DETS table, per-file cooldown, anti-oscillation detection. Pitfall 9 (bikeshedding) via category-priority mapping.

### Phase 9: HubFSM Contemplating State
**Rationale:** Add strategic thinking after core loop proves stable. Lower priority than Improving.
**Delivers:** Contemplating state, system state analysis, scalability reports, structured proposal generation.
**Addresses:** Differentiator: future feature contemplation.
**Avoids:** Vaporware proposals (P13) via scope constraints and feasibility checks.

### Phase 10: Tiered Autonomy (PR-only mode)
**Rationale:** Risk-based merge decisions. Start conservative (all PRs) before enabling auto-merge.
**Delivers:** Tier classification (auto-merge candidates vs PR), risk scoring (lines changed, files touched, test coverage), PR creation with risk assessment.
**Addresses:** Differentiator: tiered autonomy. Prepares for auto-merge.
**Avoids:** Pitfall 4 (auto-merge regressions) by starting PR-only. Enables gradual relaxation of thresholds.

### Phase 11: Pre-Publication Cleanup
**Rationale:** Safety gate before open-sourcing. Can be built independently of core loop.
**Delivers:** Deterministic secret scanning (regex patterns for API keys, tokens, paths, IPs), blocking report generation, cleanup task generation.
**Addresses:** Differentiator: pre-publication repo cleanup. Security requirement.
**Avoids:** Pitfall 10 (git history breaking) via fork-based scrubbing and coordination.

### Phase 12: Dashboard Integration and Polish
**Rationale:** Visibility into autonomous brain. After core functionality works.
**Delivers:** Hub state panel, goal progress tracking, API cost visualization, improvement history, FSM state timeline.
**Addresses:** Observability. Human oversight of autonomous system.

### Phase Ordering Rationale

- Cost controls (Phase 1) MUST come first. Non-negotiable for safe autonomous operation.
- ClaudeClient (Phase 2) before anything that calls Claude (decomposition, verification, scanning).
- GoalBacklog (Phase 3) before HubFSM because FSM needs goals to process.
- HubFSM (Phase 4) as 2-state MVP proves core loop before adding complexity.
- Decomposition (Phase 5) after HubFSM core so there's an orchestrator to test against.
- Dependencies (Phase 6) enable advanced decomposition patterns.
- Verification (Phase 7) completes the Ralph loop (observe-act-verify).
- Improvement scanning (Phase 8) only after FSM + decomposition + verification are stable. Deterministic scans only; defer LLM-assisted scans to follow-up.
- Contemplating (Phase 9) lowest operational priority, build after Improving works.
- Tiered autonomy (Phase 10) starts PR-only to prove pipeline before enabling auto-merge.
- Cleanup (Phase 11) independent, can be built anytime but needed before publication.
- Dashboard (Phase 12) after functional components exist to visualize.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 4 (HubFSM Core):** GenServer vs gen_statem decision requires architectural analysis. State corruption handling needs careful design. Research gen_statem state timeouts and postpone semantics vs explicit GenServer timer management.
- **Phase 5 (Goal Decomposition):** Prompt engineering for decomposition is critical and under-documented. First 10-20 decompositions need manual review to calibrate. Research LLM-based task decomposition quality metrics.
- **Phase 8 (Improvement Scanning):** Git diff analysis and finding prioritization need domain expertise. Research existing codebase scanning tools (Credo, Dialyzer) for integration vs LLM-only approach.

Phases with standard patterns (skip research-phase):
- **Phase 2 (ClaudeClient):** Req HTTP client wrapping is well-documented. GenServer rate limiting follows existing RateLimiter.Sweeper pattern.
- **Phase 3 (GoalBacklog):** DETS + GenServer pattern established by TaskQueue/RepoRegistry. Direct code reuse.
- **Phase 6 (Pipeline Dependencies):** Simple list of task IDs, not complex graph traversal. TaskQueue extension is mechanical.
- **Phase 11 (Pre-Publication Cleanup):** Regex-based scanning is deterministic. Pattern libraries exist (gitleaks, GitHub secret scanning).

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Minimal additions, leverages existing v1.2 foundation. Req is mature, GenServer patterns proven in codebase. |
| Features | MEDIUM-HIGH | Ralph loop pattern well-documented with multiple implementations. Goal decomposition patterns established but require prompt tuning. Tiered autonomy is emerging industry pattern. Codebase self-improvement is newer territory. |
| Architecture | HIGH | Grounded in direct analysis of v1.2 source (23 files examined). HubFSM integration follows existing supervision tree patterns. No architectural pivots, only targeted extensions. |
| Pitfalls | HIGH | Critical pitfalls (cost spiral, Sisyphus loop, state corruption, auto-merge regressions, hallucinated tasks) identified from production autonomous agent deployments (2025-2026). Prevention strategies concrete and testable. |

**Overall confidence:** HIGH

### Gaps to Address

- **Decomposition prompt quality:** The first 10-20 goal decompositions need manual review to tune prompts. Quality is highly dependent on prompt engineering. Gap: no golden test set for decomposition validation.
- **Auto-merge threshold calibration:** The specific thresholds (20 lines, protected paths, tier classification) need production data calibration. Start conservative, relax gradually. Gap: no baseline for "safe" change size in this codebase.
- **LLM verification reliability:** LLM-as-judge for goal completion is known to be unreliable. Two-judge (LLM + mechanical) mitigates but doesn't eliminate false positives. Gap: need re-open rate tracking to measure verification quality.
- **Cost budget tuning:** Per-state token budgets ($10/hour Executing, $3/hour Improving, $2/hour Contemplating) are estimates. Actual cost depends on goal complexity and scanning frequency. Gap: need production cost tracking to tune budgets.
- **Improvement oscillation detection:** Anti-oscillation via git diff comparison is heuristic-based. May have false positives/negatives. Gap: need production data to tune semantic similarity thresholds.

All gaps are operational tuning, not architectural unknowns. Ship conservative defaults, instrument heavily, tune based on production telemetry.

## Sources

### Primary (HIGH confidence)
- AgentCom v1.2 codebase -- lib/agent_com/*.ex, sidecar/lib/, .planning/ (direct code analysis, 2026-02-12)
- [snarktank/ralph](https://github.com/snarktank/ralph) -- Autonomous AI agent loop implementation (verified via WebFetch)
- [vercel-labs/ralph-loop-agent](https://github.com/vercel-labs/ralph-loop-agent) -- Continuous Autonomy for AI SDK (verified via WebFetch)
- [Ralph Wiggum Loop - beuke.org](https://beuke.org/ralph-wiggum-loop/) -- Detailed loop structure, stopping criteria, failure modes (verified via WebFetch)
- [Everything is a Ralph Loop - ghuntley.com](https://ghuntley.com/loop/) -- Core insight: monolithic, single-process-per-task, context engineering (verified via WebFetch)
- [From ReAct to Ralph Loop - Alibaba Cloud](https://www.alibabacloud.com/blog/from-react-to-ralph-loop-a-continuous-iteration-paradigm-for-ai-agents_602799) -- Ralph shifts control from LLM judgment to external verification (verified via WebFetch)
- [GenStateMachine v3.0.0 documentation](https://hexdocs.pm/gen_state_machine/GenStateMachine.html) -- evaluated for FSM implementation
- [Anthropix v0.6.2 documentation](https://hexdocs.pm/anthropix/Anthropix.html) -- Elixir Claude API client
- [Claude API Rate Limits](https://docs.claude.com/en/api/rate-limits) -- RPM, ITPM, OTPM rate limiting model

### Secondary (MEDIUM confidence)
- [Elephant Carpaccio - Henrik Kniberg](https://blog.crisp.se/2013/07/25/henrikkniberg/elephant-carpaccio-facilitation-guide) -- Thin vertical slices, nano-incremental development
- [Agent Goal Decomposition - SparkCo](https://sparkco.ai/blog/mastering-agent-goal-decomposition-in-ai-systems) -- Planner agent pattern, dependency graphs (verified via WebFetch)
- [GoalAct - NCIIP 2025 Best Paper](https://github.com/cjj826/GoalAct) -- Hierarchical decomposition into high-level skills (peer-reviewed)
- [Eight Trends - Claude Blog 2026](https://claude.com/blog/eight-trends-defining-how-software-gets-built-in-2026) -- Human oversight model: 60% AI collaboration, 0-20% full delegation (official Anthropic)
- [State Timeouts with gen_statem - DockYard](https://dockyard.com/blog/2020/01/31/state-timeouts-with-gen_statem) -- gen_statem timer patterns
- [Preventing Infinite Loops and Cost Spirals - CodieSHub](https://codieshub.com/for-ai/prevent-agent-loops-costs)
- [LLM-based Agents Suffer from Hallucinations - arXiv](https://arxiv.org/html/2509.18970v1)
- [Why Do Multi-Agent LLM Systems Fail - Galileo](https://galileo.ai/blog/multi-agent-llm-systems-fail)
- [Why Do Multi-Agent LLM Systems Fail - arXiv](https://arxiv.org/html/2503.13657v1) -- 14 distinct failure modes
- [How Task Decomposition Makes AI More Affordable - Amazon Science](https://www.amazon.science/blog/how-task-decomposition-and-smaller-llms-can-make-ai-more-affordable)
- [Scrubbing Secrets with Gitleaks and git filter-repo](https://medium.com/@sreejithv13055/scrubbing-secrets-a-practical-poc-using-gitleaks-and-git-filter-repo-08c64b8d246c)
- [git-filter-repo Documentation](https://www.mankier.com/1/git-filter-repo)

### Tertiary (LOW confidence)
- [Autonomous Enterprise 2026 - CNCF](https://www.cncf.io/blog/2026/01/23/the-autonomous-enterprise-and-the-four-pillars-of-platform-control-2026-forecast/) -- Platform control pillars (industry forecast)
- [OpenAgentSafety Framework](https://arxiv.org/pdf/2507.06134) -- Comprehensive framework for agent safety evaluation (academic)
- [Agents At Work: 2026 Playbook](https://promptengineering.org/agents-at-work-the-2026-playbook-for-building-reliable-agentic-workflows/) -- Verification-aware planning patterns (community guide)

---
*Research completed: 2026-02-12*
*Ready for roadmap: yes*
