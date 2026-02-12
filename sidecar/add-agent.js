#!/usr/bin/env node
'use strict';

// =============================================================================
// add-agent.js — One-command agent onboarding for AgentCom
// =============================================================================
//
// Usage:
//   node add-agent.js --hub http://hub-hostname:4000
//   node add-agent.js --hub http://hub-hostname:4000 --name gcu-custom-name
//   node add-agent.js --hub http://hub-hostname:4000 --resume
//   node add-agent.js --hub http://hub-hostname:4000 --name gcu-custom-name --rejoin --token <token>
//
// Prerequisites: Node.js >= 18, pm2, git, openclaw
//
// Steps:
//   [1/7] Pre-flight checks
//   [2/7] Register agent with hub
//   [3/7] Clone repository
//   [4/7] Generate sidecar config
//   [5/7] Install dependencies
//   [6/7] Start pm2 process
//   [7/7] Verify with test task

const { parseArgs } = require('node:util');
const os = require('os');
const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

// =============================================================================
// CLI Argument Parsing
// =============================================================================

const USAGE = `
Usage: node add-agent.js --hub <url> [--name <name>] [--resume]
       node add-agent.js --hub <url> --name <name> --rejoin --token <token>

Options:
  --hub     Hub API URL (required)       e.g. http://localhost:4000
  --name    Override auto-generated name  e.g. gcu-sleeper-service
  --resume  Skip already-completed steps
  --rejoin  Re-provision an existing agent (skip registration, reuse token)
  --token   Agent token (required with --rejoin unless progress file exists)
`;

let args;
try {
  const { values } = parseArgs({
    options: {
      hub:    { type: 'string',  short: 'h' },
      name:   { type: 'string',  short: 'n' },
      resume: { type: 'boolean', short: 'r', default: false },
      rejoin: { type: 'boolean', default: false },
      token:  { type: 'string',  short: 't' },
      help:   { type: 'boolean', default: false }
    },
    strict: true
  });
  args = values;
} catch (err) {
  console.error(`Error: ${err.message}`);
  console.error(USAGE);
  process.exit(1);
}

if (args.help) {
  console.log(USAGE);
  process.exit(0);
}

if (!args.hub) {
  console.error('Error: --hub is required.');
  console.error(USAGE);
  process.exit(1);
}

// Normalize hub URL: strip trailing slash
const HUB_URL = args.hub.replace(/\/+$/, '');

// Validate --rejoin flags
if (args.rejoin) {
  if (!args.name) {
    console.error('Error: --rejoin requires --name to identify which agent to rejoin.');
    console.error(USAGE);
    process.exit(1);
  }
  if (args.resume) {
    console.error('Error: --rejoin and --resume are mutually exclusive.');
    console.error('  --resume continues an incomplete onboarding.');
    console.error('  --rejoin does a fresh setup with an existing agent identity.');
    console.error(USAGE);
    process.exit(1);
  }
}

// =============================================================================
// HTTP Helper (zero npm deps — uses built-in http/https)
// =============================================================================

function httpRequest(method, url, body = null, headers = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const mod = u.protocol === 'https:' ? require('https') : require('http');
    const payload = body ? JSON.stringify(body) : null;

    const opts = {
      method,
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search,
      headers: {
        'Content-Type': 'application/json',
        ...headers
      }
    };

    if (payload) {
      opts.headers['Content-Length'] = Buffer.byteLength(payload);
    }

    const req = mod.request(opts, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        let parsed = null;
        if (data) {
          try { parsed = JSON.parse(data); } catch { parsed = data; }
        }
        resolve({ statusCode: res.statusCode, body: parsed });
      });
    });

    req.on('error', reject);
    req.setTimeout(15000, () => {
      req.destroy(new Error('Request timeout'));
    });

    if (payload) req.write(payload);
    req.end();
  });
}

// =============================================================================
// Progress Tracking (for --resume)
// =============================================================================

function progressPath(agentName) {
  return path.join(os.homedir(), '.agentcom', agentName, '.onboard-progress.json');
}

function loadProgress(agentName) {
  const p = progressPath(agentName);
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch {
    return {
      agent_name: agentName,
      hub_url: HUB_URL,
      steps_completed: [],
      token: null,
      default_repo: null
    };
  }
}

function saveProgress(progress) {
  const dir = path.dirname(progressPath(progress.agent_name));
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(progressPath(progress.agent_name), JSON.stringify(progress, null, 2));
}

