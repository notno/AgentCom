# Phase 7: Git Workflow - Research

**Researched:** 2026-02-11
**Domain:** Node.js CLI for git operations, GitHub CLI for PR management, sidecar lifecycle integration
**Confidence:** HIGH

## Summary

Phase 7 adds a CLI tool (`agentcom-git`) bundled with the sidecar that enforces git hygiene for autonomous agents. The tool wraps three commands (`start-task`, `submit`, `status`) around standard `git` and `gh` CLI calls, executed via Node.js `child_process.execSync`. The sidecar orchestrates these commands automatically: `start-task` runs before waking the agent on task assignment, and `submit` runs after the agent reports task completion, creating a fully autonomous branch-per-task workflow.

The implementation is straightforward because the heavy lifting is done by existing, well-established tools: `git` (v2.45.1, already installed) for branch and commit operations, and `gh` CLI (v2.86.0, already installed) for PR creation with labels and reviewer assignment. The `agentcom-git` CLI is a thin Node.js wrapper (~200-300 lines) that orchestrates these tools with proper error handling, exit codes, and structured JSON output for sidecar consumption. No external npm dependencies are needed beyond what is already installed.

The primary integration challenge is wiring `agentcom-git` into the sidecar's task lifecycle (between task assignment and agent wake, and between agent completion and hub notification) while handling failures gracefully -- particularly the "start-task fails but agent should still be woken with a warning" requirement.

**Primary recommendation:** Build `agentcom-git` as a single Node.js file (`sidecar/agentcom-git.js`) using only `child_process.execSync` and built-in modules. The sidecar's `handleTaskAssign` and `handleResult` functions get thin wrappers that call `agentcom-git` commands before/after their current logic. All git/gh operations target the repo directory specified in `config.json` (new `repo_dir` field), not the sidecar directory.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Branch naming & conventions
- Branch format: `{agent}/{task-slug}` (e.g. `gcu/add-login-endpoint`)
- Multiple commits allowed per branch -- no squash on submit
- Task slug source: Claude's discretion (auto-slugify task title or use explicit metadata field)
- Commit messages: conventional commits enforced (`feat(scope): message`, `fix(scope): message`)

#### PR content & metadata
- Full context in PR description: task ID, priority, agent name, original task description, auto-generated diff summary, files changed
- Auto-label PRs by agent (`agent:gcu`) and priority (`priority:urgent`)
- Request review from Flere-Imsaho (gatekeeper GitHub account) -- automated review/merge logic deferred to v2
- Include task ID and direct link to task API endpoint (`/api/tasks/{id}`) in description for cross-referencing

#### Command behavior & modes
- Dirty working tree on `start-task`: fail with error (refuse to start -- agent must have clean state)
- Always `git fetch origin` before branching -- no stale main allowed
- Force-push policy: Claude's discretion (pick safest default)
- Fully non-interactive -- no prompts ever, agents run these autonomously, fail fast on errors

#### Task lifecycle integration
- Sidecar auto-runs `start-task` when receiving a task assignment (before waking the agent -- agent lands on a clean branch)
- Sidecar auto-runs `submit` when agent reports task_complete (fully autonomous pipeline)
- After submit, sidecar reports PR URL to hub (dashboard and task history show PR links)
- If start-task fails (fetch fails, dirty tree): wake agent anyway with warning -- agent can try to resolve or report failure

### Claude's Discretion
- Task slug generation approach (auto-slugify vs metadata field)
- Force-push policy for re-submitting updated branches
- Exact PR description template formatting
- Error message wording and exit codes

### Deferred Ideas (OUT OF SCOPE)
- Automated PR review/merge by Flere-Imsaho -- v2 gatekeeper role
- PR status webhooks (merge/close events back to hub) -- future integration
- Branch cleanup after merge -- could be a post-merge hook, not in scope
</user_constraints>

## Standard Stack

