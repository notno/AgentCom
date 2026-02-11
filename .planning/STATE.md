# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-09)

**Core value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.
**Current focus:** Phase 8 (Onboarding) in progress. Plans 01 (API Endpoints) and 03 (Teardown + Submit CLI) complete.

## Current Position

Phase: 8 of 8 (Onboarding)
Plan: 2 of 3 in current phase
Status: Plans 08-01 and 08-03 complete. remove-agent.js and agentcom-submit.js created. Plan 08-02 (add-agent script) remaining.
Last activity: 2026-02-11 -- Completed 08-03-PLAN.md (Teardown + Task Submission CLI)

Progress: [██████████] 99%

## Performance Metrics

**Velocity:**
- Total plans completed: 18
- Average duration: 4 min
- Total execution time: 1.15 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-sidecar | 4/4 | 21 min | 5 min |
| 02-task-queue | 2/2 | 8 min | 4 min |
| 03-agent-state | 2/2 | 6 min | 3 min |
| 04-scheduler | 1/1 | 2 min | 2 min |
| 05-smoke-test | 2/2 | 10 min | 5 min |
| 06-dashboard | 3/3 | 11 min | 4 min |
| 07-git-workflow | 2/2 | 9 min | 5 min |
| 08-onboarding | 2/3 | 3 min | 2 min |

