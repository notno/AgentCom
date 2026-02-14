# Phase 40: Sidecar Tool Infrastructure - Research

**Researched:** 2026-02-14
**Domain:** Node.js sandboxed tool execution for LLM function calling
**Confidence:** HIGH

## Summary

Phase 40 builds the tool layer that sits between Ollama's function-calling output (Phase 41) and the filesystem/shell. The sidecar already has execution infrastructure (`sidecar/lib/execution/`) with patterns for timeouts, streaming, and error handling. This phase adds a `sidecar/lib/tools/` directory with three modules: tool-registry (definitions), sandbox (security), and tool-executor (dispatch + structured responses).

The key technical challenge is path traversal prevention in the sandbox. Node.js `path.resolve()` canonicalizes paths but does NOT resolve symlinks -- `fs.realpathSync()` is needed for symlink-aware validation. The workspace root is already available from `WorkspaceManager.ensureWorkspace()` which returns an absolute resolved path.

All 5 tools use only Node.js built-in modules (`fs`, `path`, `child_process`, `readline`). Zero new dependencies required.

**Primary recommendation:** Build three focused modules (registry, sandbox, executor) using existing sidecar patterns. Lean on `child_process.spawn` with SIGTERM/SIGKILL timeout escalation from ShellExecutor. Return typed JSON observations with consistent schema across all tools.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- 5 tools exactly: read_file, write_file, list_directory, run_command, search_files
- Qwen3 8B native JSON limit is 5 tools -- above 5 falls back to XML in content field
- Structured JSON observations -- tools return typed fields, not raw text
- Workspace sandbox is non-negotiable -- every file operation validates path is within workspace
- Pure Node.js for search_files -- zero external deps

### Claude's Discretion
- Internal module structure within sidecar/lib/tools/
- JSON observation schema field names and types
- Blocked command list contents
- Default timeout values per tool

### Deferred Ideas (OUT OF SCOPE)
- Network access tools (curl, wget) -- agent communicates through hub
- Tool call caching/memoization -- stale data bugs after file writes
- LLM-generated tool definitions -- security risk, fixed registry in code
- Custom tool protocols (MCP/A2A) -- protocol overhead for zero benefit
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Node.js built-in `fs` | N/A | File read/write/list operations | Already used throughout sidecar |
| Node.js built-in `path` | N/A | Path resolution and validation | Used by workspace-manager.js |
| Node.js built-in `child_process` | N/A | Command execution with timeout | Pattern established in shell-executor.js |
| Node.js built-in `readline` | N/A | Line-by-line file search (search_files) | Avoids loading entire files into memory |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `fs.realpathSync` | N/A | Resolve symlinks for sandbox validation | After path.resolve(), before allowing access |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Built-in readline for search | ripgrep child_process | External dependency; overkill for bounded workspace searches |
| Manual glob for list_directory | npm `glob` package | Extra dependency; `fs.readdirSync` + filter pattern is sufficient |

**Installation:**
```bash
# No new dependencies required
```

## Architecture Patterns

### Recommended Project Structure
```
sidecar/lib/tools/
├── tool-registry.js    # Tool definitions in Ollama format
├── sandbox.js          # Path validation, command blocking
└── tool-executor.js    # Dispatch tool calls, return observations
sidecar/test/tools/
├── tool-registry.test.js
├── sandbox.test.js
└── tool-executor.test.js
```

### Pattern 1: Ollama Function-Calling Tool Format
**What:** Ollama's /api/chat accepts a `tools` array with JSON Schema-based function definitions.
**When to use:** Every tool definition in tool-registry.js.
**Example:**
```javascript
// Source: Ollama /api/chat documentation
{
  type: 'function',
  function: {
    name: 'read_file',
    description: 'Read the contents of a file at the given path',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'File path relative to workspace root'
        },
        start_line: {
          type: 'integer',
          description: 'Starting line number (1-based, optional)'
        },
        end_line: {
          type: 'integer',
          description: 'Ending line number (inclusive, optional)'
        }
      },
      required: ['path']
    }
  }
}
```

### Pattern 2: Structured JSON Observation
**What:** Every tool returns a consistent JSON envelope with typed fields.
**When to use:** All tool execution results.
**Example:**
```javascript
// Success
{
  success: true,
  tool: 'read_file',
  output: {
    content: '...file contents...',
    lines: 42,
    path: 'src/index.js'
  },
  error: null
}

// Failure
{
  success: false,
  tool: 'read_file',
  output: null,
  error: {
    code: 'PATH_OUTSIDE_WORKSPACE',
    message: 'Path traversal blocked: ../../etc/passwd resolves outside workspace'
  }
}
```

