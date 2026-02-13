# Domain Pitfalls

**Domain:** Adding autonomous Hub FSM brain to existing distributed agent coordination system
**Researched:** 2026-02-12
**Codebase analyzed:** AgentCom v1.2 (Elixir/BEAM hub ~22K LOC, Node.js sidecars ~4.5K LOC, 10 DETS tables, 24 supervised GenServers, PubSub coordination, 5 AI agents on Tailscale mesh)

---

## Critical Pitfalls

Mistakes that cause rewrites, data loss, or runaway costs.

---

### Pitfall 1: Token Cost Spiral from Autonomous Thinking

**What goes wrong:** The Hub FSM enters Contemplating or Improving and makes Claude API calls for strategic thinking -- goal decomposition, improvement identification, completion verification, contemplation proposals. Without hard caps, a single contemplation session can burn $50-200 in API credits. The problem compounds because the LLM may identify improvements that require more LLM calls to evaluate, creating recursive spending. A contemplation that spawns 10 improvement scans, each requiring Claude analysis, each producing 5 sub-tasks needing decomposition -- the cost tree fans out exponentially.

**Why it happens:** The Hub FSM is designed to think autonomously. Unlike the existing sidecar execution (where a human submitted a task with known scope), the hub generates its own work. There is no human gating the volume of LLM calls. The existing `cost-calculator.js` tracks cost per task execution, but the Hub's strategic thinking happens outside the task pipeline -- it is meta-work with no natural cost boundary.

**Warning signs (concrete examples):**
- Hub enters Contemplating, generates 12 improvement proposals at ~$0.50 each ($6), then decomposes each into 4 tasks at ~$0.30 each ($14.40), then verifies each decomposition at ~$0.20 ($9.60) = $30 for a single contemplation cycle
- Hub identifies "cost tracking could be improved" as an improvement, spending $5 in API calls to analyze its own API spending patterns -- meta-loop
- Weekend operation: 48 contemplation cycles x $30 each = $1,440 unattended

**Prevention:**
1. **CostLedger GenServer.** Track cumulative Claude API spend per hour/day/session. The Hub FSM checks the ledger before every API call. If budget exhausted, FSM transitions to Resting regardless of queue state. This is new infrastructure the Hub phase must build.
2. **Per-state token budgets.** Executing = $10/hour, Improving = $3/hour, Contemplating = $2/hour. The Hub checks budget before entering each state.
3. **Tiered model usage for meta-thinking.** Use Haiku ($1/$5 per M tokens) for triage ("Is this worth decomposing?"), Sonnet ($3/$15) for decomposition, Opus ($5/$25) only for final verification of complex completions. The existing complexity tier routing (trivial/standard/complex in `tier_resolver.ex`) should extend to the Hub's own thinking.
4. **Cost telemetry.** Emit `[:agent_com, :hub_fsm, :api_call]` with token counts and estimated cost. Wire into existing Alerter with a `hub_api_spend` alert rule. The Alerter (5 existing rules) supports adding new rules dynamically.
5. **Hard cap in code, not prompts.** The LLM cannot be trusted to honor "don't spend more than $X" instructions. The CostLedger must be a GenServer that the Hub FSM queries synchronously before every API call.

**Detection:** `hub_fsm_api_cost_usd` metric in MetricsCollector. Dashboard panel showing Hub API spend over time, separate from task execution costs. Alert when hourly spend exceeds threshold.

**Phase to address:** Hub FSM core phase. Cost controls must exist before the FSM makes its first API call. Do not ship autonomous thinking without budget limits.

**Confidence:** HIGH. Every production autonomous LLM agent deployment from 2025-2026 cites uncontrolled API spending as the most common and most expensive failure mode. The CodieSHub prevention guide states: "Hard caps on iterations, tokens, time, and spend are non-negotiable in production."

---

### Pitfall 2: Infinite Improvement Loop (The Sisyphus Pattern)

**What goes wrong:** The Hub's Improving state scans a codebase, identifies improvement X, generates a task, the task gets executed, and on the next scan the Hub identifies improvement Y (caused by improvement X). Or worse: the Hub identifies X as an improvement, executes it, then identifies "undo X" as the next improvement. The system oscillates between two states forever, consuming resources and producing no net value.

**Warning signs (concrete examples):**
- Scan 1: "Extract helper function `format_timestamp/1` from `scheduler.ex`" -- executed, function extracted
- Scan 2: "Inline trivial helper `format_timestamp/1` for readability" -- executed, function inlined
- Scan 3: "Extract helper function `format_timestamp/1` from `scheduler.ex`" -- loop detected too late
- Git history: commits alternate between "extract" and "inline" changes to the same code

**Why it happens:** LLMs have no stable "good enough" threshold. Each scan produces a fresh context window with no memory of previous improvements. The LLM sees current code state and generates opinions about it. Those opinions are not deterministic -- the same code can trigger different improvement suggestions on different runs. The existing system has no improvement history tracking.

