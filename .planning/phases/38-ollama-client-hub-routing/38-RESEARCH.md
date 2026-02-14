# Phase 38: OllamaClient and Hub LLM Routing - Research

**Researched:** 2026-02-14
**Domain:** Elixir HTTP client for Ollama REST API, hub LLM backend routing
**Confidence:** HIGH

## Summary

Phase 38 replaces the Claude Code CLI (`claude -p`) backend with direct HTTP calls to local Ollama for all hub FSM LLM operations. The codebase already has a proven `:httpc` pattern in `LlmRegistry` for Ollama health checks and model discovery. The new `OllamaClient` module wraps Ollama's `/api/chat` endpoint with `stream: false`, returning parsed content and token counts. The `ClaudeClient` GenServer becomes a routing layer that dispatches to either `OllamaClient` or the existing `Cli` module based on configuration.

Three call sites need routing: `GoalOrchestrator.Decomposer` (decompose goals into tasks), `SelfImprovement.LlmScanner` (identify improvements from diffs), and `Contemplation` (generate feature proposals). All three already call through the `ClaudeClient` GenServer, so the routing change is confined to `ClaudeClient.handle_call/3`. Prompts must be adapted from XML-response-only instructions (designed for Claude) to explicit step-by-step JSON instructions suitable for Qwen3 8B.

**Primary recommendation:** Build `OllamaClient` as a stateless module with `chat/2`, route in `ClaudeClient` GenServer via config, adapt `Prompt` module to emit model-appropriate prompts, and extend `Response` module to parse Ollama's native JSON response format alongside the existing Claude JSON/XML parsing.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **Keep ClaudeClient.Cli behind config flag** -- don't delete, allow switching back if Qwen3 quality insufficient
- **ClaudeClient GenServer remains as routing layer** -- config-driven backend selection (`claude_cli` or `ollama`)
- **Use `:httpc` not Req** -- already proven in LlmRegistry, no new deps
- **`stream: false` for tool calling** -- streaming tool calls are buggy in Ollama

### Claude's Discretion
- Prompt adaptation strategy (how to restructure prompts for Qwen3 8B)
- Response parsing approach (how to handle Ollama JSON vs Claude XML)
- Config key naming and defaults
- Error handling and retry strategy for HTTP calls
- Model name configuration (hardcoded vs configurable)

