defmodule SpellRouter.Endpoint do
  @moduledoc """
  HTTP + WebSocket endpoint.
  
  Routes:
  - GET /health - Health check
  - GET /api/signal/new - Get a blank signal
  - POST /api/pipeline/run - Run a pipeline synchronously
  - WS /socket - WebSocket for operators and real-time updates
  """
  use Plug.Router
  
  plug Plug.Logger
  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  plug :dispatch

  # Health check
  get "/health" do
    send_json(conn, 200, %{status: "ok", service: "spell_router"})
  end

  # Get a blank signal
  get "/api/signal/new" do
    signal = SpellRouter.Signal.new()
    send_json(conn, 200, SpellRouter.Signal.to_json(signal))
  end

  # Get responder list
  get "/api/responders" do
    responders = SpellRouter.Signal.responders()
    send_json(conn, 200, %{responders: Enum.map(responders, &to_string/1)})
  end

  # Run a pipeline
  post "/api/pipeline/run" do
    with {:ok, steps} <- parse_steps(conn.body_params) do
      pipeline = SpellRouter.Pipeline.new(steps)
      
      case SpellRouter.Pipeline.run(pipeline) do
        {:ok, completed} ->
          send_json(conn, 200, %{
            status: "completed",
            pipeline_id: completed.id,
            signal: SpellRouter.Signal.to_json(completed.signal)
          })
        {:error, failed} ->
          send_json(conn, 422, %{
            status: "failed",
            pipeline_id: failed.id,
            error: inspect(failed.error),
            last_signal: SpellRouter.Signal.to_json(failed.signal)
          })
      end
    else
      {:error, reason} ->
        send_json(conn, 400, %{error: reason})
    end
  end

  # WebSocket upgrade
  get "/socket" do
    conn
    |> WebSockAdapter.upgrade(SpellRouter.Socket, [], timeout: 60_000)
    |> halt()
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp parse_steps(%{"steps" => steps}) when is_list(steps) do
    parsed = Enum.map(steps, &parse_step/1)
    
    if Enum.all?(parsed, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(parsed, fn {:ok, s} -> s end)}
    else
      {:error, "invalid steps"}
    end
  end
  defp parse_steps(_), do: {:error, "missing steps array"}

  defp parse_step(%{"type" => "source", "name" => name} = s) do
    pattern = Map.get(s, "pattern", %{}) |> atomize_pattern()
    {:ok, {:builtin, :source, %{name: name, pattern: pattern}}}
  end
  defp parse_step(%{"type" => "bash", "script" => script}) do
    {:ok, {:bash, script}}
  end
  defp parse_step(%{"type" => "remote", "agent" => agent}) do
    {:ok, {:remote, agent}}
  end
  defp parse_step(%{"type" => "commit"}), do: {:ok, {:builtin, :commit}}
  defp parse_step(%{"type" => "emit"}), do: {:ok, {:builtin, :emit}}
  defp parse_step(_), do: {:error, :invalid_step}

  defp atomize_pattern(pattern) do
    Map.new(pattern, fn {k, v} -> 
      {String.to_existing_atom(k), v} 
    end)
  rescue
    _ -> %{}
  end
end
