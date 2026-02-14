'use strict';

const { spawn } = require('child_process');
const { log } = require('../log');

/**
 * ShellExecutor -- runs shell commands via child_process.spawn with
 * streaming stdout/stderr, configurable per-task timeout, and retry
 * once on failure (per locked decision).
 *
 * Uses spawn (NOT exec) for streaming output (per research: exec buffers,
 * spawn streams).  On timeout: SIGTERM then SIGKILL after 5s grace
 * period (per research pitfall #4: zombie processes).
 */
class ShellExecutor {
  /**
   * Execute a shell command task.
   *
   * @param {object}   task       - Task object with metadata.shell_command or description
   * @param {object}   config     - Sidecar config
   * @param {function} onProgress - Callback for streaming events
   * @returns {Promise<{status, output, model_used, tokens_in, tokens_out, error}>}
   */
  async execute(task, config, onProgress) {
    const command = this._extractCommand(task);
    if (!command) {
      return {
        status: 'failed',
        output: '',
        model_used: 'none',
        tokens_in: 0,
        tokens_out: 0,
        error: 'No shell command found in task metadata or description'
      };
    }

    const maxRetries = 1; // Retry once (locked decision)
    let lastError = null;

    for (let attempt = 1; attempt <= maxRetries + 1; attempt++) {
      try {
        if (attempt > 1) {
          onProgress({
            type: 'status',
            message: `Shell retry ${attempt - 1}/${maxRetries}...`
          });
          log('info', 'shell_retry', {
            task_id: task.task_id,
            attempt: attempt - 1,
            max_retries: maxRetries
          });
        }

        const result = await this._runCommand(command, task, config, onProgress);

        return {
          status: 'success',
          output: result.stdout,
          model_used: 'none',
          tokens_in: 0,
          tokens_out: 0,
          error: null
        };
      } catch (err) {
        lastError = err;
        log('warning', 'shell_attempt_failed', {
          task_id: task.task_id,
          attempt,
          error: err.message
        });

        if (attempt > maxRetries) {
          onProgress({
            type: 'error',
            message: `Shell failed after ${maxRetries + 1} attempts: ${err.message}`
          });
          return {
            status: 'failed',
            output: '',
            model_used: 'none',
            tokens_in: 0,
            tokens_out: 0,
            error: err.message
          };
        }
      }
    }

    // Defensive fallback
    return {
      status: 'failed',
      output: '',
      model_used: 'none',
      tokens_in: 0,
      tokens_out: 0,
      error: lastError ? lastError.message : 'Unknown error'
    };
  }

  /**
   * Extract the shell command from task metadata or description.
   */
  _extractCommand(task) {
    if (task.metadata && task.metadata.shell_command) {
      return task.metadata.shell_command;
    }
    // Do NOT fall back to task.description — natural language descriptions
    // are not shell commands. Only execute explicit shell_command metadata.
    return null;
  }

  /**
   * Run a command via child_process.spawn with streaming stdout/stderr
   * and configurable timeout.
   *
   * @returns {Promise<{stdout: string, stderr: string, code: number}>}
   */
  _runCommand(command, task, config, onProgress) {
    return new Promise((resolve, reject) => {
      const timeoutMs = (task.metadata && task.metadata.timeout_ms) || 60000; // Default 60s
      let timedOut = false;

      const proc = spawn(command, [], {
        shell: true,
        windowsHide: true,
        cwd: config.repo_dir || process.cwd(),
        env: { ...process.env }
      });

      let stdout = '';
      let stderr = '';

      // Configurable timeout with SIGTERM -> SIGKILL escalation
      const timer = setTimeout(() => {
        timedOut = true;
        onProgress({
          type: 'status',
          message: `Command timed out after ${timeoutMs}ms, sending SIGTERM...`
        });
        proc.kill('SIGTERM');
        // Grace period: SIGKILL after 5s if still running
        setTimeout(() => {
          try { proc.kill('SIGKILL'); } catch (e) { /* ignore -- already dead */ }
        }, 5000);
      }, timeoutMs);

      proc.stdout.on('data', (data) => {
        const text = data.toString();
        stdout += text;
        onProgress({ type: 'stdout', text });
      });

      proc.stderr.on('data', (data) => {
        const text = data.toString();
        stderr += text;
        onProgress({ type: 'stderr', text });
      });

      proc.on('close', (code, signal) => {
        clearTimeout(timer);
        if (timedOut) {
          reject(new Error(`Command timed out after ${timeoutMs}ms`));
        } else if (code !== 0) {
          reject(new Error(`Command exited with code ${code}${stderr ? ': ' + stderr.slice(0, 500) : ''}`));
        } else {
          resolve({ stdout, stderr, code });
        }
      });

      proc.on('error', (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });
  }
}

module.exports = { ShellExecutor };
