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

Phase 34 adds a **risk classification layer** between task completion and PR creation. When a task completes, the system classifies it into one of three risk tiers (Tier 1/2/3) based on multiple signals: the task's complexity tier, lines changed, files touched, whether touched files are on a protected path list, and whether tests exist for the changed files. This classification is embedded in the PR description so humans can make informed review decisions.

The implementation is straightforward: a pure function module (`AgentCom.RiskClassifier`) that takes a completed task map and git diff metadata, returns a risk tier with reasoning. The existing `AgentCom.Config` GenServer stores configurable thresholds. The sidecar's `agentcom-git.js` PR body generation is enhanced to include the risk classification. No new GenServers, no auto-merge logic -- just classification and PR enrichment.

**Primary recommendation:** Build a pure function module `AgentCom.RiskClassifier` with `classify/2` that accepts a task map and a diff summary map, returns `%{tier: 1|2|3, reasons: [string], auto_merge_eligible: boolean}`. Wire it into the sidecar's submit flow by having the Elixir side compute classification and pass it through the task completion data.

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
  risk_classifier/
    config.ex                  # Default thresholds, protected paths (reads from Config GenServer)
```

### Pattern 1: Pure Function Classifier
**What:** A stateless module with a single `classify/2` entry point that takes a task map and diff metadata, returns a classification struct.
**When to use:** Always -- this is the locked decision (no GenServer).
**Example:**
```elixir
defmodule AgentCom.RiskClassifier do
  @moduledoc """
  Classifies completed tasks into risk tiers for PR review.
  Pure function module -- no state, no GenServer.
  """

  @type classification :: %{
    tier: 1 | 2 | 3,
    reasons: [String.t()],
    auto_merge_eligible: boolean()
  }

  @spec classify(task :: map(), diff_meta :: map()) :: classification()
  def classify(task, diff_meta) do
    signals = gather_signals(task, diff_meta)
    tier = compute_tier(signals)
    reasons = build_reasons(signals, tier)

    %{
      tier: tier,
      reasons: reasons,
      auto_merge_eligible: tier == 1 and auto_merge_enabled?(1)
    }
  end
end
```

### Pattern 2: Signal Gathering (Following Complexity Module Pattern)
**What:** Gather multiple independent signals, then combine them via a deterministic rule set. This is the exact pattern used in `AgentCom.Complexity`.
**When to use:** For the classification logic.
**Existing reference:** `lib/agent_com/complexity.ex` uses the same gather-then-classify pattern.
**Example signals map:**
```elixir
%{
  complexity_tier: :standard,       # from task.complexity.effective_tier
  lines_changed: 15,               # from diff metadata
  files_touched: ["lib/foo.ex"],   # from diff metadata
  new_files: [],                    # from diff metadata
  config_files_touched: false,      # computed from files_touched vs protected list
  protected_paths_touched: [],      # computed from files_touched vs protected list
  tests_exist: true,                # from diff metadata
  verification_passed: true         # from task.verification_report
}
```

### Pattern 3: Config-Driven Thresholds
**What:** Store all tier thresholds in Config GenServer so they can be changed at runtime without code changes.
**When to use:** For all classification thresholds and the protected path list.
**Existing reference:** `AgentCom.Config` already stores heartbeat_interval_ms, fallback_wait_ms, task_ttl_ms, etc.
**Config keys to add:**
```elixir
# Tier 1 thresholds
:risk_tier1_max_lines        # default: 20
:risk_tier1_max_files        # default: 3
:risk_tier1_allowed_tiers    # default: [:trivial, :standard]

# Tier 3 triggers
:risk_tier3_protected_paths  # default: ["config/", "rel/", ".github/", "mix.exs", ...]
:risk_tier3_auth_paths       # default: ["lib/agent_com/auth.ex", "lib/agent_com/plugs/"]

