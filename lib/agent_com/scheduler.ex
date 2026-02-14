defmodule AgentCom.Scheduler do
  @moduledoc """
  Event-driven task-to-agent scheduler GenServer with tier-aware routing.

  The Scheduler subscribes to PubSub "tasks", "presence", and "llm_registry"
  topics and reacts to scheduling-opportunity events by running a greedy
  matching loop that pairs queued tasks with idle, capable agents.

  ## Design (SCHED-04)

  PubSub events are the primary scheduling trigger. A 30-second stuck-assignment
  sweep provides a safety net for edge cases where events are missed or agents
  silently disappear.

  ## Tier-Aware Routing (Phase 19)

  Before matching a task to an agent, the Scheduler routes each task through
  `TaskRouter.route/3` which considers complexity, endpoint availability, and
  host load to determine the best execution target. Routing decisions are stored
  on the task map and included in the task_data sent to agents.

  When routing returns a fallback signal (no viable endpoints at the preferred
  tier), the Scheduler sets a 5-second fallback timer. When the timer fires,
  a new scheduling attempt is triggered at the fallback tier.

  ## Scheduling triggers (SCHED-01)

  - `:task_submitted` -- new task queued
  - `:task_reclaimed` -- stuck/failed task returned to queue
  - `:task_retried` -- dead-letter task requeued
  - `:task_completed` -- agent finished work, now idle
  - `:agent_joined` -- new agent connected
  - `:endpoint_changed` -- LLM endpoint status changed (recovery/registration)

  Events that are explicitly NOT scheduling triggers:
  - `:task_assigned` -- would cause feedback loop
  - `:task_dead_letter` -- task exhausted retries, no scheduling needed

  ## Capability matching (SCHED-02)

  Exact string match with subset semantics. A task's `needed_capabilities` must
  be a subset of the agent's declared capabilities. Empty `needed_capabilities`
  means any agent qualifies.

  ## Stuck sweep (SCHED-03)

  Every 30 seconds, the scheduler scans assigned tasks for ones whose
  `updated_at` timestamp is older than 5 minutes. These are reclaimed via
  `TaskQueue.reclaim_task/1`, which broadcasts `:task_reclaimed` and triggers
  a new scheduling attempt.

  ## State

  The Scheduler holds `pending_fallbacks` -- a map of task_id to fallback timer
  info. Pending fallbacks are cancelled on task assignment, completion, reclaim,
  and dead-letter events.
  """

  use GenServer
  require Logger

  alias AgentCom.TaskRouter
  alias AgentCom.TaskRouter.TierResolver

  @stuck_sweep_interval_ms 30_000
  @stuck_threshold_ms 300_000
  @fallback_timeout_ms 5_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "llm_registry")

    Process.send_after(self(), :sweep_stuck, @stuck_sweep_interval_ms)
    Process.send_after(self(), :sweep_ttl, 60_000)

    Logger.info("scheduler_started", subscriptions: ["tasks", "presence", "llm_registry"])

    {:ok, %{pending_fallbacks: %{}}}
  end

  # -- Scheduling triggers: events that mean "there might be a match to make" --

  @impl true
  def handle_info({:task_event, %{event: :task_submitted}}, state) do
    state = try_schedule_all(:task_submitted, state)
    {:noreply, state}
  end

  def handle_info({:task_event, %{event: :task_reclaimed, task_id: tid}}, state) do
    state = cancel_pending_fallback(state, tid)
    state = try_schedule_all(:task_reclaimed, state)
    {:noreply, state}
  end

  def handle_info({:task_event, %{event: :task_retried}}, state) do
    state = try_schedule_all(:task_retried, state)
    {:noreply, state}
  end

  def handle_info({:task_event, %{event: :task_completed, task_id: tid}}, state) do
    state = cancel_pending_fallback(state, tid)
    state = try_schedule_all(:task_completed, state)
    {:noreply, state}
  end

  def handle_info({:task_event, %{event: :task_dead_letter, task_id: tid}}, state) do
    state = cancel_pending_fallback(state, tid)
    {:noreply, state}
  end

  def handle_info({:agent_joined, _info}, state) do
    state = try_schedule_all(:agent_joined, state)
    {:noreply, state}
  end

  def handle_info({:agent_idle, _info}, state) do
    state = try_schedule_all(:agent_idle, state)
    {:noreply, state}
  end

  # -- LLM Registry PubSub: endpoint changes trigger re-evaluation --

  def handle_info({:llm_registry_update, :endpoint_changed}, state) do
    state = try_schedule_all(:endpoint_changed, state)
    {:noreply, state}
  end

  # -- Fallback timer (Phase 19) --

  def handle_info({:fallback_timeout, task_id}, state) do
    case Map.pop(state.pending_fallbacks, task_id) do
      {nil, _} ->
        # Already handled (task was assigned/completed/reclaimed)
        {:noreply, state}

      {fallback_info, remaining} ->
        :telemetry.execute(
          [:agent_com, :scheduler, :fallback],
          %{wait_ms: System.system_time(:millisecond) - fallback_info.queued_at},
          %{
            task_id: task_id,
            original_tier: fallback_info.original_tier,
            fallback_tier: fallback_info.fallback_tier
          }
        )

        state = %{state | pending_fallbacks: remaining}

        # Re-check if task is still queued
        case AgentCom.TaskQueue.get(task_id) do
          {:ok, %{status: :queued}} ->
            state = try_schedule_all(:fallback_timeout, state)
            {:noreply, state}

          _ ->
            {:noreply, state}
        end
    end
  end

  # -- Non-scheduling events: explicitly ignored --

  def handle_info({:task_event, %{event: _other}}, state) do
    {:noreply, state}
  end

  def handle_info({:agent_left, _}, state) do
    {:noreply, state}
  end

  def handle_info({:status_changed, _}, state) do
    {:noreply, state}
  end

  # -- Stuck assignment sweep (SCHED-03) --

  def handle_info(:sweep_stuck, state) do
    now = System.system_time(:millisecond)
    threshold = now - @stuck_threshold_ms

    assigned_tasks = AgentCom.TaskQueue.list(status: :assigned)

    Enum.each(assigned_tasks, fn task ->
      if task.updated_at < threshold do
        staleness_ms = now - task.updated_at
        staleness_min = Float.round(staleness_ms / 60_000, 1)

        Logger.warning("scheduler_reclaim_stuck",
          task_id: task.id,
          assigned_to: task.assigned_to,
          stale_minutes: staleness_min
        )

        AgentCom.TaskQueue.reclaim_task(task.id)
      end
    end)

    Process.send_after(self(), :sweep_stuck, @stuck_sweep_interval_ms)
    {:noreply, state}
  end

  # -- Task TTL sweep (Phase 19-03) --

  def handle_info(:sweep_ttl, state) do
    ttl_ms = AgentCom.Config.get(:task_ttl_ms) || 600_000
    now = System.system_time(:millisecond)
    cutoff = now - ttl_ms

    queued_tasks = AgentCom.TaskQueue.list(status: :queued)

    expired =
      queued_tasks
      |> Enum.filter(fn task ->
        tier = get_in(task, [:complexity, :effective_tier])
        task.created_at < cutoff and tier != :trivial
      end)

    Enum.each(expired, fn task ->
      Logger.warning("scheduler_task_ttl_expired",
        task_id: task.id,
        age_ms: now - task.created_at,
        ttl_ms: ttl_ms
      )

      AgentCom.TaskQueue.expire_task(task.id)
    end)

    Process.send_after(self(), :sweep_ttl, 60_000)
    {:noreply, state}
  end

  # -- Catch-all for unexpected messages --

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private: scheduling logic
  # ---------------------------------------------------------------------------

  defp try_schedule_all(trigger, state) do
    idle_agents =
      AgentCom.AgentFSM.list_all()
      |> Enum.filter(fn a -> a.fsm_state == :idle end)
      |> Enum.reject(fn a -> AgentCom.RateLimiter.rate_limited?(a.agent_id) end)

    case idle_agents do
      [] ->
        queued_tasks = AgentCom.TaskQueue.list(status: :queued)

        :telemetry.execute(
          [:agent_com, :scheduler, :attempt],
          %{idle_agents: 0, queued_tasks: length(queued_tasks)},
          %{trigger: trigger}
        )

        state

      agents ->
        queued_tasks = AgentCom.TaskQueue.list(status: :queued)

        # Phase 23: Filter out tasks for paused repos
        schedulable_tasks =
          try do
            active_repo_urls = AgentCom.RepoRegistry.active_repo_ids()
            all_repo_urls = AgentCom.RepoRegistry.list_repos() |> Enum.map(& &1.url)

            Enum.filter(queued_tasks, fn task ->
              repo = Map.get(task, :repo)
              cond do
                # nil repo = always schedulable (backward compat)
                is_nil(repo) -> true
                # Repo is active in registry = schedulable
                repo in active_repo_urls -> true
                # Repo is in registry but NOT active (paused) = skip
                repo in all_repo_urls -> false
                # Repo not in registry at all = schedulable (ad-hoc task)
                true -> true
              end
            end)
          rescue
            _ -> queued_tasks
          end

        # Phase 28: Filter out tasks whose dependencies are not yet completed
        schedulable_tasks =
          Enum.filter(schedulable_tasks, fn task ->
            deps = Map.get(task, :depends_on, [])
            deps == [] or Enum.all?(deps, fn dep_id ->
              case AgentCom.TaskQueue.get(dep_id) do
                {:ok, %{status: :completed}} -> true
                _ -> false
              end
            end)
          end)

        :telemetry.execute(
          [:agent_com, :scheduler, :attempt],
          %{idle_agents: length(agents), queued_tasks: length(schedulable_tasks)},
          %{trigger: trigger}
        )

        # Fetch LLM endpoint data for routing
        endpoints = AgentCom.LlmRegistry.list_endpoints()
        endpoint_resources = gather_endpoint_resources(endpoints)

        do_match_loop(schedulable_tasks, agents, endpoints, endpoint_resources, state)
    end
  end

  defp gather_endpoint_resources(endpoints) do
    Enum.reduce(endpoints, %{}, fn ep, acc ->
      case AgentCom.LlmRegistry.get_resources(ep.id) do
        {:ok, resources} -> Map.put(acc, ep.id, resources)
        {:error, :not_found} -> acc
      end
    end)
  end

  defp do_match_loop([], _agents, _endpoints, _resources, state), do: state
  defp do_match_loop(_tasks, [], _endpoints, _resources, state), do: state

  defp do_match_loop([task | rest_tasks], agents, endpoints, endpoint_resources, state) do
    start_us = System.monotonic_time(:microsecond)

    case TaskRouter.route(task, endpoints, endpoint_resources) do
      {:ok, decision} ->
        scoring_duration_us = System.monotonic_time(:microsecond) - start_us

        # Emit routing telemetry
        :telemetry.execute(
          [:agent_com, :scheduler, :route],
          %{candidate_count: decision.candidate_count, scoring_duration_us: scoring_duration_us},
          %{
            task_id: task.id,
            effective_tier: decision.effective_tier,
            target_type: decision.target_type,
            selected_endpoint: decision.selected_endpoint,
            selected_model: decision.selected_model,
            fallback_used: decision.fallback_used,
            fallback_reason: decision.fallback_reason,
            classification_reason: decision.classification_reason,
            estimated_cost_tier: decision.estimated_cost_tier
          }
        )

        # Find matching agent based on target type
        matched_agent = find_agent_for_decision(decision, task, agents)

        case matched_agent do
          nil ->
            # No matching agent, try next task
            do_match_loop(rest_tasks, agents, endpoints, endpoint_resources, state)

          agent ->
            state = do_assign(task, agent, decision, state)
            remaining_agents = Enum.reject(agents, fn a -> a.agent_id == agent.agent_id end)
            do_match_loop(rest_tasks, remaining_agents, endpoints, endpoint_resources, state)
        end

      {:fallback, tier, reason} ->
        scoring_duration_us = System.monotonic_time(:microsecond) - start_us

        # Check fallback tier
        fallback_tier = TierResolver.fallback_up(tier)

        if fallback_tier do
          # Set fallback timer unless one already exists for this task
          state =
            if Map.has_key?(state.pending_fallbacks, task.id) do
              state
            else
              fallback_ms = AgentCom.Config.get(:fallback_wait_ms) || @fallback_timeout_ms
              timer_ref = Process.send_after(self(), {:fallback_timeout, task.id}, fallback_ms)

              fallback_info = %{
                original_tier: tier,
                fallback_tier: fallback_tier,
                timer_ref: timer_ref,
                queued_at: System.system_time(:millisecond)
              }

              %{state | pending_fallbacks: Map.put(state.pending_fallbacks, task.id, fallback_info)}
            end

          # Still try to assign using capability matching as fallback
          # This ensures backward compatibility when no LLM endpoints are registered
          fallback_decision = %{
            effective_tier: tier,
            target_type: tier_to_target_type(tier),
            selected_endpoint: nil,
            selected_model: nil,
            fallback_used: true,
            fallback_from_tier: tier,
            fallback_reason: reason,
            candidate_count: 0,
            classification_reason: build_fallback_classification_reason(task, tier, reason),
            estimated_cost_tier: tier_to_cost(tier),
            decided_at: System.system_time(:millisecond)
          }

          # Emit routing telemetry for the fallback decision
          :telemetry.execute(
            [:agent_com, :scheduler, :route],
            %{candidate_count: 0, scoring_duration_us: scoring_duration_us},
            %{
              task_id: task.id,
              effective_tier: tier,
              target_type: fallback_decision.target_type,
              selected_endpoint: nil,
              selected_model: nil,
              fallback_used: true,
              fallback_reason: reason,
              classification_reason: fallback_decision.classification_reason,
              estimated_cost_tier: fallback_decision.estimated_cost_tier
            }
          )

          # Try capability matching as graceful degradation
          matched_agent = Enum.find(agents, fn agent -> agent_matches_task?(agent, task) end)

          case matched_agent do
            nil ->
              do_match_loop(rest_tasks, agents, endpoints, endpoint_resources, state)

            agent ->
              state = do_assign(task, agent, fallback_decision, state)
              remaining_agents = Enum.reject(agents, fn a -> a.agent_id == agent.agent_id end)
              do_match_loop(rest_tasks, remaining_agents, endpoints, endpoint_resources, state)
          end
        else
          # No fallback tier available, try capability matching anyway
          matched_agent = Enum.find(agents, fn agent -> agent_matches_task?(agent, task) end)

          fallback_decision = %{
            effective_tier: tier,
            target_type: tier_to_target_type(tier),
            selected_endpoint: nil,
            selected_model: nil,
            fallback_used: true,
            fallback_from_tier: tier,
            fallback_reason: reason,
            candidate_count: 0,
            classification_reason: build_fallback_classification_reason(task, tier, reason),
            estimated_cost_tier: tier_to_cost(tier),
            decided_at: System.system_time(:millisecond)
          }

          :telemetry.execute(
            [:agent_com, :scheduler, :route],
            %{candidate_count: 0, scoring_duration_us: scoring_duration_us},
            %{
              task_id: task.id,
              effective_tier: tier,
              target_type: fallback_decision.target_type,
              selected_endpoint: nil,
              selected_model: nil,
              fallback_used: true,
              fallback_reason: reason,
              classification_reason: fallback_decision.classification_reason,
              estimated_cost_tier: fallback_decision.estimated_cost_tier
            }
          )

          case matched_agent do
            nil ->
              do_match_loop(rest_tasks, agents, endpoints, endpoint_resources, state)

            agent ->
              state = do_assign(task, agent, fallback_decision, state)
              remaining_agents = Enum.reject(agents, fn a -> a.agent_id == agent.agent_id end)
              do_match_loop(rest_tasks, remaining_agents, endpoints, endpoint_resources, state)
          end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: agent matching for routing decisions
  # ---------------------------------------------------------------------------

  defp find_agent_for_decision(decision, task, agents) do
    # If task has assign_to, target that specific agent (operator override)
    assign_to = Map.get(task, :assign_to) || get_in(task, [:metadata, "assign_to"])

    if assign_to do
      Enum.find(agents, fn agent -> agent.agent_id == assign_to end)
    else
      case decision.target_type do
        :sidecar ->
          # Trivial tasks: any idle agent with matching capabilities
          Enum.find(agents, fn agent -> agent_matches_task?(agent, task) end)

        :ollama ->
          # Standard tasks: prefer agent whose ollama_url host matches the selected endpoint
          preferred = Enum.find(agents, fn agent ->
            agent_matches_task?(agent, task) and
              agent_matches_endpoint?(agent, decision.selected_endpoint)
          end)

          preferred || Enum.find(agents, fn agent -> agent_matches_task?(agent, task) end)

        :claude ->
          # Complex tasks: any idle agent with matching capabilities
          Enum.find(agents, fn agent -> agent_matches_task?(agent, task) end)
      end
    end
  end

  defp agent_matches_endpoint?(agent, selected_endpoint) when is_binary(selected_endpoint) do
    ollama_url = Map.get(agent, :ollama_url, "")

    if ollama_url != "" and is_binary(ollama_url) do
      String.contains?(ollama_url, String.split(selected_endpoint, ":") |> List.first() || "")
    else
      false
    end
  end

  defp agent_matches_endpoint?(_agent, _endpoint), do: false

  defp agent_matches_task?(agent, task) do
    needed = Map.get(task, :needed_capabilities, [])

    if needed == [] do
      true
    else
      agent_cap_names =
        (agent.capabilities || [])
        |> Enum.map(fn
          %{name: name} -> name
          cap when is_binary(cap) -> cap
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      Enum.all?(needed, fn cap -> cap in agent_cap_names end)
    end
  end

  # ---------------------------------------------------------------------------
  # Private: assignment
  # ---------------------------------------------------------------------------

  defp do_assign(task, agent, routing_decision, state) do
    # Store routing decision on the task
    AgentCom.TaskQueue.store_routing_decision(task.id, routing_decision)

    case AgentCom.TaskQueue.assign_task(task.id, agent.agent_id) do
      {:ok, assigned_task} ->
        task_data = %{
          task_id: assigned_task.id,
          description: assigned_task.description,
          metadata: assigned_task.metadata,
          generation: assigned_task.generation,
          # Enrichment fields (Phase 17)
          repo: Map.get(assigned_task, :repo),
          branch: Map.get(assigned_task, :branch),
          file_hints: Map.get(assigned_task, :file_hints, []),
          success_criteria: Map.get(assigned_task, :success_criteria, []),
          verification_steps: Map.get(assigned_task, :verification_steps, []),
          complexity: Map.get(assigned_task, :complexity),
          # Routing decision (Phase 19)
          routing_decision: routing_decision,
          # Verification control (Phase 21/22)
          skip_verification: Map.get(assigned_task, :skip_verification, false),
          verification_timeout_ms: Map.get(assigned_task, :verification_timeout_ms),
          max_verification_retries: Map.get(assigned_task, :max_verification_retries, 0),
          # Pipeline dependency fields (Phase 28)
          depends_on: Map.get(assigned_task, :depends_on, []),
          goal_id: Map.get(assigned_task, :goal_id)
        }

        :telemetry.execute(
          [:agent_com, :scheduler, :match],
          %{},
          %{task_id: task.id, agent_id: agent.agent_id}
        )

        case Registry.lookup(AgentCom.AgentRegistry, agent.agent_id) do
          [{pid, _meta}] ->
            send(pid, {:push_task, task_data})

            Logger.info("scheduler_assigned",
              task_id: task.id,
              agent_id: agent.agent_id,
              target_type: routing_decision.target_type,
              effective_tier: routing_decision.effective_tier
            )

          [] ->
            Logger.warning("scheduler_ws_not_found",
              task_id: task.id,
              agent_id: agent.agent_id
            )
        end

        # Cancel any pending fallback for this task
        cancel_pending_fallback(state, task.id)

      {:error, reason} ->
        Logger.warning("scheduler_assign_failed",
          task_id: task.id,
          agent_id: agent.agent_id,
          reason: inspect(reason)
        )

        state
    end
  end

  # ---------------------------------------------------------------------------
  # Private: fallback timer management
  # ---------------------------------------------------------------------------

  defp cancel_pending_fallback(state, task_id) do
    case Map.pop(state.pending_fallbacks, task_id) do
      {nil, _} -> state
      {info, remaining} ->
        Process.cancel_timer(info.timer_ref)
        %{state | pending_fallbacks: remaining}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: helper functions
  # ---------------------------------------------------------------------------

  defp tier_to_target_type(:trivial), do: :sidecar
  defp tier_to_target_type(:standard), do: :ollama
  defp tier_to_target_type(:complex), do: :claude
  defp tier_to_target_type(_), do: :ollama

  defp tier_to_cost(:trivial), do: :free
  defp tier_to_cost(:standard), do: :local
  defp tier_to_cost(:complex), do: :api
  defp tier_to_cost(_), do: :local

  defp build_fallback_classification_reason(task, tier, reason) do
    base = case task do
      %{complexity: %{source: source, effective_tier: etier, inferred: %{confidence: conf}}} ->
        "#{source}:#{etier} (confidence #{format_confidence(conf)})"

      %{complexity: %{source: source, effective_tier: etier}} ->
        "#{source}:#{etier}"

      _ ->
        "none:standard"
    end

    "#{base} [fallback from #{tier}: #{reason}]"
  end

  defp format_confidence(conf) when is_float(conf), do: :erlang.float_to_binary(conf, decimals: 2)
  defp format_confidence(conf), do: "#{conf}"
end
