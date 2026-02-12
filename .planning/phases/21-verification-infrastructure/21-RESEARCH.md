# Phase 21: Verification Infrastructure - Research

**Researched:** 2026-02-12
**Domain:** Deterministic mechanical verification checks for task completion
**Confidence:** HIGH

## Summary

Phase 21 introduces a verification layer that runs deterministic mechanical checks after task execution and produces structured pass/fail reports. The system builds on Phase 17's `verification_steps` field (already stored on tasks as a list of `%{"type" => string, "target" => string}` maps) and will integrate with Phase 22's retry loop by providing rich failure context.

The verification engine is a pure Elixir module (`AgentCom.Verification`) that takes a task's `verification_steps` list, executes each check type deterministically, and produces a structured report. Reports are persisted in a dedicated DETS table (`verification_reports`) separately from task results, enabling queryable verification history across tasks. The four built-in check types (`file_exists`, `test_passes`, `git_clean`, `command_succeeds`) use `System.cmd/3` for shell execution where needed, with a global timeout enforced via `Task.async/await` with timeout.

**Primary recommendation:** Run all checks (no fail-fast) to maximize Phase 22 retry context, attach verification reports as metadata on the task while also persisting separately for history, include per-check timing for diagnostic value, and use typed parameter maps per check type for clarity and validation.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Deterministic mechanical verification checks that run after task execution and produce structured pass/fail reports
- Four built-in check types (file_exists, test_passes, git_clean, command_succeeds) work out of the box
- Mechanical checks run before any LLM-based judgment
- The self-verification retry loop (build-verify-fix pattern) is Phase 22
- Global timeout per verification run (not per-check)
- Timeout is configurable per task; Claude picks sensible default when submitter doesn't specify
- Each check result includes pass/fail status plus captured stdout/stderr output
- Verification reports visible inline on dashboard: green/red per check, expandable output
- Reports persisted separately from task results (queryable verification history across tasks)
- `file_exists`: checks file presence at specified path
- `git_clean`: strict -- no uncommitted changes AND no untracked files (fully clean)
- `command_succeeds`: always captures stdout + stderr in check result
- `command_succeeds` is the escape hatch for custom checks -- no plugin system
- Tasks can opt out with `skip_verification: true` flag
- Tasks with no verification_steps defined auto-pass (no checks = no failures, no warnings)

### Claude's Discretion
- Fail-fast vs run-all-checks on failure
- Verification impact on task status vs metadata-only
- Per-check timing in reports
- Default global timeout value
- test_passes auto-detection strategy
- Check parameter model design
- Check execution ordering

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir `System.cmd/3` | Built-in | Execute shell commands for `test_passes`, `git_clean`, `command_succeeds` | Standard Elixir approach for running OS commands; captures stdout, returns exit code |
| Elixir `Task` module | Built-in | Global timeout enforcement via `Task.async` + `Task.await(timeout)` | Clean timeout mechanism that kills the spawned process on timeout; no external deps |
| Elixir `File.exists?/1` | Built-in | `file_exists` check type | Direct, zero-overhead file existence check |
| DETS (`:dets`) | OTP built-in | Persist verification reports separately from tasks | Consistent with project pattern (TaskQueue, LlmRegistry use DETS) |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Phoenix.PubSub | ~> 2.1 (already in project) | Broadcast verification events for dashboard updates | On verification run completion to trigger real-time dashboard updates |
| `:telemetry` | Already in project | Emit verification metrics (duration, pass/fail counts) | For every verification run, following existing telemetry patterns |
| Jason | ~> 1.4 (already in project) | Serialize verification reports for API/dashboard | Already project standard for JSON encoding |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `System.cmd/3` | Erlang `:os.cmd/1` | `System.cmd/3` is preferred: separate stdout capture, returns `{output, exit_code}` tuple, proper argument escaping |
| DETS for report storage | ETS-only | DETS survives restarts; ETS would lose verification history on hub restart. DETS consistent with project patterns |
| `Task.async/await` for timeout | `Process.send_after` + manual kill | `Task.async/await` is cleaner; automatically handles the timeout semantics and process cleanup |

