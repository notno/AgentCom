defmodule AgentCom.DashboardSocket do
  @moduledoc """
  WebSocket handler for the real-time dashboard.

  Browser clients connect to `/ws/dashboard` and receive:
  - An initial full state snapshot on connect
  - Batched PubSub event deltas (max 10 pushes/second via flush timer)

  Client messages:
  - `{"type": "request_snapshot"}` -- triggers a fresh full snapshot push
  - `{"type": "retry_task", "task_id": "..."}` -- retries a dead-letter task

  Event batching prevents PubSub message floods from overwhelming the browser.
  Events are accumulated in a pending list and flushed every 100ms.
  """

  @behaviour WebSock

  @flush_interval_ms 100

  @impl true
  def init(_opts) do
    # Subscribe to relevant PubSub topics
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")

    # Get initial snapshot
    snapshot = AgentCom.DashboardState.snapshot()

    # Start flush timer
    flush_ref = Process.send_after(self(), :flush, @flush_interval_ms)

    state = %{
      pending_events: [],
      flush_timer: flush_ref
    }

    {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot})}, state}
  end

  # -- Client messages ---------------------------------------------------------

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "request_snapshot"}} ->
        snapshot = AgentCom.DashboardState.snapshot()
        {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot})}, state}

      {:ok, %{"type" => "retry_task", "task_id" => task_id}} ->
        result =
          case AgentCom.TaskQueue.retry_dead_letter(task_id) do
            {:ok, _task} -> %{type: "retry_result", task_id: task_id, status: "requeued"}
            {:error, :not_found} -> %{type: "retry_result", task_id: task_id, status: "not_found"}
          end

        {:push, {:text, Jason.encode!(result)}, state}

      _ ->
        {:ok, state}
    end
  end

  # -- PubSub events: accumulate into pending_events ---------------------------

  @impl true
  def handle_info({:task_event, event}, state) do
    formatted = %{
      type: "task_event",
      task_id: event.task_id,
      event: normalize_event(event.event),
      agent_id: Map.get(event, :agent_id),
      timestamp: event.timestamp
    }

    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  def handle_info({:agent_joined, info}, state) do
    formatted = %{
      type: "agent_joined",
      agent_id: info[:agent_id] || info.agent_id,
      name: info[:name],
      capabilities: info[:capabilities] || []
    }

    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  def handle_info({:agent_left, agent_id}, state) do
    formatted = %{
      type: "agent_left",
      agent_id: agent_id
    }

    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  def handle_info({:status_changed, info}, state) do
    formatted = %{
      type: "status_changed",
      agent_id: info[:agent_id] || info.agent_id,
      status: info[:status]
    }

    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  # -- Flush timer: batch-push accumulated events ------------------------------

  def handle_info(:flush, state) do
    # Schedule next flush
    flush_ref = Process.send_after(self(), :flush, @flush_interval_ms)
    new_state = %{state | flush_timer: flush_ref}

    case state.pending_events do
      [] ->
        {:ok, %{new_state | pending_events: []}}

      events ->
        # Reverse to maintain chronological order (we prepended)
        ordered_events = Enum.reverse(events)
        message = Jason.encode!(%{type: "events", data: ordered_events})
        {:push, {:text, message}, %{new_state | pending_events: []}}
    end
  end

  # Catch-all for unhandled messages (e.g., :agent_idle from presence)
  def handle_info(_msg, state) do
    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize_event(event) when is_atom(event), do: to_string(event)
  defp normalize_event(event), do: event
end
