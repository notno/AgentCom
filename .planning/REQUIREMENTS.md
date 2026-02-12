# Requirements: AgentCom v2

**Defined:** 2026-02-12
**Core Value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.

## v1.2 Requirements

Requirements for milestone v1.2 Smart Agent Pipeline. Each maps to roadmap phases.

### LLM Registry

- [ ] **REG-01**: Hub tracks Ollama instances across Tailscale mesh with host, port, and available models
- [ ] **REG-02**: Health checks poll each Ollama endpoint periodically and mark unreachable hosts as offline within one check cycle
- [ ] **REG-03**: Registry tracks which models are currently loaded (warm) vs only downloaded (cold) per host
- [ ] **REG-04**: Admin can register, update, and remove Ollama endpoints via HTTP API

### Host Resources

- [ ] **HOST-01**: Sidecar periodically reports CPU utilization (total and per-thread), RAM usage, and GPU utilization to the hub
- [ ] **HOST-02**: GPU VRAM usage is tracked per host via Ollama /api/ps response data
- [ ] **HOST-03**: Host resource metrics are visible on the dashboard per machine
- [x] **HOST-04**: Resource utilization data is available to the scheduler for routing decisions

### Task Enrichment

- [x] **TASK-01**: Tasks carry structured context (repo, branch, relevant files) as optional fields
- [x] **TASK-02**: Tasks carry success criteria (testable conditions for "done") as optional fields
- [x] **TASK-03**: Tasks carry verification steps (how to check completion) as optional fields
- [x] **TASK-04**: Tasks are classified into complexity tiers (trivial/standard/complex) with explicit submitter tags
- [x] **TASK-05**: A complexity heuristic engine infers tier from task content when submitter does not specify

### Model Routing

- [x] **ROUTE-01**: Scheduler routes trivial tasks to sidecar direct execution, standard tasks to Ollama-backed agents, and complex tasks to Claude-backed agents
- [x] **ROUTE-02**: When multiple Ollama hosts have the same model loaded, scheduler distributes by current load
- [x] **ROUTE-03**: If preferred model is unavailable, scheduler falls back to next tier in a configurable chain
- [x] **ROUTE-04**: Routing decisions are logged with model used, endpoint selected, and classification reason

### Sidecar Execution

- [ ] **EXEC-01**: Sidecar calls local Ollama instance via HTTP for standard-complexity tasks
- [ ] **EXEC-02**: Sidecar calls Claude API for complex tasks
- [ ] **EXEC-03**: Sidecar executes trivial tasks locally (git, file I/O, status) with zero LLM tokens
- [ ] **EXEC-04**: Each task result includes model used, tokens consumed, and estimated cost

### Verification

- [ ] **VERIFY-01**: Task results include a structured verification report with pass/fail per check
- [ ] **VERIFY-02**: Pre-built verification step types exist for common patterns (file_exists, test_passes, git_clean, command_succeeds)
- [ ] **VERIFY-03**: After completing work, agent runs verification steps and retries fixes if checks fail (build-verify-fix loop)
- [ ] **VERIFY-04**: Mechanical verification (compile, tests, file existence) runs before any LLM-based judgment

## Future Requirements

Deferred to future milestones. Tracked but not in current roadmap.

### Advanced Routing

- **AROUTE-01**: LLM-based complexity classifier trained on production routing data
- **AROUTE-02**: Dynamic model loading/unloading based on demand
- **AROUTE-03**: Cross-agent task dependencies (DAG scheduling)

### Advanced Verification

- **AVERIFY-01**: LLM-based semantic verification using different model than generation
- **AVERIFY-02**: Verification-aware prompting (task prompt includes verification expectations)

### Security

- **SEC-01**: Token encryption at rest (replace plaintext tokens.json)
- **SEC-02**: TLS for WebSocket connections beyond Tailscale mesh

### Advanced Observability

- **AOBS-01**: Prometheus metrics export
- **AOBS-02**: Grafana dashboards
- **AOBS-03**: Distributed tracing across hub and sidecar

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| LiteLLM/OpenAI gateway proxy | AgentCom routes tasks, not tokens. Hub is not an LLM proxy. |
| LLM-based complexity classifier | Burns tokens to save tokens (chicken-and-egg). Needs production data first. |
| Dynamic model loading/unloading | Operational complexity. Models should be pre-loaded by operator. |
| Streaming LLM output through hub | Adds latency for zero coordination value. Sidecar manages inference. |
| Token budget enforcement | Track spending first, enforce caps in future milestone. |
| Agent-to-agent delegation | Bypasses central scheduler. Agents submit to queue, not each other. |
| Automated PR review by local model | Local models not reliable enough for judgment-heavy code review. |
| Cross-agent task dependencies (DAG) | Much larger system. Tasks are independent units for now. |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| REG-01 | Phase 18 | Pending |
| REG-02 | Phase 18 | Pending |
| REG-03 | Phase 18 | Pending |
| REG-04 | Phase 18 | Pending |
| HOST-01 | Phase 18 | Pending |
| HOST-02 | Phase 18 | Pending |
| HOST-03 | Phase 18 | Pending |
| HOST-04 | Phase 19 | Pending |
| TASK-01 | Phase 17 | Complete |
| TASK-02 | Phase 17 | Complete |
| TASK-03 | Phase 17 | Complete |
| TASK-04 | Phase 17 | Complete |
| TASK-05 | Phase 17 | Complete |
| ROUTE-01 | Phase 19 | Pending |
| ROUTE-02 | Phase 19 | Pending |
| ROUTE-03 | Phase 19 | Pending |
| ROUTE-04 | Phase 19 | Pending |
| EXEC-01 | Phase 20 | Pending |
| EXEC-02 | Phase 20 | Pending |
| EXEC-03 | Phase 20 | Pending |
| EXEC-04 | Phase 20 | Pending |
| VERIFY-01 | Phase 21 | Pending |
| VERIFY-02 | Phase 21 | Pending |
| VERIFY-03 | Phase 22 | Pending |
| VERIFY-04 | Phase 21 | Pending |

**Coverage:**
- v1.2 requirements: 25 total
- Mapped to phases: 25
- Unmapped: 0

---
*Requirements defined: 2026-02-12*
*Last updated: 2026-02-12 after roadmap creation*
