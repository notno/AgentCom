# Phase 8: Onboarding - Research

**Researched:** 2026-02-11
**Domain:** CLI scripting, agent provisioning, hub API extensions, pm2 process management
**Confidence:** HIGH

## Summary

Phase 8 delivers three Node.js CLI tools (`add-agent`, `remove-agent`, `agentcom-submit`) plus two hub-side API extensions (agent registration endpoint and default config endpoint). The onboarding flow is sequential and deterministic: pre-flight checks, register with hub, clone repo, generate config, install deps, start pm2, verify with test task. The hub needs a new unauthenticated registration endpoint (`POST /api/onboard/register`) because the existing `/admin/tokens` requires a Bearer token -- creating a chicken-and-egg problem for new agents. The hub also needs a config endpoint for `default_repo` so the onboarding script can fetch the repo URL without hardcoding it.

The codebase already has all the patterns needed: `agentcom-git.js` demonstrates the CLI-as-JSON-output pattern, `ecosystem.config.js` shows the pm2 configuration, `config.json.example` is the template, and `AgentCom.Config` (DETS-backed GenServer) is ready for new key-value pairs. The existing `culture-ships` npm package provides Culture ship names. Node.js 22's built-in `util.parseArgs` handles CLI flag parsing with zero dependencies.

**Primary recommendation:** Build three Node.js scripts (add-agent.js, remove-agent.js, agentcom-submit.js) in the sidecar package, add two hub endpoints (registration + config), use `child_process.execSync` for pm2/git CLI calls rather than pm2's programmatic API, and embed a Culture ship name list directly in the script (avoiding an npm dependency for a static list).

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Script interface
- Node script (part of the sidecar package), not bash
- Fully non-interactive -- everything via flags/args, no prompts
- Invocation: `add-agent <name> --hub <url>` (extensible flag-based)
- Script runs on the agent machine (SSH in first, then run locally)
- Full setup: registers with hub, generates config, clones repo, installs deps, starts pm2, verifies
- Agent names auto-generated as Culture ship names (e.g., gcu-sleeper-service) -- fun, on-brand, unique

#### Config templating
- Script needs only `--hub <url>` from the user; agent name is auto-generated
- Auth token obtained automatically by calling hub registration API
- Repo URL fetched from hub's default repo config (hub stores this in a config file)
- Install directory: `~/.agentcom/<agent-name>/`
- Capabilities default to general-purpose (all agents identical, no specialization)
- Wake command auto-templated -- requires OpenClaw pre-installed (script checks and fails if missing)
- Hub needs a new config file for default settings (default_repo, etc.)

#### Verification depth
- Full round-trip: submits a trivial test task, waits for agent to pick it up and complete it
- 30-second timeout for test task completion -- hard fail if not completed
- Test task cleaned up on success (remove task, delete test branch/PR, no artifacts)
- Step-by-step log output: `[1/N] Registering agent... done` for each step

#### Error recovery
- Fail fast with resume flag: stop immediately on failure, save progress
- Re-running with `--resume` skips completed steps
- Hard fail if test task doesn't complete -- agent registered but not verified
- Pre-flight checks at Claude's discretion (hub reachable, OpenClaw installed, Node version, etc.)
- `remove-agent` command for clean teardown (deregister, stop pm2, delete directory)

#### Task submission CLI
- Include `agentcom submit` command as part of the sidecar/onboarding package
- Full flag set: `--priority`, `--target <agent>`, `--metadata` -- mirrors the API
- Makes the system immediately usable after onboarding
- Quick-start commands printed after successful onboarding (how to submit tasks, check status, view dashboard)

### Claude's Discretion
- Sidecar dependency installation approach (npm install vs pre-built package)
- Pre-flight check selection (which checks, how thorough)
- Culture ship name generation implementation
- Exact step ordering during onboarding
- Quick-start cheat-sheet content and formatting

