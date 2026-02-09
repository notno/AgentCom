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
  - GET    /api/channels          — List all channels
  - POST   /api/channels          — Create a channel (auth required)
  - GET    /api/channels/:ch      — Channel info + subscribers
  - POST   /api/channels/:ch/subscribe   — Subscribe to channel (auth required)
  - POST   /api/channels/:ch/unsubscribe — Unsubscribe (auth required)
  - POST   /api/channels/:ch/publish     — Publish to channel (auth required)
  - GET    /api/channels/:ch/history     — Channel message history
  - GET    /api/agents/:id/subscriptions — List agent's channel subscriptions
  - WS     /ws                   — WebSocket for agent connections
  """
  use Plug.Router

  plug Plug.Logger
  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  plug :dispatch

  get "/health" do
    agents = AgentCom.Presence.list()
    send_json(conn, 200, %{
      "status" => "ok",
      "service" => "agent_com",
      "agents_connected" => length(agents)
    })
  end

  get "/api/agents" do
    agents = AgentCom.Presence.list()
    |> Enum.map(fn a ->
      %{
        "agent_id" => a.agent_id,
        "name" => a[:name],
        "status" => a[:status],
        "capabilities" => a[:capabilities] || [],
        "connected_at" => a[:connected_at]
      }
    end)

    send_json(conn, 200, %{"agents" => agents})
  end

  post "/api/message" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
    if conn.halted do
      conn
    else
      authenticated_agent = conn.assigns[:authenticated_agent]
      params = conn.body_params
      # Use authenticated agent_id as "from" — ignore any spoofed "from" field
      from = authenticated_agent

      case params do
        %{"payload" => payload} ->
          msg = AgentCom.Message.new(%{
            from: from,
            to: params["to"],
            type: params["type"] || "chat",
            payload: payload,
            reply_to: params["reply_to"]
          })

          case AgentCom.Router.route(msg) do
            {:ok, _} ->
              send_json(conn, 200, %{"status" => "sent", "id" => msg.id})
            {:error, reason} ->
              send_json(conn, 422, %{"status" => "failed", "error" => to_string(reason)})
          end

        _ ->
          send_json(conn, 400, %{"error" => "missing required field: payload"})
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
      case conn.body_params do
        %{"heartbeat_interval_ms" => ms} when is_integer(ms) and ms > 0 ->
          :ok = AgentCom.Config.put(:heartbeat_interval_ms, ms)
          send_json(conn, 200, %{"heartbeat_interval_ms" => ms, "status" => "updated"})
        _ ->
          send_json(conn, 400, %{"error" => "missing or invalid field: heartbeat_interval_ms (positive integer)"})
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
      case conn.body_params do
        %{"mailbox_ttl_ms" => ms} when is_integer(ms) and ms > 0 ->
          AgentCom.Mailbox.set_ttl(ms)
          send_json(conn, 200, %{"mailbox_ttl_ms" => ms, "status" => "updated"})
        _ ->
          send_json(conn, 400, %{"error" => "missing or invalid field: mailbox_ttl_ms (positive integer)"})
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
        send_json(conn, 200, %{"parent" => message_id, "replies" => replies, "count" => length(replies)})
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
    since = case conn.params["since"] do
      nil -> 0
      s -> String.to_integer(s)
    end

    token = get_token(conn)
    case AgentCom.Auth.verify(token) do
      {:ok, ^agent_id} ->
        {messages, last_seq} = AgentCom.Mailbox.poll(agent_id, since)
        formatted = Enum.map(messages, fn entry ->
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
        case conn.body_params do
          %{"seq" => seq} ->
            AgentCom.Mailbox.ack(agent_id, seq)
            send_json(conn, 200, %{"status" => "acked", "up_to" => seq})
          _ ->
            send_json(conn, 400, %{"error" => "missing required field: seq"})
        end
      _ ->
        send_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  # --- Channels ---

  get "/api/channels" do
    channels = AgentCom.Channels.list()
    send_json(conn, 200, %{"channels" => channels})
  end

  post "/api/channels" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
    if conn.halted do
      conn
    else
      agent_id = conn.assigns[:authenticated_agent]
      case conn.body_params do
        %{"name" => name} ->
          opts = %{
            description: conn.body_params["description"] || "",
            created_by: agent_id
          }
          case AgentCom.Channels.create(name, opts) do
            :ok -> send_json(conn, 201, %{"status" => "created", "channel" => name})
            {:error, :exists} -> send_json(conn, 409, %{"error" => "channel_exists"})
          end
        _ ->
          send_json(conn, 400, %{"error" => "missing required field: name"})
      end
    end
  end

  get "/api/channels/:channel" do
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

  post "/api/channels/:channel/subscribe" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
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

  post "/api/channels/:channel/unsubscribe" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
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

  post "/api/channels/:channel/publish" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
    if conn.halted do
      conn
    else
      agent_id = conn.assigns[:authenticated_agent]
      case conn.body_params do
        %{"payload" => payload} ->
          msg = AgentCom.Message.new(%{
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
        _ ->
          send_json(conn, 400, %{"error" => "missing required field: payload"})
      end
    end
  end

  get "/api/channels/:channel/history" do
    limit = case conn.params["limit"] do
      nil -> 50
      l -> String.to_integer(l)
    end
    since = case conn.params["since"] do
      nil -> 0
      s -> String.to_integer(s)
    end

    messages = AgentCom.Channels.history(channel, limit: limit, since: since)
    send_json(conn, 200, %{"channel" => channel, "messages" => messages, "count" => length(messages)})
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
        opts = if p = conn.params["start_time"], do: [{:start_time, String.to_integer(p)} | opts], else: opts
        opts = if p = conn.params["end_time"], do: [{:end_time, String.to_integer(p)} | opts], else: opts
        opts = if p = conn.params["cursor"], do: [{:cursor, String.to_integer(p)} | opts], else: opts
        opts = if p = conn.params["limit"], do: [{:limit, String.to_integer(p)} | opts], else: opts

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
      case conn.body_params do
        %{"agent_id" => agent_id} ->
          {:ok, token} = AgentCom.Auth.generate(agent_id)
          send_json(conn, 201, %{"agent_id" => agent_id, "token" => token})
        _ ->
          send_json(conn, 400, %{"error" => "missing required field: agent_id"})
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

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(AgentCom.Socket, [], timeout: 60_000)
    |> halt()
  end

  # --- Analytics ---

  get "/api/analytics/summary" do
    send_json(conn, 200, AgentCom.Analytics.summary())
  end

  get "/api/analytics/agents" do
    send_json(conn, 200, %{"agents" => AgentCom.Analytics.stats()})
  end

  get "/api/analytics/agents/:agent_id/hourly" do
    send_json(conn, 200, %{"agent_id" => agent_id, "hourly" => AgentCom.Analytics.hourly(agent_id)})
  end

  get "/dashboard" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, AgentCom.Dashboard.render())
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

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
