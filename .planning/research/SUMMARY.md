# Project Research Summary

**Project:** AgentCom v1.4 — Agentic Execution, Self-Healing FSM, Pipeline Reliability
**Domain:** Agentic local LLM tool calling, distributed system self-healing, pipeline reliability hardening
**Researched:** 2026-02-14
**Confidence:** HIGH

## Executive Summary

AgentCom v1.4 extends the existing Hub FSM Loop of Self-Improvement (v1.3) with three major capabilities: agentic tool-calling execution via Ollama's native function calling API, a self-healing FSM state for automated infrastructure recovery, and pipeline reliability fixes for wake failures and stuck task detection. Research confirms this milestone requires **zero new external dependencies** — all new functionality is built on the existing Milestone 2 stack (Req ~> 0.5.0 for Elixir HTTP, ollama npm ^0.6.3 for Node.js) plus custom implementations totaling approximately 880 lines of new code.

The recommended approach is a **sidecar-first agentic execution model** where local Ollama models (Qwen3 8B, Q4_K_M quantization, ~6-7GB VRAM) handle tool-calling loops for task execution, while the Hub FSM gains a 5th state (`:healing`) to detect and remediate infrastructure failures (stuck tasks, offline agents, unhealthy endpoints). Hub-side LLM operations (goal decomposition, verification) can optionally route through Ollama instead of Claude CLI, but this is a secondary optimization — the primary value is in sidecar-side agentic execution. Critical stack decision: **custom ReAct loop implementation (~350 LOC) over frameworks like LangChain** (50MB+ dependencies, imposes foreign abstractions) because the tool definitions are AgentCom-specific and must integrate with existing ShellExecutor/workspace-manager patterns.

The key risks are **agentic infinite loops** (LLM calls tools indefinitely, consuming GPU), **tool execution sandbox escapes** (LLM reads/modifies files outside task scope), and **healing cascade storms** (healing state triggers itself). These are mitigated with hard iteration caps (10 max), strict path validation (workspace-only file access), and healing cooldowns (30s minimum duration). The highest-priority reliability fix is **wake failure recovery** — an existing bug where tasks with missing wake_command hang indefinitely, blocking the entire agent. This must ship in the pipeline reliability phase.

## Key Findings

### Recommended Stack

Research confirms the v1.4 milestone requires **zero new runtime dependencies**. All new capabilities are built on the existing Milestone 2 stack plus custom implementations.

**Core technologies (already present):**
- **Req ~> 0.5.0** (Elixir): Replaces `ClaudeClient.Cli` System.cmd calls with Ollama `/api/chat` HTTP requests via Req. Supports tool-calling-formatted requests for Hub LLM operations.
- **ollama npm ^0.6.3** (Node.js): Use `chat()` with `tools` parameter for function/tool calling. Build agentic ReAct loop on top.
- **GenServer (OTP)**: Add `:healing` state to HubFSM. No new behavior needed — GenServer handles this via existing `@valid_transitions` map. Do NOT migrate to `:gen_statem`; the existing pattern is working and well-tested.
- **Node.js built-in `child_process`, `fs/promises`, `test`**: Reuse for tool-invoked shell commands, file operations, and integration tests.

**Custom implementations (no external dependency):**
- **AgenticExecutor** (sidecar, ~350 LOC): ReAct loop: send task + tools to Ollama, parse tool_calls, execute tools, feed results back, repeat until done or max iterations. Custom because: tight integration with existing ShellExecutor/OllamaExecutor patterns, AgentCom-specific tool definitions, existing `onProgress` callback, existing ExecutionResult format.
- **ToolRegistry** (sidecar, ~150 LOC): Registry of available tools with Ollama-format schemas and execution functions. Maps tool names to handlers (shell, file_read, file_write, git_status, hub_api).
- **HubLLMClient** (Elixir, ~200 LOC): Replaces `ClaudeClient.Cli` for Hub FSM LLM operations. Calls Ollama `/api/chat` via Req with tool calling support. Same API surface as ClaudeClient (decompose_goal, verify_completion, identify_improvements, generate_proposals).
- **HubFSM.Healing** (Elixir, ~100 LOC): New `:healing` state in `@valid_transitions`. Healing predicates in `HubFSM.Predicates`. Async healing cycle spawned on enter (same pattern as `:improving` and `:contemplating`).
- **HubFSM.HealthCheck** (Elixir, ~80 LOC): Gathers infrastructure health signals (Ollama reachability, sidecar connectivity, DETS integrity) consumed by `HubFSM.Predicates` to trigger healing transitions.