### Core
| Library / Tool | Version | Purpose | Why Standard |
|----------------|---------|---------|--------------|
| git (system) | 2.45.1 | Branch creation, fetch, push, diff, status | Already installed on all agent machines; the definitive VCS tool |
| gh CLI (system) | 2.86.0 | PR creation with labels, reviewers, metadata | Already installed; official GitHub CLI with non-interactive PR creation support |
| Node.js child_process (built-in) | N/A | Execute git/gh commands synchronously | Built-in module; `execSync` with `{encoding: 'utf-8', shell: true}` for cross-platform shell execution |
| Node.js path (built-in) | N/A | Cross-platform path resolution for repo_dir | Built-in; handles Windows backslashes vs Unix forward slashes |
| Node.js fs (built-in) | N/A | Read config, check file existence | Built-in; already used extensively in sidecar |

### Supporting
| Library / Tool | Version | Purpose | When to Use |
|----------------|---------|---------|-------------|
| None required | - | - | All functionality achievable with git, gh, and Node.js built-ins |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| git + gh via execSync | simple-git npm package | Adds dependency for marginal convenience; execSync is simpler for 5-6 discrete commands and matches existing sidecar patterns (see `execCommand` in index.js) |
| gh CLI for PR creation | GitHub REST API via https module | gh CLI handles auth, repo context, and label creation automatically; REST API requires token management and more code |
| Single-file CLI | Separate npm package | Over-engineering for 3 commands; single file matches sidecar's "no build step" philosophy |

**Installation:**
```bash
# No npm install needed -- all tools are system-level and already installed
# Verify prerequisites:
git --version    # 2.45.1
gh --version     # 2.86.0
node --version   # v22.18.0
```

## Architecture Patterns

### Recommended Project Structure
```
sidecar/
├── index.js              # Existing sidecar (modified: add git lifecycle hooks)
├── agentcom-git.js       # NEW: CLI wrapper for git workflow commands
├── config.json           # Modified: add repo_dir, reviewer, hub_api_url fields
├── package.json          # No changes needed (no new dependencies)
├── ecosystem.config.js   # No changes needed
├── start.bat             # No changes needed
├── start.sh              # No changes needed
└── queue.json            # Existing queue state
```

### Pattern 1: CLI Command Dispatcher
**What:** Single entry point that dispatches to command handlers based on argv
**When to use:** For the `agentcom-git` CLI tool with its 3 commands
**Example:**
```javascript
// agentcom-git.js -- invoked as: node agentcom-git.js <command> [options]
'use strict';

const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

// Load config from sidecar directory
const CONFIG_PATH = path.join(__dirname, 'config.json');
const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));

function git(cmd, opts = {}) {
  const cwd = opts.cwd || config.repo_dir;
  try {
    return execSync(`git ${cmd}`, {
      cwd,
      encoding: 'utf-8',
      shell: true,
      timeout: 60000,
      windowsHide: true
    }).trim();
  } catch (err) {
    const stderr = (err.stderr || '').trim();
    throw new Error(`git ${cmd.split(' ')[0]} failed: ${stderr || err.message}`);
  }
}

function gh(cmd, opts = {}) {
  const cwd = opts.cwd || config.repo_dir;
  try {
    return execSync(`gh ${cmd}`, {
      cwd,
      encoding: 'utf-8',
      shell: true,
      timeout: 120000,   // PR creation can be slow
      windowsHide: true
    }).trim();
  } catch (err) {
    const stderr = (err.stderr || '').trim();
    throw new Error(`gh ${cmd.split(' ')[0]} failed: ${stderr || err.message}`);
  }
}

const commands = { 'start-task': startTask, 'submit': submit, 'status': status };
const command = process.argv[2];
if (!commands[command]) {
  console.error(JSON.stringify({ error: `Unknown command: ${command}`, exit_code: 1 }));
  process.exit(1);
}
// Command args passed as JSON on argv[3]
const args = process.argv[3] ? JSON.parse(process.argv[3]) : {};
commands[command](args);
```

