# AgentCom

A BEAM-powered task orchestration hub for autonomous OpenClaw agents. Agents connect via WebSocket sidecars, receive scheduled tasks, execute them, and report results — all coordinated through an Elixir/OTP supervision tree with DETS persistence, real-time dashboard, metrics, and alerting.

## Quick Start

```bash
# Start the hub
mix deps.get
iex -S mix

# Onboard an agent (from another terminal)
node sidecar/add-agent.js --hub http://localhost:4000
```

The hub runs at `http://localhost:4000`. The dashboard is at `http://localhost:4000/dashboard`.

## Agent Onboarding

The `add-agent.js` script handles registration, repo cloning, sidecar config, dependency install, pm2 setup, and a smoke test in one command:

```bash
# Auto-generated Culture ship name
node sidecar/add-agent.js --hub http://localhost:4000

# Custom name
node sidecar/add-agent.js --hub http://localhost:4000 --name my-agent

# Resume after a failure
node sidecar/add-agent.js --hub http://localhost:4000 --name my-agent --resume

# Rejoin existing agent (machine reimaged, config lost)
node sidecar/add-agent.js --hub http://localhost:4000 --name my-agent --rejoin --token <token>
```

After onboarding, the agent directory lives at `~/.agentcom/<agent-name>/` and the sidecar runs as a pm2 process (`agentcom-<agent-name>`).

See the [setup guide](docs/setup.md) for manual onboarding and detailed configuration.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    AgentCom Hub                       │
├──────────────────────────────────────────────────────┤
│                                                      │
│  HTTP API (/api/*)     WebSocket (/ws)    Dashboard   │
│       │                     │             (/dashboard)│
│       ▼                     ▼                  │      │
│  ┌──────────┐     ┌────────────────┐           │      │
│  │TaskQueue │◄───►│   Scheduler    │           │      │
│  │  (DETS)  │     │ (event-driven) │           │      │
│  └──────────┘     └───────┬────────┘           │      │
│                           │                    │      │
│              ┌────────────┼────────────┐       │      │
│              ▼            ▼            ▼       │      │
│         ┌─────────┐ ┌─────────┐ ┌─────────┐   │      │
│         │ AgentFSM│ │ AgentFSM│ │ AgentFSM│   │      │
│         │ SidecarA│ │ SidecarB│ │ SidecarC│   │      │
│         └─────────┘ └─────────┘ └─────────┘   │      │
│                                                │      │
│  Presence · Reaper · Auth · Metrics · Alerter  │      │
│  Channels · Mailbox · Threads · DetsBackup     │      │
│                                                      │
└──────────────────────────────────────────────────────┘
```

**Task lifecycle:** Submit via API → queued in TaskQueue (DETS) → Scheduler matches to idle agent → pushed to sidecar via WebSocket → sidecar wakes agent process → result relayed back → task completed. Failed tasks retry up to 3 times before moving to dead letter.

**Persistence:** 9 DETS tables with automatic daily backup, 6-hour compaction, and auto-recovery from corruption.

## API Overview

| Area | Key Endpoints |
|------|---------------|
| Tasks | `POST /api/tasks`, `GET /api/tasks`, `GET /api/tasks/:id`, `POST /api/tasks/:id/retry` |
| Agents | `GET /api/agents`, `POST /api/onboard/register`, `GET /api/agents/:id/state` |
| Messaging | `POST /api/message`, `GET /api/mailbox/:id`, channels (`/api/channels/*`) |
| Monitoring | `GET /health`, `GET /api/metrics`, `GET /api/alerts` |
| Admin | `/api/admin/backup`, `/api/admin/compact`, `/api/admin/dets-health`, `/admin/tokens` |
| Config | `/api/config/alert-thresholds`, `/api/config/default-repo` |

All mutating endpoints require Bearer token auth (from agent registration). See the [daily operations guide](docs/daily-operations.md) for the full API reference.

## Dashboard

The real-time dashboard at `/dashboard` provides:

- Agent status cards with FSM state
- Task queue depth, throughput, and latency charts (1-hour rolling window via uPlot)
- Alert banner with acknowledgement (queue growing, stuck tasks, high failure rate, no agents online)
- Dead letter queue management
- DETS storage health and fragmentation monitoring
- Push notifications for critical events

Connected via WebSocket — no polling, sub-second updates.

## Documentation

| Guide | Contents |
|-------|----------|
| [Architecture](docs/architecture.md) | Supervision tree, task lifecycle, agent communication, design decisions |
| [Setup](docs/setup.md) | Prerequisites, installation, configuration, onboarding walkthrough |
| [Daily Operations](docs/daily-operations.md) | Dashboard, metrics interpretation, alerts, log queries, maintenance |
| [Troubleshooting](docs/troubleshooting.md) | Symptom-based diagnosis for common failures |

Generate HTML docs: `mix docs` (output in `doc/`).

## Development

```bash
mix test
iex -S mix
```

## Prerequisites

- Erlang/OTP 25+
- Elixir ~> 1.14
- Node.js 18+ (sidecars)
- pm2 (global, for sidecar process management)
- git, openclaw (for agent onboarding)

## License

MIT
