# Coding Conventions

**Analysis Date:** 2026-02-09

## Naming Patterns

**Modules:**
- Use PascalCase for module names: `AgentCom.Message`, `AgentCom.Mailbox`, `AgentCom.Socket`
- Nested modules reflect directory structure: `lib/agent_com/plugs/require_auth.ex` → `AgentCom.Plugs.RequireAuth`
- Private helper modules can omit the `AgentCom` prefix for internal utilities

**Functions:**
- Use snake_case for all function names: `generate_id()`, `verify_token()`, `get_thread()`
- Prefix private functions with `defp`: `defp recover_seq()`, `defp do_evict_expired()`, `defp normalize()`
- Public API functions use `def` and start with action verbs: `enqueue()`, `poll()`, `register()`, `create()`
- Helper functions at module end prefixed with `defp`

**Variables:**
- Use snake_case: `agent_id`, `message_id`, `current_bucket`, `overflow`
- Pattern match directly in function heads when possible: `def init(_opts)`, `def handle_call({:verify, token}, _from, state)`
- Use descriptive names in loops and comprehensions: `Enum.map(agents, fn agent_id ->`

**Types and Structs:**
- Atom keys in maps (when values are known): `%{agent_id: id, name: name}`
- String keys in JSON operations: `%{"type" => "message", "payload" => payload}`
- Struct fields match snake_case convention: `%Message{id:, from:, to:, type:, payload:}`

## Code Style

**Formatting:**
- No explicit formatter configured (Elixir defaults)
- Use standard Elixir formatting: 2-space indentation
- Keep lines reasonable length, break at logical points
- Use pipe operator `|>` for transformation chains

**Pattern Matching:**
- Prefer pattern matching in function heads over if-statements: See `AgentCom.Router.route/1` with three clauses for different `to:` patterns
- Use case statements for complex control flow: `case Registry.lookup(AgentCom.AgentRegistry, to) do`
- Guard clauses for type checking: `when is_integer(ms) and ms > 0`, `when is_atom(key)`

**Error Handling:**
- Use tuple returns `{:ok, result}` and `{:error, reason}` pattern consistently
- Pattern match on error tuples: `case AgentCom.Auth.verify(token) do {:ok, agent_id} -> ...; :error -> ...`
- Return `:ok` for side-effect-only operations: `AgentCom.Mailbox.ack()` returns `:ok`
- Use atoms for specific errors: `:not_found`, `:exists`, `:already_subscribed`

**Logging:**
- Use `require Logger` when needed and `Logger.warning()` for important events
- Log important state changes, e.g., in endpoint for admin resets
- Metadata configured in `config/config.exs`: includes `:agent_id` for context

## Import Organization

**Order:**
1. Module declaration (`defmodule`)
2. Moduledoc (`@moduledoc`)
3. Behavior/use declarations (`use GenServer`, `@behaviour WebSock`)
4. Aliases and imports: `alias AgentCom.{Message, Mailbox, Router}`
5. Module attributes (`@table`, `@defaults`, `@max_messages_per_agent`)

**Examples from codebase:**
- `AgentCom.Socket`: `use GenServer` → `alias` → `defstruct`
- `AgentCom.Mailbox`: `use GenServer` → module attributes → function definitions
- `AgentCom.Endpoint`: `use Plug.Router` → plug directives → routes

**Path Aliases:**
- No explicit path aliases used in this codebase
- Full module paths preferred: `AgentCom.Message`, `AgentCom.Mailbox`

## Comments and Documentation

**When to Comment:**
- Every public module gets a `@moduledoc` explaining its purpose and key concepts
- Complex algorithms need inline comments: See `AgentCom.Threads.collect_tree/1` explanation of tree walking
- Non-obvious logic needs explanation: `# Store message for offline agents`, `# Subscribe to broadcasts and presence`
- Avoid comments that just repeat the code

**Moduledoc Format:**
- Describe purpose and responsibility in first lines
- Include data structures being managed: `"Stores settings as key-value pairs persisted across restarts"`
- Document APIs and protocols where relevant: `AgentCom.Socket` includes full WebSocket protocol specification
- Multi-line descriptions use markdown

**Function Documentation:**
- Public functions get `@doc` strings: `@doc "Send a message to its destination."`
- Document parameter types and return values in docstrings
- Include examples where behavior isn't obvious
- Private functions (`defp`) may have inline comments but no `@doc`

**Example from `AgentCom.Mailbox`:**
```elixir
@moduledoc """
Message queue for offline or polling agents.

Messages are stored per-agent and retrieved via HTTP poll.
Each message gets a monotonic sequence number for cursor-based pagination.

Backed by DETS (disk-based ETS) for persistence across restarts.
Stored at `priv/mailbox.dets` by default.
"""

@doc """
Store a message for an agent. Called by Router when the target
agent is offline or has opted into polling mode.
"""
def enqueue(agent_id, %AgentCom.Message{} = msg) do
```

