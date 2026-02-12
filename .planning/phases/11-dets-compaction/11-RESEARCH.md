# Phase 11: DETS Compaction + Recovery - Research

**Researched:** 2026-02-11
**Domain:** Erlang/OTP DETS table maintenance -- compaction (defragmentation) and corruption recovery
**Confidence:** HIGH (verified against official Erlang/OTP 28 DETS documentation, cross-referenced with codebase analysis of all 9 DETS-owning GenServers)

## Summary

DETS compaction in Erlang is achieved through exactly one mechanism: closing the table and reopening it with `{repair, force}`. There is no incremental or online compaction API. This means compaction inherently involves a brief window where the table is unavailable. For this project's scale (9 tables, each well under 2GB, ~5 agents), the blocking window per table will be sub-second -- easily within the 1-second success criterion.

The recovery procedure must handle two distinct scenarios: (1) corruption detected at table-open time (DETS auto-detects improperly closed tables), and (2) corruption detected during runtime operations (`:dets.lookup/2` et al. return `{:error, Reason}`). In both cases, the strategy is: close the corrupted table, replace it with the latest backup file, and reopen. The existing `DetsBackup` GenServer already knows all 9 table names, their file paths, and the backup directory -- making it the natural home for compaction and recovery logic.

The key architectural insight is that each DETS table is owned by a specific GenServer (Mailbox, Channels, TaskQueue, etc.), and compaction requires that owning process to close and reopen the table. The `DetsBackup` GenServer cannot directly close tables it did not open. Therefore, compaction must either: (a) be performed by each owning GenServer via a new `handle_call`, or (b) require temporarily stopping and restarting the owning GenServer through the Supervisor. Option (a) is cleaner and avoids supervisor-level disruption.

**Primary recommendation:** Add a `:compact` handle_call to each DETS-owning GenServer that performs close-then-reopen-with-repair-force. Orchestrate compaction from `DetsBackup` by calling each GenServer's compact function. Add recovery by replacing the file with a backup copy, then restarting the owning GenServer via the Supervisor.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Auto-restore on corruption detection -- detect corruption, restore from latest backup automatically, notify operator after the fact
- Always use the latest backup -- no backup version selection needed
- Verify restored data integrity before resuming normal operations (record count, open/close test)
- Expose manual restore endpoint -- operators can force-restore a table from backup at any time (e.g., to roll back bad data)
- Manual compaction trigger via API -- operators can compact a specific table or all tables on-demand
- Dashboard + push notifications for compaction/recovery events
- Push notifications for failures and auto-restores only -- successful compaction is silent
- Dashboard shows compaction history log: recent events with time, table, result, duration
- Extend existing Phase 10 DETS health card with compaction/recovery info (single place for all DETS status)
- No pre-compaction backup -- rely on Phase 10's scheduled backups as the safety net
- Retry once on compaction failure, then wait for next scheduled run

### Claude's Discretion
- Compaction schedule type (interval vs cron) and frequency
- Per-table vs global scheduling
- Whether to skip compaction below a fragmentation threshold
- Compaction failure protection strategy (copy-and-swap vs alternative)
- Behavior when both table and backup are corrupted (graceful shutdown vs degraded mode)

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `:dets` (Erlang/OTP) | OTP 28 | DETS table management, repair, compaction | Built-in, no alternatives exist for DETS compaction |
| `Phoenix.PubSub` | ~> 2.1 (already in project) | Event broadcasting for compaction/recovery events | Already used for "backups" topic, natural extension |
| `GenServer` (Elixir) | 1.19.5 (already in project) | Process management, timer scheduling | Already the pattern for all DETS-owning processes |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `Process.send_after/3` | Built-in | Scheduling periodic compaction | Same timer pattern used by DetsBackup for daily backups |
| `Supervisor` | Built-in | Stopping/restarting GenServers for recovery | Only for recovery (not compaction) when owning process must restart |
| `File` | Built-in | File copy for restore, file existence checks | Backup file operations during recovery |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `:dets` `{repair, force}` compaction | Manual copy-all-records-to-new-table | `repair: force` is the ONLY officially documented defragmentation method. Manual copy adds complexity with no benefit. |
| `Process.send_after` interval timer | `:timer.apply_interval` or cron library | `Process.send_after` is already the project pattern (DetsBackup, Scheduler, DashboardState). Cron library adds a dependency for no benefit at this scale. |

