'use strict';

const fs = require('fs');
const path = require('path');
const { spawn, execSync } = require('child_process');
const readline = require('readline');
const { validatePath, isCommandBlocked, SandboxError } = require('./sandbox');
const { getToolByName } = require('./tool-registry');
const { log } = require('../log');

/**
 * Maximum file size for read_file (1MB).
 */
const MAX_FILE_SIZE = 1 * 1024 * 1024;

/**
 * Maximum entries returned by list_directory.
 */
const MAX_DIR_ENTRIES = 500;

/**
 * Maximum recursion depth for list_directory.
 */
const MAX_RECURSION_DEPTH = 5;

/**
 * Directories to skip during search_files.
 */
const SKIP_DIRS = new Set(['.git', 'node_modules', '_build', 'deps', 'dist', 'build', '.elixir_ls']);

// ---------------------------------------------------------------------------
// Handler implementations
// ---------------------------------------------------------------------------

/**
 * Read file contents with optional line range.
 */
async function handleReadFile(args, workspaceRoot) {
  const resolved = validatePath(args.path, workspaceRoot);

  // Check file exists
  if (!fs.existsSync(resolved)) {
    throw Object.assign(new Error(`File not found: ${args.path}`), { code: 'FILE_NOT_FOUND' });
  }

  // Check file size
  const stats = fs.statSync(resolved);
  if (stats.size > MAX_FILE_SIZE) {
    throw new SandboxError('FILE_TOO_LARGE',
      `File is ${stats.size} bytes (max ${MAX_FILE_SIZE}). Use start_line/end_line to read a range.`);
  }

  // Check for binary content (null bytes in first 8KB)
  const fd = fs.openSync(resolved, 'r');
  const probe = Buffer.alloc(Math.min(8192, stats.size));
  fs.readSync(fd, probe, 0, probe.length, 0);
  fs.closeSync(fd);
  if (probe.includes(0)) {
    throw Object.assign(
      new Error(`Binary file detected (${stats.size} bytes): ${args.path}`),
      { code: 'BINARY_FILE' }
    );
  }

  // Read file
  const content = fs.readFileSync(resolved, 'utf-8');
  let lines = content.split('\n');
  let truncated = false;

  // Apply line range (1-based inclusive)
  if (args.start_line || args.end_line) {
    const start = (args.start_line || 1) - 1;  // Convert to 0-based
    const end = args.end_line || lines.length;
    lines = lines.slice(start, end);
    truncated = (args.end_line && args.end_line < content.split('\n').length) ||
                (args.start_line && args.start_line > 1);
  }

  return {
    content: lines.join('\n'),
    lines: lines.length,
    path: args.path,
    truncated
  };
}

/**
 * Write content to a file, creating parent directories if needed.
 */
async function handleWriteFile(args, workspaceRoot) {
  const resolved = validatePath(args.path, workspaceRoot);
  const created = !fs.existsSync(resolved);

  // Create parent directories unless explicitly disabled
  if (args.create_dirs !== false) {
    const dir = path.dirname(resolved);
    fs.mkdirSync(dir, { recursive: true });
  }

  fs.writeFileSync(resolved, args.content, 'utf-8');
  const bytesWritten = Buffer.byteLength(args.content, 'utf-8');

  return {
    path: args.path,
    bytes_written: bytesWritten,
    created
  };
}

/**
 * List files and directories with optional recursion and pattern filtering.
 */
