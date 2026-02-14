---
status: resolved
trigger: "DashboardSocket crashes with Protocol.UndefinedError: Jason.Encoder not implemented for Tuple when backup_complete PubSub event is forwarded to WebSocket clients"
created: 2026-02-12T00:00:00Z
updated: 2026-02-13T00:00:00Z
---

## Current Focus

hypothesis: CONFIRMED - Two independent code paths send un-serializable data to Jason.encode!
test: Code trace through broadcast -> socket -> flush -> encode chain
expecting: Tuples reaching Jason.encode! at dashboard_socket.ex:134
next_action: Return structured diagnosis

## Symptoms

expected: backup_complete PubSub events are forwarded to WebSocket clients as JSON
actual: Crash with Protocol.UndefinedError: Jason.Encoder not implemented for Tuple
errors: "(jason 1.4.4) lib/jason.ex:164: Jason.encode!/2 ... (agent_com 0.1.0) lib/agent_com/dashboard_socket.ex:49"
reproduction: Trigger a backup (DetsBackup.backup_all/0), watch DashboardSocket crash on flush
started: After phase 10-02 (DETS backup + dashboard integration)

## Eliminated

(none - root cause found on first hypothesis)

## Evidence

- timestamp: 2026-02-12T00:00:00Z
  checked: dets_backup.ex do_backup_all/1 (lines 105-149)
  found: |
    PubSub broadcast at line 136 sends {:backup_complete, %{timestamp, tables_backed_up, backup_dir}}.
    tables_backed_up is a list of atoms (extracted from {:ok, info} tuples).
    The broadcast payload itself is clean -- atoms are serializable.
    BUT: state.last_backup_results (line 146) stores RAW results from backup_table/3,
    which are tagged tuples: {:ok, %{table: atom, path: string, size: int}} or {:error, %{...}}.
  implication: The PubSub broadcast payload is fine. But last_backup_results stored in GenServer state contains tuples.

- timestamp: 2026-02-12T00:01:00Z
  checked: dets_backup.ex health_metrics handler (lines 84-93)
  found: |
    health_metrics returns %{tables: [...], last_backup_at: ..., last_backup_results: state.last_backup_results}.
    last_backup_results is the RAW list of {:ok, %{...}} / {:error, %{...}} tuples.
    These tuples are NOT Jason-serializable.
  implication: Any code path that calls health_metrics() and passes the result to Jason.encode! will crash.

- timestamp: 2026-02-12T00:02:00Z
  checked: dashboard_state.ex snapshot (lines 133-148)
  found: |
    Line 133-137: dets_health = AgentCom.DetsBackup.health_metrics() -- includes last_backup_results with tuples.
    Line 148: snapshot includes dets_health: dets_health.
    This snapshot is sent to WebSocket clients via Jason.encode! at dashboard_socket.ex line 39 and 49.
  implication: CRASH PATH 1: snapshot -> dets_health -> last_backup_results contains tuples -> Jason.encode! explodes.

- timestamp: 2026-02-12T00:03:00Z
  checked: dashboard_socket.ex handle_info({:backup_complete, info}, ...) (lines 110-118)
  found: |
    This handler only extracts info.timestamp and info.tables_backed_up (converted to strings).
    The formatted map at line 112-115 is clean -- no tuples.
    The crash at line 49 in handle_in is from the request_snapshot path, not this handler.
  implication: The backup_complete PubSub handler in DashboardSocket is NOT the direct problem. The crash happens when a snapshot is requested (line 49) after a backup has occurred, because snapshot includes dets_health with raw tuples.

- timestamp: 2026-02-12T00:04:00Z
  checked: endpoint.ex line 627
  found: |
    HTTP endpoint also calls DetsBackup.health_metrics() and likely encodes to JSON.
    Same crash risk exists on the HTTP /api/dets/health path.
  implication: The bug affects both WebSocket snapshot AND HTTP health endpoint.

## Resolution

root_cause: |
  DetsBackup.health_metrics/0 returns last_backup_results as raw Elixir tagged tuples
  ({:ok, %{...}} / {:error, %{...}}). These tuples flow into DashboardState.snapshot()
  as dets_health.last_backup_results, which is then passed to Jason.encode!/1
  (dashboard_socket.ex lines 39, 49, 134). Jason has no encoder for tuples, causing the crash.

fix: |
  Added normalize_compaction_history/1 and normalize_compaction_result/1 in DetsBackup to convert
  all compaction history entries (including error reasons that may be tuples from GenServer exit)
  into Jason-serializable maps with string values. Applied normalization in both health_metrics
  and compaction_history handlers. The existing normalize_backup_results/1 already handled
  last_backup_results correctly.
verification: |
  All 6 dets_backup tests pass, including:
  - health_metrics returns Jason-serializable data after backup (Jason.encode! succeeds)
  - health_metrics compaction_history is Jason-serializable (Jason.encode succeeds)
  - compaction_history is Jason-serializable (Jason.encode succeeds)
files_changed:
  - lib/agent_com/dets_backup.ex
  - test/dets_backup_test.exs
