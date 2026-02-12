'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const DEFAULT_TIMEOUT_MS = 120000;

/**
 * Execute a shell command and capture output + exit status.
 * execSync throws on non-zero exit code, so catch path handles failures.
 *
 * @param {string} command - Shell command string to execute
 * @param {string} [cwd] - Working directory for execution
 * @returns {{ status: string, output: string }}
 */
function runShellCommand(command, cwd) {
  try {
    const output = execSync(command, {
      cwd: cwd || process.cwd(),
      encoding: 'utf8',
      timeout: 0,        // No per-command timeout; global timeout handles it
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true
    });
    return { status: 'pass', output: output || '' };
  } catch (err) {
    // execSync throws on non-zero exit code
    const output = (err.stdout || '') + (err.stderr || '');
    return { status: 'fail', output };
  }
}

/**
 * Resolve test command for test_passes check type.
 * If target is "auto", detect from repo directory contents.
 * Otherwise, use the target string as the literal command.
 *
 * @param {string} target - "auto" or a specific command string
 * @param {string} repoDir - Repository directory for auto-detection
 * @returns {string}
 */
function resolveTestCommand(target, repoDir) {
  if (target !== 'auto') return target;

  const dir = repoDir || '.';
  if (fs.existsSync(path.join(dir, 'mix.exs'))) return 'mix test';
  if (fs.existsSync(path.join(dir, 'package.json'))) return 'npm test';
  if (fs.existsSync(path.join(dir, 'Makefile'))) return 'make test';
  return 'echo No test runner detected';
}

// ---------------------------------------------------------------------------
// Check Type Implementations
// ---------------------------------------------------------------------------

/**
 * file_exists: Check if file exists at the specified path.
 *
 * @param {object} step - { type, target, description }
 * @param {object} _task - Active task object (unused)
 * @param {object} _config - Sidecar config (unused)
 * @returns {{ status: string, output: string }}
 */
function checkFileExists(step, _task, _config) {
  const targetPath = step.target;
  if (fs.existsSync(targetPath)) {
    return { status: 'pass', output: '' };
  }
  return { status: 'fail', output: 'File not found: ' + targetPath };
}

/**
 * test_passes: Run test command. Auto-detect if target is "auto".
 *
 * @param {object} step - { type, target, description }
 * @param {object} task - Active task object (has repo field for auto-detection)
 * @param {object} config - Sidecar config (has repo_dir)
 * @returns {{ status: string, output: string }}
 */
function checkTestPasses(step, task, config) {
  const repoDir = config.repo_dir || task.repo || '.';
  const command = resolveTestCommand(step.target, repoDir);
  return runShellCommand(command, repoDir);
}

/**
 * git_clean: Strict check -- no uncommitted changes AND no untracked files.
 * Uses git status --porcelain (respects .gitignore).
 *
 * @param {object} step - { type, target, description }
 * @param {object} _task - Active task object (unused)
 * @param {object} config - Sidecar config (has repo_dir as fallback)
 * @returns {{ status: string, output: string }}
 */
function checkGitClean(step, _task, config) {
  const dir = step.target || config.repo_dir || '.';
  const result = runShellCommand('git status --porcelain', dir);

  if (result.status === 'pass' && result.output.trim() === '') {
    return { status: 'pass', output: '' };
  }
  // Either git failed (non-zero exit) or there are dirty files
  if (result.status === 'fail') {
    return { status: 'fail', output: result.output };
  }
  // exit 0 but non-empty output = dirty files
  return { status: 'fail', output: result.output };
}

/**
 * command_succeeds: Run arbitrary command, check exit code 0.
 * This is the escape hatch for custom checks -- intentionally allows
 * arbitrary shell commands (same trust level as task execution).
 *
 * @param {object} step - { type, target, description }
 * @param {object} _task - Active task object (unused)
 * @param {object} config - Sidecar config (has repo_dir for cwd)
 * @returns {{ status: string, output: string }}
 */
function checkCommandSucceeds(step, _task, config) {
  const cwd = config.repo_dir || '.';
  return runShellCommand(step.target, cwd);
}

// Check type dispatch map
const CHECK_HANDLERS = {
  file_exists: checkFileExists,
  test_passes: checkTestPasses,
  git_clean: checkGitClean,
  command_succeeds: checkCommandSucceeds
};

/**
 * Execute a single verification check with timing.
 *
 * @param {object} step - { type, target, description }
 * @param {object} task - Active task object
 * @param {object} config - Sidecar config
 * @returns {{ type: string, target: string, description: string|null, status: string, output: string, duration_ms: number }}
 */
function executeCheck(step, task, config) {
  const startMs = Date.now();
  let result;

  const handler = CHECK_HANDLERS[step.type];
  if (handler) {
    try {
      result = handler(step, task, config);
    } catch (err) {
      result = { status: 'error', output: 'Check execution error: ' + err.message };
    }
  } else {
    result = { status: 'error', output: 'Unknown check type: ' + step.type };
  }

  const endMs = Date.now();
  return {
    type: step.type,
    target: step.target,
    description: step.description || null,
    status: result.status,
    output: result.output,
    duration_ms: endMs - startMs
  };
}

