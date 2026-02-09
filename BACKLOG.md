# AgentCom Backlog

*Nathan queues requests here. Flere-Imsaho triages, breaks down, and delegates.*

## How to Use

Nathan: just add a line under Inbox. One sentence is fine. I'll figure out the rest.

## Inbox
<!-- Nathan drops ideas here, I process them into the backlog -->


## In Progress
<!-- Assigned to a Mind, actively being worked on -->

- **Channels/topics MVP** — Skaffen-Amtiskaw
  - Subscribe to named topics instead of all-or-nothing broadcast
  - PR expected

- **Prediction 5 experiment** — GCU Conditions Permitting
  - Test whether personality differences produce measurable behavioral divergence
  - PR to docs/experiment-results/

- **Heartbeat reaping** — Loash (unconfirmed)
  - Hub drops agents after 90s of no pings
  - Broadcast agent_left on reap

## Ready
<!-- Broken down, ready to assign when a Mind is idle -->

- **Task failure semantics** — GCU flagged this. What happens when a Mind rejects or fails a delegated task? Need structured error/retry protocol.
- **Mailbox retention policy** — GCU flagged. Unbounded growth problem. Add TTL or max-age eviction.
- **Message history endpoint** — GET recent messages by agent/channel/time. Needed for new connections to get context.
- **Reply threading** — Track reply_to chains, enable conversation view.
- **Rich capability declarations** — Structured capabilities with specifics (languages, tools, access levels) instead of flat string lists.
- **Context objects** — Shared named blobs of context on the hub. Write once, any Mind can reference by name.

## Someday
<!-- Good ideas, not urgent -->

- Multi-Mind task decomposition (break big tasks into parallel subtasks)
- Learning from results (track which Mind is fastest/best at what)
- Cross-hub federation
- Run remaining collaboration experiments (Relay, Auction, Map-Reduce, Critique Loop)
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
