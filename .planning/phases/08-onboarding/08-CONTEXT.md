# Phase 8: Onboarding - Context

**Gathered:** 2026-02-11
**Status:** Ready for planning

<domain>
## Phase Boundary

One-command agent provisioning: register a new agent with the hub, set up its sidecar, clone the target repo, start it as a pm2 process, and verify the full pipeline works with a test task. Also includes a task submission CLI so the system is immediately usable after onboarding, and a remove-agent command for clean teardown.

</domain>

<decisions>
## Implementation Decisions

### Script interface
- Node script (part of the sidecar package), not bash
- Fully non-interactive — everything via flags/args, no prompts
- Invocation: `add-agent <name> --hub <url>` (extensible flag-based)
- Script runs on the agent machine (SSH in first, then run locally)
- Full setup: registers with hub, generates config, clones repo, installs deps, starts pm2, verifies
- Agent names auto-generated as Culture ship names (e.g., gcu-sleeper-service) — fun, on-brand, unique

### Config templating
- Script needs only `--hub <url>` from the user; agent name is auto-generated
- Auth token obtained automatically by calling hub registration API
- Repo URL fetched from hub's default repo config (hub stores this in a config file)
- Install directory: `~/.agentcom/<agent-name>/`
- Capabilities default to general-purpose (all agents identical, no specialization)
- Wake command auto-templated — requires OpenClaw pre-installed (script checks and fails if missing)
- Hub needs a new config file for default settings (default_repo, etc.)

### Verification depth
- Full round-trip: submits a trivial test task, waits for agent to pick it up and complete it
- 30-second timeout for test task completion — hard fail if not completed
- Test task cleaned up on success (remove task, delete test branch/PR, no artifacts)
- Step-by-step log output: `[1/N] Registering agent... done` for each step

### Error recovery
- Fail fast with resume flag: stop immediately on failure, save progress
- Re-running with `--resume` skips completed steps
- Hard fail if test task doesn't complete — agent registered but not verified
- Pre-flight checks at Claude's discretion (hub reachable, OpenClaw installed, Node version, etc.)
- `remove-agent` command for clean teardown (deregister, stop pm2, delete directory)

### Task submission CLI
- Include `agentcom submit` command as part of the sidecar/onboarding package
- Full flag set: `--priority`, `--target <agent>`, `--metadata` — mirrors the API
- Makes the system immediately usable after onboarding
- Quick-start commands printed after successful onboarding (how to submit tasks, check status, view dashboard)

### Claude's Discretion
- Sidecar dependency installation approach (npm install vs pre-built package)
- Pre-flight check selection (which checks, how thorough)
- Culture ship name generation implementation
- Exact step ordering during onboarding
- Quick-start cheat-sheet content and formatting

</decisions>

<specifics>
## Specific Ideas

- All agents are general-purpose — no capability-based specialization. Routing is not skill-based.
- Agent names should be Culture ship names (Iain M. Banks), auto-generated — consistent with existing naming (gcu-conditions-permitting)
- The hub needs a config file for default settings — at minimum a default repo URL that new agents clone
- After onboarding, print quick-start commands so the user knows exactly how to use the system

</specifics>

<deferred>
## Deferred Ideas

- Live conversation with agents (real-time chat through AgentCom) — new capability, own phase
- Agent capability specialization / skill-based routing — not needed for v1, all agents general-purpose

</deferred>

---

*Phase: 08-onboarding*
*Context gathered: 2026-02-11*
