# Phase 25: Cost Control Infrastructure - Research

**Researched:** 2026-02-13
**Domain:** GenServer + DETS/ETS invocation tracking with budget enforcement for Claude Code CLI
**Confidence:** HIGH

## Summary

Phase 25 implements a CostLedger GenServer that tracks Claude Code CLI invocations (not token costs) and enforces configurable per-state budgets. The hub uses Claude Code Max subscription ($200/month) which has usage limits but is not per-token billed, so cost control means invocation counting and rate enforcement rather than dollar tracking.

The implementation follows well-established patterns already present in the AgentCom codebase: GenServer with DETS persistence (TaskQueue, RepoRegistry), ETS for hot-path reads (MetricsCollector, RateLimiter), telemetry event emission (Telemetry module with event catalog), Config GenServer for dynamic thresholds (Alerter reads from Config every check cycle), and DetsBackup registration (10 tables currently managed).

The architecture is a dual-layer store: DETS for invocation history (survives restart), ETS for budget check lookups (fast synchronous reads on the critical path). The CostLedger.check_budget/1 function is the gate that every Claude Code invocation must pass through before proceeding.

**Primary recommendation:** Build CostLedger as a single GenServer following the RepoRegistry pattern (simpler than TaskQueue), with one DETS table `:cost_ledger` storing invocation records, and one ETS table `:cost_budget` for hot-path budget checks. Use rolling window counters in ETS for O(1) budget decisions.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Cost Model
- Hub uses `claude -p` CLI (Claude Code Max subscription), not Messages API
- Track invocations per hour/day/session rather than token costs
- Max plan has usage limits -- CostLedger enforces configurable invocation budgets
- Per-state budgets: configurable limits for Executing, Improving, Contemplating states

#### Budget Enforcement
- Synchronous check before every Claude Code invocation -- CostLedger.check_budget/1 returns :ok or :budget_exhausted
- If budget exhausted, caller knows to transition FSM to Resting
- Hard caps in code, not in prompts -- the LLM cannot be trusted to self-limit

#### Telemetry
- Emit :telemetry events for each invocation: [:agent_com, :hub, :claude_call]
- Wire into existing Alerter with new rule for hub invocation rate
- Track invocation duration (CLI spawn time) for performance monitoring

#### Persistence
- DETS-backed for invocation history (survives hub restart)
- ETS for hot-path budget checks (fast reads)
- Register with DetsBackup from day one

### Claude's Discretion
- Specific budget defaults per state
- Invocation history retention period
- Whether to track per-goal or per-state granularity
- Reset schedule (daily? rolling window?)

### Deferred Ideas (OUT OF SCOPE)
None specified -- all ideas in CONTEXT.md are in scope.
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GenServer (OTP) | OTP 28 | CostLedger process | All 24+ supervised processes in the codebase use GenServer |
| :dets (OTP) | OTP 28 | Invocation history persistence | 10 existing DETS tables follow this pattern |
| :ets (OTP) | OTP 28 | Hot-path budget check cache | MetricsCollector, RateLimiter already use ETS for fast reads |
| :telemetry | 1.3.0 | Event emission for invocations | Already a transitive dependency; Telemetry module catalogs all events |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| AgentCom.Config | existing | Store budget thresholds | Alerter already reads thresholds from Config every cycle |
| AgentCom.DetsBackup | existing | Backup/compaction/recovery | Must register new DETS table in @tables list |
| AgentCom.Alerter | existing | Hub invocation rate alerts | Add new alert rule for high invocation rate |
| Phoenix.PubSub | existing | Broadcast budget events | DashboardState subscribes for real-time display |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| GenServer + DETS | :persistent_term | Read-only; cannot track mutable invocation history |
| ETS for budget cache | GenServer state | GenServer state requires serialized reads; ETS allows concurrent reads from caller processes |
| Rolling window in ETS | Sliding window with :timer | Timer-based cleanup adds complexity; lazy evaluation on check is simpler and proven by RateLimiter |

