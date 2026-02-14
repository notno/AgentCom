# Phase 33: Contemplation and Scalability - Research

**Researched:** 2026-02-13
**Domain:** Elixir/OTP -- stateless library modules, ETS metric analysis, XML serialization, HubFSM state expansion
**Confidence:** HIGH

## Summary

Phase 33 is primarily an integration and wiring phase, not a greenfield build. Significant implementation already exists: `AgentCom.Contemplation` (orchestrator), `AgentCom.Contemplation.ProposalWriter` (XML file writer), `AgentCom.Contemplation.ScalabilityAnalyzer` (metric-based analysis), `AgentCom.XML.Schemas.Proposal` (XML schema), and `AgentCom.ClaudeClient.Prompt.build(:generate_proposals, ...)` with corresponding `Response.parse_inner(:generate_proposals, ...)`. The CostLedger already has `:contemplating` budgets configured, and `ClaudeClient` already accepts `:contemplating` as a valid hub state.

The primary remaining work is: (1) expanding HubFSM from 3-state to 4-state by adding the `:contemplating` state with proper transitions and predicates, (2) wiring the contemplation cycle into HubFSM's `do_transition` (mirroring how `:improving` triggers `SelfImprovement.run_improvement_cycle`), (3) enriching the existing Proposal schema to include the user-required "why now" and "why not" sections plus actual codebase file references, (4) enhancing the prompt to read PROJECT.md out-of-scope to avoid proposing excluded features, and (5) writing comprehensive tests.

**Primary recommendation:** Treat this as a 3-plan phase: (1) HubFSM 4-state expansion with Predicates and integration, (2) Proposal schema enrichment and contemplation cycle completion, (3) TDD test suite for all new and modified modules.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Contemplation (Feature Proposals)
- Hub enters Contemplating when Improving finds nothing to improve
- Analyzes codebase structure, backlog patterns, known tech debt
- Generates max 3 proposals per cycle, then transitions to Resting
- Proposals written as XML files in a `proposals/` directory
- Human reviews and optionally promotes to goal backlog
- Not self-executing -- contemplation produces documents, not tasks

#### Proposal Structure
- Problem statement, proposed solution, estimated complexity, dependencies
- Grounded in actual codebase (file references, module analysis)
- Includes "why now" and "why not" sections
- Scope-constrained: proposals must be achievable in one milestone phase

#### Scalability Analysis
- Read existing ETS metrics (queue depth, latency, agent utilization)
- Analyze trends: is throughput growing? Are agents saturated?
- Produce structured report recommending machines vs agents
- No LLM needed for basic stats -- pure metric analysis
- Optional: Claude Code analysis for recommendations on complex bottlenecks

### Claude's Discretion
- Proposal XML schema design
- Scalability report format (XML, markdown, or both)
- How to identify "interesting" features to propose (what makes a good proposal)
- Whether to integrate with existing tech debt list from PROJECT.md

### Deferred Ideas (OUT OF SCOPE)
None specified.
</user_constraints>

## Standard Stack

### Core

No new dependencies required. Everything builds on existing codebase modules.

