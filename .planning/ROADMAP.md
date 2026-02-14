# Roadmap: AgentCom v2

## Milestones

- [x] **v1.0 Core Architecture** - Phases 1-8 (shipped 2026-02-11)
- [x] **v1.1 Hardening** - Phases 9-16 (shipped 2026-02-12)
- [x] **v1.2 Smart Agent Pipeline** - Phases 17-23 (shipped 2026-02-12)
- [x] **v1.3 Hub FSM Loop of Self-Improvement** - Phases 24-36 (shipped 2026-02-14)
- [x] **v1.4 Reliable Autonomy** - Phases 37-44 (shipped 2026-02-14)

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

<details>
<summary>v1.4 Reliable Autonomy (Phases 37-44) - SHIPPED 2026-02-14</summary>

| Phase | Name | What It Delivered |
|-------|------|-------------------|
| 37 | CI Fix | Merge conflict resolution, pushed local fixes, green CI builds |
| 38 | OllamaClient + Hub LLM Routing | Elixir HTTP client for Ollama /api/chat, hub FSM routes through local Ollama |
| 39 | Pipeline Reliability | Wake failure recovery, execution timeouts, stuck task detection, reconnect state recovery, wake_command gate |
| 40 | Sidecar Tool Infrastructure | 5-tool registry with sandbox (path validation, command blocking, structured observations) |
| 41 | Agentic Execution Loop | ReAct loop with 3-layer output parser, safety guardrails, adaptive limits, dashboard streaming |
| 42 | Agent Self-Management | pm2 self-awareness, hub-commanded graceful restart via WebSocket |
| 43 | Hub FSM Healing | 5th FSM state with HealthAggregator, automated remediation, watchdog timeout, audit log |
| 44 | Hub FSM Testing | 22 integration tests covering all 5 FSM states, healing cycles, HTTP endpoints |

~50 commits, ~60 files, ~+5,000 LOC across 1 day.

</details>

## Progress

| Milestone | Phases | Plans | Status | Completed |
|-----------|--------|-------|--------|-----------|
| v1.0 Core Architecture | 1-8 | 19 | Complete | 2026-02-11 |
| v1.1 Hardening | 9-16 | 32 | Complete | 2026-02-12 |
| v1.2 Smart Agent Pipeline | 17-23 | 25 | Complete | 2026-02-12 |
| v1.3 Hub FSM Loop | 24-36 | 35 | Complete | 2026-02-14 |
| v1.4 Reliable Autonomy | 37-44 | 18 | Complete | 2026-02-14 |

**Totals:** 44 phases, 129 plans across 5 milestones.