**Consequences:** Task queue fills with contradictory improvement tasks. Agents churn on improvements that cancel each other out. Git history becomes a mess of "refactor X" / "refactor X back" commits. If auto-merge is enabled for small improvements, main branch accumulates pointless churn.

**Prevention:**
1. **Improvement history with deduplication.** New DETS table (or namespaced key in a hub_state table) storing attempted improvements: `{hash_of_description, status, timestamp, outcome, files_touched}`. Before generating a new improvement task, check if a semantically similar improvement was attempted in the last N hours.
2. **Improvement cooldown per file/module.** After improving file X, do not scan file X again for at least 24 hours. Track last-improved timestamps per file path.
3. **Net-value gate.** Before committing an improvement, compare before/after codebase state against objective metrics: test count, test pass rate, total line count, number of functions. If metrics are neutral or worse, reject the improvement.
4. **Improvement budget per scan cycle.** Limit the Improving state to generating at most 3-5 improvement tasks per cycle. After that, transition to Contemplating or Resting.
5. **Anti-oscillation detection.** If the same file is modified by two consecutive improvement tasks, flag and halt. Compare git diffs of consecutive improvements to the same file -- if the second diff is the inverse of the first, block it.

**Detection:** Track the ratio of improvements accepted vs. reverted. Monitor git log for "undo" or "revert" patterns in auto-generated commits. Dashboard chart: improvements per file over time.

**Phase to address:** Improvement scanning phase. The history table and cooldown must ship with the scanner from day one.

**Confidence:** HIGH. The Ralph Loop pattern explicitly addresses this by using external verification (file system state, test results) rather than LLM self-assessment. Geoffrey Huntley's work on Ralph Loops emphasizes: "The self-assessment mechanism of LLMs is unreliable -- it exits when it subjectively thinks it is 'complete' rather than when it meets objectively verifiable standards."

---

### Pitfall 3: Hub FSM State Corruption from Concurrent Events

**What goes wrong:** The Hub FSM is a single GenServer receiving events from multiple sources: PubSub task events, timer-based state transitions, API-triggered goal submissions, improvement scan completions. If the FSM processes a timer-based transition to Resting while simultaneously receiving a goal-complete event that should trigger a transition to Executing, the state machine enters an inconsistent state or silently drops the goal-complete event.

**Warning signs (concrete examples):**
- Hub is in Executing state. A `Process.send_after` Resting timer fires (from the previous cycle). The GenServer mailbox has: `[:resting_timeout, {:goal_complete, goal_id}]`. The `:resting_timeout` is processed first, transitions to Resting, and the `:goal_complete` event hits a "wrong state" guard and is silently dropped. The goal is never marked complete.
- Hub receives two PubSub events in quick succession: `{:task_event, :task_completed}` (last task in a goal) and `{:improvement_scan_complete, results}`. Both trigger state transitions. The second event arrives before the first transition completes, causing the FSM to attempt an invalid transition.

**Why it happens:** The existing `AgentFSM` is per-agent (one process per agent, events come from one WebSocket). The Hub FSM is a singleton receiving events from the entire system -- much higher event volume and diversity. The `AgentFSM` already handles stale timers (line 493 of `agent_fsm.ex`: ignoring acceptance timeouts for wrong task IDs). The Hub FSM needs similar handling but with a larger state space and more timer types.

**Consequences:** Hub stuck in wrong state. Goals complete but FSM does not transition. Resting timer interrupts active execution. FSM transitions to Improving while still Executing, causing improvement scanner to run on code that is mid-modification by an active task.

**Prevention:**
1. **Consider `gen_statem` instead of GenServer.** Erlang's `:gen_statem` provides state-specific callbacks, state timeouts (auto-cancelled on state change), and `postpone` semantics (deferring events to a later state). The DockYard article on state timeouts shows how `:gen_statem` eliminates the stale-timer problem entirely.
2. **If using GenServer:** Implement a transition function identical to `AgentFSM.transition/2` (line 508) with a `@valid_transitions` map. Guard every `handle_info` and `handle_cast` with a state check. Cancel ALL pending timers on every state transition (not just one timer as in `agent_fsm.ex`).
3. **Event queuing with priorities.** If an event arrives during a state where it cannot be processed, queue it (do not drop it). Process queued events after completing the current state's work. `gen_statem`'s `postpone` action handles this automatically.
4. **Watchdog timer.** If the Hub FSM has been in any single state for more than a configurable maximum duration (e.g., 2 hours in Executing, 30 minutes in Contemplating), force-transition to Resting with a warning log. This prevents stuck states.
5. **State transition telemetry.** Emit `[:agent_com, :hub_fsm, :transition]` on every state change with `from_state`, `to_state`, `trigger`, `duration_in_previous_state_ms`. Wire into dashboard.

**Detection:** Dashboard panel showing current Hub FSM state with time-in-state. Alert if time-in-state exceeds threshold. Log every transition with the trigger that caused it.

**Phase to address:** Hub FSM core phase. This is architectural and must be decided before implementation begins.

