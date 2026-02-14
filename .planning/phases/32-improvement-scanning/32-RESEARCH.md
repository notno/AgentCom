# Phase 32: Improvement Scanning - Research

**Researched:** 2026-02-13
**Domain:** Autonomous codebase improvement identification (deterministic + LLM-assisted scanning)
**Confidence:** HIGH

## Summary

Phase 32 implements autonomous codebase improvement scanning as a stateless library module (`SelfImprovement`) called by HubFSM during the Improving state. The module has three scanning layers: Elixir tool integration (Credo, Dialyzer), deterministic analysis (test gaps, doc gaps, dead deps), and LLM-assisted review (git diff analysis via ClaudeClient). Findings are converted to goals in GoalBacklog with "low" priority. Anti-Sisyphus protections (improvement history, file cooldowns, oscillation detection) prevent unbounded or cyclic improvement loops.

The existing codebase already provides strong foundations: `ClaudeClient.identify_improvements/2` with its prompt and response parser exists, `GoalBacklog.submit/1` accepts goals with priority/source/tags/repo fields, `RepoRegistry.list_repos/0` provides priority-ordered repo list, and `CostLedger` already has `:improving` budget limits (10/hour, 40/day). The XML schemas for `ScanResult` and `Improvement` are already defined. The HubFSM currently has 2 states (resting/executing) -- the Improving state transition must be added as a prerequisite or part of this phase.