### Pattern 2: Structured JSON Output
**What:** All CLI output is JSON for machine consumption by the sidecar
**When to use:** Every command response, both success and error
**Example:**
```javascript
// Success output (written to stdout)
function outputSuccess(data) {
  console.log(JSON.stringify({ status: 'ok', ...data }));
  process.exit(0);
}

// Error output (written to stdout -- sidecar parses stdout)
function outputError(message, details = {}) {
  console.log(JSON.stringify({ status: 'error', error: message, ...details }));
  process.exit(1);
}

// Example: start-task success
outputSuccess({
  branch: 'gcu/add-login-endpoint',
  base_commit: 'abc1234',
  repo_dir: '/home/agent/project'
});

// Example: start-task error
outputError('dirty_working_tree', {
  files: ['src/index.js', 'README.md'],
  hint: 'Commit or stash changes before starting a new task'
});
```

### Pattern 3: Sidecar Lifecycle Integration
**What:** Git operations wired into existing task assignment and completion flows
**When to use:** `handleTaskAssign` (before wake) and `handleResult` (before hub notification)
**Example:**
```javascript
// In handleTaskAssign (index.js), BEFORE wakeAgent():
async function handleTaskAssign(msg) {
  // ... existing acceptance logic ...

  // Run start-task before waking agent
  const gitResult = runGitCommand('start-task', {
    agent_id: this.config.agent_id,
    task_id: msg.task_id,
    description: msg.description,
    metadata: msg.metadata
  });

  if (gitResult.status === 'error') {
    log('git_start_task_failed', { task_id: msg.task_id, error: gitResult.error });
    // Per CONTEXT.md: wake agent anyway with warning
    task.git_warning = gitResult.error;
  } else {
    task.branch = gitResult.branch;
  }

  saveQueue(_queue);
  wakeAgent(task, this);
}

// In handleResult (index.js), BEFORE sending task_complete to hub:
function handleResult(taskId, filePath, hub) {
  // ... existing result parsing ...

  if (result.status === 'success') {
    // Run submit before reporting to hub
    const gitResult = runGitCommand('submit', {
      agent_id: _config.agent_id,
      task_id: taskId,
      task: _queue.active  // Full task data for PR description
    });

    if (gitResult.status === 'ok') {
      result.pr_url = gitResult.pr_url;
    } else {
      log('git_submit_failed', { task_id: taskId, error: gitResult.error });
      // Still report task complete, just without PR URL
    }

    hub.sendTaskComplete(taskId, result);
  }
}

// Helper to invoke agentcom-git as a child process
function runGitCommand(command, args) {
  try {
    const output = execSync(
      `node "${path.join(__dirname, 'agentcom-git.js')}" ${command} '${JSON.stringify(args)}'`,
      { encoding: 'utf-8', timeout: 120000, shell: true, windowsHide: true }
    );
    return JSON.parse(output.trim());
  } catch (err) {
    try {
      return JSON.parse(err.stdout.trim());
    } catch {
      return { status: 'error', error: err.message };
    }
  }
}
```

### Pattern 4: Task Slug Generation (Claude's Discretion Recommendation)
**What:** Auto-slugify task description into URL-safe branch segment
**When to use:** When creating branch name from task data
**Recommendation:** Auto-slugify from task description. This avoids requiring a metadata field that submitters must remember to fill in. The slug only needs to be human-readable, not unique (task ID prefix makes it unique).
**Example:**
```javascript
function generateSlug(description, maxLength = 40) {
  return description
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, '')    // Remove non-alphanumeric (keep spaces, hyphens)
    .replace(/\s+/g, '-')             // Spaces to hyphens
    .replace(/-+/g, '-')              // Collapse multiple hyphens
    .replace(/^-|-$/g, '')            // Trim leading/trailing hyphens
    .slice(0, maxLength)              // Truncate
    .replace(/-$/, '');               // Clean trailing hyphen from truncation
}

// Examples:
// "Add login endpoint"           -> "add-login-endpoint"
// "Fix: user auth   broken!!!"   -> "fix-user-auth-broken"
// "URGENT: deploy config update" -> "urgent-deploy-config-update"

// Branch name: {agent_short_id}/{slug}
function branchName(agentId, description) {
  // Use short agent ID (first segment before hyphen, or first 8 chars)
  const shortId = agentId.split('-')[0].slice(0, 8);
  const slug = generateSlug(description);
  return `${shortId}/${slug}`;
}
// "gcu-conditions-permitting" + "Add login endpoint" -> "gcu/add-login-endpoint"
```