**Confidence:** HIGH. The existing codebase already demonstrates the timer race pattern in `AgentFSM` (stale acceptance timeout handling). The Hub FSM's event diversity guarantees this problem will manifest without explicit handling.

---

### Pitfall 4: Auto-Merge Regression Introduction

**What goes wrong:** The Hub's tiered autonomy feature auto-merges "small" improvements (style fixes, docs, simple refactors) without human review. An improvement passes verification checks (tests pass, files exist, git clean) but introduces a subtle regression: a refactored function changes return value semantics, a "style fix" changes indentation that breaks YAML parsing, a "documentation update" overwrites important context.

**Warning signs (concrete examples):**
- Hub auto-merges "simplify `normalize_capabilities/1` in `agent_fsm.ex`" -- the simplification removes the `nil` rejection clause (line 537). Now `nil` capabilities leak through, causing downstream `agent_matches_task?/2` to crash when matching against `nil`.
- Hub auto-merges "update error messages in `task_queue.ex`" -- changes `:not_assigned` error atom to `"not_assigned"` string. The `reclaim_task/1` caller pattern-matches on the atom and silently falls through to a catch-all.
- Tests pass because no test covers the `nil` capability case or the error atom matching.

**Why it happens:** The existing verification system (`verification.js`) runs mechanical checks: `file_exists`, `test_passes`, `git_clean`, `command_succeeds`. These are necessary but not sufficient for semantic regressions. The LLM-generated code passes tests because tests do not cover every edge case. Test suites are never complete.

**Consequences:** Main branch accumulates subtle regressions. Because changes are small and auto-merged, they are hard to bisect. The compounding effect of many small regressions makes the codebase progressively worse while each individual change looks harmless.

**Prevention:**
1. **Never auto-merge to main directly.** Even "safe" auto-merges go to an integration branch (`hub-improvements`). Batch merge to main on a schedule or after human spot-check.
2. **Conservative size gates.** Auto-merge only if: fewer than 10 lines changed, zero new files, zero deleted files, all existing tests pass, no changes to public function signatures (detect via AST comparison for `.ex` files). Any condition failure creates a PR instead.
3. **Semantic diff analysis.** Before auto-merging, compare before/after test counts. If any test was removed or renamed, escalate to PR. If any function signature changed, escalate.
4. **Auto-merge quota.** Maximum 3 auto-merges per day per repo. After that, all improvements become PRs. Limits blast radius.
5. **Auto-revert mechanism.** Tag each auto-merge commit with `[auto-merge] hub-improvement-{id}`. Run full test suite 5 minutes after merge. If tests fail, auto-revert immediately and alert.
6. **Start with PR-only mode.** Ship the entire improvement pipeline with PR creation only. Add auto-merge as a later enhancement after the PR pipeline proves reliable with 20+ successful improvements.

**Detection:** Track test count over time. Alert if test count decreases after auto-merge. Track test execution time -- unexpected increases indicate added complexity.

**Phase to address:** Tiered autonomy phase. Start with PR-only; add auto-merge later.

**Confidence:** HIGH. GitLab's AI Merge Agent (November 2025) reports 85% success rate -- meaning 15% require human intervention. For a smaller system without GitLab's sophistication, the failure rate will be higher.

---

### Pitfall 5: Goal Decomposition Hallucination (Phantom Tasks)

**What goes wrong:** The Hub FSM uses Claude to decompose a high-level goal into concrete tasks. The LLM generates tasks referencing files, modules, or patterns that do not exist. Example: "Refactor `lib/agent_com/error_handler.ex` to use structured error types" -- but `error_handler.ex` does not exist. The task enters the queue, gets assigned, and the agent either fails or worse, creates the fictional file from scratch.

**Warning signs (concrete examples):**
- Goal: "improve error handling." Decomposed task: "Add Ecto changesets to the Agent schema" -- this project does not use Ecto.
- Goal: "add monitoring." Decomposed task: "Configure Prometheus exporter in `config/prod.exs`" -- there is no `prod.exs` in this project (single `config.exs`).
- Goal: "clean up deprecated code." Decomposed task: "Remove usage of `Phoenix.Channel`" -- this project uses raw WebSocket via WebSock, not Phoenix Channels.

**Why it happens:** The LLM decomposes goals based on training data about "typical Elixir projects," not this specific codebase. Without grounding in the actual file tree and module structure, the LLM invents plausible-sounding but fictional work items. This codebase is non-standard: DETS instead of Ecto, Bandit instead of Phoenix, flat GenServer state machines instead of `gen_statem`. The LLM will pattern-match to typical conventions.

**Consequences:** Phantom tasks fill the queue and consume real resources (agent time, API tokens, git branches). If an agent "succeeds" at a phantom task by creating new files the LLM described, the codebase grows unnecessary code.

