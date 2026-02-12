# Phase 17: Enriched Task Format - Research

**Researched:** 2026-02-12
**Domain:** Elixir/OTP data structures, validation schemas, DETS persistence, GenServer task pipeline
**Confidence:** HIGH

## Summary

Phase 17 extends the existing task data model in `AgentCom.TaskQueue` with structured context fields (repo, branch, relevant files), success criteria, verification steps, and complexity classification. The current task is a plain Elixir map with 19 fields, created in `TaskQueue.handle_call({:submit, params})` at line 206. All new fields are optional additions to this map -- no structural changes to DETS tables, GenServer architecture, or the priority index are needed.

The main challenge is ensuring backward compatibility: existing v1.0/v1.1 tasks persisted in DETS lack the new fields, so all code that reads tasks must handle missing keys gracefully. The existing `Validation.Schemas` module (Phase 12 infrastructure) provides the pattern for schema extension -- adding new optional fields to the `post_task` HTTP schema and extending the `task_assign` WebSocket push payload. The complexity heuristic engine is a new pure-function module with no GenServer state.

**Primary recommendation:** Add enrichment fields directly to the task map in `TaskQueue.submit/1`, extend existing validation schemas, build the complexity heuristic as a standalone module, and use `Map.get/3` with defaults for all backward-compatible reads.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Repo identification uses inherit-plus-override: agent's `default_repo` from onboarding is the default, task can override with an explicit repo field
- File hints carry path + reason annotation (e.g., `{path: "src/scheduler.ex", reason: "modify routing logic"}`)
- Four tiers: `trivial`, `standard`, `complex`, `unknown`
- `unknown` tier gets conservative routing (treated as standard or higher by scheduler)
- Heuristic engine always runs, even when submitter provides explicit tier -- for observability and disagreement logging
- Explicit submitter tag always wins over heuristic inference
- Inferred complexity includes a confidence score (e.g., `{tier: "standard", confidence: 0.85}`)
- Reject invalid enrichment fields with error (fail fast) -- leverage existing Phase 12 input validation infrastructure
- Soft limit on verification steps per task with warning (suggests task should be split if too many)
- Existing v1.0/v1.1 tasks must continue working unchanged

### Claude's Discretion
- Branch field design (optional source branch vs always-from-main)
- Verification step structure (typed-only vs typed+freeform, separate success_criteria vs combined)
- Default values for missing enrichment fields (nil vs sensible defaults)
- Migration strategy (runtime handling vs startup backfill)
- Heuristic engine signal design and weighting
- Soft limit threshold for verification step count

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir | ~> 1.14 | Runtime, maps, pattern matching | Already in use (mix.exs line 8) |
| DETS | OTP built-in | Task persistence | Already backing TaskQueue (`:task_queue` table) |
| Jason | ~> 1.4 | JSON encode/decode for API/WS | Already in use everywhere |
| Phoenix.PubSub | ~> 2.1 | Event broadcasting for task events | Already used by TaskQueue and Scheduler |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| :telemetry | OTP built-in | Heuristic engine observability | Emit events when heuristic disagrees with explicit tier |
| Logger | OTP built-in | Structured logging | Log complexity inference results and disagreements |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Plain maps for tasks | Elixir structs with `defstruct` | Structs would catch missing fields at compile time, but DETS stores plain maps and existing data would fail. Stick with maps. |
| Custom validation for enrichment | Ecto changesets | Overkill -- existing `AgentCom.Validation.Schemas` pattern works well and is already proven |
| GenServer for heuristic engine | Pure-function module | Heuristic is stateless -- no need for a process. Pure function is simpler, testable, no supervision tree changes |

**No new dependencies needed.** All functionality can be built with existing stack.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  task_queue.ex            # MODIFY: Add enrichment fields to task map in submit
  complexity.ex            # NEW: Complexity heuristic engine (pure functions)
  validation/
    schemas.ex             # MODIFY: Add enrichment field schemas
  validation.ex            # MODIFY: Add nested validation for file_hints, verification_steps
  scheduler.ex             # MODIFY: Pass enrichment fields in task_data push
  socket.ex                # MODIFY: Include enrichment fields in task_assign push
  endpoint.ex              # MODIFY: Pass enrichment fields through HTTP task submission

