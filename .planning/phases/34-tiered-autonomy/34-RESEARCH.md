# Phase 34: Tiered Autonomy - Research

**Researched:** 2026-02-13
**Domain:** Risk classification for completed tasks, PR-only workflow
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Tier 1 (auto-merge candidate): trivial/standard complexity, <20 lines changed, test-covered, no new files, no config changes
- Tier 2 (PR for review): complex tasks, new files, API changes, >20 lines
- Tier 3 (block and escalate): auth code, deployment config, failed verification
- Start conservative: all tiers produce PRs (PR-only mode)
- Auto-merge enabled per-tier only after configurable success threshold (e.g., 20 successful PRs)
- Classification based on: complexity_tier from task, lines changed, files touched, file paths (protected path list), whether tests exist for changed files
- Pure function module (no GenServer needed)
- Configurable thresholds via Config GenServer
- Every completed task creates a PR regardless of tier
- PR description includes risk tier classification and reasoning
- Human reviews and merges (or configures auto-merge for specific tiers later)

### Claude's Discretion
- Specific threshold values for each tier
- Protected path list (which directories/files trigger Tier 3)
- PR description template
- How to track successful PR history for auto-merge enablement

### Deferred Ideas (OUT OF SCOPE)
- None explicitly deferred
</user_constraints>

## Summary

Phase 34 adds a **risk classification layer** between task completion and PR creation. When a task completes, the system classifies the actual code changes (not just the task description) into one of three risk tiers based on multiple signals: the task's complexity tier, lines changed, files touched, whether touched files are on a protected path list, and whether tests exist for the changed files. This classification is embedded in the PR description and as a GitHub label so humans can make informed review decisions.

The implementation is a pure function module `AgentCom.RiskClassifier` that takes a completed task map and git diff metadata, returning a risk tier with reasoning. Thresholds are stored in `AgentCom.Config` GenServer (DETS-backed, hot-reloadable). The sidecar's `agentcom-git.js` submit command gathers diff metadata via `git diff --numstat` and `git diff --name-status`, then the sidecar computes classification locally (reading thresholds from a classify endpoint on the hub) or the hub provides classification via a new API endpoint. No new GenServers, no auto-merge logic -- just classification and PR enrichment.

**Primary recommendation:** Build `AgentCom.RiskClassifier` as a pure function module with `classify/2`. For the data flow, add a new hub endpoint `POST /api/tasks/:id/classify` that accepts diff metadata and returns classification. The sidecar calls this AFTER verification but BEFORE PR creation, then includes the classification in the PR body and as a GitHub label.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir stdlib | 1.16+ | Pattern matching, pure functions | Already in use throughout codebase |
| AgentCom.Config | existing | Threshold storage via DETS | Locked decision: configurable via Config GenServer |
| agentcom-git.js | existing | PR creation with `gh` CLI | Locked decision: integrate with existing git-workflow.js |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| :telemetry | existing | Emit classification events | Dashboard observability (Phase 36) |
| Jason | existing | JSON encode/decode | PR body data exchange between Elixir and sidecar |

### Alternatives Considered
None -- all technology choices are locked by existing codebase patterns. No new libraries needed.

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  risk_classifier.ex           # Pure function module: classify/2, tier logic
```

No subdirectory needed. Config thresholds are read from `AgentCom.Config` inline (not a separate config module). This mirrors how `AgentCom.Complexity` works -- single module, reads config inline, no sub-modules.

### Pattern 1: Pure Function Classifier (Mirrors AgentCom.Complexity)
**What:** A stateless module with a single `classify/2` entry point that takes a task map and diff metadata, returns a classification map. Follows the exact gather-signals-then-classify pattern used in `AgentCom.Complexity` (found at `lib/agent_com/complexity.ex`).
**When to use:** Always -- this is the locked decision (no GenServer).
**Codebase reference:** `AgentCom.Complexity.build/1` at line 57 uses `gather_signals/1` then `classify/1` then builds result map. The risk classifier should follow this identical pattern.

**Example:**
```elixir
# Source: mirrors lib/agent_com/complexity.ex pattern
defmodule AgentCom.RiskClassifier do
  @moduledoc """
  Classifies completed tasks into risk tiers based on actual code changes.
  Pure function module (no GenServer).

  ## Risk Tiers

  - Tier 1 (auto-merge candidate): trivial/standard complexity, <20 lines,
    test-covered, no new files, no config changes
  - Tier 2 (PR for review): complex tasks, new files, API changes, >20 lines
  - Tier 3 (block and escalate): auth code, deployment config, failed verification
  """

  alias AgentCom.Config

  @type classification :: %{
    tier: 1 | 2 | 3,
    reasons: [String.t()],
    auto_merge_eligible: boolean(),
    signals: map()
  }

  @spec classify(task :: map(), diff_meta :: map()) :: classification()
  def classify(task, diff_meta) when is_map(task) and is_map(diff_meta) do
    signals = gather_signals(task, diff_meta)

    cond do
      tier3?(signals) -> build_result(3, signals)
      tier1?(signals) -> build_result(1, signals)
      true -> build_result(2, signals)
    end
  end

  # No diff data -> Tier 2 (conservative default)
  def classify(task, nil), do: classify(task, %{})
