# Project Research Summary

**Project:** AgentCom v1.2 — Smart Agent Pipeline (Milestone 2)
**Domain:** Distributed multi-model LLM inference routing with enriched task orchestration and agent self-verification
**Researched:** 2026-02-12
**Confidence:** HIGH

## Executive Summary

AgentCom v1.2 transforms a proven task coordination system into a cost-efficient, model-aware orchestration platform. The core insight from research: most agent work (60-70%) doesn't need expensive cloud LLMs. By routing tasks through a three-tier complexity model (trivial/simple/complex) to appropriate execution backends (sidecar direct/local Ollama/cloud Claude), the system can achieve 85% cost reduction while maintaining quality through deterministic verification.

The recommended approach builds on the battle-tested v1.1 architecture (22 supervision tree components, 9 DETS tables, proven scheduler) by adding four new components: an LLM endpoint registry (GenServer tracking Ollama instances across the Tailscale mesh), a complexity classifier (pure function module), enriched task format (additive schema evolution), and sidecar model routing (strategy dispatch). All changes are designed as additive extensions — existing v1.0/v1.1 tasks continue working unchanged while new tasks leverage enrichment fields.

The primary risk is breaking the proven scheduler and task pipeline through invasive changes. Research identifies the critical mitigation strategy: keep the scheduler stateless and push routing complexity to the edges (pre-enrichment or sidecar-side). The second major risk — LLM self-assessment hallucinating success — is mitigated by prioritizing deterministic mechanical verification (tests pass, code compiles, files exist) over LLM judgment. Start conservative (default to strongest model) and demote to cheaper models only with explicit confidence.

## Key Findings

### Recommended Stack

**Core approach:** Minimal new dependencies. Two runtime additions (Req for hub-side Ollama HTTP calls, ollama npm for sidecar-side inference), plus four custom components built on existing BEAM/Node.js infrastructure.

**Core technologies:**
- **Req ~> 0.5.0** (Elixir): Batteries-included HTTP client for Ollama API calls — streaming support, automatic JSON decode, retries, connection pooling via Finch. Community standard, likely becoming Phoenix default.
- **ollama npm ^0.6.3** (Node.js): Official Ollama JavaScript library for sidecar model invocation — exposes chat(), generate(), list(), ps() methods with structured JSON output support.
- **Ollama 0.15.x + Qwen3 8B** (Infrastructure): Local LLM inference on each Tailscale machine. Q4_K_M quantization fits in 12GB VRAM (~6-7GB actual). Handles tier 1-2 tasks (trivial and standard complexity).
- **Custom OllamaPool** (Elixir GenServer ~250 lines): Multi-host endpoint registry with periodic health checks, model inventory tracking, VRAM status monitoring, circuit-breaker semantics.
- **Custom ComplexityClassifier** (Elixir module ~80 lines): Task complexity classification (trivial/standard/complex) from metadata. Domain-specific logic for AgentCom's 3-tier model.

**Critical stack decision:** Use Req directly rather than the ollama hex package (v0.9.0, last updated Sep 2025). The wrapper hasn't tracked Ollama's rapid evolution (server went 0.3.x → 0.15.6), and we need custom health-check polling and multi-host pool management beyond its single-client model. Direct Req usage gives full control over endpoints with zero risk of wrapper staleness.

**What NOT to add:** ex_json_schema (extend existing validation instead), LangChain (framework overhead for simple prompt-response), vLLM/TGI (complex GPU infrastructure for 5-agent system), Redis (Phoenix.PubSub handles all event distribution at this scale).

### Expected Features