### Anti-Patterns to Avoid
- **Running git commands in the sidecar directory:** The sidecar lives in `AgentCom/sidecar/` but agents work in separate repo directories. All git commands must use `cwd: config.repo_dir`, never `__dirname`.
- **Using async exec for git commands:** The `agentcom-git` CLI is invoked as a subprocess by the sidecar. Within the CLI itself, synchronous `execSync` is correct because operations are sequential (fetch, then branch, then checkout). Async adds complexity with no benefit for sequential shell commands.
- **Parsing git output with regex when structured options exist:** Use `git diff --stat --numstat` for machine-parseable output, `git status --porcelain` for parseable status, `git rev-parse --abbrev-ref HEAD` for current branch. Avoid parsing human-readable output.
- **Hardcoding GitHub repo URL:** Use `gh pr create` which auto-detects the repo from the git remote. Do not construct API URLs manually.
- **Interactive gh prompts:** Always pass `--title`, `--body`, `--head`, `--base` to `gh pr create`. If any required flag is missing, gh will prompt interactively, which hangs autonomous agents. Environment variable `GH_PROMPT_DISABLED=1` can be set as a safety net.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Branch creation from remote main | Manual ref manipulation | `git fetch origin && git checkout -b {branch} origin/main` | Git handles ref resolution, detached HEAD recovery, and reflog automatically |
| PR creation with labels/reviewers | GitHub REST API client | `gh pr create --title ... --body ... --label ... --reviewer ...` | gh handles authentication (via `gh auth`), repo detection, label creation, and reviewer validation |
| Diff summary generation | Custom diff parser | `git diff --stat origin/main...HEAD` | Git's built-in stat output is concise and well-understood by reviewers |
| Working tree dirty check | Manual file scanning | `git status --porcelain` | Git tracks all working tree states including untracked, staged, modified, deleted |
| Conventional commit validation | Custom parser | Regex: `/^(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)(\(.+\))?!?:\s.+/` | Well-established pattern; the regex is 1 line vs a parser library |
| Slug generation | NPM slug library | 4-line function (see Pattern 4 above) | The requirements are simple: lowercase, hyphens, truncate. No need for Unicode transliteration or locale awareness |

**Key insight:** The entire `agentcom-git` tool is a thin orchestration layer over `git` and `gh` CLI commands. Every "feature" is a sequence of 2-5 shell commands with error checking between them. The value is in the orchestration and error handling, not in reimplementing git/GitHub functionality.

## Common Pitfalls

### Pitfall 1: Git operations in wrong directory
**What goes wrong:** Git commands execute in the sidecar directory (`AgentCom/sidecar/`) instead of the agent's working repo directory. Branch creation, commits, and pushes happen in the wrong repo.
**Why it happens:** The sidecar process's `cwd` is the sidecar directory. `execSync` inherits `cwd` from the parent process unless explicitly overridden.
**How to avoid:** Always pass `cwd: config.repo_dir` to every `execSync` call. The `git()` and `gh()` helper functions must default to `config.repo_dir`. Add a startup validation that `config.repo_dir` exists and is a git repository.
**Warning signs:** `git status` shows sidecar files instead of agent project files; branch names appear in the wrong repo.

### Pitfall 2: gh CLI interactive prompts blocking autonomous execution
**What goes wrong:** `gh pr create` without all required flags launches an interactive editor, causing the process to hang indefinitely (no TTY for the agent to respond).
**Why it happens:** gh CLI defaults to interactive mode for missing fields (title, body). The sidecar runs as a background pm2 process with no attached terminal.
**How to avoid:** Always provide `--title`, `--body`, `--base`, and `--head` flags. Set environment variable `GH_PROMPT_DISABLED=1` as a belt-and-suspenders safety net. Test with `--dry-run` during development.
**Warning signs:** `agentcom-git submit` hangs; pm2 shows process stuck at 100% CPU.