**Prevention:**
1. **Ground decomposition in actual file tree.** Before decomposing, feed the LLM: `ls lib/agent_com/*.ex`, `ls sidecar/lib/`, module names and public function signatures. Prompt: "ONLY reference files and modules that appear in the file tree above."
2. **Post-decomposition validation.** After the LLM generates tasks, mechanically verify: for each file path mentioned, check `File.exists?`. For each module name, verify it is defined. Reject tasks referencing non-existent entities.
3. **Two-pass decomposition.** First pass: abstract tasks ("improve error handling in auth module"). Second pass: provide actual `auth.ex` contents and ask for concrete, grounded task with specific line numbers.
4. **Include codebase context.** The existing `.planning/codebase/ARCHITECTURE.md` describes the actual architecture. Include it in every decomposition prompt. Add a "what this project does NOT use" section: no Ecto, no Phoenix, no PostgreSQL.
5. **Decomposition confidence scoring.** Ask LLM to rate confidence (1-5) per task. Tasks with confidence < 3 go to "needs human review" queue.

**Detection:** Track task failure rate by source. If hub-decomposed tasks fail at higher rate than human-submitted tasks, decomposition prompts need grounding.

**Phase to address:** Goal decomposition phase. Grounding must be built into the decomposition pipeline from day one.

**Confidence:** HIGH. Amazon Science's 2025 paper on task decomposition specifically calls out "sub-tasks that don't map to available tools or agent capabilities" as a primary failure mode. The arXiv paper on multi-agent failures identifies 14 distinct failure modes, with "decomposition inaccuracies" among the most impactful.

---

## Moderate Pitfalls

Mistakes that cause significant debugging time or partial rewrites.

---

### Pitfall 6: Supervisor Tree Disruption When Adding Hub FSM

**What goes wrong:** Adding a new GenServer (Hub FSM) to `application.ex`'s supervision tree with wrong restart strategy or position causes cascading failures. The Hub FSM depends on TaskQueue, Scheduler, RepoRegistry, and DetsBackup -- all must be started first. If placed before dependencies in the `children` list, it crashes on init. With `strategy: :one_for_one` (line 61), the crash is isolated but the Hub FSM never starts.

**Why it happens:** The supervisor tree has 24 children (lines 32-58 of `application.ex`). Ordering is deliberate: PubSub first, then Registries, then GenServers. The Hub FSM needs TaskQueue and Scheduler running before it subscribes to PubSub topics.

**Prevention:**
1. Place Hub FSM after Scheduler and RepoRegistry but before Bandit in the children list.
2. Use `restart: :transient` -- restart on abnormal termination but not normal shutdown.
3. Defensive init: if dependencies not yet available, use `Process.send_after(self(), :retry_init, 1000)` rather than crashing.
4. Test the boot sequence: start full application and verify all children running.

**Detection:** Application crash on startup with `{:noproc, {GenServer, :call, [AgentCom.TaskQueue, ...]}}`.

**Phase to address:** Hub FSM core phase.

**Confidence:** HIGH. Basic OTP, but the large supervisor tree makes ordering mistakes easy.

---

### Pitfall 7: DETS Table Proliferation and Backup Coverage Gap

**What goes wrong:** The Hub FSM needs persistent state: goal backlog, improvement history, contemplation log, cost ledger. Each could be a new DETS table. The existing `DetsBackup` has a hardcoded `@tables` list of 10 tables (line 20-31 of `dets_backup.ex`). If new tables are added but `@tables` is not updated, new tables are not backed up, not compacted, not monitored, and not recoverable.

**Why it happens:** `@tables` is a compile-time constant. Adding a new DETS table requires updating three places: (1) the new GenServer that opens it, (2) `@tables` in DetsBackup, (3) `table_owner/1` (line 321-330 of `dets_backup.ex`) for compaction. Missing any one creates a silent gap.

**Prevention:**
1. **Minimize new tables.** Use one `hub_state` DETS table with namespaced keys: `{:goals, goal_id}`, `{:improvements, hash}`, `{:cost_ledger, date}`. One table to register.
2. **Registration validation at startup.** Add a function querying `:dets.all()` at boot and comparing against `@tables`. Log warning for unregistered tables.
3. **Implementation checklist.** Every plan adding a DETS table must include "Update DetsBackup @tables and table_owner/1" as a verification step.

**Detection:** Health endpoint (`/api/health/dets`) shows per-table metrics. New table absent from health response means it is unregistered.

**Phase to address:** Hub FSM core or goal backlog phase.

**Confidence:** HIGH. Mechanical integration concern unique to this codebase.

---

### Pitfall 8: Goal Completion Verification False Positives

**What goes wrong:** The Hub FSM uses LLM-powered verification to determine if a goal is complete. The LLM says "yes" when the goal is not complete, because verification prompt lacks context or the LLM optimistically interprets partial completion as full. Hub marks goal as done, moves to next goal, incomplete work is never revisited.