### Deferred Ideas (OUT OF SCOPE)
- Live conversation with agents (real-time chat through AgentCom) -- new capability, own phase
- Agent capability specialization / skill-based routing -- not needed for v1, all agents general-purpose
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Node.js built-in `util.parseArgs` | Node 22+ (stable since v20) | CLI argument parsing | Zero dependencies, built into Node.js, handles flags/positionals |
| Node.js built-in `child_process` | Node 22+ | Execute pm2, git, npm, openclaw commands | Already used throughout sidecar codebase |
| Node.js built-in `fs` | Node 22+ | File operations (config generation, progress tracking) | Standard, no deps needed |
| Node.js built-in `http`/`https` | Node 22+ | HTTP calls to hub API (register, submit task, fetch config) | Zero deps, simple JSON API calls |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| pm2 (CLI) | ^5.x (globally installed) | Process management | Called via `execSync('pm2 start ...')`, not programmatic API |
| git (CLI) | Any | Clone repo | Called via `execSync('git clone ...')` |
| ws | ^8.19.0 | WebSocket client for verification | Already a sidecar dependency, used for test task polling |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `util.parseArgs` | commander/yargs | Adds npm dependency; parseArgs sufficient for simple flag set |
| pm2 CLI via execSync | pm2 programmatic API | Programmatic API requires `pm2` as npm dep; CLI is simpler for one-shot setup |
| Embedded Culture name list | `culture-ships` npm package | Package is 7+ years old, tiny; embedding avoids a dependency for static data |
| Built-in `http` module | `node-fetch` / `axios` | Adds npm dependency; raw http is fine for simple JSON POST/GET calls |

### Recommendations (Claude's Discretion)

**Dependency installation approach:** Use `npm install --production` in the cloned repo's `sidecar/` directory. This is the existing pattern (see `start.sh` line 16). No pre-built package needed -- the sidecar package.json already lists minimal deps (ws, write-file-atomic, chokidar).

**Culture ship name generation:** Embed a curated list of ~60 Culture ship names directly in the add-agent script as a const array. Names follow the existing pattern (e.g., `gcu-conditions-permitting`, `gcu-sleeper-service`). Prefix is always `gcu-` (General Contact Unit) for uniformity. Select randomly, check hub for collisions via `/api/agents` before using. This avoids an npm dependency for a static list that never changes.

**Pre-flight checks:** Run these checks before any mutations:
1. Node.js version >= 18 (for util.parseArgs)
2. pm2 installed globally (`pm2 --version`)
3. git installed (`git --version`)
4. openclaw installed (`openclaw --version`)
5. Hub reachable (`GET /health`)
6. Install directory doesn't already exist (unless `--resume`)

**Quick-start cheat-sheet:** Print after successful onboarding:
```
Agent gcu-sleeper-service is online!

Submit a task:
  agentcom-submit --hub http://hub:4000 --description "Fix the login bug"

Check status:
  curl http://hub:4000/api/tasks?status=queued
  curl http://hub:4000/api/agents

Dashboard:
  http://hub:4000/dashboard
```

## Architecture Patterns

### Recommended Project Structure
```
sidecar/
├── index.js               # Existing sidecar process
├── agentcom-git.js        # Existing git workflow CLI
├── add-agent.js           # NEW: onboarding script
├── remove-agent.js        # NEW: teardown script
├── agentcom-submit.js     # NEW: task submission CLI
├── culture-names.js       # NEW: ship name list + generator
├── ecosystem.config.js    # Existing pm2 config (template for new agents)
├── config.json.example    # Existing config template
├── package.json           # Existing (no new deps needed)
└── ...
```

### Pattern 1: Step-Based Provisioning with Resume

**What:** Each onboarding step is idempotent and tracked in a progress file. On failure, re-running with `--resume` skips completed steps.

**When to use:** Any multi-step setup that can fail at any point.

