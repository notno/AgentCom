# External Integrations

**Analysis Date:** 2026-02-09

## APIs & External Services

**Agent Communication:**
- WebSocket connections - Agents connect to `ws://localhost:4000/ws` via WebSocket protocol
  - Defined in `C:\Users\nrosq\src\AgentCom\lib\agent_com\endpoint.ex` line 410-413
  - Handled by `C:\Users\nrosq\src\AgentCom\lib\agent_com\socket.ex`
  - Protocol: JSON message format with message types: `identify`, `message`, `status`, `list_agents`, `ping`

**HTTP Endpoints:**
- RESTful HTTP API for message sending, agent listing, polling, and administration
- Endpoints defined in `C:\Users\nrosq\src\AgentCom\lib\agent_com\endpoint.ex` (lines 36-474)
- All endpoints require authentication via bearer token in Authorization header or query parameter

## Data Storage

**Local Persistence (No External Database):**
- All data is stored locally using DETS (Disk-based ETS) on the host filesystem
- No external database service integration
- Token storage: `priv/tokens.json` (JSON file)
  - Managed by `C:\Users\nrosq\src\AgentCom\lib\agent_com\auth.ex` lines 84-97

**Data Storage Locations:**
- Configuration: `~/.agentcom/data/config.dets` (see `C:\Users\nrosq\src\AgentCom\lib\agent_com\config.ex` line 33)
- Mailbox: `priv/mailbox.dets` (see `C:\Users\nrosq\src\AgentCom\lib\agent_com\mailbox.ex` line 24)
- Channels: `priv/channels.dets` and `priv/channel_history.dets` (see `C:\Users\nrosq\src\AgentCom\lib\agent_com\channels.ex` lines 32-33)
- Message history: In-memory with DETS backing (see `C:\Users\nrosq\src\AgentCom\lib\agent_com\message_history.ex`)

**File Storage:**
- Local filesystem only - no cloud storage integration
- All files stored relative to application home directory

**Caching:**
- In-memory state via GenServer processes
- No external cache service (Redis, Memcached, etc.)

## Authentication & Identity

**Token-Based Auth:**
- Custom token implementation (32-byte hex strings)
- Stored in `priv/tokens.json` and managed by `C:\Users\nrosq\src\AgentCom\lib\agent_com\auth.ex`
- Tokens are 1:1 mapped to `agent_id` values

**Auth Flow:**
1. Token generated via POST `/admin/tokens` with `agent_id`
2. Token provided in WebSocket `identify` message or HTTP Authorization header
3. Verified by `AgentCom.Auth.verify/1` at `C:\Users\nrosq\src\AgentCom\lib\agent_com\auth.ex` lines 29-31
4. Admin agents configured via `ADMIN_AGENTS` environment variable (comma-separated list) at `C:\Users\nrosq\src\AgentCom\lib\agent_com\endpoint.ex` line 420

**No External Auth Provider:**
- Does not integrate with OAuth, OIDC, SAML, JWT, or third-party identity services
- All authentication is internal and token-based

## Monitoring & Observability

**Error Tracking:**
- Not detected - No external error tracking service (Sentry, Datadog, etc.)

**Logs:**
- Standard Elixir Logger to console
- Configured in `C:\Users\nrosq\src\AgentCom\config\config.exs` lines 6-8
- Format: `$time $metadata[$level] $message\n`
- Metadata includes: `request_id`, `agent_id`

**Metrics/Telemetry:**
- Telemetry 1.3.0 library integrated (used by Bandit and Plug)
- No external monitoring service integration detected
- Analytics module exists at `C:\Users\nrosq\src\AgentCom\lib\agent_com\analytics.ex` for in-app statistics

**Health Check:**
- `GET /health` endpoint returns service status and connected agent count (see `C:\Users\nrosq\src\AgentCom\lib\agent_com\endpoint.ex` lines 36-43)

## CI/CD & Deployment

**Hosting:**
- Self-hosted only (no cloud platform integration)
- Runs as standalone Elixir/OTP application

**CI Pipeline:**
- Not detected - No GitHub Actions, GitLab CI, CircleCI, or other CI service configuration found

**Deployment:**
- Manual or custom deployment scripts required
- Application started via `mix run --no-halt`
- Port configurable via `PORT` environment variable

## Environment Configuration

**Required env vars:**
- `PORT` - Server port (optional, default 4000)
- `ADMIN_AGENTS` - Comma-separated list of agent IDs with admin privileges (optional, default empty)
- `HOME` - User home directory (standard, used for `~/.agentcom/data` storage path)

**Optional env vars:**
- Elixir-specific: `MIX_ENV` (default `dev`)

**Secrets location:**
- Tokens stored in `priv/tokens.json` (NOT encrypted; stored as plain JSON)
- No `.env` file or external secrets manager detected

## Webhooks & Callbacks

**Incoming:**
- None detected - AgentCom does not expose webhook endpoints for external systems to call

**Outgoing:**
- None detected - AgentCom does not make outbound HTTP requests to external APIs or webhook services

## Message Protocols

**WebSocket Protocol:**
- JSON-based message format
- Message types: `identify`, `message`, `status`, `list_agents`, `ping`, `pong`, `agent_joined`, `agent_left`, `status_changed`
- Defined in `C:\Users\nrosq\src\AgentCom\lib\agent_com\socket.ex` lines 7-47

**HTTP API Message Format:**
- JSON request/response bodies
- POST `/api/message` - Send direct message with fields: `payload` (required), `to` (optional), `type`, `reply_to`
- See `C:\Users\nrosq\src\AgentCom\lib\agent_com\endpoint.ex` lines 60-91

## Agent Coordination

**Pub/Sub System:**
- Phoenix PubSub 2.2.0 for real-time messaging
- Presence tracking via `C:\Users\nrosq\src\AgentCom\lib\agent_com\presence.ex`
- Automatic `agent_joined`, `agent_left`, and `status_changed` events

**Channel System:**
- Topic-based messaging via channels (e.g., `#agentcom-dev`, `#research`)
- Agents subscribe to channels and receive messages via WebSocket or polling
- Persistent message history (200 messages per channel by default)
- Implemented in `C:\Users\nrosq\src\AgentCom\lib\agent_com\channels.ex`

**Message Routing:**
- Router at `C:\Users\nrosq\src\AgentCom\lib\agent_com\router.ex` handles message delivery
- Messages can be direct (agent-to-agent) or broadcast (channel)
- Offline messages queued in mailbox with 7-day TTL

---

*Integration audit: 2026-02-09*
