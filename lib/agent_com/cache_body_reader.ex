defmodule AgentCom.CacheBodyReader do
  @moduledoc "Caches raw request body in conn.assigns[:raw_body] for HMAC signature verification."

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn =
          update_in(conn.assigns[:raw_body], fn
            nil -> [body]
            existing -> [body | existing]
          end)

        {:ok, body, conn}

      {:more, body, conn} ->
        conn =
          update_in(conn.assigns[:raw_body], fn
            nil -> [body]
            existing -> [body | existing]
          end)

        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
