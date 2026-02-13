# Phase 23: Multi-Repo Registry and Workspace Switching - Research

**Researched:** 2026-02-12
**Domain:** Elixir GenServer DETS registry, Node.js workspace management, priority-ordered list operations, scheduler repo-filtering
**Confidence:** HIGH

## Summary

Phase 23 introduces a priority-ordered repo registry on the hub and per-repo workspace management on the sidecar. The hub's `RepoRegistry` GenServer maintains a DETS-backed list of repos with priority ordering and active/paused status. The scheduler filters out tasks tagged with paused repos. Tasks submitted without a repo field inherit the top-priority active repo. The sidecar maintains a workspace cache (one cloned repo directory per registered repo) and switches its working directory per task based on the task's `repo` field.

The existing codebase provides all the infrastructure patterns needed. The `LlmRegistry` (Phase 18) demonstrates the DETS-backed GenServer registry pattern with CRUD operations, PubSub broadcasting, and dashboard integration. The `Config` module demonstrates DETS key-value storage. The `TaskQueue` already has a `repo` field on every task (Phase 17). The `Scheduler` already passes `repo` through the assignment pipeline to the sidecar. The sidecar's `config.repo_dir` is already used as the `cwd` for shell execution, git operations, and verification checks -- making it the single point to swap for workspace switching. The dashboard already has an LLM Registry section with add/remove, table rendering, and PubSub-driven updates that can serve as the template for the Repo Registry UI.

The primary technical challenge is the sidecar workspace cache -- ensuring repos are cloned on first use, kept up to date (git pull before each task), and that the `repo_dir` override is threaded through all execution paths (shell executor `cwd`, verification `cwd`, git workflow `repo_dir`, Claude executor `cwd`). The hub-side work is largely assembly of existing patterns.

**Primary recommendation:** Build `AgentCom.RepoRegistry` as a DETS-backed GenServer following the `LlmRegistry` pattern. Use an ordered list stored as a single DETS key (not individual keys per repo) for atomic priority reordering. On the sidecar, add a `workspace-manager.js` module that maintains a `~/.agentcom/<agent_name>/workspaces/<repo_slug>/` directory tree and provides `ensureWorkspace(repoUrl)` returning the cloned path. Thread the per-task workspace path through `config.repo_dir` at dispatch time.

## Standard Stack

### Core (already in project, no new deps)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `:dets` (Erlang) | OTP 27+ | Persistent storage for repo registry | Existing pattern used by TaskQueue, Config, LlmRegistry, etc. |
| Phoenix.PubSub | ~> 2.1 | Event broadcast for dashboard updates | Already in deps, used by every dashboard-connected GenServer |
| Jason | ~> 1.4 | JSON encoding/decoding | Already in deps |
| Node.js `child_process` | built-in | Git clone/pull for workspace management | Already used in git-workflow.js, wake.js |
| Node.js `fs` | built-in | Directory existence checks, workspace cache | Already used throughout sidecar |
| Node.js `path` | built-in | Path construction for workspace directories | Already used throughout sidecar |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `write-file-atomic` | ^5.0.0 | Crash-safe workspace state persistence | Already a dependency, used by queue.js |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Single DETS key for ordered list | Individual DETS keys per repo | Individual keys make reordering non-atomic; a single list key enables atomic swap |
| Git clone for workspace init | Git worktree | Worktrees share a single clone's object store (saves disk), but require the "main" repo to exist and add management complexity. Independent clones are simpler, isolated, and match the existing add-agent.js pattern. |
| Filesystem-based workspace cache | In-memory workspace map | Filesystem cache survives sidecar restart without explicit persistence. Check `fs.existsSync()` + `.git` presence to validate. |

**Installation:** No new packages needed.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  repo_registry.ex          # NEW: GenServer with DETS persistence, priority ordering, active/paused

  # Modifications to existing files:
  scheduler.ex              # Filter out paused-repo tasks; inject top-priority repo for nil-repo tasks
  task_queue.ex             # Resolve nil repo at submit time (inherit top-priority active repo)
  endpoint.ex               # New HTTP routes: /api/admin/repo-registry/*
  socket.ex                 # No changes needed (repo already flows through task_assign)
  dashboard_state.ex        # Include repo registry data in snapshot
  dashboard_socket.ex       # Forward repo_registry PubSub events to browser
  dashboard.ex              # New dashboard section: Repo Registry table with reorder/pause controls
  validation/schemas.ex     # New schemas for repo registry HTTP routes

