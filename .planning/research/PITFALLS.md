# Domain Pitfalls

**Domain:** Adding agentic local LLM tool calling, Hub FSM Healing state, pipeline reliability to existing distributed agent coordination system
**Researched:** 2026-02-14
**Codebase analyzed:** AgentCom v2.0 milestone scope (Elixir/BEAM hub, Node.js sidecars, RTX 3080 Ti 12GB VRAM, Ollama + Qwen3 8B, existing 4-state Hub FSM, existing OllamaExecutor producing text-only output)

---

## Critical Pitfalls

Mistakes that cause system-wide failures, data loss, or runaway resource consumption.

---

### Pitfall 1: Tool-Calling Infinite Loop (The Runaway Agent)

**What goes wrong:** The OllamaExecutor currently sends a prompt and collects text output. When upgraded to support Ollama's `/api/chat` tool-calling format, the LLM can request tool calls, receive results, then request more tool calls indefinitely. Without a hard iteration cap, a single task consumes the GPU indefinitely, blocks all other tasks on that sidecar, and potentially fills disk with log output. With Qwen3 8B at ~84 seconds per tool-calling round, a 10-iteration loop takes 14 minutes. A runaway loop takes hours.

**Why it happens in THIS codebase:** The current `OllamaExecutor._streamChat()` (lines 129-232 of `ollama-executor.js`) is fire-and-forget: one request, one streaming response, done. Tool calling requires a multi-turn conversation loop where the executor must:
1. Send initial prompt with tools definition
2. Receive response with `tool_calls` array (not text content)
3. Execute the tool locally
4. Send tool results back as `role: "tool"` messages
5. Receive next response (which may contain MORE tool calls)
6. Repeat until model returns text content without tool calls

There is no loop structure in the current executor. Adding one without guards creates the infinite loop risk.

**Warning signs (concrete to this system):**
- Sidecar process memory climbs steadily as conversation history accumulates in the messages array
- Task stays in `working` status for >5 minutes when typical Ollama tasks complete in 1-2 minutes
- GPU utilization locked at 100% with no progress events being emitted to hub
- `ollama_attempt_failed` log entries stop appearing (the executor is not failing, it is looping)
- Hub's `AgentFSM` for the affected agent stays in `:working` state, never transitions to `:idle`

**Consequences:** Single runaway task blocks the entire sidecar (queue model is max 1 active task). Hub cannot assign new work to that agent. If multiple agents hit the same loop-inducing prompt, all sidecars lock up simultaneously. GPU thermal throttling under sustained load degrades even the loop itself.

**Prevention:**
1. **Hard iteration cap.** Maximum 10 tool-call rounds per task execution. After 10 rounds, force a final response by sending without the `tools` parameter. This is the single most important guard.
2. **Wall-clock timeout per task.** The existing `_streamChat` has a 5-minute timeout (line 147). For tool-calling loops, each round resets the per-round timer but a total task timeout of 10 minutes kills the entire conversation.
3. **Token budget per task.** Track cumulative `prompt_eval_count` + `eval_count` across all rounds. Cap at 16K tokens total (reasonable for 8B model with 32K context). Stop when budget exhausted.
4. **Repetition detection.** If the model calls the same tool with identical arguments twice in a row, break the loop. This catches the most common degenerate case (model keeps calling `read_file` on the same file).
5. **Progress emission per round.** Emit a `tool_call_round` progress event to the hub on each iteration. This makes loops visible in the dashboard immediately, even before the cap triggers.

**Detection:** New telemetry: `tool_call_rounds` field in task completion result. Dashboard alert if any task exceeds 5 rounds. Log each tool call with round number.

**Phase to address:** Agentic tool-calling phase. The loop guard MUST ship in the same PR as the tool-calling loop itself. Not as a follow-up.

**Confidence:** HIGH. Every production LLM agent deployment documents this as the primary failure mode. The Medium article "LLM Tool-Calling in Production" (Jan 2026) states: "Hard caps on iterations, tokens, time, and spend are non-negotiable in production."

---

### Pitfall 2: Tool Execution Sandboxing Failure (Agentic Escape)

**What goes wrong:** When the LLM gains tool-calling ability, it can request file reads, command execution, or other system operations. If the tool implementations do not sandbox properly, the LLM can read sensitive files (`config.json` with hub tokens, `.env` files), modify code outside the task scope, or execute destructive commands. The current `ShellExecutor` (line 47-67 of `dispatcher.js`) already has a shell execution path -- connecting this to LLM-directed tool calls without sandboxing creates a remote code execution surface.

**Why it happens in THIS codebase:** The sidecar runs as the user's process with full filesystem access. The existing `wake.js` uses `exec(command, { shell: true })` with no sandboxing. When the LLM requests `execute_command("rm -rf /")` as a tool call, the question is whether the tool implementation honors it. The temptation is to reuse existing shell execution infrastructure because it already works.

**Warning signs:**
- Tool definitions include `execute_shell_command` or `run_command` without path/command restrictions
- LLM-generated tool calls reference paths outside `repo_dir` (e.g., `../../config.json`)
- Tool results contain content from files the task should not access

**Consequences:** Data exfiltration (hub tokens, API keys), codebase corruption (files modified outside task scope), system damage (destructive commands).

