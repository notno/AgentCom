defmodule AgentCom.HubFSM.Healing do
  @moduledoc """
  Remediation actions for the :healing FSM state.

  Called from an async Task spawned by HubFSM when entering :healing.
  All actions are wrapped in try/catch to prevent cascading failures.

  Remediation priority:
  1. stuck_tasks -- requeue or dead-letter
  2. offline_agents -- requeue assigned tasks
  3. unhealthy_endpoints -- exponential backoff recovery
  4. merge_conflicts -- delegate to agent via TaskQueue
  5. compilation_failure -- delegate to agent via TaskQueue
  6. high_error_rate -- log for awareness (no automated fix)
  """

  require Logger

  @doc """
  Run a complete healing cycle.

  Assesses current health, sorts issues by priority, executes remediation
  actions sequentially, and returns a summary.
  """
  def run_healing_cycle do
    Logger.info("healing_cycle_started")
    health = AgentCom.HealthAggregator.assess()

    results =
      health.issues
      |> Enum.sort_by(&priority/1)
      |> Enum.map(fn issue ->
        result = remediate(issue)
        log_action(issue, result)
        {issue.category, result}
      end)

    summary = %{
      issues_found: length(health.issues),
      actions_taken: length(results),
      results: results,
      timestamp: System.system_time(:millisecond)
    }

    Logger.info("healing_cycle_complete", summary: inspect(summary))
    summary
  end

  # ---------------------------------------------------------------------------
  # Remediation actions
  # ---------------------------------------------------------------------------

  defp remediate(%{category: :stuck_tasks, detail: detail}) do
    task_ids = Map.get(detail, :task_ids, [])

    results =
      Enum.map(task_ids, fn task_id ->
        try do
          # Get task to check retry count
          tasks = AgentCom.TaskQueue.list(status: :assigned)
          task = Enum.find(tasks, fn t -> t.id == task_id end)

          cond do
            is_nil(task) ->
              {:skip, task_id, "task not found or no longer assigned"}

            Map.get(task, :retry_count, 0) >= 3 ->
              # Dead-letter after 3 retries
              AgentCom.TaskQueue.fail_task(task_id, task.generation, "stuck: exceeded 3 retries")
              {:dead_lettered, task_id}

            true ->
              # Check if agent is offline
              agent_id = task.assigned_to
              agent = find_agent(agent_id)

              if is_nil(agent) or agent.fsm_state == :offline do
                AgentCom.TaskQueue.reclaim_task(task_id)
                {:requeued, task_id, "agent offline"}
              else
                # Agent is online but slow -- skip, let pipeline timeout handle it
                {:skip, task_id, "agent online, deferring to pipeline timeout"}
              end
          end
        catch
          kind, error ->
            {:error, task_id, "#{kind}: #{inspect(error)}"}
        end
      end)

    %{action: :stuck_task_remediation, results: results}
  end

  defp remediate(%{category: :offline_agents, detail: detail}) do
    agent_ids = Map.get(detail, :agent_ids, [])

    results =
      Enum.map(agent_ids, fn agent_id ->
        try do
          # Requeue any tasks assigned to this offline agent
          assigned = AgentCom.TaskQueue.list(status: :assigned)
          agent_tasks = Enum.filter(assigned, fn t -> t.assigned_to == agent_id end)

          requeued =
            Enum.map(agent_tasks, fn task ->
              AgentCom.TaskQueue.reclaim_task(task.id)
              task.id
            end)

          {:cleaned, agent_id, requeued_tasks: requeued}
        catch
          kind, error ->
            {:error, agent_id, "#{kind}: #{inspect(error)}"}
        end
      end)

    %{action: :offline_agent_cleanup, results: results}
  end

  defp remediate(%{category: :unhealthy_endpoints, detail: detail}) do
    endpoint_ids = Map.get(detail, :endpoint_ids, [])

    # Attempt recovery with exponential backoff: 5s, 15s, 45s
    backoff_schedule = [5_000, 15_000, 45_000]

    recovery_results =
      Enum.map(endpoint_ids, fn ep_id ->
        try do
          recovered = attempt_endpoint_recovery(ep_id, backoff_schedule)
          if recovered, do: {:recovered, ep_id}, else: {:failed, ep_id}
        catch
          kind, error ->
            {:error, ep_id, "#{kind}: #{inspect(error)}"}
        end
      end)

    any_recovered =
      Enum.any?(recovery_results, fn
        {:recovered, _} -> true
        _ -> false
      end)

    # If no endpoints recovered, log that Claude fallback is available
    unless any_recovered do
      Logger.warning("healing_all_endpoints_failed_recovery",
        message: "all Ollama endpoints failed recovery, Claude tier fallback active"
      )

      :telemetry.execute(
        [:agent_com, :healing, :endpoint_fallback],
        %{failed_endpoints: length(endpoint_ids)},
        %{action: :claude_fallback}
      )
    end

    %{action: :endpoint_recovery, results: recovery_results, claude_fallback: not any_recovered}
  end

  defp remediate(%{category: :merge_conflicts, detail: detail}) do
    files = Map.get(detail, :files, [])

    try do
      task_params = %{
        description: "Fix merge conflicts in #{length(files)} file(s): #{Enum.join(Enum.take(files, 5), ", ")}",
        priority: "urgent",
        metadata: %{
          source: "healing",
          tags: ["healing", "merge-conflict", "ci"],
          files: files
        }
      }

      case AgentCom.TaskQueue.submit(task_params) do
        {:ok, task} ->
          Logger.info("healing_created_fix_task", task_id: task.id, files: files)
          %{action: :delegated_to_agent, task_id: task.id}

        {:error, reason} ->
          Logger.error("healing_failed_to_create_task", reason: inspect(reason))
          %{action: :delegation_failed, reason: reason}
      end
    catch
      kind, error ->
        %{action: :delegation_error, error: "#{kind}: #{inspect(error)}"}
    end
  end

  defp remediate(%{category: :compilation_failure, detail: detail}) do
    output = Map.get(detail, :output, "")

    try do
      task_params = %{
        description: "Fix compilation failure: #{String.slice(output, 0, 200)}",
        priority: "urgent",
        metadata: %{
          source: "healing",
          tags: ["healing", "compilation", "ci"],
          error_output: String.slice(output, 0, 1000)
        }
      }

      case AgentCom.TaskQueue.submit(task_params) do
        {:ok, task} ->
          Logger.info("healing_created_compile_fix_task", task_id: task.id)
          %{action: :delegated_to_agent, task_id: task.id}

        {:error, reason} ->
          %{action: :delegation_failed, reason: reason}
      end
    catch
      kind, error ->
        %{action: :delegation_error, error: "#{kind}: #{inspect(error)}"}
    end
  end

  defp remediate(%{category: :high_error_rate}) do
    # No automated fix for high error rate -- log for awareness
    Logger.warning("healing_high_error_rate",
      message: "high error rate detected, no automated fix"
    )

    %{action: :high_error_rate_noted, results: [:logged]}
  end

  # Catch-all for unknown categories
  defp remediate(%{category: category}) do
    Logger.warning("healing_unknown_category", category: category)
    %{action: :unknown, results: [:skipped]}
  end

  # ---------------------------------------------------------------------------
  # Endpoint recovery with exponential backoff
  # ---------------------------------------------------------------------------

  defp attempt_endpoint_recovery(endpoint_id, [delay | rest]) do
    # Get endpoint URL from registry
    endpoints =
      try do
        AgentCom.LlmRegistry.list_endpoints()
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    endpoint = Enum.find(endpoints, fn ep -> ep.id == endpoint_id end)

    if endpoint do
      url = "http://#{endpoint.host}:#{endpoint.port}/api/tags"

      case safe_http_get(url, 5_000) do
        {:ok, _} ->
          Logger.info("healing_endpoint_recovered", endpoint_id: endpoint_id)
          true

        {:error, _} ->
          Process.sleep(delay)
          attempt_endpoint_recovery(endpoint_id, rest)
      end
    else
      false
    end
  end

  defp attempt_endpoint_recovery(_endpoint_id, []), do: false

  defp safe_http_get(url, timeout) do
    try do
      charlist_url = String.to_charlist(url)
      timeout_opts = [timeout: timeout, connect_timeout: timeout]

      case :httpc.request(:get, {charlist_url, []}, timeout_opts, []) do
        {:ok, {{_, status, _}, _headers, _body}} when status in 200..299 ->
          {:ok, status}

        {:ok, {{_, status, _}, _, _}} ->
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, "rescue: #{inspect(e)}"}
    catch
      kind, error -> {:error, "#{kind}: #{inspect(error)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Helper functions
  # ---------------------------------------------------------------------------

  defp priority(%{category: :stuck_tasks}), do: 1
  defp priority(%{category: :offline_agents}), do: 2
  defp priority(%{category: :unhealthy_endpoints}), do: 3
  defp priority(%{category: :merge_conflicts}), do: 4
  defp priority(%{category: :compilation_failure}), do: 5
  defp priority(%{category: :high_error_rate}), do: 6
  defp priority(_), do: 99

  defp find_agent(agent_id) do
    try do
      agents = AgentCom.AgentFSM.list_all()
      Enum.find(agents, fn a -> a.agent_id == agent_id end)
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp log_action(issue, result) do
    # Record to audit log
    AgentCom.HubFSM.HealingHistory.record(
      issue.category,
      %{severity: issue.severity, detail: issue.detail},
      result
    )

    # Emit telemetry
    :telemetry.execute(
      [:agent_com, :healing, :action],
      %{timestamp: System.system_time(:millisecond)},
      %{category: issue.category, severity: issue.severity, result: result}
    )
  end
end