**Installation:** No new dependencies needed. All tools are built-in Elixir/OTP or already in the project.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  verification.ex               # Core verification runner (public API)
  verification/
    checks.ex                   # Check type implementations (file_exists, test_passes, etc.)
    report.ex                   # Report struct, builder, and serialization
    store.ex                    # DETS persistence for verification reports
```

### Pattern 1: Verification Runner (Stateless Module)
**What:** `AgentCom.Verification` is a stateless module (no GenServer) that runs verification checks synchronously. It takes a task map, executes checks, and returns a structured report.
**When to use:** Called after task execution completes, before the sidecar sends `task_complete` to the hub. In Phase 22, called in the retry loop.
**Why stateless:** Verification runs are synchronous, short-lived operations triggered by a specific event (task completion). No long-lived state to manage. A GenServer would add unnecessary complexity. This follows the pattern of `AgentCom.Complexity` (also a stateless module called during task processing).

```elixir
# AgentCom.Verification - Core API
defmodule AgentCom.Verification do
  @default_timeout_ms 120_000

  @doc """
  Run all verification checks for a task.
  Returns {:ok, report} or {:error, :timeout}.
  """
  @spec run(map()) :: {:ok, map()} | {:error, :timeout}
  def run(task) do
    steps = Map.get(task, :verification_steps, [])
    timeout = Map.get(task, :verification_timeout_ms, @default_timeout_ms)
    skip = Map.get(task, :skip_verification, false)

    cond do
      skip ->
        {:ok, build_skipped_report(task)}
      steps == [] ->
        {:ok, build_auto_pass_report(task)}
      true ->
        run_checks(task, steps, timeout)
    end
  end
end
```

### Pattern 2: Run-All-Checks with Global Timeout
**What:** Execute all checks regardless of individual failures, but enforce a global timeout across the entire verification run. If the timeout fires mid-check, remaining checks are marked as `:timeout` in the report.
**When to use:** Always -- this is the recommended strategy for Phase 21.
**Why:** Phase 22's retry loop needs to know ALL failures to make informed fix decisions. Fail-fast would hide problems, leading to whack-a-mole retries. The global timeout prevents any single runaway check from blocking the entire pipeline.

```elixir
defp run_checks(task, steps, timeout_ms) do
  task_ref = Task.async(fn ->
    started_at = System.monotonic_time(:millisecond)

    results = Enum.map(steps, fn step ->
      check_start = System.monotonic_time(:millisecond)
      result = execute_check(step, task)
      check_end = System.monotonic_time(:millisecond)

      %{
        type: step["type"],
        target: step["target"],
        description: step["description"],
        status: result.status,          # :pass | :fail | :error
        output: result.output,          # captured stdout/stderr
        duration_ms: check_end - check_start
      }
    end)

    total_duration = System.monotonic_time(:millisecond) - started_at
    build_report(task, results, total_duration)
  end)

  case Task.yield(task_ref, timeout_ms) || Task.shutdown(task_ref) do
    {:ok, report} -> {:ok, report}
    nil -> {:error, :timeout}
  end
end
```

### Pattern 3: Verification Report as Metadata + Separate Storage
**What:** Verification reports are both (a) attached to the task map as `verification_report` metadata and (b) persisted to a separate DETS table keyed by `{task_id, run_number}` for historical querying.
**When to use:** On every verification run completion.
**Why dual storage:** Attaching to task metadata means Phase 22 and any code that reads the task can immediately access the report without a second lookup. Separate DETS storage enables querying verification history across tasks (e.g., "which tasks failed git_clean this week?") and supports multiple verification runs per task (Phase 22 retries).

```elixir
# After verification completes
defp persist_and_attach(task_id, report) do
  # 1. Persist to separate verification history
  AgentCom.Verification.Store.save(task_id, report)

  # 2. Attach to task as metadata
  # (Phase 22 will use this to decide retry strategy)
  report