end
```

### Pattern 2: Signal Gathering
**What:** Gather multiple independent signals from the task map and diff metadata, then combine via deterministic rules. This is the exact pattern in `AgentCom.Complexity.gather_signals/1` (line 101).
**Signals map:**
```elixir
%{
  complexity_tier: :standard,        # from task.complexity.effective_tier
  lines_changed: 15,                 # lines_added + lines_deleted from diff
  files_changed: ["lib/foo.ex"],     # from diff metadata
  files_added: [],                   # from diff name-status (new files)
  new_file_count: 0,                 # length(files_added)
  file_count: 1,                     # length(files_changed)
  tests_exist: true,                 # whether test files exist for changed code
  verification_passed: true,         # from task.verification_report
  protected_paths_touched: [],       # files matching protected path patterns
  config_files_touched: false        # computed from files vs protected list
}
```

### Pattern 3: Config-Driven Thresholds via Existing Config GenServer
**What:** Store all tier thresholds in `AgentCom.Config` GenServer (DETS-backed, `lib/agent_com/config.ex`) so they can be changed at runtime without code changes.
**Existing pattern:** `AgentCom.Config.get/1` returns stored value or default from `@defaults` map (line 48-56). New keys follow same pattern -- if not stored in DETS, return module-level defaults.
**Why not add to @defaults:** The Config GenServer `@defaults` map (line 10-17) currently has 5 keys. Risk classifier defaults should live in the `RiskClassifier` module itself (using `Config.get(:key) || @default_value`) rather than bloating the Config module. This mirrors how `AgentCom.Alerter` uses `Config.get(:alert_thresholds)` with its own defaults.

**Config keys to add (all prefixed `risk_` per namespace convention):**
```elixir
:risk_tier1_max_lines         # default: 20
:risk_tier1_max_files         # default: 3
:risk_tier1_allowed_tiers     # default: [:trivial, :standard]
:risk_tier3_protected_paths   # default: ["config/", "rel/", ".github/", ...]
:risk_tier3_auth_paths        # default: ["lib/agent_com/auth", ...]
:risk_auto_merge_tier1        # default: false
:risk_auto_merge_tier2        # default: false
:risk_auto_merge_threshold    # default: 20
```

### Pattern 4: Hub API Endpoint for Classification
**What:** New endpoint `POST /api/tasks/:task_id/classify` that accepts diff metadata from the sidecar, classifies via `RiskClassifier.classify/2`, stores the classification on the task, and returns it.
**Why hub-side:** Thresholds live in `AgentCom.Config` GenServer on the Elixir side. Centralizing classification logic means config changes take effect immediately for all sidecars without restarting them. The sidecar only gathers raw diff data.
**Endpoint pattern:** Follows existing `POST /api/tasks/:task_id/retry` pattern (endpoint.ex line 1214). Auth required, rate limited.

**Data flow (decisive recommendation):**
1. Task completes execution and passes verification in sidecar
2. Sidecar gathers diff metadata via git commands (numstat, name-status, name-only)
3. Sidecar calls `POST /api/tasks/:task_id/classify` with diff metadata JSON body
4. Hub runs `RiskClassifier.classify(task, diff_meta)`, stores classification on task
5. Hub returns classification (tier, reasons, auto_merge_eligible)
6. Sidecar includes classification in PR body via enhanced `generatePrBody()`
7. Sidecar adds `risk:tier-N` label to the PR
8. Sidecar calls `runGitCommand('submit', ...)` to create the PR
9. Sidecar sends `task_complete` via WebSocket (already existing flow)

### Pattern 5: PR Body Enrichment
**What:** Enhance `generatePrBody()` in `sidecar/agentcom-git.js` (line 108) to accept an optional risk classification and include it in the PR body.
**Current function signature:** `generatePrBody(task, agentId, diffStat, config)`
**New function signature:** `generatePrBody(task, agentId, diffStat, config, riskClassification)`
**Backward compatible:** If `riskClassification` is null/undefined, the Risk Classification section is omitted.

### Pattern 6: GitHub Label for Risk Tier
**What:** Add `risk:tier-1`, `risk:tier-2`, or `risk:tier-3` label to the PR alongside existing `agent:` and `priority:` labels.
**Existing label pattern:** `sidecar/agentcom-git.js` lines 258-263 create labels with `gh label create --force` then apply them in `gh pr create --label`.
**Implementation:** Same pattern -- create label if needed, add to `--label` flag in PR creation.

### Anti-Patterns to Avoid
- **Building a GenServer for classification:** Locked decision says pure function module. Classification is stateless computation. No process needed.
- **Hardcoding thresholds:** Must be configurable via Config GenServer. Use `Config.get(:key) || @default` pattern.
- **Coupling auto-merge logic into v1.3:** PR-only mode is the mandatory default. The `auto_merge_eligible` field in the classification is informational only. Do NOT implement any auto-merge capability.
- **Classifying before execution:** Classification requires actual diff data (lines changed, files touched), which only exists after the agent has done the work. Classification MUST happen after verification, before PR creation.
- **Duplicating complexity logic:** Risk tier classification is a LAYER on top of existing complexity classification. Complexity classifies the TASK DESCRIPTION (predicted). Risk classifies the COMPLETED WORK (actual changes). They are complementary, not duplicative. The risk classifier READS `task.complexity.effective_tier` as one of its inputs.
- **Computing classification in sidecar only:** Thresholds live in Config GenServer. If classification is done purely in JS, thresholds must be duplicated or fetched. Better to centralize on the hub.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Config storage | Custom config file reader | `AgentCom.Config` GenServer (lib/agent_com/config.ex) | Already persists to DETS, hot-reloadable |
| Diff parsing | Custom git diff parser | `git diff --numstat` + `git diff --name-status` output parsing | Git provides structured diff info; simple line parsing |
| PR creation | Custom GitHub API calls | Existing `agentcom-git.js` submit command (sidecar/agentcom-git.js) | Already handles auth, labels, temp files, conventional commits |
| Complexity detection | New complexity module | Existing `AgentCom.Complexity` (lib/agent_com/complexity.ex) | Already computes effective_tier on task submission |
| Task storage | New storage for classification | Existing task map in `AgentCom.TaskQueue` DETS (lib/agent_com/task_queue.ex) | Add risk_classification field to task map |

**Key insight:** The risk classifier builds ON TOP of existing infrastructure. It reads `task.complexity.effective_tier` (already computed on submit), reads diff metadata from the sidecar, and writes `risk_classification` back to the task map. No new storage layer needed.

## Common Pitfalls

### Pitfall 1: Classifying Based Only on Task Metadata
**What goes wrong:** Using only `task.complexity.effective_tier` to determine risk tier, ignoring actual diff data.
**Why it happens:** Complexity is already computed on task submission (lib/agent_com/task_queue.ex line 280: `complexity: AgentCom.Complexity.build(params)`), so it seems unnecessary to gather diff data.
**How to avoid:** The whole point of risk tiers is to classify ACTUAL changes, not predicted complexity. A "trivial" task might touch auth code. Always use diff metadata as the primary signal, with complexity tier as a secondary input.
**Warning signs:** Tests that only test task metadata, not diff scenarios.

### Pitfall 2: Diff Metadata Not Available
**What goes wrong:** The sidecar can't gather diff data (no git repo, no commits, network error).
**Why it happens:** Edge cases: tasks that produce no code changes (research tasks), sidecar has no `repo_dir` configured, git commands fail.
**How to avoid:** Default to Tier 2 (PR for review) when diff data is unavailable or empty. Never default to Tier 1. The `classify/2` function must handle `nil` and empty-map diff_meta gracefully.
**Warning signs:** `nil` or `%{}` diff metadata reaching the classifier without falling through to Tier 2.

### Pitfall 3: Protected Path List Gets Stale
**What goes wrong:** New sensitive directories added to the project but not to the protected path list.
**Why it happens:** Protected paths are configuration, not automatically derived from the codebase.
**How to avoid:** Use path prefix patterns (not exact matches) so `"config/"` catches `config/prod.exs`, `config/runtime.exs`, etc. Include common Elixir/Phoenix sensitive paths by default. Allow users to extend via `AgentCom.Config.put(:risk_tier3_protected_paths, [...])`.
**Warning signs:** Auth code PRs classified as Tier 1.

### Pitfall 4: Sidecar-Hub Data Flow Timing
**What goes wrong:** PR is created BEFORE classification is computed, so the PR body doesn't include the tier.
**Why it happens:** The current sidecar flow (index.js lines 232-271) does: verification -> git submit -> sendTaskComplete. Classification must be inserted BETWEEN verification and git submit.
**How to avoid:** The sidecar must call the hub's classify endpoint AFTER verification passes but BEFORE calling `runGitCommand('submit', ...)`. This requires modifying `handleResult()` in `sidecar/index.js`.
**Warning signs:** PRs without risk tier labels or classification section in the body.

### Pitfall 5: Verification Report Access Pattern
**What goes wrong:** The classifier checks `task.verification_report` but the report has inconsistent key formats (string keys from JSON vs atom keys from Elixir).
**Why it happens:** Verification reports come from the sidecar as JSON (string keys like `"status"`) but are stored in the task map. When the hub reads them, the keys may be strings or atoms depending on how they were stored.
**How to avoid:** The `get_verification_status/1` helper must check BOTH `%{"status" => "pass"}` (string keys) and `%{status: :pass}` (atom keys). The existing codebase has this pattern throughout (see TaskQueue line 229: `Map.get(params, :priority, Map.get(params, "priority", "normal"))`).
**Warning signs:** Tasks with passing verification being classified as Tier 3 because the key lookup failed.

### Pitfall 6: Config Key Namespace Collision
**What goes wrong:** Config keys like `:max_lines` collide with other features.
**Why it happens:** Flat key namespace in Config GenServer. No scoping mechanism.
**How to avoid:** Prefix ALL keys with `risk_` (e.g., `:risk_tier1_max_lines`). The codebase already uses this pattern: `fallback_wait_ms`, `task_ttl_ms`, `tier_down_alert_threshold_ms` all have descriptive prefixed names.
**Warning signs:** Unexpected values when reading config keys.

## Code Examples

### Risk Classifier Module (Complete)
```elixir
# Source: follows lib/agent_com/complexity.ex pattern exactly
defmodule AgentCom.RiskClassifier do
  @moduledoc """
  Classifies completed tasks into risk tiers based on actual code changes.
  Pure function module (no GenServer).

  ## Risk Tiers

  - Tier 1 (auto-merge candidate): trivial/standard complexity, <20 lines,
    test-covered, no new files, no config changes
  - Tier 2 (PR for review): complex tasks, new files, API changes, >20 lines
  - Tier 3 (block and escalate): auth code, deployment config, failed verification
  """

  alias AgentCom.Config

  @default_tier1_max_lines 20
  @default_tier1_max_files 3
  @default_tier1_allowed_complexity [:trivial, :standard]
  @default_protected_paths [
    "config/",
    "rel/",
    ".github/",
    "Dockerfile",
    "docker-compose",
    "mix.exs",
    "mix.lock"
  ]
  @default_auth_paths [
    "lib/agent_com/auth",
    "lib/agent_com/plugs/require_auth",
    "priv/cert",
    "priv/key",
    ".env"
  ]

  @type diff_meta :: %{
    lines_added: non_neg_integer(),
    lines_deleted: non_neg_integer(),
    files_changed: [String.t()],
    files_added: [String.t()],
    tests_exist: boolean()
  }

  @type classification :: %{
    tier: 1 | 2 | 3,
    reasons: [String.t()],
    auto_merge_eligible: boolean(),
    signals: map()
  }

  @doc """
  Classify a completed task based on its metadata and actual diff data.

  Returns `%{tier: 1|2|3, reasons: [...], auto_merge_eligible: bool, signals: map}`.
  """
  @spec classify(task :: map(), diff_meta :: diff_meta()) :: classification()
  def classify(task, diff_meta) when is_map(task) and is_map(diff_meta) do
    signals = gather_signals(task, diff_meta)
    tier = compute_tier(signals)
    result = build_result(tier, signals)

    :telemetry.execute(
      [:agent_com, :risk, :classified],
      %{lines_changed: signals.lines_changed, file_count: signals.file_count},
      %{
        tier: tier,
        complexity_tier: signals.complexity_tier,
        protected_paths: length(signals.protected_paths_touched),
        auto_merge_eligible: result.auto_merge_eligible
      }
    )

    result
  end

  # No diff data -> Tier 2 (conservative default)
  def classify(task, nil), do: classify(task, %{})

  # --- Private: Signal Gathering ---

  defp gather_signals(task, diff_meta) do
    complexity_tier = get_in(task, [:complexity, :effective_tier]) || :unknown
    lines_added = Map.get(diff_meta, :lines_added, 0)
    lines_deleted = Map.get(diff_meta, :lines_deleted, 0)
    lines_changed = lines_added + lines_deleted
    files_changed = Map.get(diff_meta, :files_changed, [])
    files_added = Map.get(diff_meta, :files_added, [])
    tests_exist = Map.get(diff_meta, :tests_exist, false)
    verification_passed = get_verification_status(task)

    protected = Config.get(:risk_tier3_protected_paths) || @default_protected_paths
    auth_paths = Config.get(:risk_tier3_auth_paths) || @default_auth_paths
    all_protected = protected ++ auth_paths

    protected_touched = Enum.filter(files_changed, fn f ->
      Enum.any?(all_protected, &String.contains?(f, &1))
    end)

    %{
      complexity_tier: complexity_tier,
      lines_changed: lines_changed,
      files_changed: files_changed,
      files_added: files_added,
      new_file_count: length(files_added),
      tests_exist: tests_exist,
      verification_passed: verification_passed,
      protected_paths_touched: protected_touched,
      file_count: length(files_changed)
    }
  end

  # --- Private: Tier Computation ---

  defp compute_tier(signals) do
    cond do
      tier3?(signals) -> 3
      tier1?(signals) -> 1
      true -> 2
    end
  end

  defp tier3?(signals) do
    signals.protected_paths_touched != [] or
      not signals.verification_passed
  end

  defp tier1?(signals) do
    max_lines = Config.get(:risk_tier1_max_lines) || @default_tier1_max_lines
    max_files = Config.get(:risk_tier1_max_files) || @default_tier1_max_files
    allowed = Config.get(:risk_tier1_allowed_tiers) || @default_tier1_allowed_complexity

    signals.complexity_tier in allowed and
      signals.lines_changed <= max_lines and
      signals.file_count <= max_files and
      signals.new_file_count == 0 and
      signals.tests_exist and
      signals.verification_passed
  end

  # --- Private: Result Building ---

  defp build_result(tier, signals) do
    %{
      tier: tier,
      reasons: build_reasons(tier, signals),
      auto_merge_eligible: tier == 1 and auto_merge_enabled?(1),
      signals: signals
    }
  end

  defp auto_merge_enabled?(tier) do
    key = String.to_atom("risk_auto_merge_tier#{tier}")
    Config.get(key) || false
  end

  # Handle both string and atom keys for verification report
  defp get_verification_status(task) do
    report = Map.get(task, :verification_report) || Map.get(task, "verification_report")

    case report do
      %{"status" => "pass"} -> true
      %{status: :pass} -> true
      %{"status" => "auto_pass"} -> true
      %{"status" => "skip"} -> true
      nil -> true   # No verification = passes by default
      _ -> false
    end
  end

  defp build_reasons(1, signals) do
    ["complexity: #{signals.complexity_tier}",
     "lines: #{signals.lines_changed}",
     "files: #{signals.file_count}",
     "new files: 0",
     "tests: present",
     "verification: passed"]
  end

  defp build_reasons(2, signals) do
    max_lines = Config.get(:risk_tier1_max_lines) || @default_tier1_max_lines
    allowed = Config.get(:risk_tier1_allowed_tiers) || @default_tier1_allowed_complexity
    reasons = []
    reasons = if signals.lines_changed > max_lines, do: ["lines: #{signals.lines_changed} (>#{max_lines})" | reasons], else: reasons
    reasons = if signals.new_file_count > 0, do: ["new files: #{signals.new_file_count}" | reasons], else: reasons
    reasons = if signals.complexity_tier not in allowed, do: ["complexity: #{signals.complexity_tier}" | reasons], else: reasons
    reasons = if not signals.tests_exist, do: ["no test coverage" | reasons], else: reasons
    if reasons == [], do: ["default tier for review"], else: Enum.reverse(reasons)
  end

  defp build_reasons(3, signals) do
    reasons = []
    reasons = if signals.protected_paths_touched != [], do: ["protected paths: #{Enum.join(signals.protected_paths_touched, ", ")}" | reasons], else: reasons
    reasons = if not signals.verification_passed, do: ["verification failed" | reasons], else: reasons
    if reasons == [], do: ["escalation required"], else: Enum.reverse(reasons)
  end
