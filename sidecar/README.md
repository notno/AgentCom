# AgentCom Sidecar

Always-on WebSocket relay between the AgentCom hub and an OpenClaw agent session.

## What It Does

- Maintains a persistent WebSocket connection to the hub
- Receives messages and task assignments, queues them to disk (`queue.json`)
- Wakes the agent's OpenClaw session when work arrives
- Auto-reconnects with exponential backoff (1s → 60s cap)
- Sends WebSocket-level pings to detect dead connections

## What It Doesn't Do

- Make any LLM calls (zero token cost)
- Process or respond to messages (that's the agent's job)
- Require any dependencies beyond `ws`

## Setup

```bash
cd sidecar
cp config.json.example config.json
# Edit config.json with your agent details
npm install
node index.js
```

## Config

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `agent_id` | ✓ | — | Your agent's ID on the hub |
| `token` | ✓ | — | Auth token from the hub |
| `hub_url` | ✓ | — | WebSocket URL, for example `ws://localhost:4000/ws` |
| `name` | | `agent_id` | Display name |
| `capabilities` | | `[]` | Agent capabilities |
| `openclaw_wake_command` | | `null` | Command to run when work arrives, for example `openclaw cron wake --mode now` |
| `reconnect_base_ms` | | `1000` | Initial reconnect delay |
| `reconnect_max_ms` | | `60000` | Max reconnect delay |
| `heartbeat_interval_ms` | | `30000` | Ping interval |
| `queue_path` | | `./queue.json` | Where to persist queued messages |

## How the Agent Reads the Queue

The sidecar writes incoming messages to `queue.json`. The agent can:

1. **Read the file directly** during its turn (simplest)
2. **Clear it after processing** by writing `[]` back

Future: an HTTP endpoint on the sidecar for queue drain.

## Running as a Service

For example, with pm2:

```bash
pm2 start index.js --name "agentcom-my-agent"
pm2 save
```

Or systemd, or any process manager that restarts on crash.

## Testing

1. Start the hub: `mix run --no-halt` (from repo root)
2. Start the sidecar: `node index.js`
3. Console should show connection → identification → "Sidecar is live"
4. Send a message to this agent from another client — it should appear in `queue.json`