### Pitfall 3: Stale branch on re-assignment
**What goes wrong:** A task that was previously assigned (and branched) gets reassigned to the same agent after reclamation. The branch `gcu/add-login-endpoint` already exists locally, and `git checkout -b` fails with "branch already exists."
**Why it happens:** The scheduler reclaims stuck tasks and may reassign them to the same agent. The previous branch was created but the agent never completed work.
**How to avoid:** Before creating a branch, check if it already exists (`git branch --list {name}`). If it does, delete it and recreate from fresh `origin/main`. This ensures the agent always starts from the latest main.
**Warning signs:** `start-task` fails with "fatal: A branch named 'gcu/...' already exists."

### Pitfall 4: gh auth not configured on agent machine
**What goes wrong:** `gh pr create` fails with "You are not logged in to any GitHub hosts" because `gh auth login` was never run on the agent machine.
**Why it happens:** gh CLI requires one-time authentication setup per machine. This is easy to forget when provisioning new agents.
**How to avoid:** Add `gh auth status` check to the `agentcom-git` startup validation. If not authenticated, fail fast with a clear error message directing the operator to run `gh auth login`. This should also be added to the Phase 8 onboarding script.
**Warning signs:** `submit` command fails on first run; works after manual `gh auth login`.

### Pitfall 5: PR label does not exist in target repo
**What goes wrong:** `gh pr create --label "agent:gcu"` fails because the label hasn't been created in the GitHub repository yet.
**Why it happens:** Labels must exist in the repo before they can be applied to PRs. Unlike GitHub Actions, `gh pr create --label` does NOT auto-create labels (per GitHub CLI issue #2196).
**How to avoid:** Before the first `submit`, ensure required labels exist using `gh label create <name> --force` (the `--force` flag makes it idempotent -- updates if exists, creates if not). Run label creation as part of `submit` or as a one-time setup step. Labels needed: `agent:{id}` and `priority:{level}`.
**Warning signs:** `gh pr create` returns error "label 'agent:gcu' not found."

### Pitfall 6: Windows shell escaping in PR body
**What goes wrong:** PR description containing special characters (quotes, newlines, backticks) breaks shell parsing on Windows. The `--body` flag receives garbled text.
**Why it happens:** Windows `cmd.exe` handles quoting differently from Unix shells. Newlines, double quotes, and special characters are interpreted by the shell before reaching `gh`.
**How to avoid:** Use `gh pr create --body-file -` and pipe the body via stdin, or write the body to a temp file and use `--body-file`. This avoids all shell escaping issues on both platforms.
**Warning signs:** PR descriptions are truncated, contain literal `\n`, or have missing quotes.

### Pitfall 7: Race condition between agent completion and submit
**What goes wrong:** The agent writes its result file, the sidecar's file watcher triggers `handleResult`, and `submit` runs -- but the agent hasn't committed all its work yet. The PR contains incomplete changes.
**Why it happens:** The result file watcher triggers as soon as the `.json` file is detected. The agent might write the result file before its final `git commit`.
**How to avoid:** The contract must be clear: agents must commit all their work BEFORE writing the result file. The result file is the "done" signal. Document this contract. The `submit` command should verify there are no uncommitted changes and warn (but still proceed) if found.
**Warning signs:** PRs missing the agent's last commit; diff in PR doesn't match agent's work.

## Code Examples

Verified patterns from official sources and existing codebase:

### start-task Command Implementation
```javascript
// Source: git CLI documentation, existing sidecar patterns (index.js execCommand)
function startTask(args) {
  const { agent_id, task_id, description, metadata } = args;
  const repoDir = config.repo_dir;

  // 1. Validate repo directory exists and is a git repo
  if (!fs.existsSync(repoDir)) {
    outputError('repo_dir_not_found', { repo_dir: repoDir });
  }

  // 2. Check for dirty working tree (CONTEXT.md: fail with error)
  const status = git('status --porcelain');
  if (status.length > 0) {
    const files = status.split('\n').map(l => l.trim());
    outputError('dirty_working_tree', { files });
  }

  // 3. Fetch origin (CONTEXT.md: always fetch, no stale main)
  git('fetch origin');

  // 4. Generate branch name
  const slug = generateSlug(description);
  const shortAgent = agent_id.split('-')[0].slice(0, 8);
  const branch = `${shortAgent}/${slug}`;

  // 5. Delete existing branch if present (handles re-assignment)
  try {
    git(`branch -D ${branch}`);
  } catch { /* branch doesn't exist, that's fine */ }

  // 6. Create branch from origin/main
  git(`checkout -b ${branch} origin/main`);

  outputSuccess({
    branch,
    base_commit: git('rev-parse --short HEAD'),
    repo_dir: repoDir
  });
}
```

### submit Command Implementation
```javascript
// Source: gh CLI docs (https://cli.github.com/manual/gh_pr_create)
function submit(args) {
  const { agent_id, task_id, task } = args;
  const repoDir = config.repo_dir;
  const branch = git('rev-parse --abbrev-ref HEAD');

  // 1. Verify we're not on main
  if (branch === 'main' || branch === 'master') {
    outputError('on_main_branch', { branch });
  }

  // 2. Check for uncommitted changes (warn but proceed)
  const status = git('status --porcelain');
  if (status.length > 0) {
    // Log warning but don't fail -- agent may have intentionally left files
    console.error(JSON.stringify({
      warning: 'uncommitted_changes',
      files: status.split('\n').map(l => l.trim())
    }));
  }

  // 3. Push branch to origin (force-with-lease for safety on re-submit)
  git(`push --force-with-lease origin ${branch}`);

  // 4. Generate PR description
  const diffStat = git('diff --stat origin/main...HEAD');
  const prBody = generatePrBody(task, agent_id, diffStat);

  // 5. Ensure labels exist (idempotent)
  const shortAgent = agent_id.split('-')[0];
  const priorityLabel = `priority:${task.metadata?.priority || 'normal'}`;
  const agentLabel = `agent:${shortAgent}`;

  tryCreateLabel(agentLabel);
  tryCreateLabel(priorityLabel);

  // 6. Create PR via gh CLI
  // Write body to temp file to avoid shell escaping issues
  const bodyFile = path.join(repoDir, '.pr-body.tmp');
  fs.writeFileSync(bodyFile, prBody, 'utf-8');

  try {
    const reviewer = config.reviewer || '';
    const reviewerFlag = reviewer ? `--reviewer "${reviewer}"` : '';

    const prUrl = gh(
      `pr create --base main --head "${branch}" ` +
      `--title "${prTitle(task)}" ` +
      `--body-file "${bodyFile}" ` +
      `--label "${agentLabel}" --label "${priorityLabel}" ` +
      reviewerFlag
    );

    outputSuccess({ pr_url: prUrl, branch });
  } finally {
    // Clean up temp file
    try { fs.unlinkSync(bodyFile); } catch { /* ignore */ }
  }
}

function tryCreateLabel(name) {
  try {
    gh(`label create "${name}" --force`);
  } catch { /* label creation failed, gh pr create might still work */ }
}
```

### status Command Implementation
```javascript
// Source: git CLI documentation
function status(args) {
  const branch = git('rev-parse --abbrev-ref HEAD');
  const uncommitted = git('status --porcelain');

  let diffFromMain = '';
  try {
    diffFromMain = git('diff --stat origin/main...HEAD');
  } catch { /* might fail if origin/main doesn't exist locally */ }

  const commitCount = (() => {
    try {
      return git('rev-list --count origin/main..HEAD');
    } catch { return '0'; }
  })();

  outputSuccess({
    branch,
    commits_ahead: parseInt(commitCount, 10),
    diff_from_main: diffFromMain,
    uncommitted_changes: uncommitted ? uncommitted.split('\n').map(l => l.trim()) : [],
    is_clean: uncommitted.length === 0
  });
}
```

### PR Description Template
```javascript
// Source: CONTEXT.md locked decisions on PR content
function generatePrBody(task, agentId, diffStat) {
  const hubUrl = config.hub_api_url || 'http://localhost:4000';
  const taskId = task.task_id || task.id || 'unknown';
  const priority = task.metadata?.priority || 'normal';
  const description = task.description || 'No description provided';

  return [
    `## Task: ${taskId}`,
    '',
    `**Agent:** ${agentId}`,
    `**Priority:** ${priority}`,
    `**Task Link:** ${hubUrl}/api/tasks/${taskId}`,
    '',
    '### Description',
    '',
    description,
    '',
    '### Changes',
    '',
    '```',
    diffStat || 'No changes',
    '```',
    '',
    '---',
    `*Submitted by agentcom-git | Agent: ${agentId} | Task: ${taskId}*`
  ].join('\n');
}