end
```

### Pattern 4: Check Type Dispatch with Typed Parameters
**What:** Each check type has typed parameters appropriate to its semantics, dispatched by the `"type"` field. The `"target"` field is the primary parameter for all types, with optional type-specific fields.
**When to use:** For all four built-in check types.
**Why typed params:** Different check types need different information. A single string argument would require parsing conventions. Typed params are self-documenting and validatable.

```elixir
# Parameter model per check type:
# file_exists:       %{"type" => "file_exists", "target" => "/path/to/file"}
# test_passes:       %{"type" => "test_passes", "target" => "mix test"}
#                    OR %{"type" => "test_passes", "target" => "auto"}  (auto-detect)
# git_clean:         %{"type" => "git_clean", "target" => "/path/to/repo"}
#                    OR %{"type" => "git_clean", "target" => "."}  (current dir)
# command_succeeds:  %{"type" => "command_succeeds", "target" => "curl -s http://localhost:4000/health"}
```

### Pattern 5: Check Execution Order -- Submission Order
**What:** Checks run in the order they appear in the `verification_steps` list (submission order).
**When to use:** Always.
**Why:** The submitter may have intentionally ordered checks from cheapest to most expensive, or from prerequisite to dependent. Respecting submission order gives submitters control without adding complexity. Auto-ordering by type would require defining a priority system with no clear benefit.

### Anti-Patterns to Avoid
- **GenServer for verification runner:** Verification is a synchronous, short-lived operation. A GenServer would add unnecessary process management overhead, message passing latency, and potential bottleneck (single process serializing all verifications). Use a plain module.
- **Per-check timeouts:** The user decided on a global timeout. Per-check timeouts would complicate the API and create confusion about which timeout applies. The global timeout via `Task.async/await` is sufficient.
- **Storing reports only on the task map:** Would lose verification history when tasks are cleaned up, and would make multi-run history (Phase 22) harder to query.
- **Shell injection via string concatenation:** Always use `System.cmd/3` with argument lists, never `System.cmd("sh", ["-c", user_string])` for `command_succeeds`. However, since `target` is a user-provided command string, we must use shell execution -- document this security boundary clearly.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Shell command execution | Custom port/process management | `System.cmd/3` | Handles stdout capture, exit codes, argument escaping. Battle-tested. |
| Timeout enforcement | Manual timers + process killing | `Task.async` + `Task.yield/2` + `Task.shutdown/1` | Clean semantics: yield returns result or nil on timeout, shutdown kills the process tree |
| File existence checks | Custom stat calls | `File.exists?/1` | One-liner, handles all edge cases (symlinks, permissions) |
| JSON serialization | Custom report formatting | Jason | Already project standard, handles all Elixir types |
| Event broadcasting | Custom notification system | Phoenix.PubSub | Already in project, used by DashboardState for all real-time events |
| Persistent storage | Custom file-based storage | DETS | Consistent with project patterns (TaskQueue, LlmRegistry), key-value access, survive restarts |

**Key insight:** This phase is almost entirely composing existing Elixir/OTP primitives. The novelty is in the report structure and the integration points, not in the infrastructure.

## Common Pitfalls

### Pitfall 1: Shell Command Security with command_succeeds
**What goes wrong:** The `target` field for `command_succeeds` is an arbitrary command string. If naively passed to a shell, this creates a command injection vector.
**Why it happens:** `System.cmd/3` requires an executable + argument list, but the user provides a single command string. The temptation is to use `System.cmd("sh", ["-c", command_string])` which works but passes the string through shell interpretation.
**How to avoid:** Accept this as a known security boundary -- the `command_succeeds` type is explicitly designed as an escape hatch for arbitrary commands. Document that verification commands have the same trust level as task execution commands. In the hub context, these are submitted by trusted task submitters (authenticated via token). Add a note in the check implementation that this is intentional.
**Warning signs:** If you find yourself trying to "sanitize" command strings, you're fighting the design. The user decided `command_succeeds` is the escape hatch.

### Pitfall 2: Global Timeout Killing Mid-Check
**What goes wrong:** A long-running test suite is 95% complete when the global timeout fires. The entire verification report shows zero results because the Task was killed.
**Why it happens:** `Task.shutdown/1` kills the process, losing any accumulated results.
**How to avoid:** Accumulate results incrementally. Run checks sequentially in the Task, storing each result as it completes. If the Task is killed by timeout, the caller can still access partial results via process dictionary or an Agent. Simpler approach: use `Task.yield/2` and if timeout fires, build a partial report marking remaining checks as `:timeout`.
**Warning signs:** Tests that occasionally return empty reports despite some checks having completed.

### Pitfall 3: git_clean False Positives from Build Artifacts
**What goes wrong:** `git status` reports build artifacts (e.g., `_build/`, `deps/`, `node_modules/`) as untracked files, causing `git_clean` to always fail.
**Why it happens:** The check uses `git status --porcelain` which reports ALL untracked files, including those that should be in `.gitignore`.
**How to avoid:** Use `git status --porcelain` which already respects `.gitignore`. If `.gitignore` is properly configured, this is a non-issue. The real risk is repos with incomplete `.gitignore` files. The check should report the specific files found dirty so the user can decide if it's a real problem or a `.gitignore` gap.
**Warning signs:** `git_clean` failing on every verification run in a project with build artifacts.

### Pitfall 4: test_passes Auto-Detection Fragility
**What goes wrong:** Auto-detection (checking for `mix.exs`, `package.json`, etc.) picks the wrong test command or fails on multi-language projects.
**Why it happens:** Heuristics are inherently unreliable. A project might have both `mix.exs` and `package.json` in the same directory.
**How to avoid:** Make auto-detection simple and predictable: check for `mix.exs` first (since this is an Elixir project hub), fall back to common patterns. If the target is `"auto"`, auto-detect. If the target is a specific command string, use it directly. Document the detection order. Phase 22 retries will catch false negatives.
**Warning signs:** Different test commands running on different machines for the same project.

### Pitfall 5: DETS Table Growth from Verification History
**What goes wrong:** Every verification run creates a new record in the DETS table. With Phase 22 retries (multiple runs per task), the table grows unboundedly.
**Why it happens:** No retention policy on verification reports.
**How to avoid:** Implement a retention cap similar to the ring buffer pattern used in DashboardState. Keep the last N reports per task, or reports from the last M days. Can be added in Phase 21 or deferred to a later cleanup phase. At minimum, document the growth concern.
**Warning signs:** DETS file size growing without bound over weeks of operation.

### Pitfall 6: System.cmd on Windows vs Unix
**What goes wrong:** Commands like `git status` work on both platforms, but arbitrary `command_succeeds` targets may use Unix-specific syntax (`|`, `grep`, etc.).
**Why it happens:** The hub runs on Windows (current environment), but commands may assume Unix shell.
**How to avoid:** Use `System.cmd("cmd", ["/c", command_string])` on Windows, `System.cmd("sh", ["-c", command_string])` on Unix. Detect OS at runtime with `:os.type()`. This is critical since the current dev environment is Windows 11.
**Warning signs:** Tests passing on one platform but failing on another.

## Code Examples

Verified patterns from Elixir standard library and project codebase:

### System.cmd for Command Execution
```elixir
# System.cmd/3 returns {stdout_string, exit_code}
# Source: Elixir standard library docs
{output, exit_code} = System.cmd("git", ["status", "--porcelain"],
  cd: repo_path,
  stderr_to_stdout: true
)

