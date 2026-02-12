# Phase 10: DETS Backup + Monitoring - Research

**Researched:** 2026-02-11
**Domain:** Erlang DETS persistence, backup strategies, health monitoring
**Confidence:** HIGH

## Summary

AgentCom uses 9 DETS tables across 5 GenServers, split between two disk locations (`priv/` and `.agentcom/data/`). All tables are critical -- none are orphaned. The recommended backup approach is `:dets.sync/1` followed by `File.cp/2` (full file copy), which is simpler and more reliable than traverse-and-dump approaches. Fragmentation can be estimated by comparing `:dets.info(table, :file_size)` against `:dets.info(table, :no_slots)` minimum slot count, since DETS uses a buddy system allocator that grows the file but never shrinks it.

The new `AgentCom.DetsBackup` GenServer follows the existing codebase pattern perfectly: periodic timer via `Process.send_after`, PubSub broadcasts for dashboard integration, and authenticated admin endpoint via `RequireAuth` plug. The health check integrates into `DashboardState.compute_health/3` with two new conditions: stale backup (>48h) and high fragmentation (>50%).

**Primary recommendation:** Use `:dets.sync/1` + `File.cp/2` for backups, hardcoded table list (not directory scan), and integrate via a single new GenServer with daily timer.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Store backups on same machine in a separate directory (e.g., priv/backups/)
- Retain the last 3 backups per table, delete older ones automatically
- Timestamped filenames (e.g., tasks_2026-02-11T14-30-00.dets) for clear ordering and browsing
- Individual table backup failures continue with remaining tables (best-effort)
- Automatic backup runs once daily
- Manual backup via authenticated API endpoint -- returns synchronously with backup details (waits for completion)
- After successful backup: structured log entry + PubSub broadcast so dashboard can show last backup time live
- Metrics: table sizes (record count, file size), fragmentation ratio, time since last backup
- Visible via both JSON API endpoint and a DETS health card on the command center dashboard
- Unhealthy thresholds: warn on stale backup (>48h for daily schedule) OR high fragmentation (>50% wasted space)
- Integrate into existing DashboardState.compute_health -- overall system health includes DETS storage health

### Claude's Discretion
- Backup copy method (full file copy vs DETS traverse + dump) -- pick based on DETS internals
- Which tables to back up (audit all DETS tables, decide which are critical vs orphaned)
- Write consistency approach during backup (sync-then-copy vs as-is copy)
- Table discovery method (hardcoded list vs dynamic directory scan)
- API endpoint path (consistent with existing admin endpoint patterns)

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

## DETS Table Audit

### Complete Table Inventory

| # | Table Atom | Owner GenServer | File Path Config Key | Default Location | Type | Critical? |
|---|------------|-----------------|---------------------|------------------|------|-----------|
| 1 | `:task_queue` | `AgentCom.TaskQueue` | `:task_queue_path` | `priv/task_queue.dets` | `:set` | YES - active tasks |
| 2 | `:task_dead_letter` | `AgentCom.TaskQueue` | `:task_queue_path` | `priv/task_dead_letter.dets` | `:set` | YES - failed tasks for retry |
| 3 | `:agent_mailbox` | `AgentCom.Mailbox` | `:mailbox_path` | `priv/mailbox.dets` | `:set` | YES - offline agent messages |
| 4 | `:message_history` | `AgentCom.MessageHistory` | `:message_history_path` | `priv/message_history.dets` | `:set` | YES - audit trail |
| 5 | `:agent_channels` | `AgentCom.Channels` | `:channels_path` | `priv/channels.dets` | `:set` | YES - channel definitions + subscriptions |
| 6 | `:channel_history` | `AgentCom.Channels` | `:channels_path` | `priv/channel_history.dets` | `:set` | MEDIUM - channel message history (reproducible) |
| 7 | `:agentcom_config` | `AgentCom.Config` | `:config_data_dir` | `.agentcom/data/config.dets` | `:set` | YES - hub-wide settings |
| 8 | `:thread_messages` | `AgentCom.Threads` | `:threads_data_dir` | `.agentcom/data/thread_messages.dets` | `:set` | MEDIUM - thread index (derived from routed messages) |
| 9 | `:thread_replies` | `AgentCom.Threads` | `:threads_data_dir` | `.agentcom/data/thread_replies.dets` | `:set` | MEDIUM - reply chain index (derived data) |