**No new dependencies required.** Everything needed is already in the project.

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  cost_ledger.ex        # GenServer: DETS persistence, ETS cache, budget enforcement
```

One file. This is a focused module like RepoRegistry (298 lines), not a complex multi-file system like TaskQueue. No sub-modules needed.

### Pattern 1: Dual-Layer Store (DETS + ETS)
**What:** DETS stores invocation history records for persistence and queryability. ETS stores rolling window counters for O(1) budget checks. The GenServer owns both, syncing ETS from DETS on init and updating both on each invocation.
**When to use:** When you need both persistence (survives restart) and fast synchronous reads (budget check on every Claude call).
**Example:**
```elixir
# Source: Existing pattern from MetricsCollector (ETS) + RepoRegistry (DETS)
defmodule AgentCom.CostLedger do
  use GenServer
  require Logger

  @dets_table :cost_ledger
  @ets_table :cost_budget

  def init(_opts) do
    # Open DETS for history
    dets_path = Path.join(data_dir(), "cost_ledger.dets") |> String.to_charlist()
    {:ok, @dets_table} = :dets.open_file(@dets_table, file: dets_path, type: :set, auto_save: 5_000)

    # Create ETS for hot-path budget checks
    :ets.new(@ets_table, [:named_table, :public, :set, {:read_concurrency, true}])

    # Rebuild ETS counters from DETS history on startup
    rebuild_ets_from_history()

    {:ok, %{}}
  end
end
```

### Pattern 2: Synchronous Budget Check (check_budget/1)
**What:** A public function that callers invoke before every Claude Code CLI call. Must return `:ok` or `:budget_exhausted` with zero GenServer round-trip on the fast path (reads from ETS directly).
**When to use:** On the critical path before every LLM invocation.
**Example:**
```elixir
# Source: Adapted from RateLimiter.check/3 pattern (ETS-based, no GenServer call)
@doc "Check if budget allows an invocation for the given hub state."
@spec check_budget(atom()) :: :ok | :budget_exhausted
def check_budget(hub_state) when hub_state in [:executing, :improving, :contemplating] do
  # Read from ETS -- no GenServer bottleneck
  {hourly_count, daily_count} = read_current_counts(hub_state)
  {hourly_limit, daily_limit} = read_budget_limits(hub_state)

  cond do
    hourly_count >= hourly_limit -> :budget_exhausted
    daily_count >= daily_limit -> :budget_exhausted
    true -> :ok
  end
end
```

### Pattern 3: Record Invocation (record_invocation/2)
**What:** After a Claude Code CLI call completes, record it in both ETS (increment counter) and DETS (persist record). Uses GenServer.call for the DETS write to ensure durability.
**When to use:** After every completed Claude Code invocation.
**Example:**
```elixir
@doc "Record a completed Claude Code invocation."
def record_invocation(hub_state, metadata) do
  GenServer.call(__MODULE__, {:record_invocation, hub_state, metadata})
end

# In handle_call:
def handle_call({:record_invocation, hub_state, metadata}, _from, state) do
  now = System.system_time(:millisecond)
  record = %{
    id: generate_id(),
    hub_state: hub_state,
    timestamp: now,
    duration_ms: Map.get(metadata, :duration_ms, 0),
    prompt_type: Map.get(metadata, :prompt_type)
  }

  # Persist to DETS
  :dets.insert(@dets_table, {record.id, record})
  :dets.sync(@dets_table)

  # Update ETS counters atomically
  :ets.update_counter(@ets_table, {:hourly, hub_state}, 1, {{:hourly, hub_state}, 0})
  :ets.update_counter(@ets_table, {:daily, hub_state}, 1, {{:daily, hub_state}, 0})
  :ets.update_counter(@ets_table, {:session, hub_state}, 1, {{:session, hub_state}, 0})

  # Emit telemetry
  :telemetry.execute(
    [:agent_com, :hub, :claude_call],
    %{duration_ms: record.duration_ms, count: 1},
    %{hub_state: hub_state, prompt_type: record.prompt_type}
  )

  {:reply, :ok, state}
end
```

### Pattern 4: Config-Driven Budgets
**What:** Budget limits stored in AgentCom.Config GenServer, read dynamically by CostLedger. Changeable at runtime via API without restart.
**When to use:** For all configurable thresholds.
**Example:**
```elixir
# Source: Follows Alerter.load_thresholds/0 pattern (line 524-533 of alerter.ex)
defp read_budget_limits(hub_state) do
  budgets = try do
    case AgentCom.Config.get(:hub_invocation_budgets) do
      nil -> default_budgets()
      budgets when is_map(budgets) -> merge_with_defaults(budgets)
      _ -> default_budgets()
    end
  rescue
    _ -> default_budgets()
  end

  state_budget = Map.get(budgets, hub_state, Map.get(budgets, :default))
  {state_budget.max_per_hour, state_budget.max_per_day}