sidecar/
  lib/
    workspace-manager.js    # NEW: Per-repo workspace cache (clone, pull, path resolution)
  index.js                  # Modify: resolve repo_dir from workspace manager before dispatch
```

### Pattern 1: DETS-Backed Ordered List (Single-Key Atomic Reorder)
**What:** Store the repo registry as a single ordered list under one DETS key, rather than one key per repo. This makes reordering atomic -- swap the list in one `dets.insert`.
**When to use:** When priority ordering matters and reordering must be consistent.
**Example:**
```elixir
# Source: Existing DETS patterns from Config, LlmRegistry
defmodule AgentCom.RepoRegistry do
  use GenServer
  require Logger

  @dets_table :repo_registry
  @registry_key :repos

  def init(_opts) do
    dets_path = Path.join(data_dir(), "repo_registry.dets") |> String.to_charlist()
    {:ok, @dets_table} = :dets.open_file(@dets_table, file: dets_path, type: :set, auto_save: 5_000)

    repos = load_repos()
    Logger.info("repo_registry_started", repo_count: length(repos))
    {:ok, %{}}
  end

  defp load_repos do
    case :dets.lookup(@dets_table, @registry_key) do
      [{@registry_key, repos}] when is_list(repos) -> repos
      [] -> []
    end
  end

  defp save_repos(repos) do
    :dets.insert(@dets_table, {@registry_key, repos})
    :dets.sync(@dets_table)
  end

  # Atomic reorder: remove from old position, insert at new position
  defp move_repo(repos, repo_id, new_index) do
    case Enum.split_with(repos, fn r -> r.id != repo_id end) do
      {others, [repo]} ->
        {before, after_} = Enum.split(others, min(new_index, length(others)))
        before ++ [repo] ++ after_
      {_all, []} ->
        repos  # repo_id not found, no change
    end
  end
end
```

### Pattern 2: Repo Entry Shape
**What:** Each repo entry is a map with fields needed for registry management, scheduler filtering, and sidecar workspace resolution.
**When to use:** For all repo CRUD operations.
**Example:**
```elixir
# A single repo entry in the ordered list
%{
  id: "notno-AgentCom",                    # Slug derived from URL (owner-name)
  url: "https://github.com/notno/AgentCom.git",
  name: "AgentCom",                        # Display name
  status: :active,                         # :active | :paused
  added_at: 1707753600000,                 # millisecond timestamp
  added_by: "admin"                        # who added it
}
```

### Pattern 3: Scheduler Repo Filtering
**What:** Before the matching loop, the scheduler filters queued tasks to skip those tagged with a paused repo. Tasks with no repo or with an active repo proceed normally.
**When to use:** In `try_schedule_all/2` before `do_match_loop`.
**Example:**
```elixir
# In Scheduler.try_schedule_all/2, after fetching queued_tasks:
active_repos = AgentCom.RepoRegistry.active_repo_ids()

schedulable_tasks =
  Enum.filter(queued_tasks, fn task ->
    repo = Map.get(task, :repo)
    # nil repo = no filtering (backward compat), or repo is in active set
    repo == nil or repo in active_repos
  end)

# Use schedulable_tasks instead of queued_tasks in do_match_loop
```

### Pattern 4: Nil-Repo Inheritance at Submit Time
**What:** When a task is submitted without a `repo` field, the TaskQueue resolves it to the top-priority active repo from the RepoRegistry. This happens at submit time so the repo is persisted with the task.
**When to use:** In `TaskQueue.handle_call({:submit, params})`.
**Example:**
```elixir
# In TaskQueue submit handler, after extracting repo from params:
repo = Map.get(params, :repo, Map.get(params, "repo", nil))

# Resolve nil repo to top-priority active repo
repo =
  case repo do
    nil ->
      case AgentCom.RepoRegistry.top_active_repo() do
        {:ok, top_repo} -> top_repo.url
        :none -> nil
      end
    url -> url
  end
```

### Pattern 5: Sidecar Workspace Manager
**What:** A module that maintains a directory tree of cloned repos, one per registered repo. Ensures the workspace is cloned and up-to-date before returning the path.
**When to use:** Before task dispatch in `executeTask()`.
**Example:**
```javascript
// sidecar/lib/workspace-manager.js
'use strict';

const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');
const { log } = require('./log');