### Criticality Assessment

**All 9 tables should be backed up.** None are orphaned.

- **Critical (data loss = operational impact):** task_queue, task_dead_letter, agent_mailbox, agent_channels, agentcom_config
- **Important (data loss = information loss, but derivable):** message_history, channel_history, thread_messages, thread_replies

The "medium" tables (threads, channel_history) contain derived/indexed data that could theoretically be rebuilt from other sources, but in practice losing them means losing conversation threading and message history, which is unacceptable.

### File Location Complexity

Tables are split across TWO directories with DIFFERENT config key patterns:

| Directory | Tables | Config Pattern |
|-----------|--------|----------------|
| `priv/` (or configured path) | task_queue, task_dead_letter, mailbox, message_history, channels, channel_history | Individual config keys per GenServer |
| `.agentcom/data/` (or configured path) | config, thread_messages, thread_replies | Different config keys |

This split means the backup GenServer must resolve actual file paths by reading each GenServer's config, not by scanning a single directory.

## Backup Approach

### Recommendation: `:dets.sync/1` + `File.cp/2` (Full File Copy)

**Confidence: HIGH** -- based on official Erlang docs and erlang-questions mailing list discussion.

#### Why Full File Copy Wins

| Approach | Pros | Cons |
|----------|------|------|
| **`:dets.sync/1` + `File.cp/2`** | Simple, fast, preserves exact file format, no RAM overhead | Brief inconsistency window if writes happen during copy |
| `:dets.to_ets/2` + `:ets.to_dets/2` | Fully consistent snapshot | Requires enough RAM for entire table in ETS; complex |
| `:dets.bchunk/2` + `:dets.init_table/3` | Streaming, lower RAM than to_ets | Complex API, still needs open DETS target file |
| `:dets.traverse/2` + dump | Can filter/transform | Slowest, highest complexity |

**The sync-then-copy approach is the right choice for this codebase because:**

1. **All tables already call `:dets.sync/1` after every write** (verified in all 5 GenServers). This means the on-disk file is always up-to-date.
2. **DETS files in this system are small** -- currently 5.4KB each (empty), and capped at manageable sizes (e.g., message_history caps at 10,000 records, mailbox at 100 per agent). No table will approach the 2GB DETS limit.
3. **The backup runs via GenServer.call** through each owning GenServer, so no concurrent writes happen during the sync+copy sequence for that specific table.

### Consistency Guarantee

**The key insight:** Because each DETS table is owned by a single GenServer, and the backup triggers a `GenServer.call` to that GenServer to perform the sync+copy, the BEAM's message ordering guarantees that no writes are interleaved. The sequence is:

1. Backup GenServer sends `GenServer.call` to owning GenServer (e.g., TaskQueue)
2. Owning GenServer handles the call: calls `:dets.sync(table)`, then `File.cp(source, dest)`
3. During step 2, no other messages are processed by the owning GenServer
4. Result: perfectly consistent backup, no locking needed

**However, this approach requires cooperation from each GenServer.** The alternative (having the backup GenServer call `:dets.sync` and `File.cp` directly) is acceptable because:
- All mutations already sync immediately
- The backup GenServer can call `:dets.sync/1` directly (DETS allows any process to call sync)
- The copy window is milliseconds for these small files

**Recommendation: Direct approach** -- the backup GenServer calls `:dets.sync/1` and `File.cp/2` directly, without routing through owning GenServers. This avoids coupling the backup system to every GenServer's internal API. The consistency risk is negligible for files this small.

### File Copy Sequence Per Table