**Model selection:** Qwen3 8B (Q4_K_M quantization) for both sidecar agentic execution AND Hub LLM routing. Single model simplifies operations. ~6-7GB VRAM fits comfortably in RTX 3080 Ti 12GB. ~40+ tok/s. F1 0.933 on tool calling benchmarks. **Critical constraint:** Keep tool count ≤5 — Qwen3 with >5 tools falls back to XML-in-content format instead of native JSON tool calls.

### Expected Features

**Must have (table stakes):**
- **Tool definition registry** — LLM needs to know available tools. Keep count under 5 for Qwen3 8B (native JSON limit). New `tool-registry.js` in sidecar.
- **Tool execution engine** — Execute LLM-requested tool calls (read file, run command, call API) and return results. New `tool-executor.js` with workspace sandboxing.
- **Observation-reasoning loop (ReAct pattern)** — LLM thinks, calls tool, observes result, repeats until done. Modify OllamaExecutor for multi-turn conversation. 3-15 tool calls typical.
- **Loop safety guardrails** — External enforcement (not LLM self-policing): max iteration limit (15), repetition detection (same tool+args 3x = stop), token budget from CostLedger, wall-clock timeout (extend to 10min for agentic), monotonic progress check.
- **Healing state in FSM** — 5th state `:healing` lets FSM detect problems (Ollama down, tasks stuck, agents offline) and attempt automated remediation before human intervention. Valid transitions: any state → :healing, :healing → :resting or :executing.
- **Health check aggregation** — Unified health assessment from scattered sources (Alerter, MetricsCollector, LLM Registry, AgentFSM). New `HealthAggregator` module.
- **Stuck task detection and remediation** — Automatically reassign stuck tasks, restart unresponsive agents, or escalate to dead-letter. Most common pipeline failure.
- **Ollama endpoint recovery** — Health check retries with backoff, endpoint restart commands (if configured), graceful degradation to Claude-only routing.
- **Wake failure recovery** — Sidecar reports wake success/failure within 10s. If no ack, hub marks agent offline and requeues. **Existing bug that becomes critical in v1.4.**
- **Task timeout enforcement** — Task-level timeout in dispatcher.js wraps entire execution (including verification retries). Default 30min for agentic tasks, 10min for simple tasks. On timeout: kill execution, report failure, requeue if retries remain.

**Should have (competitive):**
- **Workspace-aware file tools** — Structured tools: `read_file` with line numbers, `write_file` with diff preview, `search_codebase` with ripgrep. Structured observations help smaller models reason better than raw shell output.
- **Tool call streaming to dashboard** — Real-time visibility into LLM tool calls, observations, reasoning. Extend progress events with `type: "tool_call"`. Invaluable for debugging.
- **Adaptive iteration limits** — Map complexity_tier to iteration budget: `{trivial: 5, standard: 10, complex: 20}`. Simple lookup, no LLM involved.
- **Healing playbook system** — Configurable condition-action pairs instead of hardcoded remediation. DETS-backed rules. Allows strategy changes without code updates.
- **Partial result acceptance** — Preserve partial work on timeout/budget exhaustion. Report as `partial_pass` with completed vs remaining. Hub creates follow-up task for remainder.

