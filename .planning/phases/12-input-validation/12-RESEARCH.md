# Phase 12: Input Validation - Research

**Researched:** 2026-02-11
**Domain:** Schema validation for WebSocket and HTTP entry points in Elixir/BEAM hub
**Confidence:** HIGH

## Summary

Phase 12 adds schema validation at every external entry point: the WebSocket handler (`AgentCom.Socket`) and the HTTP endpoint (`AgentCom.Endpoint`). The system currently has no systematic input validation -- WebSocket messages are pattern-matched by `"type"` field and any malformed payload either crashes the GenServer or silently produces incorrect state. HTTP endpoints do ad-hoc field checking (e.g., `%{"description" => description}` pattern match) with no type enforcement, length limits, or field-level error reporting.

The core deliverable is a single `AgentCom.Validation` module that defines schemas for every message type and HTTP request body, validates incoming data against those schemas, and returns structured error responses with field-level detail. This module is called from both Socket and Endpoint before any business logic executes. Additionally, an escalating disconnect mechanism protects against repeat offenders (10 validation failures in 1 minute triggers disconnect with exponential backoff), a schema discovery endpoint (`GET /api/schemas`) enables agent introspection, and validation error metrics are surfaced in the dashboard.

**Primary recommendation:** Build a pure-Elixir validation module using pattern matching and explicit type checks (not ex_json_schema). Define schemas as Elixir maps/structs in code. This avoids adding a dependency for what is fundamentally straightforward map validation, keeps schemas colocated with the protocol definition, and allows the schema discovery endpoint to serialize the same schema definitions to JSON for agents.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **Unknown fields: accept and pass through** -- most permissive, enables extensibility without hub changes
- **Strict types** -- string where integer expected is a validation error, no coercion
- **Schema discovery endpoint** -- GET /api/schemas returns supported message types and their schemas, so agents can introspect
- **Escalating response for repeat offenders** -- after 10 validation failures in 1 minute, temporarily disconnect the agent
- **Exponential backoff on reconnect** -- first disconnect: 30s cooldown, second: 1 min, third: 5 min. Prevents tight reconnect-fail loops
- **Dashboard visibility** -- show validation error counts per agent, recent failures, and any disconnected-for-violations agents
- Echo back offending fields in error responses so agents can debug what they sent wrong

### Claude's Discretion
- Error response JSON structure
- WebSocket error frame type
- HTTP status codes for validation failures
- Required vs optional field determination per message type
- String length limits
- Schema versioning strategy
- Schema source (code vs data files)
- Unknown message type handling

### Deferred Ideas (OUT OF SCOPE)
- Rate limiting on validation failures -- Phase 15 handles rate limiting separately, though the escalating disconnect provides basic protection
- Structured logging of validation events -- Phase 13 will add structured logging; validation can emit events that Phase 13 formats
</user_constraints>

## Discretion Recommendations

Based on analysis of the existing codebase, protocol patterns, and ecosystem conventions, here are recommendations for the discretionary areas.

### Error Response JSON Structure
**Recommendation:** Flat structure with field-level `errors` array.

```json
{
  "type": "error",
  "error": "validation_failed",
  "message_type": "task_complete",
  "errors": [
    {"field": "task_id", "error": "required", "detail": "field is required"},
    {"field": "generation", "error": "wrong_type", "detail": "expected integer, got string", "value": "abc"}
  ]
}
```

**Rationale:** The existing protocol uses `{"type": "error", "error": "reason"}` for all errors (see `reply_error/2` in socket.ex). This extends that pattern by adding an `errors` array with per-field detail. The `message_type` field tells the agent which of their messages caused the error. Including `value` for type mismatches (but not for missing fields) helps agents debug without leaking excessively.

### WebSocket Error Frame Type
**Recommendation:** Reuse existing `"error"` type with `"error": "validation_failed"`.

**Rationale:** The WebSocket protocol already has a single error type. Agents already handle `{"type": "error", ...}`. Adding a new `"validation_error"` type would require agents to handle a new message type. Instead, use the existing `"error"` type with a specific `"error"` field value of `"validation_failed"` that distinguishes validation errors from other errors. The added `errors` array provides full detail.