class WorkspaceManager {
  /**
   * @param {string} baseDir - Base directory for all workspaces
   *   e.g., ~/.agentcom/<agent_name>/workspaces/
   */
  constructor(baseDir) {
    this.baseDir = baseDir;
    fs.mkdirSync(baseDir, { recursive: true });
  }

  /**
   * Ensure a workspace exists for the given repo URL.
   * Clones on first use, pulls on subsequent uses.
   * Returns the absolute path to the workspace directory.
   *
   * @param {string} repoUrl - Git repo URL
   * @returns {string} Absolute path to workspace directory
   */
  ensureWorkspace(repoUrl) {
    const slug = this._urlToSlug(repoUrl);
    const wsDir = path.join(this.baseDir, slug);
    const gitDir = path.join(wsDir, '.git');

    if (fs.existsSync(gitDir)) {
      // Workspace exists -- pull latest
      try {
        execSync('git fetch origin && git reset --hard origin/main', {
          cwd: wsDir,
          encoding: 'utf-8',
          timeout: 120000,
          windowsHide: true
        });
        log('info', 'workspace_updated', { repo: repoUrl, dir: wsDir });
      } catch (err) {
        log('warning', 'workspace_pull_failed', {
          repo: repoUrl,
          error: err.message
        });
        // Continue with stale workspace rather than failing the task
      }
    } else {
      // First use -- clone
      log('info', 'workspace_cloning', { repo: repoUrl, dir: wsDir });
      fs.mkdirSync(wsDir, { recursive: true });
      execSync(`git clone "${repoUrl}" "${wsDir}"`, {
        encoding: 'utf-8',
        timeout: 300000,
        windowsHide: true
      });
      log('info', 'workspace_cloned', { repo: repoUrl, dir: wsDir });
    }

    return wsDir;
  }