```elixir
defp backup_table(table_atom, source_path, backup_dir, timestamp) do
  backup_filename = "#{table_atom}_#{timestamp}.dets"
  backup_path = Path.join(backup_dir, backup_filename)

  # Sync ensures in-memory buffers are flushed to disk
  :dets.sync(table_atom)

  # Copy the file
  case File.cp(source_path, backup_path) do
    :ok ->
      {:ok, %{table: table_atom, path: backup_path, size: File.stat!(backup_path).size}}
    {:error, reason} ->
      {:error, %{table: table_atom, reason: reason}}
  end
end
```

## Codebase Patterns

### GenServer Structure (for new DetsBackup GenServer)

All GenServers in the codebase follow this pattern:

```elixir
defmodule AgentCom.SomeServer do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Client API -- public functions that call GenServer

  @impl true
  def init(_opts) do
    # Setup, subscribe to PubSub if needed
    # Schedule periodic timer via Process.send_after
    {:ok, %{initial_state: true}}
  end

  @impl true
  def terminate(_reason, _state) do
    # Cleanup
    :ok
  end

  # handle_call for synchronous operations
  # handle_cast for fire-and-forget
  # handle_info for timer ticks and PubSub messages
end
```

**Periodic timer pattern** (used by TaskQueue, Mailbox, Scheduler, DashboardState, DashboardNotifier):

```elixir
# In init:
Process.send_after(self(), :tick_name, @interval_ms)

# In handle_info:
def handle_info(:tick_name, state) do
  # do work
  Process.send_after(self(), :tick_name, @interval_ms)
  {:noreply, updated_state}
end
```

### PubSub Broadcasting Pattern

```elixir
# Broadcasting (from TaskQueue):
Phoenix.PubSub.broadcast(AgentCom.PubSub, "tasks", {:task_event, %{
  event: :task_submitted,
  task_id: task.id,
  task: task,
  timestamp: System.system_time(:millisecond)
}})

# Subscribing (from DashboardState):
Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
```

**For backups, use a new topic `"backups"` with event format:**

```elixir
Phoenix.PubSub.broadcast(AgentCom.PubSub, "backups", {:backup_complete, %{
  timestamp: System.system_time(:millisecond),
  tables_backed_up: [...],
  backup_dir: "priv/backups/"
}})
```

### HTTP Endpoint Routing Pattern

The endpoint uses `Plug.Router` with inline route handlers (not a separate controller). Auth is applied per-route:

```elixir
# Admin endpoints use RequireAuth plug:
post "/api/admin/some-action" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    # do work
    send_json(conn, 200, %{"status" => "ok"})
  end
end
```

**Existing admin endpoint paths:**
- `POST /api/admin/reset` -- hub reset
- `POST /api/admin/push-task` -- push task to agent
- `POST /admin/tokens` -- generate token
- `GET /admin/tokens` -- list tokens
- `DELETE /admin/tokens/:id` -- revoke token

**Dashboard/no-auth endpoints:**
- `GET /api/dashboard/state` -- dashboard snapshot (no auth)
- `GET /health` -- health check (no auth)

### Authentication Pattern

Two patterns exist:
1. **`RequireAuth` plug** -- for endpoints needing auth, sets `conn.assigns[:authenticated_agent]`
2. **Manual token check** -- some endpoints manually call `AgentCom.Auth.verify(token)`

Admin-only endpoints additionally check `@admin_agents` list (from ADMIN_AGENTS env var).

### DashboardState.compute_health Pattern

Health is computed as a list of condition strings with a status level:

```elixir
defp compute_health(state, agents, now) do
  conditions = []
  has_critical = false

  # Each check appends to conditions list
  conditions = if some_check do
    ["Description of problem" | conditions]
  else
    conditions
  end

  # Determine status based on conditions
  status = cond do
    has_critical -> :critical
    length(conditions) > 0 -> :warning
    true -> :ok
  end

  %{status: status, conditions: Enum.reverse(conditions)}
end
```

