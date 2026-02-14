# Requirements: AgentCom v1.4

**Defined:** 2026-02-14
**Core Value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.

## v1.4 Requirements

Requirements for Reliable Autonomy milestone. Each maps to roadmap phases.

### Agentic Execution

- [ ] **AGENT-01**: Sidecar has a tool definition registry with 5 core tools (read_file, write_file, list_directory, run_command, search_files) in Ollama function-calling format
- [ ] **AGENT-02**: Sidecar tool executor runs tool calls within workspace sandbox (path validation, blocked commands, per-tool timeout)
- [ ] **AGENT-03**: OllamaExecutor implements ReAct loop -- multi-turn conversation with tool calls, tool results, and loop until final answer or limit
- [ ] **AGENT-04**: ReAct loop has external safety guardrails: max iteration limit, repetition detection, token budget check, wall-clock timeout
- [ ] **AGENT-05**: Structured output parser handles native tool_calls field, JSON extraction from content, and XML extraction (Qwen3 >5 tool fallback)
- [ ] **AGENT-06**: Tools return structured observations (JSON with typed fields) rather than raw text, so smaller models parse results reliably
- [ ] **AGENT-07**: Tool call events stream to dashboard in real-time via existing WebSocket progress events (tool name, args summary, result summary per call)
- [ ] **AGENT-08**: Iteration limits adapt per task complexity tier (trivial: 5, standard: 10, complex: 20)
- [ ] **AGENT-09**: Partial results preserved on timeout or budget exhaustion -- verification runs on current state, partial_pass reported with completed vs remaining work
- [ ] **AGENT-10**: Agentic system prompt instructs LLM on available tools, workspace context, and step-by-step task completion patterns

### Hub FSM Healing

- [ ] **HEAL-01**: Hub FSM has 5th state :healing with transitions from any state to :healing and :healing to :resting
- [ ] **HEAL-02**: HealthAggregator module unifies health signals from Alerter, MetricsCollector, LLM Registry, and AgentFSM into structured health report
- [ ] **HEAL-03**: FSM transitions to :healing when critical issues detected (stuck tasks, offline agents, unhealthy endpoints) with cooldown to prevent oscillation
- [ ] **HEAL-04**: Healing remediates stuck tasks: requeue if agent offline, extend deadline if agent responsive but slow, dead-letter after 3 retries
- [ ] **HEAL-05**: Healing attempts Ollama endpoint recovery: retry health checks with backoff, execute configured restart commands, fall back to Claude routing
- [ ] **HEAL-06**: Healing detects and fixes CI/compilation failures: identify merge conflicts, run mix compile, report actionable diagnostics
- [ ] **HEAL-07**: Healing state has 5-minute watchdog -- if remediation incomplete, force-transition to :resting and fire critical alert
- [ ] **HEAL-08**: All healing actions logged to healing history with timestamps, context, and outcomes for auditability

### Hub LLM Routing

- [ ] **ROUTE-01**: OllamaClient HTTP module in Elixir wraps Ollama /api/chat with streaming, tool support, and error handling
- [ ] **ROUTE-02**: Hub FSM LLM operations (goal decomposition, improvement scanning, contemplation) route through OllamaClient instead of claude -p CLI
- [ ] **ROUTE-03**: All `claude -p` / ClaudeClient.Cli invocations removed from production code paths
- [ ] **ROUTE-04**: Prompts adapted for Qwen3 8B -- explicit step-by-step instructions, structured output format, appropriate context windowing

### Pipeline Reliability

- [ ] **PIPE-01**: Wake failure recovery: sidecar reports wake success/failure within 10s, hub requeues on no-ack
- [ ] **PIPE-02**: Task-level timeout wraps entire execution (including verification retries) with configurable deadline (30min agentic, 10min simple)
- [ ] **PIPE-03**: Stuck task detection and automatic requeue with retry counter and dead-letter after max retries
- [ ] **PIPE-04**: Idempotent requeue with assignment_generation counter -- sidecar checks generation before executing, hub checks before accepting results
- [ ] **PIPE-05**: Sidecar reconnect with state recovery -- reports current state on reconnect, hub reconciles (continue waiting, accept late result, or requeue)
- [ ] **PIPE-06**: Budget check per agentic iteration (not just task start) -- save partial progress on exhaustion with clear status
- [ ] **PIPE-07**: No-wake-command fail-fast: if wake_command not configured, immediately fail task instead of silently hanging in 'working' state

### Agent Self-Management

- [ ] **PM2-01**: Sidecar is aware of its own pm2 process name and can query its own status
- [ ] **PM2-02**: Sidecar can restart itself via pm2 (graceful shutdown, pm2 auto-restarts)
- [ ] **PM2-03**: Hub can command a sidecar to restart via WebSocket message, sidecar executes graceful pm2 restart

### Hub FSM Testing

- [ ] **TEST-01**: Integration tests cover full FSM cycles (resting -> executing -> resting, resting -> improving -> contemplating -> resting)
- [ ] **TEST-02**: Integration tests cover healing state (trigger healing, verify remediation, verify exit to resting)
- [ ] **TEST-03**: HTTP endpoint tests for /api/hub/pause, /api/hub/resume, /api/hub/state, /api/hub/history
- [ ] **TEST-04**: Watchdog timeout test verifies forced transition after timeout expires

### CI Fix

- [ ] **CI-01**: Remote main has no unresolved merge conflict markers -- all local fixes pushed
- [ ] **CI-02**: `mix compile --warnings-as-errors` passes in CI
- [ ] **CI-03**: `mix test --exclude skip --exclude smoke` passes in CI

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Advanced Agentic

- **AGENT-V2-01**: LLM output format auto-correction for malformed tool calls (JSON syntax fix, markdown extraction)
- **AGENT-V2-02**: Healing playbook system -- configurable condition-action pairs in DETS instead of hardcoded remediation
- **AGENT-V2-03**: Multi-model tool calling -- different models for different tool-call phases (cheap model for file reads, capable model for code generation)

### Advanced Reliability

- **PIPE-V2-01**: Distributed sidecar health monitoring -- sidecars monitor each other, report peer failures to hub
- **PIPE-V2-02**: Task result deduplication across reconnects -- content-hash based, not just generation counter

## Out of Scope

| Feature | Reason |
|---------|--------|
| Multi-agent tool collaboration | Race conditions on shared workspace; one agent per task per workspace |
| LLM-generated tool definitions | Security risk; fixed tool registry defined in code |
| Autonomous Ollama model pulling | Large downloads could fill disk; human pulls models |
| Healing self-healing (recursive) | Infinite recursion risk; watchdog + OTP supervisor handles crashes |
| Tool call caching/memoization | Stale data bugs after file writes; fresh reads are cheap |
| Custom tool protocols (MCP/A2A) | Protocol overhead for zero benefit when we control both sides |
| Distributed healing consensus | One hub, one decision-maker; no multi-hub to coordinate |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| (To be filled by roadmapper) | | |

**Coverage:**
- v1.4 requirements: 30 total
- Mapped to phases: 0
- Unmapped: 30

---
*Requirements defined: 2026-02-14*
*Last updated: 2026-02-14 after initial definition*