# exit_code 0 = success, non-zero = failure
# stderr_to_stdout: true captures both streams in output
```

### Task.async/await for Global Timeout
```elixir
# Source: Elixir Task module docs
task = Task.async(fn ->
  # Long-running verification work
  run_all_checks(steps)
end)

case Task.yield(task, timeout_ms) || Task.shutdown(task) do
  {:ok, result} -> {:ok, result}
  nil -> {:error, :timeout}
end
```

### DETS Storage Pattern (from AgentCom.LlmRegistry)
```elixir
# Source: lib/agent_com/llm_registry.ex
# Open DETS table in init
path = dets_path("verification_reports.dets") |> String.to_charlist()
{:ok, @reports_table} = :dets.open_file(@reports_table,
  file: path, type: :set, auto_save: 5_000
)

# Persist with explicit sync (from task_queue.ex pattern)
:dets.insert(@reports_table, {key, report})
:dets.sync(@reports_table)
```

### PubSub Broadcast Pattern (from AgentCom.TaskQueue)
```elixir
# Source: lib/agent_com/task_queue.ex:783-789
Phoenix.PubSub.broadcast(AgentCom.PubSub, "verification", {
  :verification_complete,
  %{task_id: task_id, report: report, timestamp: System.system_time(:millisecond)}
})
```

### Telemetry Event Pattern (from AgentCom.TaskQueue)
```elixir
# Source: lib/agent_com/task_queue.ex:259-264
:telemetry.execute(
  [:agent_com, :verification, :run],
  %{duration_ms: total_duration, checks_passed: passed, checks_failed: failed},
  %{task_id: task_id, total_checks: total}
)
```

### Verification Report Structure
```elixir
%{
  task_id: "task-abc123",
  run_number: 1,                    # Increments with Phase 22 retries
  status: :pass | :fail | :skip | :timeout | :auto_pass,
  started_at: 1707000000000,        # System.system_time(:millisecond)
  duration_ms: 4523,                # Total verification run time
  timeout_ms: 120_000,              # Configured timeout for this run
  checks: [
    %{
      type: "file_exists",
      target: "lib/agent_com/new_module.ex",
      description: "New module file created",
      status: :pass,                # :pass | :fail | :error | :timeout
      output: "",                   # stdout/stderr (empty for file_exists)
      duration_ms: 2                # Per-check timing
    },
    %{
      type: "test_passes",
      target: "mix test test/agent_com/new_module_test.exs",
      description: "New module tests pass",
      status: :fail,
      output: "1 test, 1 failure\n\n  1) test something...",
      duration_ms: 3200
    },
    %{
      type: "git_clean",
      target: ".",
      description: nil,
      status: :pass,
      output: "",
      duration_ms: 150
    }
  ],
  summary: %{
    total: 3,
    passed: 2,
    failed: 1,
    errors: 0,
    timed_out: 0
  }
}
```

### Check Type Implementations
```elixir
defmodule AgentCom.Verification.Checks do
  @doc "file_exists: check if file exists at target path"
  def execute("file_exists", step, _task) do
    path = step["target"]
    if File.exists?(path) do
      %{status: :pass, output: ""}
    else
      %{status: :fail, output: "File not found: #{path}"}
    end
  end

  @doc "test_passes: run test command; auto-detect if target is 'auto'"
  def execute("test_passes", step, task) do
    command = resolve_test_command(step["target"], task)
    run_shell_command(command)
  end

  @doc "git_clean: strict check for fully clean working tree"
  def execute("git_clean", step, _task) do
    repo_dir = step["target"] || "."
    {output, exit_code} = System.cmd("git", ["status", "--porcelain"],
      cd: repo_dir, stderr_to_stdout: true
    )
    if exit_code == 0 and String.trim(output) == "" do
      %{status: :pass, output: ""}
    else
      %{status: :fail, output: output}
    end
  end

  @doc "command_succeeds: run arbitrary command, check exit code 0"
  def execute("command_succeeds", step, _task) do
    run_shell_command(step["target"])
  end

  # Unknown check type
  def execute(type, _step, _task) do
    %{status: :error, output: "Unknown check type: #{type}"}
  end

  defp run_shell_command(command) do
    {shell, args} = case :os.type() do
      {:win32, _} -> {"cmd", ["/c", command]}
      _           -> {"sh", ["-c", command]}
    end

    try do
      {output, exit_code} = System.cmd(shell, args, stderr_to_stdout: true)
      if exit_code == 0 do
        %{status: :pass, output: output}
      else
        %{status: :fail, output: output}
      end
    rescue
      e -> %{status: :error, output: "Command execution error: #{Exception.message(e)}"}
    end
  end

  defp resolve_test_command("auto", task) do
    repo_dir = Map.get(task, :repo) || "."
    cond do
      File.exists?(Path.join(repo_dir, "mix.exs")) -> "mix test"
      File.exists?(Path.join(repo_dir, "package.json")) -> "npm test"
      File.exists?(Path.join(repo_dir, "Makefile")) -> "make test"
      true -> "echo 'No test runner detected'"
    end
  end

  defp resolve_test_command(command, _task), do: command