# Auto-merge (future, but config shape needed now)
:risk_auto_merge_tier1       # default: false
:risk_auto_merge_threshold   # default: 20  (successful PRs before enabling)
```

### Pattern 4: PR Body Enrichment via Sidecar
**What:** The Elixir side computes the classification and attaches it to the task result. The sidecar reads it during `submit` and includes it in the PR body.
**When to use:** For the PR creation flow.
**Data flow:**
1. Task completes -> sidecar calls git status/diff -> gets diff metadata
2. Sidecar sends diff metadata to hub as part of task_complete (or hub fetches via API)
3. Hub classifies risk tier
4. Classification is stored on the task and returned to sidecar
5. Sidecar includes classification in PR body via `generatePrBody()`

**Alternative (simpler) flow:**
1. Task completes -> sidecar calls git diff -> computes lines/files locally
2. Sidecar sends diff metadata to hub with task_complete
3. Hub classifies, stores on task
4. Sidecar reads classification from task, includes in PR body

### Pattern 5: Integration Point -- Where Classification Happens
**What:** Classification must happen AFTER task execution (when we have actual diff data) but BEFORE PR creation.
**Current flow in sidecar/index.js (lines 232-270):**
1. Result file parsed
2. Verification runs
3. `runGitCommand('submit', ...)` creates PR
4. `hub.sendTaskComplete(taskId, result)` reports to hub

**New flow:**
1. Result file parsed
2. Verification runs
3. Sidecar gathers diff metadata (`git diff --stat`, `git diff --name-only`)
4. Sidecar sends diff metadata to hub (new API or part of task_complete)
5. Hub classifies risk tier via `RiskClassifier.classify/2`
6. Classification stored on task
7. `runGitCommand('submit', ...)` creates PR with classification in body
8. `hub.sendTaskComplete(taskId, result)` reports to hub

**Design decision needed:** Whether classification happens on the Elixir side or sidecar side.
- **Recommendation: Elixir side.** Thresholds live in Config GenServer, and the logic should be co-located with the configuration. The sidecar gathers diff metadata and sends it; the hub classifies and returns the tier.

### Anti-Patterns to Avoid
- **Building a GenServer for classification:** Locked decision says pure function module. Classification is stateless computation.
- **Hardcoding thresholds:** Must be configurable via Config GenServer.
- **Coupling auto-merge logic:** v1.3 is PR-only. Build the classification but do NOT implement auto-merge. The `auto_merge_eligible` field is informational only.
- **Classifying before execution:** Classification requires actual diff data (lines changed, files touched), which only exists after the agent has done the work.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Config storage | Custom config file reader | `AgentCom.Config` GenServer | Already persists to DETS, hot-reloadable |
| Diff parsing | Custom git diff parser | `git diff --stat --numstat` output parsing | Git already provides structured diff info |
| PR creation | Custom GitHub API calls | Existing `agentcom-git.js` submit command | Already handles auth, labels, temp files |
| Complexity detection | New complexity module | Existing `AgentCom.Complexity` | Already computes effective_tier for tasks |

**Key insight:** The risk tier classification LAYER on top of existing complexity classification. Complexity classifies the TASK description. Risk classifies the COMPLETED WORK (actual code changes). They are complementary, not duplicative.

## Common Pitfalls

### Pitfall 1: Classifying Based Only on Task Metadata
**What goes wrong:** Using only `task.complexity.effective_tier` to determine risk tier, ignoring actual diff data.
**Why it happens:** It's tempting to skip diff gathering since complexity is already computed.
**How to avoid:** The whole point of risk tiers is to classify ACTUAL changes, not predicted complexity. A "trivial" task might touch auth code. Always use diff metadata.
**Warning signs:** Tests that only test task metadata, not diff scenarios.

### Pitfall 2: Diff Metadata Not Available
**What goes wrong:** The sidecar can't gather diff data (no git repo, no commits, network error).
**Why it happens:** Edge cases in sidecar execution environments.
**How to avoid:** Default to Tier 2 (PR for review) when diff data is unavailable. Never default to Tier 1.
**Warning signs:** `nil` diff metadata reaching the classifier.

### Pitfall 3: Protected Path List Gets Stale
**What goes wrong:** New sensitive directories are added to the project but not to the protected path list.
**Why it happens:** Protected paths are configuration, not automatically derived.
**How to avoid:** Include common patterns by default (`config/`, `rel/`, `.github/`, `Dockerfile`, auth-related paths). Allow adding patterns, not just exact paths.
**Warning signs:** Auth code PRs classified as Tier 1.

### Pitfall 4: Sidecar-Hub Data Flow Timing
**What goes wrong:** PR is created BEFORE classification is computed, so the PR body doesn't include the tier.
**Why it happens:** The current flow creates the PR in the sidecar before calling task_complete on the hub.
**How to avoid:** Either (a) classify in the sidecar before PR creation, or (b) add a new hub API endpoint the sidecar calls before PR creation to get classification.
**Warning signs:** PRs without risk tier labels.

### Pitfall 5: Config Key Namespace Collision
**What goes wrong:** Config keys like `:max_lines` collide with other features.
**Why it happens:** Flat key namespace in Config GenServer.
**How to avoid:** Prefix all keys with `risk_` (e.g., `:risk_tier1_max_lines`).
**Warning signs:** Unexpected values when reading config.

## Code Examples

### Risk Classifier Module
```elixir
defmodule AgentCom.RiskClassifier do
  @moduledoc """
  Classifies completed tasks into risk tiers based on actual code changes.
  Pure function module (no GenServer).

  ## Risk Tiers

  - Tier 1 (auto-merge candidate): trivial/standard complexity, <20 lines, test-covered, no new files, no config changes
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
    "priv/key"
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

  @spec classify(task :: map(), diff_meta :: diff_meta()) :: classification()
  def classify(task, diff_meta) when is_map(task) and is_map(diff_meta) do
    signals = gather_signals(task, diff_meta)

    cond do
      tier3?(signals) -> build_result(3, signals)
      tier1?(signals) -> build_result(1, signals)
      true -> build_result(2, signals)
    end
  end

  # Fallback: no diff data available -> default to Tier 2
  def classify(task, nil), do: classify(task, %{})

  defp gather_signals(task, diff_meta) do
    complexity_tier = get_in(task, [:complexity, :effective_tier]) || :unknown
    lines_changed = Map.get(diff_meta, :lines_added, 0) + Map.get(diff_meta, :lines_deleted, 0)
    files_changed = Map.get(diff_meta, :files_changed, [])
    files_added = Map.get(diff_meta, :files_added, [])
    tests_exist = Map.get(diff_meta, :tests_exist, false)
    verification_passed = get_verification_status(task)

    protected = Config.get(:risk_tier3_protected_paths) || @default_protected_paths
    auth_paths = Config.get(:risk_tier3_auth_paths) || @default_auth_paths

    protected_touched = Enum.filter(files_changed, fn f ->
      Enum.any?(protected ++ auth_paths, &String.contains?(f, &1))
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

  defp get_verification_status(task) do
    case get_in(task, [:verification_report]) do
      %{"status" => "pass"} -> true
      %{status: :pass} -> true
      nil -> true  # No verification = passes by default
      _ -> false
    end
  end

  defp build_reasons(1, signals) do
    ["complexity: #{signals.complexity_tier}",
     "lines: #{signals.lines_changed}",
     "files: #{signals.file_count}",
     "tests: present",
     "verification: passed"]
  end

  defp build_reasons(2, signals) do
    reasons = []
    reasons = if signals.lines_changed > (@default_tier1_max_lines), do: ["lines: #{signals.lines_changed} (>#{@default_tier1_max_lines})" | reasons], else: reasons
    reasons = if signals.new_file_count > 0, do: ["new files: #{signals.new_file_count}" | reasons], else: reasons
    reasons = if signals.complexity_tier not in @default_tier1_allowed_complexity, do: ["complexity: #{signals.complexity_tier}" | reasons], else: reasons
    reasons = if not signals.tests_exist, do: ["no test coverage" | reasons], else: reasons
    if reasons == [], do: ["default tier for review"], else: reasons
  end

  defp build_reasons(3, signals) do
    reasons = []
    reasons = if signals.protected_paths_touched != [], do: ["protected paths: #{Enum.join(signals.protected_paths_touched, ", ")}" | reasons], else: reasons
    reasons = if not signals.verification_passed, do: ["verification failed" | reasons], else: reasons
    if reasons == [], do: ["escalation required"], else: reasons
  end
end
```

### Diff Metadata Gathering (Sidecar Side)
```javascript
// In agentcom-git.js or a new helper
function gatherDiffMeta(config) {
  const numstat = git('diff --numstat origin/main...HEAD', { _config: config });
  const nameOnly = git('diff --name-only origin/main...HEAD', { _config: config });
  const nameStatus = git('diff --name-status origin/main...HEAD', { _config: config });

  let linesAdded = 0, linesDeleted = 0;
  const filesChanged = [];
  const filesAdded = [];

  if (numstat) {
    numstat.split('\n').forEach(line => {
      const [added, deleted, file] = line.split('\t');
      if (file) {
        linesAdded += parseInt(added, 10) || 0;
        linesDeleted += parseInt(deleted, 10) || 0;
        filesChanged.push(file);
      }
    });
  }

  if (nameStatus) {
    nameStatus.split('\n').forEach(line => {
      const [status, file] = line.split('\t');
      if (status === 'A' && file) filesAdded.push(file);
    });
  }

  // Check if tests exist for changed files
  const testsExist = filesChanged.some(f => {
    const testPath = f.replace('lib/', 'test/').replace('.ex', '_test.exs');
    return filesChanged.includes(testPath) || require('fs').existsSync(
      require('path').join(config.repo_dir, testPath)
    );
  });

  return { lines_added: linesAdded, lines_deleted: linesDeleted, files_changed: filesChanged, files_added: filesAdded, tests_exist: testsExist };
}
```

### Enhanced PR Body Template
```javascript
function generatePrBody(task, agentId, diffStat, config, riskClassification) {
  const hubUrl = config.hub_api_url || 'http://localhost:4000';
  const taskId = task.task_id || task.id || 'unknown';
  const priority = (task.metadata && task.metadata.priority) || 'normal';
  const description = task.description || 'No description provided';

  const tierLabels = { 1: 'Tier 1 (Auto-merge candidate)', 2: 'Tier 2 (Review required)', 3: 'Tier 3 (Escalate)' };
  const tierEmoji = { 1: '', 2: '', 3: '' };

  const riskSection = riskClassification ? [
    `### Risk Classification`,
    '',
    `**${tierLabels[riskClassification.tier] || 'Unknown'}** ${tierEmoji[riskClassification.tier] || ''}`,
    '',
    '**Reasons:**',
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

### Config Key Registration
```elixir
# In AgentCom.Config @defaults map, add:
risk_tier1_max_lines: 20,
risk_tier1_max_files: 3,
risk_tier1_allowed_tiers: [:trivial, :standard],
risk_tier3_protected_paths: [
  "config/", "rel/", ".github/", "Dockerfile",
  "docker-compose", "mix.exs", "mix.lock"
],
risk_tier3_auth_paths: [
  "lib/agent_com/auth", "lib/agent_com/plugs/require_auth",
  "priv/cert", "priv/key"
],
risk_auto_merge_tier1: false,
risk_auto_merge_tier2: false,
risk_auto_merge_threshold: 20
```

### Telemetry Integration
```elixir
# In RiskClassifier.classify/2, after computing result:
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
```

## Discretion Recommendations

### Specific Threshold Values
| Threshold | Recommended Default | Rationale |
|-----------|-------------------|-----------|
| Tier 1 max lines | 20 | Matches locked decision "<20 lines" |
| Tier 1 max files | 3 | Trivial changes rarely touch >3 files |
| Tier 1 allowed complexity | `[:trivial, :standard]` | Matches locked decision |
| Auto-merge threshold | 20 | Locked decision says "e.g., 20 successful PRs" |
| Auto-merge tier1 enabled | `false` | Locked decision: PR-only default |

**Confidence: HIGH** -- these are directly derived from the locked decisions.

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

**Confidence: HIGH** -- these are standard sensitive paths for an Elixir/Phoenix project.

### PR Description Template
See the `generatePrBody` code example above. Key additions to existing template:
1. Risk Classification section with tier label, reasons
2. No emojis (per codebase convention)

**Confidence: HIGH** -- follows existing PR body pattern in `agentcom-git.js`.

### Auto-Merge History Tracking
For tracking successful PR history toward auto-merge enablement:

**Recommendation:** Add a DETS-backed counter per tier in Config GenServer. Increment on successful PR merge (detected via webhook or polling). Config keys:
- `:risk_tier1_success_count` -- incremented when a Tier 1 PR is merged
- `:risk_tier2_success_count` -- incremented when a Tier 2 PR is merged

When `success_count >= risk_auto_merge_threshold`, the system can recommend enabling auto-merge for that tier (but still requires manual config change to enable in v1.3).

**Alternative:** Track in a dedicated DETS table with full history (PR URL, merge date, tier, etc.). This is heavier but provides better auditability.

**Recommendation:** Simple counter in Config for v1.3. Full history table can be added later when auto-merge is actually implemented.

**Confidence: MEDIUM** -- this is forward-looking design. The exact mechanism may need revisiting when auto-merge is actually built.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| All PRs treated equally | Risk-tiered PR classification | Phase 34 (this phase) | Enables differentiated review and future auto-merge |
| Complexity = task description only | Complexity (description) + Risk (actual changes) | Phase 34 | Two-layer classification: predicted + actual |

## Open Questions

1. **Where exactly to compute classification -- hub API call or embedded in sidecar?**
   - What we know: Thresholds live in Config GenServer (Elixir side). Diff data is gathered by sidecar (JS side).
   - What's unclear: Whether sidecar should call a new `/api/tasks/:id/classify` endpoint, or embed classification logic in JS.
   - Recommendation: New hub endpoint `/api/tasks/:id/classify` that accepts diff metadata and returns classification. Keeps logic centralized on Elixir side where Config is accessible. Sidecar calls this between verification and PR creation.

2. **How to handle tasks that complete without git changes (e.g., research tasks)?**
   - What we know: Some tasks may complete without code changes.
   - What's unclear: Should these get Tier 1 (no risk) or Tier 2 (needs review)?
   - Recommendation: Tier 2 by default when no diff data. The task result should still be reviewed.

3. **Should GitHub labels be added for risk tiers?**
   - What we know: Sidecar already creates `agent:` and `priority:` labels.
   - What's unclear: Whether to add `risk:tier-1`, `risk:tier-2`, `risk:tier-3` labels.
   - Recommendation: Yes, add labels. Low effort, high value for filtering PRs in GitHub.

## Sources

### Primary (HIGH confidence)
- `lib/agent_com/complexity.ex` -- Existing complexity classification pattern (gather signals, classify, build result)
- `lib/agent_com/config.ex` -- Config GenServer API (get/put with DETS backing)
- `sidecar/agentcom-git.js` -- PR creation flow (start-task, submit, status commands)
- `sidecar/index.js` (lines 232-270) -- Task completion flow (verification -> git submit -> task_complete)
- `lib/agent_com/task_queue.ex` -- Task data model (complexity field, verification_report, etc.)
- `lib/agent_com/socket.ex` (lines 421-443) -- WebSocket task_complete handler
- `test/agent_com/complexity_test.exs` -- Test patterns for pure function classifier

### Secondary (MEDIUM confidence)
- `lib/agent_com/scheduler.ex` -- How routing decisions are stored on tasks (pattern to follow for risk classification)
- `lib/agent_com/goal_orchestrator.ex` -- Goal lifecycle context (how tasks are created from goals)
- `lib/agent_com/goal_orchestrator/verifier.ex` -- Verification flow (feeds into Tier 3 check)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- using only existing libraries and patterns from the codebase
- Architecture: HIGH -- pure function module follows locked decision and mirrors Complexity module pattern
- Pitfalls: HIGH -- identified from direct codebase analysis of data flow timing and config patterns
- Discretion areas: HIGH for thresholds (derived from locked decisions), MEDIUM for auto-merge tracking (forward-looking design)

**Research date:** 2026-02-13
**Valid until:** 2026-03-13 (stable domain, no external dependencies)
