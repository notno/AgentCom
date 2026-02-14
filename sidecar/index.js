'use strict';

const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');
const chokidar = require('chokidar');

// Extracted modules
const { loadQueue, saveQueue, cleanupResultFiles } = require('./lib/queue');
const { interpolateWakeCommand, execCommand, RETRY_DELAYS } = require('./lib/wake');
const { runGitCommand } = require('./lib/git-workflow');
const { initLogger, log, LEVELS } = require('./lib/log');
const { collectMetrics } = require('./lib/resources');
const { runVerification } = require('./verification');
const { WorkspaceManager } = require('./lib/workspace-manager');
const { gatherDiffMeta } = require('./agentcom-git');
const os = require('os');

// =============================================================================
// 1. Config Loader
// =============================================================================

const CONFIG_PATH = path.join(__dirname, 'config.json');

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    log('error', 'config_not_found', { path: CONFIG_PATH, hint: 'cp config.json.example config.json' }, 'sidecar/config');
    process.exit(1);
  }

  const raw = fs.readFileSync(CONFIG_PATH, 'utf8');
  const config = JSON.parse(raw);

  const required = ['agent_id', 'token', 'hub_url'];
  for (const field of required) {
    if (!config[field]) {
      log('error', 'config_missing_field', { field }, 'sidecar/config');
      process.exit(1);
    }
  }

  // Defaults
  config.capabilities = config.capabilities || [];
  config.confirmation_timeout_ms = config.confirmation_timeout_ms || 30000;
  config.results_dir = config.results_dir || './results';
  config.log_file = config.log_file || './sidecar.log';

  // Ollama / resource reporting (optional -- backward-compatible)
  config.ollama_url = config.ollama_url || null;

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
// 2. Structured Logging (provided by lib/log.js)
// =============================================================================

let _config = null; // Will be set after config loads
let _workspaceManager = null; // Phase 23: multi-repo workspace manager

// =============================================================================
// 3. Queue Manager
// =============================================================================
// Queue data model (per CONTEXT.md: max 1 active + 1 recovering)
// { active: { task_id, description, metadata, status, assigned_at, wake_attempts }, recovering: null }

const QUEUE_PATH = path.join(__dirname, 'queue.json');

let _queue = { active: null, recovering: null };

// =============================================================================
// 4. Wake Command Execution
// =============================================================================

/**
 * Wake the agent with configurable command, retry logic, and confirmation timeout.
 * Status flow: accepted -> waking -> waking_confirmation -> working -> (removed)
 */
