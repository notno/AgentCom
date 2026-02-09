defmodule AgentCom.Plugs.RequireAuth do
  @moduledoc """
  Plug that enforces Bearer token authentication on HTTP endpoints.

  Extracts the token from the `Authorization: Bearer <token>` header,
  verifies it via `AgentCom.Auth.verify/1`, and stores the authenticated
  agent_id in `conn.assigns[:authenticated_agent]`.

  Returns 401 if the token is missing or invalid.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- extract_bearer(conn),
         {:ok, agent_id} <- AgentCom.Auth.verify(token) do
      assign(conn, :authenticated_agent, agent_id)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "unauthorized", "hint" => "provide Authorization: Bearer <token>"}))
        |> halt()
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end
