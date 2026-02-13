# Phase 26: Claude API Client - Research

**Researched:** 2026-02-13
**Domain:** Elixir GenServer wrapping Claude Code CLI for structured LLM calls
**Confidence:** HIGH

## Summary

Phase 26 wraps the Claude Code CLI (`claude -p`) in a GenServer that provides the hub's three core LLM operations: goal decomposition, completion verification, and improvement identification. The GenServer serializes CLI invocations, checks CostLedger budget before each call, records invocations after completion, and parses structured responses.

The recommended approach uses `System.cmd/3` (not Ports) for invocation because each call is a discrete request-response with no interactive I/O needed. System.cmd blocks the calling process, which is acceptable when wrapped in a GenServer that serializes requests or delegates to Task.async for timeout control. The Claude Code CLI's `--output-format json` mode returns structured JSON with a `.result` field containing the text response, plus metadata like `session_id` and `duration_ms`.

A critical discovery: stdin piping of large prompts (>7000 chars) to `claude -p` can produce empty output (known bug, closed as not-planned). The recommended workaround is writing prompts to a temp file and referencing the file path in the CLI invocation, or using `--append-system-prompt-file` for system-level instructions.

**Primary recommendation:** Use System.cmd/3 with `--output-format json` for each invocation, wrapped in Task.async with configurable timeouts. Serial execution through GenServer call queue. Write large prompts to temp files to avoid the stdin size limitation.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Spawn `claude -p` as a System.cmd/Port process
- Pipe prompt via stdin: `echo "$prompt" | claude -p --output-format text`
- Parse text output (format depends on prompt -- JSON, XML, or plain text)
- Handle timeouts, crashes, and empty responses
- Serialize requests through GenServer (one at a time, or configurable concurrency)
- Track invocations with CostLedger before each call
- Configurable timeout per invocation (Claude Code sessions can be slow)
- Support multiple use cases: decomposition, verification, improvement identification
- Each use case has a prompt template that produces parseable output
- Depends on Phase 25 (CostLedger) for budget enforcement
- Must check CostLedger before every CLI invocation
- Claude Code CLI must be installed on the hub machine
- Max plan usage limits apply -- cannot make unlimited calls

### Claude's Discretion
- Concurrency model (serial vs bounded parallel CLI spawns)
- Prompt template structure and storage
- Response parsing strategy
- Error handling and retry policy
- Whether to use System.cmd vs Port for CLI invocation

### Deferred Ideas (OUT OF SCOPE)
None specified.
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| System.cmd/3 | stdlib | Execute `claude -p` CLI | Built-in, no deps, discrete request-response pattern fits perfectly |
| Task | stdlib | Timeout wrapper around System.cmd | Enables configurable timeouts without blocking GenServer indefinitely |
| GenServer | stdlib | Request serialization and state management | Standard OTP pattern, matches all other AgentCom GenServers |
| Jason | ~> 1.4 | Parse JSON output from `--output-format json` | Already in deps, standard Elixir JSON library |
| Saxy | ~> 1.6 | Parse XML responses when prompts request XML output | Already in deps, used by AgentCom.XML |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| AgentCom.CostLedger | existing | Budget check before each invocation | Every call path |
| AgentCom.Config | existing | Runtime configuration (timeouts, model, CLI path) | Startup and per-call |
| AgentCom.XML | existing | Decode XML responses from Claude | When prompts produce XML output |
| :telemetry | existing | Emit invocation events | Every call path |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| System.cmd | Port.open | Port gives streaming and interactive I/O, but adds complexity for a simple request-response pattern. Port is needed only if we want to stream partial responses. |
| System.cmd | :os.cmd | Lower-level, no argument safety, vulnerable to injection. System.cmd is strictly safer. |
| Temp file prompt | stdin pipe | stdin pipe is simpler but has known 7000-char limit bug. Temp files are more reliable for large prompts. |