**Example:**
```javascript
// Progress file: ~/.agentcom/<agent-name>/.onboard-progress.json
const STEPS = [
  'preflight',      // Pre-flight checks
  'register',       // Register with hub, get token
  'clone',          // Clone repo
  'config',         // Generate config.json
  'install',        // npm install
  'pm2_start',      // Start pm2 process
  'verify'          // Submit test task, wait for completion
];

function loadProgress(installDir) {
  const progressFile = path.join(installDir, '.onboard-progress.json');
  try {
    return JSON.parse(fs.readFileSync(progressFile, 'utf8'));
  } catch {
    return { completed: [], agent_id: null, token: null };
  }
}

function saveProgress(installDir, progress) {
  const progressFile = path.join(installDir, '.onboard-progress.json');
  fs.writeFileSync(progressFile, JSON.stringify(progress, null, 2));
}

function stepLog(stepNum, totalSteps, message) {
  console.log(`[${stepNum}/${totalSteps}] ${message}`);
}
```

### Pattern 2: Hub Registration API (New Endpoint)

**What:** The hub needs a new endpoint for agent self-registration. The existing `POST /admin/tokens` requires Bearer auth -- but a new agent has no token yet (chicken-and-egg problem).

**When to use:** First-time agent registration.

**Design decision:** Add `POST /api/onboard/register` that accepts `{ "agent_id": "gcu-xxx" }` and returns `{ "agent_id": "gcu-xxx", "token": "abc...", "config": { "default_repo": "...", "hub_ws_url": "ws://..." } }`. This endpoint should be rate-limited or guarded by a shared secret (e.g., `--secret` flag on the onboarding script, checked by the hub).

**Example (Hub-side Elixir):**
```elixir
post "/api/onboard/register" do
  case conn.body_params do
    %{"agent_id" => agent_id, "secret" => secret} ->
      if secret == onboard_secret() do
        {:ok, token} = AgentCom.Auth.generate(agent_id)
        default_repo = AgentCom.Config.get(:default_repo) || ""
        hub_ws_url = "ws://#{conn.host}:#{conn.port}/ws"

        send_json(conn, 201, %{
          "agent_id" => agent_id,
          "token" => token,
          "config" => %{
            "default_repo" => default_repo,
            "hub_ws_url" => hub_ws_url,
            "hub_api_url" => "http://#{conn.host}:#{conn.port}"
          }
        })
      else
        send_json(conn, 403, %{"error" => "invalid_onboard_secret"})
      end
    _ ->
      send_json(conn, 400, %{"error" => "missing required fields: agent_id, secret"})
  end
end
```

**Alternative (simpler):** Since this is a private network system, the registration endpoint can simply be unauthenticated (matching the existing pattern of `/health`, `/api/agents`, `/api/dashboard/state` which have no auth). The hub trusts its network boundary. This is simpler and matches the existing design philosophy.

**Recommendation:** Unauthenticated registration endpoint. The system already trusts its network (dashboard has no auth, health has no auth). Adding a shared secret is unnecessary complexity for a private multi-agent system where you SSH into machines to run the script.

### Pattern 3: Config Generation from Template

**What:** Generate a sidecar config.json from template values obtained from the hub.

**Example:**
```javascript
function generateConfig(agentId, token, hubUrl, repoDir) {
  return {
    agent_id: agentId,
    token: token,
    hub_url: hubUrl.replace(/^http/, 'ws') + '/ws',
    hub_api_url: hubUrl,
    repo_dir: repoDir,
    reviewer: '',
    wake_command: `openclaw agent --message "Wink wink, nudge nudge. :Task: \${TASK_JSON}" --session-id \${TASK_ID}`,
    capabilities: ['code'],
    confirmation_timeout_ms: 30000,
    results_dir: './results',
    log_file: './sidecar.log'
  };
}
```

### Pattern 4: Test Task Verification via Polling

**What:** Submit a test task via HTTP, then poll the task status API until it completes or times out.

