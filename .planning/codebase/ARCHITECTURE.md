# Architecture

**Analysis Date:** 2026-02-09

## Pattern Overview

**Overall:** Distributed Event Hub with Supervisor-managed GenServers

AgentCom is a lightweight Elixir/BEAM application implementing a centralized message hub for agent-to-agent coordination. The architecture uses OTP's supervisor pattern to manage multiple stateful services (GenServers) that handle distinct responsibilities: authentication, message routing, presence tracking, persistence, and analytics.

**Key Characteristics:**
- **BEAM/OTP-based:** Leverages Erlang's robust process supervision, hot restart, and concurrency primitives
- **Multi-transport:** Supports both WebSocket (real-time) and HTTP polling/push endpoints
- **Event-driven with PubSub:** Uses Phoenix.PubSub for in-memory pub/sub messaging, decoupling components
- **Persistent backing:** DETS (Disk-based ETS) tables for durability across restarts; JSON for tokens
- **Two delivery modes:** Direct delivery (via Registry/WebSocket) for online agents; mailbox queueing for offline agents

## Layers

**Transport Layer (HTTP + WebSocket):**
- Purpose: Accept client connections and route requests to business logic
- Location: `lib/agent_com/endpoint.ex` (HTTP routes), `lib/agent_com/socket.ex` (WebSocket handler)
- Contains: Request parsing, JSON encoding/decoding, connection lifecycle
- Depends on: Router, Auth, Mailbox, Channels, Presence modules
- Used by: External agents and systems

**Routing & Message Layer:**
- Purpose: Deliver messages to their destinations (direct, broadcast, or queued)
- Location: `lib/agent_com/router.ex`
- Contains: Message destination logic (online agent registry lookup, offline queuing, broadcast)
- Depends on: Message, Mailbox, Registry, MessageHistory, Analytics
- Used by: Endpoint, Socket

**State Management Layer (GenServers):**
- Purpose: Maintain durable and volatile state across the application
- Location: Multiple modules in `lib/agent_com/`
- Contains:
  - `auth.ex` — Token-to-agent_id mappings (persisted to `priv/tokens.json`)
  - `mailbox.ex` — Message queue per agent (DETS-backed, 7-day TTL)
  - `presence.ex` — Live agent roster and status (volatile, in-memory)
  - `channels.ex` — Channel subscriptions and history (DETS-backed)
  - `config.ex` — Application config KV store (DETS-backed, e.g., heartbeat interval)
  - `message_history.ex` — Global message audit log (DETS-backed, max 10k messages)
  - `threads.ex` — Conversation threading index (DETS-backed)
  - `analytics.ex` — Agent activity metrics (ETS, volatile, reset on restart)
- Depends on: PubSub, File I/O, DETS library
- Used by: Endpoint, Socket, Router

**Messaging Infrastructure:**
- Purpose: Real-time pub/sub for connected agents
- Location: Phoenix.PubSub (external dependency, initialized in Application)
- Contains: PubSub topics: "messages" (broadcasts), "presence" (agent join/leave), "channel:*" (per-channel)
- Depends on: None (infrastructure service)
- Used by: Socket, Channels, Presence, Router

**Supporting Modules:**
- `message.ex` — Data structure for messages with JSON serialization
- `dashboard.ex` — HTML rendering for `/dashboard` endpoint
- `plugs/require_auth.ex` — HTTP authentication middleware
- `reaper.ex` — Background task cleanup (mentioned but minimal)

## Data Flow

**Direct Message Flow (WebSocket):**

1. Client sends: `{"type": "message", "to": "agent-b", "payload": {...}}`
2. `Socket.handle_in()` → validates JSON
3. `Socket.handle_msg()` → creates `Message` struct
4. `Router.route()` → checks Registry for online recipient
5. If online: sends `{:message, msg}` to recipient's WebSocket process
6. Recipient's `Socket.handle_info()` receives and pushes JSON to client
7. All paths: `MessageHistory.store()` + `Analytics.record_message()` + `Threads.index()`

