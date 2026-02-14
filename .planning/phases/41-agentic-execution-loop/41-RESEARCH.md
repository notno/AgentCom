# Phase 41: Agentic Execution Loop - Research

**Researched:** 2026-02-14
**Domain:** Multi-turn LLM tool-calling loop (ReAct pattern) with Ollama local models
**Confidence:** HIGH (internal codebase, well-defined APIs)

## Summary

Phase 41 transforms the sidecar's OllamaExecutor from a single-shot text generator into a multi-turn ReAct agent loop. The existing codebase provides all the building blocks: `tool-registry.js` exports 5 tools in Ollama format, `tool-executor.js` handles sandboxed execution with structured JSON responses, `progress-emitter.js` batches events for WebSocket delivery, and `verification-loop.js` already handles retry/partial_pass patterns.

The core work is: (1) refactor `_streamChat` to use `stream: false` and pass `tools[]`, (2) build a 3-layer output parser for tool call extraction, (3) build an agentic system prompt with few-shot examples, (4) add safety guardrails (iteration limits, repetition detection, budget checks), and (5) wire tool call events through the existing progress pipeline to the dashboard.

**Primary recommendation:** Keep the ReAct loop inside OllamaExecutor as a new `_agenticLoop` method, preserving the existing single-shot path for backward compatibility. The output parser and prompt builder should be separate modules for testability.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **Few-shot examples in system prompt** -- Qwen3 8B benefits from concrete examples
- **`stream: false` for tool calling** -- simplifies parsing, avoids Ollama streaming bugs
- **3-layer output parser** -- graceful degradation across response formats (native tool_calls > JSON-in-content > XML extraction)
- **PIPE-06 wired here** -- per-iteration budget check integrated into the loop
- **Partial results preserved** -- don't waste completed work on timeout

### Claude's Discretion
- Internal architecture of the ReAct loop (method structure, state tracking)
- Error handling strategy for malformed tool calls
- Dashboard UI layout for tool call timeline
- System prompt wording and few-shot example selection

### Deferred Ideas (OUT OF SCOPE)
- LLM output auto-correction for malformed JSON (AGENT-V2-01)
- Multi-model tool calling (AGENT-V2-03)
- Tool call caching/memoization (explicitly out of scope in requirements)
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Node.js http | built-in | Ollama API calls | Already used by OllamaExecutor |
| tool-registry.js | Phase 40 | 5 tool definitions in Ollama format | Already built, exports `getToolDefinitions()` |
| tool-executor.js | Phase 40 | Sandboxed tool execution with JSON responses | Already built, exports `executeTool(name, args, workspace)` |
| sandbox.js | Phase 40 | Path validation, command blocking | Already built, used by tool-executor |
| progress-emitter.js | Phase 20 | Batched event delivery via WebSocket | Already built, handles token batching |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| cost-calculator.js | Phase 20 | Token cost computation | Called by dispatcher after execution |
| verification-loop.js | Phase 22 | Retry loop with partial_pass | Wraps the agentic executor |

### No New Dependencies
All required infrastructure exists in the codebase. No npm packages needed.

## Architecture Patterns

### Recommended Module Structure
```
sidecar/lib/execution/
  ollama-executor.js       # MODIFY: add _agenticLoop method, keep single-shot path
  tool-call-parser.js      # NEW: 3-layer output parser
  agentic-prompt.js        # NEW: system prompt builder with few-shot examples
  progress-emitter.js      # MODIFY: pass-through tool_call events (no batching)
  verification-loop.js     # MODIFY: handle agentic partial results
  dispatcher.js            # NO CHANGE: already routes to OllamaExecutor
sidecar/test/execution/
  tool-call-parser.test.js # NEW: parser unit tests
  agentic-prompt.test.js   # NEW: prompt builder tests
  ollama-executor.test.js  # NEW: loop integration tests
```

### Pattern 1: ReAct Loop State Machine
**What:** The agentic loop maintains conversation state (messages array) and iterates until termination.
**When to use:** Every agentic task execution.

