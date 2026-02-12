# Roadmap: AgentCom v2

## Milestones

- [x] **v1.0 Core Architecture** - Phases 1-8 (shipped 2026-02-11)
- [ ] **v1.1 Hardening** - Phases 9-16 (in progress)

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

### v1.1 Hardening

**Milestone Goal:** Shore up the v1.0 foundation with comprehensive tests, data resilience, security hardening, and operational visibility.

**Phase Numbering:**
- Integer phases (9-16): Planned milestone work
- Decimal phases (e.g., 10.1): Urgent insertions (marked with INSERTED)

- [x] **Phase 9: Testing Infrastructure** - Test isolation, helpers, factories, and comprehensive test coverage for all GenServers and pipelines
- [x] **Phase 10: DETS Backup + Monitoring** - Automated backup, manual trigger, and health monitoring for all DETS tables
- [x] **Phase 11: DETS Compaction + Recovery** - Scheduled compaction/defragmentation and documented corruption recovery
- [x] **Phase 12: Input Validation** - Schema validation at all WebSocket and HTTP entry points with structured error responses
- [ ] **Phase 13: Structured Logging + Telemetry** - JSON logging with consistent metadata and telemetry events for key lifecycle points
- [ ] **Phase 14: Metrics + Alerting** - Metrics endpoint and configurable alerter for system anomalies
- [ ] **Phase 15: Rate Limiting** - Token bucket rate limiting on WebSocket and HTTP with per-action granularity
- [ ] **Phase 16: Operations Documentation** - Setup, monitoring, and troubleshooting guides

## Phase Details

### Phase 9: Testing Infrastructure
**Goal**: Developers can confidently change any module knowing tests catch regressions
**Depends on**: Nothing (first phase of v1.1; unblocks all subsequent phases)
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04, TEST-05, TEST-06
**Success Criteria** (what must be TRUE):
  1. Running `mix test` executes unit tests for every GenServer module, covering init, key call/cast handlers, and edge cases
  2. Each test runs with its own isolated DETS tables -- no state bleeds between tests, no risk of corrupting production data
  3. An integration test submits a task and observes it flow through the full lifecycle: submit, schedule, assign, accept, complete
  4. An integration test triggers failure paths (timeout, crash, retry) and observes tasks reach dead-letter correctly
  5. Sidecar Node.js tests validate WebSocket relay, queue management, wake trigger, and git workflow functions
**Plans**: 7 plans

Plans:
- [ ] 09-01-PLAN.md -- Test infrastructure foundation (DETS refactoring, config/test.exs, helpers, factory, WS client)
- [ ] 09-02-PLAN.md -- Critical GenServer unit tests (TaskQueue, AgentFSM, Scheduler)
- [ ] 09-03-PLAN.md -- Auth deep tests + remaining GenServer unit tests
- [ ] 09-04-PLAN.md -- Integration tests (task lifecycle, failure paths, WebSocket E2E)
- [ ] 09-05-PLAN.md -- Sidecar module extraction + Node.js unit tests
- [ ] 09-06-PLAN.md -- GitHub Actions CI workflow
- [ ] 09-07-PLAN.md -- Gap closure: tag smoke tests with @moduletag :smoke for default exclusion

### Phase 10: DETS Backup + Monitoring
**Goal**: All DETS data is protected by automated backups with health visibility
**Depends on**: Phase 9 (tests validate backup correctness)
**Requirements**: DETS-01, DETS-02, DETS-04
**Success Criteria** (what must be TRUE):
  1. DETS tables are automatically backed up to a configurable directory on a periodic schedule without manual intervention
  2. An admin can trigger an immediate backup of all tables via a single API call
  3. A health endpoint returns current table sizes, fragmentation level, and the timestamp of the last successful backup
**Plans**: 3 plans

Plans:
- [x] 10-01-PLAN.md -- DetsBackup GenServer (core backup + health logic, config, supervision tree)
- [x] 10-02-PLAN.md -- API endpoints + dashboard integration (manual backup trigger, health endpoint, DETS health card)
- [x] 10-03-PLAN.md -- Gap closure: normalize tagged tuples in health_metrics to fix DashboardSocket Jason crash

### Phase 11: DETS Compaction + Recovery
**Goal**: DETS tables stay performant through compaction and can recover from corruption
**Depends on**: Phase 10 (backup must exist before compaction risks data)
**Requirements**: DETS-03, DETS-05
**Success Criteria** (what must be TRUE):
  1. DETS compaction/defragmentation runs on a configurable schedule without blocking normal operations for more than 1 second per table
  2. A documented and tested recovery procedure restores DETS tables from backup after corruption, with verified data integrity
**Plans**: 3 plans

Plans:
- [x] 11-01-PLAN.md -- Compaction core (handle_calls in all DETS-owning GenServers + DetsBackup orchestration/scheduling)
- [x] 11-02-PLAN.md -- Recovery core (restore from backup, integrity verification, corruption detection, degraded mode)
- [x] 11-03-PLAN.md -- API endpoints + dashboard integration (manual compact/restore, compaction history, push notifications)