**Prevention:**
1. **Allowlist tool operations, not denylist.** Define exactly 4-6 tools: `read_file` (within repo_dir only), `write_file` (within repo_dir only), `run_test` (predefined command), `search_code` (within repo_dir). No generic `execute_command` tool.
2. **Path canonicalization.** Every file path argument must be resolved with `path.resolve(repo_dir, tool_arg)` and verified to start with `repo_dir` after resolution. Reject path traversal (`../`).
3. **Read-only for non-task files.** The tool implementation for `read_file` should have an explicit allowlist of readable directories. Write operations only to the task's working branch.
4. **No shell: true.** Tool-executed commands use `execFile` (not `exec`) with explicit argument arrays. No shell interpretation of LLM-provided strings.
5. **Audit log.** Every tool call and its result is logged with task_id, tool_name, arguments, and truncated result. This is both a debugging and security measure.

**Detection:** Log analysis for tool calls referencing paths outside repo_dir. Alert on any tool call failure due to permission/path violation.

**Phase to address:** Agentic tool-calling phase. Tool definitions and sandboxing are the FIRST thing to implement, before the tool-calling loop.

**Confidence:** HIGH. Direct consequence of giving an LLM execution capabilities on a system with existing shell access.

---

### Pitfall 3: Self-Healing State Causing Cascade Failures (The Healing Storm)

**What goes wrong:** The proposed `:healing` state for HubFSM triggers corrective actions when problems are detected (hung tasks, unresponsive agents, stale state). If the healing logic itself triggers errors or interacts with the same systems it is trying to heal, it creates a cascade: healing action A fails, triggering healing action B, which conflicts with A's partial completion, both now need healing, and the system oscillates between `:healing` and `:executing` at the tick rate (1 second).

**Why it happens in THIS codebase:** The HubFSM runs a 1-second tick (`@tick_interval_ms 1_000`, line 56 of `hub_fsm.ex`). The `Predicates.evaluate/2` function is pure (no side effects), but `do_transition/3` has side effects: it spawns `Task.start` for improvement/contemplation cycles (lines 488-502), broadcasts PubSub events, and updates ClaudeClient state. If `:healing` transitions trigger corrective Task.start operations, and those tasks fail, the failures feed back into the next tick's system state, potentially triggering another healing transition.

The existing watchdog timer (2 hours, line 57) is a crude version of self-healing -- it force-transitions to `:resting` when stuck. But a dedicated `:healing` state needs to do more targeted work: cancel hung tasks, restart unresponsive agents, clear stale queue entries. Each of these operations can fail independently.

**Warning signs (concrete to this system):**
- HubFSM history shows rapid oscillation: `:executing` -> `:healing` -> `:executing` -> `:healing` at 1-second intervals
- `hub_fsm_transition` log entries flood with `reason: "healing triggered"` interleaved with `reason: "healing complete, goals pending"`
- GoalOrchestrator's `pending_async` is never nil because healing keeps spawning new tasks before previous ones complete
- PubSub `"hub_fsm"` topic broadcasts 60+ state change events per minute

**Consequences:** Hub FSM burns CPU on rapid transitions. PubSub floods connected dashboards. GoalOrchestrator state becomes inconsistent. Agents receive conflicting signals (task assigned, then cancelled, then re-assigned).

**Prevention:**
1. **Healing cooldown.** After entering `:healing`, enforce a minimum duration (30 seconds) before transitioning out. Use `gen_statem` state timeout or a manual timer. This prevents rapid oscillation.
2. **Healing attempt limit.** Track consecutive healing entries. If `:healing` is entered 3 times within 10 minutes without a successful `:executing` or `:resting` period between, transition to `:resting` with an alert. The system needs human intervention.
3. **Healing actions are idempotent.** Every healing action must be safe to run multiple times: "cancel task X" must succeed (or no-op) even if X is already cancelled. "Reclaim task from agent Y" must handle Y already being offline.
4. **Healing does not spawn async work.** Unlike `:improving` and `:contemplating` which spawn `Task.start`, healing actions should be synchronous within the GenServer `do_transition`. This prevents the "healing task fails and creates more healing work" feedback loop.
5. **Separate healing predicates from normal predicates.** Add healing-specific predicates to `Predicates.evaluate/2` that check for concrete conditions: `hung_task_count > 0`, `unresponsive_agent_count > 0`. Do NOT use LLM assessment for healing triggers.
6. **Valid transitions for healing must be restrictive.** Add to `@valid_transitions`: `healing: [:resting, :executing]`. Healing cannot transition to `:improving` or `:contemplating` -- it must return to a stable state first.

**Detection:** New telemetry event `[:agent_com, :hub_fsm, :healing_triggered]` with metadata about what was detected and what corrective action was taken. Dashboard panel showing healing frequency over time.

**Phase to address:** Hub FSM Healing state phase. The cooldown and attempt limit must ship with the initial implementation.

**Confidence:** HIGH. The Statsig article on distributed system failure patterns documents this as "retry storm" -- the exact same pattern applied to self-healing. GeeksforGeeks' self-healing patterns article explicitly warns: "Implementing self-healing without proper guards can cause more damage than the original failure."

---

### Pitfall 4: LLM Backend Migration Breaking Response Parsing (Silent Output Loss)

**What goes wrong:** The hub-side `ClaudeClient.Cli` invokes `claude -p` and parses stream-json output (content_block_delta events, result events with usage stats). Replacing this with Ollama calls changes EVERYTHING about the response format: different JSON structure, different token counting fields, different streaming protocol (NDJSON vs stream-json), and critically, tool-calling responses have `tool_calls` array instead of `content` text. If the parsing code is updated for Ollama but tested only with text responses, tool-calling responses silently produce empty output.

