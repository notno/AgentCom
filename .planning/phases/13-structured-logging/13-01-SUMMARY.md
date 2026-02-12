---
phase: 13-structured-logging
plan: 01
subsystem: infra
tags: [logger_json, telemetry, json-logging, structured-logging, otp-handlers]

# Dependency graph
requires:
  - phase: 12-input-validation
    provides: "Working application with standard Logger output"
provides:
  - "LoggerJSON 7.x structured JSON log output on stdout and rotating file"
  - "Token/secret redaction in all log output"
  - "AgentCom.Telemetry module with 22-event catalog and logging handler"
  - "Telemetry handler attachment in Application.start/2"
affects: [13-02, 13-03, 13-04, 14-metrics]

# Tech tracking
tech-stack:
  added: [logger_json 7.0.4]
  patterns: [tuple-format-config, programmatic-otp-handler, telemetry-module-function-capture]

key-files:
  created:
    - lib/agent_com/telemetry.ex
  modified:
    - mix.exs
    - mix.lock
    - config/config.exs
    - config/dev.exs
    - config/prod.exs
    - lib/agent_com/application.ex
    - .gitignore

key-decisions:
  - "Tuple config format {Module, opts} in config.exs because Module.new/1 unavailable at config eval time"
  - "File handler added programmatically in Application.start (Config.config/2 requires keyword lists, OTP handler tuples are not keyword lists)"
  - "RedactKeys takes plain list of key strings, not keyword list"

patterns-established:
  - "Tuple format for LoggerJSON config in config.exs: {LoggerJSON.Formatters.Basic, opts}"
  - "Programmatic OTP handler setup via :logger.add_handler in Application.start/2"
  - "Telemetry handler attachment as first call in Application.start/2"
  - "try/rescue in telemetry handle_event/4 to prevent handler detachment"

# Metrics
duration: 8min
completed: 2026-02-12
---

# Phase 13 Plan 01: Logging Infrastructure Summary

**LoggerJSON 7.x with dual JSON output (stdout + rotating file), token redaction, and 22-event telemetry catalog with crash-safe logging handler**

## Performance

- **Duration:** 8 min
- **Started:** 2026-02-12T09:58:12Z
- **Completed:** 2026-02-12T10:06:36Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments
- All Logger output is now valid JSON with full trace metadata (mfa, line, timestamp, severity, pid, node)
- Dual output: stdout JSON for real-time monitoring + rotating file at priv/logs/agent_com.log (10MB, 5 files)
- Auth tokens (token, auth_token, secret) are automatically redacted to "[REDACTED]" in all log output
- AgentCom.Telemetry module defines complete 22-event catalog across 5 domains with crash-safe logging handler
- Telemetry handlers attach before any child process starts in Application.start/2

## Task Commits

Each task was committed atomically:

1. **Task 1: Add LoggerJSON dependency and configure dual-output JSON logging** - `a9d5d77` (feat)
2. **Task 2: Create AgentCom.Telemetry module and wire into Application.start** - `9be958d` (feat)

## Files Created/Modified
- `lib/agent_com/telemetry.ex` - Telemetry event catalog (22 events), attach_handlers/0, handle_event/4 with crash safety
- `mix.exs` - Added {:logger_json, "~> 7.0"} dependency
- `mix.lock` - Updated with logger_json 7.0.4
- `config/config.exs` - Replaced old :console backend with LoggerJSON :default_handler formatter + redactors
- `config/dev.exs` - Added comment noting JSON logging is active in dev
- `config/prod.exs` - Set production log level to :info
- `lib/agent_com/application.ex` - Added Telemetry.attach_handlers() and setup_file_log_handler() in start/2
- `.gitignore` - Added priv/logs/*.log* exclusion

## Decisions Made
- Used tuple config format `{LoggerJSON.Formatters.Basic, opts}` in config.exs because `Module.new/1` is unavailable at config evaluation time (deps not yet compiled). This is documented in LoggerJSON.Formatter module docs.
- Added file handler programmatically via `:logger.add_handler/3` in Application.start/2 because Elixir's `Config.config/2` only accepts keyword lists, and OTP handler config uses `{:handler, name, module, config}` tuples.
- RedactKeys redactor takes a plain list `["token", "auth_token", "secret"]` not a keyword list `keys: [...]`. The `redact/3` callback receives the list as-is for `key in keys` matching.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Config.exs cannot call LoggerJSON.Formatters.Basic.new/1**
- **Found during:** Task 1 (LoggerJSON configuration)
- **Issue:** Plan specified `LoggerJSON.Formatters.Basic.new(...)` in config.exs, but config.exs is evaluated before deps are compiled, so the module is not available
- **Fix:** Used tuple format `{LoggerJSON.Formatters.Basic, opts}` as documented in LoggerJSON.Formatter module docs
- **Files modified:** config/config.exs
- **Verification:** mix compile succeeds, JSON output verified
- **Committed in:** a9d5d77

**2. [Rule 3 - Blocking] Config.config/2 rejects OTP handler tuple lists**
- **Found during:** Task 1 (file handler configuration)
- **Issue:** Plan specified `config :logger, [{:handler, :file_handler, ...}]` but Config.config/2 requires keyword lists, not arbitrary tuple lists
- **Fix:** Moved file handler setup to Application.start/2 using `:logger.add_handler/3` programmatic API
- **Files modified:** lib/agent_com/application.ex
- **Verification:** priv/logs/agent_com.log created with JSON content
- **Committed in:** a9d5d77

**3. [Rule 1 - Bug] RedactKeys config format incorrect**
- **Found during:** Task 1 (redaction verification)
- **Issue:** Plan used `{LoggerJSON.Redactors.RedactKeys, keys: ["token", ...]}` (keyword list). RedactKeys.redact/3 expects a plain list as opts, doing `key in keys` matching
- **Fix:** Changed to `{LoggerJSON.Redactors.RedactKeys, ["token", "auth_token", "secret"]}`
- **Files modified:** config/config.exs
- **Verification:** Logger output shows "[REDACTED]" for token and auth_token fields
- **Committed in:** a9d5d77

---

**Total deviations:** 3 auto-fixed (1 bug, 2 blocking)
**Impact on plan:** All auto-fixes required to make LoggerJSON work correctly in Elixir config system. No scope creep.

## Issues Encountered
- Port 4000 already in use during manual verification (another app instance running) -- used alternate ports for testing. Not a code issue.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- LoggerJSON and telemetry infrastructure is ready for Plan 02 (module-by-module Logger migration)
- All 22 telemetry events are defined and handlers attached -- modules can start emitting events
- JSON output verified with mfa, line, timestamp, severity, domain metadata fields
- File rotation configured at priv/logs/agent_com.log

## Self-Check: PASSED

- All 8 files verified present
- Commit a9d5d77 verified (Task 1)
- Commit 9be958d verified (Task 2)
- mix compile succeeds
- mix test passes (1 pre-existing failure, 6 excluded)
- JSON output verified with mfa, line, redaction

---
*Phase: 13-structured-logging*
*Plan: 01*
*Completed: 2026-02-12*
