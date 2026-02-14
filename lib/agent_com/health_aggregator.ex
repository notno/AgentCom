defmodule AgentCom.HealthAggregator do
  @moduledoc """
  Stateless health signal aggregator for the HubFSM healing system.

  Gathers health signals from 4 existing sources (Alerter, MetricsCollector,
  LlmRegistry, AgentFSM) and returns a structured health report with issues
  categorized by severity and source.

  All source calls are wrapped in try/catch to ensure HealthAggregator
  never crashes, even if individual sources are unavailable.
  """

  @doc """
  Assess current system health by querying all available sources.

  Returns a structured health report:

      %{
        healthy: boolean,
        issues: [%{source: atom, severity: :critical | :warning, category: atom, detail: map}],
        critical_count: integer,
        timestamp: integer
      }
  """
  def assess do
    now = System.system_time(:millisecond)
    alerts = safe_call(fn -> AgentCom.Alerter.active_alerts() end, [])
    metrics = safe_call(fn -> AgentCom.MetricsCollector.snapshot() end, %{})
    endpoints = safe_call(fn -> AgentCom.LlmRegistry.list_endpoints() end, [])
    agents = safe_call(fn -> AgentCom.AgentFSM.list_all() end, [])

    issues =
      []
      |> check_stuck_tasks(alerts)
      |> check_offline_agents(agents)
      |> check_unhealthy_endpoints(endpoints)
      |> check_high_error_rate(metrics)
      |> check_compilation_issues()

    %{
      healthy: issues == [],
      issues: issues,
      critical_count: Enum.count(issues, &(&1.severity == :critical)),
      timestamp: now
    }
  end

  # ---------------------------------------------------------------------------
  # Private: Health checks
  # ---------------------------------------------------------------------------

  defp check_stuck_tasks(issues, alerts) do
    stuck_alert =
      Enum.find(alerts, fn alert ->
        Map.get(alert, :rule_id) == :stuck_tasks
      end)

    if stuck_alert do
      details = Map.get(stuck_alert, :details, %{})
      task_ids = Map.get(details, :task_ids, [])
      stuck_count = length(task_ids)

      severity = if stuck_count >= 3, do: :critical, else: :warning

      [
        %{
          source: :alerter,
          severity: severity,
          category: :stuck_tasks,
          detail: %{task_ids: task_ids, count: stuck_count}
        }
        | issues
      ]
    else
      issues
    end
  end

  defp check_offline_agents(issues, agents) do
    # Find agents that are offline but have assigned tasks
    offline_with_tasks =
      Enum.filter(agents, fn agent ->
        agent.fsm_state == :offline and not is_nil(Map.get(agent, :current_task_id))
      end)

    if offline_with_tasks != [] do
      agent_ids = Enum.map(offline_with_tasks, & &1.agent_id)

      [
        %{
          source: :agent_fsm,
          severity: :warning,
          category: :offline_agents,
          detail: %{agent_ids: agent_ids, count: length(agent_ids)}
        }
        | issues
      ]
    else
      issues
    end
  end

  defp check_unhealthy_endpoints(issues, endpoints) do
    if endpoints == [] do
      issues
    else
      unhealthy = Enum.filter(endpoints, fn ep -> ep.status != :healthy end)
      all_unhealthy = length(unhealthy) == length(endpoints) and length(endpoints) > 0

      if all_unhealthy do
        endpoint_ids = Enum.map(unhealthy, & &1.id)

        [
          %{
            source: :llm_registry,
            severity: :critical,
            category: :unhealthy_endpoints,
            detail: %{endpoint_ids: endpoint_ids, count: length(endpoint_ids)}
          }
          | issues
        ]
      else
        issues
      end
    end
  end

  defp check_high_error_rate(issues, metrics) do
    error_rates = Map.get(metrics, :error_rates, %{})
    window = Map.get(error_rates, :window, %{})
    failure_rate = Map.get(window, :failure_rate_pct, 0.0)
    total_tasks = Map.get(window, :total_tasks, 0)

    if failure_rate > 50.0 and total_tasks > 0 do
      [
        %{
          source: :metrics_collector,
          severity: :warning,
          category: :high_error_rate,
          detail: %{failure_rate_pct: failure_rate, total_tasks: total_tasks}
        }
        | issues
      ]
    else
      issues
    end
  end

  defp check_compilation_issues(issues) do
    case check_merge_conflicts() do
      {:conflict, files} ->
        [
          %{
            source: :compilation,
            severity: :critical,
            category: :merge_conflicts,
            detail: %{files: files}
          }
          | issues
        ]

      :ok ->
        issues
    end
  end

  defp check_merge_conflicts do
    try do
      # Check for merge conflict markers (fast, no compilation needed)
      case System.cmd("git", ["diff", "--check"], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, _} ->
          if String.contains?(output, "conflict") do
            files =
              output
              |> String.split("\n")
              |> Enum.filter(&String.contains?(&1, ":"))
              |> Enum.map(fn line -> String.split(line, ":") |> List.first() end)
              |> Enum.uniq()

            {:conflict, files}
          else
            :ok
          end
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Safe call wrapper
  # ---------------------------------------------------------------------------

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      _, _ -> default
    end
  end
end