### Deferred Ideas (OUT OF SCOPE)
- None explicitly listed
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `:httpc` | OTP built-in | HTTP client for Ollama API | Already used by LlmRegistry, zero dependencies |
| `Jason` | Already in mix.exs | JSON encode/decode for request/response bodies | Already used throughout codebase |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `:ssl` | OTP built-in | SSL support for httpc | Only if Ollama ever runs HTTPS (unlikely for local) |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `:httpc` | `Req` / `Finch` | Nicer API but adds dependency; not worth it for simple POST |
| `:httpc` | `Mint` | Lower-level, more control but more code; overkill |
| `stream: false` | `stream: true` | Would enable real-time token streaming but Ollama tool calling with streaming is buggy (#12557) |

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
├── ollama_client.ex          # NEW: Stateless HTTP wrapper for /api/chat
├── claude_client.ex          # MODIFY: Add backend routing in handle_call
├── claude_client/
│   ├── cli.ex                # KEEP: Existing CLI backend (behind config)
│   ├── prompt.ex             # MODIFY: Add Ollama-specific prompt variants
│   └── response.ex           # MODIFY: Add Ollama response parsing
```

### Pattern 1: Config-Driven Backend Routing
**What:** `ClaudeClient` GenServer reads `:llm_backend` config at init and dispatches to the appropriate backend module.
**When to use:** When you need to swap implementations without changing callers.
**Example:**
```elixir
# In ClaudeClient.init/1
state = %{
  backend: Application.get_env(:agent_com, :llm_backend, :ollama),
  # ... existing fields
}

# In ClaudeClient.handle_call({:invoke, prompt_type, params}, ...)
case state.backend do
  :ollama -> AgentCom.OllamaClient.invoke(prompt_type, params)
  :claude_cli -> AgentCom.ClaudeClient.Cli.invoke(prompt_type, params, state)
end
```

### Pattern 2: Ollama /api/chat Request Format
**What:** Ollama expects a specific JSON body for chat completions.
**When to use:** Every OllamaClient.chat/2 call.
**Example:**
```elixir
# Ollama /api/chat request body
%{
  "model" => "qwen3:8b",
  "messages" => [
    %{"role" => "system", "content" => "You are a goal decomposition agent..."},
    %{"role" => "user", "content" => "<goal>...</goal>"}
  ],
  "stream" => false,
  "options" => %{
    "temperature" => 0.3,
    "num_ctx" => 8192
  }
}

# Ollama /api/chat response body (stream: false)
%{
  "model" => "qwen3:8b",
  "message" => %{
    "role" => "assistant",
    "content" => "..."
  },
  "done" => true,
  "total_duration" => 12345678,
  "prompt_eval_count" => 150,
  "eval_count" => 200
}
```

### Pattern 3: :httpc POST with JSON Body
**What:** Using OTP :httpc for POST requests with JSON body and headers.
**When to use:** OllamaClient HTTP calls.
**Example:**
```elixir
# Proven pattern from LlmRegistry (adapted for POST)
url = String.to_charlist("http://#{host}:#{port}/api/chat")
headers = [{'content-type', 'application/json'}]
body = Jason.encode!(request_map)

case :httpc.request(
  :post,
  {url, headers, 'application/json', body},
  [timeout: timeout_ms, connect_timeout: 5_000],
  []
) do
  {:ok, {{_, 200, _}, _headers, response_body}} ->
    case Jason.decode(to_string(response_body)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :json_decode_error}
    end

  {:ok, {{_, status, _}, _, body}} ->
    {:error, {:http_error, status, to_string(body)}}

  {:error, reason} ->
    {:error, {:connection_error, reason}}
end
```

### Anti-Patterns to Avoid
- **Don't start a GenServer for OllamaClient:** It's a stateless HTTP wrapper. The ClaudeClient GenServer already handles serialization and budget checking. Adding another GenServer creates unnecessary bottleneck.
- **Don't parse XML from Ollama responses:** Qwen3 8B is less reliable with XML output than Claude. Switch to JSON-formatted responses for Ollama backend.
- **Don't share prompt templates between backends:** Claude and Qwen3 need fundamentally different prompt styles. Better to have separate prompt builders than a single template with conditionals.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON encoding | Custom serializer | `Jason.encode!/1` | Already in deps, battle-tested |
| HTTP client | Raw `:gen_tcp` | `:httpc` | OTP-proven, already used in codebase |
| Timeout handling | Manual timers | `Task.async` + `Task.yield` | Already used in ClaudeClient |
| Config management | Custom config module | `Application.get_env` | Standard OTP pattern |

**Key insight:** The existing ClaudeClient infrastructure (GenServer serialization, budget checking, Task-based timeout, telemetry) should be reused. OllamaClient only needs to handle the HTTP call itself.

## Common Pitfalls

### Pitfall 1: :httpc Content-Type Header Format
**What goes wrong:** `:httpc` expects charlists for headers, not binaries. Using `"content-type"` instead of `'content-type'` causes cryptic errors.
**Why it happens:** Erlang `:httpc` predates Elixir binary strings.
**How to avoid:** Always use single-quoted charlists for `:httpc` headers and URLs.
**Warning signs:** `{:error, :invalid_request}` or pattern match failures.

### Pitfall 2: Ollama Response Body as Charlist
**What goes wrong:** `:httpc` returns the response body as a charlist, not a binary string. Passing directly to `Jason.decode/1` fails.
**Why it happens:** Erlang `:httpc` works with charlists.
**How to avoid:** Always wrap with `to_string(body)` before JSON decoding. Already done in LlmRegistry.
**Warning signs:** `Jason.DecodeError` or `FunctionClauseError`.

### Pitfall 3: Qwen3 8B XML Reliability
**What goes wrong:** Qwen3 8B produces malformed XML more frequently than Claude -- unclosed tags, extra text before/after XML, mixed formats.
**Why it happens:** Smaller model with less instruction-following precision.
**How to avoid:** Switch to JSON output format for Ollama prompts. JSON is more reliably produced by smaller models. Keep XML format only for Claude CLI backend.
**Warning signs:** Frequent `{:error, {:parse_error, "no <tasks> block found"}}`.

### Pitfall 4: Ollama Connection Timeout vs Request Timeout
**What goes wrong:** LLM inference can take 30-60+ seconds for complex prompts on 8B models. Default `:httpc` timeout (30s) may be too short.
**Why it happens:** `:httpc` has separate `connect_timeout` and `timeout` options. The `timeout` covers the entire request including response wait.
**How to avoid:** Set `timeout` to match the ClaudeClient's existing timeout (120s default). Set `connect_timeout` to 5s (fast fail if Ollama is down).
**Warning signs:** Frequent `{:error, :timeout}` on longer prompts.

### Pitfall 5: Ollama Model Name Format
**What goes wrong:** Ollama model names include tags (e.g., `qwen3:8b` not `qwen3`). Using wrong name gives 404 or pulls a different model.
**Why it happens:** Ollama uses `name:tag` format where tag defaults to `latest`.
**How to avoid:** Use full model name with tag in config. Validate model availability via LlmRegistry before first call.
**Warning signs:** `{"error": "model 'qwen3' not found"}` response from Ollama.

### Pitfall 6: Thinking Mode in Qwen3
**What goes wrong:** Qwen3 models have a "thinking" mode enabled by default that wraps reasoning in `<think>...</think>` tags before the actual response.
**Why it happens:** Qwen3 models include chain-of-thought by default when no `/no_think` or explicit system prompt disabling is provided.
**How to avoid:** Either strip `<think>` blocks from the response before parsing, or disable thinking with `/no_think` suffix in user message or `"enable_thinking": false` in options if supported.
**Warning signs:** Response starts with `<think>` tag, JSON/XML parsing fails because content includes thinking text.

## Code Examples

### OllamaClient.chat/2 Core Implementation
```elixir
defmodule AgentCom.OllamaClient do
  @moduledoc "Stateless HTTP wrapper for Ollama /api/chat."
  require Logger

  @default_host "localhost"
  @default_port 11434
  @default_model "qwen3:8b"
  @default_timeout_ms 120_000

  @spec chat(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(prompt, opts \\ []) do
    host = Keyword.get(opts, :host, config(:ollama_host, @default_host))
    port = Keyword.get(opts, :port, config(:ollama_port, @default_port))
    model = Keyword.get(opts, :model, config(:ollama_model, @default_model))
    timeout = Keyword.get(opts, :timeout, config(:ollama_timeout_ms, @default_timeout_ms))
    system = Keyword.get(opts, :system, nil)
    tools = Keyword.get(opts, :tools, nil)

    messages = build_messages(system, prompt)
    body = build_body(model, messages, tools)
    url = String.to_charlist("http://#{host}:#{port}/api/chat")

    case do_post(url, body, timeout) do
      {:ok, response} -> parse_response(response)
      {:error, _} = err -> err
    end
  end

  defp config(key, default), do: Application.get_env(:agent_com, key, default)
end
```

### ClaudeClient Backend Routing
```elixir
# In handle_call({:invoke, prompt_type, params}, _from, state)
result = case state.backend do
  :ollama ->
    prompt = AgentCom.ClaudeClient.Prompt.build(prompt_type, params, :ollama)
    case AgentCom.OllamaClient.chat(prompt) do
      {:ok, %{content: content}} ->
        AgentCom.ClaudeClient.Response.parse_ollama(content, prompt_type)
      {:error, _} = err -> err
    end

  :claude_cli ->
    AgentCom.ClaudeClient.Cli.invoke(prompt_type, params, state)
end
```

### Ollama-Adapted Prompt (Decompose)
```elixir
def build(:decompose, %{goal: goal, context: context}, :ollama) do
  """
  You are a goal decomposition agent. Break down the goal into small executable tasks.

  GOAL:
  Title: #{Map.get(goal, :title, "Untitled")}
  Description: #{Map.get(goal, :description, "")}
  Success Criteria: #{Map.get(goal, :success_criteria, "")}

  CONTEXT:
  Repository: #{Map.get(context, :repo, "")}
  Available Files: #{Enum.join(Map.get(context, :files, []), ", ")}
  Constraints: #{Map.get(context, :constraints, "")}

  INSTRUCTIONS:
  1. Read the goal and context carefully
  2. Identify 3-8 tasks that together complete the goal
  3. Each task must be independently verifiable
  4. Order tasks by dependency (earlier tasks first)
  5. Use 1-based indices for depends_on references

  Respond with ONLY a JSON array. No other text. Example:
  [
    {"title": "Add user model", "description": "Create User schema", "success_criteria": "Schema compiles", "depends_on": []},
    {"title": "Add API endpoint", "description": "Create GET /users", "success_criteria": "Returns 200", "depends_on": [1]}
  ]

  /no_think
  """
end
```

### Ollama Response Parsing
```elixir
def parse_ollama(content, :decompose) do
  # Strip any <think>...</think> blocks
  cleaned = Regex.replace(~r/<think>.*?<\/think>/s, content, "")
  cleaned = String.trim(cleaned)

  # Extract JSON array
  case extract_json_array(cleaned) do
    {:ok, tasks} when is_list(tasks) ->
      parsed = Enum.map(tasks, fn t ->
        %{
          title: t["title"] || "",
          description: t["description"] || "",
          success_criteria: t["success_criteria"] || "",
          depends_on: t["depends_on"] || []
        }
      end)
      {:ok, parsed}

    {:error, reason} ->
      {:error, {:parse_error, reason}}
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Claude CLI `claude -p` | Ollama HTTP `/api/chat` | This phase | Removes external CLI dependency, faster invocation, local-only |
| XML response format | JSON response format | This phase (for Ollama) | More reliable parsing with smaller models |
| Single backend | Config-driven backend selection | This phase | Allows fallback to Claude if quality issues |

**Deprecated/outdated:**
- `ClaudeClient.Cli.invoke/3` as default backend: Still exists but config defaults to `:ollama`

## Open Questions

1. **Qwen3 8B Context Window Size**
   - What we know: Qwen3 8B has 32K context window, but practical limits may be lower for quality output
   - What's unclear: Optimal `num_ctx` setting for decomposition quality vs speed
   - Recommendation: Start with 8192, increase if decompositions are too shallow. Make configurable.

2. **Thinking Mode Handling**
   - What we know: Qwen3 includes `<think>` blocks by default
   - What's unclear: Whether `/no_think` suffix is supported in Ollama's Qwen3 integration
   - Recommendation: Strip `<think>` blocks from response regardless. Also try `/no_think` in prompt.

3. **Temperature for Structured Output**
   - What we know: Lower temperature (0.1-0.3) improves structured output reliability
   - What's unclear: Optimal temperature for decomposition creativity vs format compliance
   - Recommendation: Use 0.3 default, make configurable per prompt type.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `lib/agent_com/claude_client.ex`, `claude_client/cli.ex`, `claude_client/prompt.ex`, `claude_client/response.ex` -- current LLM call architecture
- Codebase analysis: `lib/agent_com/llm_registry.ex` lines 316-410 -- proven `:httpc` patterns for Ollama
- Codebase analysis: `lib/agent_com/goal_orchestrator/decomposer.ex` -- decomposition call site
- Codebase analysis: `lib/agent_com/self_improvement/llm_scanner.ex` -- improvement scanning call site
- Codebase analysis: `lib/agent_com/contemplation.ex` -- proposal generation call site
- Ollama API docs: `/api/chat` endpoint specification

### Secondary (MEDIUM confidence)
- Ollama GitHub issue #12557 -- streaming tool call inconsistencies (referenced in CONTEXT.md)
- Qwen3 model behavior with thinking mode -- based on model documentation

### Tertiary (LOW confidence)
- Optimal `num_ctx` and temperature values -- requires empirical testing

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- `:httpc` and Jason already proven in codebase
- Architecture: HIGH -- routing pattern is straightforward, all call sites identified
- Pitfalls: HIGH -- `:httpc` charlist issues and Ollama response format well-documented in existing code
- Prompt adaptation: MEDIUM -- Qwen3 8B behavior with structured output needs validation

**Research date:** 2026-02-14
**Valid until:** 2026-03-14 (stable domain, Ollama API unlikely to change)