end
```

## Discretion Recommendations

Based on codebase analysis and Phase 22 integration requirements, here are recommendations for each discretion area:

### 1. Run-All-Checks (not fail-fast)
**Recommendation:** Run all checks regardless of individual failures.
**Rationale:** Phase 22's retry loop needs complete failure information to make good fix decisions. If check #1 fails and we stop, the agent might fix check #1 only to discover checks #2 and #3 also fail. Running all checks upfront enables the LLM to see the full picture and attempt a comprehensive fix.

### 2. Verification Results as Metadata + Separate Storage (both)
**Recommendation:** Attach the verification report to the task map as a `verification_report` field AND persist separately in a DETS table.
**Rationale:** Metadata attachment gives Phase 22 instant access without a second lookup. Separate DETS storage satisfies the requirement for "queryable verification history across tasks." The dual approach costs very little (one extra DETS write) and avoids the need to choose.

### 3. Include Per-Check Timing Data
**Recommendation:** Yes, include `duration_ms` on each check result.
**Rationale:** Nearly zero cost (two `System.monotonic_time/1` calls per check). Valuable for identifying slow checks that eat into the global timeout budget. Essential for Phase 22 to estimate whether there's enough timeout budget remaining for a retry.

### 4. Default Global Timeout: 120 seconds
**Recommendation:** 120,000 milliseconds (2 minutes).
**Rationale:** Test suites for this project run in under 30 seconds. A 2-minute timeout provides generous headroom for larger projects and slow CI environments while preventing runaway processes. This aligns with the `verification_timeout_ms: 120_000` value in the FEATURES.md research document.

### 5. test_passes: Hybrid Auto-Detection + Explicit Command
**Recommendation:** If `target` is `"auto"`, auto-detect from project files (mix.exs -> `mix test`, package.json -> `npm test`). If `target` is any other string, treat it as a literal command. Auto-detection checks mix.exs first (this is an Elixir project), then common alternatives.
**Rationale:** Auto-detection reduces boilerplate for common cases. Explicit command is always available as escape hatch. The `"auto"` sentinel is unambiguous.

### 6. Typed Parameter Maps Per Check Type
**Recommendation:** Use the `"target"` field as the primary parameter for all types (already established in Phase 17's validation schema). Additional type-specific fields are optional. The `"type"` field dispatches execution.
**Rationale:** Phase 17 already established `%{"type" => string, "target" => string, "description" => string}` as the verification step schema. Adding optional fields per type (e.g., `"working_dir"` for git_clean) is additive and backward-compatible. This avoids a breaking change to the existing schema.

### 7. Check Execution Order: Submission Order
**Recommendation:** Execute checks in the order they appear in `verification_steps`.
**Rationale:** Submitters can order checks from cheapest to most expensive if they want early timeout savings. Auto-ordering by type would impose an opinion that may not match every use case. Simplicity wins.

## Integration Points

### Where Verification Runs in the Pipeline

```
Task Execution (Phase 20)
    |
    v