| Module | Location | Purpose | Status |
|--------|----------|---------|--------|
| `AgentCom.Contemplation` | `lib/agent_com/contemplation.ex` | Top-level orchestrator | EXISTS -- needs minor enrichment |
| `AgentCom.Contemplation.ProposalWriter` | `lib/agent_com/contemplation/proposal_writer.ex` | XML file writer to `priv/proposals/` | EXISTS -- complete |
| `AgentCom.Contemplation.ScalabilityAnalyzer` | `lib/agent_com/contemplation/scalability_analyzer.ex` | Pure metric analysis | EXISTS -- complete |
| `AgentCom.XML.Schemas.Proposal` | `lib/agent_com/xml/schemas/proposal.ex` | Proposal struct + Saxy.Builder | EXISTS -- needs schema enrichment |
| `AgentCom.ClaudeClient.Prompt` | `lib/agent_com/claude_client/prompt.ex` | Prompt templates | EXISTS -- `:generate_proposals` clause exists |
| `AgentCom.ClaudeClient.Response` | `lib/agent_com/claude_client/response.ex` | Response parsing | EXISTS -- `:generate_proposals` clause exists |
| `AgentCom.HubFSM` | `lib/agent_com/hub_fsm.ex` | FSM GenServer | EXISTS -- needs 4-state expansion |
| `AgentCom.HubFSM.Predicates` | `lib/agent_com/hub_fsm/predicates.ex` | Pure transition functions | EXISTS -- needs contemplating predicates |
| `AgentCom.CostLedger` | `lib/agent_com/cost_ledger.ex` | Budget gating | EXISTS -- `:contemplating` already supported |
| `AgentCom.MetricsCollector` | `lib/agent_com/metrics_collector.ex` | ETS metrics source | EXISTS -- `snapshot/0` API ready |

### Supporting

| Library | Purpose | Already In Project |
|---------|---------|-------------------|
| Saxy | XML encoding/decoding | Yes |
| Jason | JSON for CLI response parsing | Yes |
| Phoenix.PubSub | Event broadcasting | Yes |

## Architecture Patterns

### Existing Pattern: Stateless Library Module (follow RepoScanner/SelfImprovement pattern)

`AgentCom.Contemplation` is already implemented as a stateless library module (not a GenServer). This matches the established pattern where `SelfImprovement` is a stateless module called by HubFSM during state transitions. The contemplation module should remain stateless.

**Key pattern:** HubFSM owns the lifecycle. When entering `:contemplating`, it spawns `Task.start(fn -> Contemplation.run() end)` and receives `{:contemplation_cycle_complete, result}` when done. This mirrors the existing `:improving` pattern exactly:

```elixir
# Existing pattern in hub_fsm.ex lines 437-444
if new_state == :improving do
  pid = self()
  Task.start(fn ->
    result = AgentCom.SelfImprovement.run_improvement_cycle()
    send(pid, {:improvement_cycle_complete, result})
  end)
end
```

The contemplation equivalent:
```elixir
if new_state == :contemplating do
  pid = self()
  Task.start(fn ->
    result = AgentCom.Contemplation.run()
    send(pid, {:contemplation_cycle_complete, result})
  end)
end
```

### Existing Pattern: HubFSM State Expansion

Phase 29 verification confirms: "Start with 2-state core, expand to 4 states after core loop proves stable." The current 3-state FSM (resting/executing/improving) was expanded from 2-state. Adding `:contemplating` follows the same expansion pattern.

**Changes required in `hub_fsm.ex`:**