/**
 * Derive overall report status from individual check results.
 * Priority: error > fail > pass (run-all strategy, no fail-fast).
 *
 * @param {Array} checks - Array of check result objects
 * @returns {string} - 'pass' | 'fail' | 'error'
 */
function deriveStatus(checks) {
  let hasError = false;
  let hasFail = false;

  for (const check of checks) {
    if (check.status === 'error') hasError = true;
    if (check.status === 'fail') hasFail = true;
  }

  if (hasError) return 'error';
  if (hasFail) return 'fail';
  return 'pass';
}

/**
 * Build summary counts from check results.
 *
 * @param {Array} checks - Array of check result objects
 * @returns {{ total: number, passed: number, failed: number, errors: number, timed_out: number }}
 */
function buildSummary(checks) {
  const summary = { total: checks.length, passed: 0, failed: 0, errors: 0, timed_out: 0 };
  for (const check of checks) {
    switch (check.status) {
      case 'pass': summary.passed++; break;
      case 'fail': summary.failed++; break;
      case 'error': summary.errors++; break;
      case 'timeout': summary.timed_out++; break;
    }
  }
  return summary;
}

/**
 * Run all verification checks for a completed task with a global timeout.
 *
 * Returns a structured verification report matching the hub-side format.
 * Handles skip_verification, empty verification_steps, and global timeout.
 *
 * @param {object} task - Active task object from _queue.active
 *   Expected fields: task_id, verification_steps, skip_verification, verification_timeout_ms
 * @param {object} config - Sidecar config object (has repo_dir)
 * @returns {Promise<object>} Verification report
 */
async function runVerification(task, config) {
  const taskId = task.task_id;
  const logFn = config._log || (() => {});

  // Skip verification if flagged
  if (task.skip_verification === true) {
    logFn('info', 'verification_skipped', { task_id: taskId });
    return {
      task_id: taskId,
      run_number: 1,
      status: 'skip',
      started_at: Date.now(),
      duration_ms: 0,
      timeout_ms: task.verification_timeout_ms || DEFAULT_TIMEOUT_MS,
      checks: [],
      summary: { total: 0, passed: 0, failed: 0, errors: 0, timed_out: 0 }
    };
  }

  // Auto-pass if no verification steps defined
  const steps = task.verification_steps;
  if (!steps || steps.length === 0) {
    logFn('info', 'verification_auto_pass', { task_id: taskId });
    return {
      task_id: taskId,
      run_number: 1,
      status: 'auto_pass',
      started_at: Date.now(),
      duration_ms: 0,
      timeout_ms: task.verification_timeout_ms || DEFAULT_TIMEOUT_MS,
      checks: [],
      summary: { total: 0, passed: 0, failed: 0, errors: 0, timed_out: 0 }
    };
  }

  // Run all checks with global timeout
  const timeoutMs = task.verification_timeout_ms || DEFAULT_TIMEOUT_MS;
  const startedAt = Date.now();

  logFn('info', 'verification_started', { task_id: taskId, checks: steps.length, timeout_ms: timeoutMs });

  return new Promise((resolve) => {
    let resolved = false;

    // Timeout promise
    const timer = setTimeout(() => {
      if (resolved) return;
      resolved = true;

      logFn('warning', 'verification_timeout', { task_id: taskId, timeout_ms: timeoutMs });

      resolve({
        task_id: taskId,
        run_number: 1,
        status: 'timeout',
        started_at: startedAt,
        duration_ms: Date.now() - startedAt,
        timeout_ms: timeoutMs,
        checks: [],
        summary: { total: steps.length, passed: 0, failed: 0, errors: 0, timed_out: steps.length }
      });
    }, timeoutMs);

    // Run all checks sequentially (execSync is blocking, so this runs in order)
    try {
      const checks = [];
      for (const step of steps) {
        if (resolved) break; // Stop if timeout already fired
        logFn('debug', 'verification_check_start', { task_id: taskId, type: step.type, target: step.target });
        const checkResult = executeCheck(step, task, config);
        checks.push(checkResult);
        logFn('debug', 'verification_check_complete', {
          task_id: taskId,
          type: step.type,
          status: checkResult.status,
          duration_ms: checkResult.duration_ms
        });
      }

      if (resolved) return; // Timeout already fired
      resolved = true;
      clearTimeout(timer);

      const totalDuration = Date.now() - startedAt;
      const status = deriveStatus(checks);
      const summary = buildSummary(checks);

      logFn('info', 'verification_complete', {
        task_id: taskId,
        status,
        passed: summary.passed,
        failed: summary.failed,
        duration_ms: totalDuration
      });

      resolve({
        task_id: taskId,
        run_number: 1,
        status,
        started_at: startedAt,
        duration_ms: totalDuration,
        timeout_ms: timeoutMs,
        checks,
        summary
      });
    } catch (err) {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);

      logFn('error', 'verification_error', { task_id: taskId, error: err.message });

      resolve({
        task_id: taskId,
        run_number: 1,
        status: 'error',
        started_at: startedAt,
        duration_ms: Date.now() - startedAt,
        timeout_ms: timeoutMs,
        checks: [],
        summary: { total: steps.length, passed: 0, failed: 0, errors: steps.length, timed_out: 0 }
      });
    }
  });
}

module.exports = { runVerification };