```javascript
// Pseudocode for the ReAct loop
async _agenticLoop(endpoint, model, task, onProgress, options) {
  const messages = buildInitialMessages(task);  // system + user
  const tools = getToolDefinitions();
  const maxIter = options.maxIterations;
  const history = [];  // track tool calls for repetition detection

  for (let i = 0; i < maxIter; i++) {
    // 1. Call Ollama with stream: false
    const response = await this._chatOnce(endpoint, model, messages, tools);

    // 2. Parse tool calls (3-layer parser)
    const parsed = parseToolCalls(response.message);

    if (parsed.type === 'final_answer') {
      return { output: parsed.content, ... };
    }

    if (parsed.type === 'tool_calls') {
      // 3. Check safety guardrails
      if (isRepetition(history, parsed.calls)) break;

      // 4. Execute tools, collect results
      for (const call of parsed.calls) {
        const result = await executeTool(call.name, call.arguments, workspace);
        messages.push({ role: 'assistant', content: '', tool_calls: [call] });
        messages.push({ role: 'tool', content: JSON.stringify(result) });
        onProgress({ type: 'tool_call', ... });
      }

      history.push(...parsed.calls);
    }
  }
  // Max iterations reached -- return partial results
}
```

### Pattern 2: Ollama /api/chat with Tools (Non-Streaming)
**What:** Ollama accepts `tools` array and returns `message.tool_calls` when the model wants to call a function.
**When to use:** Every iteration of the ReAct loop.

The Ollama `/api/chat` API with `stream: false` and tools:

**Request:**
```json
{
  "model": "qwen3:8b",
  "messages": [
    { "role": "system", "content": "..." },
    { "role": "user", "content": "..." }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "...",
        "parameters": { "type": "object", "properties": {...}, "required": [...] }
      }
    }
  ],
  "stream": false
}
```

**Response (tool call):**
```json
{
  "model": "qwen3:8b",
  "message": {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "function": {
          "name": "read_file",
          "arguments": { "path": "src/main.js" }
        }
      }
    ]
  },
  "done": true,
  "prompt_eval_count": 512,
  "eval_count": 48
}
```

**Response (final answer, no tools):**
```json
{
  "model": "qwen3:8b",
  "message": {
    "role": "assistant",
    "content": "I've completed the task. Here's what I did..."
  },
  "done": true,
  "prompt_eval_count": 1024,
  "eval_count": 256
}
```

**Tool result message format:**
```json
{ "role": "tool", "content": "{\"success\":true,\"tool\":\"read_file\",\"output\":{...}}" }
```

### Pattern 3: 3-Layer Output Parser
**What:** Graceful degradation across model output formats.
**When to use:** After every Ollama response.

```
Layer 1: message.tool_calls exists and is array → extract directly (preferred)
Layer 2: message.content contains JSON like {"name":"...","arguments":{...}} → regex extract
Layer 3: message.content contains <tool_call>...</tool_call> XML → XML extract (Qwen3 fallback)
None match + has content → final answer (exit loop)
None match + empty content → malformed, retry once
```

### Pattern 4: Message Threading
**What:** Ollama expects the full conversation history on each call.
**When to use:** Building the messages array for multi-turn.

```javascript
// After each tool call round:
// 1. Append assistant's response (with tool_calls)
messages.push({
  role: 'assistant',
  content: response.message.content || '',
  tool_calls: response.message.tool_calls
});

// 2. Append tool results (one per tool call)
for (const call of toolCalls) {
  messages.push({
    role: 'tool',
    content: JSON.stringify(toolResult)
  });
}
```