**Must have (table stakes):**
- **LLM endpoint registry** — Cannot route to endpoints you don't know about. Track Ollama hosts across Tailscale mesh with health checking.
- **Enriched task format** — Tasks need structured context (repo, branch, files), success criteria (testable conditions), and verification steps. Agents need to know what "done" means.
- **Complexity classification** — Tag tasks as trivial/standard/complex to determine routing path. Explicit submitter tagging first, keyword heuristics later.
- **Model-aware scheduler routing** — Core value proposition. Extend capability matching to include complexity tier: trivial → sidecar direct, standard → Ollama-backed agents, complex → Claude-backed agents.
- **Sidecar LLM backend routing** — Sidecar calls correct LLM backend based on task assignment (local Ollama or Claude API). Currently all tasks wake OpenClaw uniformly.
- **Sidecar trivial execution** — 60-70% of operations are mechanical (git status, file writes). Execute locally, report result, zero LLM tokens consumed.
- **Task result with verification report** — Output complement to enriched tasks. Include what was verified and pass/fail per check.

**Should have (competitive differentiators):**
- **Agent self-verification loop** — After completing work, agent runs verification steps (tests, file checks, grep assertions) before submitting. Industry evidence (Vercel agent-browser, Anthropic evals guidance) shows this dramatically improves success rates. The "build-verify-fix" pattern.
- **Complexity heuristic engine** — Infer complexity from task content instead of requiring manual tagging. Keyword-based (zero tokens, CPU only), applied as default when submitter doesn't specify.
- **Multi-host load balancing** — When multiple Ollama hosts have the same model, distribute by current load. Prevents GPU saturation while others idle.
- **Cost tracking per task** — Track which model handled each task, tokens consumed, estimated cost. Enables answering "how much did we save?"

**Defer to v2+:**
- LLM-based complexity classifier (chicken-and-egg: burns tokens to save tokens)
- Dynamic model loading/unloading (operational complexity, should be pre-loaded)
- Cross-agent task dependencies (DAG scheduling — much larger system)
- Streaming LLM output through hub (adds latency for zero coordination value)

### Architecture Approach

Build on proven v1.1 foundation through additive extensions, not rewrites. The enriched task format uses optional fields with nil/empty defaults (backward compatible with existing DETS data). The LLM registry is a new GenServer added to the supervision tree AFTER Config, BEFORE Scheduler. Model routing happens hub-side (scheduler enriches tasks with assigned_model and assigned_endpoint), and the sidecar executes those routing decisions (strategy dispatch pattern).

**Major components:**

1. **AgentCom.LlmRegistry** (NEW GenServer) — Tracks Ollama instances across Tailscale mesh. Periodic health checking (GET /api/ps for model state, not just GET / for process state). Model discovery. DETS persistence for registrations, ETS cache for health state. Broadcasts endpoint status changes via PubSub.

2. **AgentCom.ComplexityClassifier** (NEW library module) — Pure function classification: :trivial | :simple | :complex | :explicit_model. Priority chain: explicit metadata > pattern match on description > safe default (complex). NOT an LLM classifier — heuristics are transparent, debuggable, and tunable via Config.

3. **TaskQueue (MODIFIED)** — Extend task struct with 8 new optional fields: context, criteria, verification_steps, complexity, assigned_model, assigned_endpoint, model_override, verification_result. All additive with nil defaults. No DETS migration needed — Map.get(task, :context, nil) pattern handles missing fields gracefully.

4. **Scheduler (MODIFIED)** — ComplexityClassifier.classify/1 call during task submission. LlmRegistry query for model endpoints during assignment. Extended do_assign payload includes model routing fields. Model-aware matching extends capability subset matching with complexity tier filtering.

5. **Sidecar model-router.js (NEW)** — Strategy dispatch: routeTask() returns {strategy: 'trivial' | 'local_llm' | 'cloud_llm' | 'wake_default', config: {...}}. Hub decides routing, sidecar executes strategy.

6. **Sidecar verification.js (NEW)** — Deterministic verification (shell commands with exit codes), not LLM self-assessment. Mechanical checks: file exists, tests pass, no syntax errors. Gate (pass/fail), not feedback loop — failures trigger hub's existing retry logic.

**Critical architecture principle:** Hub decides, sidecar executes. All routing decisions happen in the hub (LlmRegistry state, ComplexityClassifier logic, model selection in Scheduler). The sidecar receives explicit instructions (assigned_model, assigned_endpoint) and executes them. This avoids split-brain scenarios and keeps the sidecar as a thin relay.