**Example:**
```javascript
async function verifyTestTask(hubUrl, token, agentId) {
  // Submit test task
  const task = await httpPost(`${hubUrl}/api/tasks`, {
    description: `[onboarding-test] verify ${agentId}`,
    priority: 'urgent',
    metadata: { onboarding_test: true, agent: agentId }
  }, token);

  // Poll for completion (30s timeout)
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const status = await httpGet(`${hubUrl}/api/tasks/${task.task_id}`, token);
    if (status.status === 'completed') {
      // Cleanup: task is done
      return true;
    }
    if (status.status === 'dead_letter') {
      return false;
    }
    await sleep(2000);
  }
  return false; // Timeout
}
```

### Pattern 5: pm2 Ecosystem Config for Dynamic Agent Install

**What:** Each agent installation gets its own pm2 ecosystem config pointing to the correct sidecar directory.

**Key detail:** The existing `ecosystem.config.js` uses `__dirname` for cwd, so it works from any location. The onboarding script can copy this file into the agent's install directory. The pm2 process name should include the agent name for unique identification (e.g., `agentcom-gcu-sleeper-service`).

**Example:**
```javascript
// Modified ecosystem.config.js for per-agent installs
module.exports = {
  apps: [{
    name: `agentcom-${agentId}`,  // Unique per agent
    script: process.platform === 'win32' ? 'start.bat' : 'start.sh',
    cwd: __dirname,
    interpreter: process.platform === 'win32' ? 'cmd' : '/bin/bash',
    interpreter_args: process.platform === 'win32' ? '/c' : '',
    autorestart: true,
    max_restarts: 50,
    min_uptime: 5000,
    restart_delay: 2000,
    max_memory_restart: '200M',
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    error_file: 'logs/sidecar-error.log',
    out_file: 'logs/sidecar-out.log',
    merge_logs: true,
    env: { NODE_ENV: 'production' }
  }]
};
```

### Anti-Patterns to Avoid
- **Interactive prompts:** The script must be fully non-interactive. No readline, no inquirer. Everything via flags.
- **pm2 programmatic API as dependency:** Adding `pm2` as an npm dependency to call it programmatically is unnecessary overhead. Shell out to `pm2` CLI via `execSync` -- it's simpler and the script only runs once.
- **Hardcoding hub URL or repo URL:** These come from flags (`--hub`) and the hub config API. Never bake them into the script.
- **Generating ecosystem.config.js dynamically:** Instead, use the existing template but with a dynamically written `config.json` that the sidecar reads. The ecosystem config is the same for all agents.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| CLI arg parsing | Custom process.argv parsing | `util.parseArgs` (Node.js built-in) | Handles flags, types, defaults correctly |
| Culture ship names | AI-generated names | Curated list from Iain M. Banks novels | Authentic, finite set, collision-checkable |
| HTTP requests | Raw net.Socket handling | Node.js `http`/`https` module with JSON helpers | Already used pattern in test scripts |
| Process management | Custom daemon code | pm2 CLI via child_process | pm2 handles restart, logging, persistence |
| Token generation | Custom crypto in Node.js | Hub's `AgentCom.Auth.generate/1` via API | Hub owns the token store, not the agent |

**Key insight:** The onboarding script is an orchestrator -- it calls existing systems (hub API, git, npm, pm2) rather than reimplementing any of them. Keep it thin.

## Common Pitfalls

### Pitfall 1: Registration Chicken-and-Egg
**What goes wrong:** `POST /admin/tokens` requires a Bearer token. A new agent has no token. Script can't register.
**Why it happens:** The hub was designed with authenticated endpoints; registration was assumed manual (mix task or PowerShell script).
**How to avoid:** Add a new unauthenticated `POST /api/onboard/register` endpoint on the hub. Or accept a bootstrap token via `--token` flag.
**Warning signs:** 401 errors during onboarding when no token is available.