**Defer (v2+):**
- **Multi-agent tool collaboration** — Race conditions, merge conflicts. Use task dependencies instead.
- **LLM-generated tool definitions** — Security risk. Fixed tool registry, LLM chooses which to call, not which exist.
- **Autonomous model pulling** — Downloads are 4-8GB. Alert when unavailable, human pulls models.
- **Tool call caching/memoization** — Stale data bugs (read cached after write). Re-execute every tool call.
- **Custom tool protocols (MCP/A2A)** — Adds complexity for zero benefit when you control both LLM client and tool server.

### Architecture Approach

The architecture extends the existing v1.3 Hub FSM (4-state tick-driven GenServer) and sidecar OllamaExecutor (single-shot text generation) with three orthogonal capabilities: (1) sidecar-side agentic tool-calling loop within OllamaExecutor, (2) hub-side 5th FSM state `:healing` with health detection and remediation, and (3) hub-side optional Ollama HTTP routing via new `AgentCom.OllamaClient` module parallel to `ClaudeClient.Cli`.

**Major components:**

1. **OllamaClient (Elixir, hub-side)** — HTTP client for Ollama `/api/chat`. Request building, NDJSON streaming, response parsing. No tool execution logic. Uses `:httpc` (built-in, no new deps). Called by ClaudeClient or HubFSM.Healer.

2. **HubFSM.Healer (Elixir, hub-side)** — Stateless healing cycle module. Detection → diagnosis → fix → verify. Returns healing report. Diagnosis is deterministic-first (no LLM for most cases). Remediation actions: requeue stuck tasks, restart health checks, wait for reconnect, pause goal processing. 5-minute watchdog prevents healer from getting stuck.

3. **HubFSM.HealthCheck (Elixir, hub-side)** — Gathers health signals: agent connectivity (all offline?), task throughput collapse (>3 stuck >10min?), Ollama endpoint health (all unhealthy?), repeated goal failures. Pure function, no side effects. Called by `gather_system_state/0` on every tick.

4. **ToolRegistry (Node.js, sidecar-side)** — Defines available tools as JSON schemas. Exactly 5 tools to stay within Qwen3 native JSON limit: `read_file`, `write_file`, `run_shell`, `git_diff`, `list_files`. Each has name, description, parameter schema. Static definitions.

5. **ToolExecutor (Node.js, sidecar-side)** — Executes tool calls in sandboxed context. Enforces timeouts (30s default), path restrictions (workspace-only, no `../`), output limits (4000 chars). Maps tool names to execution functions. Wraps execution in ToolSandbox.

6. **ToolSandbox (Node.js, sidecar-side)** — Workspace isolation: path canonicalization (reject traversal), process timeout (30s), output truncation. Validates every file path resolves within `repo_dir`.

7. **AgenticExecutor (Node.js, sidecar-side)** — ReAct loop implementation. Sends task + tools to Ollama → receives tool_calls → executes via ToolExecutor → appends results → repeats. Max 10 iterations. Wall-clock timeout. Token budget check per iteration. Repetition detection (same tool+args 2x = break). Returns same ExecutionResult format as OllamaExecutor.

**Critical design decisions:**
- **`stream: false` for tool calling** — Ollama's streaming tool call support is inconsistent (GitHub issue #12557). Use non-streaming for reliability. Latency trade-off acceptable because tool-calling turns are short.
- **Sidecar AND hub agentic loops (different purposes)** — Sidecar loop for task execution (file access, git, shell). Hub loop for healing operations (query TaskQueue, check agent status, read logs). Different tool sets.
- **Adapter pattern for LLM backends** — Create `LLMAdapter` behavior returning normalized response: `{:ok, %{content: String.t(), tool_calls: list(), tokens_in: int(), tokens_out: int()}}`. Implement `ClaudeAdapter` and `OllamaAdapter` separately. GoalOrchestrator consumes normalized shape. Prevents response parsing mismatches.
- **Hub-driven agent lifecycle** — Sidecar reports health via `resource_report`, hub decides corrective action. Sidecar never calls `process.exit()` based on own health. Prevents restart loops.

### Critical Pitfalls