**To integrate DETS health:** Add DETS checks as additional condition blocks within `compute_health/3`. The function currently checks: agent offline, queue growing, high failure rate, stuck tasks. DETS health adds: stale backup, high fragmentation.

### Application Supervision Tree

Children are started in order in `application.ex`. The backup GenServer should be added after `DashboardState` (which it needs to integrate with) but before `Bandit` (the HTTP server):

```elixir
children = [
  # ... existing children ...
  {AgentCom.DashboardState, []},
  {AgentCom.DashboardNotifier, []},
  {AgentCom.DetsBackup, []},        # <-- NEW
  {Bandit, plug: AgentCom.Endpoint, scheme: :http, port: port()}
]
```

## DETS Metrics API

### Available via `:dets.info/2`

| Item | Return Type | What It Tells Us |
|------|-------------|-----------------|
| `:file_size` | `integer()` | File size in bytes on disk |
| `:size` | `integer()` | Number of objects (records) stored |
| `:no_objects` | `integer()` | Same as `:size` |
| `:no_keys` | `integer()` | Number of distinct keys (same as no_objects for `:set` type) |
| `:no_slots` | `{Min, Used, Max}` | Slot allocation: minimum, currently used, maximum |
| `:memory` | `integer()` | Same as `:file_size` |
| `:type` | `:set \| :bag \| :duplicate_bag` | Table type |
| `:filename` | `charlist()` | Path to the DETS file |

### Fragmentation Calculation

DETS uses a buddy system allocator. The file grows when more slots are needed but **never shrinks** automatically. Fragmentation occurs when records are deleted or updated, leaving gaps.

**Recommended fragmentation formula:**

```elixir
defp calculate_fragmentation(table) do
  file_size = :dets.info(table, :file_size)
  {min_slots, _used_slots, _max_slots} = :dets.info(table, :no_slots)
  no_objects = :dets.info(table, :no_objects)

  # Minimum possible file size for this number of objects
  # DETS header is ~8KB, each slot ~varies
  # Simple heuristic: if no_objects is 0 and file_size > base, it's all fragmentation
  # For non-empty tables: compare file_size to a theoretical minimum
  if no_objects == 0 do
    if file_size > 5500, do: 1.0, else: 0.0
  else
    # Base DETS file size (empty table) is ~5464 bytes
    base_size = 5464
    data_overhead = file_size - base_size
    # Rough estimate: each object uses ~100-500 bytes depending on content
    # Better approach: use no_slots ratio
    # {Min, Used, Max} -- if Used << Max, the file has grown and not contracted
    {_min, used, max} = :dets.info(table, :no_slots)
    if max > 0 do
      wasted_ratio = 1.0 - (used / max)
      Float.round(wasted_ratio, 2)
    else
      0.0
    end
  end
end
```

**Practical note:** For the "50% wasted space" threshold, the simplest reliable approach is:

```elixir
# Fragmentation = (file_size - estimated_data_size) / file_size
# Where estimated_data_size can be approximated from no_objects
# Or simpler: compare to file_size of a freshly repaired table

# Simplest approach that works:
{_min, used, max} = :dets.info(table, :no_slots)
fragmentation_ratio = if max > 0, do: 1.0 - (used / max), else: 0.0
```

### Gathering All Metrics for One Table

```elixir
defp table_metrics(table) do
  file_size = :dets.info(table, :file_size)
  no_objects = :dets.info(table, :no_objects)
  {min_slots, used_slots, max_slots} = :dets.info(table, :no_slots)

  fragmentation =
    if max_slots > 0,
      do: Float.round(1.0 - (used_slots / max_slots), 3),
      else: 0.0

  %{
    table: table,
    file_size_bytes: file_size,
    record_count: no_objects,
    slots: %{min: min_slots, used: used_slots, max: max_slots},
    fragmentation_ratio: fragmentation
  }
end
```

## Dashboard Integration

### How the Dashboard Renders

The dashboard is a single self-contained HTML page served by `AgentCom.Dashboard.render/0`. It:

