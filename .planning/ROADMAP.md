# Roadmap: AgentCom v2

## Milestones

- [x] **v1.0 Core Architecture** - Phases 1-8 (shipped 2026-02-11)
- [x] **v1.1 Hardening** - Phases 9-16 (shipped 2026-02-12)
- [x] **v1.2 Smart Agent Pipeline** - Phases 17-23 (shipped 2026-02-12)
- [x] **v1.3 Hub FSM Loop of Self-Improvement** - Phases 24-36 (shipped 2026-02-14)
- [ ] **v1.4 Reliable Autonomy** - Phases 37-44 (in progress)

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

<details>
<summary>v1.2 Smart Agent Pipeline (Phases 17-23) - SHIPPED 2026-02-12</summary>

| Phase | Name | What It Delivered |
|-------|------|-------------------|
| 17 | Enriched Task Format | Structured context, success criteria, verification steps, complexity classification with heuristic inference |
| 18 | LLM Registry + Host Resources | Ollama endpoint registry with health checks, model discovery, host CPU/RAM/VRAM reporting |
| 19 | Model-Aware Scheduler | Complexity-based tier routing (trivial/standard/complex), load-balanced endpoint scoring, fallback chains |
| 20 | Sidecar Execution | Three executors (Ollama, Claude, Shell) with cost tracking, streaming progress, per-model cost estimation |
| 21 | Verification Infrastructure | Deterministic mechanical checks (file_exists, test_passes, git_clean, command_succeeds) with structured reports |
| 22 | Self-Verification Loop | Build-verify-fix pattern with corrective prompts, configurable retry budget, cumulative cost tracking |
| 23 | Multi-Repo Registry + Workspace Switching | Priority-ordered repo list, scheduler filtering, nil-repo inheritance, sidecar workspace isolation |

136 commits, 147 files, +26,075 LOC across 1 day.

</details>

<details>
<summary>v1.3 Hub FSM Loop of Self-Improvement (Phases 24-36) - SHIPPED 2026-02-14</summary>

| Phase | Name | What It Delivered |
|-------|------|-------------------|
| 24 | Document Format Conversion | Saxy-based XML infrastructure with 5 schema structs and round-trip encoding |
| 25 | Cost Control Infrastructure | CostLedger GenServer with dual DETS+ETS, per-state budgets, telemetry alerting |
| 26 | Claude API Client | CLI-based ClaudeClient GenServer with budget-gated invocation, prompt templates, response parsing |
| 27 | Goal Backlog | DETS-backed goal storage with lifecycle state machine, priority ordering, multi-channel intake |
| 28 | Pipeline Dependencies | Task dependency graph with forward-only constraints, scheduler filtering, goal tracking |
| 29 | Hub FSM Core | 4-state autonomous brain (Executing/Improving/Contemplating/Resting) with tick-driven transitions |
| 30 | Goal Decomposition and Inner Loop | LLM-powered goal-to-task transformation with Ralph-style verify-retry inner loop |
| 31 | Hub Event Wiring | GitHub webhook endpoint with signature verification, FSM wake triggers, event history |
| 32 | Improvement Scanning | Deterministic + LLM-assisted codebase scanning with anti-oscillation and file cooldowns |
| 33 | Contemplation and Scalability | Feature proposal generation, enriched proposal schema, scalability bottleneck analysis |
| 34 | Tiered Autonomy | Risk-based PR classification with configurable thresholds, sidecar diff integration |
| 35 | Pre-Publication Cleanup | Secret scanning, IP replacement, workspace file management, personal reference detection |
| 36 | Dashboard and Observability | Goal progress panels, cost tracking display, FSM state duration visualization |

167 commits, 242 files, +39,920 LOC across 2 days.

</details>

### v1.4 Reliable Autonomy (In Progress)

**Milestone Goal:** Make the autonomous pipeline actually work end-to-end -- local LLMs execute agentic tool-calling loops, the hub heals its own infrastructure and code, and the pipeline reliably moves tasks from assignment to completion.

**Phase Numbering:** 37-44 (8 phases)

- [x] **Phase 37: CI Fix** - Unblock CI with green builds before building new features (shipped 2026-02-14)
- [ ] **Phase 38: OllamaClient and Hub LLM Routing** - Hub-side Ollama HTTP client replaces all claude -p CLI calls
- [ ] **Phase 39: Pipeline Reliability** - Wake failures, execution timeouts, stuck task recovery, reconnect handling
- [ ] **Phase 40: Sidecar Tool Infrastructure** - Tool registry, sandboxed executor, structured observations for LLM tool calling
- [ ] **Phase 41: Agentic Execution Loop** - ReAct loop with guardrails, output parsing, adaptive limits, dashboard streaming
- [ ] **Phase 42: Agent Self-Management** - Sidecar pm2 awareness and hub-commanded restart capability
- [ ] **Phase 43: Hub FSM Healing** - 5th FSM state with health aggregation, automated remediation, watchdog timeout
- [ ] **Phase 44: Hub FSM Testing** - Integration tests covering all 5 FSM states, healing cycles, HTTP endpoints

