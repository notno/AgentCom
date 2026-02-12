defmodule AgentCom.DashboardSocket do
  @moduledoc """
  WebSocket handler for the real-time dashboard.

  Browser clients connect to `/ws/dashboard` and receive:
  - An initial full state snapshot on connect (includes active alerts)
  - Batched PubSub event deltas (max 10 pushes/second via flush timer)
  - `metrics_snapshot` events every ~10 seconds with aggregated system metrics
  - `alert_fired`, `alert_cleared`, `alert_acknowledged` events in real time

  Client messages:
  - `{"type": "request_snapshot"}` -- triggers a fresh full snapshot push
  - `{"type": "retry_task", "task_id": "..."}` -- retries a dead-letter task
  - `{"type": "acknowledge_alert", "rule_id": "..."}` -- acknowledges an active alert

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
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "backups")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "metrics")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "alerts")

    # Get initial snapshot
    snapshot = AgentCom.DashboardState.snapshot()

    # Fetch active alerts for initial push
    alerts =
      try do
        AgentCom.Alerter.active_alerts()
      rescue
        _ -> []
      end

    # Start flush timer
    flush_ref = Process.send_after(self(), :flush, @flush_interval_ms)

    state = %{
      pending_events: [],
      flush_timer: flush_ref
    }

    {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot, alerts: alerts})}, state}
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

      {:ok, %{"type" => "acknowledge_alert", "rule_id" => rule_id}} ->
        result =
          case AgentCom.Alerter.acknowledge(rule_id) do
            :ok -> %{type: "alert_ack_result", rule_id: rule_id, status: "acknowledged"}
            {:error, :not_found} -> %{type: "alert_ack_result", rule_id: rule_id, status: "not_found"}
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

  def handle_info({:backup_complete, info}, state) do
    formatted = %{
      type: "backup_complete",
      timestamp: info.timestamp,
      tables_backed_up: Enum.map(info.tables_backed_up, &to_string/1)
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

  # -- PubSub: compaction/recovery events --------------------------------------

  def handle_info({:compaction_complete, info}, state) do
    formatted = %{
      type: "compaction_complete",
      timestamp: info.timestamp,
      results: Enum.map(info.results, fn r ->
        %{
          table: to_string(r.table),
          status: to_string(r.status),
          duration_ms: r[:duration_ms] || 0
        }
      end)
    }
    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  def handle_info({:compaction_failed, info}, state) do
    formatted = %{
      type: "compaction_failed",
      timestamp: info.timestamp,
      failures: Enum.map(info.failures, fn f ->
        %{table: to_string(f.table), reason: to_string(f[:reason] || "unknown")}
      end)
    }
    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  def handle_info({:recovery_complete, info}, state) do
    formatted = %{
      type: "recovery_complete",
      timestamp: info.timestamp,
      table: to_string(info.table),
      trigger: to_string(info[:trigger] || "unknown"),
      backup_used: info[:backup_used],
      record_count: info[:record_count] || 0
    }
    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  def handle_info({:recovery_failed, info}, state) do
    formatted = %{
      type: "recovery_failed",
      timestamp: info.timestamp,
      table: to_string(info.table),
      reason: inspect(info[:reason])
    }
    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  # -- PubSub: metrics events ---------------------------------------------------

  def handle_info({:metrics_snapshot, snapshot}, state) do
    compact = %{
      type: "metrics_snapshot",
      data: %{
        timestamp: snapshot.timestamp,
        queue_depth: snapshot.queue_depth,
        task_latency: snapshot.task_latency,
        agent_utilization: %{
          system: snapshot.agent_utilization.system,
          per_agent:
            Enum.map(snapshot.agent_utilization.per_agent, fn a ->
              Map.take(a, [
                :agent_id,
                :state,
                :idle_pct_1h,
                :working_pct_1h,
                :blocked_pct_1h,
                :tasks_completed_1h,
                :avg_task_duration_ms
              ])
            end)
        },
        error_rates: snapshot.error_rates
      }
    }

    {:ok, %{state | pending_events: [compact | state.pending_events]}}
  end

  # -- PubSub: alert events ----------------------------------------------------

  def handle_info({:alert_fired, alert}, state) do
    formatted = %{
      type: "alert_fired",
      data: %{
        rule_id: alert.rule_id,
        severity: to_string(alert.severity),
        message: alert.message,
        details: alert.details || %{},
        fired_at: alert.fired_at,
        acknowledged: false
      }
    }

    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  def handle_info({:alert_cleared, rule_id}, state) do
    formatted = %{type: "alert_cleared", rule_id: to_string(rule_id)}
    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  def handle_info({:alert_acknowledged, rule_id}, state) do
    formatted = %{type: "alert_acknowledged", rule_id: to_string(rule_id)}
    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
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