**Installation:** No new deps needed. All libraries already in mix.exs.

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  claude_client.ex           # GenServer + public API
  claude_client/
    prompt.ex                # Prompt template builder
    response.ex              # Response parsing (JSON/XML/text)
    cli.ex                   # Low-level CLI invocation (System.cmd wrapper)
```

### Pattern 1: GenServer Request Serialization
**What:** ClaudeClient GenServer serializes all LLM calls through its mailbox. Each `handle_call` checks CostLedger, invokes CLI, records invocation, and returns parsed result.
**When to use:** Default mode -- all three use cases (decompose, verify, identify_improvements).
**Example:**
```elixir
# ClaudeClient GenServer
def handle_call({:invoke, prompt_type, params}, from, state) do
  case AgentCom.CostLedger.check_budget(state.hub_state) do
    :budget_exhausted ->
      {:reply, {:error, :budget_exhausted}, state}
    :ok ->
      # Delegate to Task for timeout control
      task = Task.async(fn -> do_invoke(prompt_type, params, state) end)
      case Task.yield(task, state.timeout_ms) || Task.shutdown(task) do
        {:ok, result} ->
          record_invocation(prompt_type, result, state)
          {:reply, result, state}
        nil ->
          {:reply, {:error, :timeout}, state}
      end
  end
end
```

### Pattern 2: Temp File Prompt Strategy
**What:** Write the full prompt to a temp file, pass it to Claude via `--system-prompt-file` or as a file reference in the query argument. Avoids the stdin >7000 char limitation.
**When to use:** All invocations (defensive approach), or only when prompt exceeds a threshold.
**Example:**
```elixir
defp do_invoke(prompt_type, params, state) do
  prompt = Prompt.build(prompt_type, params)
  tmp_path = write_temp_prompt(prompt)

  try do
    {output, exit_code} = System.cmd(
      state.cli_path,
      ["-p", "Read and follow instructions in #{tmp_path}",
       "--output-format", "json",
       "--model", state.model,
       "--no-session-persistence",
       "--dangerously-skip-permissions"],
      env: [{"CLAUDECODE", nil}],  # Unset to allow nested invocation
      stderr_to_stdout: true
    )
    Response.parse(output, exit_code, prompt_type)
  after
    File.rm(tmp_path)
  end
end
```

### Pattern 3: Prompt Template Module
**What:** Each use case (decomposition, verification, improvement identification) has a dedicated prompt builder function that produces structured prompts requesting parseable output.
**When to use:** Every LLM call.
**Example:**
```elixir
defmodule AgentCom.ClaudeClient.Prompt do
  def build(:decompose, %{goal: goal, context: context}) do
    """
    You are decomposing a goal into executable tasks.

    <goal>
    #{goal_to_xml(goal)}
    </goal>

    <context>
    #{context}
    </context>

    Respond with XML containing a <tasks> element with 3-8 <task> children.
    Each task must have: title, description, success-criteria, depends-on (list of task indices).
    """
  end

  def build(:verify, %{goal: goal, results: results}) do
    # ...verification prompt template
  end

  def build(:identify_improvements, %{repo: repo, diff: diff}) do
    # ...improvement identification prompt template
  end
end
```

### Pattern 4: Response Parsing with Type Discrimination
**What:** Parse JSON wrapper from `--output-format json`, then parse the inner text content based on expected format (XML, JSON, or plain text) depending on the prompt type.
**When to use:** Every response.
**Example:**
```elixir
defmodule AgentCom.ClaudeClient.Response do
  def parse(raw_output, 0, prompt_type) do
    case Jason.decode(raw_output) do
      {:ok, %{"result" => result}} ->
        parse_inner(result, prompt_type)
      {:ok, %{"error" => error}} ->
        {:error, {:claude_error, error}}
      {:error, _} ->
        {:error, {:parse_error, "invalid JSON wrapper"}}
    end
  end

  def parse(_raw_output, exit_code, _prompt_type) do
    {:error, {:exit_code, exit_code}}
  end

  defp parse_inner(text, :decompose) do
    # Extract XML from response text, decode with Saxy
    case extract_xml(text, "tasks") do
      {:ok, xml} -> parse_task_list(xml)
      {:error, _} = err -> err
    end
  end
