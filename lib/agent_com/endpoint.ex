defmodule AgentCom.Endpoint do
  @moduledoc """
  HTTP + WebSocket endpoint for AgentCom.

  Routes:
  - GET    /health               — Health check
  - GET    /api/agents           — List connected agents
  - POST   /api/message          — Send a message via HTTP
  - GET    /api/mailbox/:id      — Poll messages (token required)
  - POST   /api/mailbox/:id/ack  — Acknowledge messages (token required)
  - POST   /admin/tokens         — Generate a token for an agent
  - GET    /admin/tokens         — List tokens (truncated)
  - DELETE /admin/tokens/:id     — Revoke tokens for an agent
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
    params = conn.body_params

    case params do
      %{"from" => from, "payload" => payload} ->
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
        send_json(conn, 400, %{"error" => "missing required fields: from, payload"})
    end
  end

  # --- Mailbox: Poll for messages ---

  get "/api/mailbox/:agent_id" do
    since = case conn.params["since"] do
      nil -> 0
      s -> String.to_integer(s)
    end

    # Verify the agent has a valid token (passed as query param or header)
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

  # --- Admin: Token management ---

  post "/admin/tokens" do
    case conn.body_params do
      %{"agent_id" => agent_id} ->
        {:ok, token} = AgentCom.Auth.generate(agent_id)
        send_json(conn, 201, %{"agent_id" => agent_id, "token" => token})
      _ ->
        send_json(conn, 400, %{"error" => "missing required field: agent_id"})
    end
  end

  get "/admin/tokens" do
    entries = AgentCom.Auth.list()
    send_json(conn, 200, %{"tokens" => entries})
  end

  delete "/admin/tokens/:agent_id" do
    AgentCom.Auth.revoke(agent_id)
    send_json(conn, 200, %{"status" => "revoked", "agent_id" => agent_id})
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(AgentCom.Socket, [], timeout: 60_000)
    |> halt()
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
