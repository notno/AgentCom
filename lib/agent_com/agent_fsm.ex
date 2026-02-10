defmodule AgentCom.AgentFSM do
  @moduledoc """
  Per-agent finite state machine GenServer.

  Each connected agent gets a dedicated AgentFSM process that tracks its work
  lifecycle through validated state transitions:

      idle -> assigned -> working -> idle
                       -> blocked -> working -> idle
                       -> offline (from any state, on WebSocket disconnect)

  Key behaviors:
  - **Process monitoring:** Monitors the WebSocket pid and transitions to
    `:offline` (stopping itself) on `:DOWN`.
  - **Acceptance timeout:** When a task is assigned, a 60-second timer fires.
    If the agent has not accepted (transitioned to `:working`), the task is
    reclaimed and the agent is flagged `:unresponsive`.
  - **Capability normalization:** String capabilities are normalized to maps
    (`%{name: cap}`) on init.
  - **Registry lookup:** Processes are registered via `AgentCom.AgentFSMRegistry`
    for O(1) lookup by agent_id.

  ## Process lifecycle

  Agent processes use `restart: :temporary` -- they are not restarted on crash.
  The agent must reconnect via WebSocket to spawn a new FSM.
  """

  use GenServer
  require Logger

  @valid_transitions %{
    idle: [:assigned, :offline],
    assigned: [:working, :idle, :offline],
    working: [:idle, :blocked, :offline],
    blocked: [:working, :idle, :offline]
  }

  @acceptance_timeout_ms 60_000

  defstruct [
    :agent_id,
    :ws_pid,
    :ws_monitor_ref,
    :name,
    :capabilities,
    :connected_at,
    :last_state_change,
    :current_task_id,
    :acceptance_timer_ref,
    :fsm_state,
    flags: []
  ]

  # ---------------------------------------------------------------------------
  # Child spec -- restart: :temporary (agent must reconnect, not auto-restart)
  # ---------------------------------------------------------------------------

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }
  end

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start a new AgentFSM process registered under the given agent_id."
  def start_link(args) do
    agent_id = Keyword.fetch!(args, :agent_id)

    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {AgentCom.AgentFSMRegistry, agent_id}}
    )
  end

  @doc """
  Get the current state of an agent's FSM.

  Returns `{:ok, map}` with agent_id, fsm_state, current_task_id, capabilities,
  flags, connected_at, and last_state_change. Returns `{:error, :not_found}` if
  no FSM exists for the given agent_id.
  """
  def get_state(agent_id) do
    case lookup_fsm(agent_id) do
      {:ok, pid} -> GenServer.call(pid, :get_state)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Get the capabilities of an agent. Returns `{:ok, caps}` or `{:error, :not_found}`."
  def get_capabilities(agent_id) do
    case lookup_fsm(agent_id) do
      {:ok, pid} -> GenServer.call(pid, :get_capabilities)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  List all active AgentFSM processes.

  Uses Registry.select to enumerate all registered agent_ids, then calls
  get_state for each. Returns a list of state maps.
  """
  def list_all do
    AgentCom.AgentFSMRegistry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(fn agent_id ->
      case get_state(agent_id) do
        {:ok, state_map} -> state_map
        {:error, :not_found} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Assign a task to an agent. Transitions idle -> assigned."
  def assign_task(agent_id, task_id) do
    case lookup_fsm(agent_id) do
      {:ok, pid} -> GenServer.cast(pid, {:task_assigned, task_id})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Mark a task as accepted by the agent. Transitions assigned -> working."
  def task_accepted(agent_id, task_id) do
    case lookup_fsm(agent_id) do
      {:ok, pid} -> GenServer.cast(pid, {:task_accepted, task_id})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Mark the current task as completed. Transitions working -> idle."
  def task_completed(agent_id) do
    case lookup_fsm(agent_id) do
      {:ok, pid} -> GenServer.cast(pid, :task_completed)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Mark the current task as failed. Transitions working -> idle."
  def task_failed(agent_id) do
    case lookup_fsm(agent_id) do
      {:ok, pid} -> GenServer.cast(pid, :task_failed)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Mark the current task as blocked. Transitions working -> blocked."
  def task_blocked(agent_id) do
    case lookup_fsm(agent_id) do
      {:ok, pid} -> GenServer.cast(pid, :task_blocked)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Unblock the current task. Transitions blocked -> working."
  def task_unblocked(agent_id) do
    case lookup_fsm(agent_id) do
      {:ok, pid} -> GenServer.cast(pid, :task_unblocked)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(args) do
    agent_id = Keyword.fetch!(args, :agent_id)
    ws_pid = Keyword.fetch!(args, :ws_pid)
    name = Keyword.get(args, :name, agent_id)
    capabilities = Keyword.get(args, :capabilities, [])

    ref = Process.monitor(ws_pid)
    now = System.system_time(:millisecond)
    normalized_caps = normalize_capabilities(capabilities)

    # Check TaskQueue for existing assignments (reconnection scenario)
    assigned_tasks = AgentCom.TaskQueue.tasks_assigned_to(agent_id)

    {initial_state, task_id, timer_ref} =
      case assigned_tasks do
        [task | _] ->
          timer = Process.send_after(self(), {:acceptance_timeout, task.id}, @acceptance_timeout_ms)
          Logger.info("AgentFSM: agent #{agent_id} has existing assignment #{task.id}, starting in :assigned")
          {:assigned, task.id, timer}

        [] ->
          {:idle, nil, nil}
      end

    state = %__MODULE__{
      agent_id: agent_id,
      ws_pid: ws_pid,
      ws_monitor_ref: ref,
      name: name,
      capabilities: normalized_caps,
      connected_at: now,
      last_state_change: now,
      current_task_id: task_id,
      acceptance_timer_ref: timer_ref,
      fsm_state: initial_state,
      flags: []
    }

    # Push initial FSM state to Presence
    AgentCom.Presence.update_fsm_state(agent_id, initial_state)

    Logger.info("AgentFSM: started for agent #{agent_id} in state :#{initial_state}")

    {:ok, state}
  end

  # -- get_state ---------------------------------------------------------------

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = %{
      agent_id: state.agent_id,
      name: state.name,
      fsm_state: state.fsm_state,
      current_task_id: state.current_task_id,
      capabilities: state.capabilities,
      flags: state.flags,
      connected_at: state.connected_at,
      last_state_change: state.last_state_change
    }

    {:reply, {:ok, reply}, state}
  end

  # -- get_capabilities --------------------------------------------------------

  def handle_call(:get_capabilities, _from, state) do
    {:reply, {:ok, state.capabilities}, state}
  end

  # -- task_assigned -----------------------------------------------------------

  @impl true
  def handle_cast({:task_assigned, task_id}, state) do
    case transition(state, :assigned) do
      {:ok, new_state} ->
        timer = Process.send_after(self(), {:acceptance_timeout, task_id}, @acceptance_timeout_ms)

        updated = %{new_state |
          current_task_id: task_id,
          acceptance_timer_ref: timer
        }

        Logger.info("AgentFSM: agent #{state.agent_id} assigned task #{task_id}")
        {:noreply, updated}

      {:error, {:invalid_transition, from, to}} ->
        Logger.warning(
          "AgentFSM: invalid transition #{from} -> #{to} for agent #{state.agent_id} " <>
            "(task_assigned #{task_id})"
        )

        {:noreply, state}
    end
  end

  # -- task_accepted -----------------------------------------------------------

  def handle_cast({:task_accepted, task_id}, state) do
    if state.current_task_id == task_id and state.fsm_state == :assigned do
      cancel_timer(state.acceptance_timer_ref)

      case transition(state, :working) do
        {:ok, new_state} ->
          updated = %{new_state | acceptance_timer_ref: nil}
          Logger.info("AgentFSM: agent #{state.agent_id} accepted task #{task_id}")
          {:noreply, updated}

        {:error, {:invalid_transition, from, to}} ->
          Logger.warning(
            "AgentFSM: invalid transition #{from} -> #{to} for agent #{state.agent_id} " <>
              "(task_accepted #{task_id})"
          )

          {:noreply, state}
      end
    else
      Logger.warning(
        "AgentFSM: agent #{state.agent_id} received task_accepted for #{task_id} " <>
          "but current state is :#{state.fsm_state} with task #{inspect(state.current_task_id)}"
      )

      {:noreply, state}
    end
  end

  # -- task_completed ----------------------------------------------------------

  def handle_cast(:task_completed, state) do
    if state.fsm_state == :working do
      cancel_timer(state.acceptance_timer_ref)

      case transition(state, :idle) do
        {:ok, new_state} ->
          updated = %{new_state |
            current_task_id: nil,
            acceptance_timer_ref: nil
          }

          Logger.info("AgentFSM: agent #{state.agent_id} completed task #{state.current_task_id}")
          {:noreply, updated}

        {:error, {:invalid_transition, from, to}} ->
          Logger.warning(
            "AgentFSM: invalid transition #{from} -> #{to} for agent #{state.agent_id} (task_completed)"
          )

          {:noreply, state}
      end
    else
      Logger.warning(
        "AgentFSM: agent #{state.agent_id} received task_completed but is in :#{state.fsm_state}"
      )

      {:noreply, state}
    end
  end

  # -- task_failed -------------------------------------------------------------

  def handle_cast(:task_failed, state) do
    if state.fsm_state == :working do
      cancel_timer(state.acceptance_timer_ref)

      case transition(state, :idle) do
        {:ok, new_state} ->
          updated = %{new_state |
            current_task_id: nil,
            acceptance_timer_ref: nil
          }

          Logger.info("AgentFSM: agent #{state.agent_id} failed task #{state.current_task_id}")
          {:noreply, updated}

        {:error, {:invalid_transition, from, to}} ->
          Logger.warning(
            "AgentFSM: invalid transition #{from} -> #{to} for agent #{state.agent_id} (task_failed)"
          )

          {:noreply, state}
      end
    else
      Logger.warning(
        "AgentFSM: agent #{state.agent_id} received task_failed but is in :#{state.fsm_state}"
      )

      {:noreply, state}
    end
  end

  # -- task_blocked ------------------------------------------------------------

  def handle_cast(:task_blocked, state) do
    if state.fsm_state == :working do
      case transition(state, :blocked) do
        {:ok, new_state} ->
          Logger.info("AgentFSM: agent #{state.agent_id} blocked on task #{state.current_task_id}")
          {:noreply, new_state}

        {:error, {:invalid_transition, from, to}} ->
          Logger.warning(
            "AgentFSM: invalid transition #{from} -> #{to} for agent #{state.agent_id} (task_blocked)"
          )

          {:noreply, state}
      end
    else
      Logger.warning(
        "AgentFSM: agent #{state.agent_id} received task_blocked but is in :#{state.fsm_state}"
      )

      {:noreply, state}
    end
  end

  # -- task_unblocked ----------------------------------------------------------

  def handle_cast(:task_unblocked, state) do
    if state.fsm_state == :blocked do
      case transition(state, :working) do
        {:ok, new_state} ->
          Logger.info("AgentFSM: agent #{state.agent_id} unblocked on task #{state.current_task_id}")
          {:noreply, new_state}

        {:error, {:invalid_transition, from, to}} ->
          Logger.warning(
            "AgentFSM: invalid transition #{from} -> #{to} for agent #{state.agent_id} (task_unblocked)"
          )

          {:noreply, state}
      end
    else
      Logger.warning(
        "AgentFSM: agent #{state.agent_id} received task_unblocked but is in :#{state.fsm_state}"
      )

      {:noreply, state}
    end
  end

  # -- WebSocket disconnect (Process monitor :DOWN) ----------------------------

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ws_monitor_ref: ref} = state) do
    Logger.warning("AgentFSM: WebSocket down for agent #{state.agent_id}, transitioning to :offline")

    cancel_timer(state.acceptance_timer_ref)
    AgentCom.Presence.update_fsm_state(state.agent_id, :offline)
    reclaim_task_from_agent(state.agent_id, state.current_task_id)

    {:stop, :normal, %{state | fsm_state: :offline}}
  end

  # -- Acceptance timeout ------------------------------------------------------

  def handle_info({:acceptance_timeout, task_id}, %{current_task_id: task_id} = state) do
    Logger.warning(
      "AgentFSM: acceptance timeout for agent #{state.agent_id} on task #{task_id}"
    )

    reclaim_task_from_agent(state.agent_id, task_id)

    case transition(state, :idle) do
      {:ok, new_state} ->
        updated = %{new_state |
          current_task_id: nil,
          acceptance_timer_ref: nil,
          flags: Enum.uniq([:unresponsive | state.flags])
        }

        {:noreply, updated}

      {:error, _reason} ->
        # If we can't transition to idle (shouldn't happen from :assigned), log and stay
        updated = %{state |
          current_task_id: nil,
          acceptance_timer_ref: nil,
          flags: Enum.uniq([:unresponsive | state.flags])
        }

        {:noreply, updated}
    end
  end

  # Stale acceptance timeout (task_id doesn't match current) -- ignore
  def handle_info({:acceptance_timeout, _stale_task_id}, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lookup_fsm(agent_id) do
    case Registry.lookup(AgentCom.AgentFSMRegistry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp transition(state, to) do
    from = state.fsm_state
    allowed = Map.get(@valid_transitions, from, [])

    if to in allowed do
      now = System.system_time(:millisecond)
      AgentCom.Presence.update_fsm_state(state.agent_id, to)
      {:ok, %{state | fsm_state: to, last_state_change: now}}
    else
      {:error, {:invalid_transition, from, to}}
    end
  end

  defp normalize_capabilities(caps) when is_list(caps) do
    caps
    |> Enum.map(fn
      cap when is_binary(cap) -> %{name: cap}
      cap when is_map(cap) -> cap
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_capabilities(_), do: []

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp reclaim_task_from_agent(_agent_id, nil), do: :ok

  defp reclaim_task_from_agent(agent_id, task_id) do
    case AgentCom.TaskQueue.reclaim_task(task_id) do
      {:ok, _task} ->
        Logger.info("AgentFSM: reclaimed task #{task_id} from #{agent_id}")

      {:error, reason} ->
        Logger.warning("AgentFSM: reclaim failed for #{task_id}: #{reason}")
    end
  end
end
