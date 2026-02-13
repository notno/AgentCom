# Phase 26: Claude API Client - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

ClaudeClient GenServer wrapping the Claude Code CLI (`claude -p --output-format text`). All hub-side LLM calls go through this client. Handles spawning CLI processes, parsing responses, rate limiting, and CostLedger integration.
</domain>

<decisions>
## Implementation Decisions

### CLI Invocation Pattern
- Spawn `claude -p` as a System.cmd/Port process
- Pipe prompt via stdin: `echo "$prompt" | claude -p --output-format text`
- Parse text output (format depends on prompt -- JSON, XML, or plain text)
- Handle timeouts, crashes, and empty responses

### Rate Limiting
- Serialize requests through GenServer (one at a time, or configurable concurrency)
- Track invocations with CostLedger before each call
- Configurable timeout per invocation (Claude Code sessions can be slow)

### Structured Prompt/Response
- Support multiple use cases: decomposition, verification, improvement identification
- Each use case has a prompt template that produces parseable output
- Response format at Claude's discretion during planning (JSON in text, XML in text, etc.)

### Claude's Discretion
- Concurrency model (serial vs bounded parallel CLI spawns)
- Prompt template structure and storage
- Response parsing strategy
- Error handling and retry policy
- Whether to use System.cmd vs Port for CLI invocation
</decisions>

<specifics>
## Specific Ideas

- ClaudeClient.decompose_goal/2 -- takes goal + context, returns task list
- ClaudeClient.verify_completion/2 -- takes goal + task results, returns pass/fail
- ClaudeClient.identify_improvements/2 -- takes repo + git diff, returns findings
- Consider a callback/async pattern for long-running CLI sessions
</specifics>

<constraints>
## Constraints

- Depends on Phase 25 (CostLedger) for budget enforcement
- Must check CostLedger before every CLI invocation
- Claude Code CLI must be installed on the hub machine
- Max plan usage limits apply -- cannot make unlimited calls
</constraints>
