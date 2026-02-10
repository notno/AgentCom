# Testing Patterns

**Analysis Date:** 2026-02-09

## Current Testing Status

**Test Framework:** Not detected
**Test Files:** None found in codebase
**Test Configuration:** No `mix.exs` test configuration (no `:ex_unit` dependency)

**Status:** This is a production codebase without automated tests. Testing relies on manual integration testing via provided scripts.

## Manual Testing Infrastructure

The codebase provides JavaScript client scripts for manual testing of WebSocket and HTTP endpoints:

**Location:** `scripts/` directory

**Available Test Scripts:**

- `scripts/connect.js` — Generic WebSocket client for agent connection testing
- `scripts/send.js` — Send HTTP messages to the hub
- `scripts/poll.js` — Poll the mailbox endpoint
- `scripts/v1-examples/` — Legacy v1 example scripts

**Running Tests:**

```bash
# Start the hub
mix ecto.create  # if needed
mix run --no-halt

# In another terminal, test WebSocket connection
AGENT_ID=test-agent AGENT_TOKEN=<token> node scripts/connect.js

# Test HTTP message send
node scripts/send.js <recipient> "message text"

# Poll mailbox
node scripts/poll.js
```

## Test Script Structure

**Example: `scripts/connect.js`**

```javascript
const WebSocket = require('ws');

const AGENT_ID = process.env.AGENT_ID;
const AGENT_TOKEN = process.env.AGENT_TOKEN;
const HUB_URL = process.env.HUB_URL || 'ws://localhost:4000/ws';

// Environment-driven configuration
// Stdin-based interaction possible, but scripts are typically event-driven

ws.on('open', () => {
  ws.send(JSON.stringify({
    type: 'identify',
    agent_id: AGENT_ID,
    token: AGENT_TOKEN,
    name: AGENT_NAME,
    capabilities: [...],
  }));
});

ws.on('message', (data) => {
  const msg = JSON.parse(data);
  // Log and parse by message type
  if (msg.type === 'identified') { ... }
  if (msg.type === 'message') { ... }
});
```

**Pattern:** Environment variables for configuration, event-driven message handling, console logging for validation

## Testing Approach (Recommended)

**For WebSocket features:**
- Use `scripts/connect.js` to establish agent connections
- Send messages via WebSocket and HTTP endpoints in parallel
- Verify presence updates, message delivery, channel subscriptions
- Monitor stdout/stderr for errors or unexpected behavior

**For HTTP endpoints:**
- Use `curl` or `scripts/send.js` for manual endpoint testing
- Token-based auth requires generating tokens via admin endpoint first
- Test mailbox polling with `?since=` cursor parameter

**For GenServer state:**
- Use `:sys.get_state(GenServer.name)` in `iex` to inspect live state
- Test handler functions directly in `iex`

**For DETS persistence:**
- Verify `.dets` files created in `priv/` or `~/.agentcom/data/`
- Test state recovery after restart

## Areas Without Test Coverage

**High-risk untested code:**
- `AgentCom.Mailbox` — Cursor-based pagination, TTL eviction, trimming logic
- `AgentCom.Channels` — Channel creation, subscription, message distribution, history
- `AgentCom.Threads` — Tree walking (recursive), root finding, reply indexing
- `AgentCom.Analytics` — Hourly bucketing, status classification, counter management
- `AgentCom.Auth` — Token generation, revocation, persistence
- `AgentCom.Endpoint` — HTTP routes, error handling, content negotiation
- `AgentCom.Socket` — WebSocket protocol, state transitions, presence syncing
- Message routing logic in `AgentCom.Router` — broadcast vs. direct delivery

**Edge cases not verified:**
- Network failures during message delivery
- Concurrent operations on same agent/channel
- Clock skew or time-based operations
- Large message payloads or many agents
- File I/O failures (DETS corruption, permission errors)
- GenServer crash and recovery

## Recommended Testing Strategy

**Unit Test Level (if implemented):**
- Message struct creation and JSON conversion: `AgentCom.Message.new()`, `to_json()`, `from_json()`
- Token generation and verification: `AgentCom.Auth.generate()`, `verify()`
- Channel normalization: `AgentCom.Channels.normalize_name()`
- Analytics classification: `classify_status(connected, idle_ms)`
- Thread tree operations: `walk_to_root()`, `collect_tree()`

**Integration Test Level (recommended):**
- GenServer state initialization and persistence
- Message routing (direct, broadcast, offline queueing)
- WebSocket lifecycle (identify, message send/receive, disconnect)
- HTTP endpoints with token auth
- Channel operations (create, subscribe, publish, history)
- Thread retrieval across reply chains

**System Test Level:**
- Multi-agent conversations
- Channel message distribution (real-time + polling)
- Mailbox cursor-based pagination
- Analytics accumulation across time buckets
- Admin operations (reset hub, revoke tokens)
- Presence tracking across connect/disconnect cycles

## Data Persistence Testing

**DETS Tables:** Verify persistence and recovery of:
- `agent_mailbox` — Message queue entries with sequence numbers
- `agent_channels` — Channel metadata and subscriber lists
- `channel_history` — Per-channel message history with limits
- `thread_messages` — All indexed messages
- `thread_replies` — Reply graphs
- `agentcom_config` — Configuration key-value pairs

**Token Storage:** `priv/tokens.json` — Readable JSON, verify token-to-agent-id mapping

**Recovery Testing:** Delete DETS files and restart — verify clean state initialization

## Mocking Considerations

**If implementing tests:**

**What to Mock:**
- External WebSocket connections (in endpoint tests)
- System.system_time() calls (for deterministic time-based tests)
- File I/O for DETS files (to test state without persistence)
- Network I/O if testing router logic in isolation

**What NOT to Mock:**
- GenServer processes (test actual message passing)
- DETS operations (these are critical; test with real DETS)
- Phoenix.PubSub (test actual pub/sub behavior)
- Message struct operations (test conversion logic thoroughly)

**Mocking Pattern (if using ExUnit):**
```elixir
defmodule AgentComTest do
  use ExUnit.Case

  setup do
    # Start required applications
    {:ok, _} = Application.ensure_all_started(:agent_com)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    :ok
  end

  test "message routing to connected agent" do
    # Real GenServer, real Registry, test message delivery
    {:ok, agent_pid} = start_agent("test-agent")
    msg = AgentCom.Message.new(%{from: "sender", to: "test-agent", payload: %{}})

    {:ok, :delivered} = AgentCom.Router.route(msg)

    assert_receive {:message, ^msg}
  end
end
```

## Documentation for Testing

**Test Data Generators (if needed):**
- Agent ID factory: random string, alphanumeric + hyphens
- Message factory: required fields (:from, :type, :payload) + optional (:to, :reply_to)
- Token factory: 32-byte hex string
- Channel factory: normalized names, subscriber lists

**Fixtures (if needed):**
- Sample agents: `test-agent-1`, `test-agent-2`, `admin-agent`
- Sample tokens: pre-generated for testing
- Sample channels: `#dev`, `#general`, `#testing`

## Continuous Integration

**Current State:** No CI pipeline configured

**If CI were added:**
- Would need to add ExUnit tests to `test/` directory
- Update `mix.exs` with test dependencies
- Configure GitHub Actions or similar to run `mix test`
- Could reuse existing scripts for integration tests

---

*Testing analysis: 2026-02-09*