**Primary recommendation:** Build `SelfImprovement` as a pure library module with three sub-scanners, each returning a common `ScanResult`-compatible finding struct. Use DETS for improvement history with file-path keyed records containing timestamps and change descriptions. Detect oscillation by comparing consecutive improvement descriptions for the same file using simple string similarity or inverse-pattern matching.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
1. **Elixir tool integration**: Run `mix credo` and `mix dialyzer` on Elixir repos. Parse structured output for actionable findings.
2. **Deterministic analysis**: Test coverage gaps (modules without test files), documentation gaps (modules without @moduledoc), dead dependencies (deps in mix.exs not used in code).
3. **LLM-assisted review**: Send git diff (recent changes) + file context to Claude Code CLI. Ask for refactoring, simplification, and improvement opportunities.
4. **Scanning Strategy**: Cycle through repos in priority order (RepoRegistry). Per repo: deterministic scans first (no LLM cost), then LLM scans. Convert findings to goals in GoalBacklog. Rate limit: configurable max findings per scan cycle.
5. **Anti-Sisyphus Protections**: Improvement history in DETS. File-level cooldowns. Anti-oscillation detection. Improvement budget (max N findings per scan cycle).
6. **SelfImprovement module as a library (not GenServer)** -- called by HubFSM during Improving state.
7. Findings should include estimated effort/complexity for tiered autonomy (Phase 34).
8. Self-generated improvement goals default to "low" priority in GoalBacklog.
9. Anti-oscillation detection is mandatory (Pitfall #2 prevention).

### Claude's Discretion
- Credo/Dialyzer output parsing strategy
- Finding priority classification (which findings become goals first)
- LLM prompt design for improvement identification
- Cooldown duration defaults
- How to detect oscillation patterns

### Deferred Ideas (OUT OF SCOPE)
- None explicitly deferred.
</user_constraints>

## Standard Stack

### Core (Already in Project)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| DETS (Erlang stdlib) | OTP 27+ | Persistent improvement history storage | Already used for GoalBacklog, CostLedger, RepoRegistry -- proven pattern |
| System.cmd/3 | Elixir stdlib | Shell out to `mix credo` and `mix dialyzer` | Standard Elixir approach for CLI tool invocation |
| Jason | ~> 1.4 | Parse Credo JSON output | Already a project dependency |
| ClaudeClient | internal | LLM-assisted improvement identification | Already implements `identify_improvements/2` |
| GoalBacklog | internal | Destination for improvement findings as goals | Already supports `submit/1` with priority, source, tags |

### External Tools (Must Be Available in Target Repos)
| Tool | Purpose | Detection Strategy |
|------|---------|-------------------|
| Credo | Static analysis for code consistency | Check for `{:credo, ...}` in target repo's `mix.exs` deps |
| Dialyxir | Dialyzer wrapper for type analysis | Check for `{:dialyxir, ...}` in target repo's `mix.exs` deps |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `mix credo --format json` | `mix credo --format flycheck` | JSON is richer (has priority, column, trigger, explanation) -- use JSON |
| `mix dialyzer --format short` | `mix dialyzer --format github` | Short format is more compact but github format has structured `::warning file=X,line=Y::message` -- recommend short for easier Elixir-native parsing |
| DETS for history | ETS + periodic dump | DETS survives restarts natively, consistent with project patterns |

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  self_improvement.ex               # Main library module - scan_repo/2, scan_all/1
  self_improvement/
    credo_scanner.ex                 # mix credo --format json integration
    dialyzer_scanner.ex              # mix dialyzer --format short integration
    deterministic_scanner.ex         # Test gaps, doc gaps, dead deps
    llm_scanner.ex                   # ClaudeClient.identify_improvements wrapper
    improvement_history.ex           # DETS-backed history + cooldown + oscillation
    finding.ex                       # Common finding struct (scan_type, file, severity, effort)
```

### Pattern 1: Stateless Library Module (Like RepoScanner)
**What:** SelfImprovement is a library module with no GenServer, no supervision, no state. Called on demand by HubFSM during Improving state tick.
**When to use:** When the module is called periodically and doesn't need to maintain running state.
**Why:** Matches the existing RepoScanner pattern. The state (history, cooldowns) lives in DETS, not in-process. No supervision overhead.
**Example:**
```elixir
defmodule AgentCom.SelfImprovement do
  alias AgentCom.SelfImprovement.{
    CredoScanner, DialyzerScanner, DeterministicScanner,
    LlmScanner, ImprovementHistory
  }

  @default_max_findings 5

  @spec scan_repo(String.t(), keyword()) :: {:ok, [Finding.t()]} | {:error, term()}
  def scan_repo(repo_path, opts \\ []) do
    max_findings = Keyword.get(opts, :max_findings, @default_max_findings)
    repo_name = Keyword.get(opts, :repo_name, Path.basename(repo_path))

    # Layer 1: Deterministic tool scans (no LLM cost)
    credo_findings = CredoScanner.scan(repo_path)
    dialyzer_findings = DialyzerScanner.scan(repo_path)

    # Layer 2: Deterministic analysis
    det_findings = DeterministicScanner.scan(repo_path)

    all_deterministic = credo_findings ++ dialyzer_findings ++ det_findings

    # Filter out cooled-down files
    filtered = ImprovementHistory.filter_cooled_down(all_deterministic, repo_name)

    # Filter out oscillating files
    filtered = ImprovementHistory.filter_oscillating(filtered, repo_name)

    # Budget: take up to max_findings from deterministic
    {det_batch, remaining_budget} = take_budget(filtered, max_findings)

    # Layer 3: LLM-assisted review (only if budget remains)
    llm_findings =
      if remaining_budget > 0 do
        case LlmScanner.scan(repo_path, repo_name) do
          {:ok, findings} ->
            findings
            |> ImprovementHistory.filter_cooled_down(repo_name)
            |> ImprovementHistory.filter_oscillating(repo_name)
            |> Enum.take(remaining_budget)
          {:error, _} -> []
        end
      else
        []
      end

    all_findings = det_batch ++ llm_findings
    {:ok, all_findings}
  end
end
```

### Pattern 2: DETS-Backed Improvement History
**What:** Persistent record of all improvements attempted, keyed by `{repo, file_path}`, storing timestamps, scan types, and change descriptions for cooldown and oscillation detection.
**When to use:** Every time a finding is converted to a goal, record it. Before scanning, check cooldowns and oscillation.
**Example:**
```elixir
defmodule AgentCom.SelfImprovement.ImprovementHistory do
  @dets_table :improvement_history
  @default_cooldown_ms 24 * 60 * 60 * 1000  # 24 hours

  def init do
    dir = data_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "improvement_history.dets") |> String.to_charlist()
    :dets.open_file(@dets_table, file: path, type: :set, auto_save: 5_000)
  end

  def record_improvement(repo, file_path, scan_type, description) do
    key = {repo, file_path}
    now = System.system_time(:millisecond)
    entry = %{scan_type: scan_type, description: description, timestamp: now}

    existing = case :dets.lookup(@dets_table, key) do
      [{^key, records}] -> records
      _ -> []
    end

    updated = [entry | existing] |> Enum.take(10)  # Keep last 10
    :dets.insert(@dets_table, {key, updated})
    :dets.sync(@dets_table)
  end

  def cooled_down?(repo, file_path, cooldown_ms \\ @default_cooldown_ms) do
    key = {repo, file_path}
    now = System.system_time(:millisecond)

    case :dets.lookup(@dets_table, key) do
      [{^key, [latest | _]}] -> (now - latest.timestamp) < cooldown_ms
      _ -> false
    end
  end

  def oscillating?(repo, file_path) do
    key = {repo, file_path}

    case :dets.lookup(@dets_table, key) do
      [{^key, records}] when length(records) >= 3 ->
        detect_oscillation(records)
      _ -> false
    end
  end