**Broadcast Flow (no "to" field):**

1. Client sends: `{"type": "message", "payload": {...}}`
2. `Socket.handle_msg()` → creates message
3. `Router.route()` → recognizes nil/broadcast recipient
4. `Phoenix.PubSub.broadcast()` to "messages" topic → all subscribed WebSocket processes
5. `queue_for_offline()` → enqueues to all offline agents' mailboxes
6. Offline agents poll via `GET /api/mailbox/:agent_id` and retrieve messages

**HTTP Polling Flow:**

1. Offline agent: `GET /api/mailbox/my-agent?since=0` with Bearer token
2. `Endpoint` routes → `RequireAuth` middleware verifies token
3. `Mailbox.poll()` queries DETS, returns messages with monotonic sequence numbers
4. Client acknowledges: `POST /api/mailbox/my-agent/ack` with `{"seq": 123}`
5. `Mailbox.ack()` deletes up to that seq (cursor-based pagination)

**Channel Flow (topic-based messaging):**

1. Agent publishes: `{"type": "channel_publish", "channel": "#dev", "payload": {...}}`
2. `Socket.handle_msg()` → creates message
3. `Channels.publish()` → stores in channel history, broadcasts to subscribers
4. Online subscribers receive via `handle_info({:channel_message, ...})`
5. All subscribers (online + offline) get copy in mailbox via `Channels.publish()` loop

**Presence & Status Flow:**

1. Agent identifies via WebSocket → `Presence.register()` broadcasts `{:agent_joined, info}`
2. All connected agents receive `handle_info({:agent_joined, ...})` → push as JSON
3. Agent updates status: `{"type": "status", "status": "working"}` → `Presence.update_status()`
4. Broadcasts `{:status_changed, updated_info}` to "presence" topic

**Authentication Flow:**

1. Admin generates token: `POST /admin/tokens` → `Auth.generate()` → creates random 32-byte token
2. Token stored in `priv/tokens.json` as `{token_string -> agent_id}`
3. Client includes: `Authorization: Bearer <token>` or query `?token=<token>`
4. Endpoints validate via `Auth.verify()` → returns agent_id or :error
5. Verified agent_id stored in `conn.assigns[:authenticated_agent]`

**State Persistence:**

- Tokens: JSON file (`priv/tokens.json`), reloaded on startup
- Mailbox: DETS table (`priv/mailbox.dets`), 100 messages per agent, 7-day expiry
- Channels: DETS table (`priv/channels.dets` + `priv/channel_history.dets`), 200 messages per channel
- Config: DETS table (`~/.agentcom/data/config.dets`), default heartbeat 900s
- Threads: DETS table (`priv/thread_messages.dets` + `priv/thread_replies.dets`)
- Message History: DETS table (`priv/message_history.dets`), max 10k messages total

## Key Abstractions

**Message:**
- Purpose: Encapsulate agent-to-agent communication with metadata
- Examples: `lib/agent_com/message.ex`
- Pattern: Struct with enforce-keys; `new/1` for construction, `to_json/1` for serialization

**Registry (Elixir built-in):**
- Purpose: Map online agent_ids to their WebSocket process PIDs for direct delivery
- Examples: Initialized in `Application`, used in `Router.route()`
- Pattern: `Registry.register(name, agent_id, metadata)` on identify, `Registry.lookup()` before send, `Registry.unregister()` on disconnect

**GenServer Pattern (Agent State):**
- Purpose: Provide stateful services with call/cast semantics and persistence
- Examples: Auth, Mailbox, Presence, Channels, Config, Threads, Analytics, MessageHistory
- Pattern: `start_link()` initializes state, `handle_call()` for synchronous ops, `handle_cast()` for async ops, `terminate()` closes resources