**Installation:** No new dependencies required. All functionality uses built-in Erlang/OTP and existing project libraries.

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  dets_backup.ex            # MODIFIED: Add compaction scheduling, recovery, and history tracking
  config.ex                 # MODIFIED: Add :compact handle_call
  mailbox.ex                # MODIFIED: Add :compact handle_call
  channels.ex               # MODIFIED: Add :compact handle_call
  message_history.ex        # MODIFIED: Add :compact handle_call
  task_queue.ex             # MODIFIED: Add :compact handle_call
  threads.ex                # MODIFIED: Add :compact handle_call
  dashboard_state.ex        # MODIFIED: Include compaction/recovery in health + snapshot
  dashboard_notifier.ex     # MODIFIED: Push notifications for failures/auto-restores
  endpoint.ex               # MODIFIED: New API endpoints for compaction/recovery triggers
```

### Pattern 1: Owning-GenServer Compaction
**What:** Each DETS-owning GenServer handles its own compaction internally via a synchronous `handle_call`.
**When to use:** For all 9 DETS tables.
**Why:** DETS tables are opened by a specific process. Only that process (or processes that also opened it) can close it. The owning GenServer has the table name, file path, and can safely serialize compaction with normal read/write operations via its mailbox.

```elixir
# Example: Added to each DETS-owning GenServer (e.g., Mailbox, Channels, etc.)
# Source: Erlang DETS docs - "close it and reopen with repair: force"

@impl true
def handle_call(:compact, _from, state) do
  table = @table
  file_path = :dets.info(table, :filename)

  # Close the table
  :ok = :dets.close(table)

  # Reopen with repair: force (this IS the compaction)
  case :dets.open_file(table, file: file_path, type: :set, repair: :force) do
    {:ok, ^table} ->
      {:reply, :ok, state}
    {:error, reason} ->
      # Table is now closed and can't reopen -- critical failure
      {:reply, {:error, reason}, state}
  end
end
```

### Pattern 2: Orchestrated Compaction from DetsBackup
**What:** `DetsBackup` GenServer orchestrates compaction by calling each owning GenServer's compact function, collecting results, and broadcasting events.
**When to use:** For scheduled compaction runs and manual API triggers.

```elixir
# In DetsBackup GenServer
defp compact_table(table_atom) do
  owner_module = table_owner(table_atom)
  start_time = System.system_time(:millisecond)

  result = try do
    GenServer.call(owner_module, :compact, 30_000)
  catch
    :exit, reason -> {:error, reason}
  end

  duration_ms = System.system_time(:millisecond) - start_time
  {result, duration_ms}
end

# Mapping from table atom to owning GenServer module
defp table_owner(:agent_mailbox), do: AgentCom.Mailbox
defp table_owner(:message_history), do: AgentCom.MessageHistory
defp table_owner(:agent_channels), do: AgentCom.Channels
defp table_owner(:channel_history), do: AgentCom.Channels
defp table_owner(:agentcom_config), do: AgentCom.Config
defp table_owner(:thread_messages), do: AgentCom.Threads
defp table_owner(:thread_replies), do: AgentCom.Threads
defp table_owner(:task_queue), do: AgentCom.TaskQueue
defp table_owner(:task_dead_letter), do: AgentCom.TaskQueue
```

### Pattern 3: Recovery via File Replacement + GenServer Restart
**What:** Recovery replaces the corrupted file with the latest backup, then restarts the owning GenServer through the Supervisor to pick up the restored file.
**When to use:** When corruption is detected (auto-restore) or when an operator triggers manual restore.

```elixir
# Recovery procedure:
# 1. Stop the owning GenServer (this closes the DETS table via terminate/2)
# 2. Replace the file with the latest backup
# 3. Restart the GenServer (init/1 opens the restored file)