**Recent Trend:**
- Last 5 plans: 06-03 (3 min), 07-01 (4 min), 07-02 (5 min), 08-01 (1 min), 08-03 (2 min)
- Trend: Consistent 1-5 min for feature plans

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: Phases 1 (Sidecar) and 2 (Task Queue) are parallel -- no dependencies between them
- [Roadmap]: Phase 5 (Smoke Test) is the quality gate -- nothing after it matters if trivial tasks fail
- [Roadmap]: Phases 6, 7, 8 are independent after smoke test passes -- can parallelize
- [Roadmap]: PR gatekeeper deferred to v2 -- needs 50+ tasks of production data to calibrate heuristics
- [01-01]: Reuse existing hub identify protocol with client_type: sidecar field (backward-compatible)
- [01-01]: Add protocol_version: 1 to all outgoing messages for forward-compatibility
- [01-01]: Use chokidar v3 (CJS-compatible) not v4 (ESM-only) matching codebase conventions
- [01-01]: Use write-file-atomic v5 (latest CJS-compatible version)
- [01-02]: Task IDs auto-generated using crypto.strong_rand_bytes (consistent with auth token pattern)
- [01-02]: task_progress is fire-and-forget (no ack) to reduce chattiness
- [01-02]: task_recovering triggers task_reassign -- Phase 2 adds intelligence
- [01-02]: Push-task endpoint uses existing RequireAuth (any authed agent can push, scheduler replaces in Phase 2)
- [01-03]: Persist task to queue.json BEFORE sending task_accepted to hub (crash-safe ordering)
- [01-03]: Wake command skipped gracefully when not configured (agent self-start mode)
- [01-03]: Confirmation timeout treated as failure (not retry) to prevent infinite wake loops
- [01-03]: Result file cleanup after hub notification to prevent data loss
- [01-04]: Recovery reports task_recovering AFTER WebSocket identification (needs connection ready)
- [01-04]: task_reassign is default Phase 1 behavior; task_continue reserved for Phase 2+ intelligence
- [01-04]: Wrapper scripts handle git/npm failure gracefully (continue with current version if offline)
- [01-04]: pm2 ecosystem uses process.platform for cross-platform script/interpreter selection
- [02-01]: Dual-DETS approach: main table for active tasks, separate table for dead-letter
- [02-01]: In-memory sorted list for priority index (not ETS) -- simple at expected scale
- [02-01]: History capped at 50 entries per task to prevent unbounded growth
- [02-01]: update_progress is fire-and-forget cast (no generation check for informational updates)
- [02-01]: Dual atom/string key lookup in submit for Socket (string) and internal (atom) flexibility
- [02-02]: Map.get for optional fields in format_task to handle tasks without last_error key
- [02-02]: String.to_existing_atom for status filter to prevent atom table exhaustion
- [02-02]: Plug.Router route ordering: specific paths (/dead-letter, /stats) before parameterized (:task_id)
- [03-01]: restart: :temporary for agent FSM processes -- agents must reconnect, not auto-restart on crash
- [03-01]: Defensive reclaim stub in AgentFSM -- logs intent, actual TaskQueue.reclaim_task/1 deferred to Plan 02
- [03-01]: Synchronous init (no handle_continue) -- avoids race conditions where messages arrive before state is ready
- [03-02]: Socket.terminate does NOT clean up FSM -- AgentFSM's :DOWN handler owns task reclamation (Pitfall 3: clear ownership)
- [03-02]: Presence.update_fsm_state does NOT broadcast to PubSub -- FSM state changes are frequent and internal
- [03-02]: Route ordering: /api/agents/states before /:agent_id/state before /:agent_id/subscriptions
- [04-01]: Scheduler is stateless -- queries TaskQueue and AgentFSM on every attempt to avoid stale-state bugs
- [04-01]: Scheduler does NOT call AgentFSM.assign_task -- Socket push_task handler owns FSM transition
- [04-01]: Greedy matching loop iterates all queued tasks, not just queue head, preventing head-of-line blocking
- [04-01]: Map.get with default [] for needed_capabilities on existing DETS records for backward compat
- [05-01]: Used Mint.HTTP + Mint.WebSocket directly for AgentSim instead of Fresh wrapper (full control over connection lifecycle)
- [05-01]: Used :httpc for HTTP helpers (built-in, no extra deps for test usage)
- [05-01]: Generation tracked in Map keyed by task_id in sidecar (supports recovery edge cases)
- [05-02]: AgentFSM broadcasts :agent_idle to PubSub on idle transition (fixes scheduler race where idle agents missed)
- [05-02]: AgentFSM.list_all catches :exit for FSMs stopping during enumeration (defensive concurrency)
- [05-02]: Setup uses Supervisor.terminate_child/restart_child for clean DETS reset (avoids restart loops)
- [05-02]: AgentSim sends identify after WebSocket upgrade completes (correct connection sequencing)
- [06-01]: No auth on /api/dashboard/state and /ws/dashboard -- local network only, matching existing /dashboard pattern
- [06-01]: Event batching via 100ms flush timer in DashboardSocket to prevent PubSub flood to browser
- [06-01]: DashboardState tracks hourly stats in-memory (resets on restart) -- same ephemeral pattern as Analytics
- [06-01]: Health heuristics: agent offline (WARNING), queue growing 3x (WARNING), >50% failure (CRITICAL), stuck >5min (WARNING)
- [06-02]: Incremental events trigger snapshot re-request rather than client-side state merge -- simpler, avoids stale data drift
- [06-02]: Relative times re-rendered every 30s via setInterval to keep timestamps current without server push
- [06-02]: Queue expand button collapsed by default to keep command center dense
- [06-03]: VAPID keys generated ephemerally on startup if env vars not set -- notifications reset on restart, acceptable for v1
- [06-03]: Push notification delivery errors caught silently, failed subscriptions removed (progressive enhancement)
- [06-03]: Health check polling at 60s interval piggybacks on DashboardState.snapshot() rather than separate tracking
- [07-01]: Auto-slugify task description for branch names (no metadata field required from submitters)
- [07-01]: force-with-lease as default push strategy for safe re-submission without overwriting
- [07-01]: PR body written to temp file via --body-file to avoid cross-platform shell escaping
- [07-01]: Labels created idempotently via gh label create --force before PR creation
- [07-01]: Config validates repo_dir exists and is a git repo at startup (fail fast with clear error)
- [07-02]: spawnSync instead of execSync for runGitCommand -- cleaner error handling without nested try/catch
- [07-02]: Git workflow opt-in via repo_dir config field presence -- zero impact on existing sidecars
- [07-02]: start-task failure sets git_warning on task but still wakes agent -- graceful degradation
- [07-02]: submit failure still reports task_complete to hub -- PR URL simply omitted, no data loss
- [07-02]: New config fields (repo_dir, reviewer, hub_api_url) default to empty string, not required
- [08-01]: Registration endpoint is unauthenticated -- uses network trust model (same as /api/dashboard/state)
- [08-01]: Duplicate agent_id check via Auth.list() before token generation -- returns 409 on conflict
- [08-01]: Hub URLs constructed dynamically from conn.host/conn.port -- no hardcoded addresses
- [08-01]: GET /api/config/default-repo is unauthenticated -- agents need repo URL before they have a token
- [08-03]: remove-agent.js auto-reads token from agent config.json if --token not provided
- [08-03]: Best-effort teardown: each step wrapped in try/catch, only exit 1 if all 3 steps fail
- [08-03]: agentcom-submit.js stores --target in metadata.target_agent (no first-class hub field yet)
- [08-03]: Both CLI scripts use inline httpRequest helper (standalone, no shared modules)

### Pending Todos

None yet.

### Blockers/Concerns

- [Research]: Elixir version bump (1.14 to 1.17+) should be considered before starting v2 work for :gen_statem logger fix
- [Research]: Sidecar queue.json atomicity -- fs.writeFileSync has partial-write-on-crash risk, acceptable for launch

## Session Continuity

Last session: 2026-02-11
Stopped at: Completed 08-03-PLAN.md (Teardown + Task Submission CLI). Plan 08-02 (add-agent script) remaining.
Resume file: None