end
```

### Diff Metadata Gathering (Sidecar Side)
```javascript
// Source: new function in sidecar/agentcom-git.js
// Uses same git() helper already in the file (line 54)
function gatherDiffMeta(config) {
  let linesAdded = 0, linesDeleted = 0;
  const filesChanged = [];
  const filesAdded = [];

  try {
    const numstat = git('diff --numstat origin/main...HEAD', { _config: config });
    if (numstat) {
      numstat.split('\n').forEach(line => {
        const parts = line.split('\t');
        if (parts.length >= 3) {
          const [added, deleted, file] = parts;
          linesAdded += parseInt(added, 10) || 0;
          linesDeleted += parseInt(deleted, 10) || 0;
          filesChanged.push(file);
        }
      });
    }
  } catch { /* no diff available */ }

  try {
    const nameStatus = git('diff --name-status origin/main...HEAD', { _config: config });
    if (nameStatus) {
      nameStatus.split('\n').forEach(line => {
        const parts = line.split('\t');
        if (parts.length >= 2 && parts[0] === 'A') {
          filesAdded.push(parts[1]);
        }
      });
    }
  } catch { /* no diff available */ }

  // Check if test files exist for changed source files
  const fs = require('fs');
  const path = require('path');
  const testsExist = filesChanged.some(f => {
    if (!f.startsWith('lib/') || !f.endsWith('.ex')) return false;
    const testPath = f.replace('lib/', 'test/').replace('.ex', '_test.exs');
    return filesChanged.includes(testPath) ||
      fs.existsSync(path.join(config.repo_dir, testPath));
  });

  return {
    lines_added: linesAdded,
    lines_deleted: linesDeleted,
    files_changed: filesChanged,
    files_added: filesAdded,
    tests_exist: testsExist
  };
}
```

### New Hub API Endpoint
```elixir
# Source: follows POST /api/tasks/:task_id/retry pattern (endpoint.ex line 1214)
post "/api/tasks/:task_id/classify" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])

  if conn.halted do
    conn
  else
    case AgentCom.TaskQueue.get(task_id) do
      {:ok, task} ->
        diff_meta = %{
          lines_added: conn.body_params["lines_added"] || 0,
          lines_deleted: conn.body_params["lines_deleted"] || 0,
          files_changed: conn.body_params["files_changed"] || [],
          files_added: conn.body_params["files_added"] || [],
          tests_exist: conn.body_params["tests_exist"] || false
        }

        classification = AgentCom.RiskClassifier.classify(task, diff_meta)

        # Store classification on the task
        AgentCom.TaskQueue.store_risk_classification(task_id, classification)

        send_json(conn, 200, %{
          "tier" => classification.tier,
          "reasons" => classification.reasons,
          "auto_merge_eligible" => classification.auto_merge_eligible
        })

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "task_not_found"})
    end
  end