### Critical Pitfalls

1. **Enriching task format breaks the entire existing pipeline** — Task map is untyped; every layer (TaskQueue, Scheduler, Socket, sidecar) destructures independently. Prevention: Define enrichment fields as OPTIONAL with sane defaults. Carry enrichment data INSIDE existing metadata map for sidecar transport (metadata.enrichment.*) to avoid new top-level WebSocket fields. Add task_version field. Write one-time migration for DETS backfill.

2. **Complexity classification overfits to keyword heuristics** — "Rename" appears in both trivial and complex tasks. Research confirms this is the dominant LLM routing failure mode. Prevention: Start with WHITELIST approach (explicit trivial operations by type, not description parsing). Default to expensive but correct (Claude), demote to local only when explicitly flagged or whitelisted. Defer ML-based classification until 50+ completed tasks provide training data.

3. **Ollama model cold start makes health checks unreliable** — Health check says "green" but model unloaded (5-minute keep_alive default). First request triggers 10-120 second load. Prevention: Use GET /api/ps (currently loaded models) not GET /api/tags (downloaded models). Implement "warm" check (model loaded AND expiration > 60s away). Send periodic keep-alive to critical endpoints. Set OLLAMA_KEEP_ALIVE=-1 on dedicated inference hosts.

4. **Self-verification is LLM judging its own work** — Model that confidently generated wrong code will confidently verify it as correct. Prevention: Ground truth verification FIRST (mechanical checks: compile, tests, file existence), LLM verification SECOND. Use DIFFERENT model for verification than generation when possible. Require structured JSON output with confidence levels. Log verification decisions for calibration feedback loop.

5. **Touching the scheduler breaks the battle-tested assignment loop** — Current scheduler is 100 lines of stateless, proven-correct capability matching. Adding model routing means external state dependencies (endpoint registry queries mid-loop). Prevention: Keep existing match loop UNTOUCHED. Add model routing as SEPARATE step that runs AFTER basic capability match. Wrap new logic in try/rescue with fallback to existing simple matching. Never let classification failure block assignment.

## Implications for Roadmap

Based on research, a dependency-constrained 7-phase structure emerges:

### Phase 1: Enriched Task Format
**Rationale:** Foundation for everything. Every other feature (routing, verification, model assignment) reads from enrichment fields. Must be first.

**Delivers:** Extended TaskQueue schema, endpoint validation, socket pass-through, validation schemas. ComplexityClassifier module (pure functions, independently testable).

**Addresses:** Task format enrichment from FEATURES.md (table stakes), enables context/criteria/verification infrastructure.

**Avoids:** Pitfall 1 (pipeline breakage) through optional fields with defaults, metadata transport pattern, task_version field.

**Research flag:** SKIP — standard schema evolution pattern, well-documented in existing codebase (TASK-05 generation fencing shows the pattern).

### Phase 2: LLM Endpoint Registry
**Rationale:** Routing decisions need endpoint data. Must exist before scheduler queries it. Independent of enriched task format (can build in parallel with Phase 1).

**Delivers:** LlmRegistry GenServer with DETS persistence, ETS cache, health checking, model discovery. Admin HTTP endpoints. DetsBackup integration. Telemetry events.

**Uses:** Req HTTP client from STACK.md for Ollama API calls. Follows existing GenServer patterns (TaskQueue, Config, Presence).

**Avoids:** Pitfall 3 (cold start unreliability) by using /api/ps not /api/tags, warm checks. Pitfall 9 (synchronous health checks block GenServer) through async Task + ETS cache. Pitfall 11 (9th DETS table) — consider config file + ETS instead.

**Research flag:** MEDIUM — Ollama API well-documented, but health check timing and Tailscale mesh latency need validation. Suggest targeted research for optimal health check intervals and timeout values.

### Phase 3: Model-Aware Scheduler
**Rationale:** Integration point. Wires ComplexityClassifier + LlmRegistry into scheduler assignment flow. Depends on Phase 1 (task enrichment) and Phase 2 (endpoint registry).