1. **Tool-Calling Infinite Loop (The Runaway Agent)** — LLM calls tools indefinitely without converging. With Qwen3 8B at ~84s/round, a 10-iteration loop takes 14 minutes. Runaway loop blocks sidecar for hours. **Prevention:** Hard cap at 10 iterations (non-negotiable, ships with loop itself). Wall-clock timeout per task (10min). Token budget per task (16K cumulative). Repetition detection (same tool+args 2x = break). Progress emission per round (makes loops visible immediately). **CRITICAL — must ship in same PR as tool-calling loop.**

2. **Tool Execution Sandboxing Failure (Agentic Escape)** — LLM requests file reads, command execution without sandbox. Can read sensitive files (`config.json`, `.env`), modify code outside task scope, execute destructive commands. Existing `ShellExecutor` uses `exec(command, { shell: true })` with no sandboxing. **Prevention:** Allowlist 4-6 tools exactly (no generic `execute_command`). Path canonicalization (`path.resolve(repo_dir, arg)` + verify starts with `repo_dir`). Read-only for non-task files. No `shell: true` — use `execFile` with explicit args. Audit log every tool call. **CRITICAL — implement before loop.**

3. **Self-Healing State Causing Cascade Failures (The Healing Storm)** — Healing logic triggers errors that create more healing work. Cascade: healing action A fails → triggers healing B → B conflicts with A's partial completion → both need healing → system oscillates between `:healing` and `:executing` at tick rate (1s). **Prevention:** Healing cooldown (30s minimum duration). Healing attempt limit (3 entries in 10min → transition to `:resting` with alert). Healing actions are idempotent (safe to run multiple times). Healing does NOT spawn async work (unlike `:improving`/`:contemplating`). Separate healing predicates from normal predicates (concrete conditions, not LLM assessment). **CRITICAL — cooldown and attempt limit ship with initial implementation.**

4. **LLM Backend Migration Breaking Response Parsing (Silent Output Loss)** — Claude CLI uses stream-json format (`content_block_delta`, `result` events). Ollama uses NDJSON (`message.content`, `message.tool_calls`). Ollama tool-calling responses have `tool_calls` array instead of `content` text. If parsing code updated for Ollama but tested only with text responses, tool-calling responses silently produce empty output. **Prevention:** Adapter pattern (normalize response shape). Response validation (empty responses are errors). Integration test with real Ollama before shipping. Parallel run period (Claude + Ollama side-by-side for 1 week). Token field mapping (Ollama `prompt_eval_count` → `tokens_in`, `eval_count` → `tokens_out`). **CRITICAL — adapter pattern designed before migration begins.**

5. **Qwen3 8B Tool-Calling Quality on 12GB VRAM (Hallucinated Tool Calls)** — Qwen3 8B F1 0.933 means ~7% tool calls are incorrect. Q4_K_M quantization (required for 12GB VRAM) degrades further. Model invents non-existent tools, provides wrong argument types, calls tools in illogical order. **Prevention:** Strict tool call validation (tool name exists, arguments match schema, required fields present). Minimize tool count (max 3 initially, expand to 5 only if accuracy acceptable). Simple tool schemas (2-3 params max, no complex nested schemas). Fallback to text mode after 3 consecutive invalid calls. Model testing before deployment (20 predefined prompts, >85% accuracy required). Think mode (`think=true`) for complex tasks. **CRITICAL — validation is part of loop implementation.**

## Implications for Roadmap

Based on research, suggested phase structure follows a **hub-parallel-with-sidecar** build order to minimize critical path:

### Phase A: OllamaClient (Hub-side HTTP client)
**Rationale:** Standalone module with zero dependencies on other new components. Both Healing and Hub-to-Ollama routing need it. Lowest risk, enables downstream phases.
**Delivers:** `AgentCom.OllamaClient` module with `health_check/1`, `chat/2`. Uses `:httpc` (built-in). Config keys: `:ollama_url`, `:ollama_model`.
**Addresses:** Hub LLM routing (optional optimization), healing LLM-assisted diagnosis (optional).
**Avoids:** Pitfall #4 (response parsing) by establishing adapter pattern from start.
**Risk:** LOW (simple HTTP wrapper, no GenServer state, pure functions).

