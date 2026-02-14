defmodule AgentCom.HubFSM do
  @moduledoc """
  Singleton GenServer implementing the hub's autonomous brain as a 2-state FSM.

  The HubFSM drives all autonomous hub behavior by evaluating system state
  on a 1-second tick and transitioning between `:resting` and `:executing`
  based on goal queue depth and budget availability.

  ## States

  | State       | Meaning                                    |
  |-------------|--------------------------------------------|
  | `:resting`  | No pending goals or budget exhausted       |
  | `:executing`| Actively processing goals from the backlog |

  ## Tick-Based Evaluation

  Every second, the FSM gathers system state from GoalBacklog and CostLedger,
  then evaluates transition predicates via `HubFSM.Predicates.evaluate/2`.
  PubSub subscriptions to "goals" and "tasks" exist for future event-specific
  behavior but do NOT trigger evaluation -- only the tick does.

  ## Timer Management

  - **Tick timer:** 1-second interval for state evaluation
  - **Watchdog timer:** 2-hour safety net forces transition to `:resting`
    if stuck in any state too long

  ## Pause/Resume

  `pause/0` halts all autonomous transitions (tick evaluations return
  immediately). `resume/0` re-enables evaluation. Ticks continue firing
  even while paused so resume logic stays simple.

  ## History

  Every transition is recorded in `HubFSM.History` (ETS) for fast
  dashboard reads without GenServer.call overhead.
  """

  use GenServer
  require Logger

  alias AgentCom.HubFSM.{History, Predicates}

  @valid_transitions %{
    resting: [:executing],
    executing: [:resting]
  }

  @tick_interval_ms 1_000
  @watchdog_ms 2 * 60 * 60 * 1_000

  defstruct [
    :fsm_state,
    :last_state_change,
    :tick_ref,
    :watchdog_ref,
    cycle_count: 0,
    paused: false,
    transition_count: 0
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the current FSM state snapshot.

  Returns a map with `:fsm_state`, `:paused`, `:last_state_change`,
  `:cycle_count`, and `:transition_count`.
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Pause the FSM. Cancels all timers and halts autonomous transitions.

  Returns `:ok` or `{:error, :already_paused}`.
  """
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc """
  Resume the FSM. Re-arms tick and watchdog timers.

  Returns `:ok` or `{:error, :not_paused}`.
  """
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc """
  Query transition history.

  Delegates to `HubFSM.History.list/1`. See that module for options.
  """
  def history(opts \\ []) do
    GenServer.call(__MODULE__, {:history, opts})
  end

  @doc """
  Force a state transition for testing or admin use.

  Validates the transition against `@valid_transitions` before applying.
  Returns `:ok` or `{:error, :invalid_transition}`.
  """
  def force_transition(new_state, reason) do
    GenServer.call(__MODULE__, {:force_transition, new_state, reason})
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    # Initialize ETS history table FIRST
    History.init_table()

    # Subscribe to PubSub topics for future event-specific behavior
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "goals")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "tasks")

    now = System.system_time(:millisecond)

    state = %__MODULE__{
      fsm_state: :resting,
      last_state_change: now,
      cycle_count: 0,
      paused: false,
      transition_count: 0
    }

    # Arm timers
    tick_ref = arm_tick()
    watchdog_ref = arm_watchdog()

    state = %{state | tick_ref: tick_ref, watchdog_ref: watchdog_ref}

    # Record initial state in history
    History.record(nil, :resting, "hub_fsm_started", 0)

    # Broadcast initial state
    broadcast_state_change(state)

    # Notify ClaudeClient of initial hub state (safe if not started yet)
    try do
      AgentCom.ClaudeClient.set_hub_state(:executing)
    catch
      :exit, _ -> :ok
    end

    Logger.info("hub_fsm_started")

    {:ok, state}
  end

  # -- get_state ---------------------------------------------------------------

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = %{
      fsm_state: state.fsm_state,
      paused: state.paused,
      last_state_change: state.last_state_change,
      cycle_count: state.cycle_count,
      transition_count: state.transition_count
    }

    {:reply, reply, state}
  end

  # -- pause -------------------------------------------------------------------

  def handle_call(:pause, _from, %{paused: true} = state) do
    {:reply, {:error, :already_paused}, state}
  end

  def handle_call(:pause, _from, state) do
    cancel_timer(state.tick_ref)
    cancel_timer(state.watchdog_ref)

    updated = %{state | paused: true, tick_ref: nil, watchdog_ref: nil}
    broadcast_state_change(updated)

    Logger.info("hub_fsm_paused", fsm_state: state.fsm_state)

    {:reply, :ok, updated}
  end

  # -- resume ------------------------------------------------------------------

  def handle_call(:resume, _from, %{paused: false} = state) do
    {:reply, {:error, :not_paused}, state}
  end

  def handle_call(:resume, _from, state) do
    tick_ref = arm_tick()
    watchdog_ref = arm_watchdog()

    updated = %{state | paused: false, tick_ref: tick_ref, watchdog_ref: watchdog_ref}
    broadcast_state_change(updated)

    Logger.info("hub_fsm_resumed", fsm_state: state.fsm_state)

    {:reply, :ok, updated}
  end

  # -- history -----------------------------------------------------------------

  def handle_call({:history, opts}, _from, state) do
    {:reply, History.list(opts), state}
  end

  # -- force_transition --------------------------------------------------------

  def handle_call({:force_transition, new_state, reason}, _from, state) do
    allowed = Map.get(@valid_transitions, state.fsm_state, [])

    if new_state in allowed do
      updated = do_transition(state, new_state, reason)
      {:reply, :ok, updated}
    else
      {:reply, {:error, :invalid_transition}, state}
    end
  end

  # -- tick (paused) -----------------------------------------------------------

  @impl true
  def handle_info(:tick, %{paused: true} = state) do
    # Keep ticking even when paused so resume doesn't need special logic
    tick_ref = arm_tick()
    {:noreply, %{state | tick_ref: tick_ref}}
  end

  # -- tick (active) -----------------------------------------------------------

  def handle_info(:tick, state) do
    system_state = gather_system_state()

    updated =
      case Predicates.evaluate(state.fsm_state, system_state) do
        {:transition, new_state, reason} ->
          do_transition(state, new_state, reason)

        :stay ->
          state
      end

    tick_ref = arm_tick()
    {:noreply, %{updated | tick_ref: tick_ref}}
  end

  # -- watchdog (paused) -------------------------------------------------------

  def handle_info(:watchdog_timeout, %{paused: true} = state) do
    Logger.warning("hub_fsm_watchdog_timeout_while_paused")
    {:noreply, state}
  end

  # -- watchdog (active) -------------------------------------------------------

  def handle_info(:watchdog_timeout, state) do
    duration_ms = System.system_time(:millisecond) - state.last_state_change

    Logger.warning("hub_fsm_watchdog_timeout",
      fsm_state: state.fsm_state,
      stuck_duration_ms: duration_ms
    )

    :telemetry.execute(
      [:agent_com, :hub_fsm, :watchdog_timeout],
      %{duration_ms: duration_ms},
      %{fsm_state: state.fsm_state}
    )

    reason = "watchdog timeout: stuck in #{state.fsm_state} for > 2 hours"
    updated = do_transition(state, :resting, reason)

    {:noreply, updated}
  end

  # -- PubSub events (catch-all) -----------------------------------------------

  def handle_info({:goal_event, _payload}, state) do
    # Tick-based evaluation only; PubSub exists for future event-specific behavior
    {:noreply, state}
  end

  def handle_info({:task_event, _payload}, state) do
    {:noreply, state}
  end

  # Catch-all for unexpected messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  defp gather_system_state do
    # Gather GoalBacklog stats (safe if not started)
    goal_stats =
      try do
        AgentCom.GoalBacklog.stats()
      catch
        :exit, _ -> %{by_status: %{}, total: 0}
      end

    by_status = Map.get(goal_stats, :by_status, %{})
    pending_goals = Map.get(by_status, :submitted, 0)

    active_goals =
      Map.get(by_status, :decomposing, 0) +
        Map.get(by_status, :executing, 0) +
        Map.get(by_status, :verifying, 0)

    # Check budget (safe if not started)
    budget_exhausted =
      try do
        AgentCom.CostLedger.check_budget(:executing) == :budget_exhausted
      catch
        :exit, _ -> false
      end

    %{
      pending_goals: pending_goals,
      active_goals: active_goals,
      budget_exhausted: budget_exhausted
    }
  end

  defp do_transition(state, new_state, reason) do
    # Cancel existing watchdog
    cancel_timer(state.watchdog_ref)

    now = System.system_time(:millisecond)
    new_transition_count = state.transition_count + 1

    # Record in history
    History.record(state.fsm_state, new_state, reason, new_transition_count)

    # Update ClaudeClient hub state (safe if not started)
    try do
      AgentCom.ClaudeClient.set_hub_state(:executing)
    catch
      :exit, _ -> :ok
    end

    # Emit telemetry
    :telemetry.execute(
      [:agent_com, :hub_fsm, :transition],
      %{duration_ms: now - state.last_state_change},
      %{from_state: state.fsm_state, to_state: new_state, reason: reason}
    )

    # Update cycle count (resting -> executing = new cycle)
    new_cycle_count =
      if state.fsm_state == :resting and new_state == :executing do
        state.cycle_count + 1
      else
        state.cycle_count
      end

    updated = %{
      state
      | fsm_state: new_state,
        last_state_change: now,
        transition_count: new_transition_count,
        cycle_count: new_cycle_count,
        watchdog_ref: arm_watchdog()
    }

    # Broadcast state change
    broadcast_state_change(updated)

    Logger.info("hub_fsm_transition",
      from: state.fsm_state,
      to: new_state,
      reason: reason,
      cycle: new_cycle_count,
      transition: new_transition_count
    )

    updated
  end

  defp broadcast_state_change(state) do
    Phoenix.PubSub.broadcast(
      AgentCom.PubSub,
      "hub_fsm",
      {:hub_fsm_state_change,
       %{
         fsm_state: state.fsm_state,
         paused: state.paused,
         last_state_change: state.last_state_change,
         cycle_count: state.cycle_count,
         timestamp: System.system_time(:millisecond)
       }}
    )
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp arm_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  defp arm_watchdog do
    Process.send_after(self(), :watchdog_timeout, @watchdog_ms)
  end
end
