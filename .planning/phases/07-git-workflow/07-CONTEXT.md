# Phase 7: Git Workflow - Context

**Gathered:** 2026-02-10
**Status:** Ready for planning

<domain>
## Phase Boundary

CLI wrapper (`agentcom-git`) bundled with the sidecar that enforces git hygiene for autonomous agents. Three commands: `start-task` (fetch + branch from origin/main), `submit` (push + open PR with metadata), `status` (current branch, diff, uncommitted changes). Sidecar auto-invokes start-task on assignment and submit on completion. PR gatekeeper review logic is a separate (v2) concern — this phase just sets the reviewer field.

</domain>

<decisions>
## Implementation Decisions

### Branch naming & conventions
- Branch format: `{agent}/{task-slug}` (e.g. `gcu/add-login-endpoint`)
- Multiple commits allowed per branch — no squash on submit
- Task slug source: Claude's discretion (auto-slugify task title or use explicit metadata field)
- Commit messages: conventional commits enforced (`feat(scope): message`, `fix(scope): message`)

### PR content & metadata
- Full context in PR description: task ID, priority, agent name, original task description, auto-generated diff summary, files changed
- Auto-label PRs by agent (`agent:gcu`) and priority (`priority:urgent`)
- Request review from Flere-Imsaho (gatekeeper GitHub account) — automated review/merge logic deferred to v2
- Include task ID and direct link to task API endpoint (`/api/tasks/{id}`) in description for cross-referencing

### Command behavior & modes
- Dirty working tree on `start-task`: fail with error (refuse to start — agent must have clean state)
- Always `git fetch origin` before branching — no stale main allowed
- Force-push policy: Claude's discretion (pick safest default)
- Fully non-interactive — no prompts ever, agents run these autonomously, fail fast on errors

### Task lifecycle integration
- Sidecar auto-runs `start-task` when receiving a task assignment (before waking the agent — agent lands on a clean branch)
- Sidecar auto-runs `submit` when agent reports task_complete (fully autonomous pipeline)
- After submit, sidecar reports PR URL to hub (dashboard and task history show PR links)
- If start-task fails (fetch fails, dirty tree): wake agent anyway with warning — agent can try to resolve or report failure

### Claude's Discretion
- Task slug generation approach (auto-slugify vs metadata field)
- Force-push policy for re-submitting updated branches
- Exact PR description template formatting
- Error message wording and exit codes

</decisions>

<specifics>
## Specific Ideas

- The full pipeline should be: task assigned → sidecar fetches + branches → sidecar wakes agent → agent works → agent reports complete → sidecar pushes + opens PR → sidecar reports PR URL to hub
- Agents should never touch `main` directly — all work happens on feature branches
- PR description should be rich enough for Flere-Imsaho to review without needing to query AgentCom separately

</specifics>

<deferred>
## Deferred Ideas

- Automated PR review/merge by Flere-Imsaho — v2 gatekeeper role
- PR status webhooks (merge/close events back to hub) — future integration
- Branch cleanup after merge — could be a post-merge hook, not in scope

</deferred>

---

*Phase: 07-git-workflow*
*Context gathered: 2026-02-10*