### HTTP Status Codes
**Recommendation:** Use 422 Unprocessable Entity for validation failures. Keep 400 for structurally unparseable requests (already returned by `Plug.Parsers` for bad JSON).

**Rationale:** 400 Bad Request is currently used for missing required fields (e.g., "missing required field: description"). 422 is more precise for "I understood your JSON, but the content is semantically invalid." This distinction helps agents differentiate between "your JSON was malformed" (400) and "your request had wrong field types/missing required fields" (422). Existing 400 responses for structurally bad input remain unchanged.

### Required vs Optional Field Determination
**Recommendation:** Determined per message type based on "would the system crash or produce incorrect state without this field?"

| Message Type | Required Fields | Optional Fields |
|---|---|---|
| `identify` | `type`, `agent_id`, `token` | `name`, `status`, `capabilities` |
| `message` | `type`, `payload` | `to`, `message_type`, `reply_to` |
| `status` | `type`, `status` | (none) |
| `list_agents` | `type` | (none) |
| `ping` | `type` | (none) |
| `channel_subscribe` | `type`, `channel` | (none) |
| `channel_unsubscribe` | `type`, `channel` | (none) |
| `channel_publish` | `type`, `channel`, `payload` | `message_type`, `reply_to` |
| `channel_history` | `type`, `channel` | `limit`, `since` |
| `list_channels` | `type` | (none) |
| `task_accepted` | `type`, `task_id` | (none) |
| `task_progress` | `type`, `task_id` | `progress` |
| `task_complete` | `type`, `task_id`, `generation` | `result`, `tokens_used` |
| `task_failed` | `type`, `task_id`, `generation` | `error`, `reason` |
| `task_recovering` | `type`, `task_id` | (none) |

**Rationale:** `generation` is required for `task_complete` and `task_failed` because the system uses generation fencing (TASK-05). Currently these default to 0 when missing, which can cause silent stale-generation rejections. Making them required surfaces the error at the validation layer instead.

### String Length Limits
**Recommendation:** Set reasonable limits only where they matter for system stability.

| Field | Max Length | Rationale |
|---|---|---|
| `agent_id` | 128 chars | Prevents abuse, used as DETS key and registry key |
| `description` (task) | 10,000 chars | Task descriptions can be substantial but not unbounded |
| `status` | 256 chars | Freeform status string, displayed in dashboard |
| `channel` name | 64 chars | Used as PubSub topic, should be reasonable |
| `token` | 256 chars | Current tokens are ~32 hex chars, generous limit |
| `error` / `reason` | 2,000 chars | Error messages displayed in dashboard |