test/agent_com/
  complexity_test.exs      # NEW: Unit tests for heuristic engine
  task_queue_test.exs      # MODIFY: Add tests for enriched task submit/get
  validation_test.exs      # MODIFY: Add tests for enrichment field validation

sidecar/
  index.js                 # MODIFY: Pass enrichment fields from task_assign to agent
```

### Pattern 1: Task Map Extension (Adding Fields to Existing Map)
**What:** Add new optional keys to the task map created in `TaskQueue.handle_call({:submit, params})`
**When to use:** When extending the task data model without breaking existing persistence
**Example:**
```elixir
# Source: TaskQueue.handle_call({:submit, params}) -- current line 206
# EXISTING fields remain unchanged, NEW fields added at end
task = %{
  # ... all existing 19 fields unchanged ...

  # TASK-01: Context fields
  repo: Map.get(params, :repo, Map.get(params, "repo", nil)),
  branch: Map.get(params, :branch, Map.get(params, "branch", nil)),
  file_hints: Map.get(params, :file_hints, Map.get(params, "file_hints", [])),

  # TASK-02: Success criteria
  success_criteria: Map.get(params, :success_criteria, Map.get(params, "success_criteria", [])),

  # TASK-03: Verification steps
  verification_steps: Map.get(params, :verification_steps, Map.get(params, "verification_steps", [])),

  # TASK-04/TASK-05: Complexity classification
  complexity: build_complexity(params)
}
```

### Pattern 2: Inherit-Plus-Override for Repo
**What:** Task repo field defaults to agent's `default_repo` from Config, task can override
**When to use:** When repo is submitted without an explicit repo field
**Example:**
```elixir
# The agent's default_repo is set via PUT /api/config/default-repo
# At task submission via HTTP, the endpoint reads the global default
# At task assignment, the Scheduler can inject default_repo from Config

defp resolve_repo(params) do
  explicit = Map.get(params, :repo, Map.get(params, "repo", nil))
  case explicit do
    nil -> nil  # Will be resolved at assignment time from agent's default_repo
    repo -> repo
  end
end
```

### Pattern 3: Pure-Function Heuristic Engine
**What:** A module with stateless functions that analyze task content and return a complexity classification
**When to use:** For TASK-05 complexity inference
**Example:**
```elixir
defmodule AgentCom.Complexity do
  @moduledoc """
  Heuristic engine for inferring task complexity from content.
  Always runs, even when submitter provides an explicit tier.
  Returns `%{tier: atom, confidence: float, signals: map}`.
  """

  @tiers [:trivial, :standard, :complex, :unknown]
  @valid_explicit_tiers [:trivial, :standard, :complex]

  @doc "Infer complexity from task description, file hints, and metadata."
  def infer(task) do
    signals = gather_signals(task)
    {tier, confidence} = classify(signals)
    %{tier: tier, confidence: confidence, signals: signals}
  end

  @doc "Build the full complexity map for a task, combining explicit and inferred."
  def build(params) do
    explicit_tier = parse_explicit_tier(params)
    # Heuristic always runs (locked decision)
    inferred = infer(params)

    effective_tier = if explicit_tier, do: explicit_tier, else: inferred.tier

    %{
      effective_tier: effective_tier,
      explicit_tier: explicit_tier,
      inferred: inferred,
      source: if(explicit_tier, do: :explicit, else: :inferred)
    }
  end