**Delivers:** Scheduler modifications (classify + route + assign). Extended do_assign payload with model routing fields. Model-aware matching that extends capability subset matching with complexity tier filtering.

**Implements:** Core model-aware routing architecture from ARCHITECTURE.md. Scheduler queries LlmRegistry for healthy endpoints, enriches tasks with assigned_model/assigned_endpoint.

**Avoids:** Pitfall 2 (overfitting classifier) by defaulting to strongest model, explicit hints only. Pitfall 5 (breaking match loop) by adding routing as pre-enrichment step, NOT inside core match loop.

**Research flag:** SKIP — extends proven scheduler patterns (do_match_loop capability matching, do_assign enrichment). No new domain concepts.

### Phase 4: Sidecar Model Routing
**Rationale:** Agent-side complement to hub-side routing. Consumes hub routing decisions. Depends on Phase 1 (enriched task format arrives at sidecar) and Phase 3 (hub sends routing fields).

**Delivers:** model-router.js (strategy dispatch), wake.js interpolation variables, index.js handleTaskAssign branching, config.json schema extension.

**Addresses:** Sidecar LLM backend routing from FEATURES.md (table stakes). Strategy pattern makes trivial/local/cloud/default paths independently testable.

**Avoids:** Pitfall 7 (sidecar complexity explosion) — decompose FIRST (create lib/model-router.js, lib/llm-client.js) before adding features. Pitfall 8 (Ollama streaming gotchas) — start with stream: false, three-tier timeouts. Pitfall 10 (protocol version mismatch) — bump protocol_version to 2, feature detection in capabilities.

**Research flag:** HIGH — Ollama streaming behavior, Claude API integration, timeout tuning all need validation. Suggest targeted research: "Ollama API integration patterns for Node.js" covering streaming, timeouts, model loading delays.

### Phase 5: Sidecar Trivial Execution
**Rationale:** Specialization of model routing. Zero-LLM-token path for mechanical operations. Depends on Phase 4 (model router dispatches to trivial strategy).

**Delivers:** trivial-executor.js module, wire into model-router 'trivial' strategy. Security: allowlist of permitted commands, working directory constraints.

**Addresses:** Sidecar trivial execution from FEATURES.md (table stakes). Enables cost savings on 60-70% of typical operations (git status, file writes).

**Avoids:** Pitfall 13 (separate code path divergence) — implement as "null model" in routing framework, unified result format.

**Research flag:** SKIP — execCommand() already exists in wake.js. This extends existing exec infrastructure with allowlist pattern.

### Phase 6: Verification Infrastructure
**Rationale:** Can build in parallel with Phases 2-5 since it only touches completion path (handleResult), not assignment path. Depends on Phase 1 (task has verification_steps field).

**Delivers:** verification.js module, wire into index.js handleResult, extend task_complete with verification_result.

**Implements:** Verification step library from FEATURES.md (differentiator). Deterministic checks: file_exists, test_passes, git_clean, command_succeeds.

**Avoids:** Pitfall 4 (LLM judging own work) — mechanical checks FIRST (shell exit codes), LLM judgment SECOND (different model). Pitfall 12 (verification extends task beyond sweep threshold) — send task_progress during verification.

**Research flag:** SKIP — verification is deterministic shell commands. Existing execCommand() infrastructure handles execution.

### Phase 7: Self-Verification Loop (Optional Enhancement)
**Rationale:** Highest complexity, most dependencies. Requires all other pieces working end-to-end. Can be deferred to post-launch if needed.

**Delivers:** Build-verify-fix pattern in sidecar. After task completion, run verification steps. If verification fails AND attempts < max_verification_attempts, feed failure back to LLM for corrections.

**Addresses:** Agent self-verification loop from FEATURES.md (competitive differentiator). Industry evidence (Vercel, Anthropic) shows dramatic success rate improvement.

**Avoids:** Pitfall 4 (false confidence from self-assessment) through mechanical-first verification pipeline with explicit confidence thresholds.

