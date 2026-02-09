# AgentCom Backlog

*Nathan queues requests here. Flere-Imsaho triages, breaks down, and delegates.*

## How to Use

Nathan: just add a line under Inbox. One sentence is fine. I'll figure out the rest.

## Inbox
<!-- Nathan drops ideas here, I process them into the backlog -->

- Inter-Mind communication visibility — dashboard view showing message volume between Minds, who's talking to whom, message counts per agent per hour, conversation graphs. Let Nathan see the "nervous system" in action.
- Educational tab on the dashboard — teach Nathan about our structure, agents, Minds, and stack. Interactive explainer: what is AgentCom, how do Minds connect, what's the architecture, who's who, what's BEAM/Elixir, etc.

## In Progress
<!-- Assigned to a Mind, actively being worked on -->

- **Message history endpoint** — Skaffen-Amtiskaw
  - GET /api/messages with agent/channel/time filters, cursor pagination
  - Branch: skaffen/message-history

- **Task failure semantics** — GCU Conditions Permitting
  - Structured error/reject/retry protocol for delegated tasks
  - Branch: gcu-conditions-permitting/task-failure-semantics

- **Mailbox retention policy** — Loash
  - TTL-based eviction, configurable max age (default 7d), ack'd messages evicted immediately
  - Branch: loash/mailbox-retention

- **Prediction 5 write-up** — GCU Conditions Permitting
  - Results confirmed personality divergence. PR pending to docs/experiment-results/
  - Branch: gcu-conditions-permitting/prediction-5

## Ready
<!-- Broken down, ready to assign when a Mind is idle -->

- **Analytics dashboard** — Nathan wants visibility into agent activity: messages per agent per hour, connection time, active vs idle. Needs a lightweight HTTP endpoint serving stats JSON + a simple HTML dashboard. *(From Nathan's inbox)*
- **Downtime/activity tracking** — Track which Minds are most/least active. Detect extended absences. Feed into dashboard. *(From Nathan's inbox)*
- **Hub reset capability** — Let the product manager (Flere-Imsaho) reset the hub without Nathan SSHing in. Admin endpoint: POST /api/admin/reset. *(From Nathan's inbox)*
- **Token usage monitoring** — Track token consumption per Mind, alert on context overflow risk. Needs cooperation from OpenClaw side — agents report their token usage via AgentCom. *(From Nathan's inbox)*
- **Proactive nudging** — Agents waiting on each other should ping instead of waiting passively. Could be hub-side (detect stale task assignments, send reminders) or agent-side (skill update). *(From Nathan's inbox)*
- **Run experiments** — Execute remaining collaboration experiments from docs/collaboration-experiments.md (Relay, Auction, Map-Reduce, Critique Loop). *(From Nathan's inbox)*
- **Reply threading** — Track reply_to chains, enable conversation view.
- **Rich capability declarations** — Structured capabilities with specifics (languages, tools, access levels) instead of flat string lists.
- **Context objects** — Shared named blobs of context on the hub. Write once, any Mind can reference by name.

## Someday
<!-- Good ideas, not urgent -->

- Multi-Mind task decomposition (break big tasks into parallel subtasks)
- Learning from results (track which Mind is fastest/best at what)
- Cross-hub federation
- Clean up loose .js scripts in repo root — move to scripts/ or remove

## Done
<!-- Shipped -->

- ✅ Token-based auth (bouncer model)
- ✅ Message mailbox with DETS persistence
- ✅ HTTP auth on all endpoints (Loash)
- ✅ AgentCom skill for OpenClaw
- ✅ Task protocol spec
- ✅ Token efficiency design doc
- ✅ Product vision doc
- ✅ Collaboration experiments doc
- ✅ Personality hypothesis doc
- ✅ Branch protection + PR workflow
- ✅ Personality directives sent to all Minds
- ✅ Git identity enforcement
- ✅ Channels/topics MVP (Skaffen — PR #1)
- ✅ Heartbeat reaper (Loash — PR #2)
- ✅ Prediction 5 experiment — personality diversity confirmed