Verification (Phase 21) -- THIS PHASE
    |
    v
[Phase 22: Retry if failed]
    |
    v
task_complete / task_failed sent to Hub
```

Verification runs on the sidecar side, between task execution completing and the result being sent to the hub. The sidecar currently (in `handleResult`) reads a result JSON file and immediately sends `task_complete`. Phase 21 inserts a verification step between these two actions.

However, there is also a hub-side component: the verification report must be persisted and displayed on the dashboard. The report arrives with the `task_complete` message or as a separate message.

### Key Integration Points

| Integration | What Changes | How |
|-------------|-------------|-----|
| TaskQueue task map | Add `verification_report` field | Additive field with `nil` default, like enrichment fields |
| TaskQueue `complete_task/3` | Store verification_report from result_params | Read from result_params map, persist with task |
| Socket `task_complete` handler | Extract verification_report from message | Pass through to `complete_task` |
| DashboardState | Subscribe to "verification" PubSub topic | Add verification data to snapshot |
| Dashboard HTML | Render green/red indicators per check | Expand verification section in task detail view |
| Telemetry | New `[:agent_com, :verification, :run]` events | Follow existing event pattern |
| Validation Schemas | Add `verification_report` to `task_complete` message | Optional map field |
| DETS (new table) | `verification_reports` table | New table in Application supervision tree |
| Endpoint API | Include verification_report in task detail responses | Add to `format_task/1` |

### Sidecar Integration

The sidecar needs to run verification checks locally (since checks like `file_exists`, `git_clean`, and `test_passes` need filesystem access). This means:

1. The verification engine is also implemented in the sidecar (JavaScript/Node.js)
2. OR the hub sends a "run verification" command and the sidecar executes it
3. OR verification runs on the hub side using SSH/remote execution

**Recommendation:** Implement verification in the sidecar (Option 1). The sidecar already has filesystem access, runs shell commands (git workflow), and knows the working directory. The verification report is sent back with the `task_complete` message. The hub persists and displays it.

This means Phase 21 has TWO implementation surfaces:
1. **Sidecar (JavaScript):** Verification runner that executes checks locally
2. **Hub (Elixir):** Report persistence, dashboard display, API serving

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Inline shell execution | `System.cmd/3` with lists | Elixir 1.0+ | Safer argument handling, proper exit code capture |
| `Task.await/2` with hard kill | `Task.yield/2` + `Task.shutdown/1` | Elixir 1.1+ | Graceful timeout handling with option to get partial results |
| OTP `:timer.tc/1` for timing | `System.monotonic_time/1` | OTP 18+ | Monotonic clock not affected by system time changes |

**Deprecated/outdated:**
- `:os.cmd/1`: Returns charlist, no exit code, no stderr separation. Use `System.cmd/3` instead.

## Open Questions

1. **Where exactly does verification run relative to git workflow?**
   - What we know: The sidecar currently does git push + PR creation in `handleResult` before sending `task_complete`. Verification should run before git push (so we don't push broken code).
   - What's unclear: Should verification run before or after the git commit? If before commit, we can't check `git_clean`. If after commit but before push, we can check everything.
   - Recommendation: Run verification after the code changes are made but before git push/PR. The sidecar execution flow becomes: execute task -> verify -> git push (if passed) -> send result. This is a Phase 22 concern (the retry loop), but Phase 21 should be designed with this ordering in mind.

2. **How do verification reports get from sidecar to hub?**
   - What we know: Currently `task_complete` sends a `result` map. The verification report could be nested inside `result`.
   - What's unclear: Is the verification report part of the `result` field, or a separate top-level field in the `task_complete` message?
   - Recommendation: Add `verification_report` as a separate top-level field in the `task_complete` WebSocket message. This keeps it cleanly separated from the LLM's execution output and makes it easy for the hub to extract without parsing nested result structures.

3. **DETS table lifecycle for verification reports**
   - What we know: Reports should be persisted separately for queryable history.
   - What's unclear: Retention policy, cleanup schedule, maximum table size.
   - Recommendation: Start with a simple GenServer (`AgentCom.Verification.Store`) that manages the DETS table, with a configurable retention cap (e.g., last 1000 reports). Defer retention tuning to operational experience.

## Sources

### Primary (HIGH confidence)
- **Codebase analysis** - Direct reading of `lib/agent_com/task_queue.ex`, `lib/agent_com/validation.ex`, `lib/agent_com/validation/schemas.ex`, `lib/agent_com/complexity.ex`, `lib/agent_com/scheduler.ex`, `lib/agent_com/llm_registry.ex`, `lib/agent_com/dashboard_state.ex`, `lib/agent_com/telemetry.ex`, `sidecar/index.js`
- **Phase 17 VERIFICATION.md** - Confirmed verification_steps field structure and pipeline propagation
- **Elixir System.cmd/3, Task, File modules** - Standard library, well-documented, stable APIs

### Secondary (MEDIUM confidence)
- **FEATURES.md research document** - Contains early verification architecture sketch including `verification_timeout_ms: 120_000` default
- **Phase 17 RESEARCH.md** - Documented verification step schema: `%{"type" => string, "target" => string, "description" => string}`

### Tertiary (LOW confidence)
- None -- all findings verified against codebase or Elixir standard library

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all tools are built-in Elixir/OTP or already in the project
- Architecture: HIGH -- patterns directly follow existing codebase conventions (stateless modules, DETS persistence, PubSub events, telemetry)
- Pitfalls: HIGH -- identified from direct codebase analysis (Windows platform, DETS growth, shell execution semantics)

**Research date:** 2026-02-12
**Valid until:** 2026-03-12 (stable domain, no external dependency version concerns)
