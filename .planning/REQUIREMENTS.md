# Requirements: AgentCom v2

**Defined:** 2026-02-11
**Core Value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.

## v1.1 Requirements

Requirements for milestone v1.1 Hardening. Each maps to roadmap phases.

### Testing

- [ ] **TEST-01**: All GenServer modules have unit tests covering init, key call/cast handlers, and edge cases
- [ ] **TEST-02**: Test infrastructure supports DETS isolation (per-test temp tables, no global state bleed)
- [ ] **TEST-03**: Integration tests validate the full task lifecycle: submit → schedule → assign → accept → complete
- [ ] **TEST-04**: Integration tests validate failure paths: task timeout, agent crash, retry, dead-letter
- [ ] **TEST-05**: Sidecar Node.js tests cover WebSocket relay, queue management, wake trigger, and git workflow
- [ ] **TEST-06**: Test helpers and factories exist for creating agents, tasks, and WebSocket connections

### Input Validation

- [ ] **VALID-01**: All WebSocket message types are validated against expected schemas before processing
- [ ] **VALID-02**: All HTTP API endpoints validate request bodies and parameters before processing
- [ ] **VALID-03**: Malformed payloads return structured error responses without crashing GenServers
- [ ] **VALID-04**: A central Validation module provides reusable validation functions across handlers

### DETS Resilience

- [x] **DETS-01**: Periodic automated backup of all DETS tables to a configurable backup directory
- [x] **DETS-02**: Manual backup trigger available via API endpoint
- [x] **DETS-03**: DETS compaction/defragmentation runs on a configurable schedule
- [x] **DETS-04**: Health monitoring endpoint exposes table sizes, fragmentation level, and last backup time
- [x] **DETS-05**: Corruption recovery procedure documented and tested

### Observability

- [ ] **OBS-01**: Structured JSON logging with consistent metadata (task_id, agent_id, module) across all GenServers
- [ ] **OBS-02**: Telemetry events emitted for key lifecycle points (task submit, assign, complete, fail, agent connect/disconnect)
- [x] **OBS-03**: Metrics endpoint (/api/metrics) exposes queue depth, task latency, agent utilization, error rates
- [x] **OBS-04**: Configurable alerter triggers notifications (PubSub + dashboard) for anomalies (queue growth, failure rate, stuck tasks)
- [x] **OBS-05**: Alert thresholds configurable via Config without restart

### Rate Limiting

- [ ] **RATE-01**: WebSocket connections are rate-limited per agent with token bucket algorithm
- [ ] **RATE-02**: HTTP API endpoints are rate-limited per agent/IP
- [ ] **RATE-03**: Different rate limits apply per action type (messages, task submissions, channel operations)
- [ ] **RATE-04**: Rate limit violations return structured error responses with retry-after information

### Operations

- [ ] **OPS-01**: Operations guide documents hub setup, configuration, and startup procedures
- [ ] **OPS-02**: Operations guide documents monitoring, dashboard usage, and interpreting metrics
- [ ] **OPS-03**: Operations guide documents troubleshooting common issues and recovery procedures

## Future Requirements

Deferred to future milestones. Tracked but not in current roadmap.

### Security

- **SEC-01**: Token encryption at rest (replace plaintext tokens.json)
- **SEC-02**: TLS for WebSocket connections beyond Tailscale mesh

### Advanced Testing

- **ATEST-01**: Property-based testing for scheduling algorithms
- **ATEST-02**: Chaos engineering (fault injection in GenServer supervision tree)
- **ATEST-03**: Load testing framework for concurrent agent simulation

### Advanced Observability

- **AOBS-01**: Prometheus metrics export
- **AOBS-02**: Grafana dashboards
- **AOBS-03**: Distributed tracing across hub and sidecar

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Database migration (DETS to SQLite/Postgres) | DETS works at current scale. Migration rewrites 6 GenServers. |
| Full Prometheus/Grafana stack | Overkill for 5-agent system. Adds external infrastructure dependency. |
| Property-based testing (StreamData) | Diminishing returns at current system size. Standard ExUnit sufficient. |
| Ecto for validation | Massive dependency for flat JSON validation. No database, no forms. |
| Load testing framework | 5 agents. Load testing infra costs more than the insight. |
| Chaos engineering | System has zero tests. Build test suite first. |
| Distributed rate limiting (Redis/Mnesia) | Single BEAM node. External backend adds complexity for zero benefit. |
| Admin API for rate limit configuration | Hardcoded per-action defaults are sufficient for v1.1. |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| TEST-01 | Phase 9 | Pending |
| TEST-02 | Phase 9 | Pending |
| TEST-03 | Phase 9 | Pending |
| TEST-04 | Phase 9 | Pending |
| TEST-05 | Phase 9 | Pending |
| TEST-06 | Phase 9 | Pending |
| VALID-01 | Phase 12 | Pending |
| VALID-02 | Phase 12 | Pending |
| VALID-03 | Phase 12 | Pending |
| VALID-04 | Phase 12 | Pending |
| DETS-01 | Phase 10 | Complete |
| DETS-02 | Phase 10 | Complete |
| DETS-03 | Phase 11 | Pending |
| DETS-04 | Phase 10 | Complete |
| DETS-05 | Phase 11 | Pending |
| OBS-01 | Phase 13 | Pending |
| OBS-02 | Phase 13 | Pending |
| OBS-03 | Phase 14 | Complete |
| OBS-04 | Phase 14 | Complete |
| OBS-05 | Phase 14 | Complete |
| RATE-01 | Phase 15 | Pending |
| RATE-02 | Phase 15 | Pending |
| RATE-03 | Phase 15 | Pending |
| RATE-04 | Phase 15 | Pending |
| OPS-01 | Phase 16 | Pending |
| OPS-02 | Phase 16 | Pending |
| OPS-03 | Phase 16 | Pending |

**Coverage:**
- v1.1 requirements: 24 total
- Mapped to phases: 24
- Unmapped: 0

---
*Requirements defined: 2026-02-11*
*Last updated: 2026-02-11 after roadmap creation*