**Research flag:** HIGH — self-verification feedback loop patterns, retry budgets, verification-aware prompting all need deeper investigation. Suggest targeted research: "Agent self-verification and build-verify-fix patterns in 2025-2026."

### Phase Ordering Rationale

**Critical path:** Enriched Task Format → LLM Registry → Model-Aware Routing → Sidecar Backend Routing → Trivial Execution → Verification Infrastructure → Self-Verification Loop

**Why this order:**
1. Task enrichment first: every other feature reads from these fields. Nothing works without the data model.
2. Endpoint registry second: routing decisions need endpoint availability data. Can build parallel to Phase 1.
3. Scheduler routing third: the integration point that wires classifier + registry into assignment flow.
4. Sidecar routing fourth: the agent-side complement that executes hub routing decisions.
5. Trivial execution fifth: specialization of sidecar routing for zero-token path.
6. Verification infrastructure sixth: only touches completion path, can build parallel to Phases 2-5.
7. Self-verification last: requires entire pipeline working end-to-end, highest complexity, most dependencies.

**Grouping rationale:**
- Phases 1-3 are hub-side foundation (data model, registry, routing logic)
- Phases 4-5 are sidecar-side execution (routing strategies, trivial path)
- Phases 6-7 are quality infrastructure (verification, self-correction)

**Pitfall avoidance:**
- Enrichment before routing prevents data dependency failures
- Registry before scheduler prevents routing without endpoint data
- Decomposition (Phase 4) before feature additions prevents complexity explosion
- Mechanical verification (Phase 6) before self-assessment (Phase 7) prevents false confidence

### Research Flags

**Needs deeper research:**
- **Phase 2 (LLM Endpoint Registry):** Optimal health check intervals, Tailscale mesh latency characteristics, Ollama cold start timing. Pattern is established (existing GenServers with health checks), but timing parameters need validation.
- **Phase 4 (Sidecar Model Routing):** Ollama streaming behavior, Claude API rate limits and error handling, timeout tuning for model loading vs. inference. Multiple integration points with external APIs.
- **Phase 7 (Self-Verification Loop):** Verification-aware prompting techniques, retry budget strategies, feedback loop termination conditions. Emerging pattern (2025-2026 research) with evolving best practices.

**Standard patterns (skip research):**
- **Phase 1 (Enriched Task Format):** Schema evolution is well-documented in existing codebase. TASK-05 generation fencing shows the pattern.
- **Phase 3 (Model-Aware Scheduler):** Extends existing scheduler patterns (capability matching, do_assign enrichment). No new domain concepts.
- **Phase 5 (Sidecar Trivial Execution):** Extends existing wake.js execCommand() infrastructure with allowlist pattern.
- **Phase 6 (Verification Infrastructure):** Deterministic shell commands using existing exec infrastructure.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Req and ollama npm verified via official docs and npm/GitHub. Ollama API extensively documented with GitHub issues covering edge cases. Two runtime dependencies with clear rationale. |
| Features | HIGH | Codebase analysis confirms existing patterns. Table stakes features (registry, enrichment, routing) are architectural necessities. Differentiators (self-verification, heuristics) grounded in industry research (RouteLLM, Anthropic evals). |
| Architecture | HIGH | Builds on proven v1.1 architecture (22 supervision tree components, 9 DETS tables, battle-tested scheduler). All changes additive — optional fields, new GenServer, strategy dispatch. Critical principle (hub decides, sidecar executes) prevents split-brain. |
| Pitfalls | HIGH | Top 5 critical pitfalls confirmed by direct codebase analysis (scheduler.ex do_match_loop, task_queue.ex submit, socket.ex destructuring) plus external research (RouterEval on heuristic overfitting, Ollama issues on cold start, LLM hallucination surveys on self-assessment). |

**Overall confidence:** HIGH

The recommended stack is minimal (2 runtime additions), the architecture is additive (backward compatible), the phase structure respects dependencies, and the critical pitfalls have concrete prevention strategies. Research draws from authoritative sources: official Ollama API docs, Anthropic engineering guides, peer-reviewed routing evaluation papers, and direct analysis of the proven v1.1 codebase.

