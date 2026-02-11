'use strict';

const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');
const writeFileAtomic = require('write-file-atomic');
const { exec, execSync, spawnSync } = require('child_process');
const chokidar = require('chokidar');

// =============================================================================
// 1. Config Loader
// =============================================================================

const CONFIG_PATH = path.join(__dirname, 'config.json');

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    console.error(
      'ERROR: config.json not found.\n' +
      'Copy config.json.example to config.json and fill in your values:\n' +
      '  cp config.json.example config.json\n'
    );
    process.exit(1);
  }

  const raw = fs.readFileSync(CONFIG_PATH, 'utf8');
  const config = JSON.parse(raw);

  const required = ['agent_id', 'token', 'hub_url'];
  for (const field of required) {
    if (!config[field]) {
      console.error(`ERROR: config.json missing required field: ${field}`);
      process.exit(1);
    }
  }

  // Defaults
  config.capabilities = config.capabilities || [];
  config.confirmation_timeout_ms = config.confirmation_timeout_ms || 30000;
  config.results_dir = config.results_dir || './results';
  config.log_file = config.log_file || './sidecar.log';

  // Git workflow defaults (optional -- backward-compatible)
  config.repo_dir = config.repo_dir || '';
  config.reviewer = config.reviewer || '';
  config.hub_api_url = config.hub_api_url || '';

  // Resolve relative paths against __dirname
  if (!path.isAbsolute(config.log_file)) {
    config.log_file = path.join(__dirname, config.log_file);
  }
  if (!path.isAbsolute(config.results_dir)) {
    config.results_dir = path.join(__dirname, config.results_dir);
  }
  if (config.repo_dir && !path.isAbsolute(config.repo_dir)) {
    config.repo_dir = path.join(__dirname, config.repo_dir);
  }

  return config;
}

// =============================================================================
// 2. Structured Logging
// =============================================================================

let _config = null; // Will be set after config loads

function log(event, data = {}) {
  const entry = {
    ts: new Date().toISOString(),
    event,
    agent_id: _config ? _config.agent_id : 'unknown',
    ...data
  };

  const line = JSON.stringify(entry) + '\n';

  // Write to log file
  if (_config && _config.log_file) {
    try {
      fs.appendFileSync(_config.log_file, line);
    } catch (err) {
      console.error(`Failed to write to log file: ${err.message}`);
    }
  }

  // Also console.log for pm2 stdout capture
  console.log(`[${entry.ts}] ${event}`, Object.keys(data).length > 0 ? data : '');
}

// =============================================================================
// 3. Queue Manager
// =============================================================================
// Queue data model (per CONTEXT.md: max 1 active + 1 recovering)
// { active: { task_id, description, metadata, status, assigned_at, wake_attempts }, recovering: null }

const QUEUE_PATH = path.join(__dirname, 'queue.json');

let _queue = { active: null, recovering: null };

function loadQueue() {
  try {
    const data = fs.readFileSync(QUEUE_PATH, 'utf8');
    return JSON.parse(data);
  } catch (err) {
    if (err.code === 'ENOENT') return { active: null, recovering: null };
    // Corrupted file -- fall back to empty (per research pitfall #3)
    log('queue_corrupt', { error: err.message });
    return { active: null, recovering: null };
  }
}

function saveQueue(queue) {
  // Atomic write: write to temp file, then rename
  // Per CONTEXT.md locked decision: atomic writes to prevent corruption on crash
  writeFileAtomic.sync(QUEUE_PATH, JSON.stringify(queue, null, 2));
}

// =============================================================================
// 4. Wake Command Execution
// =============================================================================

const RETRY_DELAYS = [5000, 15000, 30000]; // 5s, 15s, 30s per CONTEXT.md

/**
 * Interpolate template variables in wake command string.
 * Supported: ${TASK_ID}, ${TASK_JSON}, ${TASK_DESCRIPTION}
 */
