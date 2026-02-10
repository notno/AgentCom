# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-09)

**Core value:** Reliable autonomous work execution -- ideas enter a queue and emerge as reviewed, merged PRs without human hand-holding for safe changes.
**Current focus:** Phase 4 (Scheduler) complete. Ready for Phase 5 (Smoke Test).

## Current Position

Phase: 4 of 8 (Scheduler) -- COMPLETE
Plan: 1 of 1 in current phase (all plans complete)
Status: Phase 4 complete. Scheduler GenServer auto-matches queued tasks to idle agents via PubSub events. Ready for Phase 5 (Smoke Test).
Last activity: 2026-02-10 -- Completed 04-01-PLAN.md (Scheduler GenServer)

Progress: [███████░░░] 69%

## Performance Metrics

**Velocity:**
- Total plans completed: 9
- Average duration: 4 min
- Total execution time: 0.61 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-sidecar | 4/4 | 21 min | 5 min |
| 02-task-queue | 2/2 | 8 min | 4 min |
| 03-agent-state | 2/2 | 6 min | 3 min |
| 04-scheduler | 1/1 | 2 min | 2 min |

**Recent Trend:**
- Last 5 plans: 02-02 (5 min), 03-01 (3 min), 03-02 (3 min), 04-01 (2 min)
- Trend: Stabilizing around 2-3 min for focused plans

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

### Pending Todos

None yet.

### Blockers/Concerns

- [Research]: Elixir version bump (1.14 to 1.17+) should be considered before starting v2 work for :gen_statem logger fix
- [Research]: Sidecar queue.json atomicity -- fs.writeFileSync has partial-write-on-crash risk, acceptable for launch

## Session Continuity

Last session: 2026-02-10
Stopped at: Completed 04-01-PLAN.md (Scheduler GenServer) -- Phase 4 complete
Resume file: None