end
```

### Pattern 4: Existing Validation Schema Extension
**What:** Add new optional fields to the `post_task` HTTP schema in `Validation.Schemas`
**When to use:** For TASK-01 through TASK-04 input validation
**Example:**
```elixir
# Source: Validation.Schemas @http_schemas -- extend post_task
post_task: %{
  required: %{
    "description" => :string
  },
  optional: %{
    # Existing fields
    "priority" => :string,
    "metadata" => :map,
    "max_retries" => :integer,
    "complete_by" => :integer,
    "needed_capabilities" => {:list, :string},
    # NEW: Enrichment fields (TASK-01)
    "repo" => :string,
    "branch" => :string,
    "file_hints" => {:list, :map},
    # NEW: Success criteria (TASK-02)
    "success_criteria" => {:list, :string},
    # NEW: Verification steps (TASK-03)
    "verification_steps" => {:list, :map},
    # NEW: Complexity tier (TASK-04)
    "complexity" => :string
  },
  description: "Submit a task to the queue."
}
```

### Pattern 5: Backward-Compatible Task Reading
**What:** Always use `Map.get/3` with default when reading enrichment fields from persisted tasks
**When to use:** Everywhere tasks are read (format_task, Scheduler, Socket push, etc.)
**Example:**
```elixir
# Source: Endpoint.format_task/1 -- extend for enrichment fields
defp format_task(task) do
  %{
    # ... existing fields unchanged ...
    "repo" => Map.get(task, :repo),
    "branch" => Map.get(task, :branch),
    "file_hints" => Map.get(task, :file_hints, []),
    "success_criteria" => Map.get(task, :success_criteria, []),
    "verification_steps" => Map.get(task, :verification_steps, []),
    "complexity" => format_complexity(Map.get(task, :complexity))
  }
end
```

### Anti-Patterns to Avoid
- **Direct field access on old tasks:** Never use `task.repo` -- old persisted tasks lack this key. Always `Map.get(task, :repo)`.
- **Startup migration of DETS data:** Backfilling thousands of DETS records on startup adds latency and complexity. Use runtime defaults instead.
- **GenServer for stateless computation:** The heuristic engine is pure computation. Making it a GenServer adds supervision complexity for zero benefit.
- **Breaking the task_assign WebSocket payload:** The sidecar parses `task_assign` messages. New fields must be additive -- never remove or rename existing fields.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Input validation for enrichment fields | Custom validation functions per field | Extend `AgentCom.Validation.Schemas` patterns | Phase 12 infrastructure already handles type checking, required/optional, length limits, error formatting |
| JSON serialization of task maps | Manual key-by-key serialization | `Jason.encode!/1` with proper map construction | Jason handles all Elixir primitive types natively |
| Nested field validation (file_hints items) | Ad-hoc checks in submit handler | Add nested validation support to `AgentCom.Validation` | Consistent error format, reusable pattern for Phase 21 verification infrastructure |
| DETS migration/upgrade logic | Startup scan-and-update | Runtime `Map.get/3` with defaults | Simpler, no startup latency, no migration state tracking |

**Key insight:** The existing validation infrastructure from Phase 12 can handle most of the new field validation. The complexity heuristic is the only genuinely new computation -- everything else is extending existing patterns.

## Common Pitfalls

### Pitfall 1: KeyError on Old DETS Tasks
**What goes wrong:** Code accesses `task.repo` or `task.complexity` on a task persisted before Phase 17. Crashes with `KeyError`.
**Why it happens:** DETS stores plain maps. Old tasks don't have the new keys. Unlike structs, maps don't have default values.
**How to avoid:** Always use `Map.get(task, :field, default)` for enrichment fields. Add a helper function `get_enrichment_field/3`.
**Warning signs:** Test passes on fresh DETS but crashes in production with existing data.

### Pitfall 2: Validation Schema Version Mismatch
**What goes wrong:** HTTP schema for `post_task` is updated but the sidecar sends old-format messages. Or: schema requires a field that the sidecar doesn't send.
**Why it happens:** The sidecar (Node.js) and hub (Elixir) are deployed independently. Schema changes must be backward-compatible.
**How to avoid:** All enrichment fields are OPTIONAL in the schema. Never make them required. The sidecar can be updated later.
**Warning signs:** Sidecar fails to submit tasks after hub upgrade.

### Pitfall 3: Complexity Classification Not Propagated to Sidecar
**What goes wrong:** Complexity is computed and stored in TaskQueue, but the `task_assign` WebSocket push to the sidecar doesn't include it.
**Why it happens:** The Scheduler builds `task_data` with only `task_id, description, metadata, generation` (scheduler.ex line 232-236). Enrichment fields are silently dropped.
**How to avoid:** Update `Scheduler.do_assign/2` to include all enrichment fields in the `task_data` map. Update `Socket.handle_info({:push_task, task})` to serialize them.
**Warning signs:** Sidecar receives tasks without complexity/context fields.

### Pitfall 4: Heuristic Confidence Range Issues
**What goes wrong:** Heuristic returns confidence outside 0.0-1.0, or returns string instead of float.
**Why it happens:** No type enforcement on the confidence score output.
**How to avoid:** Clamp confidence to `max(0.0, min(1.0, score))` in the heuristic engine. Add typespec and unit test.
**Warning signs:** Scheduler Phase 19 gets unexpected confidence values.

### Pitfall 5: Verification Steps Soft Limit Not Enforced at Submission
**What goes wrong:** A task with 50 verification steps is submitted without warning. Phase 21 verification infrastructure has to run all 50.
**Why it happens:** Soft limit is only conceptual -- no code checks it.
**How to avoid:** Add a warning (not error) in `TaskQueue.submit/1` when `length(verification_steps) > threshold`. Log the warning. Include a warning field in the response.
**Warning signs:** Tasks with excessive verification steps pass through silently.

### Pitfall 6: File Hint Validation Too Strict or Too Loose
**What goes wrong:** Either: valid file hints are rejected because validation is too strict on the map shape. Or: garbage maps pass through because no inner validation.
**Why it happens:** Current validation only checks top-level type (`:map`), not inner structure.
**How to avoid:** Add lightweight inner validation for file_hints: each item must have a `"path"` string. `"reason"` is optional but if present must be a string.
**Warning signs:** File hints arrive at the sidecar with missing paths.

### Pitfall 7: DETS Sync Overhead with Larger Task Maps
**What goes wrong:** Task maps are now larger (context, file hints, verification steps). DETS sync time increases.
**Why it happens:** Every DETS mutation calls `:dets.sync/1` (crash safety from TASK-06).
**How to avoid:** This is acceptable overhead. Tasks are not created at high frequency. Monitor via existing telemetry `:agent_com, :task, :submit`. No code change needed.
**Warning signs:** Task submission latency increases noticeably in telemetry.

## Code Examples

### Example 1: Extending TaskQueue.submit with Enrichment Fields
```elixir
# In TaskQueue.handle_call({:submit, params})
# After existing field extraction, before persist_task:

# TASK-01: Context fields
repo = Map.get(params, :repo, Map.get(params, "repo", nil))
branch = Map.get(params, :branch, Map.get(params, "branch", nil))
file_hints = Map.get(params, :file_hints, Map.get(params, "file_hints", []))

# TASK-02: Success criteria
success_criteria = Map.get(params, :success_criteria, Map.get(params, "success_criteria", []))

# TASK-03: Verification steps
verification_steps = Map.get(params, :verification_steps, Map.get(params, "verification_steps", []))

# TASK-04/TASK-05: Complexity (always infers, explicit wins)
complexity = AgentCom.Complexity.build(params)

# Soft limit warning for verification steps
if length(verification_steps) > verification_step_limit() do
  Logger.warning("task_verification_steps_exceeded",
    task_id: task_id,
    count: length(verification_steps),
    limit: verification_step_limit()
  )
end

task = %{
  # ... all 19 existing fields ...
  repo: repo,
  branch: branch,
  file_hints: file_hints,
  success_criteria: success_criteria,
  verification_steps: verification_steps,
  complexity: complexity
}
```

### Example 2: Complexity Heuristic Engine
```elixir
defmodule AgentCom.Complexity do
  @verification_step_limit 10

  def verification_step_limit, do: @verification_step_limit

  @doc "Build full complexity map from submission params."
  def build(params) do
    explicit_tier = parse_explicit_tier(params)
    inferred = infer(params)

    effective = if explicit_tier, do: explicit_tier, else: inferred.tier

    disagreement = explicit_tier != nil and explicit_tier != inferred.tier

    if disagreement do
      :telemetry.execute(
        [:agent_com, :complexity, :disagreement],
        %{},
        %{explicit: explicit_tier, inferred_tier: inferred.tier, confidence: inferred.confidence}
      )
    end

    %{
      effective_tier: effective,
      explicit_tier: explicit_tier,
      inferred: inferred,
      source: if(explicit_tier, do: :explicit, else: :inferred)
    }
  end

  def infer(params) do
    description = get_string(params, :description)
    file_hints = get_list(params, :file_hints)
    verification_steps = get_list(params, :verification_steps)

    signals = %{
      word_count: count_words(description),
      file_count: length(file_hints),
      verification_step_count: length(verification_steps),
      has_keywords: detect_keywords(description)
    }

    {tier, confidence} = classify(signals)
    %{tier: tier, confidence: clamp(confidence), signals: signals}
  end

  defp classify(signals) do
    cond do
      signals.word_count < 20 and signals.file_count <= 1 and
        signals.verification_step_count == 0 ->
        {:trivial, 0.85}

      signals.word_count > 100 or signals.file_count > 5 or
        signals.has_keywords.complex ->
        {:complex, 0.70}

      true ->
        {:standard, 0.75}
    end
  end

  defp parse_explicit_tier(params) do
    raw = Map.get(params, :complexity, Map.get(params, "complexity", nil))
    case raw do
      "trivial" -> :trivial
      "standard" -> :standard
      "complex" -> :complex
      _ -> nil
    end
  end

  defp clamp(v), do: max(0.0, min(1.0, v))

  defp count_words(nil), do: 0
  defp count_words(s) when is_binary(s), do: s |> String.split() |> length()

  defp detect_keywords(nil), do: %{complex: false, trivial: false}
  defp detect_keywords(desc) do
    lower = String.downcase(desc)
    %{
      complex: String.contains?(lower, ["refactor", "architect", "redesign", "migrate", "security"]),
      trivial: String.contains?(lower, ["rename", "typo", "format", "lint", "version bump"])
    }
  end

  defp get_string(params, key) do
    Map.get(params, key, Map.get(params, to_string(key), ""))
  end

  defp get_list(params, key) do
    Map.get(params, key, Map.get(params, to_string(key), []))
  end