### Phase B: Hub FSM Healing State
**Rationale:** Modifies FSM core (highest-risk hub change). Better to stabilize this before adding sidecar complexity. Healing can work with deterministic-only diagnosis initially (no LLM needed).
**Delivers:** `HubFSM.HealthCheck`, `HubFSM.Healer`, modify HubFSM (add `:healing` to `@valid_transitions`), modify `HubFSM.Predicates` (healing predicates), extend HubFSM struct (health_signals, healing_attempts, last_healed_at).
**Addresses:** Stuck task detection/remediation, Ollama endpoint recovery, healing state transitions.
**Avoids:** Pitfall #3 (healing cascade storm) with cooldown + attempt limit + idempotent actions.
**Risk:** MEDIUM (modifying core FSM, but follows existing `:improving`/`:contemplating` async Task pattern).
**Depends on:** Phase A (optional, for Ollama-assisted diagnosis).

### Phase C: Sidecar Tool Infrastructure
**Rationale:** Sidecar-side, parallel with hub work (Phases A+B). No hub changes needed. Tool definitions and sandboxing are FIRST thing to implement, before loop.
**Delivers:** `ToolRegistry.js` (5 tool schemas), `ToolSandbox.js` (path validation, timeout, output limits), `ToolExecutor.js` (dispatch to tool implementations), individual tool implementations (read_file, write_file, run_shell, git_diff, list_files).
**Addresses:** Tool execution engine, workspace sandboxing.
**Avoids:** Pitfall #2 (sandbox escape) with allowlist tools + path canonicalization + no shell:true.
**Risk:** MEDIUM (security-sensitive: sandbox must prevent path traversal).
**Depends on:** Nothing (sidecar-side, parallel with hub work).

### Phase D: Sidecar Agentic Tool-Calling Loop
**Rationale:** Core agentic capability. Most complex new behavior. Requires tool infrastructure from Phase C.
**Delivers:** Modify OllamaExecutor with multi-turn loop, non-streaming tool-call turns (`stream: false`), max iteration guard (10), timeout enforcement (`execution_timeout_ms` from task_data), repetition detection, progress emission per round.
**Addresses:** ReAct loop, loop safety guardrails, structured output parsing (detect `tool_calls` in response).
**Avoids:** Pitfall #1 (infinite loop) with hard cap + timeout + token budget + repetition detection + progress per round. Pitfall #5 (hallucinated tool calls) with strict validation.
**Risk:** MEDIUM-HIGH (most complex new behavior, parsing tool_calls, multi-turn state management).
**Depends on:** Phase C (needs ToolRegistry + ToolExecutor).

### Phase E: Hub-to-Ollama Routing
**Rationale:** Config-driven, low risk. Defaults to Claude CLI, gradually enabled. Allows hub LLM operations to use Ollama for fast/cheap tasks (healing diagnosis, simple triage).
**Delivers:** Modify ClaudeClient (backend selection via `select_backend/2`), config (`:ollama_hub_enabled`, `:ollama_prompt_types`), `OllamaClient.ToolLoop` for hub-side tool calling (healing tools), CostLedger (skip budget check for Ollama calls).
**Addresses:** Hub LLM routing through Ollama (secondary optimization).
**Avoids:** Pitfall #8 (prompt quality degradation) by keeping Claude for high-stakes operations (decomposition, verification) initially.
**Risk:** LOW (routing is config-driven, defaults to Claude CLI).
**Depends on:** Phase A + Phase B.

### Phase F: Pipeline Reliability
**Rationale:** Extends existing sweeps and protocols. Benefits from all other phases being testable. Some fixes (task timeout) pair naturally with agentic execution.
**Delivers:** Execution timeout propagation in task_data, wake failure detection (`task_started`/`task_start_failed` WebSocket msgs), stuck task recovery with backoff (`reclaim_count` tracking), dead-letter after N reclaims.
**Addresses:** Wake failure recovery (HIGHEST-PRIORITY RELIABILITY FIX — existing bug), task timeout enforcement, idempotent task requeue.
**Avoids:** Pitfall #7 (no-wake_command permanent hang) with timeout + routing_decision requirement.
**Risk:** LOW-MEDIUM (extending existing mechanisms).
**Depends on:** Phase D (sidecar needs to send `task_started`).