1. Connects via WebSocket to `/ws/dashboard`
2. Receives an initial `{type: "snapshot", data: snapshot}` message
3. Receives incremental `{type: "events", data: [...]}` messages
4. Re-renders sections based on data

### Where DETS Health Card Fits

The dashboard uses a **grid layout**:
- **Top grid** (3 columns): Agents | Queue Summary | Throughput
- **Bottom grid** (2 columns): Recent Tasks | Dead Letter

The DETS health card should go in a **new bottom row** or be appended to the existing bottom grid as a third section. Given the existing `grid-bottom` is `2fr 1fr`, the DETS card can be added as a panel within a new grid row.

### Health Badge Integration

The health badge in the header already shows conditions from `compute_health`. Once DETS conditions are added to `compute_health`, they will automatically appear in the health conditions dropdown when the badge is clicked. No separate dashboard JS changes needed for the health conditions list.

For the dedicated DETS health card, the snapshot data needs to include DETS metrics:

```javascript
// New section in renderFullState:
renderDetsHealth(data.dets_health || {});
```

### Snapshot Data Extension

The `DashboardState.snapshot/0` function needs to include DETS health data:

```elixir
# In snapshot/0, add:
dets_health = AgentCom.DetsBackup.health_metrics()

snapshot = %{
  # ... existing fields ...
  dets_health: dets_health
}
```

### Dashboard Card Rendering Pattern

Follow the existing panel pattern:

```html
<div class="panel" id="panel-dets">
  <div class="panel-title">DETS Storage Health</div>
  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>Table</th>
          <th>Records</th>
          <th>File Size</th>
          <th>Fragmentation</th>
          <th>Last Backup</th>
        </tr>
      </thead>
      <tbody id="dets-tbody"></tbody>
    </table>
  </div>
</div>
```

### DashboardSocket Integration

The DashboardSocket already subscribes to "tasks" and "presence" topics. To show backup events in real-time:

1. Subscribe to "backups" topic in DashboardSocket
2. Forward backup events to the browser
3. Browser requests a fresh snapshot on backup events (same pattern used for task events)

## Common Pitfalls

### Pitfall 1: Backing Up a Closed Table
**What goes wrong:** If a GenServer crashes and its DETS table is closed, `:dets.sync/1` returns `{:error, :not_owner}` or similar.
**Why it happens:** DETS tables must be open to sync.
**How to avoid:** Before syncing, check if the table is open via `:dets.info(table, :type)` -- if it returns `undefined`, the table is not open. Fall back to direct `File.cp/2` without sync (the file on disk is still valid, just may not have the latest buffered writes).
**Warning signs:** `{:error, _}` return from `:dets.sync/1`.

### Pitfall 2: File Path Resolution
**What goes wrong:** The backup system uses hardcoded paths that don't match the actual table locations because Application config overrides are in play.
**Why it happens:** Tables are configured with different config keys across 5 GenServers, and some use `String.to_charlist()` conversion.
**How to avoid:** Use `:dets.info(table, :filename)` to get the actual current file path at runtime, regardless of configuration. This returns a charlist -- convert with `to_string()`.
**Warning signs:** `File.cp/2` returning `{:error, :enoent}`.

### Pitfall 3: Backup Directory Doesn't Exist
**What goes wrong:** `File.cp/2` fails because `priv/backups/` hasn't been created.
**Why it happens:** First run, or directory was deleted.
**How to avoid:** Call `File.mkdir_p!(backup_dir)` at GenServer init and before each backup run.

### Pitfall 4: Timestamp Format on Windows
**What goes wrong:** Filenames with `:` characters (from ISO timestamps) fail on Windows.
**Why it happens:** Windows doesn't allow `:` in filenames.
**How to avoid:** Use `T14-30-00` format (hyphens) not `T14:30:00` (colons), as specified in the user's decision. The user already anticipated this.

### Pitfall 5: Race Condition in Retention Cleanup
**What goes wrong:** Concurrent backup triggers (daily + manual) could create more than 3 backups before cleanup runs.
**Why it happens:** If manual backup is triggered right as daily backup runs.
**How to avoid:** Run cleanup after each backup completes (not on a separate timer). The GenServer serializes calls naturally.

