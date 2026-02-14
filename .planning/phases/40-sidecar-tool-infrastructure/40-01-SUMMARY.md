---
phase: 40-sidecar-tool-infrastructure
plan: 01
subsystem: tools
tags: [ollama, sandbox, security, path-validation, function-calling]

requires:
  - phase: 37-ci-fix
    provides: green CI baseline
provides:
  - 5 Ollama-compatible tool definitions (read_file, write_file, list_directory, run_command, search_files)
  - Sandbox path validation with symlink-aware checking
  - Command blocking with 13 dangerous patterns
  - SandboxError class with typed error codes
affects: [40-02, 41-agentic-execution-loop]

tech-stack:
  added: []
  patterns:
    - "Ollama function-calling JSON format for tool definitions"
    - "Two-phase path validation: resolve + realpath for symlink safety"
    - "Regex-based command blocking with BLOCKED_PATTERNS array"

key-files:
  created:
    - sidecar/lib/tools/tool-registry.js
    - sidecar/lib/tools/sandbox.js
    - sidecar/test/tools/tool-registry.test.js
    - sidecar/test/tools/sandbox.test.js

key-decisions:
  - "13 blocked command patterns covering privilege escalation, destructive deletes, network access, and debugger attachment"
  - "Windows symlink tests skipped (require elevated privileges) with process.platform guard"

duration: 3 min
completed: 2026-02-14
---

# Phase 40 Plan 01: Tool Registry and Sandbox Summary

**5 Ollama-format tool definitions with workspace sandbox providing path traversal prevention and command blocking**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-14T22:00:00Z
- **Completed:** 2026-02-14T22:03:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Tool registry with 5 definitions in Ollama /api/chat function-calling JSON format
- Sandbox path validation blocks traversal attacks (../../../etc/passwd) and symlink escapes
- Command blocking prevents 13 categories of dangerous operations (sudo, rm -rf /, curl, wget, etc.)
- SandboxError class with typed codes for structured error reporting

## Task Commits

Each task was committed atomically:

1. **Task 1: Tool registry with 5 Ollama-format definitions** - `39cfe06` (feat)
2. **Task 2: Sandbox module with path validation and command blocking** - `31c3e60` (feat)

## Files Created/Modified
- `sidecar/lib/tools/tool-registry.js` - 5 tool definitions with getToolDefinitions(), getToolByName(), TOOLS exports
- `sidecar/lib/tools/sandbox.js` - validatePath(), isCommandBlocked(), SandboxError, BLOCKED_PATTERNS exports
- `sidecar/test/tools/tool-registry.test.js` - 42 unit tests for registry structure and lookup
- `sidecar/test/tools/sandbox.test.js` - 52 unit tests for path validation, command blocking, error codes

## Decisions Made
- 13 blocked patterns: sudo, rm -rf /, shutdown, reboot, format, mkfs, dd, curl, wget, nc, netcat, python http.server, node --inspect
- Symlink tests guarded with `process.platform !== 'win32'` since symlinks require elevated privileges on Windows

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## Next Phase Readiness
- Tool registry and sandbox ready for Plan 40-02 (tool executor with 5 handlers)
- All exports match the interface expected by tool-executor.js

---
*Phase: 40-sidecar-tool-infrastructure*
*Completed: 2026-02-14*
