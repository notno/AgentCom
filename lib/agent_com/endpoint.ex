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
  - GET    /api/agents/states          — All agent FSM states (auth required)
  - GET    /api/agents/:id/state       — Single agent FSM state detail (auth required)
  - GET    /api/agents/:id/subscriptions — List agent's channel subscriptions
  - POST   /api/admin/push-task  — Push a task to a connected agent (auth required)
  - POST   /api/admin/backup     — Trigger manual DETS backup (auth required)
  - GET    /api/admin/dets-health — DETS table health metrics (auth required)
  - POST   /api/admin/compact     — Compact all DETS tables (auth required)
  - POST   /api/admin/compact/:table — Compact a specific DETS table (auth required)
  - POST   /api/admin/restore/:table — Restore a DETS table from backup (auth required)
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
        "connected_at" => a[:connected_at],
        "fsm_state" => Map.get(a, :fsm_state, "unknown")
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

  # --- Agent FSM state endpoints (must be before parameterized :agent_id routes) ---

  get "/api/agents/states" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
    if conn.halted do
      conn
    else
      agents = AgentCom.AgentFSM.list_all()
      formatted = Enum.map(agents, fn a ->
        %{
          "agent_id" => a.agent_id,
          "fsm_state" => to_string(a.fsm_state),
          "current_task_id" => a.current_task_id,
          "capabilities" => Enum.map(a.capabilities || [], fn cap ->
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
            "capabilities" => Enum.map(agent_state.capabilities, fn cap ->
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
  @admin_agents (System.get_env("ADMIN_AGENTS", "") |> String.split(",", trim: true))

  post "/api/admin/reset" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
    if conn.halted do
      conn
    else
      agent_id = conn.assigns[:authenticated_agent]

      if agent_id not in @admin_agents do
        send_json(conn, 403, %{"error" => "admin_only", "message" => "Only admin agents can reset the hub"})
      else
        require Logger
        Logger.warning("Hub reset triggered by #{agent_id}")

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

  # --- Admin: Push task to agent (for testing, pre-scheduler) ---

  post "/api/admin/push-task" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
    if conn.halted do
      conn
    else
      admin_agent = conn.assigns[:authenticated_agent]

      case conn.body_params do
        %{"agent_id" => target_agent_id, "description" => description} = params ->
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

        _ ->
          send_json(conn, 400, %{
            "error" => "missing required fields: agent_id, description"
          })
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
          formatted = Enum.map(results, fn
            {:ok, info} -> %{"table" => to_string(info.table), "status" => "ok", "path" => info.path, "size" => info.size}
            {:error, info} -> %{"table" => to_string(info.table), "status" => "error", "reason" => to_string(info.reason)}
          end)
          success_count = Enum.count(results, fn {:ok, _} -> true; _ -> false end)
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
      formatted_tables = Enum.map(metrics.tables, fn t ->
        %{
          "table" => to_string(t.table),
          "record_count" => t.record_count,
          "file_size_bytes" => t.file_size_bytes,
          "fragmentation_ratio" => t.fragmentation_ratio,
          "status" => to_string(t.status)
        }
      end)

      now = System.system_time(:millisecond)
      stale_backup = case metrics.last_backup_at do
        nil -> true
        ts -> now - ts > 48 * 60 * 60 * 1000
      end
      high_frag = Enum.any?(metrics.tables, fn t -> t.status == :ok and t.fragmentation_ratio > 0.5 end)

      health_status = cond do
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
    "thread_replies" => :thread_replies
  }

  post "/api/admin/compact" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
    if conn.halted do
      conn
    else
      case AgentCom.DetsBackup.compact_all() do
        {:ok, results} ->
          formatted = Enum.map(results, fn r ->
            base = %{"table" => to_string(r.table), "status" => to_string(r.status)}
            base = if r[:duration_ms], do: Map.put(base, "duration_ms", r.duration_ms), else: base
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
      agent_id = conn.assigns[:authenticated_agent]
      params = conn.body_params

      case params do
        %{"description" => description} ->
          task_params = %{
            description: description,
            priority: params["priority"] || "normal",
            metadata: params["metadata"] || %{},
            max_retries: params["max_retries"] || 3,
            complete_by: params["complete_by"],
            needed_capabilities: params["needed_capabilities"] || [],
            submitted_by: agent_id
          }

          case AgentCom.TaskQueue.submit(task_params) do
            {:ok, task} ->
              send_json(conn, 201, %{
                "status" => "queued",
                "task_id" => task.id,
                "priority" => task.priority,
                "created_at" => task.created_at
              })
          end

        _ ->
          send_json(conn, 400, %{"error" => "missing required field: description"})
      end
    end
  end

  get "/api/tasks" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
    if conn.halted do
      conn
    else
      opts = []
      opts = if s = conn.params["status"] do
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

      tasks = AgentCom.TaskQueue.list(opts)
      formatted = Enum.map(tasks, &format_task/1)
      send_json(conn, 200, %{"tasks" => formatted, "count" => length(formatted)})
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
      case AgentCom.TaskQueue.get(task_id) do
        {:ok, task} ->
          send_json(conn, 200, format_task(task))
        {:error, :not_found} ->
          send_json(conn, 404, %{"error" => "task_not_found", "task_id" => task_id})
      end
    end
  end

  post "/api/tasks/:task_id/retry" do
    conn = AgentCom.Plugs.RequireAuth.call(conn, [])
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

  # --- Dashboard API (no auth -- local network only) ---

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
    subscription = conn.body_params
    AgentCom.DashboardNotifier.subscribe(subscription)
    send_json(conn, 200, %{"status" => "subscribed"})
  end

  # --- Onboarding: Agent registration (no auth -- solves chicken-and-egg problem) ---

  post "/api/onboard/register" do
    case conn.body_params do
      %{"agent_id" => agent_id} when is_binary(agent_id) and agent_id != "" ->
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

      _ ->
        send_json(conn, 400, %{"error" => "missing or invalid field: agent_id"})
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
      case conn.body_params do
        %{"url" => url} when is_binary(url) and url != "" ->
          :ok = AgentCom.Config.put(:default_repo, url)
          send_json(conn, 200, %{"status" => "ok", "default_repo" => url})
        _ ->
          send_json(conn, 400, %{"error" => "missing or invalid field: url"})
      end
    end
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
      "history" => Enum.map(task.history || [], fn
        {event, timestamp, details} ->
          %{"event" => to_string(event), "timestamp" => timestamp, "details" => format_details(details)}
        other -> other
      end)
    }
  end

  defp format_details(details) when is_map(details) do
    Map.new(details, fn {k, v} -> {to_string(k), v} end)
  end
  defp format_details(details), do: details

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