### Pattern 3: Sandbox Path Validation (Resolve + Realpath)
**What:** Two-phase validation: resolve the path, then check it starts with workspace root.
**When to use:** Before every file operation (read_file, write_file, list_directory, search_files).
**Example:**
```javascript
function validatePath(requestedPath, workspaceRoot) {
  // Phase 1: Resolve relative path against workspace root
  const resolved = path.resolve(workspaceRoot, requestedPath);

  // Phase 2: Check the resolved path starts with workspace root
  // Use path.sep to handle both forward and back slashes on Windows
  const normalizedRoot = workspaceRoot.endsWith(path.sep)
    ? workspaceRoot
    : workspaceRoot + path.sep;

  if (resolved !== workspaceRoot && !resolved.startsWith(normalizedRoot)) {
    throw new SandboxError('PATH_OUTSIDE_WORKSPACE',
      `Path ${requestedPath} resolves outside workspace`);
  }

  // Phase 3: If file exists, also check realpath (symlink resolution)
  if (fs.existsSync(resolved)) {
    const real = fs.realpathSync(resolved);
    const realRoot = fs.realpathSync(workspaceRoot);
    const normalizedRealRoot = realRoot.endsWith(path.sep)
      ? realRoot
      : realRoot + path.sep;
    if (real !== realRoot && !real.startsWith(normalizedRealRoot)) {
      throw new SandboxError('SYMLINK_OUTSIDE_WORKSPACE',
        `Symlink ${requestedPath} resolves outside workspace`);
    }
  }

  return resolved;
}
```

### Pattern 4: Timeout with SIGTERM/SIGKILL Escalation
**What:** Kill long-running commands with graceful then forced signal.
**When to use:** run_command tool.
**Example:**
```javascript
// Reuse exact pattern from shell-executor.js
const timer = setTimeout(() => {
  timedOut = true;
  proc.kill('SIGTERM');
  setTimeout(() => {
    try { proc.kill('SIGKILL'); } catch (e) { /* already dead */ }
  }, 5000);
}, timeoutMs);
```

### Anti-Patterns to Avoid
- **Checking path string prefix without resolving:** `if (filepath.startsWith(root))` is trivially bypassed with `../` sequences. MUST resolve first.
- **Using exec() for run_command:** `exec()` buffers entire output in memory. Use `spawn()` for streaming.
- **Returning raw text from tools:** Smaller models struggle to parse unstructured output. Always wrap in typed JSON.
- **Allowing command chaining in run_command:** Don't allow `&&`, `||`, `;`, `|` by default -- the LLM should make separate tool calls.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Path traversal prevention | Custom string checks | `path.resolve()` + `fs.realpathSync()` + startsWith | Edge cases with `..`, `.`, symlinks, Windows paths |
| Command timeout | Custom timer | `spawn()` + SIGTERM/SIGKILL pattern from ShellExecutor | Zombie process prevention already solved |
| File search | Custom regex walker | `readline` interface on `fs.createReadStream` | Memory-efficient line-by-line matching |
| JSON Schema validation | Custom validation | Simple type checks (typeof/Array.isArray) | Full JSON Schema validation (ajv) is overkill for 5 tools |

**Key insight:** The sidecar already has proven patterns for timeouts, streaming, and error handling in `shell-executor.js`. Reuse these patterns rather than inventing new ones.

## Common Pitfalls

### Pitfall 1: Windows Path Separators
**What goes wrong:** Path validation using forward slashes fails on Windows where paths use backslashes.
**Why it happens:** `path.resolve()` on Windows produces `C:\Users\...` but comparison may use `/`.
**How to avoid:** Always use `path.resolve()` for both the workspace root and the target path. Use `startsWith()` on resolved paths -- `path.resolve()` normalizes separators.
**Warning signs:** Tests pass on Linux CI but fail on Windows dev machines (this project runs on Windows).

### Pitfall 2: Symlink Escape
**What goes wrong:** Attacker creates a symlink inside workspace pointing to `/etc/passwd`. `path.resolve()` says the path is within workspace, but the real file is outside.
**Why it happens:** `path.resolve()` resolves `..` but does NOT follow symlinks.
**How to avoid:** After `path.resolve()` check, also call `fs.realpathSync()` on existing files and validate the real path.
**Warning signs:** Security audit finds file reads outside workspace via symlink.

### Pitfall 3: Command Injection via Arguments
**What goes wrong:** run_command receives `ls; rm -rf /` and the shell interprets the semicolon.
**Why it happens:** Using `shell: true` in spawn() passes the command through the system shell.
**How to avoid:** Blocked command patterns should check for shell metacharacters (`;`, `&&`, `||`, `|`, backticks, `$()`) OR accept only the command + args array format. The CONTEXT.md specifies a blocked command list approach.
**Warning signs:** Test with `echo hello; echo pwned` produces two echoes.

### Pitfall 4: Large File Reads Blowing Memory
**What goes wrong:** read_file on a 500MB binary file allocates 500MB+ in Node.js.
**Why it happens:** `fs.readFileSync()` loads entire file into memory.
**How to avoid:** Check file size before reading. Cap at reasonable limit (e.g., 1MB). For large files, return error suggesting line range.
**Warning signs:** Node.js OOM crash during read_file on large binary.

