---
status: resolved
trigger: "WebhookHistory test failures — ETS table not found during on_exit cleanup"
created: 2026-02-14T00:00:00Z
updated: 2026-02-14T00:00:00Z
---

## Current Focus

hypothesis: CONFIRMED - ETS table destroyed before on_exit callback runs
test: n/a - fix verified
expecting: n/a
next_action: archive

## Symptoms

expected: All WebhookHistory tests pass when running `mix test --exclude skip`
actual: 19 failures — WebhookHistoryTest tests fail with ArgumentError on ets.delete_all_objects
errors: "(stdlib 7.2) :ets.internal_delete_all(:webhook_history, :undefined) ... lib/agent_com/webhook_history.ex:41: AgentCom.WebhookHistory.clear/0"
reproduction: Run `mix test --exclude skip`
started: When WebhookHistory was added

## Eliminated

## Evidence

- timestamp: 2026-02-14T00:00:00Z
  checked: WebhookHistory.init_table/0 and clear/0
  found: init_table creates ETS table owned by calling process (test process). clear/0 calls :ets.delete_all_objects without checking if table exists.
  implication: When test process exits, BEAM destroys the ETS table. on_exit runs in a different process after test process death, so table is gone.

- timestamp: 2026-02-14T00:00:00Z
  checked: WebhookHistoryTest setup/on_exit
  found: setup calls init_table() then clear(). on_exit calls clear(). The on_exit callback runs after the test process that owns the ETS table has terminated.
  implication: Root cause confirmed - on_exit runs after ETS table owner process dies.

- timestamp: 2026-02-14T00:00:00Z
  checked: Analytics and Threads modules for orphaned status
  found: Both modules are actively used - Analytics referenced in application.ex (supervisor), router.ex, endpoint.ex, socket.ex. Threads referenced in application.ex (supervisor), router.ex, endpoint.ex, dets_backup.ex.
  implication: STATE.md note about orphaned modules is outdated/incorrect. These modules are fully integrated.

## Resolution

root_cause: WebhookHistory.clear/0 called :ets.delete_all_objects(:webhook_history) unconditionally. In tests, the ETS table is created by init_table/0 which is called from the test process. The test process owns the ETS table. When the test process terminates, BEAM automatically destroys process-owned ETS tables. The on_exit callback runs in a separate ExUnit cleanup process AFTER the test process has died, so the :webhook_history table no longer exists, causing ArgumentError.
fix: Made clear/0 defensive by checking :ets.whereis(@table) before calling delete_all_objects. Returns :ok if table doesn't exist.
verification: mix test test/agent_com/webhook_history_test.exs - 5 tests, 0 failures
files_changed:
  - lib/agent_com/webhook_history.ex