defp restore_table(table_atom, backup_path) do
  owner = table_owner(table_atom)
  original_path = get_table_path(table_atom)

  # Step 1: Stop owner (terminate/2 closes DETS)
  :ok = Supervisor.terminate_child(AgentCom.Supervisor, owner)

  # Step 2: Replace file
  File.cp!(backup_path, original_path)

  # Step 3: Restart owner (init/1 opens restored file)
  {:ok, _pid} = Supervisor.restart_child(AgentCom.Supervisor, owner)

  # Step 4: Verify integrity
  verify_table_integrity(table_atom)
end
```

### Pattern 4: Corruption Detection via Error Returns
**What:** DETS operations return `{:error, Reason}` when the table is corrupted. Detect these in the owning GenServer and trigger auto-recovery.
**When to use:** Runtime corruption detection.

```elixir
# DETS operations that can signal corruption:
# :dets.lookup/2 -> {:error, Reason}
# :dets.insert/2 -> {:error, Reason}
# :dets.open_file/2 -> {:error, {needs_repair, FileName}}
# :dets.info/2 -> :undefined (when table is not open/available)

# Detection pattern in owning GenServer:
case :dets.lookup(@table, key) do
  [{^key, val}] -> {:reply, val, state}
  [] -> {:reply, nil, state}
  {:error, reason} ->
    Logger.error("DETS corruption detected in #{@table}: #{inspect(reason)}")
    # Notify DetsBackup to trigger auto-recovery
    GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @table, reason})
    {:reply, {:error, :table_corrupted}, state}