## Function Design

**Size Guidelines:**
- Public API functions typically 2-10 lines (delegate to GenServer)
- Handler functions (`handle_call`, `handle_cast`) 5-30 lines (encapsulate one operation)
- Helper functions 5-15 lines (maintain readability)
- Longer logic broken into multiple helpers: See `AgentCom.Channels.publish/2` delegates to `store_history/2`, `trim_history/1`

**Parameters:**
- GenServer calls use single tuple as argument: `def enqueue(agent_id, %AgentCom.Message{} = msg)`
- HTTP handlers use pattern matched maps: `def handle_call({:enqueue, agent_id, msg}, _from, state)`
- Optional parameters use default values: `def history(channel, opts \\ [])`
- Guard types in signatures: `def put(key, value) when is_atom(key)`

**Return Values:**
- GenServer returns: `{:reply, result, state}`, `{:noreply, state}`
- WebSocket returns: `{:push, {:text, json}, state}`, `{:ok, state}`
- Public APIs return: `{:ok, value}`, `{:error, reason}`, or `:ok`
- Tuples for multi-value returns: `{messages, last_seq}`

## Module Design

**Exports:**
- No explicit `defdelegate` used; all functions exported by default
- Private functions use `defp` prefix (Elixir standard)
- State management via GenServer calls/casts

**Barrel Files:**
- No barrel file pattern used (no `lib/agent_com.ex`)
- Each module is imported directly: `alias AgentCom.{Message, Mailbox}`

**Pattern: GenServer Modules**
Most business logic modules follow GenServer pattern:
- `start_link(opts)` — starts the supervised process
- `init(opts)` — initializes state and resources (DETS files, ETS tables)
- Public API functions (`def`) — delegate to GenServer calls/casts
- Handler functions (`handle_call`, `handle_cast`, `handle_info`) — business logic
- Private helpers (`defp`) — support functions

Example from `AgentCom.Auth`:
```elixir
def start_link(opts) do
  GenServer.start_link(__MODULE__, opts, name: __MODULE__)
end

def verify(token) do
  GenServer.call(__MODULE__, {:verify, token})
end

@impl true
def handle_call({:verify, token}, _from, state) do
  result = case Map.get(state.tokens, token) do
    nil -> :error
    agent_id -> {:ok, agent_id}
  end
  {:reply, result, state}
end
```

**Pattern: Plug Modules**
HTTP request handlers use Plug.Router convention:
- `use Plug.Router` — declares router behavior
- Plug middleware in order: logger, match, parsers, dispatch
- Route handlers use pattern matching on HTTP method and path
- Return responses via `send_json(conn, status, data)` helper

Example from `AgentCom.Endpoint`:
```elixir
use Plug.Router

plug Plug.Logger
plug :match
plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
plug :dispatch

get "/health" do
  send_json(conn, 200, %{"status" => "ok"})
end

defp send_json(conn, status, data) do
  conn
  |> put_resp_content_type("application/json")
  |> send_resp(status, Jason.encode!(data))
end
```

**Pattern: WebSocket Handler**
WebSocket modules implement `WebSock` behavior:
- `init(opts)` — initialize connection state
- `handle_in({text, [opcode: :text]}, state)` — incoming messages
- `handle_info(msg, state)` — internal messages (PubSub broadcasts)
- Return `{:push, {:text, json}, state}` to send, `{:ok, state}` to continue

Example from `AgentCom.Socket`:
```elixir
@behaviour WebSock

def init(_opts) do
  {:ok, %__MODULE__{agent_id: nil, identified: false}}
end

def handle_in({text, [opcode: :text]}, state) do
  case Jason.decode(text) do
    {:ok, msg} -> handle_msg(msg, state)
    {:error, _} -> reply_error("invalid_json", state)
  end
end

def handle_info({:message, %Message{} = msg}, state) do
  push = %{"type" => "message", "id" => msg.id, ...}
  {:push, {:text, Jason.encode!(push)}, state}
end
```

## Message JSON Format

**Internal Message Struct:**
- Uses atoms for keys: `:from`, `:to`, `:type`, `:payload`, `:reply_to`, `:id`, `:timestamp`
- Created via `AgentCom.Message.new(attrs)` or `from_json(map)`

**External JSON Format (HTTP/WebSocket):**
- Uses string keys: `"type"`, `"from"`, `"to"`, `"payload"`, `"reply_to"`, `"id"`, `"timestamp"`
- Conversion via `AgentCom.Message.to_json/1` and `from_json/1`
- Message types: `"chat"`, `"request"`, `"response"`, `"status"`, `"ping"` (documented in `AgentCom.Message`)

---

*Convention analysis: 2026-02-09*
