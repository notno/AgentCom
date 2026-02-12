# Roadmap: AgentCom v2

## Milestones

- [x] **v1.0 Core Architecture** - Phases 1-8 (shipped 2026-02-11)
- [x] **v1.1 Hardening** - Phases 9-16 (shipped 2026-02-12)
- [ ] **v1.2 Smart Agent Pipeline** - Phases 17-22 (in progress)

## Phases

<details>
<summary>v1.0 Core Architecture (Phases 1-8) - SHIPPED 2026-02-11</summary>

| Phase | Name | What It Delivered |
|-------|------|-------------------|
| 1 | Sidecar | Always-on Node.js WebSocket relay, wake trigger, queue management |
| 2 | Task Queue | DETS-backed persistent queue with priority lanes, retries, dead-letter |
| 3 | Agent State | Per-agent FSM (idle/assigned/working/blocked/offline) |
| 4 | Scheduler | Event-driven task-to-agent matcher with capability routing |
| 5 | Smoke Test | End-to-end validation with 2 simulated agents |
| 6 | Dashboard | Real-time HTML dashboard with WebSocket updates, health monitoring, push notifications |
| 7 | Git Workflow | Branch-from-main enforcement, PR submission automation |
| 8 | Onboarding | One-command agent provisioning, Culture ship names, teardown & submit CLIs |

48 commits, 65 files, +12,858 LOC across 2 days.

</details>

<details>
<summary>v1.1 Hardening (Phases 9-16) - SHIPPED 2026-02-12</summary>

| Phase | Name | What It Delivered |
|-------|------|-------------------|
| 9 | Testing Infrastructure | DETS isolation, test factories, WS client, GenServer + integration tests, CI pipeline |
| 10 | DETS Backup + Monitoring | Automated backup with 3-backup retention, health endpoint, dashboard visibility |
| 11 | DETS Compaction + Recovery | Scheduled compaction, corruption detection, backup-based recovery, degraded mode |
| 12 | Input Validation | 27 schemas (15 WS + 12 HTTP), violation tracking, escalating disconnect backoff |
| 13 | Structured Logging + Telemetry | LoggerJSON with dual output, 22 telemetry events, token redaction, sidecar structured logs |
| 14 | Metrics + Alerting | ETS-backed metrics (queue depth, latency percentiles, utilization), 5 alert rules, dashboard charts |
| 15 | Rate Limiting | Token bucket with 3-tier classification, progressive backoff, admin overrides, DETS persistence |
| 16 | Operations Documentation | ExDoc with Mermaid diagrams, setup guide, daily operations, troubleshooting procedures |

153 commits, 195 files, +35,732 LOC across 4 days.

</details>

### v1.2 Smart Agent Pipeline (In Progress)

**Milestone Goal:** Transform agents from blind task executors into context-aware, self-verifying workers with cost-efficient model routing across a distributed LLM mesh.

**Phase Numbering:** Integer phases (17, 18, 19...): Planned milestone work. Decimal phases (17.1, 17.2): Urgent insertions (marked with INSERTED).

- [x] **Phase 17: Enriched Task Format** - Tasks carry structured context, success criteria, verification steps, and complexity classification
- [ ] **Phase 18: LLM Registry and Host Resources** - Hub tracks Ollama endpoints, model availability, and host resource utilization across the Tailscale mesh
- [ ] **Phase 19: Model-Aware Scheduler** - Scheduler routes tasks to the right execution tier based on complexity, model availability, and host load
- [ ] **Phase 20: Sidecar Execution** - Sidecars call the correct LLM backend (local Ollama, Claude API, or zero-token local execution) per task assignment
- [ ] **Phase 21: Verification Infrastructure** - Deterministic mechanical verification checks produce structured pass/fail reports before task submission
- [ ] **Phase 22: Self-Verification Loop** - Agents run verification after execution and retry fixes when checks fail (build-verify-fix pattern)

## Phase Details

### Phase 17: Enriched Task Format
**Goal**: Tasks carry all the information agents need to understand scope, verify completion, and route efficiently
**Depends on**: Nothing (foundation for v1.2)
**Requirements**: TASK-01, TASK-02, TASK-03, TASK-04, TASK-05
**Success Criteria** (what must be TRUE):
  1. A task submitted with context fields (repo, branch, relevant files) arrives at the sidecar with those fields intact
  2. A task submitted with success criteria and verification steps stores and retrieves them through the full pipeline (submit, assign, complete)
  3. A task submitted with an explicit complexity tier (trivial/standard/complex) carries that classification through assignment
  4. A task submitted without a complexity tier receives an inferred classification from the heuristic engine based on its content
  5. Existing v1.0/v1.1 tasks (without enrichment fields) continue working unchanged
**Plans**: 3 plans

Plans:
- [ ] 17-01-PLAN.md -- Complexity heuristic engine (TDD, pure-function module)
- [ ] 17-02-PLAN.md -- Task enrichment fields and validation schemas
- [ ] 17-03-PLAN.md -- Pipeline propagation (Scheduler, Socket, Sidecar wiring)

### Phase 18: LLM Registry and Host Resources
**Goal**: Hub knows which Ollama models are available on which hosts, whether they are healthy, and what resources each host has available
**Depends on**: Nothing (can build parallel with Phase 17)
**Requirements**: REG-01, REG-02, REG-03, REG-04, HOST-01, HOST-02, HOST-03
**Success Criteria** (what must be TRUE):
  1. Admin can register an Ollama endpoint via HTTP API and see it listed with its host, port, and discovered models
  2. An Ollama endpoint that goes offline is marked unhealthy within one health check cycle, and re-marked healthy when it returns
  3. Registry distinguishes between models currently loaded in VRAM (warm) and models only downloaded (cold) per host
  4. Dashboard shows per-machine resource utilization (CPU, RAM, GPU/VRAM) reported by each sidecar
  5. Registered endpoints and resource metrics survive hub restart (DETS persistence)