### Pitfall 5: search_files Regex Denial of Service
**What goes wrong:** Malicious regex pattern like `(a+)+$` causes catastrophic backtracking.
**Why it happens:** Node.js regex engine is single-threaded, vulnerable to ReDoS.
**How to avoid:** Set a per-line timeout or use a simple timeout wrapper around the search. Limit result count (max 50 per CONTEXT.md). Consider rejecting obviously pathological patterns.
**Warning signs:** search_files call hangs indefinitely on certain patterns.

## Code Examples

### Tool Registry Export
```javascript
// tool-registry.js
'use strict';

const TOOLS = [
  {
    type: 'function',
    function: {
      name: 'read_file',
      description: 'Read file contents. Returns content with line numbers.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'File path relative to workspace' },
          start_line: { type: 'integer', description: 'Start line (1-based, optional)' },
          end_line: { type: 'integer', description: 'End line (inclusive, optional)' }
        },
        required: ['path']
      }
    }
  },
  // ... 4 more tools
];

function getToolDefinitions() {
  return TOOLS;
}

function getToolByName(name) {
  return TOOLS.find(t => t.function.name === name) || null;
}

module.exports = { getToolDefinitions, getToolByName, TOOLS };
```

### Sandbox Blocked Commands
```javascript
// sandbox.js
const BLOCKED_PATTERNS = [
  /^sudo\b/,
  /^rm\s+-rf\s+\//,
  /^shutdown\b/,
  /^reboot\b/,
  /^format\b/,
  /^mkfs\b/,
  /^dd\s+/,
  /^chmod\s+777/,
  /\brm\s+-rf\s+[~\/]/,
  /^curl\b/,
  /^wget\b/,
  /^nc\b/,
  /^netcat\b/,
];

function isCommandBlocked(command) {
  const trimmed = command.trim();
  return BLOCKED_PATTERNS.some(pattern => pattern.test(trimmed));
}
```

### Tool Executor Dispatch
```javascript
// tool-executor.js
async function executeTool(toolName, args, workspaceRoot) {
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
    return { success: true, tool: toolName, output: result, error: null };
  } catch (err) {
    return {
      success: false,
      tool: toolName,
      output: null,
      error: { code: err.code || 'EXECUTION_ERROR', message: err.message }
    };
  }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Raw text tool output | Structured JSON observations | 2024+ (tool-calling era) | Smaller models parse results reliably |
| Full JSON Schema validation (ajv) | Simple type checks for 5 tools | N/A | No external dependency needed for small fixed set |
| Complex tool routing | Direct name-to-handler map | N/A | 5 tools = simple switch/map |

**Deprecated/outdated:**
- XML-based tool calling: Ollama now supports native JSON tool calling for up to 5 tools with Qwen3 8B. XML fallback is Phase 41's concern (>5 tools).

## Open Questions

1. **Should run_command allow shell metacharacters at all?**
   - What we know: The LLM may need pipes for things like `npm test 2>&1`
   - What's unclear: Whether blocking all metacharacters is too restrictive
   - Recommendation: Allow pipes and redirects but block dangerous patterns (sudo, rm -rf /, etc.). The blocked command list approach from CONTEXT.md is more practical than whitelist.

2. **Should write_file create parent directories automatically?**
   - What we know: LLM may want to create files in new directories
   - What's unclear: Whether auto-mkdir is a security concern
   - Recommendation: Yes, use `fs.mkdirSync({ recursive: true })` -- the path validation already ensures we're within workspace. Failing on missing directory would frustrate the LLM.

3. **Binary file handling for read_file**
   - What we know: Workspace may contain images, compiled files, etc.
   - What's unclear: Whether to detect and reject or attempt to read
   - Recommendation: Check if file is likely binary (null bytes in first 8KB). If binary, return metadata (size, type) instead of content.

## Sources

### Primary (HIGH confidence)
- Existing codebase: `sidecar/lib/execution/shell-executor.js` -- timeout/SIGTERM/SIGKILL pattern
- Existing codebase: `sidecar/lib/workspace-manager.js` -- workspace path resolution
- Existing codebase: `sidecar/lib/execution/ollama-executor.js` -- Ollama /api/chat integration
- Existing codebase: `sidecar/lib/execution/dispatcher.js` -- execution dispatch pattern
- Node.js docs: `path.resolve()`, `fs.realpathSync()`, `child_process.spawn()`

### Secondary (MEDIUM confidence)
- Ollama API: `/api/chat` tools parameter format (JSON Schema based)
- CONTEXT.md: Phase 40 discussion decisions (locked by user)

### Tertiary (LOW confidence)
- None -- all findings verified against codebase or official docs

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- pure Node.js built-ins, zero new deps, patterns proven in existing codebase
- Architecture: HIGH -- follows established sidecar module patterns, clear separation of concerns
- Pitfalls: HIGH -- path traversal, command injection, and timeout handling are well-understood security domains

**Research date:** 2026-02-14
**Valid until:** 2026-03-14 (stable domain, no fast-moving dependencies)