end
```

### Pattern 5: DetsBackup Registration
**What:** Add the new DETS table to DetsBackup's @tables list and table_owner/1 function.
**When to use:** Mandatory for every new DETS table.
**Example:**
```elixir
# In dets_backup.ex:
@tables [
  # ... existing 10 tables ...
  :cost_ledger           # Phase 25
]

defp table_owner(:cost_ledger), do: AgentCom.CostLedger
```

### Anti-Patterns to Avoid
- **GenServer.call for budget checks:** The check_budget/1 function is called before every Claude Code invocation. Using GenServer.call would serialize all budget checks through one process. Use ETS reads instead (RateLimiter already proves this pattern).
- **Storing budget limits in CostLedger state:** Budget limits should come from Config GenServer, not be hardcoded in CostLedger state. This allows runtime changes via the existing Config API.
- **Creating multiple DETS tables:** One DETS table with namespaced keys is sufficient. Pitfall #7 from research warns against table proliferation.
- **Trusting the LLM to self-limit:** This is a locked decision. Hard caps in code only. No prompt-based cost control.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Telemetry event emission | Custom logging | `:telemetry.execute/3` | Existing Telemetry module catalogs all events; MetricsCollector attaches handlers |
| Configuration persistence | Custom DETS config | `AgentCom.Config.get/put` | Alerter, RateLimiter, Scheduler all use Config for dynamic thresholds |
| DETS backup/recovery | Custom backup logic | Register with `AgentCom.DetsBackup` | 10 tables already managed; handles backup, compaction, corruption recovery |
| Rate limiting semantics | Custom rate limiter | Adapt `RateLimiter.check/3` pattern | Proven ETS-based lazy-refill token bucket |
| Alert rules | Custom alert logic | Add rule to `AgentCom.Alerter` | Supports new rules; has cooldown, acknowledgment, PubSub broadcast |

**Key insight:** Every infrastructure component CostLedger needs already exists in AgentCom. The implementation is pattern replication, not innovation.

## Common Pitfalls

### Pitfall 1: Budget Check Becomes a Bottleneck
**What goes wrong:** CostLedger.check_budget/1 is called synchronously before every Claude Code invocation. If implemented as GenServer.call, the GenServer becomes a serialization point. Under burst load (Executing state decomposing a goal into many sub-tasks), budget checks queue up.
**Why it happens:** Natural instinct to put all logic in the GenServer.
**How to avoid:** Read budget state from ETS, not GenServer state. The RateLimiter already proves this pattern -- `RateLimiter.check/3` reads from `:rate_limit_buckets` ETS table directly.
**Warning signs:** Budget check latency exceeding 1ms (should be microseconds for ETS read).

### Pitfall 2: ETS Counters Drift from DETS History After Restart
**What goes wrong:** On restart, ETS counters must be rebuilt from DETS history. If the rebuild logic is incorrect (wrong time window, off-by-one on hourly boundary), budget enforcement is either too loose (allows excess invocations) or too strict (blocks valid invocations).
**Why it happens:** Time-based windowing across process restarts is inherently tricky.
**How to avoid:** On init, scan DETS records within the current hour/day window. Use `System.system_time(:millisecond)` for all timestamps. Use a deterministic hour/day boundary (e.g., UTC hour/day truncation).
**Warning signs:** Budget appears reset after hub restart.

### Pitfall 3: Forgetting DetsBackup Registration
**What goes wrong:** New DETS table `:cost_ledger` is not added to DetsBackup's `@tables` list and `table_owner/1` function. The table is never backed up, never compacted, and never auto-recovered from corruption.
**Why it happens:** DetsBackup registration is a separate file requiring manual update. Easy to forget.
**How to avoid:** Include DetsBackup registration as a verification step in every plan. The PITFALLS.md research (Pitfall #7) explicitly warns about this.
**Warning signs:** `GET /api/health/dets` response does not include `:cost_ledger`.

### Pitfall 4: Test Isolation Failure
**What goes wrong:** CostLedger tests leave DETS/ETS state that bleeds into other tests. Tests pass individually but fail when run together.
**Why it happens:** DETS tables persist across test runs unless explicitly cleaned up.
**How to avoid:** Use the existing `AgentCom.TestHelpers.DetsHelpers.full_test_setup/0` pattern. Add `:cost_ledger` to the DETS tables list that gets force-closed, and add `:cost_ledger_data_dir` to the Application.put_env overrides. Add `:cost_budget` ETS table cleanup.
**Warning signs:** Tests pass with `mix test test/agent_com/cost_ledger_test.exs` but fail with `mix test`.

### Pitfall 5: Rolling Window Edge Cases
**What goes wrong:** Invocations near hour/day boundaries are miscounted. An invocation at 13:59:59 and another at 14:00:01 should be in different hourly windows, but a naive "last 60 minutes" window counts both.
**Why it happens:** Confusion between "fixed window" (aligned to clock hour) and "rolling window" (last N minutes from now).
**How to avoid:** Use rolling window (recommended). Count invocations where `timestamp > now - 3_600_000` for hourly, `timestamp > now - 86_400_000` for daily. This is simpler and avoids boundary issues. The MetricsCollector uses this approach with `@window_ms 3_600_000`.
**Warning signs:** Budget appears to reset mid-hour or carry over across hours.

## Code Examples

### Complete CostLedger Public API
```elixir
# Source: Synthesized from CONTEXT.md decisions + codebase patterns