end
```

### Pattern 3: Finding-to-Goal Conversion
**What:** Convert scan findings into GoalBacklog goals with consistent structure.
**When to use:** After a scan cycle completes and findings pass all filters.
**Example:**
```elixir
def submit_findings_as_goals(findings, repo_name) do
  Enum.map(findings, fn finding ->
    AgentCom.GoalBacklog.submit(%{
      description: finding.description,
      success_criteria: finding.suggested_action,
      priority: "low",
      source: "self_improvement",
      tags: [finding.scan_type, "auto-scan"],
      repo: repo_name,
      file_hints: [finding.file_path],
      metadata: %{
        scan_type: finding.scan_type,
        severity: finding.severity,
        effort: finding.effort,
        scanner: finding.scanner
      }
    })
  end)
end
```

### Anti-Patterns to Avoid
- **GenServer for SelfImprovement:** No ongoing state needed. The DETS history is the persistent state. Making it a GenServer adds supervision complexity without benefit.
- **Scanning all repos in one tick:** Scan one repo per HubFSM tick cycle. Spread work across ticks to avoid blocking.
- **Unbounded findings:** Always enforce max_findings budget. Without it, a repo with 200 Credo warnings floods the GoalBacklog.
- **Running Credo/Dialyzer on repos that don't have them:** Always check `mix.exs` for the dependency before attempting to run the tool.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Elixir static analysis | Custom AST walker for code quality | `mix credo --format json` | Credo has 100+ checks, battle-tested, community standard |
| Type checking | Custom type inference | `mix dialyzer --format short` | Dialyzer is the standard Erlang/Elixir type checker |
| JSON parsing | Manual string parsing of Credo output | `Jason.decode!/1` | Already in deps, handles all edge cases |
| Git diff generation | Custom file comparison | `System.cmd("git", ["diff", "--stat", ...])` | Git is the authority on what changed |
| DETS management | Custom file persistence | `:dets` module directly | Proven pattern in this codebase (6+ tables) |

**Key insight:** The three scanning layers each leverage existing tools. The value of SelfImprovement is the orchestration, filtering (cooldowns/oscillation), and conversion to goals -- not reimplementing analysis.

## Common Pitfalls

### Pitfall 1: Sisyphus Loops (Anti-Oscillation)
**What goes wrong:** Scanner finds issue X in file A, creates goal, agent fixes it. Next scan: scanner finds issue Y in file A that conflicts with the fix for X. Agent "fixes" Y, which reintroduces X. Infinite loop.
**Why it happens:** Different scanners or even different Credo checks can have conflicting recommendations (e.g., "extract function" vs "inline function").
**How to avoid:**
1. **File cooldowns:** After improving file X, don't re-scan X for 24 hours (configurable).
2. **Oscillation detection:** Track last N improvements per file. If the same file has 3+ improvements in a short window, compare descriptions. If descriptions contain inverse patterns (add/remove, extract/inline, increase/decrease), flag as oscillating and block further scans.
3. **Improvement budget:** Max N findings per scan cycle prevents flooding.
**Warning signs:** Same file appearing in findings repeatedly. Goal count growing but code quality metrics not improving.

### Pitfall 2: Credo/Dialyzer Not Available
**What goes wrong:** SelfImprovement tries to run `mix credo` on a repo that doesn't have Credo as a dependency. Command fails with cryptic error.
**Why it happens:** Not all Elixir repos include Credo/Dialyxir in their mix.exs.
**How to avoid:** Before running any tool, parse the target repo's `mix.exs` and check for `{:credo, ...}` or `{:dialyxir, ...}` in the deps list. Skip the scanner if the dependency is not present.
**Warning signs:** Repeated CLI errors for a specific repo.

### Pitfall 3: LLM Cost Explosion
**What goes wrong:** LLM scanner runs on every repo every cycle, exhausting the improving budget quickly.
**Why it happens:** LLM scans are the most expensive layer but also the most interesting.
**How to avoid:** Always run deterministic scans first. Only invoke LLM scanner if deterministic scans found fewer than max_findings. CostLedger already enforces improving budget (10/hour, 40/day).
**Warning signs:** CostLedger showing high improving invocation counts with few completed improvement goals.

### Pitfall 4: HubFSM Improving State Not Yet Implemented
**What goes wrong:** Phase 32 assumes HubFSM has an Improving state, but the current FSM only has resting/executing.
**Why it happens:** Phase 29 implemented 2-state core. The 4-state expansion was planned for later.
**How to avoid:** Phase 32 must either (a) add the Improving state to HubFSM as part of its implementation, or (b) depend on a separate phase that adds it. The infrastructure already supports it: CostLedger has `:improving` budgets, ClaudeClient accepts `:improving` as a valid hub state, XML FSM snapshot schema includes "improving".
**Warning signs:** SelfImprovement module works in isolation but never gets called because HubFSM never enters Improving state.

### Pitfall 5: Large Diffs Overwhelming LLM Context
**What goes wrong:** Git diff for a repo with many recent changes produces a massive diff that exceeds context limits or produces low-quality analysis.
**Why it happens:** `git diff` without bounds can produce megabytes of output.
**How to avoid:** Limit diff scope: `git diff HEAD~5..HEAD --stat` for summary, then `git diff HEAD~5..HEAD -- <specific_files>` for targeted analysis. Cap diff size (e.g., 50KB max). If too large, split into per-file diffs.
**Warning signs:** ClaudeClient timeouts during improvement identification.

## Code Examples

### Credo JSON Output Parsing
**Confidence:** HIGH (verified via official docs)
```elixir
defmodule AgentCom.SelfImprovement.CredoScanner do
  @doc """
  Run mix credo on a repo and parse JSON output into findings.
  Returns list of findings or empty list on error.
  """
  def scan(repo_path) do
    # Check if credo is available
    unless has_credo?(repo_path), do: return([])

    case System.cmd("mix", ["credo", "--format", "json", "--all"],
           cd: repo_path,
           stderr_to_stdout: true,
           env: [{"MIX_ENV", "dev"}]) do
      {output, _exit_code} ->
        # Credo returns exit code 1 when issues found -- that's normal
        parse_credo_json(output, repo_path)
      _ ->
        []
    end
  end

  defp parse_credo_json(output, repo_path) do
    case Jason.decode(output) do
      {:ok, %{"issues" => issues}} ->
        Enum.map(issues, fn issue ->
          %{
            file_path: issue["filename"],
            line_number: issue["line_no"],
            scan_type: "credo_" <> (issue["category"] || "unknown"),
            description: issue["message"],
            severity: credo_priority_to_severity(issue["priority"]),
            suggested_action: issue["message"],
            effort: "small",
            scanner: :credo
          }
        end)

      {:error, _} ->
        # JSON parse failed -- maybe credo output was not pure JSON
        []
    end
  end

  defp credo_priority_to_severity(priority) when priority >= 10, do: "high"
  defp credo_priority_to_severity(priority) when priority >= 1, do: "medium"
  defp credo_priority_to_severity(_), do: "low"

  defp has_credo?(repo_path) do
    mix_exs = Path.join(repo_path, "mix.exs")
    case File.read(mix_exs) do
      {:ok, content} -> String.contains?(content, ":credo")
      _ -> false
    end
  end
