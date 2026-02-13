# Feature Landscape: AgentCom v1.3 -- Hub FSM Loop of Self-Improvement

**Domain:** Autonomous agent orchestration with goal-driven FSM brain, LLM-powered decomposition, codebase self-improvement, and tiered autonomy
**Researched:** 2026-02-12
**Overall Confidence:** MEDIUM-HIGH (Ralph loop patterns well-documented with multiple implementations; goal decomposition patterns established; tiered autonomy is emerging but with clear industry consensus on risk tiers; codebase self-improvement is newer territory with fewer battle-tested implementations)

## Table Stakes

Features the system must deliver for the milestone to achieve its stated goal: "Make the hub an autonomous thinker that cycles through executing goals, improving codebases, contemplating future features, and resting -- with Ralph-style inner loops and LLM-powered decomposition."

| Feature | Why Expected | Complexity | Depends On (Existing) | Notes |
|---------|--------------|------------|----------------------|-------|
| **Hub FSM with 4 states** | The hub needs a brain -- a top-level state machine that decides what to do next. Without this, the hub is reactive (waits for task submission) not proactive (generates its own work). The four states (Executing, Improving, Contemplating, Resting) create a bounded autonomy loop. | High | Scheduler, TaskQueue, PubSub, Application supervisor | New GenServer (or GenStateMachine). NOT the per-agent AgentFSM -- this is the HUB's brain, one singleton process. State transitions driven by queue depth, time-of-day, goal backlog status. Must integrate with existing PubSub for event-driven transitions. |
| **Goal backlog with multi-source input** | Goals need to come from somewhere: Nathan's CLI commands, API submissions, file-watched GOALS.md, and self-generated improvement ideas. Without centralized intake, the FSM has nothing to execute. | Medium | TaskQueue (downstream consumer), Config, Router (HTTP endpoints) | New GenServer: GoalBacklog. DETS-backed like TaskQueue. Goals are higher-level than tasks -- a goal decomposes into 1-N tasks. Multiple input channels (HTTP API, CLI tool, file watcher, internal generation). Priority ordering like RepoRegistry pattern. |
| **LLM-powered goal decomposition** | A goal like "add rate limiting to the API" must become 3-8 enriched tasks with descriptions, success criteria, verification steps, and complexity tiers. The existing pipeline (v1.2) expects enriched tasks -- decomposition bridges the gap between human intent and machine-executable work. | High | GoalBacklog, TaskQueue.submit/1, Complexity.build/1, existing enriched task format | Claude API call from hub-side (not sidecar). Structured prompt engineering to produce enriched task JSON. "Elephant carpaccio" slicing: each task must be completable in one agent context window. Uses existing task format (v1.2 enrichment fields). |
| **Ralph-style inner loop per goal** | After decomposing a goal into tasks, the hub must track completion across all tasks and verify the goal is "done" -- not just "all subtasks completed" but "the high-level intent is satisfied." This is the observe-act-verify cycle at the goal level. | High | GoalBacklog, TaskQueue, HubFSM, decomposition | Goal has its own lifecycle: submitted -> decomposing -> executing -> verifying -> complete/failed. Hub monitors task_completed events for goal's child tasks. When all tasks complete, run goal-level verification (LLM evaluates whether success criteria are met). Retry/redecompose if verification fails. |
| **Queue-driven state transitions** | The FSM must transition based on observable system state, not timers alone. Executing -> Resting when queue empty AND no goals pending. Resting -> Executing when new goal arrives. Resting -> Improving when idle too long. This makes transitions deterministic and testable. | Medium | HubFSM, GoalBacklog, TaskQueue.stats/0 | FSM subscribes to PubSub topics: "tasks", "goals" (new topic). Transition predicates are pure functions: can_transition?(current_state, system_state) -> :ok or :stay. Dashboard shows current FSM state and transition history. |

## Differentiators

Features that go beyond minimum viable. Not expected by the user but significantly increase the system's autonomy and value.

