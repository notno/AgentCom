# Roadmap: AgentCom v2

## Milestones

- [x] **v1.0 Core Architecture** - Phases 1-8 (shipped 2026-02-11)
- [x] **v1.1 Hardening** - Phases 9-16 (shipped 2026-02-12)

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

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-8 | v1.0 | 19/19 | Complete | 2026-02-11 |
| 9-16 | v1.1 | 32/32 | Complete | 2026-02-12 |