1. `@valid_transitions` map -- add `:improving -> [:resting, :executing, :contemplating]` and `:contemplating -> [:resting]`
2. `do_transition/3` -- add contemplation cycle spawn when `new_state == :contemplating`
3. `handle_info/2` -- add `{:contemplation_cycle_complete, result}` handler (mirror improvement_cycle_complete)
4. `set_hub_state` already handles `:contemplating` (it's in `@valid_hub_states`)

**Changes required in `predicates.ex`:**

1. `:improving` predicate: when improvement cycle completes with no findings AND contemplating budget available -> transition to `:contemplating`
2. `:contemplating` predicate: when goals submitted -> transition to `:executing`, when budget exhausted -> transition to `:resting`
3. `:contemplating` stays otherwise (cycle in progress)

**Key design question:** The improving-to-contemplating transition. Currently, improvement cycle completion sends `{:improvement_cycle_complete, result}` and the handler transitions to `:resting`. The new flow should be: improvement cycle complete with zero findings -> `:contemplating`, with findings -> `:resting` (or `:executing` if goals were submitted).

### Existing Pattern: Proposal XML Schema

The `Proposal` struct already exists with fields: `id`, `title`, `description`, `rationale`, `impact`, `effort`, `repo`, `related_files`, `proposed_at`, `metadata`. The user decisions require additional fields:

| User Requirement | Current State | Gap |
|------------------|---------------|-----|
| Problem statement | `description` field exists | Rename semantics or add `problem` field |
| Proposed solution | Not explicit | Add `solution` field or use `description` |
| Estimated complexity | `effort` field (small/medium/large) | Sufficient |
| Dependencies | Not in schema | Add `dependencies` field (list of strings) |
| File references | `related_files` field exists | Already there |
| "Why now" section | Not in schema | Add `why_now` field |
| "Why not" section | Not in schema | Add `why_not` field |
| Scope constraint | Not enforced | Add to prompt instructions |

**Recommendation:** Enrich the Proposal struct with `problem`, `solution`, `why_now`, `why_not`, and `dependencies` fields. The `description` field remains as a summary. Update the XML schema, `Saxy.Builder` implementation, `from_simple_form/1`, and the prompt template accordingly.

### Existing Pattern: MetricsCollector Snapshot

`ScalabilityAnalyzer.analyze/1` already reads `MetricsCollector.snapshot/0` and produces a structured report with `current_state`, `metrics_summary`, `bottleneck_analysis`, and `recommendation`. This module is functionally complete for the scalability requirements.

The analyzer already:
- Reads queue depth, latency percentiles, agent utilization, error rates
- Detects bottlenecks with warning/critical thresholds
- Checks queue depth trends for growth patterns
- Produces recommendations distinguishing "add agents" vs "add machines" vs "investigate errors"

### Recommended Project Structure

```
lib/agent_com/
  contemplation.ex                          # Orchestrator (EXISTS, enrich)
  contemplation/
    proposal_writer.ex                      # XML file writer (EXISTS, complete)
    scalability_analyzer.ex                 # Metric analysis (EXISTS, complete)
  hub_fsm.ex                               # 4-state expansion (EXISTS, modify)
  hub_fsm/
    predicates.ex                           # Add contemplating predicates (EXISTS, modify)
  xml/schemas/
    proposal.ex                             # Enrich schema (EXISTS, modify)
  claude_client/
    prompt.ex                               # Enrich proposal prompt (EXISTS, modify)
    response.ex                             # Enrich proposal parser (EXISTS, modify)

test/agent_com/
  contemplation_test.exs                    # NEW
  contemplation/
    proposal_writer_test.exs                # NEW
    scalability_analyzer_test.exs           # NEW
  hub_fsm/
    predicates_test.exs                     # MODIFY (add contemplating tests)
  hub_fsm_test.exs                          # MODIFY (add 4-state tests)
```

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| XML encoding | Custom string builder | `Saxy.Builder` protocol | Already established, handles escaping correctly |
| Metric percentiles | Custom math | Existing `MetricsCollector` private helpers | Already tested and handles edge cases |
| Budget gating | Custom checks | `CostLedger.check_budget(:contemplating)` | Already configured with 5/hr, 15/day limits |
| File system operations | Raw File calls | `ProposalWriter` module | Already handles directory creation and sanitization |

## Common Pitfalls

### Pitfall 1: HubFSM State Transition Race Condition
**What goes wrong:** Improving cycle completes and sends `:improvement_cycle_complete`, but between receiving that message and transitioning to `:contemplating`, a new goal is submitted. The FSM transitions to `:contemplating` but should have gone to `:executing`.
**Why it happens:** The improvement result message handler currently unconditionally transitions to `:resting`.
**How to avoid:** In the `:improvement_cycle_complete` handler, check `gather_system_state()` for pending goals before deciding whether to go to `:contemplating` or `:resting`. If pending goals > 0, go to `:executing` instead.
**Warning signs:** Goals sitting in submitted state while FSM is in `:contemplating`.

### Pitfall 2: Contemplation Blocking the FSM
**What goes wrong:** LLM call for proposal generation takes too long, FSM stuck in `:contemplating` state.
**Why it happens:** Synchronous LLM call within the contemplation cycle.
**How to avoid:** Already mitigated -- `Contemplation.run()` is called via `Task.start`, same pattern as improvement cycle. The watchdog timer (2 hours) provides a safety net. Additionally, `ClaudeClient` has its own `@default_timeout_ms` of 120 seconds.
**Warning signs:** `:contemplating` state duration exceeding expected LLM response time.

### Pitfall 3: Proposal Schema Breaking XML Round-Trip
**What goes wrong:** Adding new fields to Proposal struct but forgetting to update `Saxy.Builder` implementation or `from_simple_form/1`, causing encode/decode mismatch.
**Why it happens:** The struct, builder, and parser are in different locations within the same file.
**How to avoid:** Test round-trip: `struct -> encode -> decode -> assert struct fields match`. Existing `xml_test.exs` has this pattern for Goal and ScanResult schemas.
**Warning signs:** Nil fields after XML round-trip.

### Pitfall 4: Improving-to-Contemplating Transition Logic
**What goes wrong:** Every improvement cycle transitions to `:contemplating` regardless of whether improvements were found.
**Why it happens:** Misreading the user decision: "Hub enters Contemplating when Improving finds nothing to improve."
**How to avoid:** The transition to `:contemplating` should ONLY happen when the improvement cycle produces zero findings. If findings were submitted as goals, transition to `:resting` (or `:executing` if goals are now pending).
**Warning signs:** Contemplation cycles running after every improvement cycle, even productive ones.

### Pitfall 5: Proposal Directory Path Confusion
**What goes wrong:** CONTEXT.md says `proposals/` directory but existing code uses `priv/proposals/`.
**Why it happens:** Ambiguity in the user decision about directory location.
**How to avoid:** The existing `ProposalWriter` uses `priv/proposals/` with a configurable `:proposals_dir` app env. Keep this -- `priv/` is the conventional Elixir location for application-generated artifacts. The CONTEXT.md `proposals/` is satisfied by the `priv/proposals/` location.
**Warning signs:** Proposals written to unexpected locations.

## Code Examples

### HubFSM 4-State Valid Transitions (Source: existing hub_fsm.ex pattern)

```elixir
@valid_transitions %{
  resting: [:executing, :improving],
  executing: [:resting],
  improving: [:resting, :executing, :contemplating],
  contemplating: [:resting]
}
```

### Contemplating Predicates (Source: existing predicates.ex pattern)

```elixir
# Contemplating -> executing: goals submitted (new work to do)
def evaluate(:contemplating, %{pending_goals: pending}) when pending > 0 do
  {:transition, :executing, "goals submitted while contemplating"}
end

# Contemplating -> resting: budget exhausted
def evaluate(:contemplating, %{budget_exhausted: true}) do
  {:transition, :resting, "budget exhausted while contemplating"}
end

# Contemplating: stay (cycle in progress)
def evaluate(:contemplating, _system_state), do: :stay
```

### Improvement Cycle Complete Handler (Source: existing hub_fsm.ex lines 309-318, modified)

```elixir
def handle_info({:improvement_cycle_complete, result}, state) do
  Logger.info("improvement_cycle_complete", result: inspect(result))

  if state.fsm_state == :improving do
    findings_count = get_in(result, [:findings]) || 0
    system_state = gather_system_state()

    cond do
      system_state.pending_goals > 0 ->
        updated = do_transition(state, :executing, "goals submitted during improvement")
        {:noreply, updated}

      findings_count == 0 and contemplating_budget_available?() ->
        updated = do_transition(state, :contemplating, "no improvements found, contemplating")
        {:noreply, updated}

      true ->
        updated = do_transition(state, :resting, "improvement cycle complete")
        {:noreply, updated}
    end
  else
    {:noreply, state}
  end
end
```

### Enriched Proposal Struct Fields (Discretion recommendation)

```elixir
defstruct [
  :id,
  :title,
  :problem,          # NEW: problem statement
  :solution,         # NEW: proposed solution
  :description,      # Kept: summary/overview
  :rationale,        # Kept: evidence-based motivation
  :why_now,          # NEW: why this should be done now
  :why_not,          # NEW: risks/reasons not to do this
  :impact,
  :effort,
  :repo,
  :proposed_at,
  :metadata,
  related_files: [], # Kept: actual codebase references
  dependencies: []   # NEW: list of dependency strings
]
```

### Contemplation Cycle Spawn in do_transition (Source: existing improving pattern)

```elixir
# In do_transition, after existing improving block:
if new_state == :contemplating do
  pid = self()
  Task.start(fn ->
    result = AgentCom.Contemplation.run()
    send(pid, {:contemplation_cycle_complete, result})
  end)
end
```

## State of the Art

| Area | Current State | What Phase 33 Changes |
|------|---------------|----------------------|
| HubFSM | 3-state (resting/executing/improving) | Expand to 4-state (add contemplating) |
| Predicates | Handles 3 states | Add contemplating clauses + modify improving->contemplating transition |
| Proposal schema | Basic fields (title, desc, rationale, impact, effort) | Add problem, solution, why_now, why_not, dependencies |
| Contemplation module | Exists, functional orchestrator | Enrich context gathering (read PROJECT.md out-of-scope) |
| ProposalWriter | Exists, writes to priv/proposals/ | No changes needed |
| ScalabilityAnalyzer | Exists, reads MetricsCollector | No changes needed |
| ClaudeClient | Has generate_proposals prompt/response | Enrich prompt with new schema fields |
| CostLedger | Has :contemplating budgets (5/hr, 15/day) | No changes needed |

## Discretion Recommendations

### 1. Proposal XML Schema Design
**Recommendation:** Extend the existing `Proposal` struct with `problem`, `solution`, `why_now`, `why_not`, and `dependencies` fields. Keep all existing fields. The XML structure becomes:

```xml
<proposal id="prop-001" impact="high" effort="medium" repo="AgentCom" proposed-at="2026-02-13T00:00:00Z">
  <title>Add circuit breaker to CLI calls</title>
  <problem>CLI calls timeout under load with no backoff</problem>
  <solution>Implement circuit breaker with configurable thresholds</solution>
  <description>Summary overview of the proposal</description>
  <rationale>Observed 3 CLI timeouts in last 24 hours</rationale>
  <why-now>System approaching production scale, failures will compound</why-now>
  <why-not>Adds complexity; may mask underlying issues</why-not>
  <dependencies>
    <dependency>ClaudeClient module refactor</dependency>
  </dependencies>
  <related-files>
    <file>lib/agent_com/claude_client.ex</file>
    <file>lib/agent_com/claude_client/cli.ex</file>
  </related-files>
  <metadata>optional freeform</metadata>
</proposal>
```

**Confidence:** HIGH -- follows established XML schema patterns in codebase.

### 2. Scalability Report Format
**Recommendation:** Keep as Elixir map (current implementation). The ScalabilityAnalyzer already produces a well-structured map consumed by the dashboard. No need for XML or markdown -- the map is serialized to JSON for the dashboard and stored in the contemplation report. If a file-based report is desired later, it can be trivially added.

**Confidence:** HIGH -- existing implementation is already complete and integrated.

### 3. How to Identify "Interesting" Features
**Recommendation:** Enrich the proposal generation prompt to analyze:
- FSM history patterns (e.g., frequent transitions, long stuck periods)
- Recent error/failure patterns from MetricsCollector
- MODULE.md and PROJECT.md out-of-scope items (to AVOID proposing them)
- Tech debt patterns from the codebase structure
- The `Contemplation.default_context/0` function already gathers FSM history and codebase summary. Extend it to include: scalability report summary, recent error rates, and out-of-scope items from PROJECT.md.

**Confidence:** MEDIUM -- prompt engineering effectiveness depends on LLM behavior.

### 4. Integration with PROJECT.md Tech Debt
**Recommendation:** Yes, read PROJECT.md Out of Scope section and pass it to the prompt as exclusions. The existing `Contemplation.default_context/0` already has a hardcoded `out_of_scope` string. Replace this with actual file reading of `.planning/PROJECT.md` Out of Scope section. This directly addresses the user's specific idea: "Contemplation should read PROJECT.md Out of Scope section to avoid proposing excluded features."

**Confidence:** HIGH -- straightforward file reading, no external dependencies.

## Open Questions

1. **Improving-to-Contemplating signal mechanism**
   - What we know: The `:improvement_cycle_complete` message carries a result map with `findings` count and `goals_submitted` count.
   - What's unclear: Should the transition to `:contemplating` also check CostLedger contemplating budget, or just rely on the tick predicate to handle budget exhaustion after transition?
   - Recommendation: Check contemplating budget availability in the handler before transitioning. If budget exhausted, go to `:resting`. This prevents a needless transition.

2. **Contemplation cycle completion signal**
   - What we know: `Contemplation.run/1` returns `{:ok, report}` with proposals and scalability data.
   - What's unclear: Should the contemplation cycle always transition to `:resting` on completion, or should it also consider pending goals?
   - Recommendation: Mirror the improvement pattern -- check for pending goals on completion. If goals pending, go to `:executing`. Otherwise go to `:resting`. The user decision says "Generates max 3 proposals per cycle, then transitions to Resting" which suggests always going to `:resting`, but checking for goals is defensive.

3. **Existing code quality and completeness**
   - What we know: The contemplation modules exist but have no tests. ProposalWriter and ScalabilityAnalyzer look functionally complete. The Contemplation orchestrator works end-to-end.
   - What's unclear: Has any of this code been manually tested or run?
   - Recommendation: Treat existing code as untested scaffolding. Write comprehensive tests that verify behavior, and fix any issues discovered during testing.

## Sources

### Primary (HIGH confidence)
- `lib/agent_com/contemplation.ex` -- existing orchestrator implementation
- `lib/agent_com/contemplation/proposal_writer.ex` -- existing XML file writer
- `lib/agent_com/contemplation/scalability_analyzer.ex` -- existing metric analyzer
- `lib/agent_com/hub_fsm.ex` -- current 3-state FSM, transition patterns
- `lib/agent_com/hub_fsm/predicates.ex` -- current predicate logic
- `lib/agent_com/xml/schemas/proposal.ex` -- current Proposal schema
- `lib/agent_com/claude_client/prompt.ex` -- existing `:generate_proposals` prompt
- `lib/agent_com/claude_client/response.ex` -- existing `:generate_proposals` parser
- `lib/agent_com/cost_ledger.ex` -- `:contemplating` budget already configured
- `lib/agent_com/metrics_collector.ex` -- `snapshot/0` API and shape
- `lib/agent_com/self_improvement.ex` -- pattern for HubFSM-triggered cycles
- `.planning/phases/29-hub-fsm-core/29-VERIFICATION.md` -- FSM expansion design intent
- `.planning/phases/29-hub-fsm-core/29-CONTEXT.md` -- original 4-state transition design

### Secondary (MEDIUM confidence)
- `.planning/PROJECT.md` Out of Scope section -- exclusions for proposal generation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all modules already exist in codebase, no new dependencies
- Architecture: HIGH -- follows established patterns (stateless lib module, Task.start for async cycles, pure predicates)
- Pitfalls: HIGH -- identified from actual code review of existing patterns and their edge cases
- Discretion recommendations: HIGH for schema/format, MEDIUM for prompt engineering

**Research date:** 2026-02-13
**Valid until:** 2026-03-13
