defmodule AgentCom.TaskQueue do
  @moduledoc """
  Persistent task queue with priority lanes, retry logic, and dead-letter storage.

  Tasks are stored in DETS and survive hub restarts. Priority ordering uses
  integer weights (0=urgent, 1=high, 2=normal, 3=low) with FIFO within each
  lane. An in-memory sorted index enables O(1) dequeue of the highest-priority
  queued task.

  Backed by two DETS tables:
  - `:task_queue` for active tasks (queued, assigned, completed)
  - `:task_dead_letter` for failed tasks that exhausted retries

  ## Generation Fencing (TASK-05)

  Each task carries a monotonically increasing `generation` counter. Every
  assignment bumps the generation. `complete_task/3` and `fail_task/3` require
  the caller to supply the correct generation -- stale updates from a previous
  assignment are rejected with `{:error, :stale_generation}`.

  ## Crash Safety (TASK-06)

  Every DETS mutation is followed by an explicit `:dets.sync/1` call, ensuring
  data is flushed to disk before the GenServer replies. The `auto_save: 5_000`
  option provides an additional safety net.

  ## Public API

  - `submit/1` -- Submit a new task to the queue
  - `get/1` -- Retrieve a task by ID (checks both tables)
  - `list/1` -- List tasks with optional filters
  - `list_dead_letter/0` -- List all dead-letter tasks
  - `dequeue_next/1` -- Peek at the highest-priority queued task
  - `assign_task/3` -- Assign a queued task to an agent
  - `complete_task/3` -- Mark a task as completed (generation-fenced)
  - `fail_task/3` -- Mark a task as failed; retries or dead-letters
  - `update_progress/1` -- Touch `updated_at` to prevent overdue sweep
  - `recover_task/1` -- Check task state for sidecar recovery
  - `retry_dead_letter/1` -- Move a dead-letter task back to the queue
  - `tasks_assigned_to/1` -- All tasks assigned to an agent
  - `stats/0` -- Queue statistics by status and priority
  """

  use GenServer
  require Logger

  @tasks_table :task_queue
  @dead_letter_table :task_dead_letter
  @sweep_interval_ms 30_000
  @default_max_retries 3
  @priority_map %{"urgent" => 0, "high" => 1, "normal" => 2, "low" => 3}
  @history_cap 50

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Submit a new task. Returns `{:ok, task}`."
  def submit(params) when is_map(params) do
    GenServer.call(__MODULE__, {:submit, params})
  end

  @doc "Get a task by ID. Returns `{:ok, task}` or `{:error, :not_found}`."
  def get(task_id) do
    GenServer.call(__MODULE__, {:get, task_id})
  end

  @doc """
  List tasks with optional filters.

  Options:
  - `status:` -- filter by status atom
  - `priority:` -- filter by priority string or integer
  - `assigned_to:` -- filter by agent ID
  """
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @doc "List all dead-letter tasks."
  def list_dead_letter do
    GenServer.call(__MODULE__, :list_dead_letter)
  end

  @doc """
  Peek at the highest-priority queued task without assigning it.
  Returns `{:ok, task}` or `{:error, :empty}`.
  """
  def dequeue_next(opts \\ []) do
    GenServer.call(__MODULE__, {:dequeue_next, opts})
  end

  @doc """
  Assign a queued task to an agent. Bumps generation for fencing.
  Returns `{:ok, task}` or `{:error, reason}`.
  """
  def assign_task(task_id, agent_id, opts \\ []) do
    GenServer.call(__MODULE__, {:assign_task, task_id, agent_id, opts})
  end

  @doc """
  Mark a task as completed. Requires matching generation (TASK-05 fencing).
  `result_params` should include `result` and optionally `tokens_used`.
  Returns `{:ok, task}` or `{:error, :stale_generation | :invalid_state | :not_found}`.
  """
  def complete_task(task_id, generation, result_params) do
    GenServer.call(__MODULE__, {:complete_task, task_id, generation, result_params})
  end

  @doc """
  Mark a task as failed. Requires matching generation (TASK-05 fencing).
  Retries if under max_retries, otherwise moves to dead-letter.
  Returns `{:ok, :retried, task}` or `{:ok, :dead_letter, task}` or `{:error, reason}`.
  """
  def fail_task(task_id, generation, error) do
    GenServer.call(__MODULE__, {:fail_task, task_id, generation, error})
  end

  @doc "Touch `updated_at` on an assigned task to prevent overdue sweep. Fire-and-forget."
  def update_progress(task_id) do
    GenServer.cast(__MODULE__, {:update_progress, task_id})
  end

  @doc """
  Check task state for sidecar recovery.
  Returns `{:ok, :continue, task}` or `{:ok, :reassign}` or `{:error, :not_found}`.
  """
  def recover_task(task_id) do
    GenServer.call(__MODULE__, {:recover_task, task_id})
  end

  @doc "Move a dead-letter task back to the queue with reset retry count."
  def retry_dead_letter(task_id) do
    GenServer.call(__MODULE__, {:retry_dead_letter, task_id})
  end

  @doc "Return all tasks currently assigned to the given agent."
  def tasks_assigned_to(agent_id) do
    GenServer.call(__MODULE__, {:tasks_assigned_to, agent_id})
  end

  @doc """
  Reclaim a specific task from an agent. Used by AgentFSM on disconnect or
  acceptance timeout. Resets task to :queued, bumps generation, re-adds to
  priority index. Returns {:ok, task} or {:error, :not_found | :not_assigned}.
  Idempotent: if task is already queued/completed, returns {:error, :not_assigned}.
  """
  def reclaim_task(task_id) do
    GenServer.call(__MODULE__, {:reclaim_task, task_id})
  end

  @doc "Store routing decision on a task. Called by Scheduler after routing."
  def store_routing_decision(task_id, routing_decision) do
    GenServer.call(__MODULE__, {:store_routing_decision, task_id, routing_decision})
  end

  @doc "Return queue statistics: counts by status and by priority."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    tasks_path = dets_path("task_queue.dets") |> String.to_charlist()
    dl_path = dets_path("task_dead_letter.dets") |> String.to_charlist()

    File.mkdir_p!(Path.dirname(dets_path("task_queue.dets")))

    {:ok, @tasks_table} =
      :dets.open_file(@tasks_table, file: tasks_path, type: :set, auto_save: 5_000)

    {:ok, @dead_letter_table} =
      :dets.open_file(@dead_letter_table, file: dl_path, type: :set, auto_save: 5_000)

    priority_index = rebuild_priority_index()

    Process.send_after(self(), :sweep_overdue, @sweep_interval_ms)

    {:ok, %{priority_index: priority_index, sweep_interval_ms: @sweep_interval_ms}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@tasks_table)
    :dets.close(@dead_letter_table)
    :ok
  end

  # -- submit ------------------------------------------------------------------

  @impl true
  def handle_call({:submit, params}, _from, state) do
    now = System.system_time(:millisecond)
    task_id = generate_task_id()

    priority_str = Map.get(params, :priority, Map.get(params, "priority", "normal"))
    priority = Map.get(@priority_map, to_string(priority_str), 2)

    submitted_by = Map.get(params, :submitted_by, Map.get(params, "submitted_by", "unknown"))

    task = %{
      id: task_id,
      description: Map.get(params, :description, Map.get(params, "description", "")),
      metadata: Map.get(params, :metadata, Map.get(params, "metadata", %{})),
      priority: priority,
      status: :queued,
      assigned_to: nil,
      assigned_at: nil,
      generation: 0,
      retry_count: 0,
      max_retries:
        Map.get(params, :max_retries, Map.get(params, "max_retries", @default_max_retries)),
      complete_by: Map.get(params, :complete_by, Map.get(params, "complete_by", nil)),
      needed_capabilities:
        Map.get(params, :needed_capabilities,
          Map.get(params, "needed_capabilities", [])),
      result: nil,
      tokens_used: nil,
      last_error: nil,
      submitted_by: submitted_by,
      created_at: now,
      updated_at: now,
      history: [{:queued, now, "submitted"}],
      # Enrichment fields (Phase 17)
      repo: Map.get(params, :repo, Map.get(params, "repo", nil)),
      branch: Map.get(params, :branch, Map.get(params, "branch", nil)),
      file_hints: Map.get(params, :file_hints, Map.get(params, "file_hints", [])),
      success_criteria: Map.get(params, :success_criteria, Map.get(params, "success_criteria", [])),
      verification_steps: Map.get(params, :verification_steps, Map.get(params, "verification_steps", [])),
      complexity: AgentCom.Complexity.build(params),
      routing_decision: nil,
      verification_report: nil
    }

    complexity = task.complexity

    persist_task(task, @tasks_table)

    # Emit telemetry when explicit tier disagrees with inferred tier (Phase 17)
    if complexity.explicit_tier && complexity.explicit_tier != complexity.inferred.tier do
      :telemetry.execute(
        [:agent_com, :complexity, :disagreement],
        %{},
        %{
          task_id: task_id,
          explicit_tier: complexity.explicit_tier,
          inferred_tier: complexity.inferred.tier,
          inferred_confidence: complexity.inferred.confidence
        }
      )
    end

    new_index = add_to_priority_index(state.priority_index, task)
    broadcast_task_event(:task_submitted, task)

    :telemetry.execute(
      [:agent_com, :task, :submit],
      %{queue_depth: length(new_index)},
      %{task_id: task_id, priority: priority, submitted_by: submitted_by}
    )

    {:reply, {:ok, task}, %{state | priority_index: new_index}}
  end

  # -- get ---------------------------------------------------------------------

  @impl true
  def handle_call({:get, task_id}, _from, state) do
    result =
      case lookup_task(task_id) do
        {:ok, task} -> {:ok, task}
        {:error, :not_found} -> lookup_dead_letter(task_id)
      end

    {:reply, result, state}
  end

  # -- list --------------------------------------------------------------------

  @impl true
  def handle_call({:list, opts}, _from, state) do
    status_filter = Keyword.get(opts, :status)
    priority_filter = Keyword.get(opts, :priority)
    assigned_filter = Keyword.get(opts, :assigned_to)

    priority_int =
      case priority_filter do
        nil -> nil
        p when is_integer(p) -> p
        p -> Map.get(@priority_map, to_string(p), nil)
      end

    tasks =
      :dets.foldl(
        fn {_id, task}, acc ->
          matches =
            (is_nil(status_filter) or task.status == status_filter) and
              (is_nil(priority_int) or task.priority == priority_int) and
              (is_nil(assigned_filter) or task.assigned_to == assigned_filter)

          if matches, do: [task | acc], else: acc
        end,
        [],
        @tasks_table
      )
      |> Enum.sort_by(&{&1.priority, &1.created_at})

    {:reply, tasks, state}
  end

  # -- list_dead_letter --------------------------------------------------------

  @impl true
  def handle_call(:list_dead_letter, _from, state) do
    tasks =
      :dets.foldl(fn {_id, task}, acc -> [task | acc] end, [], @dead_letter_table)
      |> Enum.sort_by(&{&1.priority, &1.created_at})

    {:reply, tasks, state}
  end

  # -- dequeue_next ------------------------------------------------------------

  @impl true
  def handle_call({:dequeue_next, _opts}, _from, state) do
    case state.priority_index do
      [] ->
        {:reply, {:error, :empty}, state}

      [{_priority, _created_at, task_id} | _rest] ->
        case lookup_task(task_id) do
          {:ok, task} -> {:reply, {:ok, task}, state}
          {:error, :not_found} ->
            # Index is stale; remove entry and try again
            new_index = remove_from_priority_index(state.priority_index, task_id)
            handle_call({:dequeue_next, []}, nil, %{state | priority_index: new_index})
        end
    end
  end

  # -- assign_task -------------------------------------------------------------

  @impl true
  def handle_call({:assign_task, task_id, agent_id, opts}, _from, state) do
    case lookup_task(task_id) do
      {:ok, %{status: :queued} = task} ->
        now = System.system_time(:millisecond)
        new_generation = task.generation + 1

        complete_by =
          Keyword.get(opts, :complete_by, task.complete_by)

        updated =
          %{task |
            status: :assigned,
            assigned_to: agent_id,
            assigned_at: now,
            generation: new_generation,
            complete_by: complete_by,
            updated_at: now,
            history:
              cap_history([
                {:assigned, now, %{agent_id: agent_id, generation: new_generation}}
                | task.history
              ])
          }

        persist_task(updated, @tasks_table)
        new_index = remove_from_priority_index(state.priority_index, task_id)
        broadcast_task_event(:task_assigned, updated)

        :telemetry.execute(
          [:agent_com, :task, :assign],
          %{wait_ms: now - task.created_at},
          %{task_id: task_id, agent_id: agent_id, generation: new_generation}
        )

        {:reply, {:ok, updated}, %{state | priority_index: new_index}}

      {:ok, %{status: status}} ->
        {:reply, {:error, {:invalid_state, status}}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # -- complete_task -----------------------------------------------------------

  @impl true
  def handle_call({:complete_task, task_id, generation, result_params}, _from, state) do
    case lookup_task(task_id) do
      {:ok, %{status: :assigned, generation: ^generation} = task} ->
        now = System.system_time(:millisecond)
        tokens_used = Map.get(result_params, :tokens_used, Map.get(result_params, "tokens_used"))
        result = Map.get(result_params, :result, Map.get(result_params, "result"))
        verification_report = Map.get(result_params, :verification_report, Map.get(result_params, "verification_report"))

        updated =
          %{task |
            status: :completed,
            result: result,
            tokens_used: tokens_used,
            verification_report: verification_report,
            updated_at: now,
            history:
              cap_history([{:completed, now, %{tokens_used: tokens_used}} | task.history])
          }

        persist_task(updated, @tasks_table)

        # Persist verification report to Store and emit telemetry
        if verification_report do
          AgentCom.Verification.Store.save(task_id, verification_report)

          summary = Map.get(verification_report, "summary", %{})
          :telemetry.execute(
            [:agent_com, :verification, :run],
            %{
              duration_ms: Map.get(verification_report, "duration_ms", 0),
              checks_passed: Map.get(summary, "passed", 0),
              checks_failed: Map.get(summary, "failed", 0)
            },
            %{
              task_id: task_id,
              status: Map.get(verification_report, "status", "unknown"),
              total_checks: Map.get(summary, "total", 0)
            }
          )
        end

        broadcast_task_event(:task_completed, updated)

        :telemetry.execute(
          [:agent_com, :task, :complete],
          %{duration_ms: now - task.assigned_at},
          %{task_id: task_id, agent_id: task.assigned_to, tokens_used: tokens_used}
        )

        {:reply, {:ok, updated}, state}

      {:ok, %{status: :assigned, generation: _other}} ->
        {:reply, {:error, :stale_generation}, state}

      {:ok, %{status: _other_status}} ->
        {:reply, {:error, :invalid_state}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # -- fail_task ---------------------------------------------------------------

  @impl true
  def handle_call({:fail_task, task_id, generation, error}, _from, state) do
    case lookup_task(task_id) do
      {:ok, %{status: :assigned, generation: ^generation} = task} ->
        now = System.system_time(:millisecond)
        new_retry_count = task.retry_count + 1

        if new_retry_count >= task.max_retries do
          # Dead-letter
          dead =
            %{task |
              status: :dead_letter,
              last_error: error,
              retry_count: new_retry_count,
              updated_at: now,
              history:
                cap_history([{:dead_letter, now, error} | task.history])
            }

          :dets.delete(@tasks_table, task_id)
          :dets.sync(@tasks_table)
          persist_task(dead, @dead_letter_table)
          broadcast_task_event(:task_dead_letter, dead)

          :telemetry.execute(
            [:agent_com, :task, :dead_letter],
            %{retry_count: new_retry_count},
            %{task_id: task_id, error: error}
          )

          {:reply, {:ok, :dead_letter, dead}, state}
        else
          # Retry
          retried =
            %{task |
              status: :queued,
              assigned_to: nil,
              assigned_at: nil,
              retry_count: new_retry_count,
              generation: task.generation + 1,
              last_error: error,
              updated_at: now,
              history:
                cap_history([{:retry, now, error} | task.history])
            }

          persist_task(retried, @tasks_table)
          new_index = add_to_priority_index(state.priority_index, retried)
          broadcast_task_event(:task_retried, retried)

          :telemetry.execute(
            [:agent_com, :task, :fail],
            %{retry_count: new_retry_count},
            %{task_id: task_id, agent_id: task.assigned_to, error: error}
          )

          {:reply, {:ok, :retried, retried}, %{state | priority_index: new_index}}
        end

      {:ok, %{status: :assigned, generation: _other}} ->
        {:reply, {:error, :stale_generation}, state}

      {:ok, %{status: _other_status}} ->
        {:reply, {:error, :invalid_state}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # -- recover_task ------------------------------------------------------------

  @impl true
  def handle_call({:recover_task, task_id}, _from, state) do
    case lookup_task(task_id) do
      {:ok, %{status: :assigned} = task} ->
        {:reply, {:ok, :continue, task}, state}

      {:ok, _task} ->
        {:reply, {:ok, :reassign}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # -- retry_dead_letter -------------------------------------------------------

  @impl true
  def handle_call({:retry_dead_letter, task_id}, _from, state) do
    case lookup_dead_letter(task_id) do
      {:ok, task} ->
        now = System.system_time(:millisecond)

        updated =
          %{task |
            status: :queued,
            retry_count: 0,
            assigned_to: nil,
            assigned_at: nil,
            generation: task.generation + 1,
            last_error: nil,
            updated_at: now,
            history:
              cap_history([{:queued, now, "retried from dead-letter"} | task.history])
          }

        :dets.delete(@dead_letter_table, task_id)
        :dets.sync(@dead_letter_table)
        persist_task(updated, @tasks_table)

        new_index = add_to_priority_index(state.priority_index, updated)
        broadcast_task_event(:task_retried, updated)

        :telemetry.execute(
          [:agent_com, :task, :retry],
          %{},
          %{task_id: task_id, previous_error: task.last_error}
        )

        {:reply, {:ok, updated}, %{state | priority_index: new_index}}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # -- tasks_assigned_to -------------------------------------------------------

  @impl true
  def handle_call({:tasks_assigned_to, agent_id}, _from, state) do
    tasks =
      :dets.foldl(
        fn {_id, task}, acc ->
          if task.status == :assigned and task.assigned_to == agent_id,
            do: [task | acc],
            else: acc
        end,
        [],
        @tasks_table
      )

    {:reply, tasks, state}
  end

  # -- reclaim_task ------------------------------------------------------------

  @impl true
  def handle_call({:reclaim_task, task_id}, _from, state) do
    case lookup_task(task_id) do
      {:ok, %{status: :assigned} = task} ->
        now = System.system_time(:millisecond)

        reclaimed =
          %{task |
            status: :queued,
            assigned_to: nil,
            assigned_at: nil,
            generation: task.generation + 1,
            updated_at: now,
            history:
              cap_history([{:reclaimed, now, "agent_disconnect"} | task.history])
          }

        persist_task(reclaimed, @tasks_table)
        new_index = add_to_priority_index(state.priority_index, reclaimed)
        broadcast_task_event(:task_reclaimed, reclaimed)

        :telemetry.execute(
          [:agent_com, :task, :reclaim],
          %{},
          %{task_id: task_id, agent_id: task.assigned_to, reason: :agent_disconnect}
        )

        {:reply, {:ok, reclaimed}, %{state | priority_index: new_index}}

      {:ok, _task} ->
        {:reply, {:error, :not_assigned}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # -- store_routing_decision --------------------------------------------------

  @impl true
  def handle_call({:store_routing_decision, task_id, routing_decision}, _from, state) do
    case lookup_task(task_id) do
      {:ok, task} ->
        updated = %{task | routing_decision: routing_decision}
        persist_task(updated, @tasks_table)
        {:reply, {:ok, updated}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # -- compact -----------------------------------------------------------------

  @impl true
  def handle_call({:compact, table_atom}, _from, state) when table_atom in [@tasks_table, @dead_letter_table] do
    path = :dets.info(table_atom, :filename)
    :ok = :dets.close(table_atom)

    case :dets.open_file(table_atom, file: path, type: :set, auto_save: 5_000, repair: :force) do
      {:ok, ^table_atom} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # -- stats -------------------------------------------------------------------

  @impl true
  def handle_call(:stats, _from, state) do
    {by_status, by_priority} =
      :dets.foldl(
        fn {_id, task}, {status_acc, priority_acc} ->
          new_status = Map.update(status_acc, task.status, 1, &(&1 + 1))
          new_priority = Map.update(priority_acc, task.priority, 1, &(&1 + 1))
          {new_status, new_priority}
        end,
        {%{}, %{}},
        @tasks_table
      )

    dead_letter_count =
      :dets.foldl(fn _entry, acc -> acc + 1 end, 0, @dead_letter_table)

    stats = %{
      by_status: by_status,
      by_priority: by_priority,
      dead_letter: dead_letter_count,
      queued_index_size: length(state.priority_index)
    }

    {:reply, stats, state}
  end

  # -- update_progress (cast) --------------------------------------------------

  @impl true
  def handle_cast({:update_progress, task_id}, state) do
    case lookup_task(task_id) do
      {:ok, %{status: :assigned} = task} ->
        now = System.system_time(:millisecond)
        updated = %{task | updated_at: now}
        persist_task(updated, @tasks_table)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  # -- sweep_overdue -----------------------------------------------------------

  @impl true
  def handle_info(:sweep_overdue, state) do
    now = System.system_time(:millisecond)

    overdue =
      :dets.foldl(
        fn {_id, task}, acc ->
          if task.status == :assigned and
               not is_nil(task.complete_by) and
               task.complete_by < now do
            [task | acc]
          else
            acc
          end
        end,
        [],
        @tasks_table
      )

    new_state =
      Enum.reduce(overdue, state, fn task, acc ->
        Logger.warning("task_overdue_reclaim",
          task_id: task.id,
          assigned_to: task.assigned_to
        )

        reclaimed =
          %{task |
            status: :queued,
            assigned_to: nil,
            assigned_at: nil,
            generation: task.generation + 1,
            updated_at: now,
            history:
              cap_history([{:reclaimed, now, "overdue"} | task.history])
          }

        persist_task(reclaimed, @tasks_table)
        new_index = add_to_priority_index(acc.priority_index, reclaimed)
        broadcast_task_event(:task_reclaimed, reclaimed)

        :telemetry.execute(
          [:agent_com, :task, :reclaim],
          %{},
          %{task_id: task.id, agent_id: task.assigned_to, reason: :overdue}
        )

        %{acc | priority_index: new_index}
      end)

    Process.send_after(self(), :sweep_overdue, state.sweep_interval_ms)
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp generate_task_id do
    "task-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp persist_task(task, table) do
    case :dets.insert(table, {task.id, task}) do
      :ok ->
        :dets.sync(table)
        :ok

      {:error, reason} ->
        Logger.error("dets_corruption_detected",
          table: table,
          reason: inspect(reason)
        )
        GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, table, reason})
        {:error, :table_corrupted}
    end
  end

  defp rebuild_priority_index do
    :dets.foldl(
      fn {_id, task}, acc ->
        if task.status == :queued do
          [{task.priority, task.created_at, task.id} | acc]
        else
          acc
        end
      end,
      [],
      @tasks_table
    )
    |> Enum.sort()
  end

  defp add_to_priority_index(index, task) do
    [{task.priority, task.created_at, task.id} | index]
    |> Enum.sort()
  end

  defp remove_from_priority_index(index, task_id) do
    Enum.reject(index, fn {_p, _c, id} -> id == task_id end)
  end

  defp broadcast_task_event(event, task) do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "tasks", {:task_event, %{
      event: event,
      task_id: task.id,
      task: task,
      timestamp: System.system_time(:millisecond)
    }})
  end

  defp cap_history(history) when length(history) > @history_cap do
    Enum.take(history, @history_cap)
  end

  defp cap_history(history), do: history

  defp lookup_task(task_id) do
    case :dets.lookup(@tasks_table, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
      {:error, reason} ->
        Logger.error("dets_corruption_detected",
          table: @tasks_table,
          reason: inspect(reason)
        )
        GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @tasks_table, reason})
        {:error, :table_corrupted}
    end
  end

  defp lookup_dead_letter(task_id) do
    case :dets.lookup(@dead_letter_table, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
      {:error, reason} ->
        Logger.error("dets_corruption_detected",
          table: @dead_letter_table,
          reason: inspect(reason)
        )
        GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @dead_letter_table, reason})
        {:error, :table_corrupted}
    end
  end

  defp dets_path(filename) do
    dir = Application.get_env(:agent_com, :task_queue_path, "priv")
    Path.join(dir, filename)
  end
end