### Pitfall 2: pm2 Process Name Collisions
**What goes wrong:** All agents use pm2 process name `agentcom-sidecar` (from existing ecosystem.config.js). Can't run multiple agents on the same machine.
**Why it happens:** The existing ecosystem.config.js hardcodes the name.
**How to avoid:** Generate per-agent ecosystem config with name `agentcom-<agent-id>` (e.g., `agentcom-gcu-sleeper-service`). Or modify the ecosystem template to read agent_id from config.json dynamically.
**Warning signs:** pm2 shows only one sidecar process when multiple agents should be running.

### Pitfall 3: Agent Name Collisions
**What goes wrong:** Random Culture name already exists in the hub. Two agents get the same name.
**Why it happens:** Random selection from finite list without collision checking.
**How to avoid:** After generating a name, call `GET /api/agents` and `GET /admin/tokens` to check for existing agents with that name. Retry with different name if collision detected.
**Warning signs:** Hub returns error on token generation for duplicate agent_id.

### Pitfall 4: Test Task Verification Timing
**What goes wrong:** Test task submitted before the sidecar is fully connected and identified. Scheduler never assigns it.
**Why it happens:** pm2 starts the sidecar asynchronously. The script submits the test task before the sidecar WebSocket connection is established.
**How to avoid:** After `pm2 start`, poll `GET /api/agents` until the new agent appears with status `idle`. Only then submit the test task. Add a 10-second timeout for this polling.
**Warning signs:** Test task stays in `queued` state and times out.

### Pitfall 5: Windows Path Separators
**What goes wrong:** Path.join on Windows uses backslashes, but git/npm commands may expect forward slashes.
**Why it happens:** Windows vs Unix path conventions.
**How to avoid:** Use `path.posix.join` for URLs, `path.join` for filesystem. The existing codebase handles this (see `start.bat` vs `start.sh` pattern).
**Warning signs:** "file not found" errors with backslash-containing paths on Windows.

### Pitfall 6: Hub Default Config Not Set
**What goes wrong:** Hub has no `default_repo` configured. Script fetches empty string, tries to clone empty URL.
**Why it happens:** Hub config is DETS-backed; `default_repo` doesn't exist until explicitly set.
**How to avoid:** Pre-flight check: fetch hub config, fail if `default_repo` is empty. Provide a `--repo` flag as override. Print clear error: "Set default repo on hub: PUT /api/config/default-repo".
**Warning signs:** Empty or missing repo_url in hub config response.

### Pitfall 7: Test Task Cleanup on Git-Enabled Agent
**What goes wrong:** Test task creates a git branch and PR (via agentcom-git integration). These artifacts persist after onboarding.
**Why it happens:** The agent has `repo_dir` configured, so the sidecar runs `agentcom-git start-task` and `agentcom-git submit` for the test task.
**How to avoid:** After test task verification, delete the test branch (`git push origin --delete <branch>`) and close the test PR (`gh pr close <url>`). Or: submit the test task with metadata `{ "skip_git": true }` and have the sidecar respect that flag (requires minor sidecar change).
**Warning signs:** Orphaned test branches and PRs in the repository after each onboarding.

### Pitfall 8: Remove-Agent Incomplete Cleanup
**What goes wrong:** `remove-agent` stops pm2 but doesn't revoke the token. Old token can still authenticate.
**Why it happens:** Forgetting to call the hub API for token revocation.
**How to avoid:** `remove-agent` sequence: stop pm2, delete pm2 from saved list, call `DELETE /admin/tokens/<agent_id>`, delete install directory. Need the hub token for the revocation call -- read it from config.json before deleting.
**Warning signs:** Removed agent's token still appears in `GET /admin/tokens`.

## Code Examples

Verified patterns from the existing codebase:

### HTTP Request Helper (Based on existing scripts pattern)
```javascript
// Source: Adapted from sidecar patterns + Node.js http module
const http = require('http');
const https = require('https');

function httpRequest(method, url, body, token) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const client = parsed.protocol === 'https:' ? https : http;

    const options = {
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname + parsed.search,
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { 'Authorization': `Bearer ${token}` } : {})
      }
    };

    const req = client.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    });

    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}
```

### CLI Argument Parsing (util.parseArgs)
```javascript
// Source: Node.js v22 built-in util.parseArgs
const { parseArgs } = require('node:util');

// add-agent CLI
const { values, positionals } = parseArgs({
  options: {
    hub: { type: 'string', short: 'h' },
    name: { type: 'string', short: 'n' },     // Override auto-generated name
    repo: { type: 'string', short: 'r' },     // Override hub default_repo
    resume: { type: 'boolean', default: false },
    help: { type: 'boolean', default: false }
  },
  allowPositionals: false,
  strict: true
});
```

### Existing Config Template (from config.json.example)
```javascript
// Source: sidecar/config.json.example
{
  "agent_id": "my-agent",
  "token": "paste-token-here",
  "hub_url": "ws://hub-hostname:4000/ws",
  "hub_api_url": "http://hub-hostname:4000",
  "repo_dir": "/path/to/agent/working/repo",
  "reviewer": "flere-imsaho",
  "wake_command": "openclaw agent --message \"Task: ${TASK_JSON}\" --session-id ${TASK_ID}",
  "capabilities": ["code"],
  "confirmation_timeout_ms": 30000,
  "results_dir": "./results",
  "log_file": "./sidecar.log"
}
```

### Existing pm2 Ecosystem Config (from ecosystem.config.js)
```javascript
// Source: sidecar/ecosystem.config.js
module.exports = {
  apps: [{
    name: 'agentcom-sidecar',
    script: process.platform === 'win32' ? 'start.bat' : 'start.sh',
    cwd: __dirname,
    interpreter: process.platform === 'win32' ? 'cmd' : '/bin/bash',
    interpreter_args: process.platform === 'win32' ? '/c' : '',
    autorestart: true,
    max_restarts: 50,
    min_uptime: 5000,
    restart_delay: 2000,
    max_memory_restart: '200M',
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    error_file: 'logs/sidecar-error.log',
    out_file: 'logs/sidecar-out.log',
    merge_logs: true,
    env: { NODE_ENV: 'production' }
  }]
};
```

### Existing Token Generation API (from endpoint.ex)
```elixir
# Source: lib/agent_com/endpoint.ex, POST /admin/tokens
post "/admin/tokens" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    case conn.body_params do
      %{"agent_id" => agent_id} ->
        {:ok, token} = AgentCom.Auth.generate(agent_id)
        send_json(conn, 201, %{"agent_id" => agent_id, "token" => token})
      _ ->
        send_json(conn, 400, %{"error" => "missing required field: agent_id"})
    end
  end
end
```

### Shell Command Execution Pattern (from agentcom-git.js)
```javascript
// Source: sidecar/agentcom-git.js
function runCommand(cmd, opts = {}) {
  try {
    return execSync(cmd, {
      encoding: 'utf-8',
      shell: true,
      timeout: 60000,
      windowsHide: true,
      cwd: opts.cwd
    }).trim();
  } catch (err) {
    const stderr = (err.stderr || '').trim();
    throw new Error(`${cmd.split(' ')[0]} failed: ${stderr || err.message}`);
  }
}
```

## Existing Hub Interfaces the Onboarding Script Must Use

| Endpoint | Method | Auth | Purpose | Used By |
|----------|--------|------|---------|---------|
| `/health` | GET | No | Check hub is reachable | Pre-flight |
| `/admin/tokens` | POST | Bearer | Generate token (existing) | Fallback if no registration endpoint |
| `/admin/tokens/:agent_id` | DELETE | Bearer | Revoke token | remove-agent |
| `/api/agents` | GET | No | Check agent name collision | add-agent |
| `/api/tasks` | POST | Bearer | Submit test task / user tasks | Verification + agentcom-submit |
| `/api/tasks/:task_id` | GET | Bearer | Poll test task status | Verification |
| `/api/config/heartbeat-interval` | GET | Bearer | Pattern for config API | Reference pattern |