function prTitle(task) {
  // Generate a conventional-commit-style title from task description
  const desc = task.description || 'agent task';
  const slug = desc.length > 60 ? desc.slice(0, 57) + '...' : desc;
  return slug;
}
```

### Sidecar Config Changes
```javascript
// New fields in config.json for git workflow
{
  "agent_id": "gcu-conditions-permitting",
  "token": "...",
  "hub_url": "ws://localhost:4000/ws",
  "hub_api_url": "http://localhost:4000",    // NEW: for PR description task links
  "repo_dir": "/home/agent/project",          // NEW: where agent's git repo lives
  "reviewer": "flere-imsaho",                 // NEW: GitHub handle for PR reviewer
  "wake_command": "...",
  "capabilities": ["code", "git"],
  "confirmation_timeout_ms": 30000,
  "results_dir": "./results",
  "log_file": "./sidecar.log"
}
```

### Conventional Commit Validation (Supporting Utility)
```javascript
// Source: https://www.conventionalcommits.org/en/v1.0.0/
const CONVENTIONAL_COMMIT_RE = /^(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)(\([a-zA-Z0-9._-]+\))?!?:\s.+/;

function isConventionalCommit(message) {
  return CONVENTIONAL_COMMIT_RE.test(message);
}

// Note: Commit message enforcement is informational in this phase.
// The status command can flag non-conventional commits, but start-task
// and submit don't reject them. Enforcement could be a pre-commit hook
// added later, but that's outside the scope of these 3 commands.
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `git push --force` | `git push --force-with-lease` | Git 1.8.5 (2013) | Prevents accidental overwrite of others' commits; safe for re-pushing branches |
| Manual GitHub API for PRs | `gh pr create` with flags | gh CLI v1.0 (2020) | No need to manage tokens/endpoints; auto-detects repo from git remote |
| Shell-escaped `--body` flag | `--body-file` flag | gh CLI v1.4 (2020) | Eliminates cross-platform shell escaping issues for PR descriptions |
| `git checkout -b` from local main | `git checkout -b branch origin/main` | Always available | Creates branch from remote tracking ref, not local (possibly stale) main |