## Phase Details

### Phase 37: CI Fix
**Goal**: CI pipeline passes -- merge conflicts resolved, compilation clean, tests green
**Depends on**: Nothing (first phase, unblocks everything)
**Requirements**: CI-01, CI-02, CI-03
**Success Criteria** (what must be TRUE):
  1. `git diff --check` on remote main shows zero conflict markers
  2. `mix compile --warnings-as-errors` exits 0 in CI environment
  3. `mix test --exclude skip --exclude smoke` exits 0 in CI environment
**Plans**: 1 plan

Plans:
- [ ] 37-01-PLAN.md -- Push local commit and verify CI green

### Phase 38: OllamaClient and Hub LLM Routing
**Goal**: Hub FSM operations (goal decomposition, improvement scanning, contemplation) talk to local Ollama instead of shelling out to claude -p
**Depends on**: Phase 37
**Requirements**: ROUTE-01, ROUTE-02, ROUTE-03, ROUTE-04
**Success Criteria** (what must be TRUE):
  1. Hub can send a chat request to Ollama /api/chat and receive a parsed response with content and token counts
  2. Goal decomposition produces valid task lists when routed through OllamaClient with Qwen3 8B
  3. Zero remaining `claude -p` or `ClaudeClient.Cli` calls in production code paths
  4. Hub FSM completes a full executing cycle (decompose goal, create tasks) using only local Ollama
**Plans**: TBD

Plans:
- [ ] 38-01: OllamaClient HTTP module
- [ ] 38-02: Hub FSM LLM routing swap and prompt adaptation

### Phase 39: Pipeline Reliability
**Goal**: Tasks reliably move from assignment to completion -- wake failures recovered, stuck tasks requeued, timeouts enforced, reconnects handled
**Depends on**: Phase 37
**Requirements**: PIPE-01, PIPE-02, PIPE-03, PIPE-04, PIPE-05, PIPE-06, PIPE-07
**Success Criteria** (what must be TRUE):
  1. Task with missing or failing wake_command is immediately failed (not silently stuck in working state)
  2. Agentic task exceeding 30-minute deadline is killed and requeued with retry counter incremented
  3. Task stuck in working state for >10 minutes with offline agent is automatically requeued
  4. Sidecar reconnecting after disconnect reports its state, and hub either continues waiting or requeues appropriately
  5. Task that exhausts iteration budget saves partial results and reports partial_pass status
**Plans**: TBD

Plans:
- [ ] 39-01: Wake failure recovery and no-wake fail-fast
- [ ] 39-02: Task timeouts, stuck detection, and idempotent requeue
- [ ] 39-03: Sidecar reconnect state recovery and per-iteration budget checks

### Phase 40: Sidecar Tool Infrastructure
**Goal**: Sidecar has a sandboxed tool execution layer that LLMs can call -- 5 tools with workspace isolation and structured JSON observations
**Depends on**: Phase 37
**Requirements**: AGENT-01, AGENT-02, AGENT-06
**Success Criteria** (what must be TRUE):
  1. ToolRegistry exports 5 tool definitions (read_file, write_file, list_directory, run_command, search_files) in Ollama function-calling JSON format
  2. Tool executor rejects file paths outside the task workspace (path traversal blocked)
  3. Tool executor kills commands exceeding per-tool timeout
  4. Every tool returns a structured JSON observation with typed fields (not raw text)
**Plans**: TBD

Plans:
- [ ] 40-01: Tool registry and sandbox
- [ ] 40-02: Tool executor with structured observations

### Phase 41: Agentic Execution Loop
**Goal**: Local Ollama models execute tasks via multi-turn tool-calling loops with safety guardrails, with real-time visibility in the dashboard
**Depends on**: Phase 40
**Requirements**: AGENT-03, AGENT-04, AGENT-05, AGENT-07, AGENT-08, AGENT-09, AGENT-10
**Success Criteria** (what must be TRUE):
  1. OllamaExecutor runs a multi-turn ReAct loop: sends task + tools to Ollama, parses tool_calls, executes tools, feeds results back, repeats until final answer
  2. Loop terminates on max iterations (5/10/20 by complexity tier), repeated tool calls, token budget exhaustion, or wall-clock timeout
  3. Output parser handles native tool_calls JSON, JSON-in-content extraction, and XML extraction (Qwen3 >5 tool fallback)
  4. Dashboard shows real-time tool call events (tool name, args summary, result summary) during agentic execution via WebSocket
  5. Task that times out or exhausts budget preserves partial work, runs verification on current state, and reports partial_pass with completed vs remaining