end
```

### Anti-Patterns to Avoid

- **Compacting from DetsBackup directly:** DetsBackup did not open the tables (it uses `:dets.info` and `:dets.sync` which work cross-process, but `:dets.close` requires the opener). Compaction must go through the owning GenServer.
- **Compacting all tables simultaneously:** Serial compaction is correct. Each table blocks its owner briefly. Parallel compaction would cause multiple GenServers to be blocked at once, potentially causing cascading timeouts.
- **Adding corruption detection wrappers to every DETS call:** Too invasive for Phase 11. Instead, wrap the key hot-path calls (lookup, insert) and rely on the compaction-time health check for less frequent operations.
- **Stopping the entire application for compaction:** Unnecessary. Each table compaction is independent and sub-second.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| DETS defragmentation | Custom record-copy to new file | `:dets.close` + `:dets.open_file(repair: :force)` | Only officially documented method; DETS internal buddy system is not exposed |
| Scheduling | Cron library or custom scheduler | `Process.send_after/3` interval timer | Already the project pattern in 4+ GenServers; adding cron lib for one timer is over-engineering |
| File integrity check | Custom binary parsing of DETS files | `:dets.open_file(repair: false)` to detect corruption, `:dets.info(table, :no_objects)` for record count | DETS has built-in integrity detection |
| Process restart for recovery | Manual GenServer stop/start with manual DETS close | `Supervisor.terminate_child` + `Supervisor.restart_child` | Supervisor handles the clean lifecycle; `terminate/2` in each GenServer already closes DETS |

**Key insight:** DETS compaction is not an operation that can be hand-rolled -- the only path is the built-in `repair: force` mechanism. The real engineering is in the orchestration: serializing compaction across multiple owning GenServers, handling the brief unavailability window, and integrating with the existing backup/health/notification infrastructure.

## Common Pitfalls

### Pitfall 1: Compaction on a Table Opened by Another Process
**What goes wrong:** Calling `:dets.close(table)` from a process that didn't open it may not actually close the table (DETS reference counts opens). The subsequent `:dets.open_file(repair: force)` is ignored because the table is still open.
**Why it happens:** DETS allows multiple processes to open the same table. Close only decrements the reference count. Repair option is ignored if the table is already open.
**How to avoid:** Always compact from within the owning GenServer's `handle_call`. The DetsBackup orchestrator calls the owning GenServer, never directly compacts.
**Warning signs:** Compaction appears to succeed but fragmentation ratio doesn't change. `:dets.info(table, :no_slots)` shows same values before and after.

### Pitfall 2: Recovery Leaving Table in Limbo
**What goes wrong:** If recovery replaces the file but fails to restart the GenServer, the table is closed and the system has no way to access it.
**Why it happens:** `Supervisor.restart_child` can fail if the init function hits an error (e.g., backup file is also corrupted).
**How to avoid:** Wrap the full recovery procedure in a try/rescue. If restart fails, log critical error and notify operator. Do NOT attempt recursive recovery. If both original and backup are corrupted, enter degraded mode rather than crash-looping.
**Warning signs:** GenServer process not found in `Process.whereis/1` after recovery attempt.

### Pitfall 3: Channels Module Owns Two Tables
**What goes wrong:** `AgentCom.Channels` opens both `:agent_channels` AND `:channel_history`. A simple `:compact` call needs to handle both tables, or separate calls need to exist.
**Why it happens:** Historical design -- channel data and channel history are in the same GenServer.
**How to avoid:** The Channels `:compact` handler should accept an optional table argument, or compact both tables sequentially. Similarly, `AgentCom.TaskQueue` owns `:task_queue` and `:task_dead_letter`, and `AgentCom.Threads` owns `:thread_messages` and `:thread_replies`.
**Warning signs:** Only one of two co-located tables gets compacted.

### Pitfall 4: Compaction During Active Writes
**What goes wrong:** A `handle_call(:compact, ...)` executes between the close and reopen while another message is queued in the GenServer mailbox. Since GenServer processes messages sequentially, this is actually safe -- but external callers of `:dets` functions (like DetsBackup's `health_metrics` which directly calls `:dets.info`) may see `:undefined` during the brief window.
**Why it happens:** DetsBackup bypasses the owning GenServer for `:dets.info` calls (by design from Phase 10).
**How to avoid:** The compaction window is sub-second. DetsBackup's health_metrics already handles `:undefined` status (returns `status: :unavailable`). No code change needed, but this interaction should be documented and tested.
**Warning signs:** Intermittent `:unavailable` status in health metrics during compaction windows.

### Pitfall 5: Backup File Naming Convention Mismatch
**What goes wrong:** Recovery needs to find "the latest backup" for a specific table. The backup naming convention is `{table_atom}_{timestamp}.dets`. If the naming convention changes or the directory has unexpected files, recovery fails.
**Why it happens:** Recovery is tightly coupled to DetsBackup's naming convention.
**How to avoid:** Recovery function should use the same file-listing-and-sorting logic already in DetsBackup's `cleanup_old_backups/2`. Extract it into a shared helper.
**Warning signs:** Recovery returns "no backup found" even though backup files exist.

## Code Examples

### Compaction Handle_Call (for each DETS-owning GenServer)
```elixir
# Source: Erlang DETS docs -- "close it and reopen with repair: force"
# Applied to the project's GenServer ownership pattern

# For GenServers that own ONE table (Mailbox, MessageHistory, Config):
@impl true
def handle_call(:compact, _from, state) do
  table = @table
  path = :dets.info(table, :filename)

  :ok = :dets.close(table)

  case :dets.open_file(table, file: path, type: :set, repair: :force) do
    {:ok, ^table} ->
      {:reply, :ok, state}
    {:error, reason} ->
      {:reply, {:error, reason}, state}
  end
end

# For GenServers that own TWO tables (Channels, TaskQueue, Threads):
@impl true
def handle_call({:compact, table_atom}, _from, state) when table_atom in [@table, @history_table] do
  path = :dets.info(table_atom, :filename)
  :ok = :dets.close(table_atom)

  case :dets.open_file(table_atom, file: path, type: :set, repair: :force) do
    {:ok, ^table_atom} ->
      {:reply, :ok, state}
    {:error, reason} ->
      {:reply, {:error, reason}, state}
  end