function stepDone(progress, step) {
  return progress.steps_completed.includes(step);
}

function markStep(progress, step) {
  if (!progress.steps_completed.includes(step)) {
    progress.steps_completed.push(step);
  }
  saveProgress(progress);
}

// =============================================================================
// Logging Helpers
// =============================================================================

function logStep(n, total, message, status) {
  if (status === 'start') {
    process.stdout.write(`[${n}/${total}] ${message}...`);
  } else if (status === 'done') {
    console.log(' done');
  } else if (status === 'skip') {
    console.log(`[${n}/${total}] ${message}... skipped (already done)`);
  } else if (status === 'fail') {
    console.log(' FAILED');
  }
}

function fatal(message) {
  console.error(`\nFATAL: ${message}`);
  if (args.name || currentAgentName) {
    console.error(`\nTo resume from where you left off, run:`);
    console.error(`  node add-agent.js --hub ${HUB_URL} --name ${args.name || currentAgentName} --resume`);
  }
  process.exit(1);
}

let currentAgentName = null;

// =============================================================================
// Step 1: Pre-flight Checks
// =============================================================================

async function preflight(progress) {
  if (args.resume && stepDone(progress, 'preflight')) {
    logStep(1, 7, 'Pre-flight checks', 'skip');
    return;
  }

  logStep(1, 7, 'Pre-flight checks', 'start');

  const failures = [];

  // Node.js >= 18
  const nodeMajor = parseInt(process.versions.node.split('.')[0], 10);
  if (nodeMajor < 18) {
    failures.push(`Node.js >= 18 required (found ${process.versions.node})`);
  }

  // pm2 installed
  try {
    execSync('pm2 --version', { stdio: 'pipe', windowsHide: true });
  } catch {
    failures.push('pm2 not found. Install: npm install -g pm2');
  }

  // git installed
  try {
    execSync('git --version', { stdio: 'pipe', windowsHide: true });
  } catch {
    failures.push('git not found. Install git: https://git-scm.com/');
  }

  // openclaw installed
  try {
    execSync('openclaw --version', { stdio: 'pipe', windowsHide: true });
  } catch {
    failures.push('openclaw not found. Install OpenClaw: https://openclaw.dev/install');
  }

  // Hub reachable
  try {
    const res = await httpRequest('GET', `${HUB_URL}/health`);
    if (res.statusCode !== 200) {
      failures.push(`Hub returned status ${res.statusCode} from ${HUB_URL}/health`);
    }
  } catch (err) {
    failures.push(`Hub unreachable at ${HUB_URL}: ${err.message}`);
  }

  // Install dir check (unless --resume or --rejoin)
  if (!args.resume && !args.rejoin && args.name) {
    const installDir = path.join(os.homedir(), '.agentcom', args.name);
    if (fs.existsSync(installDir)) {
      failures.push(`Install directory already exists: ${installDir}\nUse --resume to continue or remove the directory first.`);
    }
  }

  if (failures.length > 0) {
    logStep(1, 7, 'Pre-flight checks', 'fail');
    console.error('\nPre-flight check failures:');
    failures.forEach((f, i) => console.error(`  ${i + 1}. ${f}`));
    process.exit(1);
  }

  logStep(1, 7, 'Pre-flight checks', 'done');
  markStep(progress, 'preflight');
}

// =============================================================================
// Step 2: Register Agent
// =============================================================================

