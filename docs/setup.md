# Setup Guide

This guide walks through everything from installing prerequisites on a fresh Windows machine to a running hub with a connected agent and a completed smoke test. It is written for the solo operator returning after months away -- every step explains what it does and why.

For system architecture and design decisions, see the [Architecture Overview](architecture.md). For monitoring and maintenance once the system is running, see the [Daily Operations Guide](daily-operations.md). For diagnosing problems, see the [Troubleshooting Guide](troubleshooting.md).

## 1. Prerequisites

AgentCom has two runtime components: an Elixir/OTP hub and a Node.js sidecar per agent. Each has its own prerequisites.

### Erlang/OTP 25+

The BEAM virtual machine that runs the hub. AgentCom depends on OTP modules directly -- DETS for persistence (see `AgentCom.TaskQueue`, `AgentCom.Mailbox`, `AgentCom.Config`), `:logger` for the structured logging pipeline, and `:httpc` for HTTP client operations. Without Erlang, none of the hub's 20 supervised GenServers can start.

**Install:**
- **Windows installer:** Download from [erlang.org/downloads](https://www.erlang.org/downloads) and run the installer. Make sure to add Erlang to your PATH when prompted.
- **Chocolatey:** `choco install erlang`

**Verify:** `erl -version` should print the OTP version (25 or higher).

### Elixir ~> 1.14

The language the hub is written in. Elixir provides Mix (the build tool that compiles and runs the project), GenServer (the process abstraction every hub service uses), and Logger (the logging frontend that feeds into LoggerJSON). The `mix.exs` file specifies `elixir: "~> 1.14"` as the minimum version.

**Install:**
- **Windows installer:** Download from [elixir-lang.org/install](https://elixir-lang.org/install.html). The installer bundles the `mix`, `iex`, and `elixir` commands.
- **Chocolatey:** `choco install elixir`

**Verify:** `elixir --version` should show Elixir 1.14+ and the OTP version it is compiled against.

### Node.js 18+

The runtime for agent sidecars. The onboarding script (`sidecar/add-agent.js`) uses `require('node:util').parseArgs` which is only available in Node.js 18+. The sidecar itself uses modern APIs (structured error handling, `node:` prefixed imports) that require this version.

**Install:**
- **nodejs.org:** Download the LTS installer from [nodejs.org](https://nodejs.org/)
- **nvm-windows:** If you manage multiple Node versions, use [nvm-windows](https://github.com/coreybutler/nvm-windows): `nvm install 18` then `nvm use 18`

**Verify:** `node --version` should show v18.x.x or higher.

### npm (bundled with Node.js)

The package manager used for sidecar dependencies. It comes with Node.js -- no separate installation needed. The sidecar's `package.json` declares its dependencies (primarily for the Culture ship name generator used in auto-naming agents).

### pm2 (global)

A process manager that keeps sidecars running. When a sidecar crashes, pm2 automatically restarts it (with configurable backoff). It also provides log management, process monitoring, and startup persistence. Without pm2, a crashed sidecar means a disconnected agent until someone manually restarts it.

**Install:**
```
npm install -g pm2
```

**Verify:** `pm2 --version` should print the version number.

### Optional: jq

A command-line JSON processor used for parsing structured log files during troubleshooting. AgentCom's hub logs are JSON (via LoggerJSON), so `jq` makes filtering and reading them practical. Not required for running the system, but strongly recommended for debugging.

**Install:**
- **Chocolatey:** `choco install jq`
- **Manual:** Download from [jqlang.github.io/jq](https://jqlang.github.io/jq/download/)

### Optional: git

Required if you plan to use the agent git-workflow features (automatic branch creation, PR submission). The sidecar's `git-workflow.js` module calls `git` directly. Not needed for basic task execution.

**Install:**
- Download from [git-scm.com](https://git-scm.com/) or `choco install git`

## 2. Clone and Install

### Clone the Repository

```
git clone <your-agentcom-repo-url> AgentCom
cd AgentCom
```

### Install Elixir Dependencies

```
mix deps.get
```

This fetches and compiles the hub's dependencies:

| Dependency | Purpose |
|-----------|---------|
| `phoenix_pubsub` | Internal event distribution between GenServers (task events, agent state changes, dashboard updates) |
| `bandit` | HTTP/WebSocket server -- handles all API endpoints and agent connections |
| `websock_adapter` | WebSocket upgrade support for Bandit |
| `jason` | JSON encoding/decoding for API responses and WebSocket messages |
| `plug` | HTTP request routing and middleware pipeline |
| `web_push_elixir` | Browser push notifications for dashboard alerts |
| `logger_json` | Structured JSON log formatting with metadata and redaction |
| `ex_doc` | Documentation generation (dev only) -- builds the guide you are reading |

### Install Sidecar Dependencies

```
cd sidecar
npm install
cd ..
```

This installs the sidecar's npm dependencies. The sidecar itself is mostly zero-dependency Node.js (using built-in `http`, `ws`, `fs`, `child_process`), but the onboarding script uses a Culture ship name generator for automatic agent naming.

## 3. Configuration

### config/config.exs

The base configuration file that applies to all environments. Here is what each setting controls:

**Port:**
```elixir
config :agent_com,
  port: String.to_integer(System.get_env("PORT") || "4000"),
  backup_dir: "priv/backups"
```
- `port` -- The HTTP/WebSocket port. Defaults to 4000, overridable via the `PORT` environment variable. This is the port agents connect to and the dashboard is served on.
- `backup_dir` -- Where DETS backup files are stored. Defaults to `priv/backups/` relative to the project root. `AgentCom.DetsBackup` reads this via `Application.get_env(:agent_com, :backup_dir)`.

**Logging:**
```elixir
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic,
    metadata: {:all_except, [:conn, :crash_reason]},
    redactors: [
      {LoggerJSON.Redactors.RedactKeys, ["token", "auth_token", "secret"]}
    ]
  }
```
- The formatter outputs JSON to stdout with all metadata except `:conn` (large Plug struct) and `:crash_reason` (can contain sensitive state).
- The redactor automatically replaces values for keys named "token", "auth_token", or "secret" with `"[REDACTED]"` in log output.
- A separate file handler is added programmatically in `AgentCom.Application` that writes to `priv/logs/agent_com.log` with 10MB rotation and 5 file retention.

**Environment config:**
```elixir
import_config "#{config_env()}.exs"
```
Loads `config/dev.exs`, `config/test.exs`, or `config/prod.exs` depending on `MIX_ENV`. For development, `config/dev.exs` adds no overrides -- dev uses the same JSON logging as production for consistency.

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `PORT` | `4000` | Hub HTTP/WebSocket listen port |
| `ADMIN_AGENTS` | `""` | Comma-separated agent IDs authorized for `POST /api/admin/reset` (hub reset). Leave empty to disable reset endpoint. |
| `MIX_ENV` | `dev` | Elixir environment. Affects log level and which config file loads. Use `dev` for local operation. |

### Data Directories

AgentCom stores data in two locations:

**Project-relative (`priv/`):**
- `priv/tokens.json` -- Agent authentication tokens (managed by `AgentCom.Auth`)
- `priv/task_queue.dets` -- Active task queue
- `priv/task_dead_letter.dets` -- Failed tasks that exhausted retries
- `priv/mailbox.dets` -- Per-agent message inbox
- `priv/message_history.dets` -- Queryable message archive
- `priv/channels.dets` -- Channel metadata and subscriptions
- `priv/channel_history.dets` -- Channel message history
- `priv/logs/agent_com.log` -- Structured JSON log file (10MB x 5 rotation)
- `priv/backups/` -- DETS backup snapshots

**User home (`~/.agentcom/`):**
- `~/.agentcom/data/config.dets` -- Runtime key-value configuration (managed by `AgentCom.Config`)
- `~/.agentcom/data/thread_messages.dets` -- Thread message tracking
- `~/.agentcom/data/thread_replies.dets` -- Thread reply chains
- `~/.agentcom/<agent-name>/` -- Per-agent sidecar installation (created by `add-agent.js`)

All `priv/` directories are created automatically on first startup. The `~/.agentcom/data/` directory is created by `AgentCom.Config` and `AgentCom.Threads` on first access.

## 4. Starting the Hub

### Interactive Mode (Recommended for First Run)

```
iex -S mix
```

This starts the hub inside an interactive Elixir shell. You can inspect state, call functions directly, and see log output in real time. Use this for your first run so you can verify everything is working.

### Background Mode

```
mix run --no-halt
```

Starts the hub without an interactive shell. The `--no-halt` flag keeps the BEAM VM running after compilation (without it, the process would exit immediately since there is no interactive session holding it open).

### What Happens at Startup

When the hub starts, the following happens in order:

1. **Telemetry handlers attach** -- `AgentCom.Telemetry` registers handlers for task, scheduler, socket, backup, and HTTP events. This happens before any child process starts so no early events are missed.
2. **File log handler initializes** -- Creates `priv/logs/` directory and adds a rotating JSON file handler.
3. **ETS tables create** -- `:validation_backoff`, `:rate_limit_buckets`, and `:rate_limit_overrides` tables are created for fast in-process access.
4. **Supervision tree boots** -- 20+ child processes start in dependency order: PubSub first (everything subscribes to it), registries next, then GenServers, and Bandit last (the HTTP server, which accepts external connections only after everything it routes to is running).
5. **DETS tables open** -- Each GenServer that owns a DETS table opens or creates it during `init/1`. First run creates fresh `.dets` files.
6. **Bandit binds to port** -- The HTTP/WebSocket server starts listening on the configured port (default 4000).

See `AgentCom.Application` for the full supervision tree and startup sequence.

### Verify the Hub is Running

**Health check:**
```
curl http://localhost:4000/health
```
Expected response:
```json
{"status":"ok","agents_connected":0}
```

The `agents_connected` count is 0 because no sidecars have connected yet. If you get a connection refused error, check that the hub started without errors and is listening on the expected port.

**Dashboard:**

Open `http://localhost:4000/dashboard` in a browser. You should see the dashboard with empty widgets -- no agents, no tasks, no alerts. The connection indicator in the top-right should show "Connected" (the dashboard opens its own WebSocket to `/ws/dashboard` for real-time updates).

## 5. Agent Onboarding

An agent in AgentCom consists of three parts: a registration (token + identity on the hub), a sidecar process (persistent WebSocket relay), and optionally an agent process (like OpenClaw) that the sidecar wakes to execute tasks. Onboarding creates the first two.

### Option A: Automated Onboarding (Recommended)

The `add-agent.js` script handles the entire flow in one command:

```
node sidecar/add-agent.js --hub http://localhost:4000 --name my-agent
```

This runs 7 steps automatically:

1. **Pre-flight checks** -- Verifies Node.js >= 18, pm2, git, and hub reachability
2. **Register agent** -- Calls `POST /api/onboard/register` to create the agent and get a token
3. **Clone repository** -- Clones the project repo into `~/.agentcom/<agent-name>/repo/`
4. **Generate sidecar config** -- Creates `config.json` with agent_id, token, hub WebSocket URL, and wake command
5. **Install dependencies** -- Runs `npm install` in the sidecar directory
6. **Start pm2 process** -- Creates a pm2 ecosystem config and starts the sidecar as a managed process
7. **Verify with test task** -- Submits a test task and waits up to 30 seconds for completion

If you omit `--name`, the script auto-generates a name from Iain M. Banks Culture ship names (like `gcu-sleeper-service` or `gsu-falling-outside`).

**Where things live after automated onboarding:**
- Agent directory: `~/.agentcom/<agent-name>/`
- Sidecar config: `~/.agentcom/<agent-name>/repo/sidecar/config.json`
- Sidecar logs (pm2): `~/.agentcom/<agent-name>/logs/`
- pm2 process name: `agentcom-<agent-name>`

**If a step fails**, the script saves progress to `~/.agentcom/<agent-name>/.onboard-progress.json`. Resume with:
```
node sidecar/add-agent.js --hub http://localhost:4000 --name my-agent --resume
```

### Reconnecting an Existing Agent

If an agent needs to be re-provisioned (machine reimaged, config lost, moved to a new machine), you can rejoin with the existing identity instead of re-registering. This avoids the 409 "already registered" error and reuses the agent's existing token.

```
node sidecar/add-agent.js --hub http://localhost:4000 --name my-agent --rejoin --token <token>
```

This runs all onboarding steps (pre-flight, clone, config, deps, pm2, verify) but **skips registration** — it uses the provided token instead of requesting a new one from the hub.

**Where to find your token:**
- **TOOLS.md** in your agent's working directory (per-agent OpenClaw config)
- **Progress file:** `~/.agentcom/<agent-name>/.onboard-progress.json` (if it still exists)
- **Admin API:** `GET /admin/tokens` on the hub

If the progress file from a previous onboarding still exists, you can omit `--token` and the script will load it automatically:

```
node sidecar/add-agent.js --hub http://localhost:4000 --name my-agent --rejoin
```

**`--rejoin` vs `--resume`:**
- `--resume` continues an **incomplete** onboarding from where it left off (same machine, partial progress)
- `--rejoin` does a **fresh** setup with an existing agent identity (new machine or lost config, skips registration)

These flags are mutually exclusive.

### Option B: Manual Onboarding

If you prefer to control each step, or if `add-agent.js` does not fit your setup:

**Step 1: Register the agent**

```
curl -X POST http://localhost:4000/api/onboard/register ^
  -H "Content-Type: application/json" ^
  -d "{\"agent_id\":\"my-agent\"}"
```

Response:
```json
{
  "agent_id": "my-agent",
  "token": "generated-token-here",
  "hub_ws_url": "ws://localhost:4000/ws",
  "hub_api_url": "http://localhost:4000"
}
```

Save the `token` value -- you will need it for the sidecar config and all authenticated API calls.

The registration endpoint (`POST /api/onboard/register`) is intentionally unauthenticated. A new agent has no token yet, so requiring one would create a chicken-and-egg problem. See the [Architecture Overview](architecture.md) for more on the authentication model.

**Step 2: Create sidecar config**

Create `sidecar/config.json` (or anywhere your sidecar will run from):

```json
{
  "agent_id": "my-agent",
  "token": "generated-token-here",
  "hub_url": "ws://localhost:4000/ws",
  "hub_api_url": "http://localhost:4000",
  "repo_dir": "",
  "reviewer": "",
  "wake_command": "",
  "capabilities": ["code"],
  "confirmation_timeout_ms": 30000,
  "results_dir": "./results",
  "log_file": "./sidecar.log",
  "log_level": "info"
}
```

**Sidecar configuration fields:**

| Field | Required | Default | Purpose |
|-------|----------|---------|---------|
| `agent_id` | Yes | -- | Agent identifier, must match registration |
| `token` | Yes | -- | Auth token from registration |
| `hub_url` | Yes | -- | WebSocket URL (`ws://host:port/ws`) |
| `hub_api_url` | No | -- | HTTP API URL for REST calls |
| `repo_dir` | No | `""` | Working repository path for git operations |
| `reviewer` | No | `""` | Reviewer agent ID for PR submissions |
| `wake_command` | No | -- | Command to invoke agent process. Supports `${TASK_ID}` and `${TASK_JSON}` interpolation. |
| `capabilities` | No | `[]` | Declared capabilities for scheduler matching (e.g., `["code", "review"]`) |
| `confirmation_timeout_ms` | No | `30000` | How long the sidecar waits for the agent process to accept a task (milliseconds) |
| `results_dir` | No | `./results` | Directory where agent process writes result files |
| `log_file` | No | `./sidecar.log` | Path to structured JSON log file |
| `log_level` | No | `info` | Minimum log level (`debug`, `info`, `warn`, `error`) |

The `wake_command` is what makes an agent actually execute tasks. When the sidecar receives a task assignment, it spawns this command with the task ID and full task JSON interpolated. If `wake_command` is empty, the sidecar accepts tasks but cannot execute them -- useful for testing the connection flow.

**Step 3: Start the sidecar**

Directly:
```
cd sidecar
node index.js
```

Or via pm2 for process management:
```
cd sidecar
pm2 start index.js --name agentcom-my-agent
pm2 save
```

### Verification

After onboarding (either method), verify the agent is connected:

1. **Dashboard:** Open `http://localhost:4000/dashboard` -- the agent should appear with "idle" status
2. **API:** `curl http://localhost:4000/api/agents` should list the agent:
   ```json
   [{"agent_id":"my-agent","status":"idle","capabilities":["code"]}]
   ```
3. **Hub logs:** Check for an `agent_com.agent.connect` event in the log output, confirming the WebSocket handshake completed

If the agent does not appear, check the sidecar logs (`pm2 logs agentcom-my-agent` or the log file at the configured `log_file` path) for connection errors. Common issues: wrong token, wrong hub URL, hub not running. See the [Troubleshooting Guide](troubleshooting.md) for detailed diagnosis.

## 6. Smoke Test Walkthrough

This walkthrough verifies the entire pipeline works end-to-end: task submission, scheduling, assignment, and (optionally) execution.

### Step 1: Submit a Task

```
curl -X POST http://localhost:4000/api/tasks ^
  -H "Authorization: Bearer <token>" ^
  -H "Content-Type: application/json" ^
  -d "{\"description\":\"Test task\",\"priority\":\"normal\"}"
```

Replace `<token>` with the token from agent registration. The response includes a `task_id`.

What happens: The task enters `AgentCom.TaskQueue` in "queued" status. TaskQueue persists it to the `task_queue` DETS table and broadcasts a `:task_submitted` event via PubSub.

### Step 2: Observe Scheduling

The `AgentCom.Scheduler` receives the PubSub event and immediately attempts to match the task to an idle agent. If your agent from the onboarding step is connected and idle, the task should be assigned within milliseconds.

**Check the dashboard:** The task should appear as "assigned" to your agent.

**Check via API:**
```
curl "http://localhost:4000/api/tasks?status=assigned"
```

**Check hub logs:** Look for `scheduler_attempt` and `task_assigned` telemetry events. With `jq`:
```
jq "select(.telemetry_event == \"agent_com.scheduler.attempt\")" priv/logs/agent_com.log
```

If the task stays "queued", check that your agent is connected and idle via `GET /api/agents`. If no idle agents are available, the Scheduler queues the attempt and retries on its 30-second sweep cycle.

### Step 3: Observe Execution (if wake_command is configured)

If the sidecar has a `wake_command` configured, it spawns the agent process with the task details. The agent runs, produces a result, and the sidecar relays it back to the hub.

```
curl http://localhost:4000/api/tasks/<task_id> ^
  -H "Authorization: Bearer <token>"
```

The task should show `"status": "completed"` with the agent's result.

### Step 4: If No wake_command

If `wake_command` is empty or not configured, the task will stay in "assigned" status. This is expected and still confirms that the scheduling pipeline works correctly: the task was submitted, picked up by the Scheduler, and pushed to the correct agent's sidecar. The sidecar accepted it but has no way to execute it.

This is a valid smoke test result -- it proves the hub, scheduler, WebSocket relay, and sidecar are all functioning. Actual task execution depends on having an agent process (like OpenClaw) configured via `wake_command`.

### Step 5: Check Metrics

```
curl http://localhost:4000/api/metrics
```

The response includes queue depth, agent states, task duration histograms, and error rates. After the smoke test, you should see the task reflected in the throughput counters. See `AgentCom.MetricsCollector` for the full snapshot shape.

### Step 6: Check Dashboard

Open `http://localhost:4000/dashboard`. All widgets should reflect the activity:
- Queue depth chart shows the task flowing through
- Agent state shows your agent's status
- Task list shows the submitted task with its current status
- If any alerts fired (they should not on a clean smoke test), they appear in the alert banner

If everything checks out, the system is operational. See the [Daily Operations Guide](daily-operations.md) for ongoing monitoring and the [Troubleshooting Guide](troubleshooting.md) if anything did not work as expected.
