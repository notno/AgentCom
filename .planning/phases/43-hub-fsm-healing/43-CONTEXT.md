# Phase 43: Hub FSM Healing — Discussion Context

## Approach

Add a 5th state `:healing` to the Hub FSM with health aggregation, automated remediation, and watchdog protection. Follows the same async Task pattern as `:improving` and `:contemplating`.

### FSM State Addition
- Add `:healing` to `@valid_transitions`: any state → `:healing`, `:healing` → `:resting`
- Healing preempts other states — if infrastructure is broken, executing goals is pointless
- Always exits to `:resting` (not directly to executing) for clean health re-evaluation

### HealthAggregator
- New `AgentCom.HealthAggregator` module
- Polls existing health sources: Alerter (alert rules), MetricsCollector (queue depth, latency), LlmRegistry (endpoint health), AgentFSM (agent states)
- Returns structured report: `%{healthy: bool, issues: [%{source, severity, detail}], healing_cooldown_active: bool}`
- Transition predicate: `should_heal?/1` checks HealthAggregator

### Remediation Actions (in priority order)
1. **Stuck tasks** — requeue if agent offline, extend deadline if agent responsive, dead-letter after 3 retries
2. **Offline agents** — cleanup stale state, requeue their assigned tasks
3. **Ollama endpoint recovery** — retry health checks with exponential backoff (5s, 15s, 45s), execute configured restart command if available, fall back to Claude routing
4. **CI/compilation healing** — detect merge conflicts and compilation failures, delegate fixing to a capable OpenClaw agent (spawn task with high priority)
5. **Escalation** — if remediation fails, fire push notification to human

### Healing Cycle (async Task)
Same pattern as improving/contemplating:
1. Spawn `Task.async` from FSM
2. Assess health → list issues by priority
3. Execute remediation actions sequentially
4. Log all actions to healing history
5. Send `:healing_cycle_complete` message to FSM
6. FSM transitions to `:resting`

### Safety
- 5-minute watchdog: `Process.send_after(self(), :healing_watchdog, 300_000)`
- 5-minute cooldown after healing completes before allowing re-entry (prevent oscillation)
- 3-attempt limit within 10 minutes (prevent healing storms)
- Healing NEVER heals itself recursively — if healing crashes, OTP supervisor restarts the FSM

### CI/Compilation Healing (HEAL-06)
- Run `mix compile` and capture output
- Detect merge conflict markers via `git diff --check`
- If conflicts or compilation errors found: create a high-priority task in the queue for an OpenClaw agent to fix
- The OpenClaw agent gets full context (error output, file list, conflict markers)
- Hub doesn't auto-fix — it delegates to a capable agent

## Key Decisions

- **Delegate merge conflict fixing to OpenClaw agent** — not auto-fix. Hub detects, creates task, agent fixes.
- **5-minute watchdog + 5-minute cooldown + 3-attempt limit** — triple safety net against healing storms
- **Healing always exits to :resting** — clean re-evaluation before resuming work
- **Same async Task pattern** as improving/contemplating — proven pattern from v1.3

## Dependencies

- **Phase 38** — OllamaClient needed if healing uses LLM for diagnosis
- **Phase 39** — pipeline reliability fixes needed for stuck task remediation to work properly

## Files to Create/Modify

- `lib/agent_com/hub_fsm.ex` — add `:healing` state, transitions, watchdog, cooldown
- `lib/agent_com/hub_fsm/predicates.ex` — add `should_heal?/1`
- NEW: `lib/agent_com/health_aggregator.ex` — unified health signal module
- NEW: `lib/agent_com/hub_fsm/healing.ex` — remediation actions
- `lib/agent_com/dashboard.ex` — healing state in FSM visualization
- `lib/agent_com/endpoint.ex` — healing history API endpoint

## Risks

- MEDIUM — modifying FSM core is sensitive, but follows established patterns
- Healing cascade risk mitigated by triple safety net
- CI healing delegation adds task queue dependency — what if queue is also broken?

## Success Criteria

1. FSM transitions to :healing on critical issues (3+ stuck tasks, all endpoints unhealthy, compilation failure)
2. Healing requeues stuck tasks and dead-letters after 3 retries
3. Healing attempts Ollama recovery with backoff, falls back to Claude
4. Healing detects merge conflicts/compilation failures, delegates fixing to OpenClaw agent
5. 5-minute watchdog force-transitions to :resting with critical alert