end
```

### Finding the Latest Backup for a Table
```elixir
# Source: Existing DetsBackup.cleanup_old_backups/2 pattern, adapted for recovery

def find_latest_backup(table_atom, backup_dir) do
  prefix = "#{table_atom}_"

  case File.ls(backup_dir) do
    {:ok, files} ->
      case files
           |> Enum.filter(fn f -> String.starts_with?(f, prefix) and String.ends_with?(f, ".dets") end)
           |> Enum.sort()
           |> List.last() do
        nil -> {:error, :no_backup_found}
        filename -> {:ok, Path.join(backup_dir, filename)}
      end
    {:error, reason} ->
      {:error, {:backup_dir_unreadable, reason}}
  end
end
```

### Integrity Verification After Restore
```elixir
# Source: User decision -- "Verify restored data integrity before resuming
# normal operations (record count, open/close test)"

def verify_table_integrity(table_atom) do
  case :dets.info(table_atom, :type) do
    :undefined ->
      {:error, :table_not_open}
    _ ->
      record_count = :dets.info(table_atom, :no_objects)
      file_size = :dets.info(table_atom, :file_size)

      # Attempt a traversal to verify data readability
      traversal_ok = try do
        :dets.foldl(fn _record, acc -> acc + 1 end, 0, table_atom)
        true
      rescue
        _ -> false
      end

      if traversal_ok do
        {:ok, %{record_count: record_count, file_size: file_size}}
      else
        {:error, :data_unreadable}
      end
  end
end
```

### Compaction Schedule Timer
```elixir
# Source: Project pattern -- Process.send_after used in DetsBackup, Scheduler,
# DashboardState, DashboardNotifier

# Recommendation: 6-hour interval, fixed interval timer (not cron)
# Rationale: DETS tables in this system are low-write-volume (< 1000 writes/day).
# 4x daily compaction is sufficient to keep fragmentation low without being
# so frequent that the brief blocking windows become noticeable.

@compaction_interval_ms 6 * 60 * 60 * 1000  # 6 hours

def init(_opts) do
  # ... existing init ...
  Process.send_after(self(), :scheduled_compaction, @compaction_interval_ms)
  # ...
end

def handle_info(:scheduled_compaction, state) do
  results = compact_all_tables()
  Process.send_after(self(), :scheduled_compaction, @compaction_interval_ms)
  {:noreply, update_compaction_history(state, results)}
