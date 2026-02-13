defmodule AgentCom.GoalBacklog do
  @moduledoc """
  Persistent goal backlog with lifecycle state machine, priority ordering,
  and PubSub event broadcasting.

  Goals are higher-level work items that decompose into 1-N tasks. This
  GenServer is the centralized storage and lifecycle engine. Goals persist
  in DETS and survive restarts. An in-memory priority index enables O(1)
  dequeue of the highest-priority submitted goal.

  ## Lifecycle State Machine

  Goals follow a strict lifecycle:

      submitted -> decomposing -> executing -> verifying -> complete
                        |             |            |
                        +-> failed <--+-- failed <-+
                                           |
                        verifying -> executing (retry)

  ## Public API

  - `submit/1` -- Submit a new goal
  - `get/1` -- Retrieve a goal by ID
  - `list/1` -- List goals with optional filters
  - `dequeue/0` -- Pop highest-priority submitted goal, transition to decomposing
  - `transition/3` -- Move a goal through lifecycle states
  - `stats/0` -- Counts by status and priority
  - `delete/1` -- Remove a goal
  """

  use GenServer
  require Logger

  @table :goal_backlog
  @priority_map %{"urgent" => 0, "high" => 1, "normal" => 2, "low" => 3}
  @valid_transitions %{
    submitted: [:decomposing],
    decomposing: [:executing, :failed],
    executing: [:verifying, :failed],
    verifying: [:complete, :failed, :executing]
  }
  @history_cap 50

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Submit a new goal. Returns `{:ok, goal}`."
  def submit(params) when is_map(params) do
    GenServer.call(__MODULE__, {:submit, params})
  end

  @doc "Get a goal by ID. Returns `{:ok, goal}` or `{:error, :not_found}`."
  def get(goal_id) do
    GenServer.call(__MODULE__, {:get, goal_id})
  end

  @doc """
  List goals with optional filters.

  Filters (map keys):
  - `:status` -- filter by status atom
  - `:priority` -- filter by priority string or integer
  """
  def list(filters \\ %{}) do
    GenServer.call(__MODULE__, {:list, filters})
  end

  @doc """
  Transition a goal to a new status. Validates against lifecycle state machine.
  Returns `{:ok, updated_goal}` or `{:error, {:invalid_transition, from, to}}` or `{:error, :not_found}`.

  Options:
  - `:child_task_ids` -- list of task IDs created during decomposition
  - `:reason` -- reason for transition (e.g., failure reason)
  """
  def transition(goal_id, new_status, opts \\ []) do
    GenServer.call(__MODULE__, {:transition, goal_id, new_status, opts})
  end

  @doc """
  Dequeue the highest-priority submitted goal, transitioning it to :decomposing.
  Returns `{:ok, goal}` or `{:error, :empty}`.
  """
  def dequeue do
    GenServer.call(__MODULE__, :dequeue)
  end

  @doc "Return goal statistics: counts by status and priority."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Delete a goal. Returns `:ok` or `{:error, :not_found}`."
  def delete(goal_id) do
    GenServer.call(__MODULE__, {:delete, goal_id})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    dir = data_dir()
    File.mkdir_p!(dir)

    path = Path.join(dir, "goal_backlog.dets") |> String.to_charlist()

    {:ok, @table} =
      :dets.open_file(@table, file: path, type: :set, auto_save: 5_000)

    priority_index = rebuild_priority_index()

    Logger.info("goal_backlog_started",
      goals_loaded: :dets.info(@table, :no_objects),
      submitted_queued: length(priority_index)
    )

    {:ok, %{priority_index: priority_index}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  # -- submit ------------------------------------------------------------------

  @impl true
  def handle_call({:submit, params}, _from, state) do
    now = System.system_time(:millisecond)
    goal_id = generate_goal_id()

    priority_str = Map.get(params, :priority, Map.get(params, "priority", "normal"))
    priority = Map.get(@priority_map, to_string(priority_str), 2)

    goal = %{
      id: goal_id,
      description: Map.get(params, :description, Map.get(params, "description", "")),
      success_criteria: Map.get(params, :success_criteria, Map.get(params, "success_criteria", "")),
      priority: priority,
      status: :submitted,
      source: Map.get(params, :source, Map.get(params, "source", "api")),
      tags: Map.get(params, :tags, Map.get(params, "tags", [])),
      repo: Map.get(params, :repo, Map.get(params, "repo", nil)),
      file_hints: Map.get(params, :file_hints, Map.get(params, "file_hints", [])),
      metadata: Map.get(params, :metadata, Map.get(params, "metadata", %{})),
      submitted_by: Map.get(params, :submitted_by, Map.get(params, "submitted_by", nil)),
      depends_on: Map.get(params, :depends_on, Map.get(params, "depends_on", [])),
      child_task_ids: [],
      created_at: now,
      updated_at: now,
      history: [{:submitted, now, "goal submitted"}]
    }

    persist_goal(goal)

    new_index = add_to_priority_index(state.priority_index, goal)
    broadcast_goal_event(:goal_submitted, goal)

    :telemetry.execute(
      [:agent_com, :goal, :submit],
      %{queue_depth: length(new_index)},
      %{goal_id: goal_id, priority: priority, source: goal.source}
    )

    {:reply, {:ok, goal}, %{state | priority_index: new_index}}
  end

  # -- get ---------------------------------------------------------------------

  @impl true
  def handle_call({:get, goal_id}, _from, state) do
    result = lookup_goal(goal_id)
    {:reply, result, state}
  end

  # -- list --------------------------------------------------------------------

  @impl true
  def handle_call({:list, filters}, _from, state) do
    status_filter = Map.get(filters, :status)
    priority_filter = Map.get(filters, :priority)

    priority_int =
      case priority_filter do
        nil -> nil
        p when is_integer(p) -> p
        p -> Map.get(@priority_map, to_string(p), nil)
      end

    goals =
      :dets.foldl(
        fn {_id, goal}, acc ->
          matches =
            (is_nil(status_filter) or goal.status == status_filter) and
              (is_nil(priority_int) or goal.priority == priority_int)

          if matches, do: [goal | acc], else: acc
        end,
        [],
        @table
      )
      |> Enum.sort_by(&{&1.priority, &1.created_at})

    {:reply, goals, state}
  end

  # -- transition --------------------------------------------------------------

  @impl true
  def handle_call({:transition, goal_id, new_status, opts}, _from, state) do
    case lookup_goal(goal_id) do
      {:ok, goal} ->
        allowed = Map.get(@valid_transitions, goal.status, [])

        if new_status in allowed do
          now = System.system_time(:millisecond)
          reason = Keyword.get(opts, :reason)
          child_task_ids = Keyword.get(opts, :child_task_ids)

          history_entry = {new_status, now, reason || "transition"}

          updated =
            %{goal |
              status: new_status,
              updated_at: now,
              history: cap_history([history_entry | goal.history])
            }

          updated =
            if child_task_ids do
              %{updated | child_task_ids: child_task_ids}
            else
              updated
            end

          persist_goal(updated)

          # Remove from priority index when leaving :submitted
          new_index =
            if goal.status == :submitted do
              remove_from_priority_index(state.priority_index, goal_id)
            else
              state.priority_index
            end

          event_name = String.to_atom("goal_#{new_status}")
          broadcast_goal_event(event_name, updated)

          :telemetry.execute(
            [:agent_com, :goal, :transition],
            %{},
            %{goal_id: goal_id, new_status: new_status, from_status: goal.status}
          )

          {:reply, {:ok, updated}, %{state | priority_index: new_index}}
        else
          {:reply, {:error, {:invalid_transition, goal.status, new_status}}, state}
        end

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # -- dequeue -----------------------------------------------------------------

  @impl true
  def handle_call(:dequeue, _from, state) do
    case state.priority_index do
      [] ->
        {:reply, {:error, :empty}, state}

      [{_priority, _created_at, goal_id} | rest] ->
        case lookup_goal(goal_id) do
          {:ok, goal} ->
            now = System.system_time(:millisecond)

            updated =
              %{goal |
                status: :decomposing,
                updated_at: now,
                history: cap_history([{:decomposing, now, "dequeued"} | goal.history])
              }

            persist_goal(updated)
            broadcast_goal_event(:goal_decomposing, updated)

            :telemetry.execute(
              [:agent_com, :goal, :transition],
              %{},
              %{goal_id: goal_id, new_status: :decomposing, from_status: :submitted}
            )

            {:reply, {:ok, updated}, %{state | priority_index: rest}}

          {:error, :not_found} ->
            # Stale index entry; remove and retry
            handle_call(:dequeue, nil, %{state | priority_index: rest})
        end
    end
  end

  # -- stats -------------------------------------------------------------------

  @impl true
  def handle_call(:stats, _from, state) do
    {by_status, by_priority, total} =
      :dets.foldl(
        fn {_id, goal}, {status_acc, priority_acc, count} ->
          new_status = Map.update(status_acc, goal.status, 1, &(&1 + 1))
          new_priority = Map.update(priority_acc, goal.priority, 1, &(&1 + 1))
          {new_status, new_priority, count + 1}
        end,
        {%{}, %{}, 0},
        @table
      )

    stats = %{
      by_status: by_status,
      by_priority: by_priority,
      total: total
    }

    {:reply, stats, state}
  end

  # -- delete ------------------------------------------------------------------

  @impl true
  def handle_call({:delete, goal_id}, _from, state) do
    case lookup_goal(goal_id) do
      {:ok, _goal} ->
        :dets.delete(@table, goal_id)
        :dets.sync(@table)
        new_index = remove_from_priority_index(state.priority_index, goal_id)
        {:reply, :ok, %{state | priority_index: new_index}}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # -- compact (for DetsBackup) ------------------------------------------------

  @impl true
  def handle_call(:compact, _from, state) do
    path = :dets.info(@table, :filename)
    :ok = :dets.close(@table)

    case :dets.open_file(@table, file: path, type: :set, auto_save: 5_000, repair: :force) do
      {:ok, @table} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp generate_goal_id do
    "goal-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp persist_goal(goal) do
    case :dets.insert(@table, {goal.id, goal}) do
      :ok ->
        :dets.sync(@table)
        :ok

      {:error, reason} ->
        Logger.error("dets_corruption_detected",
          table: @table,
          reason: inspect(reason)
        )

        GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @table, reason})
        {:error, :table_corrupted}
    end
  end

  defp lookup_goal(goal_id) do
    case :dets.lookup(@table, goal_id) do
      [{^goal_id, goal}] -> {:ok, goal}
      [] -> {:error, :not_found}

      {:error, reason} ->
        Logger.error("dets_corruption_detected",
          table: @table,
          reason: inspect(reason)
        )

        GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @table, reason})
        {:error, :table_corrupted}
    end
  end

  defp rebuild_priority_index do
    :dets.foldl(
      fn {_id, goal}, acc ->
        if goal.status == :submitted do
          [{goal.priority, goal.created_at, goal.id} | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
    |> Enum.sort()
  end

  defp add_to_priority_index(index, goal) do
    [{goal.priority, goal.created_at, goal.id} | index]
    |> Enum.sort()
  end

  defp remove_from_priority_index(index, goal_id) do
    Enum.reject(index, fn {_p, _c, id} -> id == goal_id end)
  end

  defp broadcast_goal_event(event, goal) do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "goals", {:goal_event, %{
      event: event,
      goal_id: goal.id,
      goal: goal,
      timestamp: System.system_time(:millisecond)
    }})
  end

  defp cap_history(history) when length(history) > @history_cap do
    Enum.take(history, @history_cap)
  end

  defp cap_history(history), do: history

  defp data_dir do
    Application.get_env(:agent_com, :goal_backlog_data_dir, "priv/data/goal_backlog")
  end
end