end
```

### Example 3: Extending Scheduler Task Push
```elixir
# In Scheduler.do_assign/2, after TaskQueue.assign_task succeeds:
task_data = %{
  task_id: assigned_task.id,
  description: assigned_task.description,
  metadata: assigned_task.metadata,
  generation: assigned_task.generation,
  # NEW: Enrichment fields
  repo: Map.get(assigned_task, :repo),
  branch: Map.get(assigned_task, :branch),
  file_hints: Map.get(assigned_task, :file_hints, []),
  success_criteria: Map.get(assigned_task, :success_criteria, []),
  verification_steps: Map.get(assigned_task, :verification_steps, []),
  complexity: Map.get(assigned_task, :complexity)
}
```

### Example 4: Extending Socket task_assign Push
```elixir
# In Socket.handle_info({:push_task, task}):
push = %{
  "type" => "task_assign",
  "task_id" => task["task_id"] || task[:task_id],
  "description" => task["description"] || task[:description] || "",
  "metadata" => task["metadata"] || task[:metadata] || %{},
  "generation" => task["generation"] || task[:generation] || 0,
  "assigned_at" => System.system_time(:millisecond),
  # NEW: Enrichment fields (safe nil for old tasks)
  "repo" => task["repo"] || task[:repo],
  "branch" => task["branch"] || task[:branch],
  "file_hints" => task["file_hints"] || task[:file_hints] || [],
  "success_criteria" => task["success_criteria"] || task[:success_criteria] || [],
  "verification_steps" => task["verification_steps"] || task[:verification_steps] || [],
  "complexity" => format_complexity(task["complexity"] || task[:complexity])
}
```

### Example 5: Nested Validation for File Hints
```elixir
# In Validation module -- new function for nested map-in-list validation
defp validate_file_hints(acc, field, hints) when is_list(hints) do
  Enum.with_index(hints)
  |> Enum.reduce(acc, fn {hint, idx}, inner_acc ->
    cond do
      not is_map(hint) ->
        [%{field: "#{field}[#{idx}]", error: :wrong_type,
           detail: "expected object, got #{type_name(hint)}"} | inner_acc]
      not is_binary(Map.get(hint, "path")) ->
        [%{field: "#{field}[#{idx}].path", error: :required,
           detail: "file hint must have a string 'path'"} | inner_acc]
      true ->
        inner_acc
    end
  end)
