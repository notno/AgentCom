'use strict';

const fs = require('fs');
const os = require('os');

const LEVELS = { debug: 10, info: 20, notice: 30, warning: 40, error: 50 };
const LEVEL_NAMES = Object.fromEntries(
  Object.entries(LEVELS).map(([k, v]) => [v, k])
);

let _config = null;
let _logLevel = LEVELS.info;
let _logStream = null;
const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB
const MAX_FILES = 5;

function initLogger(config) {
  _config = config;
  if (config.log_level && LEVELS[config.log_level] !== undefined) {
    _logLevel = LEVELS[config.log_level];
  }
  if (config.log_file) {
    _rotateIfNeeded(config.log_file);
    _logStream = fs.createWriteStream(config.log_file, { flags: 'a' });
  }
}

/**
 * Extract caller function name and line number from Error().stack.
 * Returns { function: string, line: number } or { function: null, line: null }
 * if parsing fails. The stack frame at index 2 is the caller of log().
 */
function _getCallerInfo() {
  const err = new Error();
  const stack = err.stack;
  if (!stack) return { function: null, line: null };

  // Stack format: "    at functionName (file:line:col)" or "    at file:line:col"
  const lines = stack.split('\n');
  // lines[0] = "Error", lines[1] = this function, lines[2] = log(), lines[3] = caller
  const callerLine = lines[3] || '';
  const match = callerLine.match(/at\s+(?:(.+?)\s+\()?.*?:(\d+):\d+\)?/);
  if (match) {
    return {
      function: match[1] || null,
      line: parseInt(match[2], 10) || null
    };
  }
  return { function: null, line: null };
}

function log(level, event, data = {}, moduleName = 'sidecar/index') {
  const numLevel = typeof level === 'number' ? level : (LEVELS[level] || LEVELS.info);
  if (numLevel < _logLevel) return;

  // Capture caller info for function/line metadata (per locked decision)
  const caller = _getCallerInfo();

  const entry = {
    time: new Date().toISOString(),
    severity: LEVEL_NAMES[numLevel] || 'info',
    message: event,
    module: moduleName,
    pid: process.pid,
    node: os.hostname(),
    agent_id: _config ? _config.agent_id : 'unknown',
    function: caller.function,
    line: caller.line,
    ...data
  };

  // Redact sensitive fields (matching Elixir hub redaction keys)
  if (entry.token) entry.token = '[REDACTED]';
  if (entry.auth_token) entry.auth_token = '[REDACTED]';
  if (entry.secret) entry.secret = '[REDACTED]';

  const line = JSON.stringify(entry) + '\n';
  process.stdout.write(line);

  if (_logStream && _config && _config.log_file) {
    _logStream.write(line);
  }
}

function _rotateIfNeeded(filePath) {
  try {
    const stats = fs.statSync(filePath);
    if (stats.size >= MAX_FILE_SIZE) {
      for (let i = MAX_FILES - 1; i >= 1; i--) {
        const from = i === 1 ? filePath : `${filePath}.${i - 1}`;
        const to = `${filePath}.${i}`;
        try { fs.renameSync(from, to); } catch (_) {}
      }
      fs.renameSync(filePath, `${filePath}.1`);
    }
  } catch (_) {
    // File doesn't exist yet, no rotation needed
  }
}

module.exports = { initLogger, log, LEVELS };