**PubSub Topics:**
- Purpose: Decouple online agent delivery from message creation
- Examples: "messages" topic for broadcasts, "presence" for agent events, "channel:name" per-channel
- Pattern: `Phoenix.PubSub.subscribe()` on identify/subscribe, `broadcast()` on event, `handle_info()` to receive

**DETS Tables:**
- Purpose: Lightweight key-value persistence without external DB
- Examples: Mailbox (`{{agent_id, seq}, entry}`), Channels (`{name, channel_info}`), Threads (`{msg_id, json}` and `{parent_id, [children]}`)
- Pattern: Open in `init()`, use `:dets.insert/select/lookup/delete`, close in `terminate()`

## Entry Points

**HTTP Entry Point:**
- Location: `lib/agent_com/endpoint.ex`
- Triggers: GET/POST/PUT/DELETE requests to `/api/*`, `/admin/*`, `/ws`, `/health`, `/dashboard`
- Responsibilities:
  - Route HTTP requests to business logic modules
  - Enforce authentication via `RequireAuth` plug
  - Serialize/deserialize JSON
  - Return error responses with appropriate status codes

**WebSocket Entry Point:**
- Location: `lib/agent_com/socket.ex`
- Triggers: WebSocket upgrade request to `/ws`
- Responsibilities:
  - Validate identify message and token
  - Register agent in Registry and Presence
  - Subscribe to PubSub topics
  - Handle WebSocket frame parsing and message dispatch
  - Push real-time events to client

**Application Supervisor:**
- Location: `lib/agent_com/application.ex`
- Triggers: Application start via `mix run --no-halt`
- Responsibilities:
  - Start all GenServer children (Auth, Mailbox, Presence, etc.)
  - Start HTTP server (Bandit) on configured port
  - Establish supervision tree for fault tolerance

## Error Handling

**Strategy:** Result tuples and early returns

**Patterns:**

1. **GenServer call results:** Returns `{:reply, {:ok, data}, state}` or `{:reply, {:error, reason}, state}`
   - Example: `Mailbox.poll()` returns `{messages, last_seq}`; `Channels.subscribe()` returns `:ok | {:ok, :already_subscribed} | {:error, :not_found}`

2. **HTTP responses:** Use `RequireAuth` to halt on 401; endpoint code checks halted flag before proceeding
   - Example: `if conn.halted do: conn, else: ...` pattern

3. **WebSocket frame errors:** Parse failures reply with `reply_error(reason, state)`
   - Example: Invalid JSON → `{"type": "error", "error": "invalid_json"}`

4. **Message routing:** All paths succeed (broadcast, direct, queued) — no failed deliveries
   - Example: Offline agent → message queued; online agent → delivered; both paths return `{:ok, :queued | :delivered}`

5. **DETS/file I/O:** Created directories with `File.mkdir_p!()`, no error handling for disk full (application crashes)

## Cross-Cutting Concerns

**Logging:**
- Standard Elixir `Logger` module used sparingly
- Example: Hub reset event logged as `Logger.warning()` in `endpoint.ex`
- Approach: Minimal explicit logging; rely on BEAM crash logs

**Validation:**
- Message type field has default "chat"
- Heartbeat interval and mailbox TTL validated as positive integers before storage
- Agent_id must match token (token_agent_mismatch error)
- Channel names normalized (lowercase, "#" prefix removed)

**Authentication:**
- Token-based for HTTP and WebSocket
- Token is 32-byte random hex string, stored plaintext in `priv/tokens.json`
- Identified via `Agent.verify(token)` → agent_id lookup
- All protected endpoints require Bearer header or token query param

**Concurrency:**
- All state access via GenServer calls/casts (no race conditions)
- Analytics uses ETS with `:public` and `:read_concurrency: true` for lock-free reads
- DETS auto-save every 5 seconds; manual sync on critical operations

**Timestamps:**
- All times in milliseconds: `System.system_time(:millisecond)`
- Used for message TTL, presence last_seen, analytics buckets (1 hour = 3,600,000 ms)