end
```

### Dialyzer Short Format Parsing
**Confidence:** HIGH (verified via hexdocs.pm/dialyxir)
```elixir
defmodule AgentCom.SelfImprovement.DialyzerScanner do
  @doc """
  Run mix dialyzer on a repo and parse short-format output into findings.
  Note: Dialyzer can take minutes to run on first invocation (PLT building).
  """
  def scan(repo_path) do
    unless has_dialyxir?(repo_path), do: return([])

    # Use --format short for compact, parseable output
    # Use --quiet to suppress progress messages
    case System.cmd("mix", ["dialyzer", "--format", "short", "--quiet"],
           cd: repo_path,
           stderr_to_stdout: true,
           env: [{"MIX_ENV", "dev"}]) do
      {output, 0} ->
        # Exit 0 = no warnings
        []

      {output, 2} ->
        # Exit 2 = warnings found
        parse_dialyzer_short(output)

      _ ->
        []
    end
  end

  defp parse_dialyzer_short(output) do
    # Short format: "lib/foo.ex:42:unknown_type The type ..."
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^(.+):(\d+):(\w+)\s+(.+)$/, line) do
        [_, file, line_no, warning_type, message] ->
          [%{
            file_path: file,
            line_number: String.to_integer(line_no),
            scan_type: "dialyzer_#{warning_type}",
            description: message,
            severity: "medium",
            suggested_action: "Fix Dialyzer warning: #{message}",
            effort: "medium",
            scanner: :dialyzer
          }]
        _ ->
          []
      end
    end)
  end

  defp has_dialyxir?(repo_path) do
    mix_exs = Path.join(repo_path, "mix.exs")
    case File.read(mix_exs) do
      {:ok, content} -> String.contains?(content, ":dialyxir")
      _ -> false
    end
  end
