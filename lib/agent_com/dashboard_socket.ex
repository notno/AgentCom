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
  - `{"type": "cancel_task", "task_id": "..."}` -- permanently removes a dead-letter task
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
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "llm_registry")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "repo_registry")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "hub_fsm")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")

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

      {:ok, %{"type" => "cancel_task", "task_id" => task_id}} ->
        result =
          case AgentCom.TaskQueue.cancel_task(task_id) do
            {:ok, _task} -> %{type: "cancel_result", task_id: task_id, status: "cancelled"}
            {:error, :not_found} -> %{type: "cancel_result", task_id: task_id, status: "not_found"}
          end

        {:push, {:text, Jason.encode!(result)}, state}

      {:ok, %{"type" => "acknowledge_alert", "rule_id" => rule_id}} ->
        result =
          case AgentCom.Alerter.acknowledge(rule_id) do
            :ok ->
              %{type: "alert_ack_result", rule_id: rule_id, status: "acknowledged"}

            {:error, :not_found} ->
              %{type: "alert_ack_result", rule_id: rule_id, status: "not_found"}
          end

        {:push, {:text, Jason.encode!(result)}, state}

      {:ok, %{"type" => "register_llm_endpoint", "host" => host} = body} ->
        port = body["port"] || 11434
        name = body["name"] || "#{host}:#{port}"

        result =
          case AgentCom.LlmRegistry.register_endpoint(%{
                 host: host,
                 port: port,
                 name: name,
                 source: :manual
               }) do
            {:ok, endpoint} -> %{type: "llm_endpoint_registered", endpoint: endpoint}
            {:error, reason} -> %{type: "llm_endpoint_error", error: to_string(reason)}
          end

        {:push, {:text, Jason.encode!(result)}, state}

      {:ok, %{"type" => "remove_llm_endpoint", "id" => id}} ->
        result =
          case AgentCom.LlmRegistry.remove_endpoint(id) do
            :ok -> %{type: "llm_endpoint_removed", id: id}
            {:error, :not_found} -> %{type: "llm_endpoint_error", error: "not_found"}
          end

        {:push, {:text, Jason.encode!(result)}, state}

      # -- Repo Registry commands (Phase 23) -----------------------------------

      {:ok, %{"type" => "add_repo", "url" => url} = msg} ->
        name = Map.get(msg, "name", nil)

        case AgentCom.RepoRegistry.add_repo(%{url: url, name: name}) do
          {:ok, _repo} ->
            snapshot = AgentCom.DashboardState.snapshot()
            {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot})}, state}

          {:error, :already_exists} ->
            {:push, {:text, Jason.encode!(%{type: "repo_error", error: "repo_already_exists"})},
             state}
        end

      {:ok, %{"type" => "remove_repo", "repo_id" => repo_id}} ->
        AgentCom.RepoRegistry.remove_repo(repo_id)
        snapshot = AgentCom.DashboardState.snapshot()
        {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot})}, state}

      {:ok, %{"type" => "move_repo_up", "repo_id" => repo_id}} ->
        AgentCom.RepoRegistry.move_up(repo_id)
        snapshot = AgentCom.DashboardState.snapshot()
        {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot})}, state}

      {:ok, %{"type" => "move_repo_down", "repo_id" => repo_id}} ->
        AgentCom.RepoRegistry.move_down(repo_id)
        snapshot = AgentCom.DashboardState.snapshot()
        {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot})}, state}

      {:ok, %{"type" => "pause_repo", "repo_id" => repo_id}} ->
        AgentCom.RepoRegistry.set_status(repo_id, :paused)
        snapshot = AgentCom.DashboardState.snapshot()
        {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot})}, state}

      {:ok, %{"type" => "unpause_repo", "repo_id" => repo_id}} ->
        AgentCom.RepoRegistry.set_status(repo_id, :active)
        snapshot = AgentCom.DashboardState.snapshot()
        {:push, {:text, Jason.encode!(%{type: "snapshot", data: snapshot})}, state}

      _ ->
        {:ok, state}
    end
  end

  # -- PubSub events: accumulate into pending_events ---------------------------

  # Execution progress events push directly (not batched) for real-time streaming.
  # ProgressEmitter on the sidecar already batches at 100ms, so no additional
  # batching needed here.
  @impl true
  def handle_info(
        {:task_event, %{event: :execution_progress, task_id: task_id, execution_event: event}},
        state
      ) do
    push = %{
      "type" => "execution_event",
      "task_id" => task_id,
      "event_type" => event["event_type"] || Map.get(event, :event_type),
      "text" => event["text"] || Map.get(event, :text, ""),
      "tokens_so_far" => event["tokens_so_far"] || Map.get(event, :tokens_so_far),
      "model" => event["model"] || Map.get(event, :model),
      "timestamp" => event["timestamp"] || Map.get(event, :timestamp)
    }

    {:push, {:text, Jason.encode!(push)}, state}
  end

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
      results:
        Enum.map(info.results, fn r ->
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
      failures:
        Enum.map(info.failures, fn f ->
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

  # -- PubSub: llm_registry events ---------------------------------------------

  def handle_info({:llm_registry_update, detail}, state) do
    formatted = %{
      type: "llm_registry_update",
      detail: to_string(detail)
    }

    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  # -- PubSub: hub_fsm events ---------------------------------------------------

  def handle_info({:hub_fsm_state_change, info}, state) do
    formatted = %{
      type: "hub_fsm_state",
      data: %{
        fsm_state: to_string(info.fsm_state),
        paused: info.paused,
        last_state_change: info.last_state_change,
        cycle_count: info.cycle_count,
        timestamp: info.timestamp
      }
    }

    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  # -- PubSub: goal events -----------------------------------------------------

  def handle_info({:goal_event, payload}, state) do
    formatted = %{
      type: "goal_event",
      data: %{
        event: to_string(payload.event),
        goal_id: payload.goal_id,
        status: if(payload.goal, do: to_string(payload.goal.status), else: nil),
        priority: if(payload.goal, do: payload.goal.priority, else: nil),
        timestamp: payload.timestamp
      }
    }

    {:ok, %{state | pending_events: [formatted | state.pending_events]}}
  end

  # -- PubSub: repo_registry events --------------------------------------------

  def handle_info({:repo_registry_update, detail}, state) do
    formatted = %{
      type: "repo_registry_update",
      detail: to_string(detail)
    }

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