end
```

## Claude's Discretion Recommendations

### 1. Schedule Type: Fixed Interval (6 hours)
**Recommendation:** Use `Process.send_after/3` with a 6-hour interval.
**Rationale:** This project already uses `Process.send_after` for all periodic tasks (DetsBackup daily backup, Scheduler stuck sweep, DashboardState queue growth check, DashboardNotifier health poll). A cron library would introduce a new dependency and pattern for minimal benefit. Six hours means 4 compactions per day, which is ample for the write volumes of a 5-agent system. Make the interval configurable via `Application.get_env(:agent_com, :compaction_interval_ms, 6 * 60 * 60 * 1000)`.
**Confidence:** HIGH -- aligns with existing project patterns.

### 2. Per-Table vs Global Schedule: Global Schedule, Serial Execution
**Recommendation:** One global timer triggers compaction of ALL tables, executed serially one at a time.
**Rationale:** The 9 tables do not have meaningfully different write patterns at this scale. A per-table schedule adds configuration complexity (9 separate intervals) for no benefit. Serial execution ensures only one table is briefly unavailable at a time. Total wall-clock time for 9 tables will be well under 9 seconds.
**Confidence:** HIGH -- per-table scheduling is over-engineering for 9 small tables.

### 3. Fragmentation Threshold Skip: Yes, Skip Below 10%
**Recommendation:** Before compacting a table, check its fragmentation ratio (already computed by `DetsBackup.table_metrics/1`). Skip compaction if fragmentation is below 10%.
**Rationale:** Compaction with `repair: force` rewrites the entire file even if there is nothing to defragment. The cost is small but nonzero (file I/O, brief unavailability). At 10% fragmentation on tables under a few MB, the overhead of compaction exceeds the benefit of reclaiming space. The threshold should be configurable via `Application.get_env(:agent_com, :compaction_threshold, 0.1)`.
**Confidence:** MEDIUM -- the fragmentation ratio calculation uses `1.0 - (used_slots / max_slots)`, which is a proxy for fragmentation, not a direct measure of wasted file space. At LOW fragmentation values, compaction may still reduce file size. But the 10% threshold prevents running compaction every 6 hours on tables that have barely changed.

### 4. Compaction Failure Protection: Close-Reopen-In-Place (NOT Copy-and-Swap)
**Recommendation:** Use the standard close + reopen-with-`repair: force` approach directly on the existing file. Do NOT implement copy-and-swap.
**Rationale:**
- `repair: force` is the ONLY documented DETS compaction method. The Erlang OTP source code internally performs a safe rewrite during repair.
- "Copy-and-swap" (copy data to a new DETS file, then rename) would require: (a) creating a second DETS file, (b) iterating all records and inserting them, (c) closing both files, (d) renaming the new file over the old. This is fragile, undocumented, and duplicates what `repair: force` already does internally.
- The user decision "No pre-compaction backup" plus "Rely on Phase 10's scheduled backups as the safety net" means we have backup coverage without needing copy-and-swap.
- If compaction fails (e.g., disk full during rewrite), the retry-once behavior and Phase 10 backups provide the safety net.
**Confidence:** HIGH -- `repair: force` is the documented approach. Copy-and-swap adds complexity with no documented advantage.

### 5. Both Table and Backup Corrupted: Degraded Mode with Empty Table
**Recommendation:** If both the table file and the latest backup are corrupted:
1. Log a CRITICAL error with the table name.
2. Send a push notification to operators.
3. Delete the corrupted file.
4. Let the owning GenServer restart -- its `init/1` will create an empty DETS file (this is the default DETS behavior when the file doesn't exist).
5. System continues in degraded mode with empty data for that table.
**Rationale:** Graceful shutdown of the entire system because one table (e.g., `channel_history`) lost data is disproportionate. Most DETS tables in this system are not critical for core operation -- the system can continue with empty mailboxes, empty message history, etc. The only truly critical table is `agentcom_config`, but even that has in-code defaults. Operators are notified and can investigate.
**Exception:** If the corrupted table is `:task_queue` and there are active task assignments, a more prominent warning should be emitted since in-progress work may be affected.
**Confidence:** MEDIUM -- this is a judgment call. Graceful shutdown is the conservative choice but seems overly aggressive for a hub system that should maximize availability. Empty-table degraded mode preserves system uptime while clearly signaling data loss.

## Table Ownership Map

Critical reference for the planner -- which GenServer owns which DETS table(s):

| Table Atom | DETS File | Owning GenServer | Open Options |
|------------|-----------|------------------|--------------|
| `:agent_mailbox` | `priv/mailbox.dets` | `AgentCom.Mailbox` | `type: :set, auto_save: 5_000` |
| `:message_history` | `priv/message_history.dets` | `AgentCom.MessageHistory` | `type: :set, auto_save: 5_000` |
| `:agent_channels` | `priv/channels.dets` | `AgentCom.Channels` | `type: :set, auto_save: 5_000` |
| `:channel_history` | `priv/channel_history.dets` | `AgentCom.Channels` | `type: :set, auto_save: 5_000` |
| `:agentcom_config` | `.agentcom/data/config.dets` | `AgentCom.Config` | `type: :set` (no auto_save) |
| `:thread_messages` | `.agentcom/data/thread_messages.dets` | `AgentCom.Threads` | `type: :set` |
| `:thread_replies` | `.agentcom/data/thread_replies.dets` | `AgentCom.Threads` | `type: :set` |
| `:task_queue` | `priv/task_queue.dets` | `AgentCom.TaskQueue` | `type: :set, auto_save: 5_000` |
| `:task_dead_letter` | `priv/task_dead_letter.dets` | `AgentCom.TaskQueue` | `type: :set, auto_save: 5_000` |

**Multi-table GenServers (need special handling):**
- `AgentCom.Channels` owns 2 tables: `:agent_channels`, `:channel_history`
- `AgentCom.TaskQueue` owns 2 tables: `:task_queue`, `:task_dead_letter`
- `AgentCom.Threads` owns 2 tables: `:thread_messages`, `:thread_replies`

## Existing Infrastructure to Extend

### DetsBackup GenServer (Phase 10) -- Primary Extension Point
The existing `DetsBackup` GenServer is the natural home for compaction scheduling and recovery orchestration:
- Already has `@tables` list of all 9 table atoms
- Already has `backup_dir` in state
- Already has `table_metrics/1` that computes fragmentation ratio
- Already has PubSub broadcast pattern on "backups" topic
- Already has `cleanup_old_backups/2` which uses the same file naming pattern needed by recovery
- Already in supervision tree after DashboardNotifier, before Bandit

### DashboardState (Phase 10) -- Extend Health/Snapshot
- Already subscribes to "backups" PubSub topic
- Already fetches `DetsBackup.health_metrics()` in snapshot
- Already computes DETS health conditions (stale backup, high fragmentation)
- Needs: compaction history in snapshot, recovery events in health conditions

### DashboardSocket (Phase 10) -- Extend Event Stream
- Already subscribes to "backups" PubSub topic
- Already handles `{:backup_complete, info}` events
- Needs: handle compaction_complete and recovery events

### DashboardNotifier (Phase 10) -- Extend Push Notifications
- Already sends push notifications on health degradation
- Already polls DashboardState for health changes
- Needs: push on compaction failure and auto-restore events

### Endpoint (Phase 10) -- Extend API Surface
- Already has `POST /api/admin/backup` for manual backup trigger
- Already has `GET /api/admin/dets-health` for health metrics
- Needs: `POST /api/admin/compact` for manual compaction, `POST /api/admin/restore` for manual restore

## API Design

### New Endpoints

```
POST /api/admin/compact                   # Compact all tables (auth required)
POST /api/admin/compact/:table            # Compact specific table (auth required)
POST /api/admin/restore/:table            # Restore table from latest backup (auth required)
```

### Response Formats

```json
// POST /api/admin/compact
{
  "status": "complete",
  "tables_total": 9,
  "tables_compacted": 7,
  "tables_skipped": 2,
  "results": [
    {"table": "agent_mailbox", "status": "compacted", "duration_ms": 45, "fragmentation_before": 0.35, "fragmentation_after": 0.02},
    {"table": "agentcom_config", "status": "skipped", "reason": "below_threshold", "fragmentation": 0.03}
  ]
}