### New Hub Endpoints Needed

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `POST /api/onboard/register` | POST | None (network trust) | Register agent, return token + hub config |
| `GET /api/config/default-repo` | GET | None | Fetch default repo URL for cloning |
| `PUT /api/config/default-repo` | PUT | Bearer | Set default repo URL (admin setup) |

## Onboarding Step Sequence (Recommended)

```
add-agent --hub http://hub:4000

[1/8] Pre-flight checks...
  - Node.js v22.18.0 ✓
  - pm2 v5.x.x ✓
  - git v2.x.x ✓
  - openclaw v1.x.x ✓
  - Hub reachable at http://hub:4000 ✓
  done

[2/8] Generating agent name...
  - Selected: gcu-sleeper-service
  - No collisions found
  done

[3/8] Registering with hub...
  - POST http://hub:4000/api/onboard/register
  - Token: 3a4b5c6d... (saved to progress)
  done

[4/8] Cloning repository...
  - Repo: https://github.com/user/AgentCom.git
  - Destination: ~/.agentcom/gcu-sleeper-service/
  done

[5/8] Generating config...
  - Created: ~/.agentcom/gcu-sleeper-service/sidecar/config.json
  done

[6/8] Installing dependencies...
  - npm install --production in sidecar/
  done

[7/8] Starting pm2 process...
  - pm2 start ecosystem.config.js (name: agentcom-gcu-sleeper-service)
  - pm2 save
  - Waiting for agent to appear on hub... ✓ (idle)
  done

[8/8] Verification: test task round-trip...
  - Submitted test task: task-abc123
  - Waiting for completion (30s timeout)...
  - Task completed in 8.2s ✓
  - Cleaning up test artifacts...
  done

✓ Agent gcu-sleeper-service is online and verified!

Quick start:
  Submit a task:  node sidecar/agentcom-submit.js --hub http://hub:4000 --description "your task"
  Check agents:   curl http://hub:4000/api/agents
  Dashboard:      http://hub:4000/dashboard
```

## Remove-Agent Step Sequence