### Phase Ordering Rationale

- **OllamaClient first** because it's standalone with no dependencies. Both Healing and Hub-to-Ollama routing need it.
- **Healing State second** because it modifies FSM core (highest-risk hub change). Stabilize before adding sidecar complexity. Can work without LLM initially.
- **Sidecar Tool Infrastructure third** (parallel with A+B) because it's sidecar-side with no hub changes. Tool definitions and sandboxing MUST come before loop.
- **Agentic Loop fourth** because it depends on tool infrastructure and is the most complex behavior.
- **Hub-to-Ollama Routing fifth** because it's config-driven and low risk. Defaults to Claude, gradually enabled.
- **Pipeline Reliability last** because it extends existing mechanisms and benefits from all phases being testable.

**Parallelization:** Phases A+B (hub-side) run parallel with Phase C (sidecar-side). Critical path: A → B → E → F (hub track) merges with C → D (sidecar track) → F. Estimated ~4 phases in critical path instead of 6 serial.

### Research Flags

**Phases likely needing deeper research during planning:**
- **Phase D (Agentic Loop):** Complex integration. May need deeper dive into Ollama streaming edge cases, Qwen3 8B-specific quirks (XML fallback with >5 tools), tool result truncation strategies.
- **Phase E (Hub Routing):** Prompt rewriting for Qwen3 8B. Needs evaluation before migration (20 representative prompts, quality threshold). May discover Qwen3 8B cannot match Claude quality for decomposition/verification.

**Phases with standard patterns (skip research-phase):**
- **Phase A (OllamaClient):** HTTP POST wrapper. Standard Elixir HTTP client pattern. Ollama API is well-documented.
- **Phase B (Healing State):** Extends existing FSM pattern. GenServer + async Task pattern already established in v1.3 (`:improving`, `:contemplating`).
- **Phase C (Tool Infrastructure):** Standard sandboxing patterns (path validation, timeouts, allowlists). Well-understood security domain.
- **Phase F (Pipeline Reliability):** Extends existing Scheduler sweeps, WebSocket protocol, timeout mechanisms. Incremental changes to proven patterns.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Ollama tool calling API verified via official docs. ollama-js verified via GitHub/npm. GenServer testing patterns verified via Elixir community sources. Zero new dependencies — all built on v1.2 stack. |
| Features | MEDIUM-HIGH | Ollama tool calling API documented and verified. ReAct/agentic loop patterns well-established. Self-healing patterns standard in OTP. Pipeline reliability patterns are standard distributed systems engineering. Qwen3 8B benchmarks strong (F1 0.933) but quantized performance varies. |
| Architecture | HIGH | Grounded in direct analysis of shipped v1.3 codebase (HubFSM, ClaudeClient, Scheduler, GoalOrchestrator, AgentFSM). Integration points clearly identified. Adapter pattern prevents response parsing mismatches. Sidecar/hub separation maintained. |
| Pitfalls | HIGH | Every production LLM agent deployment documents infinite loop as primary failure mode. Sandbox escape is direct consequence of giving LLM execution capabilities. Healing cascade storm documented in distributed systems literature. Response format mismatches visible in existing codebase (two different parsers). |

**Overall confidence:** HIGH

### Gaps to Address

