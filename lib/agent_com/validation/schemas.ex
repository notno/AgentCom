defmodule AgentCom.Validation.Schemas do
  @moduledoc """
  Schema definitions for all WebSocket message types and HTTP endpoint bodies.

  Schemas are Elixir maps that serve dual purpose:
  - Runtime validation (called by AgentCom.Validation)
  - JSON serialization for GET /api/schemas discovery endpoint

  Each schema has:
  - `required` - map of field name => type (must be present and match type)
  - `optional` - map of field name => type (validated only if present)
  - `description` - human-readable description for schema discovery
  """

  # --- String length limits ---
  @length_limits %{
    "agent_id" => 128,
    "description" => 10_000,
    "status" => 256,
    "channel" => 64,
    "token" => 256,
    "error" => 2_000,
    "reason" => 2_000,
    "name" => 256,
    "repo" => 512,
    "ollama_url" => 512
  }

  # --- WebSocket message schemas (17 types) ---
  @ws_schemas %{
    "identify" => %{
      required: %{
        "type" => :string,
        "agent_id" => :string,
        "token" => :string
      },
      optional: %{
        "name" => :string,
        "status" => :string,
        "capabilities" => {:list, :string},
        "ollama_url" => :string
      },
      description: "First message on WebSocket connection. Authenticates the agent."
    },
    "message" => %{
      required: %{
        "type" => :string,
        "payload" => :map
      },
      optional: %{
        "to" => :string,
        "message_type" => :string,
        "reply_to" => :string
      },
      description: "Send a direct or broadcast message."
    },
    "status" => %{
      required: %{
        "type" => :string,
        "status" => :string
      },
      optional: %{},
      description: "Update agent status."
    },
    "list_agents" => %{
      required: %{
        "type" => :string
      },
      optional: %{},
      description: "Request list of connected agents."
    },
    "ping" => %{
      required: %{
        "type" => :string
      },
      optional: %{},
      description: "Heartbeat ping. Server responds with pong."
    },
    "channel_subscribe" => %{
      required: %{
        "type" => :string,
        "channel" => :string
      },
      optional: %{},
      description: "Subscribe to a channel."
    },
    "channel_unsubscribe" => %{
      required: %{
        "type" => :string,
        "channel" => :string
      },
      optional: %{},
      description: "Unsubscribe from a channel."
    },
    "channel_publish" => %{
      required: %{
        "type" => :string,
        "channel" => :string,
        "payload" => :map
      },
      optional: %{
        "message_type" => :string,
        "reply_to" => :string
      },
      description: "Publish a message to a channel."
    },
    "channel_history" => %{
      required: %{
        "type" => :string,
        "channel" => :string
      },
      optional: %{
        "limit" => :integer,
        "since" => :integer
      },
      description: "Request channel message history."
    },
    "list_channels" => %{
      required: %{
        "type" => :string
      },
      optional: %{},
      description: "Request list of all channels."
    },
    "task_accepted" => %{
      required: %{
        "type" => :string,
        "task_id" => :string
      },
      optional: %{},
      description: "Sidecar acknowledges task assignment."
    },
    "task_progress" => %{
      required: %{
        "type" => :string,
        "task_id" => :string
      },
      optional: %{
        "progress" => :integer,
        "execution_event" => :map
      },
      description: "Sidecar reports task progress (prevents overdue sweep). Optional execution_event for dashboard streaming."
    },
    "task_complete" => %{
      required: %{
        "type" => :string,
        "task_id" => :string,
        "generation" => :integer
      },
      optional: %{
        "result" => :map,
        "tokens_used" => :integer,
        "verification_report" => :map,
        "verification_history" => {:list, :map}
      },
      description: "Sidecar reports task completion with result."
    },
    "task_failed" => %{
      required: %{
        "type" => :string,
        "task_id" => :string,
        "generation" => :integer
      },
      optional: %{
        "error" => :string,
        "reason" => :string
      },
      description: "Sidecar reports task failure."
    },
    "task_recovering" => %{
      required: %{
        "type" => :string,
        "task_id" => :string
      },
      optional: %{},
      description: "Sidecar requests task recovery status after restart."
    },
    "ollama_report" => %{
      required: %{
        "type" => :string,
        "ollama_url" => :string
      },
      optional: %{},
      description: "Sidecar reports local Ollama endpoint URL for auto-registration."
    },
    "resource_report" => %{
      required: %{
        "type" => :string
      },
      optional: %{
        "cpu_percent" => :number,
        "ram_used_bytes" => :number,
        "ram_total_bytes" => :number,
        "vram_used_bytes" => :number,
        "vram_total_bytes" => :number,
        "timestamp" => :number
      },
      description: "Sidecar reports host resource utilization (CPU, RAM, VRAM)."
    }
  }

  # --- HTTP endpoint schemas ---
  @http_schemas %{
    post_message: %{
      required: %{
        "payload" => :map
      },
      optional: %{
        "to" => :string,
        "type" => :string,
        "reply_to" => :string
      },
      description: "Send a message via HTTP."
    },
    put_heartbeat_interval: %{
      required: %{
        "heartbeat_interval_ms" => :positive_integer
      },
      optional: %{},
      description: "Set heartbeat interval in milliseconds."
    },
    put_mailbox_retention: %{
      required: %{
        "mailbox_ttl_ms" => :positive_integer
      },
      optional: %{},
      description: "Set mailbox retention TTL in milliseconds."
    },
    post_channel: %{
      required: %{
        "name" => :string
      },
      optional: %{
        "description" => :string
      },
      description: "Create a new channel."
    },
    post_channel_publish: %{
      required: %{
        "payload" => :map
      },
      optional: %{
        "type" => :string,
        "reply_to" => :string
      },
      description: "Publish a message to a channel via HTTP."
    },
    post_mailbox_ack: %{
      required: %{
        "seq" => :integer
      },
      optional: %{},
      description: "Acknowledge mailbox messages up to sequence number."
    },
    post_admin_token: %{
      required: %{
        "agent_id" => :string
      },
      optional: %{},
      description: "Generate an authentication token for an agent."
    },
    post_admin_push_task: %{
      required: %{
        "agent_id" => :string,
        "description" => :string
      },
      optional: %{
        "metadata" => :map
      },
      description: "Push a task directly to a connected agent."
    },
    post_task: %{
      required: %{
        "description" => :string
      },
      optional: %{
        "priority" => :string,
        "metadata" => :map,
        "max_retries" => :integer,
        "complete_by" => :integer,
        "needed_capabilities" => {:list, :string},
        "repo" => :string,
        "branch" => :string,
        "file_hints" => {:list, :map},
        "success_criteria" => {:list, :string},
        "verification_steps" => {:list, :map},
        "complexity_tier" => :string,
        "max_verification_retries" => :integer,
        "skip_verification" => :boolean,
        "verification_timeout_ms" => :integer
      },
      description: "Submit a task to the queue."
    },
    post_onboard_register: %{
      required: %{
        "agent_id" => :string
      },
      optional: %{},
      description: "Register a new agent and receive a token."
    },
    put_default_repo: %{
      required: %{
        "url" => :string
      },
      optional: %{},
      description: "Set the default repository URL."
    },
    post_push_subscribe: %{
      required: %{
        "endpoint" => :string
      },
      optional: %{},
      description: "Register a push notification subscription."
    },
    post_llm_registry: %{
      required: %{
        "host" => :string
      },
      optional: %{
        "port" => :number,
        "name" => :string
      },
      description: "Register an Ollama endpoint. Port defaults to 11434."
    },
    post_repo: %{
      required: %{
        "url" => :string
      },
      optional: %{
        "name" => :string
      },
      description: "Register a new repository in the repo registry."
    }
  }

  @doc "Get a WebSocket message schema by type string. Returns nil if unknown."
  @spec get(String.t()) :: map() | nil
  def get(type), do: Map.get(@ws_schemas, type)

  @doc "Return all WebSocket message schemas."
  @spec all() :: map()
  def all, do: @ws_schemas

  @doc "Return list of known WebSocket message type strings."
  @spec known_types() :: [String.t()]
  def known_types, do: Map.keys(@ws_schemas) |> Enum.sort()

  @doc "Get an HTTP endpoint schema by atom key. Returns nil if unknown."
  @spec http_schema(atom()) :: map() | nil
  def http_schema(key), do: Map.get(@http_schemas, key)

  @doc "Return all HTTP endpoint schemas."
  @spec http_all() :: map()
  def http_all, do: @http_schemas

  @doc "Return the string length limits map."
  @spec length_limits() :: map()
  def length_limits, do: @length_limits

  @doc "Get the length limit for a field name. Returns nil if no limit."
  @spec length_limit(String.t()) :: non_neg_integer() | nil
  def length_limit(field), do: Map.get(@length_limits, field)

  @doc """
  Serialize all schemas (WS + HTTP) to a JSON-friendly format for GET /api/schemas.
  """
  @spec to_json() :: map()
  def to_json do
    ws = Enum.map(@ws_schemas, fn {type, schema} ->
      %{
        "type" => type,
        "description" => Map.get(schema, :description, ""),
        "required_fields" => format_fields(schema.required),
        "optional_fields" => format_fields(schema.optional)
      }
    end)

    http = Enum.map(@http_schemas, fn {key, schema} ->
      %{
        "key" => to_string(key),
        "description" => Map.get(schema, :description, ""),
        "required_fields" => format_fields(schema.required),
        "optional_fields" => format_fields(schema.optional)
      }
    end)

    %{
      "websocket" => ws,
      "http" => http,
      "version" => "1.0"
    }
  end

  defp format_fields(fields) do
    Enum.map(fields, fn {name, type} ->
      %{"name" => name, "type" => format_type(type)}
    end)
  end

  defp format_type(:string), do: "string"
  defp format_type(:integer), do: "integer"
  defp format_type(:number), do: "number"
  defp format_type(:positive_integer), do: "positive_integer"
  defp format_type(:map), do: "object"
  defp format_type(:boolean), do: "boolean"
  defp format_type(:any), do: "any"
  defp format_type({:list, item_type}), do: "array<#{format_type(item_type)}>"
end