end
```

### Enhanced PR Body Template
```javascript
// Source: enhances existing generatePrBody() in sidecar/agentcom-git.js (line 108)
function generatePrBody(task, agentId, diffStat, config, riskClassification) {
  const hubUrl = config.hub_api_url || 'http://localhost:4000';
  const taskId = task.task_id || task.id || 'unknown';
  const priority = (task.metadata && task.metadata.priority) || 'normal';
  const description = task.description || 'No description provided';

  const tierLabels = {
    1: 'Tier 1 -- Auto-merge candidate',
    2: 'Tier 2 -- Review required',
    3: 'Tier 3 -- Escalation required'
  };

  const riskSection = riskClassification ? [
    '### Risk Classification',
    '',
    `**${tierLabels[riskClassification.tier] || 'Unknown'}**`,
    '',
    '**Classification reasons:**',
    ...(riskClassification.reasons || []).map(r => `- ${r}`),
    '',
  ] : [];

  return [
    `## Task: ${taskId}`,
    '',
    `**Agent:** ${agentId}`,
    `**Priority:** ${priority}`,
    `**Task Link:** ${hubUrl}/api/tasks/${taskId}`,
    '',
    ...riskSection,
    '### Description',
    '',
    description,
    '',
    '### Changes',
    '',
    '```',
    diffStat || 'No changes',
    '```',
    '',
    '---',
    `*Submitted by agentcom-git | Agent: ${agentId} | Task: ${taskId}*`
  ].join('\n');
}
```

### Sidecar handleResult Flow Enhancement
```javascript
// Source: modifies handleResult() in sidecar/index.js (line 212)
// Insert between verification check (line 246) and git submit (line 248)