async function registerAgent(progress) {
  if (args.resume && stepDone(progress, 'register') && progress.token) {
    logStep(2, 7, `Registering agent "${progress.agent_name}"`, 'skip');
    return progress;
  }

  // --rejoin: skip registration, reuse existing token
  if (args.rejoin) {
    logStep(2, 7, `Rejoining agent "${args.name}"`, 'start');

    // Get token from --token arg or existing progress file
    const token = args.token || progress.token;
    if (!token) {
      logStep(2, 7, `Rejoining agent "${args.name}"`, 'fail');
      fatal('--rejoin requires a token. Provide --token <token> or ensure progress file exists.');
    }

    progress.token = token;
    progress.agent_name = args.name;
    currentAgentName = args.name;

    // Derive hub WebSocket URL
    const u = new URL(HUB_URL);
    const wsProto = u.protocol === 'https:' ? 'wss:' : 'ws:';
    progress.hub_ws_url = `${wsProto}//${u.hostname}:${u.port}/ws`;
    progress.hub_api_url = HUB_URL;

    // Fetch default_repo from hub
    try {
      const res = await httpRequest('GET', `${HUB_URL}/api/config/default-repo`);
      if (res.statusCode === 200 && res.body && res.body.default_repo) {
        progress.default_repo = res.body.default_repo;
      }
    } catch { /* will be fetched in cloneRepo if needed */ }

    markStep(progress, 'register');
    logStep(2, 7, `Rejoining agent "${args.name}"`, 'done');
    return progress;
  }

  // Determine agent name
  let agentName = args.name || progress.agent_name;

  if (!agentName || agentName === 'unknown') {
    const { generateName, getNames } = require('./culture-names.js');

    // Fetch existing agents to check for name collisions
    let existingAgents = [];
    try {
      const res = await httpRequest('GET', `${HUB_URL}/api/agents`);
      if (res.statusCode === 200 && Array.isArray(res.body)) {
        existingAgents = res.body.map(a => a.agent_id || a.id || a.name);
      }
    } catch {
      // If we cannot list agents, proceed and let registration handle duplicates
    }

    // Generate unique name (retry up to 10 times)
    agentName = generateName();
    let retries = 0;
    while (existingAgents.includes(agentName) && retries < 10) {
      agentName = generateName();
      retries++;
    }
    if (existingAgents.includes(agentName)) {
      fatal('Could not generate a unique agent name after 10 attempts. Use --name to specify one.');
    }
  }

  currentAgentName = agentName;
  progress.agent_name = agentName;
  saveProgress(progress);

  logStep(2, 7, `Registering agent "${agentName}"`, 'start');

  // Register with hub
  let res;
  try {
    res = await httpRequest('POST', `${HUB_URL}/api/onboard/register`, {
      agent_id: agentName
    });
  } catch (err) {
    logStep(2, 7, `Registering agent "${agentName}"`, 'fail');
    fatal(`Registration request failed: ${err.message}`);
  }

  if (res.statusCode === 409) {
    logStep(2, 7, `Registering agent "${agentName}"`, 'fail');
    fatal(
      `Agent "${agentName}" already registered. Options:\n` +
      `  - Rejoin with existing token: node add-agent.js --hub ${HUB_URL} --name ${agentName} --rejoin --token <token>\n` +
      `  - Choose a different name with --name\n` +
      `  - Remove the existing agent first via admin API`
    );
  }

  if (res.statusCode !== 201 && res.statusCode !== 200) {
    logStep(2, 7, `Registering agent "${agentName}"`, 'fail');
    fatal(`Registration failed with status ${res.statusCode}: ${JSON.stringify(res.body)}`);
  }

  const regData = res.body;
  progress.token = regData.token;
  progress.hub_ws_url = regData.hub_ws_url || null;
  progress.hub_api_url = regData.hub_api_url || HUB_URL;
  progress.default_repo = regData.default_repo || null;

  logStep(2, 7, `Registering agent "${agentName}"`, 'done');
  markStep(progress, 'register');

  return progress;
}

// =============================================================================
// Step 3: Clone Repository
// =============================================================================

async function cloneRepo(progress) {
  const installDir = path.join(os.homedir(), '.agentcom', progress.agent_name);
  const repoDir = path.join(installDir, 'repo');

  if (args.resume && stepDone(progress, 'clone') && fs.existsSync(repoDir)) {
    logStep(3, 7, 'Cloning repository', 'skip');
    return repoDir;
  }

  logStep(3, 7, 'Cloning repository', 'start');

  // Get repo URL from registration or config endpoint
  let repoUrl = progress.default_repo;

  if (!repoUrl) {
    try {
      const res = await httpRequest('GET', `${HUB_URL}/api/config/default-repo`);
      if (res.statusCode === 200 && res.body && res.body.url) {
        repoUrl = res.body.url;
      }
    } catch {
      // Fall through to error
    }
  }

  if (!repoUrl) {
    logStep(3, 7, 'Cloning repository', 'fail');
    fatal(
      `Hub has no default_repo configured. Run:\n` +
      `  curl -X PUT ${HUB_URL}/api/config/default-repo ` +
      `-H 'Authorization: Bearer ${progress.token}' ` +
      `-H 'Content-Type: application/json' ` +
      `-d '{"url":"https://github.com/user/repo.git"}'`
    );
  }

  progress.default_repo = repoUrl;
  saveProgress(progress);

  // Create install directory
  fs.mkdirSync(installDir, { recursive: true });

  // Clone repository
  try {
    execSync(`git clone "${repoUrl}" "${repoDir}"`, {
      stdio: 'pipe',
      windowsHide: true,
      timeout: 120000
    });
  } catch (err) {
    logStep(3, 7, 'Cloning repository', 'fail');
    const stderr = (err.stderr || '').toString().trim();
    fatal(`git clone failed: ${stderr || err.message}`);
  }

  logStep(3, 7, 'Cloning repository', 'done');
  markStep(progress, 'clone');

  return repoDir;
}