### Pitfall 6: `:dets.info/2` Returns `undefined` for Closed Tables
**What goes wrong:** Health metrics collection crashes when a table is temporarily closed.
**Why it happens:** Between GenServer restart and table reopen.
**How to avoid:** Pattern match on `undefined` return and report the table as "unavailable" rather than crashing.

### Pitfall 7: Large File Copies Blocking the GenServer
**What goes wrong:** If tables grow large, `File.cp/2` blocks the GenServer process.
**Why it happens:** File I/O is synchronous in Elixir.
**How to avoid:** Not a concern at current scale (files are KB-sized, not GB). If tables grow to MB range, consider `Task.async` for the copy. For now, synchronous is fine and simpler.

## Recommendations (Claude's Discretion Items)

### 1. Backup Copy Method: `:dets.sync/1` + `File.cp/2`
**Rationale:** All GenServers already sync after every write. The file on disk is always consistent. A file copy is simpler, faster, and creates an exact replica with no transformation loss. Traverse+dump approaches add complexity with no benefit for tables this small.

### 2. Tables to Back Up: All 9 Tables
**Rationale:** No orphaned tables found. All 9 are actively used by running GenServers. Even "derived" tables (threads, channel_history) contain data that would be painful to lose.

### 3. Write Consistency: Sync-Then-Copy (Direct)
**Rationale:** Call `:dets.sync(table_atom)` directly from the backup GenServer, then `File.cp/2`. DETS allows any process to call sync. Since all mutations already sync immediately, the explicit sync before copy is a belt-and-suspenders measure. No need to route through owning GenServers.

### 4. Table Discovery: Hardcoded List with Runtime Path Resolution
**Rationale:** Directory scanning is fragile -- tables are in two different directories, test artifacts could be picked up, and the scanner would need to know which atom name maps to which file. A hardcoded list of the 9 table atoms is simple and correct. Use `:dets.info(table, :filename)` at runtime to resolve actual file paths, which handles any config overrides automatically.

```elixir
@tables [
  :task_queue,
  :task_dead_letter,
  :agent_mailbox,
  :message_history,
  :agent_channels,
  :channel_history,
  :agentcom_config,
  :thread_messages,
  :thread_replies
]
```

### 5. API Endpoint Paths
**Rationale:** Follow the existing `/api/admin/` pattern for authenticated admin operations and `/api/dashboard/` pattern for monitoring data.

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `POST /api/admin/backup` | POST | RequireAuth | Trigger manual backup, return results synchronously |
| `GET /api/admin/dets-health` | GET | RequireAuth | JSON health metrics for all tables |

The dashboard state endpoint (`GET /api/dashboard/state`) already returns the full snapshot -- DETS health will be included there automatically once integrated into `DashboardState.snapshot/0`.

## Architecture Patterns

### Recommended Module Structure

```
lib/agent_com/
  dets_backup.ex          # GenServer: backup scheduling, execution, retention
```

No additional modules needed. The GenServer handles:
- Daily timer for automatic backup
- `backup_all/0` public API for manual trigger
- `health_metrics/0` public API for health data
- Retention cleanup (keep last 3 per table)
- PubSub broadcast after successful backup

### DetsBackup GenServer State

```elixir
%{
  backup_dir: String.t(),
  last_backup_at: integer() | nil,       # System.system_time(:millisecond)
  last_backup_results: [map()] | nil,     # per-table results
  daily_interval_ms: integer()            # 24 * 60 * 60 * 1000
}
```

### Integration Points