async function handleListDirectory(args, workspaceRoot) {
  const resolved = validatePath(args.path, workspaceRoot);

  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isDirectory()) {
    throw Object.assign(new Error(`Not a directory: ${args.path}`), { code: 'NOT_A_DIRECTORY' });
  }

  const entries = [];
  const pattern = args.pattern || null;

  function walkDir(dir, depth) {
    if (entries.length >= MAX_DIR_ENTRIES) return;
    if (depth > MAX_RECURSION_DEPTH) return;

    let dirents;
    try {
      dirents = fs.readdirSync(dir, { withFileTypes: true });
    } catch (e) {
      return; // Permission denied or other error, skip
    }

    for (const dirent of dirents) {
      if (entries.length >= MAX_DIR_ENTRIES) break;

      const fullPath = path.join(dir, dirent.name);
      const relativePath = path.relative(resolved, fullPath);
      const type = dirent.isDirectory() ? 'directory' : 'file';

      // Apply pattern filter
      if (pattern && !matchPattern(dirent.name, pattern)) {
        // If directory and recursive, still recurse into it
        if (args.recursive && dirent.isDirectory()) {
          walkDir(fullPath, depth + 1);
        }
        continue;
      }

      let size = null;
      if (dirent.isFile()) {
        try {
          size = fs.statSync(fullPath).size;
        } catch (e) {
          size = null;
        }
      }

      entries.push({
        name: args.recursive ? relativePath : dirent.name,
        type,
        size
      });

      if (args.recursive && dirent.isDirectory()) {
        walkDir(fullPath, depth + 1);
      }
    }
  }

  walkDir(resolved, 0);

  return {
    entries,
    total: entries.length,
    path: args.path
  };
}

/**
 * Simple glob pattern matching (supports *.ext, prefix*, *infix*).
 */
function matchPattern(name, pattern) {
  // Convert simple glob to regex
  const escaped = pattern
    .replace(/[.+^${}()|[\]\\]/g, '\\$&')  // Escape regex special chars except *
    .replace(/\*/g, '.*');                    // Convert * to .*
  try {
    return new RegExp(`^${escaped}$`).test(name);
  } catch (e) {
    return name.includes(pattern);
  }
}

/**
 * Execute a shell command with timeout enforcement.
 */
async function handleRunCommand(args, workspaceRoot) {
  // Check command is not blocked
  if (isCommandBlocked(args.command)) {
    throw new SandboxError('COMMAND_BLOCKED',
      `Command blocked by security policy: ${args.command}`);
  }

  const timeoutMs = args.timeout_ms || 30000;

  return new Promise((resolve, reject) => {
    let timedOut = false;
    let stdout = '';
    let stderr = '';

    const proc = spawn(args.command, [], {
      shell: true,
      windowsHide: true,
      cwd: workspaceRoot,
      env: { ...process.env }
    });

    // Timeout with SIGTERM/SIGKILL escalation (from ShellExecutor pattern)
    // On Windows, proc.kill() with shell:true doesn't kill child processes,
    // so use taskkill /T /F to kill the entire process tree.
    const timer = setTimeout(() => {
      timedOut = true;
      if (process.platform === 'win32') {
        try {
          execSync(`taskkill /PID ${proc.pid} /T /F`, { windowsHide: true, stdio: 'ignore' });
        } catch (e) { /* already dead */ }
      } else {
        proc.kill('SIGTERM');
        setTimeout(() => {
          try { proc.kill('SIGKILL'); } catch (e) { /* already dead */ }
        }, 5000);
      }
    }, timeoutMs);

    proc.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    proc.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    proc.on('close', (code) => {
      clearTimeout(timer);
      resolve({
        stdout: stdout.trimEnd(),
        stderr: stderr.trimEnd(),
        exit_code: timedOut ? null : (code || 0),
        timed_out: timedOut
      });
    });

    proc.on('error', (err) => {
      clearTimeout(timer);
      reject(Object.assign(new Error(`Command spawn failed: ${err.message}`), { code: 'EXECUTION_ERROR' }));
    });
  });
}

/**
 * Search files recursively for a regex pattern.
 */