// =============================================================================
// Step 4: Generate Config
// =============================================================================

function generateConfig(progress, repoDir) {
  const sidecarDir = path.join(repoDir, 'sidecar');
  const configPath = path.join(sidecarDir, 'config.json');

  if (args.resume && stepDone(progress, 'config') && fs.existsSync(configPath)) {
    logStep(4, 7, 'Generating sidecar config', 'skip');
    return;
  }

  logStep(4, 7, 'Generating sidecar config', 'start');

  // Determine hub WebSocket URL from hub_ws_url or derive from HUB_URL
  let hubWsUrl = progress.hub_ws_url;
  if (!hubWsUrl) {
    const u = new URL(HUB_URL);
    const wsProto = u.protocol === 'https:' ? 'wss:' : 'ws:';
    hubWsUrl = `${wsProto}//${u.hostname}:${u.port}/ws`;
  }

  const config = {
    agent_id: progress.agent_name,
    token: progress.token,
    hub_url: hubWsUrl,
    hub_api_url: progress.hub_api_url || HUB_URL,
    repo_dir: repoDir,
    reviewer: '',
    wake_command: 'openclaw agent --message "Task: ${TASK_JSON}" --session-id ${TASK_ID}',
    capabilities: ['code'],
    confirmation_timeout_ms: 30000,
    results_dir: './results',
    log_file: './sidecar.log'
  };

  // Ensure sidecar directory exists
  fs.mkdirSync(sidecarDir, { recursive: true });
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

  logStep(4, 7, 'Generating sidecar config', 'done');
  markStep(progress, 'config');
}

// =============================================================================
// Step 5: Install Dependencies
// =============================================================================

function installDeps(progress, repoDir) {
  const sidecarDir = path.join(repoDir, 'sidecar');

  if (args.resume && stepDone(progress, 'install')) {
    logStep(5, 7, 'Installing dependencies', 'skip');
    return;
  }

  logStep(5, 7, 'Installing dependencies', 'start');

  // Check if package.json exists in sidecar directory
  const pkgPath = path.join(sidecarDir, 'package.json');
  if (!fs.existsSync(pkgPath)) {
    logStep(5, 7, 'Installing dependencies', 'fail');
    fatal(`package.json not found at ${pkgPath}. Repository may be missing sidecar files.`);
  }

  try {
    execSync('npm install --production', {
      cwd: sidecarDir,
      stdio: 'pipe',
      windowsHide: true,
      timeout: 120000
    });
  } catch (err) {
    logStep(5, 7, 'Installing dependencies', 'fail');
    const stderr = (err.stderr || '').toString().trim();
    fatal(`npm install failed: ${stderr || err.message}`);
  }

  logStep(5, 7, 'Installing dependencies', 'done');
  markStep(progress, 'install');
}

// =============================================================================
// Step 6: Start pm2 Process
// =============================================================================