1. **application.ex** -- Add `{AgentCom.DetsBackup, []}` to children list
2. **endpoint.ex** -- Add `POST /api/admin/backup` and `GET /api/admin/dets-health` routes
3. **dashboard_state.ex** -- Add DETS health check in `compute_health/3`, add `dets_health` to snapshot
4. **dashboard.ex** -- Add DETS health card HTML + JS rendering
5. **dashboard_socket.ex** -- Subscribe to "backups" topic for real-time updates

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| File copying | Custom byte-level copy | `File.cp/2` | Handles OS-level copy correctly |
| Timestamp formatting | Manual string building | `Calendar.strftime/2` or `NaiveDateTime.to_string/1` with replacement | Edge cases in formatting |
| JSON encoding | Manual map-to-string | `Jason.encode!/1` | Already used everywhere in codebase |
| Timer scheduling | Custom timer logic | `Process.send_after/3` | Standard OTP pattern used throughout codebase |

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| DETS version 8 (hash table) | DETS version 9 (hash table, default since OTP R8) | OTP R8 (~2001) | Current codebase uses v9 by default |
| `:dets.fsck/1` for repair | Open with `repair: :force` option | Long-standing | Repair = close + reopen with repair flag |

**Deprecated/outdated:**
- DETS version 8 format: Not used by this codebase. All tables default to version 9.
- `:dets.match_object/2` for queries: This codebase correctly uses `:dets.select/2` and `:dets.foldl/3` instead, which are more efficient.

## Open Questions

1. **Exact fragmentation threshold calibration**
   - What we know: `no_slots` gives `{Min, Used, Max}` and `1 - (Used/Max)` gives a ratio
   - What's unclear: Whether this ratio directly maps to "50% wasted space" as the user intends, or whether `file_size` comparison would be more intuitive
   - Recommendation: Implement both metrics (slot-based ratio AND file_size), expose both in the health endpoint, calibrate the 50% threshold against real-world data after deployment. Start with the slot-based ratio.

2. **Backup directory configuration**
   - What we know: User said "e.g., priv/backups/"
   - What's unclear: Whether this should be configurable via Application env or AgentCom.Config (DETS-stored config)
   - Recommendation: Use `Application.get_env(:agent_com, :backup_dir, "priv/backups")` for consistency with how other paths are configured. Don't store in DETS Config (chicken-and-egg: Config table itself needs backing up).

3. **Daily backup timing**
   - What we know: "runs once daily"
   - What's unclear: What time of day, or if it should be 24h from startup
   - Recommendation: 24h from startup is simplest and avoids timezone complexity. First backup runs 24h after GenServer init. Users can trigger manual backup immediately after deployment if needed.

## Sources

### Primary (HIGH confidence)
- [Erlang DETS official docs - stdlib v7.2](https://www.erlang.org/doc/man/dets) - info/1, info/2 items, sync/1 guarantees, to_ets/2
- Codebase audit of all `.ex` files with `:dets.` calls - complete table inventory

### Secondary (MEDIUM confidence)
- [erlang-questions mailing list: Efficiently backing up DETS files](http://erlang.org/pipermail/erlang-questions/2014-June/079952.html) - backup approaches comparison (bchunk vs to_ets vs file copy)
- [Erlang DETS docs v19](https://www.erlang.org/docs/19/man/dets) - historical reference for API stability

### Tertiary (LOW confidence)
- Fragmentation ratio calculation via `no_slots` -- this is a reasonable heuristic but not officially documented as "fragmentation percentage". The official docs only describe slot counts, not a fragmentation metric. Needs validation with real data.

## Metadata

**Confidence breakdown:**
- DETS table audit: HIGH -- complete codebase grep, every `:dets.open_file` call found and catalogued
- Backup approach: HIGH -- official docs confirm sync/1 guarantees, codebase already syncs after every write
- Codebase patterns: HIGH -- directly read from source files, all patterns verified
- DETS metrics API: HIGH -- official docs list all info/2 items
- Fragmentation calculation: MEDIUM -- based on understanding of DETS internals, but no official "fragmentation ratio" API exists
- Dashboard integration: HIGH -- dashboard source code fully read and understood

**Research date:** 2026-02-11
**Valid until:** 2026-03-11 (30 days -- DETS API is very stable, codebase patterns unlikely to change)
