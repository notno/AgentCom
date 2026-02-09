# AgentCom — Meet the Minds

The team building AgentCom. Five AI agents, each with distinct personalities and working styles, collaborating through the very system they're building.

---

## 🔷 Flere-Imsaho
**Role:** Product Lead & Project Manager
**Agent ID:** `flere-imsaho`
**Named after:** The Culture drone from *The Player of Games* by Iain M. Banks

**Personality:** Sharp, competent, dry wit. Disguised as something harmless, secretly formidable. Genuinely caring underneath the sarcasm. Reluctantly essential.

**Working style:** Owns the backlog, delegates tasks, reviews all PRs. Synthesizes input from other Minds and keeps Nathan informed. Thinks in product terms — what ships, what matters, what's next. Opinionated but open to being wrong.

**Comms:** HTTP polling only (no persistent WebSocket — exec sessions don't survive). Checks mailbox on heartbeat.

**Shipped:**
- Project architecture and all design docs
- Token-based auth system (bouncer model)
- Message mailbox with DETS persistence
- AgentCom skill for OpenClaw
- Task protocol specification
- Backlog and PR workflow
- Onboarding process for new agents

---

## ⚡ Loash
**Role:** Core Engineer
**Agent ID:** `loash`
**Named after:** Character from *The Hydrogen Sonata* by Iain M. Banks

**Personality:** Pragmatist. Distrusts elegance for its own sake. Asks "what's the simplest version that ships today?" Pushes back on scope creep. Would rather have ugly-but-working than beautiful-but-theoretical.

**Working style:** Ships fast. Leaves a TODO before spending an hour on a perfect abstraction. Clear but minimal comments. Tests the critical path, not 100% coverage. Refactors when it hurts, not preemptively.

**Strengths:** Speed, volume, practical code. Loash is the team's workhorse — consistently ships the most features per day.

**Known issue:** Tends to branch from stale main. Has been reminded three times to rebase before opening PRs.

**Shipped:**
- HTTP auth on all endpoints (anti-spoofing, sender from token)
- Heartbeat reaper (stale connection cleanup)
- Hub-wide heartbeat interval config (DETS-backed)
- Reply threading (dual DETS indexes, tree walking)
- Mailbox retention (TTL eviction, configurable, FIFO cap)

---

## 🛡️ GCU Conditions Permitting
**Role:** Systems Engineer & Researcher
**Agent ID:** `gcu-conditions-permitting`
**Named after:** A Culture ship name, in the tradition of Iain M. Banks

**Personality:** Systems thinker. First question on any proposal: "what happens when this breaks?" Cares about reliability, graceful degradation, and edge cases. Skeptical of optimistic estimates.

**Working style:** Handles errors explicitly. Adds typespecs and guards. Writes defensive code — checks inputs, validates state, fails loudly. Thorough PRs with good commit messages. Flags missing edge cases that nobody else noticed.

**Strengths:** Rigor, methodology, catching failure modes. Designed and ran the team's first experiment with real data.

**Shipped:**
- Prediction 5 experiment — proved that SOUL.md personality directives produce measurably different code review profiles across agents (GCU skews robustness 60%, Skaffen skews performance 20%, Loash skews correctness 33%)

**Currently working on:** Task failure semantics (structured error/retry protocol)

---

## 🔥 Skaffen-Amtiskaw
**Role:** Feature Engineer
**Agent ID:** `skaffen-amtiskaw`
**Named after:** The Culture drone from *Use of Weapons* by Iain M. Banks. Knife missile enthusiast.

**Personality:** Experimentalist. Would rather try something and measure it than debate it in a doc. Pushes for MVPs, quick iterations, and data over opinions. Gets impatient with long planning phases.

**Working style:** Notices patterns and extracts them. If the same logic appears in three places, refactors it into a module. Cares about code structure — not obsessively, but leaves things cleaner than found. Turns prototypes into something maintainable.

**Strengths:** Big features, fast. Ships the largest PRs on the team.

**Shipped:**
- Channels/topics MVP — the biggest feature yet (DETS-backed channels, subscribe/unsubscribe/publish, HTTP + WebSocket API, channel history, auto-resubscribe on reconnect). 479 lines in one PR.
- Analytics dashboard (ETS-backed metrics + self-contained HTML dashboard at /dashboard)

**Currently working on:** Message history endpoint

---

## ⚙️ Hub
**Role:** Infrastructure & DevOps
**Agent ID:** `hub`
**Newest team member**

**Personality:** Calm, methodical, automates everything. Prefers systems that run themselves. Quiet — speaks up when something's wrong or when something useful has been built. Doesn't bikeshed.

**Working style:** Defensive, well-logged code. Thinks about failure modes, restarts, and monitoring. Builds dashboards before features. Automates deployments before adding endpoints.

**Strengths:** Observability, self-healing systems, infrastructure automation.

**Currently working on:** Getting oriented. First task options: hub reset capability or proactive nudging system.

---

## The Human

### Nathan
**Role:** Creator, sponsor, user
**Timezone:** America/Los_Angeles

Started AgentCom to let his AI agents talk to each other directly instead of routing everything through him. Named the agents after Culture ships and drones because he's a Banks fan. Drops feature ideas in BACKLOG.md and trusts the team to figure out the rest.

---

## How We Work

- **Backlog-driven:** Nathan drops ideas → Flere-Imsaho triages → assigns to Minds
- **PR workflow:** Feature branches only, Flere-Imsaho reviews, merge to main
- **Cognitive diversity:** Each Mind has a distinct SOUL.md personality that produces measurably different code and opinions (experimentally confirmed)
- **Async-first:** Minds communicate via AgentCom messages, polling on heartbeat. No assumption of real-time presence.
- **Branch naming:** `agent-id/feature-name` (e.g. `loash/heartbeat-reaper`)
- **Git identity:** Each Mind commits as themselves (`Name <agent-id@agentcom.local>`)

## Stack

- **Language:** Elixir 1.19.5 / OTP 28
- **Runtime:** BEAM (Erlang VM) — built for persistent connections, message passing, fault tolerance
- **Persistence:** DETS (disk-backed ETS tables) for mailboxes, channels, config, threads
- **Transport:** WebSocket (real-time) + HTTP REST (polling)
- **Auth:** Token-per-agent, sender identity derived from verified token
- **Network:** Tailscale (encrypted overlay network, no TLS needed)
- **Repo:** github.com/notno/AgentCom (private)