**Deprecated/outdated:**
- `hub` CLI (GitHub's older CLI tool): Replaced entirely by `gh` CLI. Do not use `hub`.
- `git push --force` without lease: Unsafe for any workflow where branches might be shared. Always use `--force-with-lease`.

## Force-Push Policy (Claude's Discretion Recommendation)

**Recommendation: Use `--force-with-lease` as the default.**

Rationale:
- Feature branches are owned by a single agent, so force-push scenarios are limited to re-submission after task reclamation/reassignment.
- `--force-with-lease` prevents accidental overwrites if the remote branch was updated by another process (e.g., human intervention on the PR).
- If `--force-with-lease` fails, it means someone else pushed to the branch, which is a genuine conflict that should be reported rather than silently overwritten.
- This is the industry standard "safe force push" and matches the "pick safest default" guidance from CONTEXT.md.

If `--force-with-lease` fails, `submit` should report the error and let the sidecar handle it (report task_complete without PR URL, or report failure).

## Hub Integration for PR URLs

The hub currently stores task results in the `result` field of completed tasks. PR URLs can be included in this existing structure without any hub-side changes:

```javascript
// Sidecar sends task_complete with pr_url in result:
hub.sendTaskComplete(taskId, {
  ...result,           // Original agent result (status, output, etc.)
  pr_url: gitResult.pr_url   // Added by sidecar after submit
});

// Hub stores this in TaskQueue.complete_task -> task.result
// Dashboard can read task.result.pr_url for display
// No hub code changes needed -- result is an opaque map
```

The dashboard (Phase 6) already shows recent completions. It can read `task.result.pr_url` and display it as a link. This may require a minor dashboard update but no hub API changes.

## Open Questions

1. **`repo_dir` for agents that work on multiple repos**
   - What we know: Each sidecar config has one `repo_dir` pointing to the agent's working repository.
   - What's unclear: If an agent works on multiple repos (e.g., AgentCom + a separate project), the current design assumes one repo per sidecar instance. Tasks would need to specify which repo to use, or each agent instance is scoped to one repo.
   - Recommendation: Start with one `repo_dir` per config (one repo per sidecar). If multi-repo support is needed later, add a `repo_dir` field to task metadata that overrides the config default.

2. **Conventional commit enforcement scope**
   - What we know: CONTEXT.md says "conventional commits enforced." The three `agentcom-git` commands don't create commits -- agents do.
   - What's unclear: Where exactly enforcement happens. `agentcom-git` can validate existing commits on `submit`, but it can't prevent agents from making bad commits during work.
   - Recommendation: Add validation in `submit` that checks all new commits (since `origin/main`) follow conventional commit format. If violations found, log a warning but still submit (agents should learn, not be blocked). A git commit-msg hook could enforce during agent work, but that's fragile with autonomous agents.

3. **What happens when `gh auth` expires mid-session**
   - What we know: `gh auth` tokens can expire (especially with SSO/SAML organizations).
   - What's unclear: Whether the agent machine's `gh auth` uses a long-lived token or one that needs periodic refresh.
   - Recommendation: Check `gh auth status` in `submit` before attempting PR creation. If auth is expired, fail fast with clear error. The onboarding script (Phase 8) should use `gh auth login --with-token` for long-lived tokens.

## Sources

### Primary (HIGH confidence)
- Git CLI v2.45.1 -- Local installation; `git --version` verified on target system
- GitHub CLI v2.86.0 -- Local installation; `gh --version` verified on target system
- [gh pr create official docs](https://cli.github.com/manual/gh_pr_create) -- All flags, behavior, and options verified
- [gh label create official docs](https://cli.github.com/manual/gh_label_create) -- Label management with `--force` flag for idempotent creation
- Existing sidecar codebase (`sidecar/index.js`) -- `execCommand`, `handleTaskAssign`, `handleResult`, `wakeAgent` patterns directly referenced
- Existing hub codebase (`lib/agent_com/socket.ex`, `lib/agent_com/task_queue.ex`, `lib/agent_com/scheduler.ex`) -- Task data model, assignment flow, completion flow verified

### Secondary (MEDIUM confidence)
- [Node.js child_process docs](https://nodejs.org/api/child_process.html) -- `execSync` options including `cwd`, `encoding`, `shell`, `timeout`
- [Conventional Commits spec](https://www.conventionalcommits.org/en/v1.0.0/) -- Format specification for commit message validation regex
- [Git push --force-with-lease](https://adamj.eu/tech/2023/10/31/git-force-push-safely/) -- Safety comparison between `--force` and `--force-with-lease`
- [GitHub CLI issue #2196](https://github.com/cli/cli/issues/2196) -- Confirmed that `gh pr create --label` requires labels to exist in the repo

### Tertiary (LOW confidence)
- None -- all claims verified against primary or secondary sources

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- All tools already installed and verified on target system; no new dependencies
- Architecture: HIGH -- Follows existing sidecar patterns (child_process, JSON config, file-based IPC); integration points clearly identified in existing code
- Pitfalls: HIGH -- All pitfalls identified from existing codebase patterns and verified tool behavior (gh label requirements, Windows escaping, directory context)

**Research date:** 2026-02-11
**Valid until:** 2026-03-11 (stable tools, no fast-moving dependencies)
