'use strict';

const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const CONFIG_PATH = path.join(__dirname, 'config.json');

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    outputError('config_not_found', { path: CONFIG_PATH });
  }
  const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  if (!config.repo_dir) {
    outputError('missing_repo_dir', {
      hint: 'Add "repo_dir" to config.json pointing to the agent\'s git repository'
    });
  }
  if (!fs.existsSync(config.repo_dir)) {
    outputError('repo_dir_not_found', { repo_dir: config.repo_dir });
  }
  const gitDir = path.join(config.repo_dir, '.git');
  if (!fs.existsSync(gitDir)) {
    outputError('not_a_git_repo', {
      repo_dir: config.repo_dir,
      hint: 'repo_dir must point to a directory containing a .git folder'
    });
  }
  return config;
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

function outputSuccess(data) {
  console.log(JSON.stringify({ status: 'ok', ...data }));
  process.exit(0);
}

function outputError(message, details = {}) {
  console.log(JSON.stringify({ status: 'error', error: message, ...details }));
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Shell helpers
// ---------------------------------------------------------------------------

function git(cmd, opts = {}) {
  const config = opts._config || loadConfig();
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
  const config = opts._config || loadConfig();
  const cwd = opts.cwd || config.repo_dir;
  try {
    return execSync(`gh ${cmd}`, {
      cwd,
      encoding: 'utf-8',
      shell: true,
      timeout: 120000,
      windowsHide: true,
      env: { ...process.env, GH_PROMPT_DISABLED: '1' }
    }).trim();
  } catch (err) {
    const stderr = (err.stderr || '').trim();
    throw new Error(`gh ${cmd.split(' ')[0]} failed: ${stderr || err.message}`);
  }
}

// ---------------------------------------------------------------------------
// Slug generation
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// PR body generation
// ---------------------------------------------------------------------------

function generatePrBody(task, agentId, diffStat, config, riskClassification) {
  const hubUrl = config.hub_api_url || 'http://localhost:4000';
  const taskId = task.task_id || task.id || 'unknown';
  const priority = (task.metadata && task.metadata.priority) || 'normal';
  const description = task.description || 'No description provided';

  const lines = [
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
  ];

  // Add risk classification section if provided
  if (riskClassification) {
    const tierLabels = {
      1: 'Tier 1 (Auto-merge candidate)',
      2: 'Tier 2 (Review required)',
      3: 'Tier 3 (Escalate)'
    };
    const tierLabel = tierLabels[riskClassification.tier] || `Tier ${riskClassification.tier}`;

    lines.push('');
    lines.push('### Risk Classification');
    lines.push('');
    lines.push(`**${tierLabel}**`);

    if (riskClassification.reasons && riskClassification.reasons.length > 0) {
      lines.push('');
      lines.push('**Reasons:**');
      for (const reason of riskClassification.reasons) {
        lines.push(`- ${reason}`);
      }
    }
  }

  lines.push('');
  lines.push('---');
  lines.push(`*Submitted by agentcom-git | Agent: ${agentId} | Task: ${taskId}*`);

  return lines.join('\n');
}

function prTitle(task) {
  const desc = task.description || 'agent task';
  return desc.length > 60 ? desc.slice(0, 57) + '...' : desc;
}

// ---------------------------------------------------------------------------
// Conventional commit validation
// ---------------------------------------------------------------------------

const CONVENTIONAL_COMMIT_RE = /^(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)(\([a-zA-Z0-9._-]+\))?!?:\s.+/;

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

function startTask(args) {
  const config = loadConfig();
  const { agent_id, task_id, description } = args;

  if (!agent_id || !description) {
    outputError('missing_args', {
      hint: 'start-task requires { agent_id, task_id, description }'
    });
  }

  // 1. Check working tree is clean
  const status = git('status --porcelain', { _config: config });
  if (status.length > 0) {
    const files = status.split('\n').map(l => l.trim()).filter(Boolean);
    outputError('dirty_working_tree', { files });
  }

  // 2. Fetch origin
  try {
    git('fetch origin', { _config: config });
  } catch (err) {
    outputError('fetch_failed', { message: err.message });
  }

  // 3. Generate branch name
  const slug = generateSlug(description);
  const shortAgent = agent_id.split('-')[0].slice(0, 8);
  const branch = `${shortAgent}/${slug}`;

  // 4. Delete existing local branch if it exists (handles re-assignment)
  try {
    git(`branch -D ${branch}`, { _config: config });
  } catch {
    // Branch doesn't exist -- that's fine
  }

  // 5. Create branch from origin/main
  try {
    git(`checkout -b ${branch} origin/main`, { _config: config });
  } catch (err) {
    outputError('checkout_failed', { branch, message: err.message });
  }

  // 6. Output success
  const baseCommit = git('rev-parse --short HEAD', { _config: config });
  outputSuccess({
    branch,
    base_commit: baseCommit,
    repo_dir: config.repo_dir
  });
}

function submit(args) {
  const config = loadConfig();
  const { agent_id, task_id, task, risk_classification } = args;

  if (!agent_id || !task_id) {
    outputError('missing_args', {
      hint: 'submit requires { agent_id, task_id, task }'
    });
  }

  const taskObj = task || {};

  // 1. Get current branch
  const branch = git('rev-parse --abbrev-ref HEAD', { _config: config });
  if (branch === 'main' || branch === 'master') {
    outputError('on_main_branch', { branch });
  }

  // 2. Check for uncommitted changes (warn but proceed)
  const status = git('status --porcelain', { _config: config });
  if (status.length > 0) {
    console.error(JSON.stringify({
      warning: 'uncommitted_changes',
      files: status.split('\n').map(l => l.trim()).filter(Boolean)
    }));
  }

  // 3. Check for commits ahead of origin/main
  let commitCount;
  try {
    commitCount = git('rev-list --count origin/main..HEAD', { _config: config });
  } catch {
    commitCount = '0';
  }
  if (parseInt(commitCount, 10) === 0) {
    outputError('no_commits', { hint: 'Agent made no commits on this branch' });
  }

  // 4. Push with force-with-lease
  try {
    git(`push --force-with-lease origin ${branch}`, { _config: config });
  } catch (err) {
    outputError('push_failed', { branch, message: err.message });
  }

  // 5. Generate PR body
  let diffStat = '';
  try {
    diffStat = git('diff --stat origin/main...HEAD', { _config: config });
  } catch {
    // diff stat not available
  }
  const prBody = generatePrBody(taskObj, agent_id, diffStat, config, risk_classification);

  // 6. Ensure labels exist (idempotent via --force)
  const shortAgent = agent_id.split('-')[0].slice(0, 8);
  const agentLabel = `agent:${shortAgent}`;
  const priorityLabel = `priority:${(taskObj.metadata && taskObj.metadata.priority) || 'normal'}`;

  try { gh(`label create "${agentLabel}" --force`, { _config: config }); } catch { /* ignore */ }
  try { gh(`label create "${priorityLabel}" --force`, { _config: config }); } catch { /* ignore */ }

  // 6b. Create risk tier label if classification provided
  let riskLabel = null;
  if (risk_classification && risk_classification.tier) {
    riskLabel = `risk:tier-${risk_classification.tier}`;
    try { gh(`label create "${riskLabel}" --force`, { _config: config }); } catch { /* ignore */ }
  }

  // 7. Write PR body to temp file (avoids shell escaping -- Pitfall 6)
  const bodyFile = path.join(config.repo_dir, '.pr-body.tmp');
  fs.writeFileSync(bodyFile, prBody, 'utf-8');

  try {
    // 8. Create PR
    const title = prTitle(taskObj);
    const reviewerFlag = config.reviewer ? ` --reviewer "${config.reviewer}"` : '';

    const riskLabelFlag = riskLabel ? ` --label "${riskLabel}"` : '';
    const prUrl = gh(
      `pr create --base main --head "${branch}" ` +
      `--title "${title}" ` +
      `--body-file "${bodyFile}" ` +
      `--label "${agentLabel}" --label "${priorityLabel}"` +
      riskLabelFlag +
      reviewerFlag,
      { _config: config }
    );

    // 9. Output success
    outputSuccess({ pr_url: prUrl, branch });
  } catch (err) {
    outputError('pr_create_failed', { branch, message: err.message });
  } finally {
    // 10. Clean up temp file
    try { fs.unlinkSync(bodyFile); } catch { /* ignore */ }
  }
}

// ---------------------------------------------------------------------------
// Diff metadata gathering for risk classification
// ---------------------------------------------------------------------------

function gatherDiffMeta(config) {
  const defaults = {
    lines_added: 0,
    lines_deleted: 0,
    files_changed: [],
    files_added: [],
    tests_exist: false
  };

  try {
    // Lines added/deleted per file
    let linesAdded = 0;
    let linesDeleted = 0;
    try {
      const numstat = git('diff --numstat origin/main...HEAD', { _config: config });
      if (numstat) {
        for (const line of numstat.split('\n')) {
          const parts = line.split('\t');
          if (parts.length >= 3) {
            const added = parseInt(parts[0], 10);
            const deleted = parseInt(parts[1], 10);
            if (!isNaN(added)) linesAdded += added;
            if (!isNaN(deleted)) linesDeleted += deleted;
          }
        }
      }
    } catch { /* use defaults */ }

    // New files (status 'A')
    let filesAdded = [];
    try {
      const nameStatus = git('diff --name-status origin/main...HEAD', { _config: config });
      if (nameStatus) {
        for (const line of nameStatus.split('\n')) {
          const parts = line.split('\t');
          if (parts.length >= 2 && parts[0] === 'A') {
            filesAdded.push(parts[1]);
          }
        }
      }
    } catch { /* use defaults */ }

    // All changed files
    let filesChanged = [];
    try {
      const nameOnly = git('diff --name-only origin/main...HEAD', { _config: config });
      if (nameOnly) {
        filesChanged = nameOnly.split('\n').filter(Boolean);
      }
    } catch { /* use defaults */ }

    // Check if tests exist for changed files
    let testsExist = false;
    try {
      for (const file of filesChanged) {
        // lib/X.ex -> test/X_test.exs
        if (file.startsWith('lib/') && file.endsWith('.ex')) {
          const testFile = file.replace(/^lib\//, 'test/').replace(/\.ex$/, '_test.exs');
          const testPath = path.join(config.repo_dir, testFile);
          if (fs.existsSync(testPath)) {
            testsExist = true;
            break;
          }
        }
      }
    } catch { /* use defaults */ }

    return {
      lines_added: linesAdded,
      lines_deleted: linesDeleted,
      files_changed: filesChanged,
      files_added: filesAdded,
      tests_exist: testsExist
    };
  } catch {
    return defaults;
  }
}

function status() {
  const config = loadConfig();

  // 1. Get current branch
  const branch = git('rev-parse --abbrev-ref HEAD', { _config: config });

  // 2. Get uncommitted changes
  const uncommitted = git('status --porcelain', { _config: config });

  // 3. Get diff from main
  let diffFromMain = '';
  try {
    diffFromMain = git('diff --stat origin/main...HEAD', { _config: config });
  } catch {
    // origin/main might not exist locally
  }

  // 4. Get commits ahead
  let commitCount = '0';
  try {
    commitCount = git('rev-list --count origin/main..HEAD', { _config: config });
  } catch {
    // default to 0
  }

  // 5. Validate conventional commits
  const nonConventional = [];
  try {
    const commits = git('log --format=%s origin/main..HEAD', { _config: config });
    if (commits) {
      commits.split('\n').forEach(msg => {
        if (msg && !CONVENTIONAL_COMMIT_RE.test(msg)) {
          nonConventional.push(msg);
        }
      });
    }
  } catch {
    // No commits or origin/main not reachable
  }

  // 6. Output success
  outputSuccess({
    branch,
    commits_ahead: parseInt(commitCount, 10),
    diff_from_main: diffFromMain,
    uncommitted_changes: uncommitted ? uncommitted.split('\n').map(l => l.trim()).filter(Boolean) : [],
    is_clean: uncommitted.length === 0,
    non_conventional_commits: nonConventional
  });
}

// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

function gatherDiffMetaCommand() {
  const config = loadConfig();
  const meta = gatherDiffMeta(config);
  outputSuccess(meta);
}

const commands = { 'start-task': startTask, 'submit': submit, 'status': status, 'gather-diff-meta': gatherDiffMetaCommand };

try {
  const command = process.argv[2];
  if (!commands[command]) {
    outputError('unknown_command', { command, available: Object.keys(commands) });
  }
  const args = process.argv[3] ? JSON.parse(process.argv[3]) : {};
  commands[command](args);
} catch (err) {
  // Catch JSON parse errors and any other unexpected errors
  outputError('unexpected_error', { message: err.message });
}
