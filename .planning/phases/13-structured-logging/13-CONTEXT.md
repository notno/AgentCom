# Phase 13: Structured Logging + Telemetry - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Convert all system log output (Elixir hub and Node.js sidecar) to structured JSON with consistent metadata fields, and emit telemetry events for key lifecycle points. This phase delivers the logging and telemetry infrastructure that Phase 14 (Metrics + Alerting) will aggregate and monitor.

</domain>

<decisions>
## Implementation Decisions

### Log format & fields
- Full trace metadata in every log entry: timestamp, level, module, message, pid, node, function name, line number
- Context fields included when available: task_id, agent_id, request_id
- 5-level system: debug (internal state), info (lifecycle events), notice (operational completions like backups/compaction), warning (recoverable issues), error (failures requiring attention)
- Redact auth tokens/secrets in log output; task content and agent names are allowed

### Telemetry event design
- Erlang/OTP naming convention: `[:agent_com, :task, :submit]` style atom lists
- Full state machine granularity: every FSM state transition emits an event (idle->assigned, assigned->working, working->blocked, etc.)
- Events carry measurements with timing: duration_ms for operations, queue_depth for submissions, retry_count for failures -- enables Phase 14 metrics aggregation
- DETS operations included: backup:start/complete/fail, compaction:start/complete, restore:start/complete

### Migration approach
- Big bang migration: replace all Logger calls across all modules in one phase -- clean cutover, no mixed formats
- Both Elixir hub and Node.js sidecar get structured JSON logging with same field conventions for unified log parsing
- Tests assert log output is valid JSON with required fields (per-module assertion tests, not just smoke)

### Output & consumption
- Dual output: stdout for real-time monitoring + rotating log files for historical analysis
- Log level configurable both via config.exs (default) and runtime API endpoint (PUT /api/admin/log-level) -- API override resets on restart

### Claude's Discretion
- Nested operation correlation strategy (flat correlation IDs vs span-style parent/child)
- Whether to use a shared AgentCom.Log helper module or Logger.metadata per-process
- File rotation strategy (size-based vs time-based, retention count)
- Whether telemetry events should feed into the dashboard in real-time now or wait for Phase 14

</decisions>

<specifics>
## Specific Ideas

No specific requirements -- open to standard approaches. Key constraint: log output must be parseable by standard JSON tools (jq, log aggregators) without custom parsing per success criteria.

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope.

</deferred>

---

*Phase: 13-structured-logging*
*Context gathered: 2026-02-12*