**Plans**: TBD

Plans:
- [ ] 41-01: ReAct loop core with output parsing
- [ ] 41-02: Safety guardrails and adaptive limits
- [ ] 41-03: System prompt, partial results, and dashboard streaming

### Phase 42: Agent Self-Management
**Goal**: Sidecars are aware of their own pm2 process and can restart themselves on hub command
**Depends on**: Phase 37
**Requirements**: PM2-01, PM2-02, PM2-03
**Success Criteria** (what must be TRUE):
  1. Sidecar can query its own pm2 process name and running status
  2. Sidecar can trigger its own graceful restart via pm2 (process exits, pm2 auto-restarts)
  3. Hub sends a restart command over WebSocket, and the target sidecar executes a graceful pm2 restart
**Plans**: TBD

Plans:
- [ ] 42-01: pm2 self-awareness and hub-commanded restart

### Phase 43: Hub FSM Healing
**Goal**: Hub autonomously detects and remediates infrastructure problems -- stuck tasks, dead endpoints, CI failures -- via a dedicated healing state with watchdog protection
**Depends on**: Phase 38, Phase 39
**Requirements**: HEAL-01, HEAL-02, HEAL-03, HEAL-04, HEAL-05, HEAL-06, HEAL-07, HEAL-08
**Success Criteria** (what must be TRUE):
  1. FSM transitions to :healing when critical issues detected (3+ stuck tasks, all endpoints unhealthy, compilation failure)
  2. Healing requeues stuck tasks (offline agent) and dead-letters tasks after 3 retries
  3. Healing attempts Ollama endpoint recovery with backoff retries and falls back to Claude routing if recovery fails
  4. Healing detects merge conflicts and compilation failures and produces actionable diagnostics
  5. Healing state force-transitions to :resting after 5-minute watchdog timeout with critical alert
**Plans**: TBD

Plans:
- [ ] 43-01: Healing state and health aggregator
- [ ] 43-02: Stuck task and endpoint remediation
- [ ] 43-03: CI/compilation healing, watchdog, and audit logging

### Phase 44: Hub FSM Testing
**Goal**: Integration tests validate all 5 FSM states, healing cycles, and HTTP control endpoints
**Depends on**: Phase 43
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04
**Success Criteria** (what must be TRUE):
  1. Tests exercise full FSM cycles: resting -> executing -> resting, resting -> improving -> contemplating -> resting
  2. Tests trigger healing state, verify remediation actions fire, and confirm exit to resting
  3. HTTP endpoints /api/hub/pause, /api/hub/resume, /api/hub/state, /api/hub/history return correct responses
  4. Watchdog timeout test verifies forced transition fires after configured timeout expires
**Plans**: TBD

Plans:
- [ ] 44-01: FSM cycle integration tests
- [ ] 44-02: Healing state and HTTP endpoint tests

## Progress

**Execution Order:**
Phases execute in numeric order: 37 -> 38 -> 39 -> 40 -> 41 -> 42 -> 43 -> 44
Note: Phases 38, 39, 40, 42 all depend only on Phase 37, so they can parallelize after CI is green.

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-8 | v1.0 | 19/19 | Complete | 2026-02-11 |
| 9-16 | v1.1 | 32/32 | Complete | 2026-02-12 |
| 17-23 | v1.2 | 25/25 | Complete | 2026-02-12 |
| 24-36 | v1.3 | 35/35 | Complete | 2026-02-14 |
| 37. CI Fix | v1.4 | 1/1 | Complete | 2026-02-14 |
| 38. OllamaClient + Hub LLM Routing | v1.4 | 0/TBD | Not started | - |
| 39. Pipeline Reliability | v1.4 | 0/TBD | Not started | - |
| 40. Sidecar Tool Infrastructure | v1.4 | 0/TBD | Not started | - |
| 41. Agentic Execution Loop | v1.4 | 0/TBD | Not started | - |
| 42. Agent Self-Management | v1.4 | 0/TBD | Not started | - |
| 43. Hub FSM Healing | v1.4 | 0/TBD | Not started | - |
| 44. Hub FSM Testing | v1.4 | 0/TBD | Not started | - |

**Totals:** 44 phases, 111+ plans across 5 milestones.