function startPm2(progress, repoDir) {
  const installDir = path.join(os.homedir(), '.agentcom', progress.agent_name);
  const sidecarDir = path.join(repoDir, 'sidecar');
  const pm2Name = `agentcom-${progress.agent_name}`;

  if (args.resume && stepDone(progress, 'pm2')) {
    // Check if process is running
    try {
      const list = execSync('pm2 jlist', { stdio: 'pipe', windowsHide: true, encoding: 'utf-8' });
      const processes = JSON.parse(list);
      const running = processes.find(p => p.name === pm2Name && p.pm2_env.status === 'online');
      if (running) {
        logStep(6, 7, `Starting pm2 process "${pm2Name}"`, 'skip');
        return pm2Name;
      }
    } catch {
      // Fall through to start
    }
  }

  logStep(6, 7, `Starting pm2 process "${pm2Name}"`, 'start');

  // Generate per-agent ecosystem file
  const ecosystemPath = path.join(installDir, 'ecosystem.config.js');
  const ecosystemContent = `// Auto-generated by add-agent.js for ${progress.agent_name}
module.exports = {
  apps: [{
    name: '${pm2Name}',
    script: process.platform === 'win32' ? 'start.bat' : 'start.sh',
    cwd: '${sidecarDir.replace(/\\/g, '\\\\')}',
    interpreter: process.platform === 'win32' ? 'cmd' : '/bin/bash',
    interpreter_args: process.platform === 'win32' ? '/c' : '',
    autorestart: true,
    max_restarts: 50,
    min_uptime: 5000,
    restart_delay: 2000,
    max_memory_restart: '200M',
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    error_file: '${path.join(installDir, 'logs', 'sidecar-error.log').replace(/\\/g, '\\\\')}',
    out_file: '${path.join(installDir, 'logs', 'sidecar-out.log').replace(/\\/g, '\\\\')}',
    merge_logs: true,
    env: { NODE_ENV: 'production' }
  }]
};
`;

  // Create logs directory
  fs.mkdirSync(path.join(installDir, 'logs'), { recursive: true });
  fs.writeFileSync(ecosystemPath, ecosystemContent);

  // Stop existing process if any (idempotent)
  try {
    execSync(`pm2 delete ${pm2Name}`, { stdio: 'pipe', windowsHide: true });
  } catch {
    // Process didn't exist -- fine
  }

  // Start via ecosystem config
  try {
    execSync(`pm2 start "${ecosystemPath}"`, {
      stdio: 'pipe',
      windowsHide: true,
      timeout: 30000
    });
  } catch (err) {
    logStep(6, 7, `Starting pm2 process "${pm2Name}"`, 'fail');
    const stderr = (err.stderr || '').toString().trim();
    fatal(`pm2 start failed: ${stderr || err.message}`);
  }

  // Save pm2 process list for auto-restart on reboot
  try {
    execSync('pm2 save', { stdio: 'pipe', windowsHide: true });
  } catch {
    // Non-fatal: pm2 save failing doesn't block onboarding
  }

  logStep(6, 7, `Starting pm2 process "${pm2Name}"`, 'done');

  // Wait for sidecar to connect to hub
  console.log('  Waiting 3 seconds for sidecar to connect...');
  const waitUntil = Date.now() + 3000;
  while (Date.now() < waitUntil) {
    // Busy-wait (synchronous sleep for CLI script)
  }

  markStep(progress, 'pm2');
  return pm2Name;
}

// =============================================================================
// Step 7: Verify with Test Task
// =============================================================================

async function verifyTestTask(progress) {
  logStep(7, 7, 'Verifying with test task', 'start');

  const pm2Name = `agentcom-${progress.agent_name}`;

  // Submit test task
  let taskId;
  try {
    const res = await httpRequest('POST', `${HUB_URL}/api/tasks`, {
      description: `Onboarding test: echo 'Agent ${progress.agent_name} online'`,
      priority: 'urgent',
      metadata: { onboarding_test: true }
    }, {
      'Authorization': `Bearer ${progress.token}`
    });

    if (res.statusCode !== 201 && res.statusCode !== 200) {
      logStep(7, 7, 'Verifying with test task', 'fail');
      console.error(`  Test task submission failed with status ${res.statusCode}: ${JSON.stringify(res.body)}`);
      console.error(`  Agent is registered and running, but test task could not be submitted.`);
      console.error(`  Check sidecar logs: pm2 logs ${pm2Name}`);
      return false;
    }

    taskId = res.body.task_id || res.body.id;
  } catch (err) {
    logStep(7, 7, 'Verifying with test task', 'fail');
    console.error(`  Test task submission error: ${err.message}`);
    console.error(`  Agent is registered and running, but test task could not be submitted.`);
    console.error(`  Check sidecar logs: pm2 logs ${pm2Name}`);
    return false;
  }

  if (!taskId) {
    logStep(7, 7, 'Verifying with test task', 'fail');
    console.error('  Test task submitted but no task_id returned.');
    return false;
  }

  console.log(` polling task ${taskId}...`);

  // Poll for completion (30 seconds, every 2 seconds)
  const deadline = Date.now() + 30000;
  let completed = false;

  while (Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 2000));

    try {
      const res = await httpRequest('GET', `${HUB_URL}/api/tasks/${taskId}`, null, {
        'Authorization': `Bearer ${progress.token}`
      });

      if (res.statusCode === 200 && res.body) {
        const status = res.body.status;
        if (status === 'completed' || status === 'complete') {
          completed = true;
          break;
        }
        if (status === 'failed') {
          logStep(7, 7, 'Verifying with test task', 'fail');
          console.error(`  Test task failed. Check sidecar logs: pm2 logs ${pm2Name}`);
          return false;
        }
      }
    } catch {
      // Poll error -- keep trying until deadline
    }
  }

  if (!completed) {
    logStep(7, 7, 'Verifying with test task', 'fail');
    console.error(`\n  HARD FAILURE: Agent registered and running but test task did not complete within 30 seconds.`);
    console.error(`  Check sidecar logs: pm2 logs ${pm2Name}`);
    console.error(`  The agent may still become operational once the sidecar connects.`);
    return false;
  }

  logStep(7, 7, 'Verifying with test task', 'done');
  markStep(progress, 'verify');
  return true;
}

