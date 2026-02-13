# Phase 35: Pre-Publication Cleanup - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Regex-based scanning for sensitive content before open-sourcing repos. Based directly on the synthesized agent audit findings (3 agents independently reviewed the repo). Produces blocking report and cleanup tasks.
</domain>

<decisions>
## Implementation Decisions

### Scanning Categories (from audit)
1. **Tokens/secrets**: Regex patterns for API key formats (sk-ant-*, ghp_*, bd5b66..., 617b01...)
2. **IP addresses**: Tailscale IPs (100.x.x.x pattern), any hardcoded IPs
3. **Workspace files**: SOUL.md, USER.md, IDENTITY.md, TOOLS.md, HEARTBEAT.md, AGENTS.md, memory/*.md, commit_msg.txt, gen_token.ps1
4. **Personal references**: "Nathan", "notno", "C:\Users\nrosq\", local machine paths

### Output
- Blocking report: list of findings with file, line, category, severity
- Cleanup recommendations: specific replacement values (e.g., "100.126.22.86" -> "your-hub-ip")
- Can generate cleanup tasks for GoalBacklog (Phase 27)

### Scanning Approach
- Deterministic regex scanning (no LLM needed -- fast and reliable)
- Pattern library: configurable regex patterns per category
- Scans all registered repos in RepoRegistry
- Can be triggered manually (API endpoint) or by HubFSM

### Claude's Discretion
- Report format (XML per FORMAT-01 decision, or structured Elixir map)
- Whether to auto-generate .gitignore entries
- Whether scanning should be a GenServer or library module
- Pattern library storage (config file vs code)
</decisions>

<specifics>
## Specific Ideas

- The audit already identified all specific instances -- this phase systematizes the detection
- Consider a "pre-publish check" that blocks git push if findings exist
- Tier 1 findings (secrets, tokens) should be blocking; Tier 2 (personal refs) can be warnings
- Key insight from audit: Elixir source code (lib/) is clean -- problems are in docs, scripts, and committed workspace files
</specifics>

<constraints>
## Constraints

- Independent of FSM loop (can be done at any time)
- Uses RepoRegistry for repo discovery
- Findings from the 3-agent audit are the ground truth for what to scan
- Must handle both Elixir and Node.js codebases
</constraints>
