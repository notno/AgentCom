defmodule AgentCom.TestHelpers.WsClient do
  @moduledoc """
  Simplified Mint.WebSocket GenServer client for integration tests.

  Connects to the hub via WebSocket, sends/receives JSON messages,
  and collects all received messages for test assertions.

  Based on the `Smoke.AgentSim` pattern but stripped of task handling
  logic -- this is a generic message collector.

  ## Usage

      {:ok, client} = AgentCom.TestHelpers.WsClient.start_link(url: "ws://localhost:4002/ws")
      :ok = AgentCom.TestHelpers.WsClient.connect_and_identify(client, "agent-1", token)
      :ok = AgentCom.TestHelpers.WsClient.wait_for_identified(client)
      :ok = AgentCom.TestHelpers.WsClient.send_json(client, %{"type" => "ping"})
      messages = AgentCom.TestHelpers.WsClient.messages(client)
      AgentCom.TestHelpers.WsClient.stop(client)
  """

  use GenServer

  defstruct [
    :url,
    :conn,
    :websocket,
    :request_ref,
    :response_status,
    :response_headers,
    identified: false,
    messages: [],
    buffer: <<>>
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the WebSocket test client GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Connect to the hub and send an identify message.

  Initiates the WebSocket connection and queues the identify message
  to be sent once the upgrade completes.
  """
  def connect_and_identify(pid, agent_id, token) do
    GenServer.call(pid, {:connect_and_identify, agent_id, token}, 10_000)
  end

  @doc "Send a JSON-encoded map over the WebSocket."
  def send_json(pid, map) when is_map(map) do
    GenServer.call(pid, {:send_json, map})
  end

  @doc "Return all received JSON messages as a list of maps (oldest first)."
  def messages(pid) do
    GenServer.call(pid, :messages)
  end

  @doc """
  Wait until the client has been identified by the hub.

  Polls at 100ms intervals up to the given timeout (default 5000ms).
  Returns :ok or raises on timeout.
  """
  def wait_for_identified(pid, timeout \\ 5_000) do
    deadline = System.system_time(:millisecond) + timeout
    do_wait_identified(pid, deadline)
  end

  @doc "Check if the client has been identified."
  def identified?(pid) do
    GenServer.call(pid, :identified?)
  end

  @doc "Gracefully stop the client."
  def stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    url = Keyword.get(opts, :url, "ws://localhost:4002/ws")
    {:ok, %__MODULE__{url: url}}
  end

  @impl true
  def handle_call({:connect_and_identify, agent_id, token}, _from, state) do
    case do_connect(state) do
      {:ok, new_state} ->
        # Queue the identify message to be sent after WebSocket upgrade completes
        identify_msg = %{
          "type" => "identify",
          "agent_id" => agent_id,
          "token" => token,
          "name" => "ws-client-#{agent_id}",
          "status" => "idle",
          "capabilities" => [],
          "client_type" => "test_client",
          "protocol_version" => 1
        }

        {:reply, :ok, %{new_state | buffer: Jason.encode!(identify_msg)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_json, map}, _from, state) do
    case send_frame(state, {:text, Jason.encode!(map)}) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:messages, _from, state) do
    {:reply, Enum.reverse(state.messages), state}
  end

  def handle_call(:identified?, _from, state) do
    {:reply, state.identified, state}
  end

  @impl true
  def handle_info(message, state) do
    if state.conn == nil do
      {:noreply, state}
    else
      case Mint.WebSocket.stream(state.conn, message) do
        {:ok, conn, responses} ->
          new_state = %{state | conn: conn}
          new_state = process_responses(responses, new_state)
          {:noreply, new_state}

        {:error, conn, _reason, _responses} ->
          {:noreply, %{state | conn: conn}}

        :unknown ->
          {:noreply, state}
      end
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn && state.websocket do
      try do
        {:ok, websocket, data} = Mint.WebSocket.encode(state.websocket, {:close, 1000, "shutdown"})
        {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data)
        Mint.HTTP.close(conn)
        _ = websocket
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private: Connection
  # ---------------------------------------------------------------------------

  defp do_connect(state) do
    uri = URI.parse(state.url)

    http_scheme = case uri.scheme do
      "ws" -> :http
      "wss" -> :https
    end

    ws_scheme = case uri.scheme do
      "ws" -> :ws
      "wss" -> :wss
    end

    path = uri.path || "/"
    path = case uri.query do
      nil -> path
      query -> path <> "?" <> query
    end

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []) do
      {:ok, %{state | conn: conn, request_ref: ref}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Response processing
  # ---------------------------------------------------------------------------

  defp process_responses([], state), do: state

  defp process_responses([response | rest], state) do
    new_state = process_response(response, state)
    process_responses(rest, new_state)
  end

  defp process_response({:status, _ref, status}, state) do
    %{state | response_status: status}
  end

  defp process_response({:headers, _ref, headers}, state) do
    %{state | response_headers: headers}
  end

  defp process_response({:done, ref}, state) do
    case Mint.WebSocket.new(state.conn, ref, state.response_status, state.response_headers) do
      {:ok, conn, websocket} ->
        new_state = %{state | conn: conn, websocket: websocket}

        # If we have a buffered identify message, send it now
        if new_state.buffer != <<>> do
          case send_frame(new_state, {:text, new_state.buffer}) do
            {:ok, sent_state} -> %{sent_state | buffer: <<>>}
            {:error, _} -> %{new_state | buffer: <<>>}
          end
        else
          new_state
        end

      {:error, conn, _reason} ->
        %{state | conn: conn}
    end
  end

  defp process_response({:data, _ref, data}, state) do
    if state.websocket do
      case Mint.WebSocket.decode(state.websocket, data) do
        {:ok, websocket, frames} ->
          new_state = %{state | websocket: websocket}
          process_frames(frames, new_state)

        {:error, websocket, _reason} ->
          %{state | websocket: websocket}
      end
    else
      state
    end
  end

  defp process_response({:error, _ref, _reason}, state), do: state

  # ---------------------------------------------------------------------------
  # Private: Frame processing
  # ---------------------------------------------------------------------------

  defp process_frames([], state), do: state

  defp process_frames([frame | rest], state) do
    new_state = process_frame(frame, state)
    process_frames(rest, new_state)
  end

  defp process_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "identified"} = msg} ->
        %{state | identified: true, messages: [msg | state.messages]}

      {:ok, msg} ->
        %{state | messages: [msg | state.messages]}

      {:error, _} ->
        state
    end
  end

  defp process_frame({:ping, data}, state) do
    case send_frame(state, {:pong, data}) do
      {:ok, new_state} -> new_state
      {:error, _} -> state
    end
  end

  defp process_frame({:close, _code, _reason}, state) do
    %{state | conn: nil, websocket: nil}
  end

  defp process_frame(_frame, state), do: state

  # ---------------------------------------------------------------------------
  # Private: Send frame
  # ---------------------------------------------------------------------------

  defp send_frame(state, frame) do
    if state.conn == nil or state.websocket == nil do
      {:error, :not_connected}
    else
      with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
           {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
        {:ok, %{state | conn: conn, websocket: websocket}}
      else
        {:error, _reason} = err -> err
        {:error, _ws_or_conn, reason} -> {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Polling
  # ---------------------------------------------------------------------------

  defp do_wait_identified(pid, deadline) do
    if System.system_time(:millisecond) > deadline do
      raise "Timeout waiting for WebSocket client to be identified"
    end

    if identified?(pid) do
      :ok
    else
      Process.sleep(100)
      do_wait_identified(pid, deadline)
    end
  end
end