end
```

### Deterministic Test Gap Scanner
**Confidence:** HIGH (pure Elixir file system operations)
```elixir
defmodule AgentCom.SelfImprovement.DeterministicScanner do
  def scan(repo_path) do
    test_gaps(repo_path) ++ doc_gaps(repo_path) ++ dead_deps(repo_path)
  end

  defp test_gaps(repo_path) do
    lib_modules = find_elixir_modules(Path.join(repo_path, "lib"))
    test_files = find_elixir_files(Path.join(repo_path, "test"))

    Enum.flat_map(lib_modules, fn {module_path, _module_name} ->
      expected_test = module_path
        |> String.replace("lib/", "test/")
        |> String.replace(".ex", "_test.exs")

      full_test_path = Path.join(repo_path, expected_test)

      if not File.exists?(full_test_path) do
        [%{
          file_path: module_path,
          line_number: 1,
          scan_type: "test_gap",
          description: "Module has no corresponding test file (expected #{expected_test})",
          severity: "medium",
          suggested_action: "Create #{expected_test}",
          effort: "medium",
          scanner: :deterministic
        }]
      else
        []
      end
    end)
  end

  defp doc_gaps(repo_path) do
    lib_modules = find_elixir_modules(Path.join(repo_path, "lib"))

    Enum.flat_map(lib_modules, fn {module_path, _} ->
      full_path = Path.join(repo_path, module_path)
      case File.read(full_path) do
        {:ok, content} ->
          if String.contains?(content, "defmodule") and
             not String.contains?(content, "@moduledoc") do
            [%{
              file_path: module_path,
              line_number: 1,
              scan_type: "doc_gap",
              description: "Module missing @moduledoc",
              severity: "low",
              suggested_action: "Add @moduledoc to module",
              effort: "small",
              scanner: :deterministic
            }]
          else
            []
          end
        _ -> []
      end
    end)
  end

  defp dead_deps(repo_path) do
    mix_exs = Path.join(repo_path, "mix.exs")
    case File.read(mix_exs) do
      {:ok, mix_content} ->
        declared_deps = extract_dep_names(mix_content)
        lib_files = find_all_source_files(repo_path)
        all_source = Enum.map(lib_files, fn f ->
          case File.read(f) do
            {:ok, c} -> c
            _ -> ""
          end
        end) |> Enum.join("\n")

        Enum.flat_map(declared_deps, fn dep_name ->
          # Check if dep module is referenced in source code
          # Convert dep name (e.g., :jason) to likely module name (e.g., "Jason")
          module_name = dep_name |> Atom.to_string() |> Macro.camelize()

          if not String.contains?(all_source, module_name) do
            [%{
              file_path: "mix.exs",
              line_number: 1,
              scan_type: "dead_dep",
              description: "Dependency :#{dep_name} may be unused (#{module_name} not found in source)",
              severity: "low",
              suggested_action: "Verify if :#{dep_name} is still needed",
              effort: "small",
              scanner: :deterministic
            }]
          else
            []
          end
        end)
      _ -> []
    end
  end