end
```

### Anti-Patterns to Avoid
- **Blocking GenServer indefinitely:** Never call System.cmd directly in handle_call without timeout. Always use Task.async + Task.yield for timeout control.
- **Piping large prompts via stdin:** Known Claude CLI bug causes empty output with >7000 chars via stdin. Use temp files.
- **Hardcoding CLI path:** Store in Config for testability and platform portability.
- **Skipping CostLedger check:** Every code path must check budget before invocation.
- **Retrying without backoff:** Claude Code CLI calls are expensive. Use exponential backoff or fixed delay between retries.
- **Not unsetting CLAUDECODE env var:** Claude Code refuses to run inside another Claude Code session. Must unset the `CLAUDECODE` environment variable when spawning.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON parsing | Custom string parsing | Jason.decode/1 | Already in deps, handles edge cases |
| XML parsing | Regex extraction | AgentCom.XML.decode/2 + Saxy | Already built for this project, handles escaping |
| Timeout management | Process.sleep + kill | Task.async + Task.yield + Task.shutdown | Built-in OTP pattern, handles process cleanup |
| Budget enforcement | Manual counter | CostLedger.check_budget/1 | Already implemented in Phase 25 |
| Temp file lifecycle | Manual create/delete | File.write! + try/after File.rm | Elixir stdlib, ensures cleanup even on crash |

**Key insight:** This phase is primarily a coordination layer -- it wires together existing infrastructure (CostLedger, XML, Config, Telemetry) around a CLI invocation. Most complexity lives in prompt templates and response parsing, not in infrastructure.

## Common Pitfalls

### Pitfall 1: CLAUDECODE Environment Variable Blocking Nested Invocations
**What goes wrong:** Claude Code CLI sets `CLAUDECODE` environment variable. If the hub process itself was started by Claude Code (e.g., during development), spawning `claude -p` inside it will fail with "Claude Code cannot be launched inside another Claude Code session."
**Why it happens:** Environment inheritance from parent process.
**How to avoid:** Always pass `env: [{"CLAUDECODE", nil}]` to System.cmd/3 to unset the variable in the child process environment.
**Warning signs:** "cannot be launched inside another Claude Code session" error in logs.

### Pitfall 2: Stdin Size Limitation (>7000 chars)
**What goes wrong:** Claude CLI returns empty output (exit code 0) when stdin exceeds approximately 7000 characters.
**Why it happens:** Known bug in Claude Code CLI, closed as not-planned (Feb 2026).
**How to avoid:** Write prompts to temp files and reference them via the CLI query argument or `--system-prompt-file` flag. Never pipe large prompts via stdin.
**Warning signs:** Empty string result with exit code 0, no error output.

### Pitfall 3: System.cmd Blocking Without Timeout
**What goes wrong:** System.cmd blocks indefinitely if Claude Code CLI hangs or takes very long.
**Why it happens:** System.cmd has no built-in timeout. Claude Code sessions can take minutes.
**How to avoid:** Wrap System.cmd call in Task.async, use Task.yield/2 with configurable timeout, Task.shutdown/1 on timeout.
**Warning signs:** GenServer handle_call timeout (default 5s), caller process exits.

### Pitfall 4: Windows Port Hanging
**What goes wrong:** On Windows, System.cmd can hang when the child process closes stdout without exiting.
**Why it happens:** Erlang/OTP issue with Windows port handling (erlang/otp#8324, fixed upstream).
**How to avoid:** Ensure Erlang/OTP version includes the fix. Use the Task.async timeout pattern as a safety net regardless.
**Warning signs:** Process hangs after Claude Code has finished writing output.

### Pitfall 5: Not Recording Failed Invocations in CostLedger
**What goes wrong:** If you only record successful invocations, budget tracking becomes inaccurate. A call that timed out or errored still consumed an API invocation.
**Why it happens:** Recording only in the success path.
**How to avoid:** Always call CostLedger.record_invocation/2 after any CLI invocation attempt, regardless of outcome. Include the error type in metadata.
**Warning signs:** Budget counts don't match actual CLI usage.

### Pitfall 6: JSON Response Parsing Fragility
**What goes wrong:** The `--output-format json` wrapper structure may vary between Claude Code versions. The inner `.result` field contains the LLM's text response, which may include markdown fences, preamble text, or partial XML.
**Why it happens:** LLMs don't always produce perfectly parseable output even when instructed.
**How to avoid:** Use lenient extraction (regex for XML tags within text, strip markdown fences, handle preamble). Validate parsed structures and return clear error types.
**Warning signs:** Parse errors on responses that "look correct" visually.

## Code Examples

### Example 1: ClaudeClient GenServer Skeleton
```elixir
defmodule AgentCom.ClaudeClient do
  use GenServer
  require Logger

  @default_timeout_ms 120_000
  @default_model "sonnet"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public API

  @spec decompose_goal(map(), map()) :: {:ok, [map()]} | {:error, term()}
  def decompose_goal(goal, context) do
    GenServer.call(__MODULE__, {:invoke, :decompose, %{goal: goal, context: context}}, call_timeout())
  end

  @spec verify_completion(map(), map()) :: {:ok, :pass | :fail, String.t()} | {:error, term()}
  def verify_completion(goal, results) do
    GenServer.call(__MODULE__, {:invoke, :verify, %{goal: goal, results: results}}, call_timeout())
  end

  @spec identify_improvements(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def identify_improvements(repo, diff) do
    GenServer.call(__MODULE__, {:invoke, :identify_improvements, %{repo: repo, diff: diff}}, call_timeout())
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)
    state = %{
      cli_path: cli_path(),
      model: default_model(),
      timeout_ms: default_timeout(),
      hub_state: :executing  # Updated by HubFSM via set_hub_state/1
    }
    Logger.info("claude_client_started")
    {:ok, state}
  end

  @impl true
  def handle_call({:invoke, prompt_type, params}, _from, state) do
    case AgentCom.CostLedger.check_budget(state.hub_state) do
      :budget_exhausted ->
        {:reply, {:error, :budget_exhausted}, state}
      :ok ->
        start = System.monotonic_time(:millisecond)
        task = Task.async(fn ->
          AgentCom.ClaudeClient.Cli.invoke(prompt_type, params, state)
        end)
        result = case Task.yield(task, state.timeout_ms) || Task.shutdown(task) do
          {:ok, result} -> result
          nil -> {:error, :timeout}
        end
        duration = System.monotonic_time(:millisecond) - start

        # Always record, even on error
        AgentCom.CostLedger.record_invocation(state.hub_state, %{
          duration_ms: duration,
          prompt_type: prompt_type
        })

        # Emit telemetry
        :telemetry.execute(
          [:agent_com, :hub, :claude_call],
          %{duration_ms: duration, count: 1},
          %{hub_state: state.hub_state, prompt_type: prompt_type}
        )

        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:set_hub_state, new_state}, _from, state) do
    {:reply, :ok, %{state | hub_state: new_state}}
  end

  defp cli_path, do: Application.get_env(:agent_com, :claude_cli_path, "claude")
  defp default_model, do: Application.get_env(:agent_com, :claude_model, @default_model)
  defp default_timeout, do: Application.get_env(:agent_com, :claude_timeout_ms, @default_timeout_ms)
  defp call_timeout, do: default_timeout() + 5_000  # GenServer.call timeout > Task timeout