**Warning signs (concrete examples):**
- Goal: "Improve error handling across all GenServers." Sub-tasks completed for 4 of 12 GenServers. LLM verification: "Error handling has been significantly improved across the codebase" = true. Goal marked complete with 8 GenServers untouched.
- Goal: "Add telemetry to all public API endpoints." LLM verification checks current codebase and sees telemetry exists (it was already there from v1.1). Reports goal complete even though no new telemetry was added.

**Why it happens:** The existing verification system (Phase 21-22) uses mechanical checks that are deterministic. Goal completion is semantic judgment. "Is error handling improved across the codebase?" cannot be answered by checking file existence. The Ralph Loop insight applies: LLM self-assessment is unreliable.

**Prevention:**
1. **Require mechanical success criteria for every goal.** At creation time, require at least one verifiable criterion: "tests pass," "file X exists," "endpoint Y returns 200." Goals without mechanical criteria cannot be auto-completed.
2. **Two-judge verification.** LLM for semantic assessment plus mechanical checks. Both must agree. If LLM says complete but mechanical checks fail, goal stays open.
3. **Sub-task completion tracking.** A goal is complete only when ALL decomposed sub-tasks are completed (not just "most"). The Hub tracks sub-task completion percentage and requires 100%.
4. **Human review for complex goals.** Goals with more than 5 sub-tasks or touching more than 3 files must be human-verified. Hub transitions them to "pending review" state.

**Detection:** Track re-opened goals (marked complete then found incomplete). Re-open rate > 10% means verification is too loose.

**Phase to address:** Goal lifecycle phase.

**Confidence:** MEDIUM. The existing verification infrastructure provides patterns, but semantic verification is harder than mechanical.

---

### Pitfall 9: Improvement Scanner Bikeshedding

**What goes wrong:** The improvement scanner identifies cosmetic improvements instead of substantive ones: variable renames, import reordering, type spec additions to internal helpers, comment reformatting. The task queue fills with bikeshedding that consumes agent capacity while high-value work waits.

**Warning signs (concrete examples):**
- 10 improvement tasks generated: 7 are "rename variable `x` to `more_descriptive_name`", 2 are "add @doc to private function", 1 is "fix potential race condition in timer handling." The race condition fix (actual value) is buried under style noise.
- Scanner generates "add @moduledoc to `AgentCom.TaskRouter.TierResolver`" -- the module already has adequate documentation.

**Why it happens:** LLMs are trained on code review discussions disproportionately about style and naming. When asked "what could be improved?", the LLM defaults to easiest observations. Structural improvements require deeper analysis.

**Prevention:**
1. **Category-priority mapping.** security > correctness > performance > reliability > observability > readability > style. Security = `urgent`, style = `low`. Scanner must categorize each improvement.
2. **Minimum impact threshold.** Reject improvements affecting fewer than 3 lines or only changing comments/whitespace.
3. **Prompt engineering.** Scanner prompt: "Focus on bugs, security issues, error handling gaps, and performance problems. Do NOT suggest variable renames, comment changes, import reordering, or formatting changes."
4. **Rate limit by category.** Maximum 1 style improvement per day, unlimited security/correctness.
5. **Value scoring.** Ask LLM to estimate impact (1-10). Discard below 5.

**Detection:** Tag improvement tasks by category. Dashboard chart showing improvements by category over time. Style/naming dominance means prompt recalibration needed.

**Phase to address:** Improvement scanning phase.

**Confidence:** HIGH. Every code review tool based on LLMs (CodeRabbit, Sourcery, etc.) has had to explicitly filter out bikeshedding.

---

### Pitfall 10: Secret Scrubbing Breaks Git History and Agent Collaboration

**What goes wrong:** Pre-publication cleanup uses `git filter-repo` to scrub secrets from history. This rewrites every commit hash, breaking: (1) all existing clones (5 agents must re-clone), (2) all open PRs, (3) all branch tracking, (4) all commit references in planning files (`.planning/MILESTONES.md` references git ranges like `107f592a..a529eed`).

