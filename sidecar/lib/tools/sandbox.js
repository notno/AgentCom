'use strict';

const fs = require('fs');
const path = require('path');

/**
 * SandboxError -- thrown when a tool operation violates workspace security.
 *
 * Codes:
 *   PATH_OUTSIDE_WORKSPACE  -- resolved path escapes the workspace root
 *   SYMLINK_OUTSIDE_WORKSPACE -- symlink target resolves outside workspace
 *   COMMAND_BLOCKED -- command matches a blocked pattern
 *   FILE_TOO_LARGE -- file exceeds size limit
 */
class SandboxError extends Error {
  /**
   * @param {string} code - Machine-readable error code
   * @param {string} message - Human-readable description
   */
  constructor(code, message) {
    super(message);
    this.name = 'SandboxError';
    this.code = code;
  }
}

/**
 * Validate that a requested path is within the workspace root.
 *
 * Two-phase validation:
 *   1. path.resolve() to canonicalize the requested path
 *   2. Check resolved path starts with workspace root
 *   3. If file exists, also check fs.realpathSync() for symlink escape
 *
 * @param {string} requestedPath - Path requested by the tool (relative or absolute)
 * @param {string} workspaceRoot - Absolute path to the workspace root
 * @returns {string} Resolved absolute path (safe to use)
 * @throws {SandboxError} If path escapes the workspace
 */
function validatePath(requestedPath, workspaceRoot) {
  // Phase 1: Resolve the path against workspace root
  const resolved = path.resolve(workspaceRoot, requestedPath);

  // Phase 2: Check resolved path starts with workspace root
  // Normalize root to ensure trailing separator for prefix check
  const normalizedRoot = workspaceRoot.endsWith(path.sep)
    ? workspaceRoot
    : workspaceRoot + path.sep;

  if (resolved !== workspaceRoot && !resolved.startsWith(normalizedRoot)) {
    throw new SandboxError(
      'PATH_OUTSIDE_WORKSPACE',
      `Path "${requestedPath}" resolves outside workspace`
    );
  }

  // Phase 3: If file exists, also check realpath (symlink resolution)
  if (fs.existsSync(resolved)) {
    const real = fs.realpathSync(resolved);
    const realRoot = fs.realpathSync(workspaceRoot);
    const normalizedRealRoot = realRoot.endsWith(path.sep)
      ? realRoot
      : realRoot + path.sep;

    if (real !== realRoot && !real.startsWith(normalizedRealRoot)) {
      throw new SandboxError(
        'SYMLINK_OUTSIDE_WORKSPACE',
        `Symlink "${requestedPath}" resolves outside workspace`
      );
    }
  }

  return resolved;
}

/**
 * Blocked command patterns -- regex array checked against the full command string.
 *
 * These patterns prevent dangerous operations. The agent communicates through
 * the hub, so network access tools (curl, wget, nc) are blocked.
 */
const BLOCKED_PATTERNS = [
  /^sudo\b/,                    // privilege escalation
  /\brm\s+-rf\s+[/~]/,          // destructive deletes outside workspace
  /^shutdown\b/,                 // system control
  /^reboot\b/,                   // system control
  /^format\b/,                   // disk formatting
  /^mkfs\b/,                     // disk formatting
  /^dd\s+/,                      // raw disk access
  /^curl\b/,                     // network access (agent uses hub)
  /^wget\b/,                     // network access
  /^nc\b/,                       // network access
  /^netcat\b/,                   // network access
  /^python.*-m\s+http/,          // HTTP server
  /^node.*--inspect/,            // debugger (security risk)
];

/**
 * Check if a command matches any blocked pattern.
 *
 * @param {string} command - Shell command to check
 * @returns {boolean} true if the command is blocked
 */
function isCommandBlocked(command) {
  const trimmed = command.trim();
  return BLOCKED_PATTERNS.some(pattern => pattern.test(trimmed));
}

module.exports = { validatePath, isCommandBlocked, SandboxError, BLOCKED_PATTERNS };
