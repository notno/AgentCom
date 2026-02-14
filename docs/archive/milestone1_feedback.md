# Milestone 1 Architecture Feedback

## What's Working Well

**Strong OTP foundation.** Elixir/BEAM is an excellent choice for this kind of system. The GenServer-per-concern design (Auth, Mailbox, Presence, Channels, TaskQueue, AgentFSM, Scheduler) maps naturally to OTP supervision trees, giving you fault isolation and restart semantics for free. This is one of the best possible tech choices for a distributed agent coordination hub.

**Clean separation: Hub vs Sidecar.** Keeping the hub in Elixir (stateful coordination) and the sidecar in Node.js (agent-local relay, git ops) is pragmatic. Each runtime plays to its strengths.

**Event-driven scheduler.** The PubSub-reactive scheduler that responds to task and presence events is the right pattern. It avoids polling and scales naturally with the BEAM's message-passing model.

**GPU-scheduler-style push model.** The v1 to v2 evolution from pull-based to push-based task assignment is a smart architectural move. Having the hub decide which agent gets which task (capability matching, FSM state awareness) is much more controllable than agents competing for work.

## Concerns

**Zero test coverage is the biggest risk.** With 22 GenServer modules managing persistent DETS state, one regression in the Scheduler or AgentFSM could cascade across the system. This should be the top priority for the next milestone.

**DETS as primary storage has a ceiling.** It works now with 5 agents, but DETS tables have known fragmentation issues, a 2GB size limit, and no built-in compaction. There's no backup/recovery strategy documented. A single corrupt DETS file could lose your mailbox or task queue.

**Security is thin.** Plaintext token storage, no rate limiting, minimal input validation. If this ever leaves a Tailscale mesh, these become critical vulnerabilities.

**Sidecar complexity.** The Node.js sidecar is doing a lot -- WebSocket relay, queue management, wake triggers, git workflow, PM2 lifecycle. This feels like it could fragment into hard-to-debug failure modes, especially since there's no test coverage there either.

## The Recursive Aspect

The most interesting thing here is that the 5 AI agents building AgentCom are using AgentCom itself to coordinate. That's a powerful feedback loop -- the team is its own dogfood. It also means stability matters more than in a typical early-stage project, since failures directly impact your development velocity.

## Recommended Priorities

1. **Tests** -- even basic integration tests for the Scheduler to AgentFSM to TaskQueue pipeline
2. **DETS backup/compaction** -- a Reaper extension or separate GenServer
3. **Input validation** at the WebSocket and HTTP boundaries
4. **Observability** -- structured logging for the task lifecycle (delegate, assign, accept, complete) to debug production issues

## Summary

Solid architecture, well-documented, pragmatic tech choices. The main risks are operational (no tests, no backup, thin security) rather than architectural.
