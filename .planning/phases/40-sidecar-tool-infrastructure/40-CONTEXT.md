# Phase 40: Sidecar Tool Infrastructure — Discussion Context

## Approach

Build the tool definition registry and sandboxed executor that the agentic ReAct loop (Phase 41) will use. Pure infrastructure — no loop yet, just the tools themselves.

### Tool Registry
- New `sidecar/lib/tools/tool-registry.js`
- Exports 5 tool definitions in Ollama function-calling format
- Each tool: name, description, JSON schema for parameters
- Keep to exactly 5 tools (Qwen3 8B native JSON limit)

### Core Tools

| Tool | Purpose | Safety |
|------|---------|--------|
| `read_file` | Read file contents, optional line range | Read-only, workspace-only paths |
| `write_file` | Write/overwrite file contents | Workspace-only, no `..` traversal |
| `list_directory` | List files/dirs, optional recursion + pattern | Read-only, respects .gitignore |
| `run_command` | Execute shell command with timeout | Blocked command list, workspace CWD, timeout enforced |
| `search_files` | Regex search across files | Read-only, bounded results (max 50), pure Node.js |

### Tool Executor
- New `sidecar/lib/tools/tool-executor.js`
- Maps tool names to execution functions
- Validates args against schema before execution
- Enforces workspace sandbox: all paths resolved and checked against workspace root
- Per-tool timeout (30s default)
- Returns structured JSON: `{success: bool, output: string/object, error: string|null}`

### Sandbox Security
- Path validation: `path.resolve()` then check starts with workspace root
- Blocked commands: configurable list (`rm -rf /`, `sudo`, `format`, `shutdown`, etc.)
- No network access tools (no `curl`, `wget` — agent communicates through hub)
- Timeout on all tool executions

## Key Decisions

- **Pure Node.js for search_files** — zero external deps, fast enough for single-repo workspaces
- **5 tools exactly** — Qwen3 8B native JSON limit. Above 5, falls back to XML in content field.
- **Structured JSON observations** — tools return typed fields, not raw text. Helps smaller models parse results.
- **Workspace sandbox is non-negotiable** — every file operation validates path is within workspace

## Files to Create

- `sidecar/lib/tools/tool-registry.js` — tool definitions
- `sidecar/lib/tools/tool-executor.js` — execution engine
- `sidecar/lib/tools/sandbox.js` — path validation, command blocking
- `sidecar/test/tools/` — unit tests for each tool

## Risks

- MEDIUM (security-sensitive) — sandbox must be correct, path traversal is a real risk
- Test extensively: `../../../etc/passwd`, symlink traversal, command injection via args

## Success Criteria

1. ToolRegistry exports 5 tool definitions in Ollama function-calling JSON format
2. Tool executor rejects file paths outside task workspace (path traversal blocked)
3. Tool executor kills commands exceeding per-tool timeout
4. Every tool returns structured JSON observation with typed fields
