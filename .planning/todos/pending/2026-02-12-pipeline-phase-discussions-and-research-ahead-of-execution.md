---
created: 2026-02-12T19:53:44.263Z
title: Pipeline phase discussions and research ahead of execution
area: planning
files:
  - .planning/ROADMAP.md
---

## Problem

Currently GSD phases run fully serially: discuss → research → plan → execute for phase N, then start phase N+1. This means discussion and research for downstream phases sit idle while earlier phases execute, even though they have no hard dependency on the executing code.

Analysis of v1.2 phases 17-22 showed that:
- **Discussion** needs only roadmap requirements — zero code dependency, can always be front-loaded
- **Research** is ~70-80% front-loadable — core research (external APIs, library choices, architectural patterns) is independent of prior phase code. Only internal codebase integration points need the prior phase's output.
- **Planning** can partially run against a dependency's finalized PLAN.md rather than waiting for its executed code (small rework risk if execution deviates)
- **Execution** is the only hard dependency

With pipelining, v1.2's 5 serial waves could compress to ~3 wall-clock waves.

## Solution

Investigate workflow changes to enable pipelining:

1. **Batch discussion**: After roadmap creation, allow running `/gsd:discuss-phase` for all (or several) future phases in a batch. Discussions only read ROADMAP.md + user intent, so they can all happen upfront.

2. **Eager research**: Allow `/gsd:research-phase` to run for phase N+1 while phase N is executing. Flag which research findings depend on unfinished code (mark as "provisional — verify after phase N lands"). External research (API docs, library eval) gets full confidence.

3. **Speculative planning**: Allow `/gsd:plan-phase` for phase N+1 once phase N's PLAN.md is finalized (before N executes). Plans reference the planned module structure rather than actual code. Add a lightweight "plan revalidation" step after the dependency phase executes.

4. **Pipeline visualization**: Show the pipeline state in `/gsd:progress` — which phases have discussion done, research done, plan done, vs executing.

5. **Dependency-aware scheduling**: The workflow could automatically suggest "Phase 19 discussion can start now" when phases 17+18 begin executing, rather than waiting for human to remember.

Key question: How much of this is GSD framework changes vs just user discipline about when to invoke commands?