// NEW: Gather diff metadata and classify risk tier
let riskClassification = null;
if (_config.repo_dir) {
  try {
    const diffMeta = gatherDiffMeta({ repo_dir: _config.repo_dir, _config: { repo_dir: _config.repo_dir } });

    // Call hub classify endpoint
    const classifyUrl = `${_config.hub_api_url}/api/tasks/${taskId}/classify`;
    const classifyRes = await httpRequest('POST', classifyUrl, diffMeta, {
      'Authorization': `Bearer ${_config.token}`
    });

    if (classifyRes.status === 200) {
      riskClassification = classifyRes.data;
      log('info', 'risk_classified', {
        task_id: taskId,
        tier: riskClassification.tier,
        reasons: riskClassification.reasons
      });
    }
  } catch (err) {
    log('warning', 'risk_classify_failed', { task_id: taskId, error: err.message });
    // Proceed without classification -- PR will not have risk section
  }
}

// Then pass riskClassification to submit (which calls generatePrBody)
```

### TaskQueue: store_risk_classification
```elixir
# Source: follows store_routing_decision pattern (task_queue.ex line 157)
@doc "Store risk classification on a task. Called after classification."
def store_risk_classification(task_id, classification) do
  GenServer.call(__MODULE__, {:store_risk_classification, task_id, classification})
