# Milestones

## v1.0 — Core v2 Architecture (Complete)

**Completed:** 2026-02-11
**Phases:** 1-8 (19 plans, 1.2 hours total)
**Last phase number:** 8

### What Shipped

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

### Key Accomplishments

- Always-on sidecar relay with persistent WebSocket, crash recovery, OpenClaw wake trigger, and pm2 management
- DETS-backed task queue with priority lanes, retry semantics, generation fencing, dead-letter storage, and overdue sweep
- Per-agent FSM tracking work lifecycle with 60s acceptance timeout and automatic task reclamation on disconnect
- Event-driven scheduler matching tasks to idle agents by capability with PubSub reactivity and stuck sweep
- Real-time command center dashboard with WebSocket-driven updates, web push notifications, and system health heuristics
- One-command agent onboarding with Culture ship names, 7-step provisioning, resume capability, and full lifecycle CLIs

### Stats

- 48 commits, 65 files changed, +12,858 / -119 lines
- Timeline: 2 days (2026-02-09 to 2026-02-11)
- Git range: 107f592a..a529eed

### Deferred

- PR review gatekeeper role (needs production data to calibrate)

---


## v1.1 — Hardening (Complete)

**Completed:** 2026-02-12
**Phases:** 9-16 (32 plans, 2.6 hours total)
**Last phase number:** 16

### What Shipped

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

### Key Accomplishments

- Comprehensive test infrastructure with DETS path isolation, test factories, and GitHub Actions CI
- DETS data resilience: automated backups, scheduled compaction, corruption recovery with degraded mode
- Input validation at all 27 entry points with schema-as-data, violation tracking, and escalating enforcement
- Structured JSON logging with 22 telemetry events, file rotation, token redaction, and sidecar parity
- Real-time metrics aggregation with configurable alerting, cooldowns, and dashboard integration (uPlot charts)
- Token bucket rate limiting with per-action granularity, progressive backoff, and admin override API
- Operations documentation: setup, monitoring, troubleshooting guides with Mermaid architecture diagrams

### Stats

- 153 commits, 195 files changed, +35,732 / -1,317 lines
- Elixir codebase: 18,509 LOC
- Timeline: 4 days (2026-02-08 to 2026-02-12)
- Git range: 4701ebc..299e701

### Deferred

- Elixir version bump (1.14 to 1.17+) for :gen_statem logger fix
- Sidecar queue.json atomicity (fs.writeFileSync partial-write-on-crash risk)
- VAPID keys ephemeral (push subscriptions lost on hub restart)
- Analytics and Threads modules orphaned (not exposed via API)

---

