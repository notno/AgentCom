# Feature Landscape: AgentCom Hardening

**Domain:** System hardening for Elixir/BEAM agent coordination
**Researched:** 2026-02-11

## Table Stakes

Features that must exist for a production-quality system. Missing = system is fragile.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Unit + integration tests | Zero test coverage blocks confident changes. 22 GenServers, zero tests. | Medium | ExUnit already available. Need test helpers, factories, DETS isolation. |
| Input validation on all entry points | Malformed payloads can crash GenServers or enable DoS. 9 entry points with minimal validation. | Low | Pattern matching + guards. Central Validation module. |
| DETS backup strategy | Single copy of all persistent data (9 tables), no recovery plan. | Medium | Periodic file copy + manual trigger. Two path roots to manage. |
| Rate limiting on WS + HTTP | Any agent with valid token can spam the system. Security audit flagged this. | Low | ETS token bucket. ~60 lines of code. |
| Structured logging with metadata | Current logs are unstructured strings, unusable for debugging. | Low | LoggerJSON + Logger.metadata. Config change + metadata calls. |

## Differentiators

Features that go beyond minimum viable hardening. Not expected, but valued.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| DETS compaction (defragmentation) | Prevents disk waste and query slowdown on long-running hubs | Medium | Requires coordination with owning GenServers. Erlang's `repair: :force` does the heavy lifting. |
| Telemetry events + metrics | Enables performance analysis, scheduling efficiency tracking, capacity planning | Medium | ~12 event types. TelemetryHandler to log/aggregate. Foundation for future Prometheus. |
| Alerter with configurable thresholds | Proactive notification of system health issues | Medium | GenServer with periodic checks. Broadcasts to PubSub for dashboard. |
| DETS health monitoring endpoint | Admin visibility into table sizes, fragmentation, last backup time | Low | Read-only endpoint calling :dets.info/1 on registered tables. |
| Per-action rate limit granularity | Different limits for messages vs task submissions vs channel creates | Low | RateLimiter already keyed by {agent_id, action}. Just configure thresholds. |
| Configurable rate limits via admin API | Tune limits without code change or restart | Low | Store limits in Config (DETS-backed). |

## Anti-Features

Features to explicitly NOT build in this milestone.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Database migration (DETS to SQLite/Postgres) | DETS works at current scale. Migration rewrites 6 GenServers. | Harden DETS: backup, compact, monitor. |
| Distributed rate limiting (Redis/Mnesia) | Single BEAM node. External backend is operational complexity for zero benefit. | Custom ETS bucket. Revisit if multi-hub happens. |
| Full observability stack (Prometheus/Grafana) | Overkill for 5-agent system. Adds external infrastructure. | Telemetry events + LoggerJSON + Alerter. Export to Prometheus later if needed. |
| Property-based testing (StreamData) | Diminishing returns for this system size. | Standard ExUnit tests. Add StreamData for specific edge-case modules later. |
| Ecto for validation | Massive dependency for flat JSON validation. No database, no forms. | Elixir pattern matching + guards in a Validation module. |
| Load testing framework | 5 agents. Load testing infra costs more than the insight. | Existing smoke tests with 2 simulated agents. |
| Chaos engineering | System has zero tests. Chaos on untested system produces noise. | Build test suite first. Add targeted failure tests. |

## Feature Dependencies

```
Testing Infrastructure --> (enables all other features)
  |
  +--> Input Validation (no deps)
  |
  +--> Structured Logging (no deps)
  |      |
  |      +--> Telemetry Events (benefits from logging)
  |             |
  |             +--> Alerter (uses telemetry counters + PubSub)
  |
  +--> Rate Limiting (benefits from validation being in place)
  |
  +--> DETS Manager (benefits from logging + testing)
        |
        +--> DETS Backup (subset of DetsManager)
        +--> DETS Compaction (subset of DetsManager)
        +--> DETS Health Monitoring (subset of DetsManager)
```

## MVP Recommendation

Prioritize:
1. **Testing infrastructure** (ExUnit setup, helpers, factories) -- unblocks everything
2. **Input validation** on all 9 entry points -- immediate safety improvement
3. **DETS backup** (without compaction) -- protect existing data
4. **Rate limiting** on WebSocket and unauthenticated endpoints -- security floor
5. **Structured logging** -- switch to LoggerJSON, add metadata to key paths

Defer:
- **DETS compaction**: Not urgent at current table sizes. Add after backup is working.
- **Alerter**: Dashboard already shows system state. Alerter adds proactive monitoring.
- **Telemetry events**: Foundational but not urgent. Can be sprinkled incrementally.
- **Admin API for rate limits**: Hardcoded defaults are fine initially.

## Sources

- AgentCom CONCERNS.md -- identified all gaps being addressed (HIGH confidence)
- AgentCom codebase -- all entry points analyzed for validation gaps (HIGH confidence)
- [Erlang DETS docs](https://www.erlang.org/doc/apps/stdlib/dets.html) -- DETS limitations and maintenance (HIGH confidence)
- [LoggerJSON](https://hexdocs.pm/logger_json/readme.html) -- structured logging capabilities (HIGH confidence)
- [Telemetry](https://github.com/beam-telemetry/telemetry) -- event dispatching patterns (HIGH confidence)