async function handleSearchFiles(args, workspaceRoot) {
  const searchPath = args.path || '.';
  const resolved = validatePath(searchPath, workspaceRoot);
  const maxResults = args.max_results || 50;

  // Validate regex
  let regex;
  try {
    regex = new RegExp(args.pattern);
  } catch (e) {
    throw Object.assign(new Error(`Invalid regex pattern: ${e.message}`), { code: 'INVALID_REGEX' });
  }

  const matches = [];
  let filesSearched = 0;

  // Collect files to search
  const files = [];
  function collectFiles(dir) {
    let dirents;
    try {
      dirents = fs.readdirSync(dir, { withFileTypes: true });
    } catch (e) {
      return;
    }

    for (const dirent of dirents) {
      if (SKIP_DIRS.has(dirent.name)) continue;

      const fullPath = path.join(dir, dirent.name);
      if (dirent.isDirectory()) {
        collectFiles(fullPath);
      } else if (dirent.isFile()) {
        // Apply file_pattern filter
        if (args.file_pattern && !matchPattern(dirent.name, args.file_pattern)) {
          continue;
        }
        files.push(fullPath);
      }
    }
  }

  collectFiles(resolved);

  // Search each file line-by-line
  for (const filePath of files) {
    if (matches.length >= maxResults) break;

    filesSearched++;
    const relativePath = path.relative(workspaceRoot, filePath);

    // Check file size -- skip large files
    let stats;
    try {
      stats = fs.statSync(filePath);
    } catch (e) {
      continue;
    }
    if (stats.size > MAX_FILE_SIZE) continue;

    // Check for binary file -- skip
    const fd = fs.openSync(filePath, 'r');
    const probe = Buffer.alloc(Math.min(512, stats.size));
    fs.readSync(fd, probe, 0, probe.length, 0);
    fs.closeSync(fd);
    if (probe.includes(0)) continue;

    // Read and search line by line
    const content = fs.readFileSync(filePath, 'utf-8');
    const lines = content.split('\n');
    for (let i = 0; i < lines.length; i++) {
      if (matches.length >= maxResults) break;

      if (regex.test(lines[i])) {
        matches.push({
          file: relativePath.replace(/\\/g, '/'),  // Normalize Windows paths
          line: i + 1,
          content: lines[i].length > 500 ? lines[i].substring(0, 500) + '...' : lines[i]
        });
      }
    }
  }

  return {
    matches,
    total_matches: matches.length,
    files_searched: filesSearched,
    truncated: matches.length >= maxResults
  };
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

const TOOL_HANDLERS = {
  read_file: handleReadFile,
  write_file: handleWriteFile,
  list_directory: handleListDirectory,
  run_command: handleRunCommand,
  search_files: handleSearchFiles,
};

/**
 * Execute a tool by name with the given arguments.
 *
 * Every tool returns a structured JSON envelope:
 *   { success: boolean, tool: string, output: object|null, error: { code, message }|null }
 *
 * @param {string} toolName - Name of the tool to execute
 * @param {object} args - Tool arguments
 * @param {string} workspaceRoot - Absolute path to the workspace root
 * @returns {Promise<object>} Structured JSON observation
 */
async function executeTool(toolName, args, workspaceRoot) {
  const startTime = Date.now();
  const handler = TOOL_HANDLERS[toolName];

  if (!handler) {
    return {
      success: false,
      tool: toolName,
      output: null,
      error: { code: 'UNKNOWN_TOOL', message: `No handler for tool: ${toolName}` }
    };
  }

  try {
    const result = await handler(args, workspaceRoot);
    const durationMs = Date.now() - startTime;

    log('info', 'tool_executed', {
      tool: toolName,
      success: true,
      duration_ms: durationMs
    }, 'sidecar/tools/tool-executor');

    return { success: true, tool: toolName, output: result, error: null };
  } catch (err) {
    const durationMs = Date.now() - startTime;
    const code = err.code || 'EXECUTION_ERROR';

    log('info', 'tool_executed', {
      tool: toolName,
      success: false,
      duration_ms: durationMs,
      error_code: code
    }, 'sidecar/tools/tool-executor');

    return {
      success: false,
      tool: toolName,
      output: null,
      error: { code, message: err.message }
    };
  }
}

module.exports = { executeTool };
