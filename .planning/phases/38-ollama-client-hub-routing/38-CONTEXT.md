# Phase 38: OllamaClient + Hub LLM Routing — Discussion Context

## Approach

Build `AgentCom.OllamaClient` module as an Elixir HTTP wrapper around Ollama `/api/chat`. Then replace all `ClaudeClient.Cli` call sites with OllamaClient calls. Rewrite prompts for Qwen3 8B.

### OllamaClient Module
- Uses `:httpc` (already available, used by LlmRegistry for health probes). No new deps.
- `stream: false` for simplicity — tool calling with streaming is inconsistent (Ollama GitHub #12557).
- Returns parsed content + token counts.
- Supports `tools` parameter for future use by Hub healing.

### Hub LLM Routing Swap
- Replace calls in: `GoalOrchestrator.Decomposer`, `SelfImprovement.LlmScanner`, `Contemplation`
- These currently go through `ClaudeClient` GenServer -> `ClaudeClient.Cli.invoke/3` -> `System.cmd("claude", ["-p", ...])`
- New path: `ClaudeClient` GenServer -> `OllamaClient.chat/2` (or config-driven backend selection)

### Prompt Adaptation
- Qwen3 8B needs more explicit step-by-step instructions than Claude
- Structured output format (JSON with specific fields)
- Appropriate context windowing (smaller context window than Claude)

## Key Decisions

- **Keep ClaudeClient.Cli behind config flag** — don't delete, allow switching back if Qwen3 quality insufficient
- **ClaudeClient GenServer remains as routing layer** — config-driven backend selection (`claude_cli` or `ollama`)
- **Use `:httpc` not Req** — already proven in LlmRegistry, no new deps
- **`stream: false` for tool calling** — streaming tool calls are buggy in Ollama

## Files to Modify

- `lib/agent_com/claude_client.ex` — add backend routing
- `lib/agent_com/claude_client/cli.ex` — keep but disable by default
- NEW: `lib/agent_com/ollama_client.ex` — HTTP wrapper
- `lib/agent_com/claude_client/prompt.ex` — adapt prompts for Qwen3
- `lib/agent_com/claude_client/response.ex` — parse Ollama response format
- `config/config.exs` — add `llm_backend: :ollama` config

## Risks

- MEDIUM — Qwen3 8B may produce lower quality decompositions/improvements than Claude
- Mitigation: config flag to switch back, quality evaluation before committing

## Success Criteria

1. Hub can send chat request to Ollama /api/chat and receive parsed response with content and token counts
2. Goal decomposition produces valid task lists via OllamaClient with Qwen3 8B
3. Zero remaining `claude -p` or `ClaudeClient.Cli` calls in production code paths (still exists behind config)
4. Hub FSM completes full executing cycle using only local Ollama