end

# In handle_call:
def handle_call({:store_risk_classification, task_id, classification}, _from, state) do
  case lookup_task(task_id) do
    {:ok, task} ->
      updated = Map.put(task, :risk_classification, classification)
      persist_task(updated, @tasks_table)
      {:reply, {:ok, updated}, state}

    {:error, :not_found} ->
      {:reply, {:error, :not_found}, state}
  end
end
```

## Discretion Recommendations

### Specific Threshold Values
| Threshold | Recommended Default | Rationale |
|-----------|-------------------|-----------|
| Tier 1 max lines | 20 | Matches locked decision "<20 lines changed" |
| Tier 1 max files | 3 | Trivial changes rarely touch >3 files; conservative starting point |
| Tier 1 allowed complexity | `[:trivial, :standard]` | Matches locked decision "trivial/standard complexity" |
| Auto-merge threshold | 20 | Locked decision says "e.g., 20 successful PRs" |
| Auto-merge tier1 enabled | `false` | Locked decision: PR-only default, no auto-merge in v1.3 |

**Confidence: HIGH** -- directly derived from locked decisions.

### Protected Path List
Recommended defaults for Tier 3 escalation:
```
config/               # Runtime/deploy configuration
rel/                  # Release configuration
.github/              # CI/CD workflows
Dockerfile            # Container definitions
docker-compose        # Container orchestration
mix.exs               # Dependency changes
mix.lock              # Dependency lock file
lib/agent_com/auth    # Authentication module
lib/agent_com/plugs/require_auth  # Auth middleware
priv/cert             # TLS certificates
priv/key              # Private keys
.env                  # Environment variables
```

**Confidence: HIGH** -- standard sensitive paths for this Elixir/Phoenix codebase, verified against actual file structure (lib/agent_com/auth.ex, lib/agent_com/plugs/require_auth.ex exist).

### PR Description Template
See the `generatePrBody` code example above. Key design decisions:
1. Risk Classification section appears BEFORE the description (high visibility)
2. No emojis (per codebase convention -- no emojis anywhere in existing codebase)
3. Uses `---` separator (already used in existing template, line 131)
4. Backward compatible: if `riskClassification` is null, section is omitted entirely

**Confidence: HIGH** -- follows existing PR body pattern in `agentcom-git.js`.

### Auto-Merge History Tracking
**Recommendation:** Simple counter in `AgentCom.Config` for v1.3.

Config keys:
- `:risk_tier1_success_count` -- incremented when a Tier 1 PR is merged (detected via GitHub webhook, which already exists in endpoint.ex line 2329)
- `:risk_tier2_success_count` -- same for Tier 2

When `success_count >= risk_auto_merge_threshold`, the system could log/alert that auto-merge could be enabled -- but still requires manual `Config.put(:risk_auto_merge_tier1, true)` to activate (which is a future phase concern).

The webhook handler for `pull_request` merged events (endpoint.ex line 2329) already detects PR merges. Adding a counter increment there is trivial:

```elixir
# In handle_github_event for "pull_request" merged:
# After accepting the webhook, increment the appropriate tier counter
if task_risk_tier do
  counter_key = String.to_atom("risk_tier#{task_risk_tier}_success_count")
  current = Config.get(counter_key) || 0
  Config.put(counter_key, current + 1)
