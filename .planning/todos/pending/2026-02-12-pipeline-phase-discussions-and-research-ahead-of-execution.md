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

## Brainstorm Notes (2026-02-12)

### Agent delegation angle
GSD skills are just markdown files loaded into Claude Code. The sidecar wake command runs openclaw (Claude Code) with a task message. If openclaw has GSD installed, it already has the skills — a task description like "run /gsd:research-phase 19" might just work.

The hub would need DAG-aware scheduling (depends_on fields, release-on-completion) to orchestrate the pipeline automatically. But the simplest version is just manually submitting discussion/research tasks via `agentcom-submit.js`.

### Key blockers identified
1. **Discussion should stay human-in-the-loop** — that's where architectural decisions happen, not something to automate away
2. **openclaw + GSD is untested** — we haven't verified that an agent can invoke GSD skills via task message. This is the prerequisite experiment before any pipeline tooling.
3. **No framework changes needed for manual pipelining** — just run `/gsd:discuss-phase 19` in a separate conversation while Phase 18 executes

### Prerequisite experiment
Before building any pipeline tooling, test the basics:
1. Submit a simple task: "Create a file called test.md with 'hello world'"
2. Verify openclaw picks it up and executes
3. Then try a GSD skill as the task description
4. Observe what happens

### Front door reminder
```bash
node sidecar/agentcom-submit.js \
  --description "..." \
  --hub http://<hub-ip>:4000 \
  --token <token>
```