async function wakeAgent(task, hub) {
  const wakeCommand = _config.wake_command;

  if (!wakeCommand) {
    log('error', 'no_wake_command', {
      task_id: task.task_id,
      reason: 'wake_command not configured and no execution routing available'
    });
    task.status = 'failed';
    saveQueue(QUEUE_PATH, _queue);
    hub.sendTaskFailed(task.task_id, 'no_wake_command_configured');
    hub.send({
      type: 'wake_result',
      task_id: task.task_id,
      status: 'failed',
      attempt: 0,
      error: 'no_wake_command_configured'
    });
    _queue.active = null;
    saveQueue(QUEUE_PATH, _queue);
    return;
  }

  // Update status to waking
  task.status = 'waking';
  saveQueue(QUEUE_PATH, _queue);

  const interpolatedCommand = interpolateWakeCommand(wakeCommand, task);

  for (let attempt = 1; attempt <= RETRY_DELAYS.length + 1; attempt++) {
    task.wake_attempts = attempt;
    saveQueue(QUEUE_PATH, _queue);

    log('info', 'wake_attempt', { task_id: task.task_id, attempt, command: interpolatedCommand });

    try {
      const result = await execCommand(interpolatedCommand);
      log('info', 'wake_success', { task_id: task.task_id, attempt, exit_code: 0, stdout: result.stdout.trim() });

      // PIPE-01: Report wake success to hub
      hub.send({
        type: 'wake_result',
        task_id: task.task_id,
        status: 'success',
        attempt: attempt
      });

      // Successful wake -- start confirmation timeout
      task.status = 'waking_confirmation';
      saveQueue(QUEUE_PATH, _queue);

      startConfirmationTimeout(task, hub);
      return; // Exit retry loop on success

    } catch (err) {
      log('error', 'wake_error', { task_id: task.task_id, attempt, error: err.message, stderr: err.stderr });

      if (attempt <= RETRY_DELAYS.length) {
        const delay = RETRY_DELAYS[attempt - 1];
        log('warning', 'wake_retry', { task_id: task.task_id, attempt, next_attempt: attempt + 1, delay_ms: delay });
        await new Promise(resolve => setTimeout(resolve, delay));
      } else {
        // All retries exhausted
        log('error', 'wake_failed', { task_id: task.task_id, attempts: attempt, error: err.message });
        task.status = 'failed';
        saveQueue(QUEUE_PATH, _queue);

        // PIPE-01: Report wake failure to hub
        hub.send({
          type: 'wake_result',
          task_id: task.task_id,
          status: 'failed',
          attempt: attempt,
          error: err.message
        });

        hub.sendTaskFailed(task.task_id, 'wake_failed_after_3_attempts');

        // Clear active task
        _queue.active = null;
        saveQueue(QUEUE_PATH, _queue);
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

  log('info', 'confirmation_wait', { task_id: task.task_id, timeout_ms: timeout });

  const timer = setTimeout(() => {
    // Check if task is still in waking_confirmation (might have been confirmed already)
    if (!_queue.active || _queue.active.task_id !== task.task_id || _queue.active.status !== 'waking_confirmation') {
      return; // Already handled
    }

    log('warning', 'confirmation_timeout', { task_id: task.task_id, timeout_ms: timeout });

    // PIPE-01: Report confirmation timeout to hub
    hub.send({
      type: 'wake_result',
      task_id: task.task_id,
      status: 'timeout',
      reason: 'confirmation_timeout'
    });

    // Treat as wake failure -- report to hub
    task.status = 'failed';
    saveQueue(QUEUE_PATH, _queue);

    hub.sendTaskFailed(task.task_id, 'confirmation_timeout');

    _queue.active = null;
    saveQueue(QUEUE_PATH, _queue);
  }, timeout);

  // Store timer reference on task for cleanup
  task._confirmationTimer = timer;
}

/**
 * Handle confirmation: .started file detected.
 */
function handleConfirmation(taskId) {
  if (!_queue.active || _queue.active.task_id !== taskId) {
    log('debug', 'confirmation_ignored', { task_id: taskId, reason: 'not_active_task' });
    return;
  }

  if (_queue.active.status !== 'waking_confirmation') {
    log('debug', 'confirmation_ignored', { task_id: taskId, reason: 'unexpected_status', status: _queue.active.status });
    return;
  }

  // Clear confirmation timer
  if (_queue.active._confirmationTimer) {
    clearTimeout(_queue.active._confirmationTimer);
    delete _queue.active._confirmationTimer;
  }

  log('info', 'confirmation_received', { task_id: taskId });
  _queue.active.status = 'working';
  saveQueue(QUEUE_PATH, _queue);
}

/**
 * Handle task result: .json file detected in results directory.
 * Flow: parse result -> run verification -> git push (if passed) -> sendTaskComplete (always, with report)
 */
async function handleResult(taskId, filePath, hub) {
  if (!_queue.active || _queue.active.task_id !== taskId) {
    log('debug', 'result_ignored', { task_id: taskId, reason: 'not_active_task' });
    return;
  }

  let result;
  try {
    const data = fs.readFileSync(filePath, 'utf8');
    result = JSON.parse(data);
  } catch (err) {
    log('error', 'result_parse_error', { task_id: taskId, error: err.message, file: filePath });
    // Treat unparseable result as failure
    hub.sendTaskFailed(taskId, 'result_parse_error: ' + err.message);
    _queue.active = null;
    saveQueue(QUEUE_PATH, _queue);
    cleanupResultFiles(taskId, _config.results_dir);
    return;
  }

  // Determine success/failure from result content
  if (result.status === 'success') {
    // Run verification checks before git push
    const verificationReport = await runVerification(_queue.active, _config);
    result.verification_report = verificationReport;

    log('info', 'verification_complete', {
      task_id: taskId,
      status: verificationReport.status,
      passed: verificationReport.summary ? verificationReport.summary.passed : 0,
      failed: verificationReport.summary ? verificationReport.summary.failed : 0
    });

    // Only do git workflow if verification passed or was skipped/auto-passed
    const skipGit = verificationReport.status === 'fail' || verificationReport.status === 'error';
    let riskClassification = null;

    if (_config.repo_dir && !skipGit) {
      // Gather diff metadata for risk classification (direct call, no child process)
      const diffMeta = gatherDiffMeta(_config);

      log('info', 'diff_meta_gathered', { task_id: taskId, lines_added: diffMeta.lines_added, lines_deleted: diffMeta.lines_deleted, files: (diffMeta.files_changed || []).length });

      // Classify risk tier via hub API
      try {
        riskClassification = await classifyTask(_config, taskId, diffMeta);
        log('info', 'risk_classified', { task_id: taskId, tier: riskClassification.tier, reasons: riskClassification.reasons });
      } catch (err) {
        riskClassification = { tier: 2, reasons: ['classification unavailable'], auto_merge_eligible: false };
        log('warning', 'risk_classify_fallback', { task_id: taskId, error: err.message });
      }

      const gitResult = runGitCommand('submit', {
        agent_id: _config.agent_id,
        task_id: taskId,
        task: _queue.active,
        risk_classification: riskClassification
      });

      if (gitResult.status === 'ok') {
        result.pr_url = gitResult.pr_url;
        log('info', 'git_submit_ok', { task_id: taskId, pr_url: gitResult.pr_url });
      } else {
        log('warning', 'git_submit_failed', { task_id: taskId, error: gitResult.error });
        // Still report task complete, just without PR URL
      }
    } else if (skipGit) {
      log('info', 'git_skipped_verification_failed', {
        task_id: taskId,
        verification_status: verificationReport.status
      });
    }

    // Include risk_classification in result for hub storage
    if (riskClassification) {
      result.risk_classification = riskClassification;
    }

    // Always send task_complete with verification_report
    // (hub decides task status based on report)
    log('info', 'task_complete', { task_id: taskId, output: result.output, pr_url: result.pr_url, risk_tier: riskClassification ? riskClassification.tier : null });
    hub.sendTaskComplete(taskId, result);
  } else {
    const reason = result.reason || result.error || 'unknown';
    log('warning', 'task_failed', { task_id: taskId, reason });
    hub.sendTaskFailed(taskId, reason);
  }

  // Clear confirmation timer if still running
  if (_queue.active._confirmationTimer) {
    clearTimeout(_queue.active._confirmationTimer);
  }

  // Clear active task
  _queue.active = null;
  saveQueue(QUEUE_PATH, _queue);

  // Clean up result files
  cleanupResultFiles(taskId, _config.results_dir);
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
      log('debug', 'result_watcher_started_file', { task_id: taskId, file: filePath });
      handleConfirmation(taskId);
      return;
    }

    // Handle .json files (result)
    if (filename.endsWith('.json')) {
      const taskId = filename.replace('.json', '');
      log('debug', 'result_watcher_result_file', { task_id: taskId, file: filePath });
      handleResult(taskId, filePath, hub);
      return;
    }

    // Ignore other files
    log('debug', 'result_watcher_unknown_file', { file: filePath });
  });

  _resultWatcher.on('error', (err) => {
    log('error', 'result_watcher_error', { error: err.message });
  });

  log('info', 'result_watcher_started', { results_dir: resultsDir });
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
// 5b. Risk Classification Helper
// =============================================================================

/**
 * Call hub classify endpoint to get risk tier for a completed task.
 * On any error, returns Tier 2 default (fail-safe, never blocks PR creation).
 */
function classifyTask(config, taskId, diffMeta) {
  const url = `${config.hub_api_url}/api/tasks/${taskId}/classify`;
  const body = JSON.stringify(diffMeta);

  return new Promise((resolve) => {
    const defaultResult = { tier: 2, reasons: ['classification unavailable'], auto_merge_eligible: false };

    if (!config.hub_api_url) {
      resolve(defaultResult);
      return;
    }

    try {
      const urlObj = new URL(url);
      const httpModule = urlObj.protocol === 'https:' ? require('https') : require('http');

      const req = httpModule.request({
        hostname: urlObj.hostname,
        port: urlObj.port,
        path: urlObj.pathname,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${config.token}`
        },
        timeout: 10000
      }, (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => {
          try {
            if (res.statusCode === 200) {
              resolve(JSON.parse(data));
            } else {
              log('warning', 'classify_http_error', { task_id: taskId, status: res.statusCode });
              resolve(defaultResult);
            }
          } catch (err) {
            log('warning', 'classify_parse_error', { task_id: taskId, error: err.message });
            resolve(defaultResult);
          }
        });
      });

      req.on('error', (err) => {
        log('warning', 'classify_request_error', { task_id: taskId, error: err.message });
        resolve(defaultResult);
      });

      req.on('timeout', () => {
        req.destroy();
        log('warning', 'classify_timeout', { task_id: taskId });
        resolve(defaultResult);
      });

      req.write(body);
      req.end();
    } catch (err) {
      log('warning', 'classify_error', { task_id: taskId, error: err.message });
      resolve(defaultResult);
    }
  });
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
    this.resourceInterval = null;
    this.initialResourceTimer = null;
  }

  connect() {
    if (this.shuttingDown) return;

    log('info', 'ws_connecting', { hub_url: this.config.hub_url });

    try {
      this.ws = new WebSocket(this.config.hub_url);
    } catch (err) {
      log('error', 'ws_connect_error', { error: err.message });
      this.scheduleReconnect();
      return;
    }

    this.ws.on('open', () => {
      log('info', 'ws_open');
      this.reconnectDelay = 1000; // Reset backoff on successful connect
      this.identify();
      this.startHeartbeat();
      this.startResourceReporting();
    });

    this.ws.on('close', (code, reason) => {
      const reasonStr = reason ? reason.toString() : '';
      log('warning', 'ws_close', { code, reason: reasonStr });
      this.identified = false;
      this.stopHeartbeat();
      this.stopResourceReporting();
      this.scheduleReconnect();
    });

    this.ws.on('error', (err) => {
      // Error also triggers 'close', so reconnect is handled there
      log('error', 'ws_error', { error: err.message });
    });

    this.ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        this.handleMessage(msg);
      } catch (err) {
        log('error', 'ws_message_parse_error', { error: err.message });
      }
    });
  }

  identify() {
    const payload = {
      type: 'identify',
      agent_id: this.config.agent_id,
      token: this.config.token,
      name: this.config.agent_id,
      status: 'idle',
      capabilities: this.config.capabilities,
      client_type: 'sidecar',
      protocol_version: 1
    };
    if (this.config.ollama_url) {
      payload.ollama_url = this.config.ollama_url;
    }
    this.send(payload);
    log('info', 'identify_sent', { ollama_url: this.config.ollama_url || 'none' });
  }

  scheduleReconnect() {
    if (this.shuttingDown) return;

    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(
      this.reconnectDelay * 2,
      this.maxReconnectDelay
    );

    log('info', 'reconnect_scheduled', { delay_ms: delay, next_delay_ms: this.reconnectDelay });

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
        log('info', 'identified', { agent_id: msg.agent_id });
        // Report any recovering task to hub after identification
        this.reportRecovery();
        break;

      case 'error':
        log('error', 'hub_error', { error: msg.error });
        break;

      case 'pong':
        this.lastPongTime = Date.now();
        break;

      case 'task_assign':
        this.handleTaskAssign(msg);
        break;

      case 'task_ack':
        log('debug', 'task_ack', { task_id: msg.task_id });
        break;

      case 'task_reassign':
        this.handleTaskReassign(msg);
        break;

      case 'task_continue':
        this.handleTaskContinue(msg);
        break;

      case 'task_cancelled':
        this.handleTaskCancelled(msg);
        break;

      default:
        log('debug', 'unhandled_message', { type: msg.type });
        break;
    }
  }

  send(obj) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      log('warning', 'send_failed', { reason: 'not_connected', type: obj.type });
      return false;
    }

    const payload = { ...obj, protocol_version: 1 };
    try {
      this.ws.send(JSON.stringify(payload));
      return true;
    } catch (err) {
      log('error', 'send_error', { error: err.message, type: obj.type });
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
    // Extract verification_report and verification_history as top-level WS fields (not nested inside result)
    const verificationReport = result.verification_report;
    const verificationHistory = result.verification_history;
    const cleanResult = { ...result };
    delete cleanResult.verification_report;
    delete cleanResult.verification_history;

    const sent = this.send({
      type: 'task_complete',
      task_id: taskId,
      result: cleanResult,
      generation,
      verification_report: verificationReport || null,
      verification_history: verificationHistory || null
    });
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
      log('warning', 'task_rejected', { task_id: msg.task_id, reason: 'busy', active_task_id: _queue.active.task_id });
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
      wake_attempts: 0,
      // Enrichment fields (Phase 17)
      repo: msg.repo || null,
      branch: msg.branch || null,
      file_hints: msg.file_hints || [],
      success_criteria: msg.success_criteria || [],
      verification_steps: msg.verification_steps || [],
      complexity: msg.complexity || null,
      // Verification control fields (Phase 21)
      skip_verification: msg.skip_verification || false,
      verification_timeout_ms: msg.verification_timeout_ms || null,
      // Routing decision (Phase 20)
      routing_decision: msg.routing_decision || null,
      // Verification retry config (Phase 22)
      max_verification_retries: msg.max_verification_retries || 0
    };

    // Persist BEFORE acknowledging (crash between accept and persist loses the task)
    _queue.active = task;
    saveQueue(QUEUE_PATH, _queue);

    // Acknowledge to hub
    this.sendTaskAccepted(msg.task_id);
    log('info', 'task_received', { task_id: msg.task_id, description: msg.description });

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
        log('info', 'git_start_task_ok', { task_id: msg.task_id, branch: gitResult.branch });
      } else {
        // Per CONTEXT.md: wake agent anyway with warning
        task.git_warning = gitResult.error || 'start-task failed';
        log('warning', 'git_start_task_failed', { task_id: msg.task_id, error: gitResult.error });
      }
      saveQueue(QUEUE_PATH, _queue);
    }

    // Phase 20: Direct execution when routing_decision present
    const routing = task.routing_decision;
    if (routing && routing.target_type && routing.target_type !== 'wake') {
      this.executeTask(task);
    } else {
      // Legacy: wake agent and watch for result file
      wakeAgent(task, this);
    }
  }

  // ---------------------------------------------------------------------------
  // Phase 20: Direct Execution via Execution Engine
  // ---------------------------------------------------------------------------

  /**
   * Execute a task directly using the execution engine (dispatcher).
   * Called when task has a routing_decision with a concrete target_type.
   * Streams progress events to hub via WebSocket, reports completion/failure.
   */
  async executeTask(task) {
    const { executeWithVerification } = require('./lib/execution/verification-loop');
    const { ProgressEmitter } = require('./lib/execution/progress-emitter');

    // Resolve per-task workspace (Phase 23: multi-repo support)
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

    const emitter = new ProgressEmitter((events) => {
      for (const event of events) {
        this.send({
          type: 'task_progress',
          task_id: task.task_id,
          execution_event: {
            event_type: event.type,
            text: event.text || event.message || '',
            tokens_so_far: event.tokens_so_far || null,
            model: event.model || null,
            timestamp: Date.now()
          }
        });
      }
    }, { batchIntervalMs: 100 });

    try {
      task.status = 'working';
      saveQueue(QUEUE_PATH, _queue);

      const result = await executeWithVerification(task, effectiveConfig, (event) => emitter.emit(event));
      emitter.flush();
      emitter.destroy();

      this.sendTaskComplete(task.task_id, {
        status: result.status,
        output: result.output,
        model_used: result.model_used,
        tokens_in: result.tokens_in,
        tokens_out: result.tokens_out,
        estimated_cost_usd: result.estimated_cost_usd,
        equivalent_claude_cost_usd: result.equivalent_claude_cost_usd,
        execution_ms: result.execution_ms,
        verification_report: result.verification_report,
        verification_history: result.verification_history,
        verification_status: result.verification_status,
        verification_attempts: result.verification_attempts
      });
    } catch (err) {
      emitter.destroy();
      log('error', 'execution_failed', { task_id: task.task_id, error: err.message });
      this.sendTaskFailed(task.task_id, err.message);
    }

    _queue.active = null;
    saveQueue(QUEUE_PATH, _queue);
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
    log('info', 'recovery_reporting', { task_id: task.task_id, last_status: task.status });

    this.send({
      type: 'task_recovering',
      task_id: task.task_id,
      description: task.description,
      metadata: task.metadata,
      last_status: task.status,
      protocol_version: 1
    });

    log('info', 'recovery_reported', { task_id: task.task_id });
  }

  /**
   * Hub is taking the recovering task back (default Phase 1 behavior).
   * Clear recovering slot so sidecar is idle and ready for new tasks.
   */
  handleTaskCancelled(msg) {
    const taskId = msg.task_id;
    log('info', 'task_cancelled_by_hub', { task_id: taskId });

    // Clear active task if it matches
    if (_queue.active && _queue.active.task_id === taskId) {
      _queue.active = null;
      saveQueue(QUEUE_PATH, _queue);
      log('info', 'active_task_cleared', { task_id: taskId, reason: 'cancelled' });
    }

    // Clear recovering task if it matches
    if (_queue.recovering && _queue.recovering.task_id === taskId) {
      _queue.recovering = null;
      saveQueue(QUEUE_PATH, _queue);
      log('info', 'recovering_task_cleared', { task_id: taskId, reason: 'cancelled' });
    }

    // Clean up generation tracking
    this.taskGenerations.delete(taskId);
  }

  handleTaskReassign(msg) {
    const taskId = msg.task_id;
    log('info', 'recovery_reassigned', { task_id: taskId });

    // Clean up generation tracking for reassigned task
    this.taskGenerations.delete(taskId);

    if (_queue.recovering && _queue.recovering.task_id === taskId) {
      _queue.recovering = null;
      saveQueue(QUEUE_PATH, _queue);
    } else {
      log('debug', 'recovery_reassign_ignored', { task_id: taskId, reason: 'not_recovering_task' });
    }
  }

  /**
   * Hub says the agent is still working on the recovering task (future Phase 2+ behavior).
   * Move recovering back to active and resume watching for result file.
   */
  handleTaskContinue(msg) {
    const taskId = msg.task_id;
    log('info', 'recovery_continued', { task_id: taskId });

    // Update generation from task_continue message (may have changed during recovery)
    if (msg.generation !== undefined) {
      this.taskGenerations.set(taskId, msg.generation);
    }

    if (_queue.recovering && _queue.recovering.task_id === taskId) {
      _queue.active = _queue.recovering;
      _queue.recovering = null;
      saveQueue(QUEUE_PATH, _queue);
    } else {
      log('debug', 'recovery_continue_ignored', { task_id: taskId, reason: 'not_recovering_task' });
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
          log('warning', 'heartbeat_timeout', { last_pong: this.lastPongTime, ping_sent: pingTime });
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
  // Resource Reporting: collect CPU/RAM/VRAM and send to hub every 30 seconds
  // ---------------------------------------------------------------------------

  /**
   * Send a single resource_report message with current host metrics.
   */
  async sendResourceReport() {
    if (!this.identified) return;
    try {
      const metrics = await collectMetrics(this.config.ollama_url);
      this.send({
        type: 'resource_report',
        agent_id: this.config.agent_id,
        ...metrics,
        timestamp: Date.now()
      });
      log('debug', 'resource_report_sent', { cpu_percent: metrics.cpu_percent, ram_used_bytes: metrics.ram_used_bytes });
    } catch (err) {
      log('warning', 'resource_report_error', { error: err.message });
    }
  }

  /**
   * Start periodic resource reporting every 30 seconds.
   * Also schedules an initial report 5 seconds after identify.
   */
  startResourceReporting() {
    this.stopResourceReporting();

    // Initial report after 5 seconds (gives identify time to complete)
    this.initialResourceTimer = setTimeout(() => {
      this.initialResourceTimer = null;
      this.sendResourceReport();
    }, 5000);

    // Periodic report every 30 seconds
    this.resourceInterval = setInterval(() => {
      this.sendResourceReport();
    }, 30000);

    log('info', 'resource_reporting_started', { interval_ms: 30000 });
  }

  /**
   * Stop periodic resource reporting.
   */
  stopResourceReporting() {
    if (this.initialResourceTimer) {
      clearTimeout(this.initialResourceTimer);
      this.initialResourceTimer = null;
    }
    if (this.resourceInterval) {
      clearInterval(this.resourceInterval);
      this.resourceInterval = null;
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
    this.stopResourceReporting();

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
    log('info', 'shutdown', { signal });
    // Stop result watcher
    stopResultWatcher();
    // Save current queue state before closing
    saveQueue(QUEUE_PATH, _queue);
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

  // Initialize structured logger with config (agent_id, log_file, log_level)
  initLogger(config);

  log('info', 'startup', {
    agent_id: config.agent_id,
    hub_url: config.hub_url,
    capabilities: config.capabilities,
    version: '1.0.0'
  });

  // Initialize workspace manager for multi-repo support (Phase 23)
  const agentName = config.agent_id || 'unknown';
  const wsBaseDir = path.join(os.homedir(), '.agentcom', agentName, 'workspaces');
  try {
    _workspaceManager = new WorkspaceManager(wsBaseDir);
  } catch (err) {
    log('warning', 'workspace_manager_init_failed', { error: err.message });
  }

  // Load persisted queue state and check for incomplete tasks (crash recovery)
  _queue = loadQueue(QUEUE_PATH);
  if (_queue.active) {
    log('warning', 'recovery_found', { task_id: _queue.active.task_id, status: _queue.active.status });
    // Move active to recovering slot -- sidecar crashed while task was in progress
    _queue.recovering = _queue.active;
    _queue.active = null;
    saveQueue(QUEUE_PATH, _queue);
  }

  // Create connection and connect
  const hub = new HubConnection(config);
  hub.connect();

  // Start watching results directory for task completion files
  startResultWatcher(hub);

  // Set up graceful shutdown
  setupGracefulShutdown(hub);

  log('info', 'ready', { agent_id: config.agent_id });
}

// =============================================================================
// 9. Global Error Handlers
// =============================================================================

process.on('unhandledRejection', (reason) => {
  log('error', 'unhandled_rejection', { reason: String(reason) });
});

process.on('uncaughtException', (err) => {
  log('error', 'uncaught_exception', { error: err.message, stack: err.stack });
  process.exit(1);
});

main();
