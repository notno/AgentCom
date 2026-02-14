---
status: diagnosed
trigger: "Smoke tests in test/smoke/ run during `mix test --exclude skip` and fail with econnrefused"
created: 2026-02-11T00:00:00Z
updated: 2026-02-11T00:00:00Z
---

## Current Focus

hypothesis: Smoke test modules lack @moduletag :smoke, so ExUnit has no way to exclude them
test: Read all 3 smoke files + test_helper.exs + ci.yml for any exclusion mechanism
expecting: No @moduletag present anywhere in smoke test files
next_action: Return structured diagnosis

## Symptoms

expected: `mix test --exclude skip` should only run unit/integration tests that don't need a running hub server
actual: All 3 smoke test files (basic_test.exs, failure_test.exs, scale_test.exs) are picked up and executed, failing with econnrefused because they try to connect to the hub via WebSocket/HTTP
errors: econnrefused on smoke test execution
reproduction: Run `mix test --exclude skip` without a hub server running
started: These tests have never had exclusion tags; the gap has existed since the files were created

## Eliminated

(none needed -- root cause confirmed on first inspection)

## Evidence

- timestamp: 2026-02-11T00:00:00Z
  checked: test/smoke/basic_test.exs (108 lines)
  found: Uses `use ExUnit.Case, async: false`. Has `@tag timeout: 60_000` on the test but NO @moduletag of any kind.
  implication: ExUnit will always include this module in default test runs.

- timestamp: 2026-02-11T00:00:00Z
  checked: test/smoke/failure_test.exs (178 lines)
  found: Uses `use ExUnit.Case, async: false`. Has `@tag timeout: 120_000` on tests but NO @moduletag.
  implication: Same -- always included.

- timestamp: 2026-02-11T00:00:00Z
  checked: test/smoke/scale_test.exs (193 lines)
  found: Uses `use ExUnit.Case, async: false`. Has `@tag timeout: 60_000` on tests but NO @moduletag.
  implication: Same -- always included.

- timestamp: 2026-02-11T00:00:00Z
  checked: test/test_helper.exs (18 lines)
  found: `ExUnit.start(exclude: [:skip], capture_log: true)` -- only excludes :skip tag. No mention of :smoke exclusion.
  implication: Even if @moduletag :smoke were added to smoke files, they would still run unless :smoke is also added to the exclude list here (or passed via CLI --exclude smoke).

- timestamp: 2026-02-11T00:00:00Z
  checked: .github/workflows/ci.yml (line 39)
  found: CI runs `mix test --exclude skip` -- no --exclude smoke flag.
  implication: CI will also run smoke tests and fail, unless the exclusion is added to test_helper.exs or the CI command.

- timestamp: 2026-02-11T00:00:00Z
  checked: Grep for @moduletag, :smoke, ExUnit.configure across entire test/ directory
  found: Zero matches. No module in the test suite uses @moduletag anywhere.
  implication: Confirms this is a net-new pattern that needs to be introduced.

- timestamp: 2026-02-11T00:00:00Z
  checked: mix.exs for any smoke-related aliases or test configuration
  found: No smoke-related config. Aliases only has `setup: ["deps.get"]`.
  implication: No existing mechanism to separate smoke tests from unit tests.

## Resolution

root_cause: The 3 smoke test modules (Smoke.BasicTest, Smoke.FailureTest, Smoke.ScaleTest) have no @moduletag to distinguish them from regular tests. ExUnit.start in test_helper.exs only excludes [:skip]. Therefore ExUnit includes every test file matching test/**/*_test.exs, including the smoke tests, which fail with econnrefused because they require a running hub server.

fix: (diagnosis only -- not applied)

verification: (diagnosis only)

files_changed: []