**Why it happens in THIS codebase:** The `ClaudeClient` GenServer (lines 130-168 of `claude_client.ex`) delegates to `ClaudeClient.Cli.invoke/3` which handles prompt construction AND response parsing. The sidecar's `claude-executor.js` parses `content_block_delta` events (line 153) and `result` events (line 166). The sidecar's `ollama-executor.js` parses NDJSON with `parsed.message.content` (line 186) and `parsed.done` (line 175).

These are completely different response formats:
- Claude: `{"type": "content_block_delta", "delta": {"type": "text_delta", "text": "..."}}`
- Ollama text: `{"message": {"content": "..."}, "done": false}`
- Ollama tool call: `{"message": {"tool_calls": [{"function": {"name": "...", "arguments": {...}}}]}, "done": true}`

The danger: refactoring to use Ollama on the hub side (replacing `ClaudeClient.Cli`) while keeping the existing response shape expectations in `GoalOrchestrator.Decomposer` and `GoalOrchestrator.Verifier`.

**Warning signs:**
- `decompose_goal` returns `{:ok, []}` (empty task list) instead of `{:error, ...}` -- the LLM responded but the response was not parsed
- `verify_completion` returns `{:ok, :pass}` on every verification because the parsed output is empty and the default path is optimistic
- `tokens_in: 0, tokens_out: 0` in CostLedger despite Ollama processing (because Ollama uses `prompt_eval_count`/`eval_count`, not `input_tokens`/`output_tokens`)
- No errors in logs -- the system appears to work but produces empty/default results

**Consequences:** Goal decomposition produces no tasks (goals sit in `:decomposing` forever). Verification always passes (broken code ships). Cost tracking shows zero spend (budget controls ineffective). The system appears functional but accomplishes nothing.

**Prevention:**
1. **Adapter pattern.** Create an `LLMAdapter` behaviour/interface with `call/2` returning a normalized response: `{:ok, %{content: String.t(), tool_calls: list(), tokens_in: integer(), tokens_out: integer()}}`. Implement `ClaudeAdapter` and `OllamaAdapter` separately. GoalOrchestrator consumes the normalized shape.
2. **Response validation.** After every LLM call, assert the response is non-empty. `decompose_goal` must return at least 1 task or an explicit error. Empty responses are errors, never successes.
3. **Integration test with real Ollama.** Before shipping the migration, run the full decompose-execute-verify cycle against actual Ollama with Qwen3 8B. Mock-based tests will not catch response format mismatches.
4. **Parallel run period.** Keep ClaudeClient functional alongside OllamaClient for 1 week. Run decomposition through both, compare results. This catches semantic quality differences (Qwen3 8B may decompose differently than Claude Sonnet).
5. **Token field mapping.** Explicit mapping: Ollama `prompt_eval_count` -> normalized `tokens_in`, Ollama `eval_count` -> normalized `tokens_out`. Note: Ollama caches prompt evaluations and returns `prompt_eval_count: 0` on cache hits (the existing `ollama-executor.js` already handles this on line 177 with `|| 0`). This is NOT an error.

**Detection:** Assertion in CostLedger: if an LLM call was made but tokens_in + tokens_out == 0, log a warning. Non-zero duration with zero tokens means the response was not parsed correctly.

**Phase to address:** LLM backend migration phase. The adapter pattern must be designed BEFORE the migration begins, not retrofitted after.

**Confidence:** HIGH. The existing codebase already has TWO different response parsers (claude-executor.js and ollama-executor.js) demonstrating the format divergence. The Medium article "When Your Dev and Prod LLM Backends Don't Match" (Dec 2025) documents exactly this failure mode.

---

### Pitfall 5: Qwen3 8B Tool-Calling Quality on 12GB VRAM (Hallucinated Tool Calls)

**What goes wrong:** Qwen3 8B achieves 0.933 F1 on tool-calling benchmarks, which sounds excellent until you realize this means ~7% of tool calls are incorrect. On a 12GB RTX 3080 Ti running the Q4_K_M quantized version (required to fit in VRAM), accuracy drops further. Hallucinated tool calls include: calling non-existent tools, providing wrong argument types, calling tools with plausible but incorrect arguments (e.g., `read_file("src/main.rs")` in an Elixir project).

**Why it happens in THIS codebase:** The tool definitions sent to Ollama describe available tools. But the 8B model has limited instruction-following capacity compared to larger models. With 4-6 tools defined, the model sometimes:
- Invents a 7th tool that does not exist
- Calls `write_file` when it should call `read_file` (similar names)
- Provides arguments as a string instead of an object
- Generates tool call JSON that is syntactically valid but semantically wrong

