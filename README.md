# SpellRouter 🔮

A BEAM-powered hub for routing spell signals between operators.

Part of the [funmagic](https://github.com/notno/funmagic) ecosystem — functional magic for TTRPGs.

## Concept

Spells are **pipelines** of operators. Each operator transforms a 16-dimensional **semantic signal**, nudging "responders" that represent aspects of meaning:

```
source("fire") |> ignite |> hush |> veil |> bind |> commit |> emit
```

The signal flows left-to-right, each operator adjusting responder values before passing it on. The final signal determines the spell's effect.

## Quick Start

```bash
# Install dependencies
mix deps.get

# Start the server
mix run --no-halt

# Or with custom port
PORT=4001 mix run --no-halt
```

Server runs at `http://localhost:4000`

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   SpellRouter                        │
├─────────────────────────────────────────────────────┤
│                                                     │
│   HTTP API          WebSocket              PubSub   │
│   ─────────         ─────────              ──────   │
│   /api/*            /socket                Events   │
│                         │                     │     │
│                         ▼                     │     │
│              ┌──────────────────┐             │     │
│              │ OperatorRegistry │◄────────────┘     │
│              └────────┬─────────┘                   │
│                       │                             │
│         ┌─────────────┼─────────────┐               │
│         ▼             ▼             ▼               │
│   ┌─────────┐   ┌─────────┐   ┌─────────┐          │
│   │  Bash   │   │ Remote  │   │ Elixir  │          │
│   │Operator │   │  Agent  │   │ Module  │          │
│   └─────────┘   └─────────┘   └─────────┘          │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## API

### HTTP Endpoints

**Health check:**
```bash
curl http://localhost:4000/health
```

**List responders:**
```bash
curl http://localhost:4000/api/responders
```

**Run a pipeline:**
```bash
curl -X POST http://localhost:4000/api/pipeline/run \
  -H "Content-Type: application/json" \
  -d '{
    "steps": [
      {"type": "source", "name": "fire", "pattern": {"spark_lord": 0.8}},
      {"type": "bash", "script": "priv/operators/hush.sh"},
      {"type": "bash", "script": "priv/operators/veil.sh"},
      {"type": "commit"},
      {"type": "emit"}
    ]
  }'
```

### WebSocket Protocol

Connect to `ws://localhost:4000/socket`

**Register as an operator:**
```json
{"type": "register", "agent_id": "my_operator", "capabilities": ["transform"]}
```

**Receive transform requests:**
```json
// Incoming
{"type": "transform", "request_id": "abc123", "signal": {...}}

// Respond with
{"type": "transform_result", "request_id": "abc123", "signal": {...}}
```

**Run a pipeline:**
```json
{"type": "run_pipeline", "request_id": "xyz", "steps": [...]}
```

**Subscribe to events:**
```json
{"type": "subscribe", "topic": "pipeline:*"}
```

## Signal Structure

```json
{
  "values": {
    "spark_lord": 0.8,
    "quiet_tide": 0.0,
    "binder_who_smiles": 0.0,
    "last_witness": 0.0,
    "hollow_crown": 0.0,
    "dream_eater": 0.0,
    "iron_promise": 0.0,
    "soft_betrayal": 0.0,
    "ember_heart": 0.0,
    "void_singer": 0.0,
    "golden_liar": 0.0,
    "storm_bringer": 0.0,
    "pale_hunter": 0.0,
    "silk_shadow": 0.0,
    "bone_reader": 0.0,
    "star_child": 0.0
  },
  "trace": [],
  "metadata": {}
}
```

All values are clamped to [-1.0, 1.0].

## Bash Operators

Bash operators receive signal JSON on stdin, output transformed signal on stdout:

```bash
#!/bin/bash
# hush.sh - attenuate, strengthen quiet aspects
jq '
  .values.quiet_tide += 0.18 |
  .values.last_witness -= 0.08
'
```

Make sure `jq` is installed: `sudo apt install jq`

## Remote Operators

Connect via WebSocket, register, and respond to transform requests:

```python
import websocket
import json

ws = websocket.create_connection("ws://localhost:4000/socket")

# Register
ws.send(json.dumps({
    "type": "register",
    "agent_id": "my_python_operator",
    "capabilities": ["transform"]
}))

# Listen for requests
while True:
    msg = json.loads(ws.recv())
    if msg["type"] == "transform":
        signal = msg["signal"]
        # Transform the signal...
        signal["values"]["spark_lord"] += 0.1
        ws.send(json.dumps({
            "type": "transform_result",
            "request_id": msg["request_id"],
            "signal": signal
        }))
```

## Step Types

| Type | Fields | Description |
|------|--------|-------------|
| `source` | `name`, `pattern` (optional) | Initialize signal with pattern |
| `bash` | `script` | Run bash script operator |
| `remote` | `agent` | Call remote WebSocket agent |
| `commit` | — | Transition from plan to resolve space |
| `emit` | — | Finalize spell |

## Development

```bash
# Run tests
mix test

# Interactive console
iex -S mix
```

## License

MIT