end
```

### Oscillation Detection
**Confidence:** MEDIUM (custom implementation, no existing library)
```elixir
defp detect_oscillation(records) when length(records) >= 3 do
  # Take the last 3 improvements for this file
  [r1, r2, r3 | _] = records

  # Check for inverse patterns in descriptions
  inverse_pairs = [
    {"add", "remove"}, {"extract", "inline"}, {"increase", "decrease"},
    {"enable", "disable"}, {"split", "merge"}, {"expand", "collapse"}
  ]

  descs = [r1.description, r2.description, r3.description]
    |> Enum.map(&String.downcase/1)

  # If any two consecutive descriptions contain inverse terms, flag oscillation
  Enum.any?(inverse_pairs, fn {a, b} ->
    has_term = fn desc, term -> String.contains?(desc, term) end

    (has_term.(Enum.at(descs, 0), a) and has_term.(Enum.at(descs, 1), b)) or
    (has_term.(Enum.at(descs, 0), b) and has_term.(Enum.at(descs, 1), a)) or
    (has_term.(Enum.at(descs, 1), a) and has_term.(Enum.at(descs, 2), b)) or
    (has_term.(Enum.at(descs, 1), b) and has_term.(Enum.at(descs, 2), a))
  end)
end

defp detect_oscillation(_), do: false
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Credo text-only output | `mix credo --format json` with structured fields | Credo 1.5+ | Enables programmatic parsing with priority, filename, line_no, category, trigger |
| Dialyzer raw output | `mix dialyzer --format short` (Dialyxir 1.x) | Dialyxir 1.0+ | Compact parseable format with file:line:warning_type message structure |
| Manual code review for improvements | LLM-assisted analysis via git diff | 2024-2025 | Enables finding higher-level improvements (architecture, patterns) that tools miss |

**Deprecated/outdated:**
- Credo `--format flycheck`: Still works but JSON provides richer data (priority, trigger, explanation).
- Dialyzer raw format: Still available but short format is more suitable for automated parsing.

## Critical Implementation Notes

### HubFSM Improving State
The HubFSM currently has only 2 states (resting, executing). Phase 32 requires the Improving state. The infrastructure already supports it:
- `CostLedger` has `:improving` in `@hub_states` with budget limits (10/hour, 40/day)
- `ClaudeClient` accepts `:improving` in `@valid_hub_states`
- `XML.Schemas.FsmSnapshot` has "improving" in `@valid_states`
- Dashboard CSS already has `improving: '#facc15'` color

The planner must include a task to add the `improving` state to `HubFSM.@valid_transitions` and `HubFSM.Predicates.evaluate/2`. The transition logic: when resting with no pending goals but improving budget available, transition to `:improving`. When improving and a goal is submitted, transition to `:executing`. When improving and improvement scan completes, transition back to `:resting`.

### DETS Table Registration
The new `:improvement_history` DETS table must be added to `DetsBackup.@tables` list for backup/recovery/compaction support. This requires also adding a `table_owner/1` clause and a `get_table_path/1` clause in DetsBackup.

### Existing ClaudeClient Integration
`ClaudeClient.identify_improvements/2` already exists with prompt template and response parser. The LLM scanner should use this directly rather than building a new CLI invocation. The existing prompt asks for improvements with title, description, category, effort, and files -- which aligns with the finding struct.

### Credo Output Format
Credo JSON output structure (verified via hexdocs.pm/credo):
```json
{
  "issues": [
    {
      "category": "refactor",
      "check": "Credo.Check.Refactor.PipeChainStart",
      "column": null,
      "column_end": null,
      "filename": "lib/my_app/foo.ex",
      "line_no": 12,
      "message": "Pipe chain should start with a raw value.",
      "priority": 2,
      "trigger": "TODO"
    }
  ]
}
```

### Dialyzer Short Format
Dialyzer short format output (verified via hexdocs.pm/dialyxir):
```
lib/foo.ex:42:unknown_type The type specification...
```
Format: `file:line:warning_name message`

### Cooldown Duration Recommendation
**Recommendation:** Default 24-hour cooldown per file. Configurable via `AgentCom.Config.get(:improvement_cooldown_ms)`. Rationale: most improvement goals take less than 24 hours to process through the pipeline, so this prevents re-scanning files that have pending improvement goals.