end
```

**Confidence: MEDIUM** -- this is forward-looking. The exact mechanism may need revisiting when auto-merge is actually built. But the infrastructure (webhooks, Config GenServer) is proven.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| All PRs treated equally | Risk-tiered PR classification | Phase 34 (this phase) | Enables differentiated review and future auto-merge |
| Complexity = task description only | Complexity (description) + Risk (actual changes) | Phase 34 | Two-layer classification: predicted vs actual |

## Open Questions

1. **How to handle tasks that complete without git changes (e.g., research tasks)?**
   - What we know: Some tasks may complete without code changes. The sidecar checks `if (_config.repo_dir && !skipGit)` (index.js line 247).
   - What's unclear: Should research tasks get a PR at all?
   - Recommendation: **Tier 2 by default when no diff data.** If the sidecar has no `repo_dir` or `gatherDiffMeta()` returns all zeros, classify as Tier 2. The classify endpoint handles this gracefully via `classify(task, %{})` defaulting to Tier 2.

2. **Should the classify endpoint be authenticated or not?**
   - Recommendation: **Authenticated.** Follows the pattern of all task-modifying endpoints. Uses `AgentCom.Plugs.RequireAuth`.

3. **Should risk classification be stored on the task map or separately?**
   - What we know: `routing_decision` is stored directly on the task map (task_queue.ex line 281). `verification_report` is also stored on the task map.
   - Recommendation: **Store on task map** as `risk_classification` field, following the `routing_decision` pattern with `store_risk_classification/2`. This keeps all task data colocated and avoids a new DETS table.

## Integration Points (Verified)

These are the exact files and line numbers that need modification:

| File | Line(s) | Change |
|------|---------|--------|
| `lib/agent_com/risk_classifier.ex` | NEW | Pure function module |
| `lib/agent_com/config.ex` | N/A | No changes needed (runtime config via put/get) |
| `lib/agent_com/endpoint.ex` | After line 1238 | New `POST /api/tasks/:task_id/classify` endpoint |
| `lib/agent_com/task_queue.ex` | After line 159 | New `store_risk_classification/2` function |
| `sidecar/agentcom-git.js` | After line 100 | New `gatherDiffMeta()` function |
| `sidecar/agentcom-git.js` | Line 108-134 | Enhanced `generatePrBody()` with classification param |
| `sidecar/agentcom-git.js` | Line 258-263 | Add `risk:tier-N` label creation |
| `sidecar/agentcom-git.js` | Line 274-280 | Pass classification + risk label to `gh pr create` |
| `sidecar/index.js` | Lines 246-267 | Insert classify call between verification and git submit |
| `test/agent_com/risk_classifier_test.exs` | NEW | Tests for pure function classifier |

## Sources

### Primary (HIGH confidence)
- `lib/agent_com/complexity.ex` -- Existing complexity classification pattern (gather signals, classify, build result). Lines 57-95 for public API, lines 101-112 for signal gathering, lines 118-157 for classification logic.
- `lib/agent_com/config.ex` -- Config GenServer API. Lines 26-33 for get/put, lines 10-17 for defaults map.
- `sidecar/agentcom-git.js` -- PR creation flow. Lines 108-134 for `generatePrBody()`, lines 151-201 for `startTask()`, lines 203-291 for `submit()`.
- `sidecar/index.js` -- Task completion flow. Lines 212-289 for `handleResult()`, showing verification -> git submit -> sendTaskComplete sequence.
- `lib/agent_com/task_queue.ex` -- Task data model. Line 280 for complexity field, line 157-159 for `store_routing_decision` pattern, lines 251-299 for task map structure.
- `lib/agent_com/endpoint.ex` -- HTTP API. Lines 1057-1131 for task submit endpoint, lines 1214-1238 for task retry endpoint (pattern for new classify endpoint).
- `lib/agent_com/socket.ex` -- WebSocket task_complete handler. Lines 421-443 showing how verification_report flows from sidecar to hub.
- `test/agent_com/complexity_test.exs` -- Test patterns for pure function classifier (async: true, telemetry event testing).

### Secondary (MEDIUM confidence)
- `lib/agent_com/scheduler.ex` -- How routing decisions are stored on tasks (lines 562-564, `store_routing_decision` call pattern).
- `lib/agent_com/goal_orchestrator.ex` -- Goal lifecycle context. How tasks are created from goals.
- `lib/agent_com/hub_fsm.ex` -- FSM states. Understanding of when tasks execute in the pipeline.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- using only existing libraries and patterns from the codebase
- Architecture: HIGH -- pure function module follows locked decision and mirrors Complexity module pattern exactly
- Pitfalls: HIGH -- identified from direct codebase analysis of data flow timing, key format inconsistencies, and integration points
- Integration points: HIGH -- verified file paths, line numbers, and function signatures against actual code
- Discretion areas: HIGH for thresholds (derived from locked decisions), MEDIUM for auto-merge tracking (forward-looking design)

**Research date:** 2026-02-13
**Valid until:** 2026-03-13 (stable domain, no external dependencies)