### Gaps to Address

**Ollama cold start timing:** Research confirms the 5-minute keep_alive default and documents model loading delays, but actual timing on the target hardware (RTX 3080 Ti 12GB with Qwen3 8B Q4_K_M) needs empirical measurement. Suggest: benchmark model load times during Phase 2 implementation to calibrate timeout values.

**Tailscale mesh latency:** Documented ranges (1-5ms direct, 50-200ms via DERP relay), but actual performance depends on network topology. Health check intervals and timeout values should be tuned based on observed latency. Suggest: measure Tailscale ping times between hub and Ollama hosts during Phase 2.

**Verification step timeout budgets:** Research establishes the pattern (mechanical checks before LLM judgment), but specific timeout values for compilation, test execution, and verification loops need tuning. Suggest: start with conservative defaults (180s model load, 60s generation, 30s per verification step) and adjust based on telemetry during Phase 6.

**Self-verification feedback loop termination:** Anthropic evals guidance documents the pattern, but optimal retry budgets (max_verification_attempts) and failure modes (verification timeout, retry exhaustion) need validation. Suggest: defer Phase 7 to post-launch, collect verification data from Phase 6 mechanical checks to calibrate retry strategy.

## Sources

### Primary (HIGH confidence)
- AgentCom v1.1 shipped codebase — all source files in lib/agent_com/ and sidecar/ (direct analysis, 2026-02-12)
- [Req v0.5.17 on Hex](https://hex.pm/packages/req) — version, dependencies, release date Jan 2026
- [Req documentation](https://hexdocs.pm/req/Req.html) — streaming, retry, JSON support, Finch pool config
- [ollama npm v0.6.3](https://www.npmjs.com/package/ollama) — version, 412 dependents
- [ollama-js GitHub README](https://github.com/ollama/ollama-js) — API methods, host config, format parameter
- [Ollama API docs on GitHub](https://github.com/ollama/ollama/blob/main/docs/api.md) — all endpoints, /api/ps response fields including size_vram
- [Ollama releases](https://github.com/ollama/ollama/releases) — v0.15.6 current as of Feb 7, 2026
- [Ollama FAQ](https://docs.ollama.com/faq) — keep_alive default, parallel request memory multiplication
- [Anthropic: Effective Context Engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) — task context structure, minimal high-signal tokens
- [Anthropic: Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) — success criteria, deterministic vs LLM graders

### Secondary (MEDIUM confidence)
- [RouteLLM (LMSYS)](https://lmsys.org/blog/2024-07-01-routellm/) — open-source complexity-based routing, 85% cost reduction
- [RouterEval benchmark paper](https://aclanthology.org/2025.findings-emnlp.208.pdf) — heuristic overfitting failure mode
- [When Routing Collapses: Degenerate Convergence](https://arxiv.org/html/2602.03478) — routing collapse analysis
- [LLM routing in production (LogRocket)](https://blog.logrocket.com/llm-routing-right-model-for-requests) — heuristic classification, cascade fallback
- [LLM Agent Hallucination Survey (2025)](https://arxiv.org/html/2509.18970v1) — agent-specific hallucination taxonomy
- [Ollama GitHub issue #4350](https://github.com/ollama/ollama/issues/4350) — model loading timeout
- [Ollama GitHub issue #7685](https://github.com/ollama/ollama/issues/7685) — streaming timeout behind gateway
- [Ollama GitHub issue #9084](https://github.com/ollama/ollama/issues/9084) — tools breaking streaming

### Tertiary (LOW confidence)
- [IBM LLM Router cost savings](https://sourceforge.net/software/llm-routers/) — 85% cost reduction claim (cited in multiple sources but unverified primary)
- [Agents At Work: 2026 Playbook](https://promptengineering.org/agents-at-work-the-2026-playbook-for-building-reliable-agentic-workflows/) — verification-aware planning patterns (community guide)

---
*Research completed: 2026-02-12*
*Ready for roadmap: yes*