| Feature | Value Proposition | Complexity | Depends On (Existing) | Notes |
|---------|-------------------|------------|----------------------|-------|
| **Autonomous codebase improvement scanning** | When the goal queue is empty, the hub proactively scans registered repos for improvement opportunities: test coverage gaps, code duplication, missing docs, dead code, outdated dependencies. Transforms idle time into value. | High | RepoRegistry (priority-ordered repos), HubFSM (Improving state), GoalBacklog (self-generated goals), Claude API | Hub sends repo file listing + sample code to Claude with structured prompt: "Identify 3-5 improvement opportunities in this codebase." Responses become goals in the backlog. Scans repos in priority order from RepoRegistry. Rate-limited to prevent runaway token spend. |
| **Tiered autonomy (auto-merge vs human review)** | Small, safe improvements (typo fixes, doc updates, test additions) should auto-merge. Larger changes (refactoring, new features, API changes) should create PRs for human review. This prevents the system from creating review bottlenecks while maintaining safety. | Medium | Git workflow (sidecar git-workflow.js), Complexity classification, HubFSM | Tier classification based on: (1) complexity_tier from task, (2) files touched count, (3) lines changed count, (4) whether tests exist for changed code, (5) whether it touches public API. Tier 1 (trivial+standard, <20 lines, test-covered): auto-merge. Tier 2 (everything else): create PR. Configurable thresholds via Config GenServer. |
| **Goal completion verification (LLM judge)** | After all tasks for a goal complete, an LLM evaluates whether the goal's success criteria are actually met -- not just "did the tasks finish" but "was the intent achieved." This catches cases where tasks succeed individually but the goal fails holistically. | High | GoalBacklog, TaskQueue (completed tasks), Claude API | Prompt engineering: send goal description + success criteria + task results to Claude. Structured output: {complete: bool, evidence: string[], gaps: string[]}. If incomplete, hub can redecompose with gap context. Bounded: max 2 verification attempts per goal, then escalate to human. |
| **Future feature contemplation and proposal writing** | In the Contemplating state, the hub thinks about what the system could become. It reviews the codebase, backlog patterns, and user feedback to generate feature proposals. Output: structured markdown proposals added to a proposals directory. | Medium | HubFSM (Contemplating state), RepoRegistry, Claude API | Lower priority than Improving. Output is passive (files, not actions). Proposals follow a template: problem, proposed solution, complexity estimate, dependencies. Human reviews and promotes to goal backlog. Not self-executing -- contemplation produces documents, not tasks. |
| **Pre-publication repo cleanup** | Before a repo goes public, automated scanning for: leaked tokens/API keys (regex patterns), personal references (names, emails, paths), workspace-specific files (.planning/, .claude/), hardcoded IPs/hostnames, TODO/FIXME comments with sensitive context. Output: cleanup tasks or blocking report. | Medium | RepoRegistry, GoalBacklog, sidecar execution | Regex-based scanning (not LLM -- deterministic and fast). Pattern library: API key formats (sk-ant-*, ghp_*, etc.), email regex, IP address regex, path patterns (C:\Users\*, /home/*/). Can run as a pre-commit hook or as a hub-initiated scan goal. |
| **Pipeline pipelining (front-loading research)** | When a goal requires research before execution (e.g., "add WebSocket compression"), decomposition produces a research task first. Research output feeds into subsequent implementation task context. This parallelizes the discussion/research phase with other goal execution. | Medium | GoalBacklog, decomposition, TaskQueue | Decomposition identifies research-dependent goals. Produces: (1) research task (complexity: complex, target: Claude), (2) implementation tasks with dependency on research task ID. TaskQueue needs a `depends_on` field (deferred from v1.0 scope). Research results stored in task result, injected into dependent task context. |
| **Scalability analysis** | Hub periodically analyzes its own performance: task throughput, queue depth trends, agent utilization, bottleneck identification. Produces structured reports identifying whether to add machines, add agents, or optimize existing pipeline. | Low | MetricsCollector (ETS-backed metrics), Alerter, HubFSM | Reads from existing ETS metrics tables. Pure analysis -- no LLM needed for basic stats. Trend detection: is queue depth growing over time? Is agent utilization >80%? Are specific complexity tiers bottlenecked? Output: structured JSON report + optional Claude analysis for recommendations. |

## Anti-Features

Features to explicitly NOT build. Documented to prevent scope creep and re-discussion.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Fully autonomous multi-agent orchestration** | The Ralph loop pattern explicitly warns against over-engineering multi-agent systems. "Ralph is monolithic. Ralph works autonomously in a single repository as a single process that performs one task per loop." Adding agent-to-agent delegation, dynamic team formation, or multi-agent consensus bypasses the central scheduler and creates untrackable work. | Keep the hub as the single brain. Agents are execution units, not decision-makers. The hub decomposes goals, creates tasks, and monitors completion. Agents execute assigned tasks. |
| **LLM-based complexity classifier for decomposition** | Using an LLM to classify whether a goal needs decomposition at all is a chicken-and-egg problem. The decomposition prompt already handles this -- if the goal is atomic, the LLM returns a single task. Adding a pre-classifier burns tokens for routing. | Always attempt decomposition. If the LLM determines the goal is already atomic, it returns one task. The decomposition prompt handles this gracefully. Cost: one extra Claude call per atomic goal (acceptable). |
| **Real-time streaming of FSM state to external systems** | Exposing FSM state via a streaming API (SSE, WebSocket to external consumers) adds protocol complexity for zero internal value. The dashboard already gets state via PubSub. | Use PubSub internally. Dashboard reads FSM state like it reads all other state. Add HTTP GET endpoint for external polling if needed. |
| **Dynamic goal priority rebalancing by LLM** | Having the LLM re-prioritize the goal backlog introduces non-determinism into scheduling. Priority should be explicit (human-set) or rule-based (FIFO within priority lanes), not LLM-judged. | Use the same priority lane system as TaskQueue: urgent/high/normal/low. Human sets priority on goal submission. Self-generated improvement goals default to "low" priority. |
| **Cross-repo goal dependencies** | Goals that span multiple repos with inter-repo dependencies (repo A's change requires repo B's change first) add DAG scheduling complexity that is out of scope. | Decompose cross-repo work into separate goals per repo. Execute in priority order (RepoRegistry ordering). If ordering matters, human submits goals sequentially. |
| **Autonomous deployment/release** | The system should NOT autonomously deploy, release, or publish code. Even with tiered autonomy, deployment is a human decision. Auto-merge to a branch is acceptable; deploying that branch is not. | Auto-merge merges to the configured branch (usually a feature branch or main). Deployment/release is triggered by human action or separate CI/CD pipeline. |
| **Persistent LLM conversation memory** | Maintaining a long-running conversation context with the LLM across decomposition, verification, and contemplation calls creates context window pressure and stale context risk. | Each LLM call is stateless. Context is constructed fresh from: goal description, success criteria, task results, codebase snapshots. This is the Ralph pattern: fresh context per iteration with state persisted in files/DETS. |

## Feature Dependencies

```
GoalBacklog (centralized goal intake + priority ordering)
  |
  +--> Multi-Source Input (API, CLI, file watcher, internal generation)
  |
  +--> LLM Goal Decomposition (Claude API, structured prompt -> enriched tasks)
  |      |
  |      +--> Elephant Carpaccio Slicing (each task fits one context window)
  |      |
  |      +--> Task Submission to existing TaskQueue.submit/1
  |
  +--> Goal Completion Tracking (monitor child task events, aggregate status)
         |
         +--> LLM Completion Verification (goal-level success criteria check)

HubFSM (4-state loop: Executing, Improving, Contemplating, Resting)
  |
  +--> Queue-Driven Transitions (predicates on TaskQueue + GoalBacklog state)
  |
  +--> Executing State: Process goals from backlog, decompose, execute via pipeline
  |
  +--> Improving State: Scan repos, generate improvement goals
  |      |
  |      +--> Autonomous Codebase Scanning (Claude API, repo file analysis)
  |      |
  |      +--> Pre-Publication Repo Cleanup (regex-based, deterministic)
  |
  +--> Contemplating State: Generate feature proposals, scalability analysis
  |
  +--> Resting State: Idle, wait for new goals or transition triggers

Tiered Autonomy (risk-based merge vs PR decision)
  |
  +--> Requires: Complexity classification (existing v1.2)
  +--> Requires: Goal decomposition (task-level risk assessment)
  +--> Requires: Git workflow (existing sidecar git-workflow.js)
  +--> Configurable thresholds via Config GenServer

Pipeline Pipelining (research-first decomposition)
  |
  +--> Requires: GoalBacklog + Decomposition
  +--> Requires: TaskQueue task dependency field (NEW, deferred from v1.0)
```

**Critical path:** GoalBacklog -> Decomposition -> Goal Completion Tracking -> HubFSM -> Improvement Scanning

**Why this order:**
1. GoalBacklog first: the FSM needs something to execute. Without a goal intake, the FSM is an engine with no fuel.
2. Decomposition second: goals must become tasks for the existing pipeline. This bridges intent to execution.
3. Goal completion tracking third: the FSM needs to know when goals finish to transition states.
4. HubFSM fourth: now it has fuel (goals), a converter (decomposition), and a gauge (completion tracking).
5. Improvement scanning fifth: the Improving state needs the scanning capability. Only needed after FSM is running.

## Detailed Feature Specifications

### Hub FSM: The Four States

The hub FSM is a singleton GenServer (or GenStateMachine) that represents the hub's "brain." It is distinct from the per-agent AgentFSM (which tracks individual agent work lifecycle). The hub FSM decides what the system should be DOING at a macro level.

```
                    +---> [Executing] ---+
                    |         |          |
                    |    (goals done,    |
 (new goal)        |     queue empty)   |
                    |         v          |
 [Resting] <--------+--- [Improving] ---+
      |             |         |          |
      |             |    (scan done,     |
      |             |     idle timer)    |
      |             |         v          |
      +-----------> +- [Contemplating] -+
                              |
                         (proposals done,
                          long idle timer)
                              |
                              v
                          [Resting]
```

**State: Executing**
- Trigger: Goals exist in backlog
- Behavior: Pick highest-priority goal, decompose into tasks, submit to pipeline, monitor completion
- Exit: All goals completed (and none pending) -> Improving. New goal arrives -> stay Executing.
- Inner loop: Ralph-style observe-act-verify per goal. Decompose -> execute -> verify completion -> next goal.

**State: Improving**
- Trigger: No goals in backlog, system is idle
- Behavior: Scan repos from RepoRegistry in priority order. Identify improvement opportunities via Claude API. Generate improvement goals and add to backlog. Process generated goals.
- Exit: New external goal arrives -> Executing. Scan of all repos complete AND generated goals complete -> Contemplating (or Resting if contemplation disabled).
- Rate limit: Max 3 improvement scans per hour. Max 5 improvement goals generated per scan.

**State: Contemplating**
- Trigger: No goals (external or self-generated), all improvements processed
- Behavior: Review codebase architecture, backlog history, and task patterns. Generate feature proposals as structured markdown. Write proposals to `.planning/proposals/` directory.
- Exit: New goal arrives -> Executing. Proposals complete -> Resting.
- Rate limit: Max 1 contemplation session per 4 hours.

**State: Resting**
- Trigger: Nothing to do, or cooldown period active
- Behavior: Idle. Monitor for new goal submissions via PubSub.
- Exit: New goal submitted -> Executing. Idle for >30 min and repos have pending improvements -> Improving.

**Implementation decision: GenServer vs GenStateMachine**

Use a GenServer with explicit state tracking (like existing AgentFSM), NOT GenStateMachine. Rationale:
- AgentFSM already establishes the pattern of GenServer-based FSM with `@valid_transitions` map
- The hub FSM has 4 states, not 40 -- GenStateMachine's callback-mode-per-state adds boilerplate without benefit
- GenServer integrates more naturally with existing PubSub subscription pattern
- Avoids Elixir 1.14 `:gen_statem` logger compatibility issue (known tech debt)

**Confidence:** HIGH -- GenServer-based FSM pattern is proven in the codebase (AgentFSM). State transition logic is straightforward. The complexity is in the transition predicates, not the FSM mechanics.

### Goal Backlog

A centralized DETS-backed GenServer for high-level goal management. Goals are the unit of intent; tasks are the unit of execution.

```elixir
# Goal structure
%{
  id: "goal-" <> hex_id,
  title: "Add rate limiting to the public API",
  description: "Implement token bucket rate limiting...",
  success_criteria: [
    "All public endpoints have rate limiting",
    "Rate limits are configurable per endpoint",
    "Dashboard shows rate limit status"
  ],
  priority: 2,                    # 0=urgent, 1=high, 2=normal, 3=low
  status: :pending,               # :pending | :decomposing | :executing | :verifying | :complete | :failed
  source: :api,                   # :api | :cli | :file | :improvement | :contemplation
  repo: "https://github.com/...", # Optional, for repo-specific goals
  task_ids: [],                   # Populated after decomposition
  decomposition_result: nil,      # Raw LLM decomposition response
  verification_result: nil,       # Goal-level verification result
  created_at: timestamp,
  updated_at: timestamp,
  completed_at: nil,
  submitted_by: "nathan",
  attempt_count: 0,               # Decomposition/verification attempts
  max_attempts: 3,
  history: [{:pending, timestamp, "submitted via CLI"}]
}
```

**Input channels:**
1. **HTTP API** -- `POST /api/goals` with title, description, success criteria, priority. Integrates with existing Router.
2. **CLI tool** -- New `agentcom-goal.js` script in sidecar directory. `node agentcom-goal.js add "Title" --desc "..." --priority normal`.
3. **File watcher** -- Watch `GOALS.md` or `goals/*.md` for changes. Parse markdown into goal structs. (Lowest priority -- defer if complex.)
4. **Internal generation** -- `GoalBacklog.submit_internal/1` for improvement and contemplation goals. Tagged with `:improvement` or `:contemplation` source.

**Confidence:** HIGH -- Follows established GenServer + DETS pattern (TaskQueue, RepoRegistry). Goal struct is a superset of existing patterns.

### LLM-Powered Goal Decomposition

The decomposition engine takes a goal and produces enriched tasks suitable for the existing v1.2 pipeline.

**Decomposition prompt structure:**

```
You are a task decomposition engine for a distributed AI coding system.

GOAL:
Title: {goal.title}
Description: {goal.description}
Success Criteria:
{formatted success_criteria}

TARGET REPO: {goal.repo or "any"}
AVAILABLE COMPLEXITY TIERS: trivial (zero-LLM shell commands), standard (local Ollama), complex (Claude API)

CONSTRAINTS:
- Each task must be completable in a SINGLE agent context window (one session)
- Each task must be independently verifiable (tests, file checks, command output)
- Tasks should be ordered by dependency (earlier tasks first)
- Prefer many small tasks over few large tasks ("elephant carpaccio" - slice thin)
- Include verification_steps for EVERY task (file_exists, test_passes, command_succeeds, git_clean)
- Assign appropriate complexity_tier based on the work required

OUTPUT FORMAT (JSON array):
[
  {
    "description": "Clear, actionable description",
    "complexity_tier": "trivial|standard|complex",
    "priority": "normal",
    "success_criteria": ["Criterion 1", "Criterion 2"],
    "verification_steps": [
      {"type": "test_passes", "command": "mix test test/specific_test.exs"},
      {"type": "file_exists", "path": "lib/new_module.ex"}
    ],
    "file_hints": ["lib/relevant_file.ex"],
    "depends_on_index": null | 0 | 1,
    "estimated_complexity": "brief rationale"
  }
]
```

**Elephant Carpaccio principles applied:**
- Each task = one thin vertical slice (not "build the module" but "add the struct definition," "add the GenServer init," "add the public API function," "add the test")
- Each slice is independently deployable and verifiable
- 15-30 minute tasks, not 2-hour tasks
- If decomposition produces fewer than 3 tasks for a non-trivial goal, it is probably too coarse-grained

**Cost management:**
- One Claude API call per decomposition (~$0.05-0.15 per goal, depending on context)
- Cache decomposition results in goal struct (no re-decomposition on hub restart)
- Max 3 decomposition attempts per goal (with refined prompt on retry)
- Decomposition result validation: must produce valid JSON, each task must have required fields

**Confidence:** MEDIUM-HIGH -- LLM-based decomposition is well-established (GoalAct, HiPlan, TMS research). The prompt engineering is the critical path. Quality depends heavily on prompt tuning with real goals. First 10-20 decompositions will need manual review to calibrate.

### Ralph-Style Inner Loop Per Goal

Based on research into ralph (snarktank), ralph-loop-agent (Vercel), and the Ralph Wiggum technique, the inner loop follows this pattern:

```
Goal enters "executing" status
  |
  v
DECOMPOSE: Claude API -> enriched task array
  |
  v
SUBMIT: For each task, TaskQueue.submit/1
  |
  v
MONITOR: Subscribe to task_completed/task_failed events
  |         (existing PubSub "tasks" topic)
  |
  +---> Task completed: mark task done in goal tracking
  |       |
  |       +--> All tasks done? -> VERIFY
  |       |
  |       +--> Not all done? -> wait for next event
  |
  +---> Task failed (after retries exhausted):
  |       |
  |       +--> Retry budget remaining? -> resubmit with failure context
  |       |
  |       +--> Retry budget exhausted? -> FAIL goal
  |
  v
VERIFY: LLM evaluates goal success criteria against task results
  |
  +--> Verified complete -> goal status = :complete, move to next goal
  |
  +--> Verification failed with gaps:
        |
        +--> Attempt count < max? -> REDECOMPOSE with gap context
        |
        +--> Attempt count >= max? -> goal status = :failed, notify human
```

**Key implementation decisions from Ralph pattern research:**

1. **Fresh context per iteration** -- Each decomposition/verification call to Claude gets a fresh prompt with current state. No accumulated conversation context. State persists in DETS, not in LLM memory.

2. **File-system as memory** -- Ralph uses progress.txt + prd.json. AgentCom equivalent: GoalBacklog DETS table + TaskQueue DETS table. The hub reads current state from DETS on each iteration, exactly like Ralph reads progress.txt.

3. **Bounded iterations** -- Ralph defaults to max 10 iterations. AgentCom: max 3 decomposition attempts per goal (configurable). Max 2 verification attempts. Total: max 5 LLM calls per goal lifecycle.

4. **Completion = external verification, not LLM self-assessment** -- Ralph's key insight over ReAct: completion is judged by external criteria (tests pass, files exist), not by the LLM saying "I'm done." AgentCom already has this via mechanical verification (v1.2 Phase 21-22). Goal-level verification adds LLM judgment ON TOP of mechanical checks, not instead of.

**Confidence:** HIGH -- Pattern is well-documented across multiple implementations (snarktank/ralph, vercel-labs/ralph-loop-agent, ghuntley/loop). Implementation maps cleanly to existing PubSub event-driven architecture.

### Autonomous Codebase Improvement Scanning

When the FSM enters the Improving state, it scans repos for improvement opportunities.

**Scan types (priority order):**

1. **Test coverage gaps** -- List files with no corresponding test file. `lib/foo.ex` exists but `test/foo_test.exs` does not. Deterministic scan, no LLM needed.

2. **Code duplication** -- Send file contents to Claude: "Identify significant code duplication in these files. Suggest extraction patterns." LLM-assisted.

3. **Documentation gaps** -- Modules with `@moduledoc false` or no `@moduledoc`. Functions with no `@doc`. Deterministic scan.

4. **Dead code** -- Modules not referenced by any other module. Functions not called anywhere. Partially deterministic (grep-based), partially LLM-assisted.

5. **Dependency updates** -- Parse mix.exs and package.json for outdated dependencies. Check against hex.pm / npm registry. Deterministic.

6. **Simplification opportunities** -- Send complex modules (high cyclomatic complexity, many functions) to Claude: "Suggest simplifications." LLM-assisted.

**Output:** Each scan produces 0-N improvement goals submitted to GoalBacklog with source: `:improvement` and priority: `:low`. Human can promote priority if desired.

**Rate limiting:**
- Max 3 repo scans per hour
- Max 5 improvement goals per scan
- Max $1.00 Claude spend per improvement session
- Cooldown: 15 minutes between scans of the same repo

**Confidence:** MEDIUM -- Deterministic scans (test gaps, doc gaps, deps) are straightforward. LLM-assisted scans (duplication, simplification) require careful prompt engineering to avoid low-quality suggestions. Start with deterministic scans only; add LLM-assisted scans after calibrating quality.

### Tiered Autonomy

Risk-based decision matrix for auto-merge vs human review:

**Tier 1: Auto-merge (low risk)**
- Conditions (ALL must be true):
  - complexity_tier is :trivial or :standard
  - Lines changed <= 20
  - Only modifies existing files (no new files in public API)
  - All verification steps pass
  - Test coverage exists for modified code
  - No changes to: config files, security-related modules, public API surface
- Action: Merge directly to target branch. Log merge event. Dashboard notification.

**Tier 2: PR for review (elevated risk)**
- Conditions (ANY triggers Tier 2):
  - complexity_tier is :complex
  - Lines changed > 20
  - New files created
  - Changes to config, auth, or router modules
  - Verification steps have partial failures
  - Self-generated improvement goal (source: :improvement)
- Action: Create PR with description, verification report, and risk assessment. Assign human reviewer. Dashboard alert.

**Tier 3: Block and escalate (high risk)**
- Conditions (ANY triggers Tier 3):
  - Changes to authentication or authorization code
  - Changes to deployment configuration
  - Cross-repo changes
  - Goal verification failed after max attempts
- Action: Do NOT merge. Create PR with "NEEDS REVIEW" label. Send push notification. Dashboard critical alert.

**Configuration:**
```elixir
%{
  auto_merge_max_lines: 20,
  auto_merge_tiers: [:trivial, :standard],
  protected_paths: ["lib/agent_com/auth.ex", "config/", "mix.exs"],
  require_test_coverage: true,
  improvement_goals_always_pr: true
}
```

**Confidence:** MEDIUM -- Tiered autonomy is a clear industry pattern (risk-based human-in-the-loop). The specific thresholds (20 lines, protected paths) need calibration with real production data. Start conservative (everything is Tier 2 except explicitly trivial operations), then relax thresholds as confidence grows.

### Goal Completion Verification

After all tasks for a goal complete, the LLM evaluates whether the goal's intent was achieved.

**Verification prompt:**

```
You are evaluating whether a development goal has been measurably completed.

GOAL:
Title: {goal.title}
Description: {goal.description}
Success Criteria:
{numbered list of success_criteria}

TASK RESULTS:
{for each completed task: description + result summary + verification_report}

EVALUATE each success criterion:
1. Is it met? (YES/NO/PARTIAL)
2. What evidence supports this? (specific task results, file changes, test outputs)
3. If not met, what is missing?

OUTPUT (JSON):
{
  "complete": true/false,
  "criteria_results": [
    {"criterion": "...", "status": "met|partial|unmet", "evidence": "...", "gap": null|"..."}
  ],
  "overall_assessment": "Brief assessment",
  "suggested_follow_up": null | ["Follow-up action if gaps exist"]
}
```

**Decision logic:**
- All criteria "met" -> goal complete
- Any criterion "unmet" and attempt_count < max_attempts -> redecompose with gap context
- Any criterion "unmet" and attempt_count >= max_attempts -> goal failed, escalate to human
- Any criterion "partial" -> LLM suggests whether to accept or retry (human makes final call for Tier 2+ goals)

**Confidence:** MEDIUM -- LLM-as-judge is established but known to be unreliable for nuanced evaluation. Mitigation: mechanical verification (v1.2) provides the ground truth; LLM verification is an additional layer that catches semantic gaps. If LLM says "complete" but mechanical checks fail, mechanical checks win.

### Pre-Publication Repo Cleanup

Deterministic scanning for sensitive content before making a repo public.

**Pattern library:**

| Category | Patterns | Action |
|----------|----------|--------|
| API keys | `sk-ant-*`, `ghp_*`, `sk-*`, `AKIA*`, `xox[bpsa]-*` | BLOCK: must be removed |
| Tokens | `eyJ*` (JWT), hex strings > 32 chars in config | WARN: review for sensitivity |
| Personal info | Email regex, phone regex | WARN: review and redact |
| Paths | `C:\Users\*`, `/home/*/`, `~/*` | WARN: make portable |
| IPs | IPv4 regex in non-config files | WARN: replace with hostname or env var |
| Workspace files | `.planning/`, `.claude/`, `SOUL.md`, `IDENTITY.md`, `HEARTBEAT.md` | BLOCK: add to .gitignore |
| Hardcoded hostnames | Tailscale IPs (`100.64.*`), machine names | WARN: replace with env var |
| Debug artifacts | `erl_crash.dump`, `nul`, `tmp/`, `commit_msg.txt` | BLOCK: add to .gitignore |

**Output:** Structured report with file, line number, pattern matched, and severity (BLOCK vs WARN). BLOCK items prevent publication; WARN items need human review.

**Confidence:** HIGH -- Regex-based scanning is deterministic and well-understood. Pattern libraries exist (GitHub secret scanning, gitleaks). Implementation is straightforward file-by-file scanning.

## MVP Recommendation

Prioritize (in build order, respecting dependency chain):

1. **Goal Backlog** -- Foundation. The FSM needs goals to process. DETS-backed GenServer following TaskQueue/RepoRegistry patterns. API endpoint for submission. Minimum: HTTP API + internal generation. Defer: CLI tool, file watcher.

2. **LLM Goal Decomposition** -- Bridge between intent and execution. Claude API call from hub-side. Structured prompt producing enriched tasks. Submit decomposed tasks to existing TaskQueue.submit/1. This is the highest-risk feature: prompt quality determines system quality.

3. **Goal Completion Tracking** -- Monitor task events for goal's child tasks. Aggregate completion status. Simple event-driven tracking via PubSub subscription. No LLM needed for tracking.

4. **Hub FSM (4-state loop)** -- The brain. GenServer with state transitions driven by GoalBacklog and TaskQueue state. Start with 2 states (Executing, Resting) for MVP. Add Improving and Contemplating after the core loop works.

5. **Queue-Driven State Transitions** -- Wire FSM to PubSub events. Transition predicates as pure functions. Dashboard integration for FSM state visibility.

6. **Goal Completion Verification (LLM judge)** -- After core loop works, add LLM-based verification of goal-level success criteria. This is the "verify" in observe-act-verify.

7. **Tiered Autonomy** -- Risk-based merge/PR decision. Start conservative: everything creates PRs. Gradually enable auto-merge for trivial+standard with passing verification.

Defer to follow-up phases:

- **Autonomous codebase improvement scanning**: Needs the FSM + Improving state working first. Start with deterministic scans (test gaps, doc gaps), defer LLM-assisted scans.
- **Pre-publication repo cleanup**: Can be built independently, lower priority than core loop.
- **Pipeline pipelining**: Requires task dependency field in TaskQueue (new schema change). Build after core loop proves stable.
- **Future feature contemplation**: Lowest priority. Build after Improving state is calibrated.
- **Scalability analysis**: Nice-to-have, builds on existing metrics. Can be added anytime.

## User Workflows

### Workflow 1: Nathan Submits a Goal via API

```
1. Nathan: POST /api/goals
   {
     title: "Add WebSocket compression",
     description: "Enable permessage-deflate for WebSocket connections to reduce bandwidth",
     success_criteria: [
       "WebSocket connections use permessage-deflate when client supports it",
       "Existing agents connect without issues (backward compatible)",
       "Dashboard shows compression ratio"
     ],
     priority: "normal"
   }

2. Hub GoalBacklog: persists goal, broadcasts :goal_submitted on "goals" PubSub topic

3. Hub FSM (was in Resting state): receives event, transitions to Executing
   - Picks goal from backlog (highest priority first)
   - Calls Claude API with decomposition prompt
   - Claude returns 5 tasks:
     a. "Add permessage-deflate option to Bandit config" (trivial, 3 lines)
     b. "Update Socket module to advertise compression support" (standard)
     c. "Add compression ratio tracking to Telemetry" (standard)
     d. "Update dashboard to show compression metrics" (standard)
     e. "Add integration test for compressed WebSocket connection" (standard)

4. Hub submits 5 tasks to TaskQueue.submit/1 (existing pipeline takes over)
   - Scheduler assigns to idle agents by complexity tier
   - Agents execute, verify, complete
   - PubSub events flow back to HubFSM

5. All 5 tasks complete. Hub runs goal verification:
   - Claude evaluates: "All 3 success criteria met. Evidence: [test results, config change, dashboard update]"
   - Goal marked :complete
   - Hub FSM: no more goals -> transitions to Improving (or Resting)

6. Dashboard shows: Goal completed, 5/5 tasks done, verification passed
```

### Workflow 2: Autonomous Improvement Cycle

```
1. Hub FSM is in Resting state. No goals in backlog. Timer: idle for 30 minutes.

2. FSM transitions to Improving:
   - Queries RepoRegistry.list_repos() for active repos in priority order
   - First repo: AgentCom (this repo)

3. Hub scans AgentCom for improvement opportunities:
   a. Deterministic: finds 3 modules without test files:
      - lib/agent_com/dashboard_notifier.ex (no test)
      - lib/agent_com/dashboard_state.ex (no test)
      - lib/agent_com/alerter.ex (no test)
   b. Deterministic: finds 2 modules with @moduledoc false:
      - lib/agent_com/endpoint.ex
      - lib/mix/tasks/gen_token.ex

4. Hub generates 5 improvement goals:
   - "Add tests for DashboardNotifier module" (priority: low, source: improvement)
   - "Add tests for DashboardState module" (priority: low, source: improvement)
   - "Add tests for Alerter module" (priority: low, source: improvement)
   - "Add @moduledoc to Endpoint module" (priority: low, source: improvement)
   - "Add @moduledoc to GenToken mix task" (priority: low, source: improvement)

5. FSM transitions to Executing to process improvement goals
   - Each goal decomposed into tasks
   - Tasks execute through normal pipeline
   - Tiered autonomy: test additions are standard complexity, <20 lines -> auto-merge
   - Doc additions are trivial complexity, <5 lines -> auto-merge

6. All improvement goals complete. No more repos to scan.
   FSM transitions to Resting (or Contemplating if enabled).

7. Nathan returns to find: 5 PRs merged, test coverage improved, docs updated.
   Dashboard shows full improvement cycle history.
```

### Workflow 3: Goal Fails Verification

```
1. Goal: "Refactor TaskQueue to use ETS for priority index"
   Success criteria:
   - "Priority index stored in ETS, not in GenServer state"
   - "Dequeue performance improves (benchmark test)"
   - "All existing TaskQueue tests pass"

2. Decomposition produces 4 tasks. All complete successfully.

3. Goal verification:
   Claude evaluates task results:
   - Criterion 1: MET (ETS table created, index stored there)
   - Criterion 2: UNMET ("No benchmark test was created. Cannot verify performance improvement.")
   - Criterion 3: MET (all tests pass)

4. Verification returns {complete: false, gaps: ["Missing benchmark test"]}

5. Hub: attempt_count < max_attempts (3). Redecompose with gap context:
   "Previous attempt completed refactoring but missed: benchmark test for dequeue performance.
    Create a benchmark test comparing ETS-based vs state-based priority index performance."

6. Decomposition produces 1 additional task. Task executes, creates benchmark.

7. Re-verification: all criteria now MET. Goal complete.

8. Total LLM cost: 3 Claude calls (decompose + verify + redecompose) + 1 task execution
```

## Sources

### Primary (HIGH confidence)
- AgentCom codebase -- agent_fsm.ex, scheduler.ex, task_queue.ex, repo_registry.ex, complexity.ex, sidecar/index.js, sidecar/lib/execution/verification-loop.js, sidecar/lib/execution/dispatcher.js (direct code examination, 2026-02-12)
- [snarktank/ralph](https://github.com/snarktank/ralph) -- Autonomous AI agent loop implementation: prd.json, progress.txt, 10-iteration default, passes: true/false tracking (official implementation, verified via WebFetch)
- [vercel-labs/ralph-loop-agent](https://github.com/vercel-labs/ralph-loop-agent) -- Continuous Autonomy for AI SDK: inner/outer loop, verifyCompletion function, iterationCountIs/tokenCountIs/costIs stop conditions (official Vercel Labs, verified via WebFetch)
- [Ralph Wiggum Loop - beuke.org](https://beuke.org/ralph-wiggum-loop/) -- Detailed loop structure: perception-action-feedback-iteration cycle, fresh context per iteration, stopping criteria, failure modes (oscillation, context overload, hallucination entrenchment) (verified via WebFetch)
- [Everything is a Ralph Loop - ghuntley.com](https://ghuntley.com/loop/) -- Core insight: monolithic, single-process-per-task, context engineering as primary mechanism, CTRL+C checkpoints (verified via WebFetch)
- [From ReAct to Ralph Loop - Alibaba Cloud](https://www.alibabacloud.com/blog/from-react-to-ralph-loop-a-continuous-iteration-paradigm-for-ai-agents_602799) -- Detailed comparison: Ralph shifts control from internal LLM judgment to external verification, stop hook interception, completion promise pattern (verified via WebFetch)

### Secondary (MEDIUM confidence)
- [Elephant Carpaccio - Henrik Kniberg](https://blog.crisp.se/2013/07/25/henrikkniberg/elephant-carpaccio-facilitation-guide) -- Original facilitation guide: 15-20 thin vertical slices, nano-incremental development, risk reduction through small batches (established Agile practice)
- [Agent Goal Decomposition - SparkCo](https://sparkco.ai/blog/mastering-agent-goal-decomposition-in-ai-systems) -- Planner Agent pattern: dependency graphs (DAGs), complexity thresholds, four-step workflow (task assignment, planning, iterative improvement, integration) (verified via WebFetch)
- [GoalAct - NCIIP 2025 Best Paper](https://github.com/cjj826/GoalAct) -- Hierarchical decomposition into high-level skills, reducing planning complexity (academic, peer-reviewed)
- [Backlog.md](https://github.com/MrLesk/Backlog.md) -- Markdown-native task management for Git repos with MCP integration, CLI commands, priority/status/dependency tracking (open source, verified via WebFetch)
- [Eight Trends - Claude Blog 2026](https://claude.com/blog/eight-trends-defining-how-software-gets-built-in-2026) -- Human oversight model: 60% AI collaboration, 0-20% full delegation, four priority areas for safety (official Anthropic, verified via WebFetch)
- [OODA Loop for Agentic AI - Sogeti Labs](https://labs.sogeti.com/harnessing-the-ooda-loop-for-agentic-ai-from-generative-foundations-to-proactive-intelligence/) -- Observe-Orient-Decide-Act framework for autonomous agents
- [Task Completion Metric - DeepEval](https://deepeval.com/docs/metrics-task-completion) -- Success rate measurement, partial completion scoring for multi-step tasks
- [GitHub: Removing Sensitive Data](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository) -- git-filter-repo, BFG Repo-Cleaner, .gitignore prevention (official GitHub docs)
- [Cogent: Self-Evolving Software 2026](https://www.cogentinfo.com/resources/ai-driven-self-evolving-software-the-rise-of-autonomous-codebases-by-2026) -- AI agents monitoring code health, fixing bugs, refactoring architecture, generating docs autonomously

### Tertiary (LOW confidence)
- [Autonomous Enterprise 2026 - CNCF](https://www.cncf.io/blog/2026/01/23/the-autonomous-enterprise-and-the-four-pillars-of-platform-control-2026-forecast/) -- Platform control pillars for autonomous systems (industry forecast)
- [OpenAgentSafety Framework](https://arxiv.org/pdf/2507.06134) -- Comprehensive framework for agent safety evaluation (academic)
- [Agents At Work: 2026 Playbook](https://promptengineering.org/agents-at-work-the-2026-playbook-for-building-reliable-agentic-workflows/) -- Verification-aware planning patterns (community guide)

---
*Research completed: 2026-02-12*
*Focus: Hub FSM autonomous brain features for v1.3 milestone*
*Predecessor: v1.2 FEATURES.md covered Smart Agent Pipeline (shipped)*
