# Phase 41: Agentic Execution Loop — Discussion Context

## Approach

Refactor OllamaExecutor from single-shot text generation into a multi-turn ReAct agent loop. This is the core deliverable of v1.4 — local LLMs actually DO things.

### ReAct Loop
1. Build initial messages: system prompt (with tool instructions + few-shot examples) + task description + context
2. Call Ollama `/api/chat` with `messages[]` + `tools[]` + `stream: false`
3. Parse response:
   - Has `message.tool_calls`? → execute tools, append results as `role: "tool"` messages, go to step 2
   - No `tool_calls` (content only)? → final answer, exit loop
   - Malformed? → attempt auto-correction, retry once
4. On loop exit: collect file modifications, run verification, return result

### Output Parser (3-layer)
1. Native `message.tool_calls` field (preferred path)
2. JSON extraction from `message.content` (regex for `{"name":..., "arguments":...}`)
3. XML extraction from `message.content` (Qwen3 `<tool_call>` fallback for >5 tools)

### Safety Guardrails (external to loop)
- Max iterations by complexity tier: trivial=5, standard=10, complex=20
- Repetition detection: same tool+args called 3x consecutively → force stop
- Wall-clock timeout: from PIPE-02 (30min agentic, 10min simple)
- Token budget check per iteration: PIPE-06 (check CostLedger before each Ollama call)
- Monotonic progress check: if no new file modifications in 5 iterations → force stop

### System Prompt
- Describes available tools with usage instructions
- Few-shot examples of tool calling patterns (read file → understand → modify → verify)
- Step-by-step task completion pattern for Qwen3 8B
- Workspace context (repo name, branch, relevant files from task)

### Dashboard Streaming
- Emit `type: "tool_call"` progress events through existing WebSocket channel
- Each event: `{tool_name, args_summary, result_summary, iteration_number}`
- Dashboard shows live tool-call timeline per task

### Partial Results
- On forced stop (timeout, budget, max iterations): run verification on current workspace state
- If some verification checks pass: report `partial_pass` with completed vs remaining work
- Hub can create follow-up task for remaining work

## Key Decisions

- **Few-shot examples in system prompt** — Qwen3 8B benefits from concrete examples
- **`stream: false` for tool calling** — simplifies parsing, avoids Ollama streaming bugs
- **3-layer output parser** — graceful degradation across response formats
- **PIPE-06 wired here** — per-iteration budget check integrated into the loop
- **Partial results preserved** — don't waste completed work on timeout

## Files to Modify

- `sidecar/lib/execution/ollama-executor.js` — major refactor: single-shot → multi-turn loop
- NEW: `sidecar/lib/execution/tool-call-parser.js` — 3-layer output parser
- NEW: `sidecar/lib/execution/agentic-prompt.js` — system prompt builder with few-shot examples
- `sidecar/lib/execution/progress-emitter.js` — add tool_call event type
- `sidecar/lib/execution/verification-loop.js` — partial result handling
- `priv/static/dashboard.html` or `lib/agent_com/dashboard.ex` — tool call timeline display

## Dependencies

- **Phase 40** (tool infrastructure) — tools must exist for the loop to call them
- **Phase 39 PIPE-02** (task timeout) — wraps the entire loop
- PIPE-06 (per-iteration budget) — integrated into loop, was deferred from Phase 39

## Risks

- HIGH — most complex phase, core agentic capability
- Infinite loop risk mitigated by external guardrails
- Qwen3 8B tool calling quality needs empirical validation
- Output parser must handle edge cases gracefully

## Success Criteria

1. OllamaExecutor runs multi-turn ReAct loop with tool calling
2. Loop terminates on max iterations, repetition, budget, or timeout
3. Output parser handles native JSON, JSON-in-content, and XML extraction
4. Dashboard shows real-time tool call events via WebSocket
5. Timeout/budget exhaustion preserves partial work with partial_pass
