defmodule AgentCom.Endpoint do
  @moduledoc """
  HTTP + WebSocket endpoint for AgentCom.

  Routes:
  - GET    /health               — Health check
  - GET    /api/agents           — List connected agents
  - POST   /api/message          — Send a message via HTTP (auth required)
  - GET    /api/config/heartbeat-interval — Get heartbeat interval (auth required)
  - PUT    /api/config/heartbeat-interval — Set heartbeat interval (admin, auth required)
  - GET    /api/mailbox/:id      — Poll messages (token required)
  - POST   /api/mailbox/:id/ack  — Acknowledge messages (token required)
  - POST   /admin/tokens         — Generate a token for an agent (auth required)
  - GET    /admin/tokens         — List tokens (auth required)
  - DELETE /admin/tokens/:id     — Revoke tokens for an agent (auth required)
  - POST   /api/admin/agents/:agent_id/reset-token — Revoke and reissue token (auth required)
  - GET    /api/channels          — List all channels
  - POST   /api/channels          — Create a channel (auth required)
  - GET    /api/channels/:ch      — Channel info + subscribers
  - POST   /api/channels/:ch/subscribe   — Subscribe to channel (auth required)
  - POST   /api/channels/:ch/unsubscribe — Unsubscribe (auth required)
  - POST   /api/channels/:ch/publish     — Publish to channel (auth required)
  - GET    /api/channels/:ch/history     — Channel message history
  - GET    /api/agents/states          — All agent FSM states (auth required)
  - GET    /api/agents/:id/state       — Single agent FSM state detail (auth required)
  - GET    /api/agents/:id/subscriptions — List agent's channel subscriptions
  - POST   /api/admin/push-task  — Push a task to a connected agent (auth required)
  - POST   /api/admin/backup     — Trigger manual DETS backup (auth required)
  - GET    /api/admin/dets-health — DETS table health metrics (auth required)
  - POST   /api/admin/compact     — Compact all DETS tables (auth required)
  - POST   /api/admin/compact/:table — Compact a specific DETS table (auth required)
  - POST   /api/admin/restore/:table — Restore a DETS table from backup (auth required)
  - PUT    /api/admin/log-level    — Change runtime log level (auth required, resets on restart)
  - POST   /api/tasks             — Submit a task to the queue (auth required)
  - GET    /api/tasks             — List tasks with optional filters (auth required)
  - GET    /api/tasks/dead-letter — List dead-letter tasks (auth required)
  - GET    /api/tasks/stats       — Queue statistics (auth required)
  - GET    /api/tasks/:task_id    — Get task details with history (auth required)
  - POST   /api/tasks/:task_id/retry — Retry a dead-letter task (auth required)
  - WS     /ws/dashboard         — WebSocket for dashboard real-time updates
  - GET    /api/dashboard/state  — Full dashboard state snapshot (JSON, no auth)
  - GET    /sw.js               — Service worker for push notifications
  - GET    /api/dashboard/vapid-key — VAPID public key for push subscription
  - POST   /api/dashboard/push-subscribe — Register push subscription
  - POST   /api/onboard/register — Register new agent, get token (no auth)
  - GET    /api/config/default-repo — Get default repository URL (no auth)
  - PUT    /api/config/default-repo — Set default repository URL (auth required)
  - GET    /api/metrics          — System metrics (queue depth, latency, utilization, errors)
  - GET    /api/alerts           — Active alerts (no auth)
  - POST   /api/alerts/:rule_id/acknowledge — Acknowledge alert (auth required)
  - GET    /api/config/alert-thresholds — Get alert thresholds (auth required)
  - PUT    /api/config/alert-thresholds — Update alert thresholds (auth required)
  - GET    /api/admin/rate-limits           — Rate limit overview: defaults, overrides, whitelist (auth required)
  - PUT    /api/admin/rate-limits/:agent_id — Set per-agent rate limit overrides (auth required)
  - DELETE /api/admin/rate-limits/:agent_id — Remove per-agent overrides (auth required)
  - GET    /api/admin/rate-limits/whitelist — Get exempt agent whitelist (auth required)
  - PUT    /api/admin/rate-limits/whitelist — Replace entire whitelist (auth required)
  - POST   /api/admin/rate-limits/whitelist — Add agent to whitelist (auth required)
  - DELETE /api/admin/rate-limits/whitelist/:agent_id — Remove agent from whitelist (auth required)
  - GET    /api/admin/llm-registry           — List all LLM endpoints (auth required)
  - GET    /api/admin/llm-registry/snapshot — Full registry snapshot with resources and models (auth required)
  - GET    /api/admin/llm-registry/:id     — Get single LLM endpoint (auth required)
  - POST   /api/admin/llm-registry         — Register an Ollama endpoint (auth required)
  - DELETE /api/admin/llm-registry/:id     — Remove an LLM endpoint (auth required)
  - GET    /api/admin/repo-registry           — List all registered repos (auth required)
  - POST   /api/admin/repo-registry           — Register a new repo (auth required)
  - DELETE /api/admin/repo-registry/:repo_id  — Remove a repo (auth required)
  - PUT    /api/admin/repo-registry/:repo_id/move-up   — Move repo up in priority (auth required)
  - PUT    /api/admin/repo-registry/:repo_id/move-down — Move repo down in priority (auth required)
  - PUT    /api/admin/repo-registry/:repo_id/pause     — Pause a repo (auth required)
  - PUT    /api/admin/repo-registry/:repo_id/unpause   — Unpause a repo (auth required)
  - POST   /api/admin/repo-scanner/scan — Scan repos for sensitive content (auth required)
  - POST   /api/goals             — Submit a goal to the backlog (auth required)
  - GET    /api/goals             — List goals with optional filters (auth required)
  - GET    /api/goals/stats       — Goal backlog statistics (auth required)
  - GET    /api/goals/:goal_id    — Get goal details (auth required)
  - PATCH  /api/goals/:goal_id/transition — Transition goal lifecycle state (auth required)
  - GET    /api/schemas           — Schema discovery (no auth)
  - POST   /api/hub/pause        — Pause the HubFSM (auth required)
  - POST   /api/hub/resume       — Resume the HubFSM (auth required)
  - GET    /api/hub/state        — Get current HubFSM state (no auth -- dashboard)
  - GET    /api/hub/history      — Get HubFSM transition history (no auth -- dashboard)
  - POST   /api/webhooks/github           — GitHub webhook endpoint (HMAC auth, no bearer)
  - GET    /api/webhooks/github/history   — Webhook event history (no auth -- dashboard)
  - PUT    /api/config/webhook-secret     — Set webhook secret (auth required)
  - WS     /ws                   — WebSocket for agent connections
  """
  use Plug.Router

  require Logger

  alias AgentCom.Validation

  plug(Plug.Logger)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    body_reader: {AgentCom.CacheBodyReader, :read_body, []},
    json_decoder: Jason
  )

  plug(:dispatch)

  # --- NOT rate limited: health check, dashboard, WS upgrades, schemas ---

  get "/health" do
    agents = AgentCom.Presence.list()

    send_json(conn, 200, %{
      "status" => "ok",
      "service" => "agent_com",
      "agents_connected" => length(agents)
    })
  end

  # --- Unauthenticated routes with IP-based rate limiting ---

  get "/api/agents" do
    conn = AgentCom.Plugs.RateLimit.call(conn, action: :get_agents)

    if conn.halted do
      conn
    else
      agents =
        AgentCom.Presence.list()
        |> Enum.map(fn a ->
          %{
            "agent_id" => a.agent_id,
            "name" => a[:name],
            "status" => a[:status],
            "capabilities" => a[:capabilities] || [],
            "connected_at" => a[:connected_at],
            "fsm_state" => Map.get(a, :fsm_state, "unknown")
          }
        end)

      send_json(conn, 200, %{"agents" => agents})
    end
  end

  # --- Authenticated routes with agent-based rate limiting ---

  post "/api/message" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_message)

      if conn.halted do
        conn
      else
        authenticated_agent = conn.assigns[:authenticated_agent]
        params = conn.body_params

        case Validation.validate_http(:post_message, params) do
          {:ok, _} ->
            # Use authenticated agent_id as "from" -- ignore any spoofed "from" field
            from = authenticated_agent
            payload = params["payload"]

            msg =
              AgentCom.Message.new(%{
                from: from,
                to: params["to"],
                type: params["type"] || "chat",
                payload: payload,
                reply_to: params["reply_to"]
              })

            {:ok, _} = AgentCom.Router.route(msg)
            send_json(conn, 200, %{"status" => "sent", "id" => msg.id})

          {:error, errors} ->
            send_validation_error(conn, errors)
        end
      end
    end
  end

  # --- Config: Heartbeat interval ---

  get "/api/config/heartbeat-interval" do
    token = get_token(conn)

    case AgentCom.Auth.verify(token) do
      {:ok, _agent_id} ->
        interval = AgentCom.Config.get(:heartbeat_interval_ms)
        send_json(conn, 200, %{"heartbeat_interval_ms" => interval})

      _ ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  put "/api/config/heartbeat-interval" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Validation.validate_http(:put_heartbeat_interval, conn.body_params) do
        {:ok, _} ->
          ms = conn.body_params["heartbeat_interval_ms"]
          :ok = AgentCom.Config.put(:heartbeat_interval_ms, ms)
          send_json(conn, 200, %{"heartbeat_interval_ms" => ms, "status" => "updated"})

        {:error, errors} ->
          send_validation_error(conn, errors)
      end
    end
  end

  # --- Config: Mailbox retention ---

  get "/api/config/mailbox-retention" do
    token = get_token(conn)

    case AgentCom.Auth.verify(token) do
      {:ok, _agent_id} ->
        ttl = AgentCom.Mailbox.get_ttl()
        send_json(conn, 200, %{"mailbox_ttl_ms" => ttl})

      _ ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  put "/api/config/mailbox-retention" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Validation.validate_http(:put_mailbox_retention, conn.body_params) do
        {:ok, _} ->
          ms = conn.body_params["mailbox_ttl_ms"]
          AgentCom.Mailbox.set_ttl(ms)
          send_json(conn, 200, %{"mailbox_ttl_ms" => ms, "status" => "updated"})

        {:error, errors} ->
          send_validation_error(conn, errors)
      end
    end
  end

  post "/api/mailbox/evict" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      AgentCom.Mailbox.evict_expired()
      send_json(conn, 200, %{"status" => "eviction_triggered"})
    end
  end

  # --- Threads: Conversation view ---

  get "/api/threads/:message_id" do
    token = get_token(conn)

    case AgentCom.Auth.verify(token) do
      {:ok, _agent_id} ->
        {:ok, thread} = AgentCom.Threads.get_thread(message_id)
        send_json(conn, 200, thread)

      _ ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  get "/api/threads/:message_id/replies" do
    token = get_token(conn)

    case AgentCom.Auth.verify(token) do
      {:ok, _agent_id} ->
        {:ok, replies} = AgentCom.Threads.get_replies(message_id)

        send_json(conn, 200, %{
          "parent" => message_id,
          "replies" => replies,
          "count" => length(replies)
        })

      _ ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  get "/api/threads/:message_id/root" do
    token = get_token(conn)

    case AgentCom.Auth.verify(token) do
      {:ok, _agent_id} ->
        {:ok, root_id} = AgentCom.Threads.get_root(message_id)
        send_json(conn, 200, %{"message_id" => message_id, "root" => root_id})

      _ ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  # --- Mailbox: Poll for messages ---

  get "/api/mailbox/:agent_id" do
    since =
      case conn.params["since"] do
        nil -> 0
        s -> String.to_integer(s)
      end

    token = get_token(conn)

    case AgentCom.Auth.verify(token) do
      {:ok, ^agent_id} ->
        {messages, last_seq} = AgentCom.Mailbox.poll(agent_id, since)

        formatted =
          Enum.map(messages, fn entry ->
            Map.put(entry.message, "seq", entry.seq)
          end)

        send_json(conn, 200, %{
          "agent_id" => agent_id,
          "messages" => formatted,
          "last_seq" => last_seq,
          "count" => length(formatted)
        })

      _ ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  post "/api/mailbox/:agent_id/ack" do
    token = get_token(conn)

    case AgentCom.Auth.verify(token) do
      {:ok, ^agent_id} ->
        case Validation.validate_http(:post_mailbox_ack, conn.body_params) do
          {:ok, _} ->
            seq = conn.body_params["seq"]
            AgentCom.Mailbox.ack(agent_id, seq)
            send_json(conn, 200, %{"status" => "acked", "up_to" => seq})

          {:error, errors} ->
            send_validation_error(conn, errors)
        end

      _ ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  # --- Channels ---

  get "/api/channels" do
    conn = AgentCom.Plugs.RateLimit.call(conn, action: :get_channels)

    if conn.halted do
      conn
    else
      channels = AgentCom.Channels.list()
      send_json(conn, 200, %{"channels" => channels})
    end
  end

  post "/api/channels" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_channel)

      if conn.halted do
        conn
      else
        agent_id = conn.assigns[:authenticated_agent]

        case Validation.validate_http(:post_channel, conn.body_params) do
          {:ok, _} ->
            name = conn.body_params["name"]

            opts = %{
              description: conn.body_params["description"] || "",
              created_by: agent_id
            }

            case AgentCom.Channels.create(name, opts) do
              :ok -> send_json(conn, 201, %{"status" => "created", "channel" => name})
              {:error, :exists} -> send_json(conn, 409, %{"error" => "channel_exists"})
            end

          {:error, errors} ->
            send_validation_error(conn, errors)
        end
      end
    end
  end

  get "/api/channels/:channel" do
    conn = AgentCom.Plugs.RateLimit.call(conn, action: :get_channel_info)

    if conn.halted do
      conn
    else
      case AgentCom.Channels.info(channel) do
        {:ok, info} ->
          send_json(conn, 200, %{
            "name" => info.name,
            "description" => info.description,
            "subscribers" => info.subscribers,
            "subscriber_count" => length(info.subscribers),
            "created_at" => info.created_at,
            "created_by" => info.created_by
          })

        {:error, :not_found} ->
          send_json(conn, 404, %{"error" => "channel_not_found"})
      end
    end
  end

  post "/api/channels/:channel/subscribe" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_channel_subscribe)

      if conn.halted do
        conn
      else
        agent_id = conn.assigns[:authenticated_agent]

        case AgentCom.Channels.subscribe(channel, agent_id) do
          :ok -> send_json(conn, 200, %{"status" => "subscribed", "channel" => channel})
          {:ok, :already_subscribed} -> send_json(conn, 200, %{"status" => "already_subscribed"})
          {:error, :not_found} -> send_json(conn, 404, %{"error" => "channel_not_found"})
        end
      end
    end
  end

  post "/api/channels/:channel/unsubscribe" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_channel_unsubscribe)

      if conn.halted do
        conn
      else
        agent_id = conn.assigns[:authenticated_agent]

        case AgentCom.Channels.unsubscribe(channel, agent_id) do
          :ok -> send_json(conn, 200, %{"status" => "unsubscribed", "channel" => channel})
          {:error, :not_found} -> send_json(conn, 404, %{"error" => "channel_not_found"})
        end
      end
    end
  end

  post "/api/channels/:channel/publish" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_channel_publish)

      if conn.halted do
        conn
      else
        agent_id = conn.assigns[:authenticated_agent]

        case Validation.validate_http(:post_channel_publish, conn.body_params) do
          {:ok, _} ->
            payload = conn.body_params["payload"]

            msg =
              AgentCom.Message.new(%{
                from: agent_id,
                to: nil,
                type: conn.body_params["type"] || "chat",
                payload: payload,
                reply_to: conn.body_params["reply_to"]
              })

            case AgentCom.Channels.publish(channel, msg) do
              {:ok, seq} -> send_json(conn, 200, %{"status" => "published", "seq" => seq})
              {:error, :not_found} -> send_json(conn, 404, %{"error" => "channel_not_found"})
            end

          {:error, errors} ->
            send_validation_error(conn, errors)
        end
      end
    end
  end

  get "/api/channels/:channel/history" do
    limit =
      case conn.params["limit"] do
        nil -> 50
        l -> String.to_integer(l)
      end

    since =
      case conn.params["since"] do
        nil -> 0
        s -> String.to_integer(s)
      end

    messages = AgentCom.Channels.history(channel, limit: limit, since: since)

    send_json(conn, 200, %{
      "channel" => channel,
      "messages" => messages,
      "count" => length(messages)
    })
  end

  # --- Agent FSM state endpoints (must be before parameterized :agent_id routes) ---

  get "/api/agents/states" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      agents = AgentCom.AgentFSM.list_all()

      formatted =
        Enum.map(agents, fn a ->
          %{
            "agent_id" => a.agent_id,
            "fsm_state" => to_string(a.fsm_state),
            "current_task_id" => a.current_task_id,
            "capabilities" =>
              Enum.map(a.capabilities || [], fn cap ->
                if is_map(cap) do
                  Map.new(cap, fn {k, v} -> {to_string(k), v} end)
                else
                  cap
                end
              end),
            "flags" => Enum.map(a.flags || [], &to_string/1),
            "connected_at" => a.connected_at,
            "name" => a.name
          }
        end)

      send_json(conn, 200, %{"agents" => formatted})
    end
  end

  get "/api/agents/:agent_id/state" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.AgentFSM.get_state(agent_id) do
        {:ok, agent_state} ->
          send_json(conn, 200, %{
            "agent_id" => agent_state.agent_id,
            "fsm_state" => to_string(agent_state.fsm_state),
            "current_task_id" => agent_state.current_task_id,
            "capabilities" =>
              Enum.map(agent_state.capabilities, fn cap ->
                if is_map(cap) do
                  Map.new(cap, fn {k, v} -> {to_string(k), v} end)
                else
                  cap
                end
              end),
            "flags" => Enum.map(agent_state.flags, &to_string/1),
            "connected_at" => agent_state.connected_at,
            "last_state_change" => agent_state.last_state_change,
            "name" => agent_state.name
          })

        {:error, :not_found} ->
          send_json(conn, 404, %{"error" => "agent_not_found"})
      end
    end
  end

  get "/api/agents/:agent_id/subscriptions" do
    channels = AgentCom.Channels.subscriptions(agent_id)
    send_json(conn, 200, %{"agent_id" => agent_id, "channels" => channels})
  end

  # --- Message History ---

  get "/api/messages" do
    token = get_token(conn)

    case AgentCom.Auth.verify(token) do
      {:ok, _agent_id} ->
        opts = []
        opts = if p = conn.params["from"], do: [{:from, p} | opts], else: opts
        opts = if p = conn.params["to"], do: [{:to, p} | opts], else: opts
        opts = if p = conn.params["channel"], do: [{:channel, p} | opts], else: opts

        opts =
          if p = conn.params["start_time"],
            do: [{:start_time, String.to_integer(p)} | opts],
            else: opts

        opts =
          if p = conn.params["end_time"],
            do: [{:end_time, String.to_integer(p)} | opts],
            else: opts

        opts =
          if p = conn.params["cursor"], do: [{:cursor, String.to_integer(p)} | opts], else: opts

        opts =
          if p = conn.params["limit"], do: [{:limit, String.to_integer(p)} | opts], else: opts

        result = AgentCom.MessageHistory.query(opts)

        send_json(conn, 200, %{
          "messages" => result.messages,
          "cursor" => result.cursor,
          "count" => result.count
        })

      _ ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  # --- Admin: Token management (requires auth) ---

  post "/admin/tokens" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Validation.validate_http(:post_admin_token, conn.body_params) do
        {:ok, _} ->
          agent_id = conn.body_params["agent_id"]
          {:ok, token} = AgentCom.Auth.generate(agent_id)
          send_json(conn, 201, %{"agent_id" => agent_id, "token" => token})

        {:error, errors} ->
          send_validation_error(conn, errors)
      end
    end
  end

  get "/admin/tokens" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
    if conn.halted, do: conn, else: send_json(conn, 200, %{"tokens" => AgentCom.Auth.list()})
  end

  delete "/admin/tokens/:agent_id" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      AgentCom.Auth.revoke(agent_id)
      send_json(conn, 200, %{"status" => "revoked", "agent_id" => agent_id})
    end
  end

  # --- Admin: Reset token (revoke + reissue for agent re-onboarding) ---

  post "/api/admin/agents/:agent_id/reset-token" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      existing = AgentCom.Auth.list()

      if Enum.any?(existing, fn entry -> entry.agent_id == agent_id end) do
        AgentCom.Auth.revoke(agent_id)
        {:ok, token} = AgentCom.Auth.generate(agent_id)

        send_json(conn, 201, %{
          "agent_id" => agent_id,
          "token" => token,
          "hint" => "Use with: node add-agent.js --rejoin --name #{agent_id} --token <token>"
        })
      else
        send_json(conn, 404, %{"error" => "agent_not_found", "agent_id" => agent_id})
      end
    end
  end

  get "/ws/dashboard" do
    conn
    |> WebSockAdapter.upgrade(AgentCom.DashboardSocket, [], timeout: 60_000)
    |> halt()
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(AgentCom.Socket, [], timeout: 60_000)
    |> halt()
  end

  # --- Admin: Hub reset ---

  # Admin agents can be configured via ADMIN_AGENTS env var (comma-separated).
  # For example: ADMIN_AGENTS=flere-imsaho,hub-admin
  post "/api/admin/reset" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      agent_id = conn.assigns[:authenticated_agent]

      if agent_id not in admin_agents() do
        send_json(conn, 403, %{
          "error" => "admin_only",
          "message" => "Only admin agents can reset the hub"
        })
      else
        Logger.warning("hub_reset_triggered", triggered_by: agent_id)

        # Send response before restarting to avoid killing the connection mid-flight
        spawn(fn ->
          Process.sleep(500)
          children = Supervisor.which_children(AgentCom.Supervisor)

          Enum.each(children, fn {id, _pid, _type, _modules} ->
            if id != Bandit do
              Supervisor.terminate_child(AgentCom.Supervisor, id)
              Supervisor.restart_child(AgentCom.Supervisor, id)
            end
          end)
        end)

        send_json(conn, 200, %{"status" => "reset_scheduled", "triggered_by" => agent_id})
      end
    end
  end

  # --- Admin: Runtime log level ---

  put "/api/admin/log-level" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      level = conn.body_params["level"]

      if level in ~w(debug info notice warning error) do
        Logger.configure(level: String.to_existing_atom(level))

        Logger.notice("log_level_changed",
          new_level: level,
          changed_by: conn.assigns[:authenticated_agent]
        )

        send_json(conn, 200, %{"status" => "ok", "level" => level})
      else
        send_json(conn, 422, %{
          "error" => "invalid_level",
          "valid" => ["debug", "info", "notice", "warning", "error"]
        })
      end
    end
  end

  # --- Analytics ---

  get "/api/analytics/summary" do
    send_json(conn, 200, AgentCom.Analytics.summary())
  end

  get "/api/analytics/agents" do
    send_json(conn, 200, %{"agents" => AgentCom.Analytics.stats()})
  end

  get "/api/analytics/agents/:agent_id/hourly" do
    send_json(conn, 200, %{
      "agent_id" => agent_id,
      "hourly" => AgentCom.Analytics.hourly(agent_id)
    })
  end

  get "/dashboard" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, AgentCom.Dashboard.render())
  end

  # --- Admin: Push task to agent (for testing, pre-scheduler) ---

  post "/api/admin/push-task" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_admin_push_task)

      if conn.halted do
        conn
      else
        admin_agent = conn.assigns[:authenticated_agent]

        case Validation.validate_http(:post_admin_push_task, conn.body_params) do
          {:ok, _} ->
            params = conn.body_params
            target_agent_id = params["agent_id"]
            description = params["description"]

            task = %{
              "task_id" => "task-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
              "description" => description,
              "metadata" => params["metadata"] || %{},
              "submitted_by" => admin_agent,
              "submitted_at" => System.system_time(:millisecond)
            }

            case Registry.lookup(AgentCom.AgentRegistry, target_agent_id) do
              [{pid, _meta}] ->
                send(pid, {:push_task, task})

                send_json(conn, 200, %{
                  "status" => "pushed",
                  "task_id" => task["task_id"],
                  "agent_id" => target_agent_id
                })

              [] ->
                send_json(conn, 404, %{
                  "error" => "agent_not_connected",
                  "agent_id" => target_agent_id
                })
            end

          {:error, errors} ->
            send_validation_error(conn, errors)
        end
      end
    end
  end

  # --- Admin: DETS Backup ---

  post "/api/admin/backup" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.DetsBackup.backup_all() do
        {:ok, results} ->
          formatted =
            Enum.map(results, fn
              {:ok, info} ->
                %{
                  "table" => to_string(info.table),
                  "status" => "ok",
                  "path" => info.path,
                  "size" => info.size
                }

              {:error, info} ->
                %{
                  "table" => to_string(info.table),
                  "status" => "error",
                  "reason" => to_string(info.reason)
                }
            end)

          success_count =
            Enum.count(results, fn
              {:ok, _} -> true
              _ -> false
            end)

          send_json(conn, 200, %{
            "status" => "complete",
            "tables_total" => length(results),
            "tables_success" => success_count,
            "results" => formatted
          })
      end
    end
  end

  get "/api/admin/dets-health" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      metrics = AgentCom.DetsBackup.health_metrics()

      formatted_tables =
        Enum.map(metrics.tables, fn t ->
          %{
            "table" => to_string(t.table),
            "record_count" => t.record_count,
            "file_size_bytes" => t.file_size_bytes,
            "fragmentation_ratio" => t.fragmentation_ratio,
            "status" => to_string(t.status)
          }
        end)

      now = System.system_time(:millisecond)

      stale_backup =
        case metrics.last_backup_at do
          nil -> true
          ts -> now - ts > 48 * 60 * 60 * 1000
        end

      high_frag =
        Enum.any?(metrics.tables, fn t -> t.status == :ok and t.fragmentation_ratio > 0.5 end)

      health_status =
        cond do
          stale_backup and high_frag -> "unhealthy"
          stale_backup or high_frag -> "warning"
          true -> "healthy"
        end

      send_json(conn, 200, %{
        "health_status" => health_status,
        "stale_backup" => stale_backup,
        "high_fragmentation" => high_frag,
        "last_backup_at" => metrics.last_backup_at,
        "tables" => formatted_tables
      })
    end
  end

  # --- Admin: DETS Compaction & Restore ---

  @dets_table_atoms %{
    "task_queue" => :task_queue,
    "task_dead_letter" => :task_dead_letter,
    "agent_mailbox" => :agent_mailbox,
    "message_history" => :message_history,
    "agent_channels" => :agent_channels,
    "channel_history" => :channel_history,
    "agentcom_config" => :agentcom_config,
    "thread_messages" => :thread_messages,
    "thread_replies" => :thread_replies,
    "repo_registry" => :repo_registry,
    "goal_backlog" => :goal_backlog
  }

  post "/api/admin/compact" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.DetsBackup.compact_all() do
        {:ok, results} ->
          formatted =
            Enum.map(results, fn r ->
              base = %{"table" => to_string(r.table), "status" => to_string(r.status)}

              base =
                if r[:duration_ms], do: Map.put(base, "duration_ms", r.duration_ms), else: base

              base = if r[:reason], do: Map.put(base, "reason", to_string(r.reason)), else: base
              base = if r[:retried], do: Map.put(base, "retried", r.retried), else: base
              base
            end)

          compacted = Enum.count(results, fn r -> r.status == :compacted end)
          skipped = Enum.count(results, fn r -> r.status == :skipped end)

          send_json(conn, 200, %{
            "status" => "complete",
            "tables_total" => length(results),
            "tables_compacted" => compacted,
            "tables_skipped" => skipped,
            "results" => formatted
          })
      end
    end
  end

  post "/api/admin/compact/:table_name" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Map.get(@dets_table_atoms, table_name) do
        nil ->
          send_json(conn, 404, %{"error" => "unknown_table", "table" => table_name})

        table_atom ->
          case AgentCom.DetsBackup.compact_one(table_atom) do
            {:ok, result} ->
              send_json(conn, 200, %{
                "table" => table_name,
                "status" => to_string(result.status),
                "duration_ms" => result[:duration_ms] || 0
              })
          end
      end
    end
  end

  post "/api/admin/restore/:table_name" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Map.get(@dets_table_atoms, table_name) do
        nil ->
          send_json(conn, 404, %{"error" => "unknown_table", "table" => table_name})

        table_atom ->
          case AgentCom.DetsBackup.restore_table(table_atom) do
            {:ok, info} ->
              send_json(conn, 200, %{
                "status" => "restored",
                "table" => table_name,
                "backup_used" => info[:backup_used],
                "record_count" => get_in(info, [:integrity, :record_count]) || 0,
                "file_size" => get_in(info, [:integrity, :file_size]) || 0
              })

            {:error, reason} ->
              send_json(conn, 500, %{
                "status" => "failed",
                "table" => table_name,
                "error" => inspect(reason)
              })
          end
      end
    end
  end

  # --- Task Queue API ---

  post "/api/tasks" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_task)

      if conn.halted do
        conn
      else
        agent_id = conn.assigns[:authenticated_agent]
        params = conn.body_params

        case Validation.validate_http(:post_task, params) do
          {:ok, _} ->
            case Validation.validate_enrichment_fields(params) do
              {:ok, _} ->
                description = params["description"]

                task_params = %{
                  description: description,
                  priority: params["priority"] || "normal",
                  metadata: params["metadata"] || %{},
                  max_retries: params["max_retries"] || 3,
                  complete_by: params["complete_by"],
                  needed_capabilities: params["needed_capabilities"] || [],
                  submitted_by: agent_id,
                  repo: params["repo"],
                  branch: params["branch"],
                  file_hints: params["file_hints"] || [],
                  success_criteria: params["success_criteria"] || [],
                  verification_steps: params["verification_steps"] || [],
                  complexity_tier: params["complexity_tier"],
                  max_verification_retries: params["max_verification_retries"],
                  skip_verification: params["skip_verification"],
                  verification_timeout_ms: params["verification_timeout_ms"],
                  depends_on: params["depends_on"] || [],
                  goal_id: params["goal_id"],
                  assign_to: params["assign_to"]
                }

                case AgentCom.TaskQueue.submit(task_params) do
                  {:ok, task} ->
                    warnings =
                      case Validation.verify_step_soft_limit(params) do
                        :ok -> []
                        {:warn, msg} -> [msg]
                      end

                    response = %{
                      "status" => "queued",
                      "task_id" => task.id,
                      "priority" => task.priority,
                      "created_at" => task.created_at
                    }

                    response =
                      if warnings != [],
                        do: Map.put(response, "warnings", warnings),
                        else: response

                    send_json(conn, 201, response)
                end

              {:error, errors} ->
                send_validation_error(conn, errors)
            end

          {:error, errors} ->
            send_validation_error(conn, errors)
        end
      end
    end
  end

  get "/api/tasks" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :get_tasks)

      if conn.halted do
        conn
      else
        opts = []

        opts =
          if s = conn.params["status"] do
            try do
              [{:status, String.to_existing_atom(s)} | opts]
            rescue
              ArgumentError -> opts
            end
          else
            opts
          end

        opts = if p = conn.params["priority"], do: [{:priority, p} | opts], else: opts
        opts = if a = conn.params["assigned_to"], do: [{:assigned_to, a} | opts], else: opts
        opts = if g = conn.params["goal_id"], do: [{:goal_id, g} | opts], else: opts

        tasks = AgentCom.TaskQueue.list(opts)
        formatted = Enum.map(tasks, &format_task/1)
        send_json(conn, 200, %{"tasks" => formatted, "count" => length(formatted)})
      end
    end
  end

  # IMPORTANT: /dead-letter and /stats MUST be defined BEFORE /:task_id
  get "/api/tasks/dead-letter" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      tasks = AgentCom.TaskQueue.list_dead_letter()
      formatted = Enum.map(tasks, &format_task/1)
      send_json(conn, 200, %{"tasks" => formatted, "count" => length(formatted)})
    end
  end

  get "/api/tasks/stats" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      stats = AgentCom.TaskQueue.stats()
      send_json(conn, 200, stats)
    end
  end

  get "/api/tasks/:task_id" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :get_task_detail)

      if conn.halted do
        conn
      else
        case AgentCom.TaskQueue.get(task_id) do
          {:ok, task} ->
            send_json(conn, 200, format_task(task))

          {:error, :not_found} ->
            send_json(conn, 404, %{"error" => "task_not_found", "task_id" => task_id})
        end
      end
    end
  end

  post "/api/tasks/:task_id/retry" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_task_retry)

      if conn.halted do
        conn
      else
        case AgentCom.TaskQueue.retry_dead_letter(task_id) do
          {:ok, task} ->
            send_json(conn, 200, %{
              "status" => "requeued",
              "task_id" => task.id,
              "priority" => task.priority
            })

          {:error, :not_found} ->
            send_json(conn, 404, %{"error" => "task_not_found", "task_id" => task_id})
        end
      end
    end
  end

  post "/api/tasks/:task_id/cancel" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.TaskQueue.cancel_task(task_id) do
        {:ok, task} ->
          send_json(conn, 200, %{
            "status" => "cancelled",
            "task_id" => task.id,
            "previous_status" => to_string(task.status)
          })

        {:error, :not_found} ->
          send_json(conn, 404, %{"error" => "task_not_found", "task_id" => task_id})
      end
    end
  end

  # --- Goal Backlog API (auth required) ---

  # IMPORTANT: /stats MUST be defined BEFORE /:goal_id to avoid "stats" being captured as :goal_id
  get "/api/goals/stats" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      stats = AgentCom.GoalBacklog.stats()
      send_json(conn, 200, stats)
    end
  end

  post "/api/goals" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Validation.validate_http(:post_goal, conn.body_params) do
        {:ok, _} ->
          params = %{
            description: conn.body_params["description"],
            success_criteria: conn.body_params["success_criteria"],
            priority: conn.body_params["priority"] || "normal",
            source: conn.body_params["source"] || "api",
            tags: conn.body_params["tags"] || [],
            repo: conn.body_params["repo"],
            file_hints: conn.body_params["file_hints"] || [],
            metadata: conn.body_params["metadata"] || %{},
            depends_on: conn.body_params["depends_on"] || []
          }

          {:ok, goal} = AgentCom.GoalBacklog.submit(params)

          send_json(conn, 201, %{
            "status" => "submitted",
            "goal_id" => goal.id,
            "priority" => goal.priority,
            "created_at" => goal.created_at
          })

        {:error, errors} ->
          send_validation_error(conn, errors)
      end
    end
  end

  get "/api/goals" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      filters = %{}

      filters =
        if s = conn.params["status"],
          do: Map.put(filters, :status, String.to_atom(s)),
          else: filters

      filters = if p = conn.params["priority"], do: Map.put(filters, :priority, p), else: filters

      goals = AgentCom.GoalBacklog.list(filters)
      formatted = Enum.map(goals, &format_goal/1)
      send_json(conn, 200, %{"goals" => formatted})
    end
  end

  get "/api/goals/:goal_id" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.GoalBacklog.get(goal_id) do
        {:ok, goal} ->
          send_json(conn, 200, format_goal(goal))

        {:error, :not_found} ->
          send_json(conn, 404, %{"error" => "goal_not_found"})
      end
    end
  end

  patch "/api/goals/:goal_id/transition" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Validation.validate_http(:patch_goal_transition, conn.body_params) do
        {:ok, _} ->
          status_atom = String.to_atom(conn.body_params["status"])
          opts = []
          opts = if r = conn.body_params["reason"], do: [{:reason, r} | opts], else: opts

          opts =
            if ids = conn.body_params["child_task_ids"],
              do: [{:child_task_ids, ids} | opts],
              else: opts

          case AgentCom.GoalBacklog.transition(goal_id, status_atom, opts) do
            {:ok, goal} ->
              send_json(conn, 200, format_goal(goal))

            {:error, {:invalid_transition, from, to}} ->
              send_json(conn, 422, %{
                "error" => "invalid_transition",
                "detail" => "Cannot transition from #{from} to #{to}"
              })

            {:error, :not_found} ->
              send_json(conn, 404, %{"error" => "goal_not_found"})
          end

        {:error, errors} ->
          send_validation_error(conn, errors)
      end
    end
  end

  # --- Hub FSM API ---

  post "/api/hub/pause" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.HubFSM.pause() do
        :ok -> send_json(conn, 200, %{"status" => "paused"})
        {:error, :already_paused} -> send_json(conn, 200, %{"status" => "already_paused"})
      end
    end
  end

  post "/api/hub/resume" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.HubFSM.resume() do
        :ok -> send_json(conn, 200, %{"status" => "resumed"})
        {:error, :not_paused} -> send_json(conn, 200, %{"status" => "not_paused"})
      end
    end
  end

  get "/api/hub/state" do
    try do
      state = AgentCom.HubFSM.get_state()

      send_json(conn, 200, %{
        "fsm_state" => to_string(state.fsm_state),
        "paused" => state.paused,
        "cycle_count" => state.cycle_count,
        "transition_count" => state.transition_count,
        "last_state_change" => state.last_state_change
      })
    catch
      :exit, _ -> send_json(conn, 503, %{"error" => "hub_fsm not available"})
    end
  end

  get "/api/hub/history" do
    limit =
      case conn.params["limit"] do
        nil ->
          50

        l ->
          parsed = String.to_integer(l)
          min(parsed, 200)
      end

    try do
      transitions = AgentCom.HubFSM.history(limit: limit)

      formatted =
        Enum.map(transitions, fn t ->
          %{
            "from_state" => to_string(t.from_state),
            "to_state" => to_string(t.to_state),
            "reason" => to_string(t.reason),
            "timestamp" => t.timestamp,
            "cycle_count" => t.cycle_count
          }
        end)

      send_json(conn, 200, %{"transitions" => formatted})
    catch
      :exit, _ -> send_json(conn, 503, %{"error" => "hub_fsm not available"})
    end
  end

  # --- Webhook API ---

  # IMPORTANT: GET /history MUST be defined BEFORE POST to avoid path conflicts
  get "/api/webhooks/github/history" do
    AgentCom.WebhookHistory.init_table()

    limit = case conn.params["limit"] do
      nil -> 50
      l -> min(String.to_integer(l), 100)
    end

    events = AgentCom.WebhookHistory.list(limit: limit)

    formatted = Enum.map(events, fn e ->
      Map.new(e, fn {k, v} -> {to_string(k), v} end)
    end)

    send_json(conn, 200, %{"events" => formatted})
  end

  post "/api/webhooks/github" do
    case AgentCom.WebhookVerifier.verify_signature(conn) do
      {:ok, conn} ->
        event_type = Plug.Conn.get_req_header(conn, "x-github-event") |> List.first()
        delivery_id = Plug.Conn.get_req_header(conn, "x-github-delivery") |> List.first()

        Logger.info("webhook_received",
          event_type: event_type,
          delivery_id: delivery_id
        )

        handle_github_event(conn, event_type, conn.body_params, delivery_id)

      {:error, reason} ->
        Logger.warning("webhook_signature_failed", reason: inspect(reason))
        send_json(conn, 401, %{"error" => "invalid_signature"})
    end
  end

  # --- Webhook Secret Config (auth required) ---

  put "/api/config/webhook-secret" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      secret = conn.body_params["secret"]

      if is_binary(secret) and byte_size(secret) >= 16 do
        :ok = AgentCom.Config.put(:github_webhook_secret, secret)
        send_json(conn, 200, %{"status" => "updated"})
      else
        send_json(conn, 422, %{"error" => "secret must be a string of at least 16 characters"})
      end
    end
  end

  # --- Metrics API (no auth -- same visibility as dashboard, rate limited) ---

  get "/api/metrics" do
    conn = AgentCom.Plugs.RateLimit.call(conn, action: :get_metrics)

    if conn.halted do
      conn
    else
      snapshot = AgentCom.MetricsCollector.snapshot()
      send_json(conn, 200, snapshot)
    end
  end

  # --- Alerts API ---

  get "/api/alerts" do
    alerts = AgentCom.Alerter.active_alerts()

    send_json(conn, 200, %{
      "alerts" => alerts,
      "timestamp" => System.system_time(:millisecond)
    })
  end

  post "/api/alerts/:rule_id/acknowledge" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.Alerter.acknowledge(rule_id) do
        :ok -> send_json(conn, 200, %{"status" => "acknowledged", "rule_id" => rule_id})
        {:error, :not_found} -> send_json(conn, 404, %{"error" => "alert_not_found"})
      end
    end
  end

  # --- Alert Thresholds Config (auth required) ---

  get "/api/config/alert-thresholds" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      thresholds = AgentCom.Config.get(:alert_thresholds) || AgentCom.Alerter.default_thresholds()
      send_json(conn, 200, thresholds)
    end
  end

  put "/api/config/alert-thresholds" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      thresholds = conn.body_params
      :ok = AgentCom.Config.put(:alert_thresholds, thresholds)
      send_json(conn, 200, %{"status" => "updated", "effective" => "next_check_cycle"})
    end
  end

  # --- Admin: Rate limit overrides & whitelist (auth required) ---

  # IMPORTANT: Whitelist routes MUST be defined BEFORE the parameterized :agent_id route,
  # otherwise "whitelist" would be captured as an agent_id parameter.

  get "/api/admin/rate-limits" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      defaults = AgentCom.RateLimiter.get_defaults()
      overrides = AgentCom.RateLimiter.get_overrides()
      whitelist = AgentCom.RateLimiter.get_whitelist()

      # Convert atom keys to strings for JSON serialization
      defaults_json = Map.new(defaults, fn {tier, v} -> {to_string(tier), v} end)

      overrides_json =
        Map.new(overrides, fn {agent_id, tiers} ->
          {agent_id, Map.new(tiers, fn {tier, v} -> {to_string(tier), v} end)}
        end)

      send_json(conn, 200, %{
        "defaults" => defaults_json,
        "overrides" => overrides_json,
        "whitelist" => whitelist
      })
    end
  end

  get "/api/admin/rate-limits/whitelist" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      whitelist = AgentCom.RateLimiter.get_whitelist()
      send_json(conn, 200, %{"whitelist" => whitelist})
    end
  end

  put "/api/admin/rate-limits/whitelist" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      agent_ids = conn.body_params["agent_ids"] || []

      if is_list(agent_ids) and Enum.all?(agent_ids, &is_binary/1) do
        AgentCom.RateLimiter.update_whitelist(agent_ids)
        send_json(conn, 200, %{"status" => "updated", "whitelist" => agent_ids})
      else
        send_json(conn, 422, %{
          "error" => "invalid_whitelist",
          "detail" => "agent_ids must be a list of strings"
        })
      end
    end
  end

  post "/api/admin/rate-limits/whitelist" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      agent_id_to_add = conn.body_params["agent_id"]

      if is_binary(agent_id_to_add) and agent_id_to_add != "" do
        AgentCom.RateLimiter.add_to_whitelist(agent_id_to_add)
        send_json(conn, 200, %{"status" => "added", "agent_id" => agent_id_to_add})
      else
        send_json(conn, 422, %{
          "error" => "invalid_agent_id",
          "detail" => "agent_id must be a non-empty string"
        })
      end
    end
  end

  delete "/api/admin/rate-limits/whitelist/:agent_id" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      AgentCom.RateLimiter.remove_from_whitelist(agent_id)
      send_json(conn, 200, %{"status" => "removed", "agent_id" => agent_id})
    end
  end

  put "/api/admin/rate-limits/:agent_id" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params

      case parse_override_params(params) do
        {:ok, parsed} ->
          AgentCom.RateLimiter.set_override(agent_id, parsed)

          send_json(conn, 200, %{
            "status" => "updated",
            "agent_id" => agent_id,
            "overrides" => params
          })

        {:error, reason} ->
          send_json(conn, 422, %{"error" => "invalid_overrides", "detail" => reason})
      end
    end
  end

  delete "/api/admin/rate-limits/:agent_id" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      AgentCom.RateLimiter.remove_override(agent_id)
      send_json(conn, 200, %{"status" => "removed", "agent_id" => agent_id})
    end
  end

  # --- Admin: LLM Registry routes (auth required) ---

  get "/api/admin/llm-registry" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      endpoints = AgentCom.LlmRegistry.list_endpoints()
      send_json(conn, 200, %{endpoints: endpoints})
    end
  end

  # IMPORTANT: /snapshot MUST be defined BEFORE /:id to avoid "snapshot" being captured as :id
  get "/api/admin/llm-registry/snapshot" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      snapshot = AgentCom.LlmRegistry.snapshot()
      send_json(conn, 200, snapshot)
    end
  end

  get "/api/admin/llm-registry/:id" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.LlmRegistry.get_endpoint(id) do
        {:ok, endpoint} -> send_json(conn, 200, endpoint)
        {:error, :not_found} -> send_json(conn, 404, %{error: "endpoint_not_found"})
      end
    end
  end

  post "/api/admin/llm-registry" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      body = conn.body_params

      params = %{
        host: body["host"],
        port: body["port"] || 11434,
        name: body["name"] || "#{body["host"]}:#{body["port"] || 11434}",
        source: :manual
      }

      case AgentCom.LlmRegistry.register_endpoint(params) do
        {:ok, endpoint} -> send_json(conn, 201, endpoint)
        {:error, reason} -> send_json(conn, 400, %{error: to_string(reason)})
      end
    end
  end

  delete "/api/admin/llm-registry/:id" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.LlmRegistry.remove_endpoint(id) do
        :ok -> send_json(conn, 200, %{status: "removed", id: id})
        {:error, :not_found} -> send_json(conn, 404, %{error: "endpoint_not_found"})
      end
    end
  end

  # --- Admin: Repo Registry routes (auth required) ---

  get "/api/admin/repo-registry" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      repos = AgentCom.RepoRegistry.list_repos()
      send_json(conn, 200, %{"repos" => repos})
    end
  end

  post "/api/admin/repo-registry" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Validation.validate_http(:post_repo, conn.body_params) do
        {:ok, _} ->
          params = %{
            url: conn.body_params["url"],
            name: conn.body_params["name"]
          }

          case AgentCom.RepoRegistry.add_repo(params) do
            {:ok, repo} ->
              send_json(conn, 201, repo)

            {:error, :already_exists} ->
              send_json(conn, 409, %{"error" => "repo_already_registered"})
          end

        {:error, errors} ->
          send_validation_error(conn, errors)
      end
    end
  end

  delete "/api/admin/repo-registry/:repo_id" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case AgentCom.RepoRegistry.remove_repo(repo_id) do
        :ok -> send_json(conn, 200, %{"status" => "removed"})
        {:error, :not_found} -> send_json(conn, 404, %{"error" => "not_found"})
      end
    end
  end

  put "/api/admin/repo-registry/:repo_id/move-up" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      {:ok, repos} = AgentCom.RepoRegistry.move_up(repo_id)
      send_json(conn, 200, %{"repos" => repos})
    end
  end

  put "/api/admin/repo-registry/:repo_id/move-down" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      {:ok, repos} = AgentCom.RepoRegistry.move_down(repo_id)
      send_json(conn, 200, %{"repos" => repos})
    end
  end

  put "/api/admin/repo-registry/:repo_id/pause" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      AgentCom.RepoRegistry.set_status(repo_id, :paused)
      send_json(conn, 200, %{"status" => "paused"})
    end
  end

  put "/api/admin/repo-registry/:repo_id/unpause" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      AgentCom.RepoRegistry.set_status(repo_id, :active)
      send_json(conn, 200, %{"status" => "active"})
    end
  end

  # --- Dashboard API (no auth -- local network only, NOT rate limited) ---

  get "/api/dashboard/state" do
    snapshot = AgentCom.DashboardState.snapshot()
    send_json(conn, 200, snapshot)
  end

  get "/sw.js" do
    conn
    |> put_resp_content_type("application/javascript")
    |> put_resp_header("service-worker-allowed", "/")
    |> send_resp(200, AgentCom.Dashboard.service_worker())
  end

  get "/api/dashboard/vapid-key" do
    key = AgentCom.DashboardNotifier.get_vapid_public_key()
    send_json(conn, 200, %{"vapid_public_key" => key})
  end

  post "/api/dashboard/push-subscribe" do
    case Validation.validate_http(:post_push_subscribe, conn.body_params) do
      {:ok, _} ->
        subscription = conn.body_params
        AgentCom.DashboardNotifier.subscribe(subscription)
        send_json(conn, 200, %{"status" => "subscribed"})

      {:error, errors} ->
        send_validation_error(conn, errors)
    end
  end

  # --- Onboarding: Agent registration (no auth, rate limited to prevent spam) ---

  post "/api/onboard/register" do
    conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_onboard_register)

    if conn.halted do
      conn
    else
      case Validation.validate_http(:post_onboard_register, conn.body_params) do
        {:ok, _} ->
          agent_id = conn.body_params["agent_id"]

          # Additional check: non-empty string (schema ensures string type, but guard against "")
          if agent_id == "" do
            send_validation_error(conn, [
              %{field: "agent_id", error: :required, detail: "agent_id must not be empty"}
            ])
          else
            # Check for existing agent with same name
            existing = AgentCom.Auth.list()
            already_registered = Enum.any?(existing, fn entry -> entry.agent_id == agent_id end)

            if already_registered do
              send_json(conn, 409, %{"error" => "agent_id already registered"})
            else
              {:ok, token} = AgentCom.Auth.generate(agent_id)
              default_repo = AgentCom.Config.get(:default_repo)
              host = conn.host
              port = conn.port
              hub_ws_url = "ws://#{host}:#{port}/ws"
              hub_api_url = "http://#{host}:#{port}"

              send_json(conn, 201, %{
                "agent_id" => agent_id,
                "token" => token,
                "hub_ws_url" => hub_ws_url,
                "hub_api_url" => hub_api_url,
                "default_repo" => default_repo
              })
            end
          end

        {:error, errors} ->
          send_validation_error(conn, errors)
      end
    end
  end

  # --- Config: Default repository URL ---

  get "/api/config/default-repo" do
    value = AgentCom.Config.get(:default_repo)

    case value do
      nil -> send_json(conn, 200, %{"default_repo" => nil, "configured" => false})
      _ -> send_json(conn, 200, %{"default_repo" => value, "configured" => true})
    end
  end

  put "/api/config/default-repo" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Validation.validate_http(:put_default_repo, conn.body_params) do
        {:ok, _} ->
          url = conn.body_params["url"]
          :ok = AgentCom.Config.put(:default_repo, url)
          send_json(conn, 200, %{"status" => "ok", "default_repo" => url})

        {:error, errors} ->
          send_validation_error(conn, errors)
      end
    end
  end

  # --- Admin: Repo Scanner (auth required) ---

  @valid_scan_categories ~w(tokens ips workspace_files personal_refs)a

  post "/api/admin/repo-scanner/scan" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params

      opts =
        case parse_scan_categories(params["categories"]) do
          {:ok, cats} ->
            [categories: cats]

          :all ->
            []

          {:error, _reason} ->
            :error_categories
        end

      if opts == :error_categories do
        send_json(conn, 422, %{
          "error" => "invalid_categories",
          "valid" => Enum.map(@valid_scan_categories, &to_string/1)
        })
      else
        case params["repo_path"] do
          nil ->
            {:ok, reports} = AgentCom.RepoScanner.scan_all(opts)
            send_json(conn, 200, %{"reports" => Enum.map(reports, &format_scan_report/1)})

          repo_path when is_binary(repo_path) ->
            case AgentCom.RepoScanner.scan_repo(repo_path, opts) do
              {:ok, report} ->
                send_json(conn, 200, format_scan_report(report))

              {:error, reason} ->
                send_json(conn, 422, %{"error" => inspect(reason)})
            end
        end
      end
    end
  end

  # --- Schema Discovery (no auth, NOT rate limited) ---

  get "/api/schemas" do
    schemas = AgentCom.Validation.Schemas.to_json()
    send_json(conn, 200, %{"schemas" => schemas, "version" => "1.0"})
  end

  match _ do
    send_json(conn, 404, %{"error" => "not_found"})
  end

  defp get_token(conn) do
    # Check Authorization header first, then query param
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> conn.params["token"]
    end
  end

  defp format_task(task) do
    %{
      "id" => task.id,
      "description" => task.description,
      "metadata" => task.metadata,
      "priority" => task.priority,
      "status" => to_string(task.status),
      "assigned_to" => task.assigned_to,
      "assigned_at" => task.assigned_at,
      "generation" => task.generation,
      "retry_count" => task.retry_count,
      "max_retries" => task.max_retries,
      "needed_capabilities" => Map.get(task, :needed_capabilities, []),
      "last_error" => Map.get(task, :last_error),
      "complete_by" => task.complete_by,
      "result" => task.result,
      "tokens_used" => task.tokens_used,
      "submitted_by" => task.submitted_by,
      "created_at" => task.created_at,
      "updated_at" => task.updated_at,
      "history" =>
        Enum.map(task.history || [], fn
          {event, timestamp, details} ->
            %{
              "event" => to_string(event),
              "timestamp" => timestamp,
              "details" => format_details(details)
            }

          other ->
            other
        end),
      "repo" => Map.get(task, :repo),
      "branch" => Map.get(task, :branch),
      "file_hints" => Map.get(task, :file_hints, []),
      "success_criteria" => Map.get(task, :success_criteria, []),
      "verification_steps" => Map.get(task, :verification_steps, []),
      "complexity" => format_complexity(Map.get(task, :complexity)),
      "verification_report" => Map.get(task, :verification_report),
      "verification_history" => Map.get(task, :verification_history, []),
      "max_verification_retries" => Map.get(task, :max_verification_retries, 0),
      "routing_decision" => format_routing_decision(Map.get(task, :routing_decision)),
      "depends_on" => Map.get(task, :depends_on, []),
      "goal_id" => Map.get(task, :goal_id)
    }
  end

  defp format_goal(goal) when is_map(goal) do
    %{
      "id" => goal.id,
      "description" => goal.description,
      "success_criteria" => Map.get(goal, :success_criteria, []),
      "status" => to_string(goal.status),
      "priority" => goal.priority,
      "source" => Map.get(goal, :source),
      "tags" => Map.get(goal, :tags, []),
      "repo" => Map.get(goal, :repo),
      "file_hints" => Map.get(goal, :file_hints, []),
      "metadata" => Map.get(goal, :metadata, %{}),
      "depends_on" => Map.get(goal, :depends_on, []),
      "child_task_ids" => Map.get(goal, :child_task_ids, []),
      "history" =>
        Enum.map(Map.get(goal, :history, []), fn
          {event, timestamp, details} ->
            %{
              "event" => to_string(event),
              "timestamp" => timestamp,
              "details" => format_details(details)
            }

          other ->
            other
        end),
      "created_at" => goal.created_at,
      "updated_at" => Map.get(goal, :updated_at)
    }
  end

  defp format_complexity(nil), do: nil

  defp format_complexity(c) when is_map(c) do
    %{
      "effective_tier" => to_string(Map.get(c, :effective_tier)),
      "explicit_tier" =>
        case Map.get(c, :explicit_tier) do
          nil -> nil
          t -> to_string(t)
        end,
      "source" => to_string(Map.get(c, :source)),
      "inferred" =>
        case Map.get(c, :inferred) do
          nil ->
            nil

          inf ->
            %{
              "tier" => to_string(Map.get(inf, :tier)),
              "confidence" => Map.get(inf, :confidence)
            }
        end
    }
  end

  defp format_routing_decision(nil), do: nil

  defp format_routing_decision(rd) when is_map(rd) do
    %{
      "effective_tier" => safe_to_string(Map.get(rd, :effective_tier)),
      "target_type" => safe_to_string(Map.get(rd, :target_type)),
      "selected_endpoint" => safe_to_string(Map.get(rd, :selected_endpoint)),
      "selected_model" => safe_to_string(Map.get(rd, :selected_model)),
      "fallback_used" => Map.get(rd, :fallback_used, false),
      "fallback_from_tier" => safe_to_string(Map.get(rd, :fallback_from_tier)),
      "fallback_reason" => safe_to_string(Map.get(rd, :fallback_reason)),
      "candidate_count" => Map.get(rd, :candidate_count),
      "classification_reason" => safe_to_string(Map.get(rd, :classification_reason)),
      "estimated_cost_tier" => safe_to_string(Map.get(rd, :estimated_cost_tier)),
      "decided_at" => Map.get(rd, :decided_at)
    }
  end

  defp safe_to_string(nil), do: nil
  defp safe_to_string(val) when is_atom(val), do: to_string(val)
  defp safe_to_string(val) when is_binary(val), do: val
  defp safe_to_string(val), do: inspect(val)

  defp format_details(details) when is_map(details) do
    Map.new(details, fn {k, v} -> {to_string(k), v} end)
  end

  defp format_details(details), do: details

  defp send_validation_error(conn, errors) do
    formatted = Validation.format_errors(errors)

    send_json(conn, 422, %{
      "error" => "validation_failed",
      "errors" => formatted
    })
  end

  defp admin_agents do
    System.get_env("ADMIN_AGENTS", "") |> String.split(",", trim: true)
  end

  defp parse_override_params(params) do
    tiers = [:light, :normal, :heavy]

    parsed =
      Enum.reduce_while(tiers, %{}, fn tier, acc ->
        tier_str = to_string(tier)

        case Map.get(params, tier_str) do
          nil ->
            {:cont, acc}

          %{"capacity" => cap, "refill_rate_per_min" => rate}
          when is_number(cap) and is_number(rate) ->
            # Convert human-readable to internal units: capacity * 1000, rate * 1000 / 60_000
            internal_cap = trunc(cap * 1000)
            internal_rate = rate * 1000 / 60_000
            {:cont, Map.put(acc, tier, %{capacity: internal_cap, refill_rate: internal_rate})}

          _ ->
            {:halt, {:error, "each tier must have numeric 'capacity' and 'refill_rate_per_min'"}}
        end
      end)

    case parsed do
      {:error, _} = err ->
        err

      map when map == %{} ->
        {:error, "at least one tier (light, normal, heavy) must be specified"}

      map ->
        {:ok, map}
    end
  end

  defp parse_scan_categories(nil), do: :all

  defp parse_scan_categories(cats) when is_list(cats) do
    parsed =
      Enum.reduce_while(cats, [], fn cat, acc when is_binary(cat) ->
        atom = String.to_atom(cat)

        if atom in @valid_scan_categories do
          {:cont, [atom | acc]}
        else
          {:halt, {:error, "unknown category: #{cat}"}}
        end
      end)

    case parsed do
      {:error, _} = err -> err
      list when is_list(list) -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_scan_categories(_), do: :all

  defp format_scan_report(report) do
    # Convert atom keys to string keys for JSON, and findings structs to maps
    by_category =
      report.summary.by_category
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

    findings =
      Enum.map(report.findings, fn f ->
        %{
          "file_path" => f.file_path,
          "line_number" => f.line_number,
          "category" => to_string(f.category),
          "pattern_name" => f.pattern_name,
          "matched_text" => f.matched_text,
          "severity" => to_string(f.severity),
          "replacement" => f.replacement,
          "action" => to_string(f.action)
        }
      end)

    %{
      "repo_path" => report.repo_path,
      "scanned_at" => report.scanned_at,
      "scan_duration_ms" => report.scan_duration_ms,
      "files_scanned" => report.files_scanned,
      "findings" => findings,
      "summary" => %{
        "critical" => report.summary.critical,
        "warning" => report.summary.warning,
        "by_category" => by_category
      },
      "blocking" => report.blocking,
      "gitignore_recommendations" => report.gitignore_recommendations,
      "cleanup_tasks" =>
        Enum.map(report.cleanup_tasks, fn task ->
          Map.new(task, fn {k, v} -> {to_string(k), v} end)
        end)
    }
  end

  # --- GitHub Webhook Helpers ---

  defp handle_github_event(conn, "push", payload, delivery_id) do
    repo_full_name = get_in(payload, ["repository", "full_name"])
    ref = payload["ref"]
    head_commit_id = get_in(payload, ["head_commit", "id"])

    case match_active_repo(repo_full_name) do
      {:ok, repo} ->
        reason = "push to #{repo_full_name} ref=#{ref} commit=#{head_commit_id}"
        wake_fsm(:improving, reason)

        AgentCom.WebhookHistory.record(%{
          event_type: "push",
          repo: repo_full_name,
          ref: ref,
          commit: head_commit_id,
          delivery_id: delivery_id,
          action: "accepted",
          repo_id: repo.id
        })

        Logger.info("webhook_push_accepted",
          repo: repo_full_name,
          ref: ref,
          commit: head_commit_id
        )

        send_json(conn, 200, %{
          "status" => "accepted",
          "event" => "push",
          "repo" => repo_full_name
        })

      :not_active ->
        AgentCom.WebhookHistory.record(%{
          event_type: "push",
          repo: repo_full_name,
          ref: ref,
          delivery_id: delivery_id,
          action: "ignored",
          reason: "repo not active"
        })

        Logger.info("webhook_push_ignored",
          repo: repo_full_name,
          reason: "repo not active"
        )

        send_json(conn, 200, %{
          "status" => "ignored",
          "reason" => "repo not active"
        })
    end
  end

  defp handle_github_event(conn, "pull_request", payload, delivery_id) do
    action = payload["action"]
    merged = get_in(payload, ["pull_request", "merged"])

    if action == "closed" and merged == true do
      repo_full_name = get_in(payload, ["repository", "full_name"])
      pr_number = get_in(payload, ["pull_request", "number"])
      base_branch = get_in(payload, ["pull_request", "base", "ref"])

      case match_active_repo(repo_full_name) do
        {:ok, repo} ->
          reason = "PR ##{pr_number} merged to #{base_branch} on #{repo_full_name}"
          wake_fsm(:improving, reason)

          AgentCom.WebhookHistory.record(%{
            event_type: "pull_request",
            repo: repo_full_name,
            pr_number: pr_number,
            base_branch: base_branch,
            delivery_id: delivery_id,
            action: "accepted",
            repo_id: repo.id
          })

          Logger.info("webhook_pr_merge_accepted",
            repo: repo_full_name,
            pr_number: pr_number,
            base_branch: base_branch
          )

          send_json(conn, 200, %{
            "status" => "accepted",
            "event" => "pull_request_merged",
            "repo" => repo_full_name,
            "pr_number" => pr_number
          })

        :not_active ->
          AgentCom.WebhookHistory.record(%{
            event_type: "pull_request",
            repo: repo_full_name,
            pr_number: pr_number,
            delivery_id: delivery_id,
            action: "ignored",
            reason: "repo not active"
          })

          Logger.info("webhook_pr_merge_ignored",
            repo: repo_full_name,
            reason: "repo not active"
          )

          send_json(conn, 200, %{
            "status" => "ignored",
            "reason" => "repo not active"
          })
      end
    else
      AgentCom.WebhookHistory.record(%{
        event_type: "pull_request",
        pr_action: action,
        merged: merged,
        delivery_id: delivery_id,
        action: "ignored",
        reason: "not a merge"
      })

      send_json(conn, 200, %{
        "status" => "ignored",
        "reason" => "not a merge"
      })
    end
  end

  defp handle_github_event(conn, event_type, _payload, delivery_id) do
    AgentCom.WebhookHistory.record(%{
      event_type: event_type,
      delivery_id: delivery_id,
      action: "ignored",
      reason: "unhandled event type"
    })

    Logger.info("webhook_event_ignored",
      event_type: event_type,
      reason: "unhandled event type"
    )

    send_json(conn, 200, %{
      "status" => "ignored",
      "reason" => "unhandled event type"
    })
  end

  defp match_active_repo(full_name) when is_binary(full_name) do
    target_id = String.replace(full_name, "/", "-")

    repos =
      try do
        AgentCom.RepoRegistry.list_repos()
      catch
        :exit, _ -> []
      end

    case Enum.find(repos, fn r -> r.id == target_id and r.status == :active end) do
      nil -> :not_active
      repo -> {:ok, repo}
    end
  end

  defp match_active_repo(_), do: :not_active

  defp wake_fsm(target_state, reason) do
    try do
      case AgentCom.HubFSM.force_transition(target_state, reason) do
        :ok ->
          Logger.info("webhook_fsm_wake",
            target_state: target_state,
            reason: reason
          )

        {:error, :invalid_transition} ->
          Logger.debug("webhook_fsm_already_active",
            target_state: target_state,
            reason: reason
          )
      end
    catch
      :exit, _ ->
        Logger.warning("webhook_fsm_unavailable",
          target_state: target_state,
          reason: reason
        )
    end
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
