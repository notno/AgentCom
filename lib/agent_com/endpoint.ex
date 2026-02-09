defmodule AgentCom.Endpoint do
  @moduledoc """
  HTTP + WebSocket endpoint for AgentCom.

  Routes:
  - GET  /health       — Health check
  - GET  /api/agents   — List connected agents
  - POST /api/message  — Send a message via HTTP
  - WS   /ws           — WebSocket for agent connections
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

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(AgentCom.Socket, [], timeout: 60_000)
    |> halt()
  end

  match _ do
    send_json(conn, 404, %{"error" => "not_found"})
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
