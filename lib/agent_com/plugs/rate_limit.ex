defmodule AgentCom.Plugs.RateLimit do
  @moduledoc """
  HTTP rate limiting plug. Returns 429 Too Many Requests when rate limit exceeded.

  Uses agent_id from conn.assigns[:authenticated_agent] (set by RequireAuth plug)
  or falls back to IP address for unauthenticated endpoints.

  ## Usage

      # After RequireAuth in authenticated routes:
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :post_task)

      # In unauthenticated routes (uses IP-based identification):
      conn = AgentCom.Plugs.RateLimit.call(conn, action: :get_agents)
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    action = Keyword.get(opts, :action, :unknown)
    tier = AgentCom.RateLimiter.Config.http_tier(action)

    # Use authenticated agent_id if available, fall back to IP
    agent_id = conn.assigns[:authenticated_agent] || format_ip(conn.remote_ip)

    case AgentCom.RateLimiter.check(agent_id, :http, tier) do
      {:allow, :exempt} -> conn
      {:allow, _} -> conn
      {:warn, _} -> conn  # HTTP has no warning channel, just allow

      {:deny, retry_after_ms} ->
        AgentCom.RateLimiter.record_violation(agent_id)
        retry_seconds = max(div(retry_after_ms, 1000), 1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_seconds))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{
          "error" => "rate_limited",
          "retry_after_ms" => retry_after_ms,
          "tier" => to_string(tier)
        }))
        |> halt()
    end
  end

  defp format_ip({a, b, c, d}), do: "ip:#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: "ip:#{inspect(ip)}"
end