```
remove-agent --hub http://hub:4000 --name gcu-sleeper-service

[1/4] Stopping pm2 process...
  - pm2 stop agentcom-gcu-sleeper-service
  - pm2 delete agentcom-gcu-sleeper-service
  - pm2 save
  done

[2/4] Revoking hub token...
  - DELETE http://hub:4000/admin/tokens/gcu-sleeper-service
  done

[3/4] Deleting install directory...
  - rm -rf ~/.agentcom/gcu-sleeper-service/
  done

[4/4] Verifying cleanup...
  - Agent not in hub: ✓
  - pm2 process gone: ✓
  - Directory deleted: ✓
  done

✓ Agent gcu-sleeper-service removed.
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual token gen (mix task or PowerShell) | API-based registration | Phase 8 (new) | Enables one-command onboarding |
| Hardcoded repo URL in config | Hub-stored default config | Phase 8 (new) | Single source of truth for repo URL |
| Manual config.json editing | Auto-generated from hub API response | Phase 8 (new) | No copy-paste errors |
| Manual pm2 setup | Scripted pm2 start + save | Phase 8 (new) | Reproducible, resumable setup |

**Deprecated/outdated:**
- `gen_token.ps1`: PowerShell script for manual token generation. Superseded by add-agent script's automatic registration.
- `config.json.example`: Manual copy-and-edit pattern. Superseded by auto-generation during onboarding.
- `mix agent_com.gen_token`: Mix task for token generation. Still works, but onboarding script replaces the use case.

## Open Questions

1. **Token for remove-agent revocation**
   - What we know: `DELETE /admin/tokens/:agent_id` requires Bearer auth. The remove-agent script needs a token to call this.
   - What's unclear: Should remove-agent use the agent's own token (read from config.json before deletion)? Or should it require a separate admin token?
   - Recommendation: Read the agent's own token from `~/.agentcom/<name>/sidecar/config.json` before deleting the directory. Use that token for the revocation call. If the config is already deleted, skip revocation with a warning.

2. **Test task git cleanup**
   - What we know: If the agent has `repo_dir` configured, the test task will trigger git branch creation and PR submission.
   - What's unclear: Should we clean up the test branch/PR programmatically? Or should the test task be specially marked to skip git?
   - Recommendation: Mark the test task with metadata `{ "onboarding_test": true }`. Modify the sidecar's `handleResult` to skip git submit when this metadata flag is set. This is a minor, backward-compatible change to `index.js` (one `if` check). Cleaner than post-hoc cleanup of branches/PRs.

3. **agentcom-submit token management**
   - What we know: `POST /api/tasks` requires Bearer auth. The submit CLI needs a token.
   - What's unclear: Where does the submit CLI get its token? It could use any agent's token.
   - Recommendation: Accept `--token` flag on agentcom-submit. After onboarding, the quick-start output includes the token. Alternatively, the submit CLI could read from a local config file (e.g., `~/.agentcom/submit-config.json`).

4. **Multiple agents on same machine**
   - What we know: Install dir is `~/.agentcom/<agent-name>/`, pm2 process name is `agentcom-<agent-name>`. Both are unique per agent.
   - What's unclear: Do agents share the cloned repo or each get their own copy?
   - Recommendation: Each agent gets its own clone at `~/.agentcom/<agent-name>/`. This avoids git conflicts when multiple agents work on different branches simultaneously. Disk space cost is acceptable.

## Sources

### Primary (HIGH confidence)
- Codebase inspection: `sidecar/index.js` -- full sidecar architecture, config loading, task lifecycle
- Codebase inspection: `lib/agent_com/endpoint.ex` -- all hub HTTP endpoints including `/admin/tokens`
- Codebase inspection: `lib/agent_com/auth.ex` -- token generation/verification/revocation API
- Codebase inspection: `lib/agent_com/config.ex` -- DETS-backed hub config (currently only heartbeat_interval)
- Codebase inspection: `sidecar/agentcom-git.js` -- CLI tool pattern (JSON output, command dispatch)
- Codebase inspection: `sidecar/ecosystem.config.js` -- pm2 configuration pattern
- Codebase inspection: `sidecar/config.json` + `config.json.example` -- config template structure
- Node.js v22 docs: `util.parseArgs` stable API

### Secondary (MEDIUM confidence)
- [PM2 Programmatic API](https://pm2.io/docs/runtime/reference/pm2-programmatic/) -- pm2.connect, pm2.start, pm2.stop signatures
- [PM2 Startup Docs](https://pm2.keymetrics.io/docs/usage/startup/) -- pm2 save, pm2 startup for persistence
- [culture-ships npm](https://github.com/ceejbot/culture-ships) -- Culture ship name list source; MIT license
- [Culture ship names](https://theculture.fandom.com/wiki/List_of_spacecraft) -- Comprehensive ship name reference

### Tertiary (LOW confidence)
- None -- all findings verified against codebase or official documentation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- zero new dependencies, all patterns exist in codebase
- Architecture: HIGH -- step-based provisioning is straightforward, all hub APIs documented
- Pitfalls: HIGH -- identified from direct codebase analysis (auth chicken-and-egg, pm2 naming, git cleanup)
- Hub changes: HIGH -- Config.ex and endpoint.ex patterns are clear and minimal additions needed

**Research date:** 2026-02-11
**Valid until:** 2026-03-11 (stable -- no external library dependencies, all internal patterns)