- **Qwen3 8B quantized quality on specific GPU:** Benchmarks are for generic Q4_K_M. RTX 3080 Ti-specific performance needs empirical validation. Run 20-prompt tool-calling evaluation suite before deploying. If accuracy <85%, consider different model or quantization.
- **Healing playbook design:** Research documents hardcoded remediation first, extract to configurable playbook after patterns stabilize. Initial implementation uses deterministic rules (no LLM). May need LLM-assisted diagnosis later — deferred to follow-up.
- **Hub LLM routing prompt quality:** If migrating hub operations to Ollama, prompts must be rewritten for Qwen3 8B. Current prompts tuned for Claude. Research suggests hybrid approach (Ollama for low-stakes, Claude for high-stakes) but this needs validation during implementation.
- **Wake failure root cause:** Research identifies the bug (no `wake_command` causes permanent hang) but does not explain why `wake_command` is sometimes missing. Investigate during pipeline reliability phase: is this config error, routing logic gap, or edge case in task decomposition?

## Sources

### Primary (HIGH confidence)
- [Ollama Tool Calling Documentation](https://docs.ollama.com/capabilities/tool-calling) — Request/response format, tool schemas, tool role messages
- [Ollama Streaming Tool Calling Blog](https://ollama.com/blog/streaming-tool) — Streaming with tool calls, chunk accumulation
- [Ollama API Reference (GitHub)](https://github.com/ollama/ollama/blob/main/docs/api.md) — /api/chat endpoint, tools parameter
- [ollama-js GitHub](https://github.com/ollama/ollama-js) — npm library API, chat() with tools
- [ollama npm v0.6.3](https://www.npmjs.com/package/ollama) — Current version, 416 dependents
- AgentCom v1.3 shipped codebase — HubFSM, ClaudeClient, Scheduler, GoalOrchestrator, AgentFSM (direct code examination)
- [Elixir GenServer Testing Patterns](https://www.freshcodeit.com/blog/how-to-design-and-test-elixir-genservers) — start_supervised, callback testing
- [Architecting GenServers for Testability](https://tylerayoung.com/2021/09/12/architecting-genservers-for-testability/) — Thin GenServer pattern

### Secondary (MEDIUM confidence)
- [Ollama VRAM Requirements Guide](https://localllm.in/blog/ollama-vram-requirements-for-local-llms) — Q4_K_M memory requirements
- [Qwen3 8B Tool Calling](https://collabnix.com/best-ollama-models-for-function-calling-tools-complete-guide-2025/) — F1 0.933, model comparison
- [Docker LLM Tool Calling Evaluation](https://www.docker.com/blog/local-llm-tool-calling-a-practical-evaluation/) — Practical benchmarks
- [Qwen3 Function Calling Documentation](https://qwen.readthedocs.io/en/latest/framework/function_call.html) — Hermes-style tool use
- [LLM Tool-Calling in Production (Medium, Jan 2026)](https://medium.com/@komalbaparmar007/llm-tool-calling-in-production-rate-limits-retries-and-the-infinite-loop-failure-mode-you-must-2a1e2a1e84c8) — Loop guardrails
- [Why AI Agents Get Stuck in Loops](https://www.fixbrokenaiapps.com/blog/ai-agents-infinite-loops) — Root causes
- [Self-Healing Patterns for Distributed Systems (GeeksforGeeks)](https://www.geeksforgeeks.org/important-self-healing-patterns-for-distributed-systems/) — Retry, circuit breaker, health check
- [ReAct Prompting Guide](https://www.promptingguide.ai/techniques/react) — Thought-Action-Observation cycle
- [Building AI Agents with ReAct Pattern (TypeScript, 2026)](https://noqta.tn/en/tutorials/ai-agent-react-pattern-typescript-vercel-ai-sdk-2026) — Implementation reference

### Tertiary (LOW confidence)
- [Agent Deployment Gap (ZenML)](https://www.zenml.io/blog/the-agent-deployment-gap-why-your-llm-loop-isnt-production-ready-and-what-to-do-about-it) — Production readiness gaps
- [Event-Driven Agentic Loops (BoundaryML)](https://boundaryml.com/podcast/2025-11-05-event-driven-agents) — Event log architecture
- [Qwen3-coder Tool Calling Fails with Many Tools (GitHub Issue)](https://github.com/block/goose/issues/6883) — Qwen3 XML fallback with >5 tools

---
*Research completed: 2026-02-14*
*Ready for roadmap: yes*
