---
created: 2026-02-12T19:58:00.000Z
title: Multi-project fallback queue for idle agent utilization
area: architecture
files:
  - lib/agent_com/scheduler.ex
  - lib/agent_com/task_queue.ex
---

## Problem

When the primary project's task queue is empty, agents sit idle. This wastes compute — especially GPU machines running Ollama that could be doing useful work on secondary projects. There's no mechanism to say "if AgentCom has no tasks, work on Project B; if B is empty, try Project C."

This becomes more valuable as the fleet scales: with 5+ machines and local LLM capability, idle time during planning/discussion phases (which are human-bottlenecked) is significant wasted capacity.

## Solution

Design a priority-ordered project fallback system:

### Core concept
- Hub maintains an ordered list of project configs (repo URL, branch rules, task source)
- Primary project gets all agent attention when it has tasks
- When primary queue is empty, scheduler checks the next project in priority order
- Each project defines its own repo, branch conventions, and task types

### Key design questions

1. **Task sourcing per project**: Where do secondary project tasks come from?
   - Option A: Each project has its own task queue in the hub (multi-queue)
   - Option B: A single queue with project tags — scheduler filters by priority
   - Option C: Secondary projects pull from GitHub Issues or external sources

2. **Agent context switching**: How does an agent switch between projects?
   - Sidecar needs to clone/checkout the right repo
   - Agent workspace (branch, working directory) must be project-specific
   - Clean handoff — don't leave half-done work on secondary when primary gets new tasks

3. **Preemption policy**: What happens when primary gets a new task while agents work on secondary?
   - Finish current secondary task then return? (simpler, wastes less work)
   - Interrupt immediately? (faster response, loses in-progress work)
   - Priority-based: only preempt for high-priority primary tasks?

4. **Project config shape**:
   ```elixir
   %{
     priority: 1,                    # lower = higher priority
     name: "agentcom",
     repo: "notno/AgentCom",
     branch_prefix: "agent/",
     task_source: :internal_queue,    # or :github_issues
     preemptible: false               # primary is never preempted
   }
   ```

5. **Scope boundaries**: Should secondary projects share the same hub, or spin up separate hub instances? Single hub is simpler but mixes concerns. Separate hubs waste resources.

6. **Reporting**: Dashboard should show which project each agent is working on, and time-split across projects.

### Potential phases
- Phase A: Project registry (CRUD for project configs with priority ordering)
- Phase B: Multi-queue or tagged queue support
- Phase C: Scheduler fallback logic (check next project when current is empty)
- Phase D: Sidecar project switching (repo checkout, workspace isolation)
- Phase E: Preemption policy and handoff
- Phase F: Dashboard multi-project view
