'use strict';

const path = require('path');
const { spawnSync } = require('child_process');

/**
 * Invoke agentcom-git.js as a child process with a custom path to the CLI script.
 * Returns parsed JSON output. On error, returns { status: 'error', error: message }.
 *
 * @param {string} gitCliPath - Absolute path to agentcom-git.js
 * @param {string} command - Git workflow command (e.g. 'start-task', 'submit', 'status')
 * @param {object} args - Arguments to pass as JSON to agentcom-git.js
 * @returns {{ status: string, [key: string]: any }}
 */
function runGitCommandWithPath(gitCliPath, command, args) {
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

/**
 * Invoke agentcom-git.js using the default path (relative to this module's directory).
 * Convenience wrapper around runGitCommandWithPath.
 *
 * @param {string} command - Git workflow command
 * @param {object} args - Arguments object
 * @returns {{ status: string, [key: string]: any }}
 */
function runGitCommand(command, args) {
  const gitCliPath = path.join(__dirname, '..', 'agentcom-git.js');
  return runGitCommandWithPath(gitCliPath, command, args);
}

module.exports = { runGitCommand, runGitCommandWithPath };
