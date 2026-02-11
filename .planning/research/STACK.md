# Technology Stack: Hardening Features

**Project:** AgentCom v2 Hardening
**Researched:** 2026-02-11

## Recommended Stack

### Core Framework
| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| LoggerJSON | ~> 7.0 | Structured JSON log output | Standard Elixir lib for machine-parseable logs. Supports Basic, Google Cloud, Datadog, Elastic formatters. Uses Jason encoder already in project. v7.0.4 current. |
| Telemetry.Metrics | ~> 1.0 | Metric definitions for telemetry events | Official BEAM telemetry project. Already a transitive dep via Bandit. Formalizes metric types (counter, sum, last_value, summary, distribution). v1.1.0 current. |

### Custom Implementations (No Dependency)

| Component | Approach | Lines (est.) | Why Custom |
|-----------|----------|-------------|------------|
| RateLimiter | ETS token bucket with atomic counters | ~60 | Single-node, concurrent, no serialization. Faster and simpler than any library. |
| Validation | Pattern matching + guards | ~150 | Flat JSON schemas. No nested forms. Elixir built-ins are the right fit. |
| DetsManager | GenServer coordinating backup/compaction | ~200 | Unique to this system's DETS topology. No off-the-shelf solution. |
| Alerter | GenServer with threshold checks | ~100 | Simple threshold monitoring via PubSub. |
| TelemetryHandler | Module attaching to telemetry events | ~80 | Thin handler. ConsoleReporter too basic; custom is ~30 lines more. |

### Already Present (No Change)

| Technology | Version | Role in Hardening |
|------------|---------|-------------------|
| :telemetry | 1.3.0 | Already a dep via Bandit. Emit events with `:telemetry.execute/3`. |
| Jason | 1.4.4 | Used by LoggerJSON as JSON encoder. No version change. |
| ExUnit | built-in | Test framework. Already available, just no tests written yet. |
| :dets (Erlang stdlib) | OTP | Backup/compaction uses native `:dets.open_file(repair: :force)`. |
| :ets (Erlang stdlib) | OTP | Rate limiter uses native ETS with concurrent read/write options. |

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Rate limiting | Custom ETS bucket | Hammer ~> 7.0 | Hammer's value is pluggable backends (Redis, Mnesia) for distributed rate limiting. AgentCom is single-node. Custom ETS bucket is 40 lines, zero deps, concurrent. |
| Rate limiting | Custom ETS bucket | ExRated ~> 2.1 | Serializes all checks through a GenServer. Architecturally wrong for growth. |
| Input validation | Pattern matching | Ecto ~> 3.12 standalone | Massive dependency for flat JSON validation. No database, no forms, no nested schemas. |
| Input validation | Pattern matching | NimbleOptions ~> 1.x | Designed for library option validation, not incoming JSON payloads. |
| Metrics reporter | Custom TelemetryHandler | TelemetryMetricsPrometheus ~> 1.1 | Adds Prometheus /metrics endpoint on separate port. Overkill for 5-agent system. Add later if Grafana is desired. |
| Testing mock | start_supervised! + real GenServers | Mox ~> 1.2 | Mox requires defining behaviours for all mockable modules. Codebase has no behaviours. Testing real GenServers is more valuable and requires no new architecture. |

## Installation

```bash
# New dependencies (only 2)
# Add to mix.exs deps:
#   {:logger_json, "~> 7.0"},
#   {:telemetry_metrics, "~> 1.0"}

mix deps.get
```

## Configuration Changes

```elixir
# config/config.exs -- structured logging for production
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic, metadata: :all}

# config/dev.exs (NEW) -- human-readable for development
import Config
config :logger, :console,
  format: "$time [$level] $metadata $message\n",
  metadata: [:agent_id, :task_id, :request_id]

# config/test.exs (NEW) -- minimal logging in tests
import Config
config :logger, level: :warning
config :agent_com,
  mailbox_path: "tmp/test/mailbox.dets",
  message_history_path: "tmp/test/message_history.dets",
  channels_path: "tmp/test/channels.dets",
  task_queue_path: "tmp/test/"
```

## mix.exs Changes

```elixir
defp deps do
  [
    # ... existing deps ...
    {:logger_json, "~> 7.0"},
    {:telemetry_metrics, "~> 1.0"}
  ]
end

# Add for test support modules:
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

## Sources

- [LoggerJSON v7.0.4 on Hex](https://hex.pm/packages/logger_json) -- download stats, version history (HIGH confidence)
- [LoggerJSON documentation](https://hexdocs.pm/logger_json/readme.html) -- configuration, formatter options (HIGH confidence)
- [Telemetry.Metrics v1.1.0](https://hexdocs.pm/telemetry_metrics/Telemetry.Metrics.html) -- metric type definitions (HIGH confidence)
- [Hammer on GitHub](https://github.com/ExHammer/hammer) -- evaluated for rate limiting (MEDIUM confidence)
- [ExRated on Hex](https://hexdocs.pm/ex_rated/ExRated.html) -- evaluated for rate limiting (MEDIUM confidence)
- [Validating Data in Elixir](https://blog.appsignal.com/2023/11/07/validating-data-in-elixir-using-ecto-and-nimbleoptions.html) -- Ecto vs NimbleOptions comparison (MEDIUM confidence)