Quantization to Q4_K_M (necessary for 12GB VRAM with Qwen3 8B's 16GB FP16 size) further degrades instruction following. The model may produce malformed `tool_calls` JSON that the Ollama server cannot parse, resulting in a text response that LOOKS like a tool call but is not structured as one.

**Warning signs:**
- Ollama returns `message.content` containing text that looks like a function call (e.g., `I'll call read_file("config.exs")`) instead of a proper `message.tool_calls` array
- Tool call arguments fail JSON schema validation
- Model calls tools in illogical order (write before read, delete before create)
- Model repeatedly calls the same tool with slightly different arguments, fishing for the "right" response

**Consequences:** Tool execution fails (non-existent tool), produces wrong results (wrong arguments), or corrupts state (write to wrong file). The tool-calling loop retries with the error message, but the model may not learn from the error and repeats the same mistake.

**Prevention:**
1. **Strict tool call validation.** Before executing any tool call, validate: tool name exists in defined tools, arguments match expected schema (type check each field), required arguments are present. Return a structured error to the model if validation fails.
2. **Minimize tool count.** With an 8B model, fewer tools = higher accuracy. Start with 3 tools maximum: `read_file`, `write_file`, `list_files`. Add more only if accuracy remains acceptable.
3. **Simple tool schemas.** Each tool should have at most 2-3 parameters. Complex nested schemas confuse small models. `read_file(path: string)` not `read_file(path: string, encoding: string, start_line: int, end_line: int)`.
4. **Fallback to text mode.** If tool calling fails 3 times in a row (invalid calls), fall back to text-only mode for that task. Parse structured output from text using regex/JSON extraction. The current text-only pipeline already works -- it is the fallback.
5. **Model testing before deployment.** Run a tool-calling evaluation suite against the specific quantized model on the specific GPU. Benchmark: 20 predefined prompts with expected tool calls. If accuracy < 85%, consider a different model or quantization level.
6. **Think mode.** Qwen3 supports `think=true` which enables chain-of-thought before tool calling. This significantly improves tool-calling accuracy at the cost of ~2x latency. Enable for tool-calling tasks, disable for simple text generation.

**Detection:** Track tool call validation failure rate per model. Dashboard metric: `tool_calls_valid / tool_calls_total`. Alert if ratio drops below 0.85.

**Phase to address:** Agentic tool-calling phase. Validation is part of the tool-calling loop implementation.

**Confidence:** MEDIUM. Qwen3 8B benchmarks are strong, but quantized performance on specific tasks varies. The Docker blog evaluation (2025) shows Qwen3 8B as the best local model for tool calling, but notes configuration-dependent issues.

---

## Moderate Pitfalls

Mistakes that cause significant debugging time or partial rework.

---

### Pitfall 6: Adding :healing to @valid_transitions Without Updating All Consumers

**What goes wrong:** The HubFSM's `@valid_transitions` map (line 49-54 of `hub_fsm.ex`) defines which state transitions are legal. Adding `:healing` requires updating this map, but also every piece of code that handles FSM states exhaustively:
- `Predicates.evaluate/2` has pattern matches for all 4 states (`:resting`, `:executing`, `:improving`, `:contemplating`). Missing `:healing` falls through to the catch-all `evaluate(_unknown, _system_state), do: :stay` (line 89) -- healing state evaluations are silently ignored.
- `do_transition/3` has conditional logic for `:improving` and `:contemplating` (lines 485-502). If `:healing` needs entry actions (like `:improving` spawns `SelfImprovement.run_improvement_cycle()`), they must be added here.
- `ClaudeClient.set_hub_state/1` only accepts `[:executing, :improving, :contemplating]` (line 34). Calling it with `:healing` crashes. The `do_transition` guard (line 441) currently skips `:resting`; it must also skip `:healing` or add `:healing` to `@valid_hub_states`.
- `gather_system_state/0` does not collect healing-relevant data (hung task count, unresponsive agents). The `:healing` predicates will need new data points.
- `broadcast_state_change/1` works generically but dashboard consumers may not render `:healing` state.

**Why it happens:** The current 4-state FSM was designed as a complete set. Pattern matching in Elixir is exhaustive only if the developer adds catch-all clauses. The Predicates module uses specific atoms, not a generic handler, so a new state is silently caught by the catch-all.

**Warning signs:**
- After adding `:healing`, the FSM enters healing but tick evaluation always returns `:stay` (predicates do not handle it)
- `ClaudeClient` crashes with `FunctionClauseError` when hub enters `:healing` state
- Dashboard shows blank/unknown state when hub is healing

**Prevention:**
1. **Enumerate all touch points before coding.** Search for `:resting`, `:executing`, `:improving`, `:contemplating` across the entire codebase. Every file that references these atoms needs review.
2. **Add `:healing` to `@valid_hub_states` in ClaudeClient** OR exclude it from the `do_transition` ClaudeClient notification (like `:resting` is excluded).
3. **Add healing predicates explicitly.** New `evaluate(:healing, system_state)` clause in Predicates.evaluate/2 that checks healing completion criteria.
4. **Add healing-specific system state fields** to `gather_system_state/0`: `hung_task_count`, `stale_agent_count`, `queue_anomalies`.
5. **Compile-time validation.** Add a module attribute listing all valid FSM states: `@all_states [:resting, :executing, :improving, :contemplating, :healing]`. Use it in tests to verify Predicates handles every state.

**Detection:** Test that calls `Predicates.evaluate(state, system_state)` for every state in `@valid_transitions` keys. If any returns unexpected `:stay`, the predicate is missing.

**Phase to address:** Hub FSM Healing state phase. This is the first task: enumerate all touch points.

**Confidence:** HIGH. Mechanical correctness issue. The codebase patterns make the touch points identifiable but easy to miss.

---

### Pitfall 7: Pipeline Silent Failure -- No wake_command Causes Permanent Task Hang

**What goes wrong:** When `wake_command` is not configured in sidecar `config.json`, the `wakeAgent` function (lines 96-104 of `index.js`) sets `task.status = 'working'` and returns. But no agent process actually starts working. The task sits in `working` status forever. The hub's `AgentFSM` shows the agent as `:working`, so the scheduler does not assign new tasks. The task never completes, never fails, never times out.

This is an EXISTING bug, not a new one. But it becomes critical in v2.0 because:
- The routing dispatcher (line 722-728 of `index.js`) only uses direct execution when `routing.target_type !== 'wake'`. Tasks without routing decisions fall through to `wakeAgent`.
- Hub-generated tasks (from goal decomposition) may not have routing decisions if the decomposer does not set them.
- The healing state is supposed to detect and fix this -- but if the healing implementation does not know about this failure mode, it cannot fix it.

**Warning signs:**
- Task status is `working` for >30 minutes with no progress events
- Agent FSM shows `:working` but sidecar logs show no activity after `wake_skipped`
- GoalOrchestrator's `active_goals` count grows but never decreases
- `check_goal_task_progress` (line 342 of `goal_orchestrator.ex`) always returns tasks as "still pending"

**Consequences:** Agent permanently blocked. Goal never completes. If all agents hit this, the entire system halts. The Hub FSM stays in `:executing` because `active_goals > 0`, never transitions to `:resting` or `:improving`.

**Prevention:**
1. **Execution timeout on all tasks.** Every task must have a maximum execution duration. After timeout, sidecar reports `task_failed` with reason `execution_timeout`. Add a `setTimeout` in `handleTaskAssign` that fires after `config.execution_timeout_ms || 600000` (10 minutes default).
2. **Require routing_decision for all tasks.** Hub-side: GoalOrchestrator.Decomposer must attach `routing_decision` to every task. Sidecar-side: reject tasks without routing_decision (or default to `target_type: 'ollama'`).
3. **Eliminate the wake_command path for v2.0.** If all execution goes through the dispatcher (Ollama/Claude/Shell), the wake_command path becomes dead code. Remove it or gate it behind an explicit feature flag.
4. **Hub-side task timeout.** The hub already has a 60-second acceptance timeout in AgentFSM (line 39). Add an execution timeout: if a task is in `:working` state for >N minutes, reclaim it. This is a healing action.

**Detection:** Health check: query all tasks in `working` status with `duration > threshold`. Alert on any. The existing `gather_system_state/0` should include `stale_working_tasks_count`.

**Phase to address:** Pipeline reliability phase. This is the highest-priority reliability fix -- it is a bug that exists TODAY.

**Confidence:** HIGH. The code path is visible in `index.js` lines 96-104. The comment "agent expected to self-start" acknowledges the gap.

---

### Pitfall 8: Ollama Replacing ClaudeClient on Hub Side -- Prompt Format Mismatch

**What goes wrong:** The hub's `ClaudeClient.Cli` constructs prompts specifically for Claude Code CLI's capabilities: it passes `-p` flag for prompt, `--output-format stream-json`, and `--model sonnet`. The prompts in `Decomposer` and `Verifier` are written for Claude's instruction-following quality. Replacing Claude with Qwen3 8B for hub-side operations (decomposition, verification, improvement scanning) produces dramatically different results because:
- Qwen3 8B follows instructions less precisely than Claude Sonnet
- Claude's context window is 200K tokens; Qwen3 8B is 32K tokens (with effective quality at ~16K for quantized)
- Claude's structured output quality is significantly higher
- Prompts tuned for Claude may not work with Qwen3 8B (different system prompt conventions, different tool-calling syntax)

**Why it happens in THIS codebase:** The `ClaudeClient` GenServer is the hub's LLM interface. All three hub operations flow through it: `decompose_goal/2`, `verify_completion/2`, `identify_improvements/2`. The prompts inside `ClaudeClient.Cli.invoke/3` are authored for Claude. Simply swapping the backend to Ollama while keeping the same prompts will produce degraded output.

**Warning signs:**
- Goal decomposition produces 1-2 vague tasks instead of 3-5 specific ones
- Verification always returns `:pass` because the model cannot follow the structured verification rubric
- Improvement scanning returns generic suggestions not grounded in actual code
- JSON parsing fails because Qwen3 8B outputs markdown-wrapped JSON (```json ... ```) instead of raw JSON

**Consequences:** Hub decision quality drops. Goals are poorly decomposed. Verification is unreliable. The system technically works but produces low-quality results.

**Prevention:**
1. **Separate hub-side and sidecar-side LLM concerns.** Hub operations (decomposition, verification) may need to stay on Claude API if quality requirements demand it. Sidecar task execution can use Ollama. These are different use cases with different quality bars.
2. **If migrating hub to Ollama:** Re-write all prompts for Qwen3 8B. Shorter, more explicit instructions. Include JSON format examples in every prompt. Use Ollama's `format: "json"` parameter to force JSON output.
3. **Structured output via Ollama.** Use Ollama's structured output capability (`format` parameter with JSON schema) instead of hoping the model outputs valid JSON. This eliminates the markdown-wrapped JSON problem.
4. **Evaluation before migration.** Run 20 representative goal decompositions through both Claude and Qwen3 8B. Compare: task count, task specificity, file reference accuracy, JSON validity rate. Set a quality threshold -- if Qwen3 8B falls below, keep Claude for hub operations.
5. **Hybrid approach.** Use Ollama for low-stakes operations (improvement scanning triage) and Claude for high-stakes operations (goal decomposition, verification). The CostLedger already tracks per-state budgets, so this maps naturally.

**Detection:** A/B comparison metrics: decomposition quality score, verification accuracy, improvement relevance score. Track over time as prompts are tuned.

**Phase to address:** LLM backend migration phase. Prompt rewriting is the majority of the work, not the API integration.

**Confidence:** HIGH. Model capability differences are well-documented. The Ryz Labs article on LLM tuning mistakes (2025) emphasizes: "Test relentlessly with your actual data before going live."

---

### Pitfall 9: Agent Self-Awareness Creating Identity Confusion in pm2

**What goes wrong:** Making agents self-aware of their process management (knowing they are managed by pm2, knowing their own agent_id, being able to request restarts) creates a feedback loop risk. If the sidecar can detect its own unhealthy state and trigger a pm2 restart, and the restart condition is still present after restart (e.g., hub unreachable), the agent enters a restart loop. pm2's `max_restarts: 50` (line 34 of `ecosystem.config.js`) means 50 rapid restarts before pm2 gives up.

**Why it happens in THIS codebase:** The sidecar currently has no self-awareness. It connects, processes tasks, and relies on pm2 for lifecycle management. Adding self-awareness means the sidecar could:
- Detect it has been in `working` state for too long and self-restart
- Detect Ollama is unresponsive and request a restart
- Detect memory usage above threshold and exit
- Report its own health status to the hub

Each of these is individually reasonable. But combined with pm2's autorestart, they create complex restart dynamics.

**Warning signs:**
- pm2 logs show rapid restart cycles: `restart_count` climbing quickly
- Hub sees agent disconnect/reconnect events every few seconds
- Agent's recovering task is repeatedly reported and reassigned
- `_queue.recovering` is always populated (sidecar crashes during task execution, task moves to recovering, sidecar restarts, reports recovery, gets reassigned, crashes again)

**Consequences:** Agent becomes permanently unstable. Hub wastes time on recovery protocol for every restart. Task assigned to the agent is repeatedly failed and reassigned, consuming retry budget.

**Prevention:**
1. **Self-awareness is read-only.** The sidecar can observe its own state (memory, CPU, connection status, task duration) and REPORT it to the hub. It does NOT take corrective action itself. Corrective action is the hub's responsibility (via the healing state).
2. **No self-restart.** The sidecar never calls `process.exit()` based on its own health assessment. It reports unhealthy status to the hub, and the hub decides whether to reassign the task or ask the agent to restart.
3. **Crash budget.** Track restarts within a window. If the sidecar has restarted 3 times in 5 minutes, enter a "degraded" mode: connect to hub, report degraded status, refuse new tasks, wait for manual intervention.
4. **Health reporting via existing resource_report.** The sidecar already sends `resource_report` messages every 30 seconds (lines 956-968 of `index.js`). Extend this with self-awareness metrics: `task_duration_ms`, `restart_count`, `last_error`. No new protocol messages needed.
5. **Hub-driven lifecycle.** If the hub detects an agent is unhealthy (via resource reports or healing state analysis), it sends a `restart_requested` message. The sidecar cleanly shuts down, pm2 restarts it. This is unidirectional: hub commands, sidecar obeys.

**Detection:** pm2's restart count visible in `pm2 jlist`. Hub tracks agent reconnection frequency. Alert if reconnections exceed 3 per hour.

**Phase to address:** Agent self-awareness phase. Design the self-awareness scope BEFORE implementing any of it.

**Confidence:** MEDIUM. The restart loop is a known pm2 pattern, but the specific interaction with hub recovery protocol is unique to this architecture.

---

### Pitfall 10: Ollama Tool-Calling Response Format Differs from Text Response Format

**What goes wrong:** The current `OllamaExecutor._streamChat` (lines 129-232) expects every NDJSON chunk to have `parsed.message.content`. When tool calling is enabled, the response format changes: `message.content` is empty (or absent), and `message.tool_calls` is present instead. The existing parser will collect empty strings as the "full response", produce an output of `""`, and report success with empty output.

**Why it happens in THIS codebase:** The streaming parser (lines 165-198) has this logic:
```javascript
if (parsed.message && parsed.message.content) {
  fullResponse += parsed.message.content;
}
```
When Ollama returns a tool-calling response, `parsed.message.content` is `""` (empty string), which is falsy in JavaScript. The content is never collected. The `tool_calls` array is never checked. The response resolves with `{ fullResponse: '', tokensIn: N, tokensOut: M }`.

This is not a hypothetical -- it is exactly what will happen with the current code when tools are added to the request.

**Warning signs:**
- Task completes with `status: 'success'` but `output: ''`
- Token counts are non-zero (the model DID generate output), but output is empty
- No errors in logs (the parser did not fail, it just collected nothing)

**Consequences:** Tasks appear to succeed but produce no useful output. The verification loop may pass the empty output. The hub records the task as complete with empty results.

**Prevention:**
1. **Detect tool_calls in streaming response.** Add a check: `if (parsed.message && parsed.message.tool_calls)`. When detected, accumulate tool calls in a separate array. This is the fundamental change needed.
2. **New response shape.** The executor's return value needs a new field: `tool_calls: []` alongside `output`. The dispatcher must handle this new shape.
3. **Non-empty output assertion.** After streaming completes, if both `fullResponse === ''` AND `tool_calls.length === 0`, treat as an error, not success. The model produced nothing usable.
4. **Separate streaming parsers.** Create `_streamToolChat` for tool-calling conversations (multi-turn) and keep `_streamChat` for text-only tasks. Do not try to make one parser handle both -- the control flow is fundamentally different (one-shot vs. loop).

**Detection:** Assert in the executor: if tokens_out > 0 but output is empty and no tool_calls, log an error and return failure.

**Phase to address:** Agentic tool-calling phase. This is the first integration task -- before any tool execution logic.

**Confidence:** HIGH. The code path is unambiguous. Lines 186-190 of ollama-executor.js will produce empty output for tool-calling responses.

---

## Minor Pitfalls

Mistakes that cause inconvenience or need small fixes.

---

### Pitfall 11: VRAM Exhaustion During Tool-Calling Conversations

**What goes wrong:** Each round of tool calling adds to the conversation history sent to Ollama. With a 32K context window and 12GB VRAM, the conversation history for a 10-round tool-calling session can exhaust available context. Ollama will either truncate the conversation (losing earlier context) or return an error.

**Prevention:**
1. Summarize previous tool results instead of including full output. `read_file` result of 200 lines -> summary of 5 lines for conversation history.
2. Monitor `prompt_eval_count` per round. If approaching 24K tokens (75% of 32K), force final response.
3. Consider Qwen3 8B with `num_ctx: 32768` explicitly set in Ollama model parameters.

**Phase to address:** Agentic tool-calling phase.

**Confidence:** MEDIUM. Depends on actual task complexity and tool output sizes.

---

### Pitfall 12: Healing State Masking Real Failures

**What goes wrong:** The healing state automatically resolves problems (cancels hung tasks, reclaims from unresponsive agents). But some "problems" are symptoms of real bugs: a task hangs because of a deadlock in the executor, an agent is unresponsive because of a memory leak. Healing clears the symptom (cancels the task) but the root cause persists. The same task will hang again when re-assigned.

**Prevention:**
1. Track healing actions per task/agent. If the same task requires healing 3 times, mark it as `needs_investigation` instead of re-queuing.
2. Track healing actions per agent. If the same agent triggers healing 3 times in an hour, mark it as degraded and stop assigning work.
3. Log healing actions with enough context for post-mortem: which task, which agent, what state, how long stuck.

**Phase to address:** Hub FSM Healing state phase.

**Confidence:** MEDIUM. Standard observability concern.

---

### Pitfall 13: Race Between Task Execution Timeout and Task Completion

**What goes wrong:** Adding execution timeouts (to fix Pitfall 7) creates a race condition: the sidecar's timeout fires and sends `task_failed`, but the Ollama response arrives milliseconds later. The sidecar tries to send `task_complete` after already sending `task_failed`. The hub receives both messages and must handle the conflict.

**Prevention:**
1. Use a flag: `let completed = false`. Set on first resolution (success or timeout). Ignore subsequent events.
2. Clear the timeout timer in the success path before sending task_complete.
3. Hub-side: if `task_complete` arrives for a task already in `failed` status, log a warning but accept the result (last writer wins, and success is better than failure).

**Phase to address:** Pipeline reliability phase.

**Confidence:** HIGH. Classic async race condition.

---

### Pitfall 14: Ollama Server Restart Invalidating In-Flight Requests

**What goes wrong:** Ollama server restarts (model reload, OOM, manual restart) kill any in-flight `/api/chat` requests. The OllamaExecutor's retry logic (lines 28-76) retries the failed request, but if the model is still loading (Ollama loads models on first request after restart), the retry hits a timeout. All retries exhaust before the model finishes loading.

**Prevention:**
1. Add Ollama health check before task execution: `GET /api/tags` to verify Ollama is responding.
2. Increase retry delays for Ollama: current delays are minimal (no backoff). Add 10s, 20s, 30s backoff for Ollama model loading time.
3. Pre-load the model: `POST /api/generate {"model": "qwen3:8b", "keep_alive": "24h"}` on sidecar startup.

**Phase to address:** Pipeline reliability phase.

**Confidence:** MEDIUM. Depends on Ollama restart frequency.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation | Severity |
|---|---|---|---|
| **Agentic Tool Calling** | Infinite loop (P1) | Hard cap at 10 rounds + wall-clock timeout + token budget | Critical |
| **Agentic Tool Calling** | Tool execution sandbox escape (P2) | Allowlist tools, path canonicalization, no shell:true | Critical |
| **Agentic Tool Calling** | Qwen3 8B hallucinated tool calls (P5) | Strict validation, minimize tool count, think mode | Critical |
| **Agentic Tool Calling** | Empty output from tool-call responses (P10) | Detect tool_calls in parser, separate streaming paths | Moderate |
| **Agentic Tool Calling** | VRAM exhaustion in multi-round (P11) | Summarize tool results, monitor token count | Minor |
| **Hub FSM Healing** | Healing cascade storm (P3) | Cooldown timer, attempt limit, synchronous actions | Critical |
| **Hub FSM Healing** | Missing predicate/transition coverage (P6) | Enumerate all touch points, compile-time state list | Moderate |
| **Hub FSM Healing** | Masking real failures (P12) | Per-task/per-agent healing counters | Minor |
| **LLM Backend Migration** | Silent output loss from format mismatch (P4) | Adapter pattern, response validation, integration test | Critical |
| **LLM Backend Migration** | Prompt quality degradation (P8) | Separate hub/sidecar concerns, prompt rewriting, evaluation | Moderate |
| **Pipeline Reliability** | No-wake_command permanent hang (P7) | Execution timeout, require routing_decision | Critical |
| **Pipeline Reliability** | Timeout/completion race (P13) | Completion flag, timer cleanup | Minor |
| **Pipeline Reliability** | Ollama restart invalidating requests (P14) | Health check, backoff, model pre-load | Minor |
| **Agent Self-Awareness** | Restart loop with pm2 (P9) | Read-only self-awareness, hub-driven lifecycle | Moderate |

---

## Integration Pitfalls Specific to Existing Architecture

### Tool-Calling Loop vs. Single-Task Queue Model

The sidecar's queue model is `max 1 active + 1 recovering` (line 81 of `index.js`). A tool-calling loop that takes 14 minutes for 10 rounds blocks the entire sidecar for that duration. The hub may timeout the agent's acceptance window for a subsequent task before the current one completes. Consider: should tool-calling tasks have a different timeout profile? The current `confirmation_timeout_ms` (30 seconds) and implicit execution expectations are calibrated for text-only responses.

### CostLedger Budget Checks with Ollama

The existing `CostLedger.check_budget/1` (called on line 133 of `claude_client.ex`) gates LLM calls based on hub state budgets. If hub operations move to Ollama (local, zero API cost), the budget checks become meaningless for cost but still serve as rate limiters. Decide: should the CostLedger track Ollama calls for rate limiting even though they are free? The answer is yes -- GPU time and electricity are finite resources even if there is no per-token API cost.

### HubFSM @valid_transitions Asymmetry

The current transition map has asymmetric paths:
- `:resting` -> `[:executing, :improving]` (cannot go directly to `:contemplating`)
- `:improving` -> `[:resting, :executing, :contemplating]` (can go to `:contemplating`)

Adding `:healing` must decide: can ANY state transition to `:healing`? Or only specific states? If `:executing` -> `:healing` is valid but `:improving` -> `:healing` is not, a problem detected during improvement scanning cannot trigger healing. Recommendation: `:healing` should be reachable from ALL active states (`:executing`, `:improving`, `:contemplating`) but NOT from `:resting` (nothing to heal if resting).

### Existing Test Suite Fragility

The test suite already had 300+ failures from HubFSM cascading crashes (commit b2f9fa6). Adding a 5th state and tool-calling will require updating many tests. The risk is not the new features failing tests -- it is the new features making existing tests flaky by changing timing, adding PubSub events, or altering GenServer state shapes. Run the full test suite after each incremental change, not just at the end.

### Dispatcher Target Type Expansion

The `dispatcher.js` switch statement (lines 34-72) handles `'ollama'`, `'claude'`, and `'sidecar'`. If tool-calling execution requires a different dispatch path (e.g., `'ollama_agentic'` vs. `'ollama'` for simple text), a new case is needed. Alternatively, tool-calling vs. text-only can be determined within OllamaExecutor based on whether `task.tools` is defined.

---

## Sources

- [Ollama Tool Calling Documentation](https://docs.ollama.com/capabilities/tool-calling)
- [Ollama Streaming Tool Calling Blog](https://ollama.com/blog/streaming-tool)
- [Qwen3 on Ollama](https://ollama.com/library/qwen3)
- [Qwen3 Function Calling Docs](https://qwen.readthedocs.io/en/latest/framework/function_call.html)
- [Docker Blog: Local LLM Tool Calling Evaluation](https://www.docker.com/blog/local-llm-tool-calling-a-practical-evaluation/)
- [LLM Tool-Calling in Production: Rate Limits, Retries, and Infinite Loops (Medium, Jan 2026)](https://medium.com/@komalbaparmar007/llm-tool-calling-in-production-rate-limits-retries-and-the-infinite-loop-failure-mode-you-must-2a1e2a1e84c8)
- [Agentic Resource Exhaustion: The Infinite Loop Attack (Medium, Feb 2026)](https://medium.com/@instatunnel/agentic-resource-exhaustion-the-infinite-loop-attack-of-the-ai-era-76a3f58c62e3)
- [Preventing Infinite Loops and Cost Spirals in Agent Deployments](https://codieshub.com/for-ai/prevent-agent-loops-costs)
- [Self-Healing Patterns for Distributed Systems (GeeksforGeeks)](https://www.geeksforgeeks.org/computer-networks/important-self-healing-patterns-for-distributed-systems/)
- [Handling Failures in Distributed Systems: Patterns and Anti-Patterns (Statsig)](https://www.statsig.com/perspectives/handling-failures-in-distributed-systems-patterns-and-anti-patterns)
- [State Machine State Explosion (Statecharts)](https://statecharts.dev/state-machine-state-explosion.html)
- [When Dev and Prod LLM Backends Don't Match (Medium, Dec 2025)](https://medium.com/@michael.hannecke/when-your-dev-and-prod-llm-backends-dont-match-and-why-that-s-okay-3bf2cb1c55c2)
- [7 Common Mistakes When Tuning LLMs for Commercial Use (Ryz Labs)](https://learn.ryzlabs.com/llm-development/7-common-mistakes-when-tuning-llms-for-commercial-use)
- [Qwen3 8B Tool Calling Issues (SGLang GitHub)](https://github.com/sgl-project/sglang/issues/18102)
- [Ollama API Documentation (GitHub)](https://github.com/ollama/ollama/blob/main/docs/api.md)

---
*Pitfalls research for: v2.0 Agentic Tool Calling, Hub FSM Healing, Pipeline Reliability*
*Researched: 2026-02-14*