**Warning signs (concrete examples):**
- `git filter-repo --invert-paths --path priv/tokens.json` rewrites the entire history. All 337+ commits get new hashes. The milestone audit records (`v1.1..v1.2`, commit ranges) become invalid.
- Sidecar's `agentcom-git.js` runs `git pull --rebase origin main`. After filter-repo, this fails with diverged history. All 5 sidecars crash-loop.
- On Windows (this project's platform): case-insensitive filesystem causes `git filter-repo` to silently choose wrong version of files differing only in case.

**Why it happens:** `git filter-repo` is destructive by design. The `git filter-repo` man page explicitly warns: "using git filter-repo is destructive and will rewrite the entire history of the original repository."

**Prevention:**
1. **Scrub on a fork, not the original.** Create a fresh clone, scrub, push as public repo. Keep unscrubbed repo as internal development repo.
2. **Coordinate with agents.** Before scrubbing: pause all repos in RepoRegistry, wait for in-flight tasks to complete. After: update sidecar configs, re-clone on each machine.
3. **Inventory secrets first.** Use `gitleaks detect --log-opts="--all"` to scan full history. Verify completeness. After scrubbing, run again to confirm removal.
4. **Test on throwaway copy.** Clone, scrub, verify compilation and tests pass, verify no secrets remain. Then execute on real target.
5. **Expect secrets in unexpected places.** Check: commit messages (tokens in debug output), `priv/tokens.json` (plaintext tokens), sidecar `config.json` files (API keys), log files (if committed), DETS backup files (if committed).
6. **Pre-commit hook after scrub.** Add `gitleaks` as a pre-commit hook and CI step to prevent re-introduction.

**Detection:** `gitleaks detect --log-opts="--all"` before and after. Compare results.

**Phase to address:** Pre-publication cleanup phase (last phase). Must be planned as coordinated operation.

**Confidence:** HIGH. The `git filter-repo` documentation explicitly warns about these issues.

---

### Pitfall 11: Scheduler Starvation from Hub-Generated Task Volume

**What goes wrong:** The Hub FSM generates improvement tasks and decomposes goals into sub-tasks. These flow into the existing TaskQueue and Scheduler. If the Hub generates 20 improvement tasks while 5 human-submitted tasks wait, the scheduler may match agents to improvement tasks first (equal or higher priority), starving human-submitted work.

**Warning signs (concrete examples):**
- Nathan submits "Fix authentication bug on endpoint X" at priority `normal`. Hub has already queued 15 improvement tasks at priority `normal`. The 15 hub tasks were submitted first (lower `created_at`), so FIFO ordering puts Nathan's task 16th in line. With 5 agents, Nathan waits for 3 improvement cycles before his bug fix gets picked up.
- Hub's Improving state generates 10 tasks in a batch. These immediately consume all 5 agents. The queue is "busy" but not productive from Nathan's perspective.

**Why it happens:** The scheduler's `try_schedule_all` (line 258 of `scheduler.ex`) iterates tasks in priority+FIFO order. It does not distinguish task sources. Hub-generated tasks compete equally with human-submitted tasks.

**Prevention:**
1. **Task source field.** Add `source` to task schema: `"human"`, `"hub_goal"`, `"hub_improvement"`, `"hub_contemplation"`. Use for filtering and priority adjustments.
2. **Source-aware priority boost.** Human-submitted tasks get implicit priority boost (-1 to priority integer). Hub improvement tasks get priority floor (minimum `low` = 3).
3. **Reserved agent capacity.** At least 1 agent must always be available for non-hub work. Scheduler skips hub tasks if assigning would leave zero agents for human tasks.
4. **Hub task rate limiting.** Hub submits max N tasks per hour. Batch decomposition outputs (15 tasks released as 3 batches of 5 with delays).
5. **Preemption for urgent human tasks.** If human task with `urgent` priority enters queue and all agents work on hub tasks, reclaim least-important hub task.

**Detection:** Dashboard: average wait time for human-submitted vs. hub-generated tasks. If human wait time increases after hub FSM enabled, priority scheme needs adjustment.

**Phase to address:** Goal decomposition and improvement scanning phases. `source` field added in first phase.

**Confidence:** HIGH. Basic resource contention, becomes visible immediately when hub starts generating tasks.

---

## Minor Pitfalls

Mistakes that cause inconvenience or need small fixes.

---

### Pitfall 12: Over-Decomposition of Goals

**What goes wrong:** LLM decomposes a simple goal into excessive tiny tasks. "Add health check endpoint" becomes 8 tasks: "create route", "add handler", "return JSON", "add tests", "add docs", "update dashboard", "add telemetry", "add to operations guide". Each task is too small, and coordination overhead (branch creation, PR, merge) exceeds the work itself.

**Prevention:**
1. Minimum task size: if describable in fewer than 20 words and touching 1 file, merge with related tasks.
2. Prompt: "Generate 2-5 tasks per goal. Each should represent 10-60 minutes of work."
3. Post-decomposition consolidation: "These tasks are too granular. Merge related tasks into cohesive units."

**Phase to address:** Goal decomposition phase.

**Confidence:** MEDIUM. Impact depends on prompt engineering quality.

---

### Pitfall 13: Contemplation State Producing Vaporware Proposals

**What goes wrong:** Contemplating state generates feature proposals that sound impressive but are infeasible, redundant with existing features, or out of scope. Proposals consume review time and create backlog noise.

**Prevention:**
1. Include "Out of Scope" section from PROJECT.md in contemplation prompt so LLM does not re-propose rejected ideas. The existing out-of-scope list has 15 items with explicit rationale.
2. Each proposal must include: estimated complexity, dependencies, required infrastructure.
3. Maximum 1 proposal per contemplation cycle.

**Phase to address:** Contemplation phase.

**Confidence:** MEDIUM.

---

### Pitfall 14: Pipeline Pipelining Creating Branch Conflicts

**What goes wrong:** Pipeline pipelining front-loads research/planning so multiple goals are in-flight simultaneously. If two goals touch the same files (both modify `scheduler.ex`), the second goal's execution branch has merge conflicts the agents cannot resolve autonomously.

**Prevention:**
1. File-level locking: record which files each goal will modify (from `file_hints`). Prevent scheduling tasks with overlapping file targets.
2. Sequential execution for conflicting goals. Pipeline research/planning but serialize execution.
3. Small, focused tasks minimize conflict surface.

**Phase to address:** Pipeline pipelining phase.

**Confidence:** MEDIUM. Requires new infrastructure to track expected file modifications.

---

### Pitfall 15: LLM Context Window Overflow in Codebase Scanning

**What goes wrong:** Improvement scanner tries to feed the entire codebase to the LLM. At ~22K LOC Elixir + ~4.5K LOC JavaScript, the codebase plus prompt hits 60-80K tokens. LLM truncates or loses context, producing incomplete analysis.

**Prevention:**
1. Scan per-file or per-module, not per-codebase.
2. Prioritize by recency: scan recently modified files first (most likely to benefit).
3. Two-pass: first pass sends file names/sizes/dates for triage; second pass sends only flagged files.

**Phase to address:** Improvement scanning phase.

**Confidence:** HIGH. At 22K LOC, this is already a constraint.

---

### Pitfall 16: Hub FSM Timer Drift in Resting State

**What goes wrong:** Hub FSM enters Resting with `Process.send_after` timer. Under BEAM load, timer message is delayed. Over many cycles, drift accumulates and effective work rate drops.

**Prevention:**
1. Monotonic time for scheduling: `System.monotonic_time(:millisecond)`.
2. Track expected vs. actual wake time. Alert if drift exceeds 10%.
3. Do not compound timers -- schedule from current time, not expected previous end.

**Phase to address:** Hub FSM core phase.

**Confidence:** LOW. Unlikely at current scale (5 agents, single BEAM node).

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation | Severity |
|---|---|---|---|
| **Hub FSM Core** | State corruption from concurrent events (P3) | Use `gen_statem` or implement comprehensive timer cancellation | Critical |
| **Hub FSM Core** | Supervisor tree ordering (P6) | Place after Scheduler, `restart: :transient`, defensive init | Moderate |
| **Hub FSM Core** | Timer drift (P16) | Monotonic time, drift tracking | Minor |
| **Hub FSM Core** | Cost spiral before controls exist (P1) | CostLedger GenServer must exist before first API call | Critical |
| **Goal Backlog** | DETS table not registered with backup (P7) | Single table with namespaced keys, update DetsBackup | Moderate |
| **Goal Decomposition** | Hallucinated tasks (P5) | Ground in file tree, post-decomposition validation | Critical |
| **Goal Decomposition** | Over-decomposition (P12) | Min task size heuristic, prompt guidance | Minor |
| **Goal Decomposition** | Scheduler starvation from volume (P11) | Source field, priority boost, reserved capacity | Moderate |
| **Goal Completion** | False positive verification (P8) | Mechanical criteria required, two-judge verification | Moderate |
| **Improvement Scanning** | Infinite loop / Sisyphus pattern (P2) | Cooldown, dedup, net-value gate, anti-oscillation | Critical |
| **Improvement Scanning** | Bikeshedding (P9) | Category priority, min impact threshold, prompt engineering | Moderate |
| **Improvement Scanning** | Context window overflow (P15) | Per-module scanning, metadata triage | Minor |
| **Tiered Autonomy** | Auto-merge regressions (P4) | Integration branch, size gating, canary period, start PR-only | Critical |
| **Pipeline Pipelining** | Branch conflicts (P14) | File-level locking, sequential for overlapping goals | Moderate |
| **Contemplation** | Vaporware proposals (P13) | Scope constraints, feasibility check, rate limit | Minor |
| **Pre-publication** | Git history breaking (P10) | Fork-based scrub, coordinated agent pause | Moderate |
| **Cost Control (all)** | Token cost spiral (P1) | CostLedger, per-state budgets, tiered model usage | Critical |

---

## Integration Pitfalls Specific to Existing Architecture

These arise specifically from how the Hub FSM integrates with existing AgentCom components.

### Existing AgentFSM vs. Hub FSM Naming Confusion

The codebase already has `AgentFSM` (per-agent state machine, `lib/agent_com/agent_fsm.ex`). Adding a `HubFSM` creates ambiguity. The Hub FSM is a singleton orchestrator; the Agent FSM is per-connection. Name the module clearly: `AgentCom.HubBrain` or `AgentCom.Autonomy` rather than `AgentCom.HubFSM` to avoid confusion.

### PubSub Topic Management

The system already uses 6+ PubSub topics: "tasks", "presence", "llm_registry", "messages", "backups", "repo_registry". The Hub FSM needs its own topic for state changes and goal events. Keep it to one topic: `"hub_brain"`. Do not create per-state or per-goal topics.

### DETS Auto-Save Timing

Existing tables use `auto_save: 5_000` (5 seconds). Hub FSM state changes may occur faster. Use explicit `:dets.sync/1` after critical changes (goal completion, improvement acceptance) as `persist_task/2` does in `task_queue.ex`.

### Rate Limiter Interaction

The Hub FSM submits tasks to TaskQueue on behalf of itself. The existing `RateLimiter` is per-agent-id. If Hub uses a pseudo-agent-id (e.g., "hub-brain"), it could trigger rate limiting. Either exempt hub submissions or configure generous limits for the hub's pseudo-agent-id.

### Alerter Configuration

The Alerter has 5 configured rules. Hub FSM needs new rules: high API spend, stuck state, excessive task generation. Add without disrupting existing rules. The Alerter supports dynamic addition.

### Existing Sidecar Compatibility

The Hub FSM generates tasks that flow through the existing pipeline to sidecars. Sidecars do not need to know about the Hub FSM -- tasks look the same to them. However, if hub-generated tasks have different `metadata` shapes (e.g., `metadata.source: "hub_improvement"`), the sidecar's `handleTaskAssign` must handle this gracefully. New metadata fields nested inside the existing `metadata` map are safe (JavaScript ignores unknown properties).

### Dashboard Impact

The existing dashboard (`dashboard.ex`, `dashboard_state.ex`, `dashboard_socket.ex`) shows task queue, agent states, and system health. The Hub FSM adds a new dimension: hub state, goal progress, improvement history, cost tracking. This is new dashboard UI, but it should use the existing WebSocket push pattern (`DashboardNotifier`) rather than adding a new transport.

---

## Sources

- [Preventing Infinite Loops and Cost Spirals in Autonomous Agent Deployments](https://codieshub.com/for-ai/prevent-agent-loops-costs)
- [LLM-based Agents Suffer from Hallucinations: A Survey](https://arxiv.org/html/2509.18970v1)
- [Why Do Multi-Agent LLM Systems Fail (Galileo)](https://galileo.ai/blog/multi-agent-llm-systems-fail)
- [Why Do Multi-Agent LLM Systems Fail (arXiv)](https://arxiv.org/html/2503.13657v1)
- [From ReAct to Ralph Loop: Continuous Iteration for AI Agents](https://www.alibabacloud.com/blog/from-react-to-ralph-loop-a-continuous-iteration-paradigm-for-ai-agents_602799)
- [Ralph Loops in Software Engineering (LinearB)](https://linearb.io/blog/ralph-loop-agentic-engineering-geoffrey-huntley)
- [Everything is a Ralph Loop (ghuntley)](https://ghuntley.com/loop/)
- [Ralph Loop Agent (Vercel Labs)](https://github.com/vercel-labs/ralph-loop-agent)
- [The Agentic Recursive Deadlock: LLM Orchestration Collapses](https://tech-champion.com/artificial-intelligence/the-agentic-recursive-deadlock-llm-orchestration-collapses/)
- [Agentic AI Pitfalls: Loops, Hallucinations, Ethical Failures & Fixes](https://medium.com/@amitkharche/agentic-ai-pitfalls-loops-hallucinations-ethical-failures-fixes-77bd97805f9f)
- [Self-Modifying AI Risks (ISACA)](https://www.isaca.org/resources/news-and-trends/isaca-now-blog/2025/unseen-unchecked-unraveling-inside-the-risky-code-of-self-modifying-ai)
- [LLM Task Decomposition Strategies](https://apxml.com/courses/agentic-llm-memory-architectures/chapter-4-complex-planning-tool-integration/task-decomposition-strategies)
- [Systematic Decomposition of Complex LLM Tasks (arXiv)](https://arxiv.org/html/2510.07772v1)
- [How Task Decomposition Makes AI More Affordable (Amazon Science)](https://www.amazon.science/blog/how-task-decomposition-and-smaller-llms-can-make-ai-more-affordable)
- [Scrubbing Secrets with Gitleaks and git filter-repo](https://medium.com/@sreejithv13055/scrubbing-secrets-a-practical-poc-using-gitleaks-and-git-filter-repo-08c64b8d246c)
- [git-filter-repo Documentation](https://www.mankier.com/1/git-filter-repo)
- [State Timeouts with gen_statem (DockYard)](https://dockyard.com/blog/2020/01/31/state-timeouts-with-gen_statem)
- [GenStateMachine Elixir Wrapper](https://hexdocs.pm/gen_state_machine/GenStateMachine.html)
- [GitLab AI Merge Agent](https://www.webpronews.com/gitlabs-ai-merge-agent-automating-chaos-in-code-merges/)
- [Claude API Pricing 2026](https://www.metacto.com/blogs/anthropic-api-pricing-a-full-breakdown-of-costs-and-integration)
- [Taming AI Agents: The Autonomous Workforce of 2026 (CIO)](https://www.cio.com/article/4064998/taming-ai-agents-the-autonomous-workforce-of-2026.html)

---
*Pitfalls research for: v1.3 Hub FSM Loop of Self-Improvement*
*Researched: 2026-02-12*
