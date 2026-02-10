# Technology Stack

**Analysis Date:** 2026-02-09

## Languages

**Primary:**
- Elixir 1.14+ - All backend code for message hub, WebSocket server, and agent coordination

**Secondary:**
- JavaScript (minimal) - `ws` package for WebSocket connectivity (`package.json`)

## Runtime

**Environment:**
- Erlang/OTP (BEAM VM) - Required for running Elixir applications

**Package Manager:**
- Mix - Elixir's build and dependency manager
- npm - Node.js package manager for lightweight JavaScript dependencies

**Lockfile:**
- `mix.lock` - Elixir dependency lock file (checked in)
- `package-lock.json` - npm dependency lock file

## Frameworks

**Core:**
- Bandit 1.10.2 - HTTP and WebSocket server; handles all incoming connections at `C:\Users\nrosq\src\AgentCom\lib\agent_com\application.ex` line 24
- Plug 1.19.1 - Web framework for routing and middleware; used in `C:\Users\nrosq\src\AgentCom\lib\agent_com\endpoint.ex` for request handling
- Phoenix PubSub 2.2.0 - Pub/Sub messaging for real-time agent presence and message broadcasting; initialized in `C:\Users\nrosq\src\AgentCom\lib\agent_com\application.ex` line 13

**WebSocket:**
- WebSock 0.5.3 - WebSocket abstraction layer for handling agent connections
- WebSock Adapter 0.5.9 - Integrates WebSocket into Plug/Bandit stack at `C:\Users\nrosq\src\AgentCom\lib\agent_com\endpoint.ex` line 412

**Data Serialization:**
- Jason 1.4.4 - JSON encoder/decoder used throughout for API responses and message payloads

## Key Dependencies

**Critical:**
- Bandit 1.10.2 - HTTP server. Without it, no agent connections possible
- Phoenix PubSub 2.2.0 - Powers real-time agent discovery and messaging. Core to agent coordination
- Jason 1.4.4 - All JSON parsing/encoding; application will fail without it

**Infrastructure:**
- Thousand Island 1.4.3 - Low-level HTTP/TCP handling; dependency of Bandit
- Telemetry 1.3.0 - Metrics and observability; used by Bandit and Plug for monitoring
- Plug Crypto 2.1.1 - Cryptographic operations; used for token generation at `C:\Users\nrosq\src\AgentCom\lib\agent_com\auth.ex` line 60
- MIME 2.0.7 - Content-type handling for HTTP responses
- HPAX 1.0.3 - HTTP header parsing; Bandit dependency
- ws 8.19.0 - Node.js WebSocket client library (minimal dependency, likely for testing or client SDKs)

## Configuration

**Environment:**
- Port: Configurable via `PORT` environment variable at `C:\Users\nrosq\src\AgentCom\config\config.exs` line 4 (default 4000)
- Logger: Standard Elixir logger with console output; configured in `C:\Users\nrosq\src\AgentCom\config\config.exs` lines 6-8

**Build:**
- Configuration file: `C:\Users\nrosq\src\AgentCom\config\config.exs`
- Mix project file: `C:\Users\nrosq\src\AgentCom\mix.exs` defines project metadata and dependencies

**Aliases:**
- `mix setup` - Runs `mix deps.get` to fetch dependencies

## Storage

**Data Persistence:**
- DETS (Disk-based ETS) - Used for persistent key-value storage across restarts:
  - Agent tokens: `priv/tokens.json` - In-memory map with JSON file backup; see `C:\Users\nrosq\src\AgentCom\lib\agent_com\auth.ex`
  - Configuration: DETS table at `~/.agentcom/data/config.dets`; see `C:\Users\nrosq\src\AgentCom\lib\agent_com\config.ex` lines 33-35
  - Mailbox: DETS table at `priv/mailbox.dets` with 7-day TTL; see `C:\Users\nrosq\src\AgentCom\lib\agent_com\mailbox.ex` lines 26-30
  - Channels: DETS tables at `priv/channels.dets` and `priv/channel_history.dets`; see `C:\Users\nrosq\src\AgentCom\lib\agent_com\channels.ex` lines 32-37

**In-Memory State:**
- Registry (Elixir built-in) - Tracks connected agents by `agent_id`; initialized in `C:\Users\nrosq\src\AgentCom\lib\agent_com\application.ex` line 14
- GenServer processes - Each major module (Auth, Config, Mailbox, Channels, etc.) runs as a supervised GenServer

## Platform Requirements

**Development:**
- Elixir 1.14 or higher
- OTP/Erlang runtime
- Mix package manager
- Node.js (optional, for npm WebSocket client)

**Production:**
- Erlang/OTP runtime
- Sufficient disk space for DETS files (tokens, mailbox, channels)
- Network access for agent connections via HTTP and WebSocket (default port 4000)

## Entry Points

**HTTP Server:**
- Bandit HTTP server started in `C:\Users\nrosq\src\AgentCom\lib\agent_com\application.ex` line 24
- Listening on configurable port (default 4000)

**Application Supervision:**
- OTP Application defined in `C:\Users\nrosq\src\AgentCom\lib\agent_com\application.ex`
- Main supervisor tree starts all genserver modules and HTTP server

---

*Stack analysis: 2026-02-09*
