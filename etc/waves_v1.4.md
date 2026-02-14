# v1.4 Reliable Autonomy — Wave Execution Plan

## Dependency Graph

```
Phase 37 (CI Fix)
  |
  +-- Phase 38 (OllamaClient + Hub Routing) ------+
  |                                                |
  +-- Phase 39 (Pipeline Reliability) -------------+-- Phase 43 (Healing) -- Phase 44 (Testing)
  |                                                |
  +-- Phase 40 (Tool Infrastructure) -- Phase 41 (Agentic Loop)
  |
  +-- Phase 42 (pm2 Self-Management)
```

## Two Independent Tracks

The work naturally splits into **hub-side** and **sidecar-side**:

**Hub track:** 37 -> 38 -> 43 -> 44
- OllamaClient in Elixir -> Healing state uses it -> Tests validate it

**Sidecar track:** 37 -> 40 -> 41
- Tool registry + executor -> ReAct loop uses them

**Cross-cutting:** 37 -> 39 (touches both hub and sidecar)
**Independent:** 37 -> 42 (small, self-contained)

## Waves

| Wave | Phases | What | Why together |
|------|--------|------|-------------|
| **Wave 1** | 37 | CI Fix | Unblocks everything. Nothing can merge to main until CI is green. |
| **Wave 2** | 38 + 39 + 40 + 42 | All four parallel | Each depends only on 37. Hub work (38) and sidecar work (40) are completely independent codebases. Pipeline reliability (39) touches both but different files. pm2 (42) is tiny and isolated. |
| **Wave 3** | 41 + 43 | Agentic loop + Healing | 41 needs 40's tools. 43 needs 38's OllamaClient + 39's reliability fixes. Both are the "big payoff" phases. Also parallel -- 41 is sidecar JS, 43 is hub Elixir. |
| **Wave 4** | 44 | FSM Testing | Needs Healing state (43) to exist before testing it. Small phase, clean cap on the milestone. |

## Critical Path

**4 waves, not 8 serial phases.** The critical path is:

```
37 -> {38 or 39} -> 43 -> 44
```

That's 4 sequential steps. Phases 40, 41, 42 run alongside without extending the timeline.

The bottleneck is **Wave 2** -- it has the most work (4 phases). But since they're on different tracks (Elixir vs JS vs pm2), they genuinely parallelize if you run `/gsd:execute-phase` on them concurrently or in quick succession.

## Pitfalls Research Flag

The pitfalls research strongly recommends: **fix pipeline reliability (39) before agentic execution goes live (41)**. The reasoning is sound -- agentic tasks generate more tasks, which amplifies existing failure modes (silent wake hangs, no timeouts). The wave structure respects this: 39 is in Wave 2, 41 is in Wave 3.

## Execution Strategy

If running phases one at a time, the fastest order is:
1. **37** -- quick, maybe 1 plan
2. **40** -- sidecar tools (while you plan 38)
3. **38** -- hub OllamaClient
4. **39** -- pipeline reliability
5. **42** -- pm2 (small, slot in anywhere)
6. **41** -- agentic loop (40 done, 39 done = safe to go)
7. **43** -- healing (38 + 39 done)
8. **44** -- testing (43 done)

If executing waves in parallel via `/gsd:execute-phase`, Wave 2 is where the biggest time savings are.