Payload maps have no size limit (they are JSON-decoded by `Plug.Parsers` / `Jason.decode` which handles memory naturally via Bandit's body size limits).

### Schema Versioning Strategy
**Recommendation:** Evolve-in-place schemas (no versioning).

**Rationale:** The system is pre-1.0. Adding schema versioning (v1, v2 negotiation) adds complexity without value -- there is one hub and a handful of sidecars, all deployed together. The "unknown fields pass through" policy provides forward compatibility. When a genuinely breaking change occurs (unlikely given additive-only design), it can be handled by a protocol version bump in the WebSocket handshake.

### Schema Source
**Recommendation:** Define schemas as Elixir data structures in code within the `AgentCom.Validation` module.

**Rationale:** Schemas are coupled to the protocol handler logic (they define what `handle_msg/2` expects). Keeping them in Elixir code means they are version-controlled alongside the handlers, compile-checked, and testable. JSON Schema files would add indirection (load at startup, parse, resolve `$ref`), require the `ex_json_schema` dependency, and make the relationship between schema and handler implicit rather than explicit. The schema discovery endpoint (`GET /api/schemas`) serializes these Elixir data structures to JSON on demand.

### Unknown Message Type Handling
**Recommendation:** Return a validation error with type `"unknown_message_type"` listing the known types.

```json
{
  "type": "error",
  "error": "unknown_message_type",
  "received_type": "foobar",
  "known_types": ["identify", "message", "status", "list_agents", "ping", ...]
}
```

**Rationale:** The current handler has a catch-all `handle_msg(_unknown, state)` that returns `"unknown_message_type"`. This enhances it with the list of known types so agents can self-correct. This is better than silently dropping unknown messages.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir pattern matching | OTP stdlib | Schema validation logic | No dependency needed. Elixir maps + pattern matching + guards handle flat schema validation cleanly. The codebase already uses this pattern everywhere (see `handle_msg/2` pattern matching in socket.ex). |
| Jason | ~> 1.4 (existing) | JSON encoding/decoding | Already in deps. Used for error response serialization and schema discovery endpoint. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| ExJsonSchema | ~> 0.11.2 | JSON Schema validation | NOT recommended for this phase. The schemas are flat maps with simple type constraints. Hand-rolled validation in Elixir is more natural, produces better error messages, and avoids a dependency for ~15 schema definitions. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Hand-rolled validation | ex_json_schema | ex_json_schema adds a dependency, requires schemas as JSON maps, error messages are generic ("Type mismatch. Expected String but got Integer."), and schemas must be `resolve()`d at startup. For flat Elixir maps with ~5 fields each, hand-rolled is simpler and produces more actionable error messages like "field 'generation' expected integer, got string 'abc'". |
| Hand-rolled validation | Ecto changesets | Massive dependency for simple JSON validation. No database in this system. Overkill. |
| Hand-rolled validation | Vex / Skooma | Additional dependency for simple validations. These libraries are designed for struct validation, not WebSocket message validation. |

**No new dependencies needed.** The validation module uses only Elixir stdlib + Jason (already present).

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  validation.ex              # Central validation module with all schemas
  validation/
    schemas.ex               # Schema definitions (message types + HTTP bodies)
    violation_tracker.ex      # Per-agent validation failure counting + disconnect logic
  socket.ex                  # MODIFIED: calls Validation before handle_msg
  endpoint.ex                # MODIFIED: calls Validation before processing
  dashboard_state.ex         # MODIFIED: adds validation metrics to snapshot
```

### Pattern 1: Validate-Then-Dispatch
**What:** Every incoming message/request is validated before business logic executes. Validation returns either `{:ok, validated_data}` or `{:error, errors}`.
**When to use:** Every WebSocket message and HTTP request body.
**Example:**
```elixir
# In socket.ex handle_in/2 -- BEFORE dispatching to handle_msg/2
def handle_in({text, [opcode: :text]}, state) do
  case Jason.decode(text) do
    {:ok, msg} ->
      case AgentCom.Validation.validate_ws_message(msg) do
        {:ok, validated} ->
          handle_msg(validated, state)
        {:error, errors} ->
          # Track violation for escalating disconnect
          if state.identified do
            AgentCom.Validation.ViolationTracker.record(state.agent_id)
            case AgentCom.Validation.ViolationTracker.check_threshold(state.agent_id) do
              :ok -> reply_validation_error(msg, errors, state)
              :disconnect -> {:stop, :normal, {1008, "too many validation errors"}, state}
            end
          else
            reply_validation_error(msg, errors, state)
          end
      end
    {:error, _} -> reply_error("invalid_json", state)
  end
end
```

### Pattern 2: Schema-as-Data for Discovery
**What:** Schemas are defined as Elixir data structures that serve dual purpose: runtime validation AND JSON serialization for the `GET /api/schemas` endpoint.
**When to use:** Schema definitions in the Validation module.
**Example:**
```elixir
defmodule AgentCom.Validation.Schemas do
  @schemas %{
    "identify" => %{
      required: %{
        "type" => :string,
        "agent_id" => :string,
        "token" => :string
      },
      optional: %{
        "name" => :string,
        "status" => :string,
        "capabilities" => {:list, :string}
      },
      description: "First message on WebSocket connection. Authenticates the agent."
    },
    "task_complete" => %{
      required: %{
        "type" => :string,
        "task_id" => :string,
        "generation" => :integer
      },
      optional: %{
        "result" => :map,
        "tokens_used" => :integer
      },
      description: "Report task completion with result."
    }
    # ... all message types
  }

  def get(message_type), do: Map.get(@schemas, message_type)
  def all, do: @schemas

  # Serialize to JSON-friendly format for GET /api/schemas
  def to_json_schema(schema) do
    # Convert :string, :integer, :map, {:list, :string} to JSON Schema types
    ...
  end
end
```

### Pattern 3: ViolationTracker as Agent Process State
**What:** Track validation failure counts per agent in the Socket process state, not in a separate GenServer.
**When to use:** Escalating disconnect feature.
**Why:** The failure count is per-connection. When the WebSocket disconnects, the count naturally resets. No need for a separate GenServer or ETS table. The backoff cooldown tracking (how many times this agent has been disconnected) DOES need to persist across reconnections -- use an ETS table or the existing AgentFSM state for that.

```elixir
# Socket state gains validation tracking fields
defstruct [:agent_id, :identified, :violation_count, :violation_window_start]

# On each validation failure:
defp track_violation(state) do
  now = System.system_time(:millisecond)
  window_start = state.violation_window_start || now

  if now - window_start > 60_000 do
    # Reset window
    %{state | violation_count: 1, violation_window_start: now}
  else
    count = (state.violation_count || 0) + 1
    %{state | violation_count: count}
  end
end
```

### Pattern 4: Plug-Based HTTP Validation
**What:** A validation plug or inline validation call that validates HTTP request bodies before processing.
**When to use:** Every POST/PUT endpoint in endpoint.ex.
**Example:**
```elixir
# In endpoint.ex, POST /api/tasks
post "/api/tasks" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    case AgentCom.Validation.validate_http(:post_task, conn.body_params) do
      {:ok, _validated} ->
        # existing logic
        ...
      {:error, errors} ->
        send_json(conn, 422, %{
          "error" => "validation_failed",
          "errors" => format_validation_errors(errors)
        })
    end
  end
end
```

### Anti-Patterns to Avoid
- **Validation inside GenServers:** Never let invalid data reach TaskQueue, Scheduler, or AgentFSM. Validate at the boundary (Socket and Endpoint), not inside business logic.
- **Coercive validation:** The user locked "strict types." Do NOT convert `"42"` to `42`. Return an error. This prevents silent data corruption.
- **Filtering unknown fields:** The user locked "accept and pass through." Do NOT strip unknown fields from messages. Only validate known required/optional fields; extra fields pass through untouched.
- **Global state for per-connection tracking:** Do NOT use a GenServer to track per-agent violation counts. Use the Socket process state. The Socket IS the per-agent process.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON parsing | Custom parser | `Jason.decode/1` (already in use) | Battle-tested, handles edge cases |
| WebSocket close frames | Custom close logic | WebSock `{:stop, reason, {code, msg}, state}` | Built into WebSock behaviour |
| JSON pointer paths for errors | Custom path builder | Simple string concatenation `"#/field"` | Flat schemas don't need deep paths |

**Key insight:** The validation itself IS the domain-specific logic. For flat maps with ~5 fields each, Elixir pattern matching IS the right tool. The "don't hand-roll" guidance applies to infrastructure (JSON parsing, WebSocket framing), not the validation rules themselves.

## Common Pitfalls

### Pitfall 1: Breaking Existing Agents
**What goes wrong:** Adding validation rejects messages that existing sidecars currently send successfully because they rely on defaults (e.g., `generation` defaults to 0 when missing).
**Why it happens:** Validation is retroactively applied to an existing protocol. Some agents may not send all fields.
**How to avoid:** Before making `generation` required for `task_complete`, verify that the sidecar always sends it. Check `sidecar/index.js` for what fields are included in `sendTaskComplete`. If the sidecar omits `generation`, either make it optional with a default, or update the sidecar first.
**Warning signs:** Existing integration tests fail after adding validation.

### Pitfall 2: Validation Error Loop
**What goes wrong:** Agent sends invalid message, receives error, tries to process error as a task result, sends another invalid message, loops.
**Why it happens:** Some agent code may not handle `"error"` type messages gracefully.
**How to avoid:** The validation error response is sent TO the agent, not processed BY the hub. The agent must handle the error type. This is an agent-side concern, but the hub can protect itself with the escalating disconnect (10 failures in 1 minute = disconnect).
**Warning signs:** Validation failure count spikes for a single agent.

### Pitfall 3: Validation Blocking the Socket Process
**What goes wrong:** Complex validation logic (e.g., cross-field validation, database lookups) blocks the Socket process, causing WebSocket heartbeat timeouts.
**Why it happens:** Socket.handle_in is synchronous.
**How to avoid:** Keep validation as pure function calls on in-memory data. No database lookups, no GenServer calls during validation. The validation module should be pure functions operating on the decoded JSON map.
**Warning signs:** WebSocket connection drops during high message volume.

### Pitfall 4: Disconnect Mechanism Races
**What goes wrong:** Agent is disconnected for violations, reconnects within cooldown, is allowed to reconnect because the cooldown state was lost.
**Why it happens:** Per-connection violation tracking resets on disconnect. The backoff state must persist across connections.
**How to avoid:** Store disconnect-backoff state in an ETS table keyed by `agent_id`, not in Socket process state. The Socket checks this ETS table during `identify` to enforce cooldown. The ETS table entry has a TTL (e.g., 10 minutes after the last disconnect) and is cleaned up by a periodic sweep.
**Warning signs:** Agent rapidly reconnects and sends the same bad messages.

### Pitfall 5: Over-Validating Internal Messages
**What goes wrong:** Validation is applied to hub-to-agent messages (`:push_task`, `:message`) or internal GenServer calls, adding overhead where trust is already established.
**Why it happens:** Enthusiasm for validation leads to validating everything.
**How to avoid:** Only validate at the EXTERNAL boundary: incoming WebSocket messages (agent-to-hub) and incoming HTTP requests (external-to-hub). Internal messages between GenServers are trusted -- they are created by the hub's own code.
**Warning signs:** Performance regression, validation errors in logs from internal messages.

### Pitfall 6: Disconnect Close Code
**What goes wrong:** Using WebSocket close code 1000 (Normal Closure) for validation disconnects, making it impossible for agents to distinguish "I was kicked" from "clean shutdown."
**Why it happens:** Not thinking about what the agent sees.
**How to avoid:** Use close code 1008 (Policy Violation) for validation-triggered disconnects. Include a close reason message like "too many validation errors." The sidecar can detect 1008 and apply backoff before reconnecting.
**Warning signs:** Agents reconnect immediately after being kicked, not respecting backoff.

## Code Examples

### Core Validation Function
```elixir
defmodule AgentCom.Validation do
  @moduledoc """
  Central validation module for all external input.
  Called by Socket (WebSocket) and Endpoint (HTTP) before processing.
  """

  alias AgentCom.Validation.Schemas

  @doc """
  Validate a WebSocket message against its schema.
  Returns {:ok, msg} or {:error, errors} where errors is a list of
  %{field: string, error: atom, detail: string, value: term | nil}.
  """
  def validate_ws_message(msg) when is_map(msg) do
    case msg do
      %{"type" => type} when is_binary(type) ->
        case Schemas.get(type) do
          nil ->
            {:error, [%{field: "type", error: :unknown_message_type,
              detail: "unknown message type '#{type}'",
              known_types: Schemas.known_types()}]}
          schema ->
            validate_against_schema(msg, schema)
        end
      %{"type" => type} ->
        {:error, [%{field: "type", error: :wrong_type,
          detail: "expected string, got #{type_name(type)}", value: type}]}
      _ ->
        {:error, [%{field: "type", error: :required,
          detail: "field is required"}]}
    end
  end

  defp validate_against_schema(msg, schema) do
    errors = []

    # Check required fields
    errors = Enum.reduce(schema.required, errors, fn {field, expected_type}, acc ->
      case Map.get(msg, field) do
        nil -> [%{field: field, error: :required, detail: "field is required"} | acc]
        value -> validate_type(field, value, expected_type, acc)
      end
    end)

    # Check optional fields (only if present)
    errors = Enum.reduce(schema.optional, errors, fn {field, expected_type}, acc ->
      case Map.get(msg, field) do
        nil -> acc  # optional, absent is fine
        value -> validate_type(field, value, expected_type, acc)
      end
    end)

    # Note: unknown fields are NOT checked -- pass-through policy

    case errors do
      [] -> {:ok, msg}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_type(field, value, :string, acc) when is_binary(value), do: acc
  defp validate_type(field, value, :string, acc),
    do: [%{field: field, error: :wrong_type, detail: "expected string, got #{type_name(value)}", value: value} | acc]

  defp validate_type(field, value, :integer, acc) when is_integer(value), do: acc
  defp validate_type(field, value, :integer, acc),
    do: [%{field: field, error: :wrong_type, detail: "expected integer, got #{type_name(value)}", value: value} | acc]

  defp validate_type(field, value, :map, acc) when is_map(value), do: acc
  defp validate_type(field, value, :map, acc),
    do: [%{field: field, error: :wrong_type, detail: "expected object, got #{type_name(value)}", value: inspect(value)} | acc]

  defp validate_type(field, value, {:list, _item_type}, acc) when is_list(value), do: acc
  defp validate_type(field, value, {:list, _item_type}, acc),
    do: [%{field: field, error: :wrong_type, detail: "expected array, got #{type_name(value)}", value: inspect(value)} | acc]

  defp validate_type(_field, _value, :any, acc), do: acc

  defp type_name(v) when is_binary(v), do: "string"
  defp type_name(v) when is_integer(v), do: "integer"
  defp type_name(v) when is_float(v), do: "float"
  defp type_name(v) when is_boolean(v), do: "boolean"
  defp type_name(v) when is_map(v), do: "object"
  defp type_name(v) when is_list(v), do: "array"
  defp type_name(nil), do: "null"
  defp type_name(_), do: "unknown"
end
```

### Validation Error Response (WebSocket)
```elixir
defp reply_validation_error(msg, errors, state) do
  message_type = Map.get(msg, "type", "unknown")
  formatted_errors = Enum.map(errors, fn error ->
    base = %{"field" => error.field, "error" => to_string(error.error), "detail" => error.detail}
    if Map.has_key?(error, :value) and error.value != nil do
      Map.put(base, "value", error.value)
    else
      base
    end
  end)

  reply = Jason.encode!(%{
    "type" => "error",
    "error" => "validation_failed",
    "message_type" => message_type,
    "errors" => formatted_errors
  })
  {:push, {:text, reply}, state}
end
```

### Escalating Disconnect in Socket State
```elixir
# Extended Socket state
defstruct [
  :agent_id,
  :identified,
  violation_count: 0,
  violation_window_start: nil
]

# After validation failure:
defp maybe_disconnect_for_violations(state) do
  now = System.system_time(:millisecond)
  window_start = state.violation_window_start || now

  {count, window} = if now - window_start > 60_000 do
    # Reset window
    {1, now}
  else
    {state.violation_count + 1, window_start}
  end

  new_state = %{state | violation_count: count, violation_window_start: window}

  if count >= 10 do
    # Disconnect with policy violation code
    # Record backoff level in ETS for reconnection enforcement
    :ets.update_counter(:validation_backoff, state.agent_id, {2, 1}, {state.agent_id, 0, now})
    {:disconnect, new_state}
  else
    {:ok, new_state}
  end
end
```

### HTTP Validation (Endpoint Pattern)
```elixir
# POST /api/tasks validation schema
@post_task_schema %{
  required: %{"description" => :string},
  optional: %{
    "priority" => :string,
    "metadata" => :map,
    "max_retries" => :integer,
    "complete_by" => :integer,
    "needed_capabilities" => {:list, :string}
  }
}

# In endpoint.ex
post "/api/tasks" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    case AgentCom.Validation.validate_http(:post_task, conn.body_params) do
      {:ok, _} ->
        # ... existing task creation logic ...
      {:error, errors} ->
        send_json(conn, 422, %{
          "error" => "validation_failed",
          "errors" => Enum.map(errors, fn e ->
            base = %{"field" => e.field, "error" => to_string(e.error), "detail" => e.detail}
            if e[:value], do: Map.put(base, "value", e.value), else: base
          end)
        })
    end
  end
end
```

### Schema Discovery Endpoint
```elixir
# GET /api/schemas
get "/api/schemas" do
  schemas = AgentCom.Validation.Schemas.all()
  |> Enum.map(fn {type, schema} ->
    %{
      "type" => type,
      "description" => Map.get(schema, :description, ""),
      "required_fields" => Enum.map(schema.required, fn {name, type} ->
        %{"name" => name, "type" => format_type(type)}
      end),
      "optional_fields" => Enum.map(schema.optional, fn {name, type} ->
        %{"name" => name, "type" => format_type(type)}
      end)
    }
  end)
  send_json(conn, 200, %{"schemas" => schemas, "version" => "1.0"})
end
```

### Backoff Enforcement on Reconnect
```elixir
# In handle_msg for "identify" -- check backoff before allowing reconnect
defp do_identify(agent_id, msg, state) do
  # Check if agent is in backoff cooldown
  case :ets.lookup(:validation_backoff, agent_id) do
    [{^agent_id, disconnect_count, last_disconnect_at}] ->
      cooldown_ms = backoff_duration(disconnect_count)
      elapsed = System.system_time(:millisecond) - last_disconnect_at
      if elapsed < cooldown_ms do
        remaining = div(cooldown_ms - elapsed, 1000)
        reply_error("cooldown_active: retry in #{remaining}s", state)
        # Close the connection
        {:stop, :normal, {1008, "cooldown active"}, state}
      else
        # Cooldown expired, allow reconnect
        proceed_with_identify(agent_id, msg, state)
      end
    [] ->
      proceed_with_identify(agent_id, msg, state)
  end
end

defp backoff_duration(1), do: 30_000     # 30 seconds
defp backoff_duration(2), do: 60_000     # 1 minute
defp backoff_duration(n) when n >= 3, do: 300_000  # 5 minutes
defp backoff_duration(_), do: 0
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|---|---|---|---|
| No validation (current) | Validate-then-dispatch at boundary | This phase | Prevents GenServer crashes from malformed input |
| Ad-hoc field checks in endpoint.ex | Central Validation module | This phase | Consistent error format, reusable across handlers |
| Silent defaults for missing fields | Explicit required/optional with errors | This phase | Agents get actionable feedback instead of silent failures |

**Not applicable:**
- This is Elixir standard pattern matching, not a library that might have deprecated features.

## Inventory of Entry Points to Validate

### WebSocket Message Types (socket.ex)
| Type | Current Handler | Requires Auth | Notes |
|---|---|---|---|
| `identify` | `handle_msg/2` match | No (pre-auth) | Must validate before auth check |
| `message` | `handle_msg/2` match | Yes | Payload is freeform map |
| `status` | `handle_msg/2` match | Yes | |
| `list_agents` | `handle_msg/2` match | Yes | No fields besides type |
| `ping` | `handle_msg/2` match | Yes | No fields besides type |
| `channel_subscribe` | `handle_msg/2` match | Yes | |
| `channel_unsubscribe` | `handle_msg/2` match | Yes | |
| `channel_publish` | `handle_msg/2` match | Yes | |
| `channel_history` | `handle_msg/2` match | Yes | `limit` and `since` are optional integers |
| `list_channels` | `handle_msg/2` match | Yes | No fields besides type |
| `task_accepted` | `handle_msg/2` match | Yes | |
| `task_progress` | `handle_msg/2` match | Yes | |
| `task_complete` | `handle_msg/2` match | Yes | `generation` should be required |
| `task_failed` | `handle_msg/2` match | Yes | `generation` should be required |
| `task_recovering` | `handle_msg/2` match | Yes | |

### HTTP Endpoints (endpoint.ex)
| Method | Path | Body Params | Notes |
|---|---|---|---|
| POST | `/api/message` | `payload` (required), `to`, `type`, `reply_to` | |
| PUT | `/api/config/heartbeat-interval` | `heartbeat_interval_ms` (required, positive int) | Already validates type |
| PUT | `/api/config/mailbox-retention` | `mailbox_ttl_ms` (required, positive int) | Already validates type |
| POST | `/api/channels` | `name` (required), `description` | |
| POST | `/api/channels/:ch/publish` | `payload` (required), `type`, `reply_to` | |
| POST | `/api/mailbox/:id/ack` | `seq` (required) | |
| POST | `/admin/tokens` | `agent_id` (required) | |
| POST | `/api/admin/push-task` | `agent_id`, `description` (both required), `metadata` | |
| POST | `/api/tasks` | `description` (required), `priority`, `metadata`, etc. | |
| POST | `/api/tasks/:id/retry` | (no body) | |
| POST | `/api/onboard/register` | `agent_id` (required, non-empty string) | Already validates |
| PUT | `/api/config/default-repo` | `url` (required, non-empty string) | Already validates |

## Open Questions

1. **Should validation run before or after auth?**
   - What we know: Currently `identify` is the auth step. Pre-identify messages MUST include `type` and `agent_id`. Post-identify messages have auth established.
   - What's unclear: If we validate before auth, we leak schema information to unauthenticated connections (they see error details). If after, unauthenticated messages that happen to be malformed get a generic "not_identified" error.
   - Recommendation: Validate `identify` messages fully (they are pre-auth by nature). For all other messages, the existing `identified: false` check runs first, then validation runs second. This means only identified agents get detailed validation errors.

2. **ETS table lifecycle for backoff tracking**
   - What we know: Need to persist disconnect counts across reconnections. ETS is in-memory and dies with the process.
   - What's unclear: Should this ETS table be owned by the Socket module (compile-time) or a supervisor?
   - Recommendation: Create the ETS table in `Application.start/2` (application.ex) as a named public table. Clean up entries older than 10 minutes with a periodic sweep (can reuse the Reaper pattern already in the codebase). This survives individual Socket process crashes.

3. **Sidecar compatibility**
   - What we know: The sidecar sends `task_complete` without always including `generation`. Making `generation` required could break existing sidecars.
   - What's unclear: Exact fields the sidecar currently sends for each message type.
   - Recommendation: Before marking `generation` as required, verify the sidecar code. If it omits `generation`, keep it optional with a default for backward compatibility, or update the sidecar simultaneously.

## Sources

### Primary (HIGH confidence)
- AgentCom codebase: `lib/agent_com/socket.ex` -- all 15 WebSocket message types, current error handling, protocol documentation
- AgentCom codebase: `lib/agent_com/endpoint.ex` -- all HTTP endpoints, current ad-hoc validation patterns
- AgentCom codebase: `lib/agent_com/task_queue.ex` -- task struct definition, generation fencing, DETS persistence
- AgentCom codebase: `lib/agent_com/message.ex` -- Message struct, `new/1` accepting maps
- [WebSock behaviour](https://hexdocs.pm/websock/WebSock.html) -- return tuples including `{:stop, reason, {code, msg}, state}` for controlled disconnect
- [ex_json_schema v0.11.2 README](https://github.com/jonasschmidt/ex_json_schema) -- API: `Schema.resolve/1`, `Validator.validate/3`, error format `{:error, [{message, path}]}`

### Secondary (MEDIUM confidence)
- [Elixir patterns and guards](https://hexdocs.pm/elixir/patterns-and-guards.html) -- guard clauses for type checking in function heads
- [Elixir Forum: Simple validation without Ecto](https://elixirforum.com/t/simple-validation-without-ecto/22436) -- community confirmation that hand-rolled validation is standard for non-Ecto use cases

### Tertiary (LOW confidence)
- WebSocket close codes: 1008 = Policy Violation (appropriate for validation disconnect). From RFC 6455.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- no new dependencies, uses existing Elixir patterns already proven in this codebase
- Architecture: HIGH -- validate-then-dispatch is a universal pattern, directly grounded in codebase analysis of all 15 WS message types and 12+ HTTP endpoints
- Pitfalls: HIGH -- pitfalls derived from analysis of actual codebase behavior (generation defaults, sidecar compatibility, Socket process model)
- Escalating disconnect: MEDIUM -- WebSock `{:stop}` tuples verified via docs, ETS backoff tracking is straightforward but untested in this codebase
- Schema discovery: MEDIUM -- JSON serialization of Elixir schema structs is standard, but exact format is discretionary

**Research date:** 2026-02-11
**Valid until:** 2026-03-13 (30 days -- stable domain, no library version concerns)