// =============================================================================
// Quick-Start Guide
// =============================================================================

function printQuickStart(progress) {
  const name = progress.agent_name;
  const pm2Name = `agentcom-${name}`;
  const installDir = path.join(os.homedir(), '.agentcom', name);
  const hubUrl = progress.hub_api_url || HUB_URL;

  console.log(`
=====================================
  Agent "${name}" is online!
=====================================

Quick start:
  Submit a task:   curl -X POST ${hubUrl}/api/tasks -H 'Authorization: Bearer ${progress.token}' -H 'Content-Type: application/json' -d '{"description":"Fix the login bug","priority":"normal"}'
  Check status:    pm2 status ${pm2Name}
  View logs:       pm2 logs ${pm2Name}
  View dashboard:  open ${hubUrl} in browser

Agent directory:   ${installDir}
Sidecar config:    ${path.join(installDir, 'repo', 'sidecar', 'config.json')}
`);
}

// =============================================================================
// Main
// =============================================================================

async function main() {
  console.log('AgentCom Add Agent');
  console.log('==================\n');

  // Determine initial agent name (for progress tracking)
  let agentName = args.name || 'unknown';
  currentAgentName = agentName !== 'unknown' ? agentName : null;

  // Load progress (for --resume or --rejoin with existing progress)
  let progress;
  if (args.resume && agentName !== 'unknown') {
    progress = loadProgress(agentName);
    if (progress.steps_completed.length > 0) {
      console.log(`Resuming onboarding for "${progress.agent_name}" (${progress.steps_completed.length} steps completed)\n`);
    }
  } else if (args.rejoin && agentName !== 'unknown') {
    // Load existing progress to recover token if --token not provided
    const existing = loadProgress(agentName);
    progress = {
      agent_name: agentName,
      hub_url: HUB_URL,
      steps_completed: [],
      token: existing.token || null,
      default_repo: null
    };
    console.log(`Rejoining existing agent "${agentName}" (fresh setup with existing identity)\n`);
  } else {
    progress = {
      agent_name: agentName,
      hub_url: HUB_URL,
      steps_completed: [],
      token: null,
      default_repo: null
    };
  }

  try {
    // Step 1: Pre-flight
    await preflight(progress);

    // Step 2: Register
    progress = await registerAgent(progress);
    currentAgentName = progress.agent_name;

    // Step 3: Clone
    const repoDir = await cloneRepo(progress);

    // Step 4: Config
    generateConfig(progress, repoDir);

    // Step 5: Install deps
    installDeps(progress, repoDir);

    // Step 6: Start pm2
    startPm2(progress, repoDir);

    // Step 7: Verify
    const verified = await verifyTestTask(progress);

    // Print results
    if (verified) {
      printQuickStart(progress);
    } else {
      console.log(`\nAgent "${progress.agent_name}" is registered and running but test task verification failed.`);
      console.log('The agent may still become operational. Check the sidecar logs for details.');
      process.exit(1);
    }

  } catch (err) {
    console.error(`\nUnexpected error: ${err.message}`);
    if (currentAgentName) {
      console.error(`\nTo resume: node add-agent.js --hub ${HUB_URL} --name ${currentAgentName} --resume`);
    }
    process.exit(1);
  }
}

main();