// POST /api/admin/restore/:table
{
  "status": "restored",
  "table": "agent_mailbox",
  "backup_used": "agent_mailbox_2026-02-12T07-23-54.dets",
  "record_count": 142,
  "file_size": 32768
}
```

### PubSub Events (on "backups" topic)

```elixir
# Compaction complete event
{:compaction_complete, %{
  timestamp: integer(),
  results: [%{table: atom(), status: :compacted | :skipped | :error, duration_ms: integer()}]
}}

# Recovery event
{:recovery_complete, %{
  timestamp: integer(),
  table: atom(),
  backup_used: String.t(),
  record_count: integer(),
  trigger: :auto | :manual
}}

# Recovery failure
{:recovery_failed, %{
  timestamp: integer(),
  table: atom(),
  reason: term(),
  trigger: :auto | :manual
}}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| DETS v8 format | DETS v9 format | OTP R8 (stable since ~2003) | v9 is the only format in modern OTP. No version migration needed. |
| `:dets.open_file(Name)` (1-arg form) | `:dets.open_file(Name, Args)` (2-arg form) | Always preferred | 1-arg form is deprecated. All codebase usage is 2-arg. |
| `erlang:hash/2` based tables | `erlang:phash2/1` based tables | OTP R8 | All tables created by modern OTP use phash2. No migration. |