### Phase 12: Input Validation
**Goal**: All external input is validated before reaching GenServers, preventing crashes and malformed state
**Depends on**: Phase 9 (tests validate that validation logic is correct and does not break existing agents)
**Requirements**: VALID-01, VALID-02, VALID-03, VALID-04
**Success Criteria** (what must be TRUE):
  1. Every WebSocket message type is checked against its expected schema before dispatch to handlers
  2. Every HTTP API endpoint validates request bodies and parameters before processing
  3. Sending a malformed payload returns a structured error response with field-level details -- no GenServer crashes
  4. All validation logic lives in a single reusable Validation module called by both WebSocket and HTTP handlers
**Plans**: 3 plans

Plans:
- [x] 12-01-PLAN.md -- Core validation module, schemas, and violation tracker infrastructure
- [x] 12-02-PLAN.md -- WebSocket and HTTP handler integration with schema discovery endpoint
- [x] 12-03-PLAN.md -- Dashboard validation visibility and comprehensive test suite

### Phase 13: Structured Logging + Telemetry
**Goal**: Every significant system event is logged in a machine-parseable format with consistent metadata
**Depends on**: Phase 10 (DETS backup exists before increasing write volume from logging)
**Requirements**: OBS-01, OBS-02
**Success Criteria** (what must be TRUE):
  1. All GenServer log output is structured JSON with consistent metadata fields (task_id, agent_id, module) attached automatically
  2. Telemetry events fire for key lifecycle points: task submit, assign, complete, fail, and agent connect/disconnect
  3. Log output is parseable by standard JSON tools (jq, log aggregators) without custom parsing
**Plans**: TBD

Plans:
- [ ] 13-01: TBD

### Phase 14: Metrics + Alerting
**Goal**: Operators can see system health at a glance and get notified of anomalies before they become outages
**Depends on**: Phase 13 (telemetry events must exist for metrics to aggregate and alerter to monitor)
**Requirements**: OBS-03, OBS-04, OBS-05
**Success Criteria** (what must be TRUE):
  1. A GET /api/metrics endpoint returns current queue depth, task latency percentiles, agent utilization, and error rates
  2. When a monitored threshold is exceeded (queue growth, failure rate, stuck tasks), an alert broadcasts to the dashboard within 60 seconds
  3. Alert thresholds can be changed via the Config store without restarting the hub, and changes take effect on the next check cycle
**Plans**: TBD

Plans:
- [ ] 14-01: TBD

### Phase 15: Rate Limiting
**Goal**: Misbehaving or compromised agents cannot flood the system with messages or requests
**Depends on**: Phase 12 (validation classifies message types, which rate limiting uses to apply per-action limits)
**Requirements**: RATE-01, RATE-02, RATE-03, RATE-04
**Success Criteria** (what must be TRUE):
  1. A WebSocket-connected agent that exceeds its message rate gets throttled per token bucket limits without affecting other agents
  2. HTTP API requests from an agent or IP that exceed rate limits receive 429 responses
  3. Different rate limits apply to different action types (messages, task submissions, channel operations) and each is enforced independently
  4. Rate limit violation responses include a structured error with retry_after_ms so agents can back off intelligently
**Plans**: TBD

Plans:
- [ ] 15-01: TBD

### Phase 16: Operations Documentation
**Goal**: A new operator can set up, monitor, and troubleshoot the system without reading source code
**Depends on**: Phases 13-14 (documentation references metrics, logging, and alerting features that must exist first)
**Requirements**: OPS-01, OPS-02, OPS-03
**Success Criteria** (what must be TRUE):
  1. An operations guide documents hub setup from scratch: configuration, dependencies, startup procedures, and verification steps
  2. The guide documents how to use the dashboard, interpret metrics, read structured logs, and respond to alerts
  3. The guide documents troubleshooting procedures for common failure modes (DETS corruption, agent disconnects, queue backlog, stuck tasks) with step-by-step recovery actions
**Plans**: TBD

Plans:
- [ ] 16-01: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 9 -> 10 -> 11 -> 12 -> 13 -> 14 -> 15 -> 16
(Phases 12 and 13 can execute in parallel after Phase 10 if desired.)

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 9. Testing Infrastructure | v1.1 | 7/7 | Complete | 2026-02-11 |
| 10. DETS Backup + Monitoring | v1.1 | 3/3 | Complete | 2026-02-12 |
| 11. DETS Compaction + Recovery | v1.1 | 3/3 | Complete | 2026-02-12 |
| 12. Input Validation | v1.1 | 3/3 | Complete | 2026-02-12 |
| 13. Structured Logging + Telemetry | v1.1 | 0/TBD | Not started | - |
| 14. Metrics + Alerting | v1.1 | 0/TBD | Not started | - |
| 15. Rate Limiting | v1.1 | 0/TBD | Not started | - |
| 16. Operations Documentation | v1.1 | 0/TBD | Not started | - |