**Plans**: 4 plans

Plans:
- [ ] 18-01-PLAN.md -- LLM Registry GenServer core (TDD: DETS persistence, health checks, model discovery)
- [ ] 18-02-PLAN.md -- Sidecar resource reporting (resources.js, identify extension, periodic metrics)
- [ ] 18-03-PLAN.md -- Pipeline wiring (WS handlers, HTTP admin routes, validation schemas, supervisor)
- [ ] 18-04-PLAN.md -- Dashboard integration (registry table, resource bars, fleet summary, add/remove controls)

### Phase 19: Model-Aware Scheduler
**Goal**: Scheduler sends trivial tasks to sidecar direct execution, standard tasks to local Ollama agents, and complex tasks to Claude agents -- picking the best available endpoint
**Depends on**: Phase 17 (enriched tasks with complexity tiers), Phase 18 (registry with endpoint/resource data)
**Requirements**: ROUTE-01, ROUTE-02, ROUTE-03, ROUTE-04, HOST-04
**Success Criteria** (what must be TRUE):
  1. A trivial-complexity task is routed to sidecar direct execution (not to an LLM)
  2. A standard-complexity task is routed to an agent backed by a healthy Ollama endpoint with the needed model loaded
  3. A complex-complexity task is routed to a Claude-backed agent
  4. When two Ollama hosts have the same model loaded, the scheduler distributes tasks toward the less-loaded host
  5. Every routing decision is logged with the model selected, endpoint chosen, and the classification reason
**Plans**: 4 plans

Plans:
- [ ] 19-01-PLAN.md -- TaskRouter routing decision engine (TDD: tier resolution, endpoint scoring, load balancing)
- [ ] 19-02-PLAN.md -- Scheduler wiring (TaskRouter integration, fallback timers, llm_registry PubSub, routing telemetry)
- [ ] 19-03-PLAN.md -- Config + alerting + TTL (routing timeouts, tier-down alert rule, task TTL sweep)
- [ ] 19-04-PLAN.md -- Dashboard routing visibility (routing column, fallback badge, expandable detail, routing stats)

### Phase 20: Sidecar Execution
**Goal**: Sidecars execute tasks using the LLM backend the hub assigned -- local Ollama for standard work, Claude API for complex work, or local shell commands for trivial work -- and report what model and tokens were used
**Depends on**: Phase 17 (enriched task arrives at sidecar), Phase 19 (hub sends routing fields with assignment)
**Requirements**: EXEC-01, EXEC-02, EXEC-03, EXEC-04
**Success Criteria** (what must be TRUE):
  1. A task assigned with strategy "local_llm" calls the specified Ollama endpoint and returns the model's response
  2. A task assigned with strategy "cloud_llm" calls the Claude API and returns the model's response
  3. A task assigned with strategy "trivial" executes the specified shell command locally with zero LLM tokens consumed
  4. Every completed task result includes the model used (or "none" for trivial), tokens consumed, and estimated cost
**Plans**: TBD

Plans:
- [ ] 20-01: TBD
- [ ] 20-02: TBD
- [ ] 20-03: TBD

### Phase 21: Verification Infrastructure
**Goal**: After task execution, deterministic mechanical checks produce a structured verification report that confirms work was done correctly before submission
**Depends on**: Phase 17 (tasks carry verification_steps), Phase 20 (execution produces results to verify)
**Requirements**: VERIFY-01, VERIFY-02, VERIFY-04
**Success Criteria** (what must be TRUE):
  1. A completed task includes a structured verification report showing pass/fail for each verification step
  2. Pre-built verification step types (file_exists, test_passes, git_clean, command_succeeds) work out of the box when specified in a task
  3. Mechanical verification (compile, tests, file existence) runs before any LLM-based judgment in the verification pipeline
**Plans**: 3 plans

Plans:
- [ ] 21-01-PLAN.md -- Verification report structure and DETS-backed Store (TDD)
- [ ] 21-02-PLAN.md -- Sidecar verification runner with 4 check types
- [ ] 21-03-PLAN.md -- Hub pipeline wiring and dashboard rendering

### Phase 22: Self-Verification Loop
**Goal**: Agents that fail verification automatically retry with corrective action, only submitting when checks pass or retry budget is exhausted
**Depends on**: Phase 20 (execution backend to retry with), Phase 21 (verification checks to evaluate against)
**Requirements**: VERIFY-03
**Success Criteria** (what must be TRUE):
  1. When verification fails after task completion, the agent feeds failure details back to the LLM and retries the fix (build-verify-fix loop)
  2. The retry loop terminates after a configurable maximum number of attempts, submitting with a partial-pass report if budget exhausted
  3. Each verification retry iteration is visible in the task result (attempt count, which checks passed/failed per iteration)
**Plans**: TBD

Plans:
- [ ] 22-01: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 17 -> 17.1 -> 17.2 -> 18 -> ... -> 22

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-8 | v1.0 | 19/19 | Complete | 2026-02-11 |
| 9-16 | v1.1 | 32/32 | Complete | 2026-02-12 |
| 17. Enriched Task Format | v1.2 | 3/3 | Complete | 2026-02-12 |
| 18. LLM Registry + Host Resources | v1.2 | 0/4 | Planned | - |
| 19. Model-Aware Scheduler | v1.2 | 0/4 | Planned | - |
| 20. Sidecar Execution | v1.2 | 0/TBD | Not started | - |
| 21. Verification Infrastructure | v1.2 | 0/TBD | Not started | - |
| 22. Self-Verification Loop | v1.2 | 0/TBD | Not started | - |