### Anti-Patterns to Avoid
- **Streaming with tools:** Ollama streaming + tool_calls is unreliable. Always use `stream: false` for agentic calls.
- **Unbounded message history:** Conversation grows with each iteration. For 20 iterations with verbose tool results, context can blow up. Truncate old tool results after N iterations.
- **Blocking on single tool call:** If model returns multiple tool_calls in one response, execute all of them (they're independent reads/writes).
- **Retrying on every malformed response:** Only retry once on malformed output. After that, treat content as final answer.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Tool definitions | Manual JSON construction | `tool-registry.getToolDefinitions()` | Already built, tested, matches Ollama format |
| Tool execution + sandbox | Custom file/command handlers | `tool-executor.executeTool()` | Already built with path validation, timeout, structured output |
| Progress batching | Manual WebSocket throttling | `ProgressEmitter` | Already handles token batching, non-token pass-through |
| Cost tracking | Manual token accounting | `cost-calculator.calculateCost()` | Already handles Ollama (free) vs Claude pricing |
| Verification retry | Custom retry logic | `verification-loop.executeWithVerification()` | Already handles corrective prompts, partial_pass |

**Key insight:** Phase 40 built the tool infrastructure specifically for this phase. Phase 41 is the integration layer that wires tools into the execution loop.

## Common Pitfalls

### Pitfall 1: Context Window Overflow
**What goes wrong:** After 15+ iterations, the messages array contains thousands of tokens of tool results, exceeding Qwen3 8B's 32K context.
**Why it happens:** Each tool result (especially `read_file` and `search_files`) can be large, and the full history is sent each call.
**How to avoid:** Track cumulative message token count (approximate by character count / 4). After exceeding 75% of context window (~24K tokens), summarize older tool results: keep the last 3 rounds verbatim, replace older tool results with one-line summaries.
**Warning signs:** Ollama returns empty or incoherent responses after many iterations.

### Pitfall 2: Tool Call Argument Type Mismatch
**What goes wrong:** Qwen3 8B returns string "true" instead of boolean true, or string "30000" instead of integer 30000.
**Why it happens:** Smaller models don't always respect JSON Schema types in tool definitions.
**How to avoid:** Coerce arguments before passing to tool executor: parse string numbers to integers, parse string booleans to booleans. Do this in the parser, not the executor.
**Warning signs:** Tool executor errors on type validation.

### Pitfall 3: Infinite Thinking / No Tool Calls
**What goes wrong:** Model generates lengthy "thinking" text but never actually calls tools.
**Why it happens:** Qwen3 8B sometimes enters a planning mode, especially with complex tasks. Also, Qwen3's `<think>` tags in thinking mode can confuse parsing.
**How to avoid:** If response has content but no tool calls AND content doesn't look like a final answer (no "completed", "done", etc.), nudge with "Please use the available tools to complete the task" and continue loop. Limit nudges to 2 per loop.
**Warning signs:** Multiple consecutive iterations with content-only responses.

### Pitfall 4: Partial Tool Call JSON
**What goes wrong:** Model starts a tool call JSON object but truncates mid-way through.
**Why it happens:** Token limit hit during generation, or model confusion about JSON structure.
**How to avoid:** With `stream: false`, Ollama returns the complete response. But if `eval_count` equals `num_predict` (max tokens), the response may be truncated. Check for this and retry with higher `num_predict`.
**Warning signs:** JSON.parse throws on extracted content.

### Pitfall 5: Qwen3 Thinking Mode Interference
**What goes wrong:** Qwen3 8B wraps responses in `<think>...</think>` tags, and the actual tool call is after the think block.
**Why it happens:** Qwen3 has a thinking mode that's on by default.
**How to avoid:** Strip `<think>...</think>` blocks from content before running the tool call parser. The thinking content is useful for debugging but not for parsing.
**Warning signs:** Parser finds no tool calls, but raw content has them after `</think>`.

## Code Examples

### Example 1: Non-Streaming Ollama Chat Call
```javascript
// Source: existing OllamaExecutor._streamChat pattern, adapted for stream: false
_chatOnce(endpoint, model, messages, tools) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      model,
      messages,
      tools,
      stream: false
    });

    const options = {
      hostname: endpoint.hostname,
      port: endpoint.port,
      path: '/api/chat',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body)
      },
      timeout: 120000  // 2-minute per-call timeout
    };

    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        if (res.statusCode !== 200) {
          reject(new Error(`Ollama HTTP ${res.statusCode}: ${data.slice(0, 500)}`));
          return;
        }
        try {
          resolve(JSON.parse(data));
        } catch (e) {
          reject(new Error(`Ollama response parse error: ${e.message}`));
        }
      });
    });

    req.on('timeout', () => { req.destroy(); reject(new Error('Ollama per-call timeout')); });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}
```

### Example 2: Tool Call Parser (3-Layer)
```javascript
function parseToolCalls(message) {
  // Layer 1: Native tool_calls
  if (message.tool_calls && Array.isArray(message.tool_calls) && message.tool_calls.length > 0) {
    return {
      type: 'tool_calls',
      calls: message.tool_calls.map(tc => ({
        name: tc.function.name,
        arguments: tc.function.arguments || {}
      }))
    };
  }

  let content = message.content || '';

  // Strip Qwen3 thinking blocks
  content = content.replace(/<think>[\s\S]*?<\/think>/g, '').trim();

  // Layer 2: JSON extraction from content
  const jsonPattern = /\{\s*"name"\s*:\s*"(\w+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})\s*\}/g;
  const jsonMatches = [...content.matchAll(jsonPattern)];
  if (jsonMatches.length > 0) {
    return {
      type: 'tool_calls',
      calls: jsonMatches.map(m => ({
        name: m[1],
        arguments: JSON.parse(m[2])
      }))
    };
  }

  // Layer 3: XML extraction (<tool_call> tags)
  const xmlPattern = /<tool_call>\s*\{[\s\S]*?\}\s*<\/tool_call>/g;
  const xmlMatches = [...content.matchAll(xmlPattern)];
  if (xmlMatches.length > 0) {
    const calls = xmlMatches.map(m => {
      const json = m[0].replace(/<\/?tool_call>/g, '').trim();
      const parsed = JSON.parse(json);
      return { name: parsed.name, arguments: parsed.arguments || {} };
    });
    return { type: 'tool_calls', calls };
  }

  // No tool calls found
  if (content.length > 0) {
    return { type: 'final_answer', content };
  }

  return { type: 'empty', content: '' };
}
```

### Example 3: Repetition Detection
```javascript
function isRepetition(history, newCalls, threshold = 3) {
  if (history.length < threshold) return false;

  const newKey = newCalls.map(c => `${c.name}:${JSON.stringify(c.arguments)}`).join('|');
  const recent = history.slice(-threshold);
  const recentKeys = recent.map(h =>
    h.map(c => `${c.name}:${JSON.stringify(c.arguments)}`).join('|')
  );

  return recentKeys.every(k => k === newKey);
}
```

### Example 4: Progress Event for Tool Calls
```javascript
// Emit through existing ProgressEmitter (non-token events flush immediately)
onProgress({
  type: 'tool_call',
  tool_name: call.name,
  args_summary: summarizeArgs(call.arguments),
  result_summary: summarizeResult(toolResult),
  iteration: iterationNumber,
  timestamp: Date.now()
});
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single-shot text generation | Multi-turn tool calling | Ollama 0.5+ (2025) | Models can now DO things, not just describe |
| Claude CLI shelling | Ollama HTTP API | Phase 38 | Local execution, zero API cost |
| Text output only | Structured JSON observations | Phase 40 | Reliable tool result parsing by smaller models |

**Relevant Ollama behavior:**
- Ollama's `/api/chat` with `tools` array was stabilized around v0.5
- `stream: false` returns a single JSON object (not NDJSON), simplifying parsing significantly
- Tool results go back as `role: "tool"` messages
- Qwen3 8B supports native function calling for up to ~5 tools; above that it may fall back to content-based tool calls

## Open Questions

1. **Qwen3 8B tool call quality in practice**
   - What we know: Qwen3 supports function calling, the 3-layer parser handles fallback
   - What's unclear: How reliably Qwen3 8B produces correct tool calls for multi-step tasks
   - Recommendation: Build the parser defensively, add argument coercion, log all parsing layer hits for empirical analysis

2. **Context window management at scale**
   - What we know: Qwen3 8B has 32K context, tool results can be large
   - What's unclear: Exact token overhead per iteration in practice
   - Recommendation: Start with character-count approximation, add truncation at 75% capacity, tune after real usage

3. **Optimal num_predict for tool calls**
   - What we know: Default Ollama num_predict may be too low for complex tool call JSON
   - What's unclear: Best default value for agentic calls
   - Recommendation: Set `num_predict: 2048` for tool-calling iterations (tool calls are short), `num_predict: 4096` for final answer generation

## Sources

### Primary (HIGH confidence)
- `sidecar/lib/execution/ollama-executor.js` -- existing executor, target for refactor
- `sidecar/lib/tools/tool-registry.js` -- 5 tool definitions in Ollama format
- `sidecar/lib/tools/tool-executor.js` -- sandboxed execution with structured JSON
- `sidecar/lib/execution/progress-emitter.js` -- event batching for WebSocket
- `sidecar/lib/execution/verification-loop.js` -- retry loop with partial_pass
- `sidecar/lib/execution/dispatcher.js` -- routing to executors
- `sidecar/index.js:850-910` -- progress pipeline from executor to WebSocket
- `.planning/phases/41-agentic-execution-loop/41-CONTEXT.md` -- locked decisions

### Secondary (MEDIUM confidence)
- Ollama API documentation -- tool calling format, stream: false behavior
- Qwen3 8B model card -- context window, function calling capabilities

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all components already built in codebase
- Architecture: HIGH -- clear integration points, well-defined API contracts
- Pitfalls: MEDIUM -- Qwen3 8B tool calling behavior needs empirical validation
- Output parser: MEDIUM -- 3 layers covers known formats, edge cases may surface in practice

**Research date:** 2026-02-14
**Valid until:** 2026-03-14 (stable internal codebase, no external dependency risk)