defmodule AgentCom.CostLedger do
  @moduledoc """
  Invocation budget enforcement for hub-side Claude Code CLI calls.

  Tracks invocations per hour/day/session with per-state budgets
  (Executing, Improving, Contemplating). DETS-backed history with
  ETS hot-path for synchronous budget checks.

  ## Public API

  - `check_budget/1` -- Synchronous budget gate (ETS read, no GenServer call)
  - `record_invocation/2` -- Record completed invocation (GenServer call for DETS write)
  - `stats/0` -- Current invocation counts and budget status
  - `history/1` -- Invocation history with optional filters
  """

  use GenServer
  require Logger

  # Client API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec check_budget(atom()) :: :ok | :budget_exhausted
  def check_budget(hub_state)

  @spec record_invocation(atom(), map()) :: :ok
  def record_invocation(hub_state, metadata)

  @spec stats() :: map()
  def stats()

  @spec history(keyword()) :: [map()]
  def history(opts \\ [])
end
```

### Alerter Integration (New Rule)
```elixir
# Source: Adapted from evaluate_high_error_rate pattern in alerter.ex (line 431)

# In a new Alerter check cycle or as a separate telemetry-driven alert:
defp evaluate_hub_invocation_rate(thresholds) do
  hourly_threshold = Map.get(thresholds, :hub_invocations_per_hour_warn, 50)

  total_hourly = try do
    AgentCom.CostLedger.stats()
    |> get_in([:hourly, :total])
  rescue
    _ -> 0
  end

  if total_hourly > hourly_threshold do
    {:triggered, :warning,
     "Hub invocation rate high: #{total_hourly} calls this hour (threshold: #{hourly_threshold})",
     %{hourly_invocations: total_hourly, threshold: hourly_threshold}}
  else
    :ok
  end
end
```

### DetsHelpers Update for Tests
```elixir
# Source: Existing pattern from test/support/dets_helpers.ex

# Add to setup_test_dets/0:
Application.put_env(:agent_com, :cost_ledger_data_dir, Path.join(tmp_dir, "cost_ledger"))
File.mkdir_p!(Path.join(tmp_dir, "cost_ledger"))

# Add to restart_dets_servers/0 stop_order:
AgentCom.CostLedger  # Add before Scheduler in stop order

# Add to dets_tables force-close list:
:cost_ledger
```

### Telemetry Event Definition
```elixir
# Source: Follows pattern from telemetry.ex event catalog

# New events to add to Telemetry module:

# ### Hub Claude Code Invocations
#
# - `[:agent_com, :hub, :claude_call]` - Claude Code CLI invocation completed
#   measurements: `%{duration_ms: integer, count: 1}`
#   metadata: `%{hub_state: atom, prompt_type: atom}`
#
# - `[:agent_com, :hub, :budget_exhausted]` - Budget check returned exhausted
#   measurements: `%{}`
#   metadata: `%{hub_state: atom, hourly_count: integer, daily_count: integer}`
```

### Supervision Tree Placement
```elixir
# Source: application.ex children list