**Deprecated/outdated:**
- DETS v8 format: Not relevant to this project (all tables are v9, created by OTP 28)
- `dets:open_file/1` (1-arg form): Deprecated. Not used in codebase.

## Open Questions

1. **Exact blocking time for `repair: force` on project-scale tables**
   - What we know: DETS docs say "substantial time for large tables." Project tables are small (< 10MB each based on 5-agent scale).
   - What's unclear: Exact milliseconds for tables in the 1-10MB range on NVMe storage.
   - Recommendation: Measure during implementation. Add timing instrumentation to compact_table/1. The 1-second success criterion should be easily met, but measure to confirm and log.

2. **Fragmentation ratio accuracy as compaction trigger**
   - What we know: Current fragmentation calculation is `1.0 - (used_slots / max_slots)`. This measures hash table slot utilization, not file space waste.
   - What's unclear: Whether low slot fragmentation correlates well with low file fragmentation. A table could have well-utilized slots but wasted space from deleted records.
   - Recommendation: Use the slot-based ratio as a good-enough proxy. Add file_size tracking (before/after compaction) to the compaction history to validate the proxy over time.

3. **TaskQueue in-memory priority index after compaction**
   - What we know: TaskQueue maintains an in-memory `priority_index` built from DETS data on init. Compaction (close + reopen) does not rebuild this index.
   - What's unclear: Whether `repair: force` changes any record data that would invalidate the index. It should not (repair preserves all records).
   - Recommendation: Do NOT rebuild the priority index after compaction -- it's an in-memory structure that is correct as long as records are preserved. Add a test to verify.

## Sources

### Primary (HIGH confidence)
- [Erlang DETS stdlib v7.2 documentation](https://www.erlang.org/doc/apps/stdlib/dets.html) -- `open_file/2` repair option, defragmentation, `is_dets_file/1`, `info/2`, slot management, 2GB limit, thread safety
- AgentCom codebase -- all DETS-owning GenServers analyzed: `dets_backup.ex`, `config.ex`, `mailbox.ex`, `channels.ex`, `message_history.ex`, `task_queue.ex`, `threads.ex`, `dashboard_state.ex`, `dashboard_notifier.ex`, `endpoint.ex`
- [Erlang DETS erldocs](https://www.erldocs.com/current/stdlib/dets) -- repair option semantics, multi-process table access

### Secondary (MEDIUM confidence)
- [Erlang/OTP DETS issue #8513](https://github.com/erlang/otp/issues/8513) -- Auto-repair data loss regression in newer OTP versions (relevant to understanding repair risk)
- [Erlang DETS source code](https://github.com/erlang/otp/blob/master/lib/stdlib/src/dets.erl) -- `compact_init` internal function confirms copy-and-swap is done internally by repair
- [Elixir Forum: DETS open_file errors](https://elixirforum.com/t/erlang-dets-open-file-error-i-cant-understand-and-fix/14748) -- Common error patterns and recovery approaches

### Tertiary (LOW confidence)
- [Learn You Some Erlang: ETS/DETS chapter](https://learnyousomeerlang.com/ets) -- General DETS patterns and limitations
- [DETS keeps getting corrupted (erlang-history)](https://github.com/ferd/erlang-history/issues/17) -- Real-world DETS corruption scenarios

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- DETS is the only option; `repair: force` is the only compaction mechanism; no library choices to make
- Architecture: HIGH -- Ownership pattern is clear from codebase analysis; orchestration pattern follows existing DetsBackup design
- Pitfalls: HIGH -- DETS process ownership rules are well-documented; multi-table GenServer issue is directly visible in code
- Compaction timing: MEDIUM -- Sub-second claim is based on table size reasoning, not measurement
- Fragmentation threshold: MEDIUM -- Slot-based proxy for file fragmentation is imprecise

**Research date:** 2026-02-11
**Valid until:** 2026-03-11 (DETS is extremely stable; no changes expected)