end
```

### Example 2: CLI Invocation Module
```elixir
defmodule AgentCom.ClaudeClient.Cli do
  @doc "Execute claude -p with prompt, return parsed response."
  def invoke(prompt_type, params, state) do
    prompt = AgentCom.ClaudeClient.Prompt.build(prompt_type, params)
    tmp_path = write_temp_prompt(prompt)

    try do
      args = [
        "-p", "Read and follow the instructions in #{tmp_path}",
        "--output-format", "json",
        "--model", state.model,
        "--no-session-persistence"
      ]

      {output, exit_code} = System.cmd(state.cli_path, args,
        env: [{"CLAUDECODE", nil}],
        stderr_to_stdout: true
      )

      AgentCom.ClaudeClient.Response.parse(output, exit_code, prompt_type)
    after
      File.rm(tmp_path)
    end
  end

  defp write_temp_prompt(prompt) do
    tmp_dir = System.tmp_dir!()
    path = Path.join(tmp_dir, "claude_prompt_#{System.unique_integer([:positive])}.md")
    File.write!(path, prompt)
    path
  end
end
```

### Example 3: Response Parsing Module
```elixir
defmodule AgentCom.ClaudeClient.Response do
  @doc "Parse JSON wrapper and extract inner content based on prompt type."
  def parse(raw_output, exit_code, prompt_type)

  def parse("", 0, _prompt_type), do: {:error, :empty_response}

  def parse(raw_output, 0, prompt_type) do
    case Jason.decode(raw_output) do
      {:ok, %{"result" => result}} when is_binary(result) ->
        parse_inner(result, prompt_type)
      {:ok, %{"result" => %{"content" => [%{"text" => text} | _]}}} ->
        parse_inner(text, prompt_type)
      {:ok, other} ->
        {:error, {:unexpected_format, other}}
      {:error, _} ->
        # Maybe it's plain text (--output-format text fallback)
        parse_inner(raw_output, prompt_type)
    end
  end

  def parse(_raw_output, exit_code, _prompt_type) do
    {:error, {:exit_code, exit_code}}
  end

  defp parse_inner(text, :decompose) do
    case extract_xml_block(text, "tasks") do
      {:ok, xml} -> parse_task_list(xml)
      {:error, _} -> {:error, {:parse_error, "no <tasks> block found in response"}}
    end
  end

  defp parse_inner(text, :verify) do
    case extract_xml_block(text, "verification") do
      {:ok, xml} -> parse_verification(xml)
      {:error, _} -> {:error, {:parse_error, "no <verification> block found"}}
    end
  end

  defp parse_inner(text, :identify_improvements) do
    case extract_xml_block(text, "improvements") do
      {:ok, xml} -> parse_improvements(xml)
      {:error, _} -> {:error, {:parse_error, "no <improvements> block found"}}
    end
  end

  # Extract XML between opening and closing tags, handling markdown fences
  defp extract_xml_block(text, root_tag) do
    # Strip markdown code fences if present
    cleaned = Regex.replace(~r/```(?:xml)?\n?/, text, "")

    pattern = ~r/<#{root_tag}[\s>].*?<\/#{root_tag}>/s
    case Regex.run(pattern, cleaned) do
      [xml_block] -> {:ok, xml_block}
      nil -> {:error, :not_found}
    end
  end
end
```

### Example 4: Testing with Mocked CLI
```elixir
# In test, override cli_path to a test script or mock module
defmodule AgentCom.ClaudeClientTest do
  use ExUnit.Case, async: false

  setup do
    # Point CLI path to a mock script that returns canned responses
    Application.put_env(:agent_com, :claude_cli_path, "test/support/mock_claude.sh")
    on_exit(fn -> Application.delete_env(:agent_com, :claude_cli_path) end)
  end

  test "decompose_goal returns parsed task list" do
    goal = %{id: "g-001", title: "Test goal", description: "Test"}
    context = %{repo: "AgentCom", files: ["lib/agent_com/config.ex"]}
    assert {:ok, tasks} = AgentCom.ClaudeClient.decompose_goal(goal, context)
    assert is_list(tasks)
    assert length(tasks) >= 3
  end

  test "returns :budget_exhausted when CostLedger denies" do
    # Exhaust budget first
    for _ <- 1..20 do
      AgentCom.CostLedger.record_invocation(:executing, %{})
    end
    assert {:error, :budget_exhausted} = AgentCom.ClaudeClient.decompose_goal(%{}, %{})
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| HTTP API direct (Req) | Claude Code CLI (`claude -p`) | Context decision | CLI provides tool use, file access, full agentic loop in a single call |
| `--output-format text` only | `--output-format json` with `--json-schema` | Claude Code CLI current | JSON wrapper gives metadata (session_id, duration); `--json-schema` can enforce response structure |
| stdin pipe for prompts | Temp file + query reference | Known bug workaround | Avoids empty response bug with >7000 char prompts |
| Interactive mode | `-p` (print/headless) mode | Always for automation | Non-interactive, exits after response, suitable for GenServer invocation |

**Deprecated/outdated:**
- The roadmap's success criteria mention "Req with connection pooling" and "Claude Messages API" -- these are superseded by the CONTEXT.md decision to use the Claude Code CLI wrapper pattern instead of direct HTTP API calls.
- `--output-format stream-json` exists but is unnecessary for this phase since we don't need streaming; each call is a complete request-response.

## Recommendations for Discretion Areas

### Concurrency Model: Serial (Recommended)
**Recommendation:** Start with pure serial execution through GenServer call queue. One CLI invocation at a time.
**Rationale:** Claude Code CLI sessions are heavyweight (spawning a Node.js process, loading context, making API calls). Parallel invocations would compete for API rate limits and complicate budget tracking. Serial is simpler to reason about, test, and debug. If throughput becomes a bottleneck later, add bounded concurrency via a pool (e.g., `poolboy` or simple `Task.Supervisor` with max_children).

### Prompt Template Structure: Module Functions (Recommended)
**Recommendation:** Store prompt templates as module functions in `AgentCom.ClaudeClient.Prompt`, not as external files or EEx templates.
**Rationale:** Module functions are compile-time checked, can interpolate struct data safely, are testable in isolation, and follow the pattern established by the XML schema modules. If templates need to change without recompilation, they can be moved to Config later.

### Response Parsing Strategy: XML in JSON Wrapper (Recommended)
**Recommendation:** Use `--output-format json` for the outer wrapper (gives metadata), instruct the LLM to produce XML in the response text (gives structured parsing via existing Saxy infrastructure).
**Rationale:** The project already has a mature XML parsing pipeline (Saxy, AgentCom.XML.Parser, schema structs). Asking Claude to produce XML responses and parsing them with existing infrastructure is the path of least resistance. The JSON wrapper from `--output-format json` provides session metadata and error information.

### Error Handling and Retry Policy: Fail-Fast with Caller Retry (Recommended)
**Recommendation:** ClaudeClient returns errors immediately. No automatic retries within the GenServer. Let the caller (HubFSM, GoalDecomposer, etc.) decide retry policy based on error type.
**Rationale:** Different callers have different retry budgets and strategies. The HubFSM may want to retry decomposition once but give up on verification failures. Embedding retry logic in ClaudeClient would couple it to caller-specific policies. Return typed errors (`:budget_exhausted`, `:timeout`, `:empty_response`, `:parse_error`, `{:exit_code, n}`) so callers can make informed decisions.

### System.cmd vs Port: System.cmd (Recommended)
**Recommendation:** Use System.cmd/3, not Port.open/2.
**Rationale:** Each Claude CLI call is a discrete request-response. We don't need streaming, interactive I/O, or partial output processing. System.cmd is simpler, safer (argument list prevents injection), and sufficient. The timeout limitation is addressed by wrapping in Task.async. Port would only be needed if we wanted to stream partial responses, which is out of scope.

## Open Questions

1. **Exact `--output-format json` response structure**
   - What we know: Contains `.result` field with text, `.session_id`, and metadata. The `--json-schema` flag can enforce inner response structure.
   - What's unclear: Exact field names and nesting. Documentation is sparse; some sources say `result` is a string, others show `result.content[].text` nesting.
   - Recommendation: Build the response parser with flexible extraction -- try `result` as string first, then try `result.content[0].text`, fail gracefully. Validate with a real CLI call early in implementation.

2. **`--json-schema` flag reliability**
   - What we know: The `--json-schema` flag can enforce structured output conforming to a JSON Schema definition.
   - What's unclear: Whether it works reliably with complex schemas, and whether it conflicts with XML instructions in the prompt.
   - Recommendation: Start without `--json-schema`. Use prompt engineering to get XML output, parse with Saxy. If XML parsing proves unreliable, investigate `--json-schema` as a fallback.

3. **Windows-specific System.cmd behavior**
   - What we know: There was a known Erlang/OTP issue with Windows ports where child processes that close stdout without exiting cause hangs. A fix was submitted upstream (erlang/otp#8324).
   - What's unclear: Whether the current OTP version on this machine includes the fix. Claude CLI is at `C:\Users\nrosq\.local\bin\claude.exe`.
   - Recommendation: The Task.async timeout pattern provides a safety net regardless. Test early on Windows to confirm behavior.

4. **Hub state for CostLedger budget check**
   - What we know: CostLedger.check_budget/1 takes a hub_state atom (:executing, :improving, :contemplating).
   - What's unclear: How ClaudeClient knows the current hub state before Phase 29 (HubFSM) exists.
   - Recommendation: Accept hub_state as a GenServer state field with a `set_hub_state/1` API. Default to `:executing`. HubFSM will call `set_hub_state/1` on transitions once it exists in Phase 29.

## Sources

### Primary (HIGH confidence)
- Claude Code CLI reference: https://code.claude.com/docs/en/cli-reference - Complete flag reference for `-p`, `--output-format`, `--model`, `--json-schema`, `--system-prompt-file`, `--no-session-persistence`
- Claude Code headless docs: https://code.claude.com/docs/en/headless - Programmatic invocation patterns, stdin piping, continuation
- Elixir System.cmd docs: https://hexdocs.pm/elixir/System.html - System.cmd/3 options, return format, limitations
- Elixir Port docs: https://hexdocs.pm/elixir/Port.html - Port.open/2 options, orphan process handling, zombie prevention
- Project source: `lib/agent_com/cost_ledger.ex` - CostLedger API (check_budget/1, record_invocation/2)
- Project source: `lib/agent_com/xml/xml.ex` - XML encode/decode infrastructure
- Project source: `lib/agent_com/config.ex` - Config GenServer pattern
- Project source: `lib/agent_com/telemetry.ex` - Telemetry event catalog (already includes hub claude_call events)

### Secondary (MEDIUM confidence)
- Claude Code stdin bug: https://github.com/anthropics/claude-code/issues/7263 - Large stdin empty response bug, temp file workaround
- Windows port hang: https://github.com/elixir-lang/elixir/issues/13449 - System.cmd hang on Windows when child closes stdout without exiting
- Stream-JSON docs: https://github.com/ruvnet/claude-flow/wiki/Stream-Chaining - Stream-JSON event types and structure
- Elixir Port patterns: https://tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports/ - GenServer + Port lifecycle management

### Tertiary (LOW confidence)
- JSON response structure (result field nesting) - Multiple sources disagree on exact shape. Needs empirical validation with real CLI call.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Uses all existing deps, no new libraries needed
- Architecture: HIGH - GenServer pattern well-established in codebase, CLI invocation well-documented
- Pitfalls: HIGH - Key pitfalls (CLAUDECODE env, stdin size, timeouts) verified via official docs and issue trackers
- Response parsing: MEDIUM - JSON wrapper structure needs empirical validation
- Windows behavior: MEDIUM - Fix submitted upstream but version compatibility unconfirmed

**Research date:** 2026-02-13
**Valid until:** 2026-03-13 (30 days -- Claude Code CLI may change flags/behavior)