end
```

## Discretion Recommendations

### Branch Field Design
**Recommendation: Optional source branch, default nil (always-from-main behavior)**

The Phase 7 git workflow always branches from `origin/main` (agentcom-git.js line 168-189, verified in 07-VERIFICATION.md). The `branch` field should be an optional override that, when present, tells the sidecar to branch from a different base. When nil, the existing always-from-main behavior continues unchanged. This is consistent with the inherit-plus-override pattern used for repo.

### Verification Step Structure
**Recommendation: Typed steps with optional freeform description, separate success_criteria field**

Verification steps should be typed maps to enable Phase 21 mechanical verification. Each step has:
- `type` (string, required): one of `"file_exists"`, `"test_passes"`, `"command_succeeds"`, `"git_clean"`, `"custom"`
- `target` (string, required): the file path, test command, etc.
- `description` (string, optional): human-readable explanation

Success criteria should be a separate field (`success_criteria`) as a list of plain strings -- they represent testable "done" conditions that are human-readable, whereas verification steps are machine-executable. This separation maps cleanly to Phase 21 requirements (VERIFY-02 pre-built types vs VERIFY-01 structured reports).

Example verification step: `%{"type" => "test_passes", "target" => "mix test test/agent_com/task_queue_test.exs", "description" => "TaskQueue tests pass"}`
Example success criterion: `"Enrichment fields are persisted in DETS and survive restart"`

### Default Values for Missing Enrichment Fields
**Recommendation: nil for scalar fields, empty lists for collection fields**

- `repo`: nil (inherit from global default_repo at assignment time)
- `branch`: nil (use default always-from-main behavior)
- `file_hints`: `[]` (no file hints)
- `success_criteria`: `[]` (no criteria specified)
- `verification_steps`: `[]` (no steps specified)
- `complexity`: always present (heuristic engine always runs, produces `%{effective_tier: :unknown, ...}` when no signals)

This avoids the nil-vs-empty ambiguity: nil means "not specified", empty list means "explicitly nothing."

### Migration Strategy
**Recommendation: Runtime handling (Map.get with defaults), no startup backfill**

Startup backfill would:
1. Add startup latency scanning all DETS records
2. Require migration state tracking (did we already migrate?)
3. Risk corruption if interrupted mid-migration

Runtime `Map.get/3` with defaults:
1. Zero startup cost
2. No migration state needed
3. Old tasks "just work" -- they return defaults for missing fields
4. Simpler to implement and test

### Heuristic Engine Signal Design
**Recommendation: Four signals with simple threshold-based classification**

Signals:
1. **Word count** of description: < 20 words suggests trivial, > 100 suggests complex
2. **File count** from file_hints: > 5 files suggests complex
3. **Verification step count**: 0 suggests trivial, > 5 suggests complex
4. **Keyword detection**: presence of complexity-indicating keywords ("refactor", "architect", "migrate" = complex; "rename", "typo", "format" = trivial)

Weighting: Simple threshold-based classification (no numerical weights). This is intentionally conservative -- the heuristic is a signal for Phase 19 scheduler, and the AROUTE-01 future LLM classifier will replace it. Overengineering the heuristic now would be wasted effort.

Confidence scoring: Base confidence for each tier, reduced when signals conflict. Trivial = 0.85 base, Standard = 0.75 base, Complex = 0.70 base. Unknown = 0.5 (when signals strongly conflict).

### Soft Limit Threshold for Verification Steps
**Recommendation: 10 verification steps per task**

Reasoning: A well-scoped task should verify 3-5 things. More than 10 suggests the task should be split. This is a warning, not a hard limit -- the task still submits. The warning appears in:
1. Hub structured logs (Logger.warning)
2. Task submission HTTP response (a `"warnings"` field)
3. Telemetry event for dashboard monitoring

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Tasks are flat description + metadata | Tasks carry structured context, criteria, classification | Phase 17 (now) | Enables intelligent routing (P19), verification (P21), self-correction (P22) |
| Complexity is implicit (in submitter's head) | Complexity is explicit or inferred | Phase 17 (now) | Scheduler can route to appropriate LLM tier |
| No verification expectations on tasks | Tasks carry testable success/verification criteria | Phase 17 (now) | Phase 21 verification infrastructure can operate |

**Deprecated/outdated:**
- Nothing deprecated. Phase 17 is purely additive.

## Open Questions

1. **File hint path resolution**
   - What we know: File hints carry `{path, reason}`. Path is relative to repo root.
   - What's unclear: Should the hub validate that the path looks reasonable (e.g., no `..` traversal)? Or is that the sidecar's responsibility?
   - Recommendation: Basic sanity check in validation (reject paths starting with `..` or containing null bytes). Leave filesystem validation to sidecar.

2. **Complexity heuristic tuning data**
   - What we know: Initial thresholds (word count, file count, keywords) are reasonable defaults.
   - What's unclear: What are good real-world thresholds? We have no production data yet.
   - Recommendation: Ship with conservative defaults. The disagreement logging (explicit vs inferred) will provide tuning data for future adjustment. Thresholds should be configurable via `AgentCom.Config`.

3. **Schema version in API response**
   - What we know: `Schemas.to_json()` returns `"version" => "1.0"`.
   - What's unclear: Should we bump to "1.1" to indicate enrichment fields are available?
   - Recommendation: Bump to "1.1" when enrichment schemas are added. This helps sidecars detect hub capability.

## Sources

### Primary (HIGH confidence)
- `lib/agent_com/task_queue.ex` -- Task map structure, submit handler (line 206-229), persist/sync pattern
- `lib/agent_com/validation/schemas.ex` -- Schema definition pattern, post_task schema (line 244-254)
- `lib/agent_com/validation.ex` -- Validation engine, type checking, nested list validation (line 192-213)
- `lib/agent_com/scheduler.ex` -- Task-to-agent matching, task_data push construction (line 232-236)
- `lib/agent_com/socket.ex` -- WebSocket task_assign push (line 170-185), task lifecycle handlers
- `lib/agent_com/endpoint.ex` -- HTTP POST /api/tasks handler (line 849-889), format_task helper (line 1265-1291)
- `sidecar/index.js` -- handleTaskAssign (line 506-560), task object structure
- `test/agent_com/task_queue_test.exs` -- Test patterns for task submit, assign, complete
- `test/support/test_factory.ex` -- Factory pattern for creating test agents and tasks

### Secondary (MEDIUM confidence)
- `.planning/phases/07-git-workflow/07-VERIFICATION.md` -- Git workflow always-from-main pattern confirmed
- `.planning/ROADMAP.md` -- Phase 17 success criteria, downstream phase dependencies
- `.planning/REQUIREMENTS.md` -- TASK-01 through TASK-05 requirement definitions

### Tertiary (LOW confidence)
- Heuristic engine signal thresholds (word count, file count) -- based on general software engineering judgment, not empirical data. Will need tuning with production use.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- this is purely extending existing Elixir/OTP patterns already in the codebase
- Architecture: HIGH -- all touch points identified by reading every relevant source file
- Pitfalls: HIGH -- derived directly from analyzing existing code patterns and DETS persistence model
- Heuristic engine design: MEDIUM -- signal design is reasonable but thresholds are untested
- Verification step structure: MEDIUM -- structure anticipates Phase 21 needs but Phase 21 is not yet designed

**Research date:** 2026-02-12
**Valid until:** 2026-03-12 (stable domain -- pure data model extension, no external dependencies)