### Finding Priority Classification Recommendation
**Recommendation:** Classify findings into priority tiers based on scanner and severity:
1. **Dialyzer warnings** (type errors are high-value, low-effort for type-safe languages) -> high severity
2. **Test gaps** (modules without tests are medium risk) -> medium severity
3. **Credo issues** (code quality, but rarely blocking) -> low-medium severity based on Credo priority
4. **Doc gaps** (nice to have, not blocking) -> low severity
5. **Dead deps** (cleanup, not blocking) -> low severity
6. **LLM suggestions** (variable quality) -> low severity unless specifically identified as high-impact

All self-improvement goals still get "low" priority in GoalBacklog per the locked decision, but severity within findings helps the system prioritize which findings become goals first when under budget.

### LLM Prompt Enhancement Recommendation
The existing `ClaudeClient.Prompt.build(:identify_improvements, ...)` prompt is good but could be enhanced for the self-improvement use case:
- Add instruction to estimate effort per improvement (already in response schema)
- Add instruction to avoid suggesting changes that conflict with existing Credo/Dialyzer rules
- Limit to 3-5 focused improvements rather than exhaustive list
- Include file cooldown context: "Do not suggest improvements for these files: [cooled_down_files]"

## Open Questions

1. **Dialyzer PLT Build Time**
   - What we know: First `mix dialyzer` invocation builds a PLT (Persistent Lookup Table) that can take 5-30 minutes. Subsequent runs are fast.
   - What's unclear: Should the scanner handle PLT building? Should it skip Dialyzer if PLT doesn't exist?
   - Recommendation: Skip Dialyzer scan if PLT doesn't exist (check for `_build/*/plt` directory). Document that PLT must be pre-built for Dialyzer scanning to work. This avoids blocking the scan cycle for 30 minutes.

2. **Repo Local Path Resolution**
   - What we know: RepoRegistry stores repo URLs, not local paths. RepoScanner uses `base_dir` + repo name.
   - What's unclear: How does SelfImprovement resolve a repo URL to a local checkout path?
   - Recommendation: Follow RepoScanner pattern -- accept a `base_dir` option, derive repo name from URL, construct local path as `Path.join(base_dir, repo_name)`. Verify directory exists before scanning.

3. **Improving State Transition Timing**
   - What we know: HubFSM needs an Improving state. CostLedger already has improving budgets.
   - What's unclear: Should the Improving state be added in this phase or as a prerequisite?
   - Recommendation: Add it in this phase. The change is small (2-3 predicate clauses + 1 transition map entry) and tightly coupled to scanning behavior.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `AgentCom.ClaudeClient`, `AgentCom.GoalBacklog`, `AgentCom.RepoRegistry`, `AgentCom.RepoScanner`, `AgentCom.CostLedger`, `AgentCom.HubFSM`, `AgentCom.DetsBackup` -- all read and analyzed
- [Credo basic_usage](https://hexdocs.pm/credo/basic_usage.html) -- JSON output format with issues array containing category, check, filename, line_no, message, priority, trigger fields
- [Dialyxir Mix.Tasks.Dialyzer](https://hexdocs.pm/dialyxir/Mix.Tasks.Dialyzer.html) -- Output formats: short, raw, dialyxir, dialyzer, github, ignore_file, ignore_file_strict
- `AgentCom.XML.Schemas.ScanResult` and `AgentCom.XML.Schemas.Improvement` -- Already defined structs for scan findings and improvements

### Secondary (MEDIUM confidence)
- [Getting Started with Dialyzer in Elixir](https://blog.appsignal.com/2025/03/18/getting-started-with-dialyzer-in-elixir.html) -- PLT building and usage patterns

### Tertiary (LOW confidence)
- Oscillation detection approach: Custom design based on inverse-pattern matching. No established library or pattern exists for this specific use case. Should be validated with real-world usage.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All tools are existing Elixir ecosystem standards already in use or well-documented
- Architecture: HIGH - Follows established codebase patterns (library module like RepoScanner, DETS persistence like GoalBacklog)
- Credo/Dialyzer parsing: HIGH - Verified output formats via official hexdocs
- Anti-oscillation detection: MEDIUM - Custom design, no established pattern to reference
- HubFSM integration: HIGH - Infrastructure already prepared, just needs state machine expansion

**Research date:** 2026-02-13
**Valid until:** 2026-03-15 (stable domain, tools change slowly)