function interpolateWakeCommand(command, task) {
  return command
    .replace(/\$\{TASK_ID\}/g, task.task_id)
    .replace(/\$\{TASK_JSON\}/g, JSON.stringify(task).replace(/"/g, '\\"'))
    .replace(/\$\{TASK_DESCRIPTION\}/g, (task.description || '').replace(/"/g, '\\"'));
}

/**
 * Execute a shell command and return a promise.
 */
function execCommand(command) {
  return new Promise((resolve, reject) => {
    exec(command, {
      timeout: 60000,      // Kill if wake command itself hangs
      shell: true,         // Required for Windows .bat/.cmd files (per research pitfall #2)
      windowsHide: true    // Prevent cmd window popup on Windows
    }, (error, stdout, stderr) => {
      if (error) {
        reject({ code: error.code, signal: error.signal, stderr, message: error.message });
      } else {
        resolve({ code: 0, stdout, stderr });
      }
    });
  });
}

/**
 * Wake the agent with configurable command, retry logic, and confirmation timeout.
 * Status flow: accepted -> waking -> waking_confirmation -> working -> (removed)
 */
async function wakeAgent(task, hub) {
  const wakeCommand = _config.wake_command;

  if (!wakeCommand) {
    log('wake_skipped', { task_id: task.task_id, reason: 'no wake_command configured' });
    // Update status to working directly (agent expected to self-start)
    task.status = 'working';
    saveQueue(_queue);
    return;
  }

  // Update status to waking
  task.status = 'waking';
  saveQueue(_queue);

  const interpolatedCommand = interpolateWakeCommand(wakeCommand, task);

  for (let attempt = 1; attempt <= RETRY_DELAYS.length + 1; attempt++) {
    task.wake_attempts = attempt;
    saveQueue(_queue);

    log('wake_attempt', { task_id: task.task_id, attempt, command: interpolatedCommand });

    try {
      const result = await execCommand(interpolatedCommand);
      log('wake_success', { task_id: task.task_id, attempt, exit_code: 0, stdout: result.stdout.trim() });

      // Successful wake -- start confirmation timeout
      task.status = 'waking_confirmation';
      saveQueue(_queue);

      startConfirmationTimeout(task, hub);
      return; // Exit retry loop on success

    } catch (err) {
      log('wake_error', { task_id: task.task_id, attempt, error: err.message, stderr: err.stderr });

      if (attempt <= RETRY_DELAYS.length) {
        const delay = RETRY_DELAYS[attempt - 1];
        log('wake_retry', { task_id: task.task_id, attempt, next_attempt: attempt + 1, delay_ms: delay });
        await new Promise(resolve => setTimeout(resolve, delay));
      } else {
        // All retries exhausted
        log('wake_failed', { task_id: task.task_id, attempts: attempt, error: err.message });
        task.status = 'failed';
        saveQueue(_queue);

        hub.sendTaskFailed(task.task_id, 'wake_failed_after_3_attempts');

        // Clear active task
        _queue.active = null;
        saveQueue(_queue);
        return;
      }
    }
  }
}

/**
 * Start confirmation timeout -- wait for .started file within timeout period.
 * If timeout expires, treat as failure and go through retry logic.
 */
function startConfirmationTimeout(task, hub) {
  const timeout = _config.confirmation_timeout_ms || 30000;

  log('confirmation_wait', { task_id: task.task_id, timeout_ms: timeout });

  const timer = setTimeout(() => {
    // Check if task is still in waking_confirmation (might have been confirmed already)
    if (!_queue.active || _queue.active.task_id !== task.task_id || _queue.active.status !== 'waking_confirmation') {
      return; // Already handled
    }

    log('confirmation_timeout', { task_id: task.task_id, timeout_ms: timeout });

    // Treat as wake failure -- report to hub
    task.status = 'failed';
    saveQueue(_queue);

    hub.sendTaskFailed(task.task_id, 'confirmation_timeout');

    _queue.active = null;
    saveQueue(_queue);
  }, timeout);

  // Store timer reference on task for cleanup
  task._confirmationTimer = timer;
}

/**
 * Handle confirmation: .started file detected.
 */
function handleConfirmation(taskId) {
  if (!_queue.active || _queue.active.task_id !== taskId) {
    log('confirmation_ignored', { task_id: taskId, reason: 'not_active_task' });
    return;
  }

  if (_queue.active.status !== 'waking_confirmation') {
    log('confirmation_ignored', { task_id: taskId, reason: 'unexpected_status', status: _queue.active.status });
    return;
  }

  // Clear confirmation timer
  if (_queue.active._confirmationTimer) {
    clearTimeout(_queue.active._confirmationTimer);
    delete _queue.active._confirmationTimer;
  }

  log('confirmation_received', { task_id: taskId });
  _queue.active.status = 'working';
  saveQueue(_queue);
}

/**
 * Handle task result: .json file detected in results directory.
 */
function handleResult(taskId, filePath, hub) {
  if (!_queue.active || _queue.active.task_id !== taskId) {
    log('result_ignored', { task_id: taskId, reason: 'not_active_task' });
    return;
  }

  let result;
  try {
    const data = fs.readFileSync(filePath, 'utf8');
    result = JSON.parse(data);
  } catch (err) {
    log('result_parse_error', { task_id: taskId, error: err.message, file: filePath });
    // Treat unparseable result as failure
    hub.sendTaskFailed(taskId, 'result_parse_error: ' + err.message);
    _queue.active = null;
    saveQueue(_queue);
    cleanupResultFiles(taskId);
    return;
  }

  // Determine success/failure from result content
  if (result.status === 'success') {
    // Git workflow: push branch and create PR before reporting to hub
    if (_config.repo_dir) {
      const gitResult = runGitCommand('submit', {
        agent_id: _config.agent_id,
        task_id: taskId,
        task: _queue.active
      });

      if (gitResult.status === 'ok') {
        result.pr_url = gitResult.pr_url;
        log('git_submit_ok', { task_id: taskId, pr_url: gitResult.pr_url });
      } else {
        log('git_submit_failed', { task_id: taskId, error: gitResult.error });
        // Still report task complete, just without PR URL
      }
    }

    log('task_complete', { task_id: taskId, output: result.output, pr_url: result.pr_url });
    hub.sendTaskComplete(taskId, result);
  } else {
    const reason = result.reason || result.error || 'unknown';
    log('task_failed', { task_id: taskId, reason });
    hub.sendTaskFailed(taskId, reason);
  }

  // Clear confirmation timer if still running
  if (_queue.active._confirmationTimer) {
    clearTimeout(_queue.active._confirmationTimer);
  }

  // Clear active task
  _queue.active = null;
  saveQueue(_queue);

  // Clean up result files
  cleanupResultFiles(taskId);
}

/**
 * Delete result and started files for a completed/failed task.
 */
function cleanupResultFiles(taskId) {
  const resultsDir = _config.results_dir;
  const resultFile = path.join(resultsDir, `${taskId}.json`);
  const startedFile = path.join(resultsDir, `${taskId}.started`);

  try {
    if (fs.existsSync(resultFile)) fs.unlinkSync(resultFile);
  } catch (err) {
    log('cleanup_error', { file: resultFile, error: err.message });
  }
  try {
    if (fs.existsSync(startedFile)) fs.unlinkSync(startedFile);
  } catch (err) {
    log('cleanup_error', { file: startedFile, error: err.message });
  }
}

// =============================================================================
// 4b. Git Workflow Integration
// =============================================================================

/**
 * Invoke agentcom-git.js as a child process.
 * Returns parsed JSON output. On error, returns { status: 'error', error: message }.
 */
function runGitCommand(command, args) {
  const gitCliPath = path.join(__dirname, 'agentcom-git.js');
  const result = spawnSync('node', [gitCliPath, command, JSON.stringify(args)], {
    encoding: 'utf-8',
    timeout: 180000,
    windowsHide: true
  });

  const output = (result.stdout || '').trim();
  if (output) {
    try { return JSON.parse(output); } catch {}
  }
  return { status: 'error', error: result.stderr || 'no output from agentcom-git' };
}

// =============================================================================
// 5. Result File Watcher
// =============================================================================

let _resultWatcher = null;

/**
 * Start watching the results directory for task completion files.
 * Expects files named: {task_id}.started (confirmation) and {task_id}.json (result)
 */
function startResultWatcher(hub) {
  const resultsDir = _config.results_dir;

  // Create results directory if it doesn't exist
  fs.mkdirSync(resultsDir, { recursive: true });

  _resultWatcher = chokidar.watch(resultsDir, {
    ignoreInitial: true,
    awaitWriteFinish: {
      stabilityThreshold: 500,  // Wait 500ms for file to finish writing
      pollInterval: 100
    }
  });

  _resultWatcher.on('add', (filePath) => {
    const filename = path.basename(filePath);

    // Handle .started files (confirmation)
    if (filename.endsWith('.started')) {
      const taskId = filename.replace('.started', '');
      log('result_watcher_started_file', { task_id: taskId, file: filePath });
      handleConfirmation(taskId);
      return;
    }

    // Handle .json files (result)
    if (filename.endsWith('.json')) {
      const taskId = filename.replace('.json', '');
      log('result_watcher_result_file', { task_id: taskId, file: filePath });
      handleResult(taskId, filePath, hub);
      return;
    }

    // Ignore other files
    log('result_watcher_unknown_file', { file: filePath });
  });

  _resultWatcher.on('error', (err) => {
    log('result_watcher_error', { error: err.message });
  });

  log('result_watcher_started', { results_dir: resultsDir });
}

/**
 * Stop the result file watcher.
 */
function stopResultWatcher() {
  if (_resultWatcher) {
    _resultWatcher.close();
    _resultWatcher = null;
  }
}

// =============================================================================
// 6. HubConnection Class
// =============================================================================

class HubConnection {
  constructor(config) {
    this.config = config;
    this.ws = null;
    this.identified = false;
    this.reconnectDelay = 1000;       // Start at 1s
    this.maxReconnectDelay = 60000;   // Cap at 60s
    this.reconnectTimer = null;
    this.heartbeatInterval = null;
    this.pongTimer = null;
    this.lastPongTime = null;
    this.shuttingDown = false;
    this.taskGenerations = new Map(); // task_id -> generation from task_assign
  }

  connect() {
    if (this.shuttingDown) return;

    log('ws_connecting', { hub_url: this.config.hub_url });

    try {
      this.ws = new WebSocket(this.config.hub_url);
    } catch (err) {
      log('ws_connect_error', { error: err.message });
      this.scheduleReconnect();
      return;
    }

    this.ws.on('open', () => {
      log('ws_open');
      this.reconnectDelay = 1000; // Reset backoff on successful connect
      this.identify();
      this.startHeartbeat();
    });

    this.ws.on('close', (code, reason) => {
      const reasonStr = reason ? reason.toString() : '';
      log('ws_close', { code, reason: reasonStr });
      this.identified = false;
      this.stopHeartbeat();
      this.scheduleReconnect();
    });

    this.ws.on('error', (err) => {
      // Error also triggers 'close', so reconnect is handled there
      log('ws_error', { error: err.message });
    });

    this.ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        this.handleMessage(msg);
      } catch (err) {
        log('ws_message_parse_error', { error: err.message });
      }
    });
  }

  identify() {
    this.send({
      type: 'identify',
      agent_id: this.config.agent_id,
      token: this.config.token,
      name: this.config.agent_id,
      status: 'idle',
      capabilities: this.config.capabilities,
      client_type: 'sidecar',
      protocol_version: 1
    });
    log('identify_sent');
  }

  scheduleReconnect() {
    if (this.shuttingDown) return;

    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(
      this.reconnectDelay * 2,
      this.maxReconnectDelay
    );

    log('reconnect_scheduled', { delay_ms: delay, next_delay_ms: this.reconnectDelay });

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  handleMessage(msg) {
    switch (msg.type) {
      case 'identified':
        this.identified = true;
        this.reconnectDelay = 1000; // Reset on successful identification
        log('identified', { agent_id: msg.agent_id });
        // Report any recovering task to hub after identification
        this.reportRecovery();
        break;

      case 'error':
        log('hub_error', { error: msg.error });
        break;

      case 'pong':
        this.lastPongTime = Date.now();
        break;

      case 'task_assign':
        this.handleTaskAssign(msg);
        break;

      case 'task_ack':
        log('task_ack', { task_id: msg.task_id });
        break;

      case 'task_reassign':
        this.handleTaskReassign(msg);
        break;

      case 'task_continue':
        this.handleTaskContinue(msg);
        break;

      default:
        log('unhandled_message', { type: msg.type });
        break;
    }
  }

  send(obj) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      log('send_failed', { reason: 'not_connected', type: obj.type });
      return false;
    }

    const payload = { ...obj, protocol_version: 1 };
    try {
      this.ws.send(JSON.stringify(payload));
      return true;
    } catch (err) {
      log('send_error', { error: err.message, type: obj.type });
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Task Lifecycle Senders
  // ---------------------------------------------------------------------------

  sendTaskAccepted(taskId) {
    return this.send({ type: 'task_accepted', task_id: taskId });
  }

  sendTaskComplete(taskId, result) {
    const generation = this.taskGenerations.get(taskId) || 0;
    const sent = this.send({ type: 'task_complete', task_id: taskId, result, generation });
    this.taskGenerations.delete(taskId);
    return sent;
  }

  sendTaskFailed(taskId, reason) {
    const generation = this.taskGenerations.get(taskId) || 0;
    const sent = this.send({ type: 'task_failed', task_id: taskId, reason, generation });
    this.taskGenerations.delete(taskId);
    return sent;
  }

  sendTaskRejected(taskId, reason) {
    return this.send({ type: 'task_rejected', task_id: taskId, reason });
  }

  // ---------------------------------------------------------------------------
  // Task Assignment Handler
  // ---------------------------------------------------------------------------

  handleTaskAssign(msg) {
    // Check if sidecar is already busy with an active task
    if (_queue.active !== null) {
      log('task_rejected', { task_id: msg.task_id, reason: 'busy', active_task_id: _queue.active.task_id });
      this.sendTaskRejected(msg.task_id, 'busy');
      return;
    }

    // Track generation from task_assign for use in task_complete/task_failed
    if (msg.generation !== undefined) {
      this.taskGenerations.set(msg.task_id, msg.generation);
    }

    // Create task object with full payload for crash-safe persistence
    const task = {
      task_id: msg.task_id,
      description: msg.description,
      metadata: msg.metadata || {},
      status: 'accepted',
      assigned_at: msg.assigned_at || Date.now(),
      generation: msg.generation || 0,
      wake_attempts: 0
    };

    // Persist BEFORE acknowledging (crash between accept and persist loses the task)
    _queue.active = task;
    saveQueue(_queue);

    // Acknowledge to hub
    this.sendTaskAccepted(msg.task_id);
    log('task_received', { task_id: msg.task_id, description: msg.description });

    // Git workflow: create branch before waking agent
    if (_config.repo_dir) {
      const gitResult = runGitCommand('start-task', {
        agent_id: this.config.agent_id,
        task_id: msg.task_id,
        description: msg.description || '',
        metadata: msg.metadata || {}
      });

      if (gitResult.status === 'ok') {
        task.branch = gitResult.branch;
        log('git_start_task_ok', { task_id: msg.task_id, branch: gitResult.branch });
      } else {
        // Per CONTEXT.md: wake agent anyway with warning
        task.git_warning = gitResult.error || 'start-task failed';
        log('git_start_task_failed', { task_id: msg.task_id, error: gitResult.error });
      }
      saveQueue(_queue);
    }

    // Start wake process
    wakeAgent(task, this);
  }

  // ---------------------------------------------------------------------------
  // Recovery: report incomplete tasks to hub after identification
  // ---------------------------------------------------------------------------

  /**
   * If a task was in-progress when the sidecar crashed, report it to the hub.
   * Called after successful identification so the WebSocket connection is ready.
   */
  reportRecovery() {
    if (!_queue.recovering) return;

    const task = _queue.recovering;
    log('recovery_reporting', { task_id: task.task_id, last_status: task.status });

    this.send({
      type: 'task_recovering',
      task_id: task.task_id,
      description: task.description,
      metadata: task.metadata,
      last_status: task.status,
      protocol_version: 1
    });

    log('recovery_reported', { task_id: task.task_id });
  }

  /**
   * Hub is taking the recovering task back (default Phase 1 behavior).
   * Clear recovering slot so sidecar is idle and ready for new tasks.
   */
  handleTaskReassign(msg) {
    const taskId = msg.task_id;
    log('recovery_reassigned', { task_id: taskId });

    // Clean up generation tracking for reassigned task
    this.taskGenerations.delete(taskId);

    if (_queue.recovering && _queue.recovering.task_id === taskId) {
      _queue.recovering = null;
      saveQueue(_queue);
    } else {
      log('recovery_reassign_ignored', { task_id: taskId, reason: 'not_recovering_task' });
    }
  }

  /**
   * Hub says the agent is still working on the recovering task (future Phase 2+ behavior).
   * Move recovering back to active and resume watching for result file.
   */
  handleTaskContinue(msg) {
    const taskId = msg.task_id;
    log('recovery_continued', { task_id: taskId });

    // Update generation from task_continue message (may have changed during recovery)
    if (msg.generation !== undefined) {
      this.taskGenerations.set(taskId, msg.generation);
    }

    if (_queue.recovering && _queue.recovering.task_id === taskId) {
      _queue.active = _queue.recovering;
      _queue.recovering = null;
      saveQueue(_queue);
    } else {
      log('recovery_continue_ignored', { task_id: taskId, reason: 'not_recovering_task' });
    }
  }

  // ---------------------------------------------------------------------------
  // Heartbeat: ping every 30s, expect pong within 10s
  // Detects silent WebSocket death (NAT timeout, firewall kill, network partition)
  // ---------------------------------------------------------------------------

  startHeartbeat() {
    this.stopHeartbeat(); // Clear any existing heartbeat

    this.heartbeatInterval = setInterval(() => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

      this.send({ type: 'ping' });

      // Set a timeout to check for pong response
      const pingTime = Date.now();
      this.pongTimer = setTimeout(() => {
        // If no pong received since we sent the ping, connection is dead
        if (!this.lastPongTime || this.lastPongTime < pingTime) {
          log('heartbeat_timeout', { last_pong: this.lastPongTime, ping_sent: pingTime });
          // Force close -- this triggers 'close' event which triggers reconnect
          if (this.ws) {
            try {
              this.ws.terminate();
            } catch (err) {
              // Ignore terminate errors
            }
          }
        }
      }, 10000); // 10s pong timeout
    }, 30000); // 30s ping interval
  }

  stopHeartbeat() {
    if (this.heartbeatInterval) {
      clearInterval(this.heartbeatInterval);
      this.heartbeatInterval = null;
    }
    if (this.pongTimer) {
      clearTimeout(this.pongTimer);
      this.pongTimer = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Shutdown
  // ---------------------------------------------------------------------------

  shutdown() {
    this.shuttingDown = true;

    // Cancel pending reconnect
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    this.stopHeartbeat();

    // Close WebSocket cleanly
    if (this.ws) {
      try {
        this.ws.close(1000, 'shutdown');
      } catch (err) {
        // Ignore close errors during shutdown
      }
    }
  }
}

// =============================================================================
// 7. Graceful Shutdown
// =============================================================================

function setupGracefulShutdown(hub) {
  const shutdown = (signal) => {
    log('shutdown', { signal });
    // Stop result watcher
    stopResultWatcher();
    // Save current queue state before closing
    saveQueue(_queue);
    hub.shutdown();
    // Give a moment for the close frame to send, then exit
    setTimeout(() => {
      process.exit(0);
    }, 500);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  // Windows: handle SIGBREAK (Ctrl+Break)
  if (process.platform === 'win32') {
    process.on('SIGBREAK', () => shutdown('SIGBREAK'));
  }
}

// =============================================================================
// 8. Main Entry Point
// =============================================================================

function main() {
  // Load config
  const config = loadConfig();
  _config = config;

  log('startup', {
    agent_id: config.agent_id,
    hub_url: config.hub_url,
    capabilities: config.capabilities,
    version: '1.0.0'
  });

  // Load persisted queue state and check for incomplete tasks (crash recovery)
  _queue = loadQueue();
  if (_queue.active) {
    log('recovery_found', { task_id: _queue.active.task_id, status: _queue.active.status });
    // Move active to recovering slot -- sidecar crashed while task was in progress
    _queue.recovering = _queue.active;
    _queue.active = null;
    saveQueue(_queue);
  }

  // Create connection and connect
  const hub = new HubConnection(config);
  hub.connect();

  // Start watching results directory for task completion files
  startResultWatcher(hub);

  // Set up graceful shutdown
  setupGracefulShutdown(hub);

  log('ready', { agent_id: config.agent_id });
}

main();
