'use strict';

const { exec } = require('child_process');

/**
 * Retry delays for wake command attempts: 5s, 15s, 30s.
 * Per CONTEXT.md specification.
 */
const RETRY_DELAYS = [5000, 15000, 30000];

/**
 * Interpolate template variables in a wake command string.
 * Supported: ${TASK_ID}, ${TASK_JSON}, ${TASK_DESCRIPTION}
 *
 * @param {string} command - Wake command template
 * @param {object} task - Task object with task_id, description, etc.
 * @returns {string} Interpolated command string
 */
function interpolateWakeCommand(command, task) {
  return command
    .replace(/\$\{TASK_ID\}/g, task.task_id || '')
    .replace(/\$\{TASK_JSON\}/g, JSON.stringify(task).replace(/"/g, '\\"'))
    .replace(/\$\{TASK_DESCRIPTION\}/g, (task.description || '').replace(/"/g, '\\"'));
}

/**
 * Execute a shell command and return a promise.
 *
 * @param {string} command - Shell command to execute
 * @returns {Promise<{code: number, stdout: string, stderr: string}>}
 */
function execCommand(command) {
  return new Promise((resolve, reject) => {
    exec(command, {
      timeout: 60000,
      shell: true,
      windowsHide: true
    }, (error, stdout, stderr) => {
      if (error) {
        reject({ code: error.code, signal: error.signal, stderr, message: error.message });
      } else {
        resolve({ code: 0, stdout, stderr });
      }
    });
  });
}

module.exports = { interpolateWakeCommand, execCommand, RETRY_DELAYS };
