defmodule Smoke.AgentSim do
  @moduledoc """
  Simulated WebSocket agent GenServer for smoke tests.

  Connects to the hub via WebSocket using Mint.HTTP + Mint.WebSocket,
  identifies as an agent, receives task_assign messages, and automatically
  handles them based on the configured `on_task_assign` behavior.

  ## Usage

      {:ok, pid} = Smoke.AgentSim.start_link(
        agent_id: "smoke-1",
        token: token,
        hub_url: "ws://localhost:4000/ws",
        on_task_assign: :complete,
        capabilities: ["code"]
      )

      # Wait for identification
      Smoke.Assertions.wait_for(fn -> Smoke.AgentSim.identified?(pid) end)

      # ... submit tasks, wait for completion ...

      count = Smoke.AgentSim.completed_count(pid)
      tasks = Smoke.AgentSim.received_tasks(pid)

      Smoke.AgentSim.stop(pid)

  ## on_task_assign behaviors

    - `:complete` -- immediately send task_accepted then task_complete with generation
    - `:fail` -- send task_accepted then task_failed
    - `:ignore` -- do nothing (simulate unresponsive)
    - `{:delay, ms}` -- send task_accepted, wait ms, then task_complete
  """

  use GenServer
  require Logger

  defstruct [
    :agent_id,
    :token,
    :hub_url,
    :on_task_assign,
    :capabilities,
    :conn,
    :websocket,
    :request_ref,
    :response_status,
    :response_headers,
    :caller,
    identified: false,
    tasks_received: [],
    tasks_completed: 0,
    buffer: <<>>
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the simulated agent GenServer."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Graceful stop -- closes WebSocket."
  def stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  end

  @doc "Return the number of completed tasks."
  def completed_count(pid) do
    GenServer.call(pid, :completed_count)
  end

  @doc "Return list of received task maps."
  def received_tasks(pid) do
    GenServer.call(pid, :received_tasks)
  end

  @doc """
  Abruptly kill the WebSocket connection.

  Does NOT send a clean close frame -- just terminates the underlying
  TCP connection so the hub sees an abrupt disconnect, triggering
  the AgentFSM :DOWN handler.
  """
  def kill_connection(pid) do
    GenServer.cast(pid, :kill_connection)
  end

  @doc "Check if the agent has been identified by the hub."
  def identified?(pid) do
    GenServer.call(pid, :identified?)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    token = Keyword.fetch!(opts, :token)
    hub_url = Keyword.get(opts, :hub_url, "ws://localhost:4000/ws")
    on_task_assign = Keyword.get(opts, :on_task_assign, :complete)
    capabilities = Keyword.get(opts, :capabilities, [])

    state = %__MODULE__{
      agent_id: agent_id,
      token: token,
      hub_url: hub_url,
      on_task_assign: on_task_assign,
      capabilities: capabilities
    }

    # Connect asynchronously to avoid blocking the caller
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_call(:completed_count, _from, state) do
    {:reply, state.tasks_completed, state}
  end

  def handle_call(:received_tasks, _from, state) do
    {:reply, state.tasks_received, state}
  end

  def handle_call(:identified?, _from, state) do
    {:reply, state.identified, state}
  end

  @impl true
  def handle_cast(:kill_connection, state) do
    # Abruptly close the TCP connection without sending a close frame
    if state.conn do
      Mint.HTTP.close(state.conn)
    end

    {:noreply, %{state | conn: nil, websocket: nil}}
  end

  @impl true
  def handle_info(:connect, state) do
    case do_connect(state) do
      {:ok, new_state} ->
        # Send identify message
        identify_msg = Jason.encode!(%{
          "type" => "identify",
          "agent_id" => state.agent_id,
          "token" => state.token,
          "name" => "smoke-#{state.agent_id}",
          "status" => "idle",
          "capabilities" => state.capabilities,
          "client_type" => "smoke_test",
          "protocol_version" => 1
        })

        case send_frame(new_state, {:text, identify_msg}) do
          {:ok, new_state2} ->
            {:noreply, new_state2}

          {:error, _reason} ->
            Logger.warning("AgentSim #{state.agent_id}: failed to send identify")
            {:noreply, new_state}
        end

      {:error, reason} ->
        Logger.warning("AgentSim #{state.agent_id}: connect failed: #{inspect(reason)}")
        # Retry after a short delay
        Process.send_after(self(), :connect, 1_000)
        {:noreply, state}
    end
  end

  # Handle delayed task completion timer
  def handle_info({:delayed_complete, task_id, generation}, state) do
    new_state = do_task_complete(state, task_id, generation)
    {:noreply, new_state}
  end

  # Handle incoming TCP data from Mint
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
      # Try to send a close frame, but don't worry if it fails
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
    uri = URI.parse(state.hub_url)

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
      {:error, reason} ->
        {:error, reason}

      {:error, _conn, reason} ->
        {:error, reason}
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
        %{state | conn: conn, websocket: websocket}

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
      # Buffer data received before WebSocket upgrade completes
      %{state | buffer: state.buffer <> data}
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
      {:ok, msg} -> handle_ws_message(msg, state)
      {:error, _} -> state
    end
  end

  defp process_frame({:ping, data}, state) do
    # Respond to pings automatically
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
  # Private: WebSocket message handling
  # ---------------------------------------------------------------------------

  defp handle_ws_message(%{"type" => "identified"}, state) do
    Logger.info("AgentSim #{state.agent_id}: identified")
    %{state | identified: true}
  end

  defp handle_ws_message(%{"type" => "error", "error" => error}, state) do
    Logger.warning("AgentSim #{state.agent_id}: hub error: #{error}")
    state
  end

  defp handle_ws_message(%{"type" => "task_assign"} = msg, state) do
    task_id = msg["task_id"]
    generation = msg["generation"] || 0

    Logger.info("AgentSim #{state.agent_id}: received task_assign #{task_id} gen=#{generation}")

    # Track received task
    task_record = %{
      task_id: task_id,
      generation: generation,
      received_at: System.system_time(:millisecond)
    }

    new_state = %{state | tasks_received: [task_record | state.tasks_received]}

    # Handle based on on_task_assign behavior
    case state.on_task_assign do
      :complete ->
        new_state = do_task_accepted(new_state, task_id)
        do_task_complete(new_state, task_id, generation)

      :fail ->
        new_state = do_task_accepted(new_state, task_id)
        do_task_failed(new_state, task_id, generation)

      :ignore ->
        new_state

      {:delay, ms} ->
        new_state = do_task_accepted(new_state, task_id)
        Process.send_after(self(), {:delayed_complete, task_id, generation}, ms)
        new_state
    end
  end

  defp handle_ws_message(%{"type" => "task_ack"}, state) do
    # Acknowledgment from hub -- nothing to do
    state
  end

  defp handle_ws_message(%{"type" => "pong"}, state) do
    state
  end

  defp handle_ws_message(_msg, state) do
    state
  end

  # ---------------------------------------------------------------------------
  # Private: Task lifecycle senders
  # ---------------------------------------------------------------------------

  defp do_task_accepted(state, task_id) do
    msg = Jason.encode!(%{
      "type" => "task_accepted",
      "task_id" => task_id,
      "protocol_version" => 1
    })

    case send_frame(state, {:text, msg}) do
      {:ok, new_state} -> new_state
      {:error, _} -> state
    end
  end

  defp do_task_complete(state, task_id, generation) do
    msg = Jason.encode!(%{
      "type" => "task_complete",
      "task_id" => task_id,
      "generation" => generation,
      "result" => %{"status" => "success", "output" => "smoke-test-result"},
      "tokens_used" => 0,
      "protocol_version" => 1
    })

    case send_frame(state, {:text, msg}) do
      {:ok, new_state} ->
        %{new_state | tasks_completed: new_state.tasks_completed + 1}

      {:error, _} ->
        state
    end
  end

  defp do_task_failed(state, task_id, generation) do
    msg = Jason.encode!(%{
      "type" => "task_failed",
      "task_id" => task_id,
      "generation" => generation,
      "error" => "smoke-test-failure",
      "protocol_version" => 1
    })

    case send_frame(state, {:text, msg}) do
      {:ok, new_state} -> new_state
      {:error, _} -> state
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Send frame via Mint.WebSocket
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
end