  /**
   * Convert a git URL to a filesystem-safe slug.
   * "https://github.com/notno/AgentCom.git" -> "notno-AgentCom"
   */
  _urlToSlug(url) {
    // Strip protocol, .git suffix, and special chars
    let slug = url
      .replace(/^https?:\/\//, '')
      .replace(/^git@[^:]+:/, '')
      .replace(/\.git$/, '')
      .replace(/\//g, '-')
      .replace(/[^a-zA-Z0-9_-]/g, '-');
    return slug;
  }
}

module.exports = { WorkspaceManager };
```

### Pattern 6: Threading Workspace Through Dispatch
**What:** Before dispatching a task for execution, resolve the workspace path and override `config.repo_dir` so all downstream code (shell executor, verification, git workflow) uses the correct directory.
**When to use:** In `executeTask()` in index.js, before calling `executeWithVerification`.
**Example:**
```javascript
// In HubConnection.executeTask(task):
async executeTask(task) {
  // Resolve workspace for this task's repo
  let effectiveConfig = { ..._config };
  if (task.repo && _workspaceManager) {
    try {
      const wsDir = _workspaceManager.ensureWorkspace(task.repo);
      effectiveConfig.repo_dir = wsDir;
      log('info', 'workspace_resolved', {
        task_id: task.task_id,
        repo: task.repo,
        workspace: wsDir
      });
    } catch (err) {
      log('error', 'workspace_resolve_failed', {
        task_id: task.task_id,
        repo: task.repo,
        error: err.message
      });
      this.sendTaskFailed(task.task_id,
        `Workspace setup failed for ${task.repo}: ${err.message}`);
      _queue.active = null;
      saveQueue(QUEUE_PATH, _queue);
      return;
    }
  }

  // Pass effectiveConfig (with resolved repo_dir) to execution
  const result = await executeWithVerification(task, effectiveConfig, ...);
  // ...
}
```

### Anti-Patterns to Avoid
- **One DETS key per repo with separate priority counter:** Makes reordering a multi-step mutation that can be interrupted. Use a single ordered list.
- **Cloning repos in the scheduler (hub side):** The hub does not need the repo files. Cloning happens only on the sidecar side.
- **Sharing a single clone across tasks from different repos:** Each repo gets its own workspace directory. Never switch branches in a shared directory -- use independent clones.
- **Blocking task dispatch on slow git clone:** For a first-time workspace clone, the sidecar will block during clone. This is acceptable -- it only happens once per repo per sidecar. After that, pulls are fast.
- **Modifying the original `_config` object:** Create a shallow copy with overridden `repo_dir` for each task. Never mutate the global `_config`.
- **Filtering tasks in TaskQueue instead of Scheduler:** The queue stores all tasks. Filtering belongs in the scheduler where scheduling decisions are made. Paused repos stay in queue for when they are unpaused.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Priority-ordered list persistence | Custom file-based ordering with locks | DETS single-key ordered list | Atomic swap, existing pattern, crash-safe with sync |
| Git clone/pull | Custom HTTP download + unzip | `git clone` and `git fetch && git reset --hard` via `child_process` | Git handles auth, partial failures, delta compression natively |
| Repo URL slug generation | Manual string parsing with regex | Simple replace chain (`/` -> `-`, strip `.git`) | URL structure is predictable; no need for a slug library |
| Dashboard table with reorder | Custom drag-and-drop or complex JS | Up/down arrow buttons per row (same as priority lanes) | Matches existing dashboard patterns; reordering is infrequent |
| PubSub-driven dashboard updates | Custom polling from dashboard | Phoenix.PubSub broadcast + DashboardSocket handler | Existing pipeline used by every dashboard section |

**Key insight:** This phase introduces one genuinely new capability (sidecar workspace management). Everything else -- the DETS registry, HTTP API, validation schemas, scheduler filtering, dashboard table, PubSub events -- is direct assembly of patterns already established in the codebase.

## Common Pitfalls

### Pitfall 1: Non-Atomic Reorder Corruption
**What goes wrong:** If repos are stored as individual DETS keys with a `priority` integer, reordering requires updating multiple keys. A crash between updates leaves inconsistent priorities (two repos at priority 1, or a gap).
**Why it happens:** Multi-key DETS updates are not atomic.
**How to avoid:** Store the entire ordered list as a single DETS value. Reorder by manipulating the list in memory, then write it back with one `dets.insert`. One write = atomic.
**Warning signs:** Duplicate priorities in the registry list, repos disappearing from the list.

### Pitfall 2: Workspace Clone Timeout Failing Task
**What goes wrong:** First task for a new repo triggers a git clone. If the repo is large, the clone exceeds the sidecar's task timeout and the task fails.
**Why it happens:** Git clone of a large repo can take minutes. The stuck-task sweep (5 min threshold) may reclaim it.
**How to avoid:** (1) Set a generous timeout for git clone (5 minutes). (2) Send `task_progress` events during clone to keep the task alive (resets `updated_at` on hub). (3) The stuck sweep threshold (5 minutes) should be sufficient for most clones.
**Warning signs:** Tasks failing with timeout errors on first execution against a new repo.

### Pitfall 3: Stale Workspace After Force Push
**What goes wrong:** Someone force-pushes to a repo's main branch. The sidecar's cached clone has diverged history. `git pull` fails with merge conflicts.
**Why it happens:** `git pull` cannot fast-forward when remote history was rewritten.
**How to avoid:** Use `git fetch origin && git reset --hard origin/main` instead of `git pull`. This always matches remote state regardless of local history. This is safe because workspace directories are not for human editing -- they are ephemeral execution sandboxes.
**Warning signs:** Git errors about "diverged branches" in workspace pull.

### Pitfall 4: Dashboard Reorder Sends Stale Position
**What goes wrong:** Two rapid dashboard reorder clicks send overlapping requests. The second request uses a stale position index, placing the repo in the wrong slot.
**Why it happens:** Frontend does not wait for the first reorder response before sending the second.
**How to avoid:** (1) Disable reorder buttons until the pending request completes. (2) The HTTP response includes the full updated list, which the frontend uses to refresh. (3) Use move-up/move-down by one position (not absolute index) to reduce conflict surface.
**Warning signs:** Repos in unexpected positions after rapid clicking.

### Pitfall 5: Paused Repo Tasks Accumulate Forever
**What goes wrong:** A repo is paused, tasks keep being submitted targeting it, the queue grows indefinitely.
**Why it happens:** Paused repos' tasks are skipped by the scheduler but not removed from the queue.
**How to avoid:** (1) The existing task TTL sweep (Phase 19) will expire old queued tasks. (2) Dashboard should show a count of queued tasks per repo, so the admin sees the backlog. (3) Optionally, the submit endpoint could warn when submitting to a paused repo.
**Warning signs:** Queue depth growing while agents are idle.

### Pitfall 6: Config.repo_dir Mutation Across Tasks
**What goes wrong:** The global `_config` object is mutated to set `repo_dir` for one task. A second task arrives before the first completes (shouldn't happen with single-active-task, but could in recovery scenarios), and inherits the wrong repo_dir.
**Why it happens:** JavaScript objects are passed by reference. `_config.repo_dir = wsDir` mutates the shared object.
**How to avoid:** Never mutate `_config`. Create a shallow copy: `const effectiveConfig = { ..._config, repo_dir: wsDir }`. Pass `effectiveConfig` to the execution pipeline.
**Warning signs:** Tasks executing against the wrong repo's workspace.

### Pitfall 7: DETS Table Not in DetsBackup.@tables
**What goes wrong:** The `:repo_registry` DETS table is not included in `DetsBackup`'s `@tables` list, so it never gets backed up or compacted.
**Why it happens:** Forgetting to update the existing DetsBackup module (same pitfall as Phase 18).
**How to avoid:** Add `:repo_registry` to `@tables` in `dets_backup.ex`. Add `table_owner/1` and `get_table_path/1` clauses.
**Warning signs:** `DetsBackup.health_metrics()` does not show the new table.

### Pitfall 8: Repo URL Mismatch Between Hub Registry and Task Field
**What goes wrong:** Hub registry stores `https://github.com/notno/AgentCom.git` but task.repo contains `https://github.com/notno/AgentCom` (no `.git` suffix). Scheduler's repo-is-active check fails because of string mismatch.
**Why it happens:** Git accepts both URL forms. Users may submit either.
**How to avoid:** Normalize repo URLs at both registration time and task submission time. Strip trailing `.git` and trailing `/` before comparison. Store the normalized form.
**Warning signs:** Tasks for a registered repo being treated as if the repo is not in the registry.

## Code Examples

### Example 1: RepoRegistry GenServer Core
```elixir
defmodule AgentCom.RepoRegistry do
  use GenServer
  require Logger

  @dets_table :repo_registry
  @registry_key :repos

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -- Client API --

  def add_repo(params), do: GenServer.call(__MODULE__, {:add_repo, params})
  def remove_repo(repo_id), do: GenServer.call(__MODULE__, {:remove_repo, repo_id})
  def list_repos, do: GenServer.call(__MODULE__, :list_repos)
  def move_up(repo_id), do: GenServer.call(__MODULE__, {:move, repo_id, :up})
  def move_down(repo_id), do: GenServer.call(__MODULE__, {:move, repo_id, :down})
  def set_status(repo_id, status), do: GenServer.call(__MODULE__, {:set_status, repo_id, status})

  @doc "Return IDs of all active repos (for scheduler filtering)."
  def active_repo_ids do
    GenServer.call(__MODULE__, :active_repo_ids)
  end

  @doc "Return the top-priority active repo, or :none."
  def top_active_repo do
    GenServer.call(__MODULE__, :top_active_repo)
  end

  @doc "Snapshot for dashboard."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  # -- Server callbacks --

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)
    dets_path = Path.join(data_dir(), "repo_registry.dets") |> String.to_charlist()
    {:ok, @dets_table} = :dets.open_file(@dets_table, file: dets_path, type: :set, auto_save: 5_000)
    repos = load_repos()
    Logger.info("repo_registry_started", repo_count: length(repos))
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_repo, params}, _from, state) do
    url = normalize_url(params.url)
    id = url_to_id(url)
    repos = load_repos()

    if Enum.any?(repos, fn r -> r.id == id end) do
      {:reply, {:error, :already_exists}, state}
    else
      entry = %{
        id: id,
        url: url,
        name: Map.get(params, :name, id),
        status: :active,
        added_at: System.system_time(:millisecond),
        added_by: Map.get(params, :added_by, "admin")
      }
      new_repos = repos ++ [entry]
      save_repos(new_repos)
      broadcast_change()
      {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def handle_call({:remove_repo, repo_id}, _from, state) do
    repos = load_repos()
    case Enum.split_with(repos, fn r -> r.id != repo_id end) do
      {remaining, [_removed]} ->
        save_repos(remaining)
        broadcast_change()
        {:reply, :ok, state}
      {_all, []} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_repos, _from, state) do
    {:reply, load_repos(), state}
  end

  @impl true
  def handle_call({:move, repo_id, direction}, _from, state) do
    repos = load_repos()
    idx = Enum.find_index(repos, fn r -> r.id == repo_id end)

    new_repos =
      case {idx, direction} do
        {nil, _} -> repos
        {0, :up} -> repos
        {i, :up} -> swap(repos, i, i - 1)
        {i, :down} when i >= length(repos) - 1 -> repos
        {i, :down} -> swap(repos, i, i + 1)
      end

    save_repos(new_repos)
    broadcast_change()
    {:reply, {:ok, new_repos}, state}
  end

  @impl true
  def handle_call({:set_status, repo_id, status}, _from, state)
      when status in [:active, :paused] do
    repos = load_repos()
    new_repos = Enum.map(repos, fn r ->
      if r.id == repo_id, do: %{r | status: status}, else: r
    end)
    save_repos(new_repos)
    broadcast_change()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:active_repo_ids, _from, state) do
    ids = load_repos()
      |> Enum.filter(fn r -> r.status == :active end)
      |> Enum.map(fn r -> r.url end)
    {:reply, ids, state}
  end

  @impl true
  def handle_call(:top_active_repo, _from, state) do
    result = load_repos()
      |> Enum.find(fn r -> r.status == :active end)
    case result do
      nil -> {:reply, :none, state}
      repo -> {:reply, {:ok, repo}, state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{repos: load_repos()}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@dets_table)
    :ok
  end

  # -- Private helpers --

  defp load_repos do
    case :dets.lookup(@dets_table, @registry_key) do
      [{@registry_key, repos}] when is_list(repos) -> repos
      _ -> []
    end
  end

  defp save_repos(repos) do
    :dets.insert(@dets_table, {@registry_key, repos})
    :dets.sync(@dets_table)
  end

  defp swap(list, i, j) do
    list
    |> List.replace_at(i, Enum.at(list, j))
    |> List.replace_at(j, Enum.at(list, i))
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "repo_registry", {:repo_registry_update, :changed})
  end

  defp normalize_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.trim_trailing(".git")
  end

  defp url_to_id(normalized_url) do
    normalized_url
    |> String.replace(~r{^https?://[^/]+/}, "")
    |> String.replace("/", "-")
  end

  defp data_dir, do: Application.get_env(:agent_com, :data_dir, "priv/data")
end
```

### Example 2: Scheduler Repo Filtering
```elixir
# In Scheduler.try_schedule_all/2, right after fetching queued_tasks:

# Filter out tasks for paused repos
active_repo_urls = AgentCom.RepoRegistry.active_repo_ids()

schedulable_tasks =
  Enum.filter(queued_tasks, fn task ->
    repo = Map.get(task, :repo)
    # Tasks with nil repo always schedulable (backward compat)
    # Tasks with a repo URL must match an active registry entry
    # Tasks whose repo is not in the registry at all are also schedulable
    #   (they may be ad-hoc tasks with a custom repo)
    repo == nil or repo in active_repo_urls or not repo_in_registry?(repo)
  end)

# Replace queued_tasks with schedulable_tasks in do_match_loop call
```

### Example 3: TaskQueue Nil-Repo Resolution
```elixir
# In TaskQueue.handle_call({:submit, params}), when building the task map:
repo = Map.get(params, :repo, Map.get(params, "repo", nil))

# Inherit top-priority active repo when no explicit repo given
repo =
  if is_nil(repo) do
    case AgentCom.RepoRegistry.top_active_repo() do
      {:ok, top_repo} -> top_repo.url
      :none -> nil
    end
  else
    normalize_repo_url(repo)
  end
```

### Example 4: Sidecar Workspace Manager Integration
```javascript
// In index.js startup, after loading config:
const { WorkspaceManager } = require('./lib/workspace-manager');

const agentName = _config.agent_id || 'unknown';
const wsBaseDir = path.join(os.homedir(), '.agentcom', agentName, 'workspaces');
const _workspaceManager = new WorkspaceManager(wsBaseDir);

// In executeTask, before dispatch:
let effectiveConfig = { ..._config };
if (task.repo) {
  try {
    effectiveConfig.repo_dir = _workspaceManager.ensureWorkspace(task.repo);
  } catch (err) {
    this.sendTaskFailed(task.task_id, `Workspace setup failed: ${err.message}`);
    return;
  }
}
// Pass effectiveConfig to executeWithVerification
```

### Example 5: HTTP API Routes
```elixir
# In endpoint.ex, following the existing admin route patterns:

get "/api/admin/repo-registry" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted, do: conn, else:
    send_json(conn, 200, %{"repos" => AgentCom.RepoRegistry.list_repos()})
end

post "/api/admin/repo-registry" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    case Validation.validate_http(:post_repo, conn.body_params) do
      {:ok, _} ->
        params = %{
          url: conn.body_params["url"],
          name: conn.body_params["name"]
        }
        case AgentCom.RepoRegistry.add_repo(params) do
          {:ok, repo} -> send_json(conn, 201, repo)
          {:error, :already_exists} -> send_json(conn, 409, %{"error" => "repo_already_registered"})
        end
      {:error, errors} -> send_validation_error(conn, errors)
    end
  end
end

delete "/api/admin/repo-registry/:repo_id" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted, do: conn, else:
    case AgentCom.RepoRegistry.remove_repo(repo_id) do
      :ok -> send_json(conn, 200, %{"status" => "removed"})
      {:error, :not_found} -> send_json(conn, 404, %{"error" => "not_found"})
    end
end

put "/api/admin/repo-registry/:repo_id/move-up" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted, do: conn, else:
    case AgentCom.RepoRegistry.move_up(repo_id) do
      {:ok, repos} -> send_json(conn, 200, %{"repos" => repos})
    end
end

put "/api/admin/repo-registry/:repo_id/move-down" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted, do: conn, else:
    case AgentCom.RepoRegistry.move_down(repo_id) do
      {:ok, repos} -> send_json(conn, 200, %{"repos" => repos})
    end
end

put "/api/admin/repo-registry/:repo_id/pause" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted, do: conn, else:
    AgentCom.RepoRegistry.set_status(repo_id, :paused)
    send_json(conn, 200, %{"status" => "paused"})
end

put "/api/admin/repo-registry/:repo_id/unpause" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted, do: conn, else:
    AgentCom.RepoRegistry.set_status(repo_id, :active)
    send_json(conn, 200, %{"status" => "active"})
end
```

### Example 6: Validation Schemas for Repo Registry
```elixir
# In Validation.Schemas @http_schemas:
post_repo: %{
  required: %{
    "url" => :string
  },
  optional: %{
    "name" => :string
  },
  description: "Register a new repository in the repo registry."
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single `default_repo` in Config | Priority-ordered repo registry | Phase 23 (now) | Multiple repos with priority, active/paused |
| Single `config.repo_dir` per sidecar | Per-repo workspace cache | Phase 23 (now) | Sidecar can work on multiple repos without manual reconfiguration |
| All queued tasks schedulable | Scheduler filters by repo status | Phase 23 (now) | Paused repos' tasks wait in queue |
| Tasks inherit global default_repo | Tasks inherit top-priority active repo | Phase 23 (now) | Dynamic default based on registry priority |

**Deprecated/outdated:**
- `AgentCom.Config.get(:default_repo)` as the sole repo configuration. After Phase 23, the top-priority active repo in the registry serves this role. The Config key can remain as a fallback for backward compatibility, but the RepoRegistry is the primary source.

## Open Questions

1. **Relationship between existing `default_repo` Config and new RepoRegistry**
   - What we know: `Config.get(:default_repo)` currently sets the single repo URL used during onboarding (add-agent.js) and as the default for nil-repo tasks.
   - What's unclear: Should the existing `default_repo` config be replaced entirely by the top-priority active repo, or should it remain as a fallback?
   - Recommendation: Keep `default_repo` as a bootstrap fallback. When the RepoRegistry has entries, `top_active_repo()` takes precedence. When the registry is empty, fall back to `Config.get(:default_repo)`. This maintains backward compatibility for systems that haven't configured the registry yet.

2. **Preemption policy for lower-priority repo tasks**
   - What we know: The todo document raises whether agents working on a secondary project's task should be interrupted when a primary project task arrives.
   - What's unclear: Whether to implement preemption in this phase.
   - Recommendation: No preemption in Phase 23. Tasks finish normally. The scheduler's existing behavior (assign to idle agents) naturally favors higher-priority repos because tasks for the top-priority repo will be picked up first from the queue. Preemption adds significant complexity (cancel in-flight task, roll back workspace) and should be a separate phase if ever needed.

3. **Sidecar workspace cleanup**
   - What we know: Workspace directories accumulate on disk. Over time, many repos could consume significant space.
   - What's unclear: When to clean up workspaces for repos that are removed from the registry.
   - Recommendation: Do not auto-delete workspaces. A repo might be re-added later. Provide a manual cleanup mechanism (sidecar command or admin API) but defer automatic cleanup to a future phase. Disk space is cheap; data loss is expensive.

4. **How does onboarding (add-agent.js) interact with multi-repo?**
   - What we know: Currently, add-agent.js clones a single repo into `~/.agentcom/<name>/repo/`. The workspace manager uses `~/.agentcom/<name>/workspaces/<slug>/`.
   - What's unclear: Should add-agent.js be updated to use the workspace manager, or can they coexist?
   - Recommendation: Leave add-agent.js as-is for Phase 23. The onboarding clone creates the sidecar's "home" repo. The workspace manager creates additional repos on demand. They coexist in different directories. If `config.repo_dir` points to the onboarded repo and the task has no explicit repo, execution uses the original repo_dir. If the task has a repo field, the workspace manager overrides.

5. **Git authentication for private repos**
   - What we know: The existing add-agent.js clone works because the sidecar host has git credentials configured (SSH key or credential helper).
   - What's unclear: Will the workspace manager's clone work for private repos on the same host?
   - Recommendation: Yes, if the host's git credentials are configured. `execSync('git clone ...')` inherits the process environment, including SSH agent and credential helpers. No additional auth handling needed in the workspace manager.

## Sources

### Primary (HIGH confidence)
- `lib/agent_com/llm_registry.ex` -- DETS GenServer registry pattern (CRUD, health checks, PubSub, snapshot)
- `lib/agent_com/config.ex` -- DETS key-value storage pattern, `default_repo` usage
- `lib/agent_com/task_queue.ex` -- Task map structure, `repo` field (line 244), submit handler
- `lib/agent_com/scheduler.ex` -- Task-to-agent matching loop, `repo` passthrough (line 532), endpoint/resource gathering
- `lib/agent_com/endpoint.ex` -- HTTP admin routes pattern (LLM registry CRUD at lines 60-64), `format_task` helper (line 1380)
- `lib/agent_com/socket.ex` -- `push_task` handler (line 170), `repo` field forwarded in task_assign (line 179)
- `lib/agent_com/dashboard_state.ex` -- Snapshot aggregation, LLM registry integration (line 200-205)
- `lib/agent_com/dashboard.ex` -- LLM Registry UI section (line 934-960), table + add/remove pattern
- `lib/agent_com/validation/schemas.ex` -- Schema definition pattern for HTTP and WS messages
- `lib/agent_com/dets_backup.ex` -- `@tables` list (line 20-30) that must include new DETS tables
- `lib/agent_com/application.ex` -- Supervision tree children list (line 32-57)
- `sidecar/index.js` -- Task assignment handler (line 553), `executeTask` (line 638), `config.repo_dir` usage
- `sidecar/lib/execution/shell-executor.js` -- `cwd: config.repo_dir` (line 128)
- `sidecar/lib/execution/verification-loop.js` -- `config` parameter threaded through (line 134)
- `sidecar/verification.js` -- `config.repo_dir` used as cwd for all checks (lines 82, 97, 122)
- `sidecar/agentcom-git.js` -- `config.repo_dir` as git working directory (lines 18-33, 56)
- `sidecar/add-agent.js` -- Clone step (line 403), config generation (line 468), `repo_dir` setup
- `.planning/todos/done/2026-02-12-multi-project-fallback-queue-for-idle-agent-utilization.md` -- Original design thinking

### Secondary (MEDIUM confidence)
- `.planning/phases/18-llm-registry-host-resources/18-RESEARCH.md` -- DETS + ETS hybrid pattern, DetsBackup integration, dashboard section pattern
- `.planning/phases/17-enriched-task-format/17-RESEARCH.md` -- Task `repo` field design, inherit-plus-override pattern
- `.planning/phases/20-sidecar-execution/20-RESEARCH.md` -- Execution dispatcher, executor interface, config threading

### Tertiary (LOW confidence)
- Workspace pull strategy (`git fetch && git reset --hard origin/main`) -- standard git practice, but interaction with in-progress branches from git-workflow.js needs care. The workspace manager should only pull when no task is active on that workspace.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries already in use in the project, no new deps
- Architecture: HIGH -- all hub-side patterns directly observed in existing codebase (DETS registry, PubSub, HTTP routes, dashboard rendering, validation schemas, supervision tree)
- Sidecar workspace management: HIGH -- git clone/pull via child_process is proven pattern in add-agent.js; config.repo_dir threading is observed in every executor and verification module
- Pitfalls: HIGH -- derived from direct analysis of DETS atomicity, git behavior, and JavaScript reference semantics
- Scheduler repo filtering: HIGH -- simple Enum.filter added to existing try_schedule_all flow, minimal risk

**Research date:** 2026-02-12
**Valid until:** 2026-03-14 (30 days -- stable domain, no external dependencies)