# Place CostLedger after Config (it reads Config for budgets)
# and before any future ClaudeClient/HubFSM (they depend on it)
children = [
  # ... existing children through Config ...
  {AgentCom.Config, []},
  {AgentCom.CostLedger, []},    # Phase 25: Must start before Phase 26 ClaudeClient
  {AgentCom.Auth, []},
  # ... rest of existing children ...
]
```

## Discretion Recommendations

These are areas marked as "Claude's Discretion" in CONTEXT.md. My recommendations based on codebase analysis:

### Budget Defaults Per State

**Recommendation:** Rolling window with these defaults:

| State | Max Per Hour | Max Per Day | Rationale |
|-------|-------------|-------------|-----------|
| Executing | 20 | 100 | Goal decomposition may need several rapid calls; most active state |
| Improving | 10 | 40 | Improvement scanning is less intensive; runs periodically |
| Contemplating | 5 | 15 | Contemplation is infrequent and should be lean |
| Default/Global | 30 | 120 | Catch-all if state not specified |

**Rationale:** These are conservative starting points. The Claude Code Max plan's exact usage limits are not publicly documented, but community reports suggest 50-100 invocations/hour is sustainable. Starting conservative and adjusting up via Config is safer than starting high and hitting platform limits.

**Confidence:** MEDIUM. These are informed estimates, not empirically validated.

### Invocation History Retention Period

**Recommendation:** 7 days, with periodic cleanup via `Process.send_after` timer.

**Rationale:** 7 days provides enough history for trend analysis and debugging without unbounded DETS growth. At 100 invocations/day max, that's ~700 records -- trivially small for DETS. The MetricsCollector uses 1-hour window for ETS data but that's for aggregated metrics; raw invocation history benefits from longer retention.

Clean up records older than 7 days on a daily timer (matching DetsBackup's daily backup schedule).

**Confidence:** HIGH. Storage cost is negligible; retention is a UX decision.

### Per-Goal vs Per-State Granularity

**Recommendation:** Per-state only for Phase 25. Add per-goal tracking in Phase 27 (Goal Backlog) when goals exist.

**Rationale:** CostLedger must exist before Phase 26 (ClaudeClient) which is before Phase 27 (GoalBacklog). There is no concept of "goal" in the codebase yet. Adding per-goal tracking now would require placeholder infrastructure. The invocation record can include an optional `goal_id` field for future use, but budget enforcement should be per-state only.

**Confidence:** HIGH. Follows the "must exist before Phase 26" constraint.

### Reset Schedule

**Recommendation:** Rolling window (not fixed reset).

**Rationale:** Rolling window avoids the "boundary problem" where all budget resets at midnight and a burst of invocations follows. Rolling window means "count invocations in the last 60 minutes" and "count invocations in the last 24 hours" -- no reset events needed.

Implementation: On each `check_budget/1` call, count DETS records where `timestamp > now - window_ms`. Cache the count in ETS and invalidate on each `record_invocation/2`. This is the same lazy-evaluation pattern used by `RateLimiter.check/3`.

For session tracking: session starts when CostLedger GenServer starts (application boot). Session counter is a simple ETS counter incremented on each `record_invocation/2`, never reset until restart.

**Confidence:** HIGH. Rolling window is proven in the codebase (MetricsCollector uses `@window_ms 3_600_000`).

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Token-based cost tracking (sidecar cost-calculator.js) | Invocation-based tracking | Phase 25 context decision | Hub uses Claude Code Max, not per-token API |
| No hub-side cost control | CostLedger with hard caps | Phase 25 | Prevents Pitfall #1 (cost spiral) |
| LLM self-limiting via prompts | Code-enforced budget caps | Phase 25 context decision | Hard enforcement, not prompt-based |

**Deprecated/outdated:**
- The sidecar `cost-calculator.js` remains for sidecar task execution cost tracking. CostLedger is separate -- it tracks hub-side CLI invocations, not sidecar API calls. These are complementary, not replacements.

## Open Questions

1. **Claude Code Max exact usage limits**
   - What we know: $200/month subscription with "usage limits" -- not publicly documented exact invocation caps
   - What's unclear: Exact hourly/daily invocation limits imposed by Anthropic on the Max plan
   - Recommendation: Start with conservative budget defaults (20/hour, 100/day for Executing). Monitor actual usage. The CostLedger's history will provide data to calibrate limits against the plan's actual constraints.

2. **Dashboard integration scope for Phase 25**
   - What we know: CONTEXT.md mentions "Dashboard panel showing invocation rate over time (feeds into Phase 36)"
   - What's unclear: Whether Phase 25 should add a dashboard panel or just expose the data for Phase 36
   - Recommendation: Phase 25 should expose `stats/0` and `history/1` APIs. Dashboard panel is Phase 36 scope. However, adding CostLedger to the DashboardState snapshot (like RepoRegistry.snapshot()) is minimal effort and should be included.

3. **Burst allowance for Executing state**
   - What we know: CONTEXT.md suggests "Consider a burst allowance for Executing state (goal decomposition might need several calls quickly)"
   - What's unclear: Whether burst should be a separate concept or just a higher per-hour limit
   - Recommendation: A higher per-hour limit for Executing (20 vs 10 for Improving) effectively provides burst capacity. A separate burst mechanism adds complexity. Start simple; add burst tracking later if needed.

## Integration Points

### Files That Must Be Modified

1. **`lib/agent_com/application.ex`** -- Add `{AgentCom.CostLedger, []}` to children list after Config
2. **`lib/agent_com/dets_backup.ex`** -- Add `:cost_ledger` to `@tables`, add `table_owner(:cost_ledger)` clause
3. **`lib/agent_com/telemetry.ex`** -- Add new event definitions to catalog and handler attachment
4. **`lib/agent_com/alerter.ex`** -- Add `hub_invocation_rate` alert rule
5. **`test/support/dets_helpers.ex`** -- Add cost_ledger to test isolation setup

### Files That Must Be Created

1. **`lib/agent_com/cost_ledger.ex`** -- The CostLedger GenServer
2. **`test/agent_com/cost_ledger_test.exs`** -- Tests following TaskQueue test patterns

### Downstream Consumers (Phase 26+)

- **Phase 26 (ClaudeClient):** Will call `CostLedger.check_budget/1` before every `claude -p` invocation and `CostLedger.record_invocation/2` after completion
- **Phase 29 (HubFSM):** Will transition to Resting when `check_budget/1` returns `:budget_exhausted`
- **Phase 36 (Dashboard):** Will call `CostLedger.stats/0` for invocation rate display

## Sources

### Primary (HIGH confidence)
- AgentCom codebase analysis (direct file reads):
  - `lib/agent_com/task_queue.ex` -- GenServer + DETS pattern with explicit sync
  - `lib/agent_com/repo_registry.ex` -- Simpler GenServer + DETS pattern
  - `lib/agent_com/rate_limiter.ex` -- ETS-based hot-path checks without GenServer
  - `lib/agent_com/alerter.ex` -- Dynamic Config-driven thresholds, alert rule pattern
  - `lib/agent_com/telemetry.ex` -- Event catalog and handler attachment
  - `lib/agent_com/dets_backup.ex` -- Table registration, backup, compaction, recovery
  - `lib/agent_com/config.ex` -- DETS-backed key-value config store
  - `lib/agent_com/metrics_collector.ex` -- ETS counter/gauge pattern with rolling windows
  - `lib/agent_com/application.ex` -- Supervision tree ordering (24 children)
  - `test/support/dets_helpers.ex` -- Test isolation pattern for DETS-backed GenServers
  - `test/agent_com/task_queue_test.exs` -- Test structure with full_test_setup/teardown
- `.planning/research/PITFALLS.md` -- Pitfall #1 (cost spiral), #7 (DETS proliferation)
- `.planning/phases/25-cost-control-infrastructure/25-CONTEXT.md` -- Locked decisions
- `.planning/phases/26-claude-api-client/26-CONTEXT.md` -- Downstream consumer contract
- `.planning/phases/29-hub-fsm-core/29-CONTEXT.md` -- FSM budget exhaustion transition
- `.planning/REQUIREMENTS.md` -- COST-01 through COST-04 requirements

### Secondary (MEDIUM confidence)
- Elixir/OTP 28 (verified via `elixir --version`): GenServer, :dets, :ets, :telemetry APIs are stable and well-documented
- telemetry 1.3.0 (verified via mix.lock): `execute/3`, `attach_many/4`, `span/3` all available

### Tertiary (LOW confidence)
- Claude Code Max plan usage limits: Not publicly documented. Budget defaults are informed estimates based on community reports, not official documentation. Must be validated empirically.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all components already exist in the codebase; pure pattern replication
- Architecture: HIGH -- dual-layer DETS+ETS proven by MetricsCollector and RateLimiter; GenServer pattern proven by 24+ existing processes
- Pitfalls: HIGH -- identified from direct codebase analysis and existing PITFALLS.md research
- Budget defaults: MEDIUM -- informed estimates, not empirically validated against Claude Code Max limits

**Research date:** 2026-02-13
**Valid until:** 2026-03-13 (stable domain; OTP patterns do not change frequently)
