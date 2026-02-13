defmodule AgentCom.XML.Schemas.FsmSnapshot do
  @moduledoc """
  XML schema struct for Hub FSM state snapshots.

  FSM snapshots capture the current state of the Hub FSM (Phase 29) at a point
  in time, including the active state, cycle count, current goal, and recent
  transition history.

  ## XML structure

      <fsm-snapshot state="executing" since="2026-01-01T00:00:00Z" cycle-count="42" queue-depth="3" budget-remaining="0.50" snapshot-at="2026-01-01T01:00:00Z">
        <current-goal-id>g-001</current-goal-id>
        <transition-history>
          <transition from="resting" to="executing" at="2026-01-01T00:00:00Z"/>
          <transition from="executing" to="improving" at="2026-01-01T00:30:00Z"/>
        </transition-history>
      </fsm-snapshot>

  ## Fields

  - `state` - Current FSM state (required): "executing", "improving", "contemplating", "resting"
  - `since` - ISO 8601 timestamp of when current state began (required)
  - `cycle_count` - Number of completed execution cycles
  - `current_goal_id` - ID of the goal currently being executed
  - `queue_depth` - Number of goals in the queue
  - `budget_remaining` - Remaining budget as string
  - `transition_history` - List of transition maps with "from", "to", "at" keys
  - `snapshot_at` - ISO 8601 timestamp of when snapshot was taken (required)
  """

  alias AgentCom.XML.Parser

  @valid_states ~w(executing improving contemplating resting)

  defstruct [
    :state,
    :since,
    :cycle_count,
    :current_goal_id,
    :queue_depth,
    :budget_remaining,
    :snapshot_at,
    transition_history: []
  ]

  @doc """
  Creates a new FsmSnapshot struct from a keyword list or map.

  Returns `{:ok, snapshot}` if required fields are present, `{:error, reason}` otherwise.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    snapshot = struct(__MODULE__, attrs)

    cond do
      is_nil(snapshot.state) or snapshot.state == "" ->
        {:error, "fsm_snapshot state is required"}

      snapshot.state not in @valid_states ->
        {:error, "state must be one of: #{Enum.join(@valid_states, ", ")}"}

      is_nil(snapshot.since) or snapshot.since == "" ->
        {:error, "fsm_snapshot since is required"}

      is_nil(snapshot.snapshot_at) or snapshot.snapshot_at == "" ->
        {:error, "fsm_snapshot snapshot_at is required"}

      true ->
        {:ok, snapshot}
    end
  end

  @doc """
  Parses a SimpleForm tuple into an FsmSnapshot struct.
  """
  @spec from_simple_form(Saxy.SimpleForm.t()) :: {:ok, t()} | {:error, String.t()}
  def from_simple_form({"fsm-snapshot", attrs, children}) do
    snapshot = %__MODULE__{
      state: Parser.find_attr(attrs, "state"),
      since: Parser.find_attr(attrs, "since"),
      cycle_count: Parser.find_attr(attrs, "cycle-count"),
      current_goal_id: Parser.find_child_text(children, "current-goal-id"),
      queue_depth: Parser.find_attr(attrs, "queue-depth"),
      budget_remaining: Parser.find_attr(attrs, "budget-remaining"),
      transition_history: Parser.find_child_map_list(children, "transition-history", "transition"),
      snapshot_at: Parser.find_attr(attrs, "snapshot-at")
    }

    {:ok, snapshot}
  end

  def from_simple_form({tag, _attrs, _children}) do
    {:error, "expected <fsm-snapshot> root element, got <#{tag}>"}
  end

  @type t :: %__MODULE__{
    state: String.t() | nil,
    since: String.t() | nil,
    cycle_count: String.t() | nil,
    current_goal_id: String.t() | nil,
    queue_depth: String.t() | nil,
    budget_remaining: String.t() | nil,
    transition_history: [map()],
    snapshot_at: String.t() | nil
  }
end

defimpl Saxy.Builder, for: AgentCom.XML.Schemas.FsmSnapshot do
  import Saxy.XML

  def build(snapshot) do
    attrs =
      [
        {"state", snapshot.state},
        {"since", snapshot.since},
        {"cycle-count", snapshot.cycle_count},
        {"queue-depth", snapshot.queue_depth},
        {"budget-remaining", snapshot.budget_remaining},
        {"snapshot-at", snapshot.snapshot_at}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    children =
      []
      |> maybe_add_element("current-goal-id", snapshot.current_goal_id)
      |> maybe_add_transitions(snapshot.transition_history)
      |> Enum.reverse()

    element("fsm-snapshot", attrs, children)
  end

  defp maybe_add_element(acc, _name, nil), do: acc
  defp maybe_add_element(acc, name, value), do: [element(name, [], value) | acc]

  defp maybe_add_transitions(acc, []), do: acc

  defp maybe_add_transitions(acc, transitions) do
    items =
      Enum.map(transitions, fn transition ->
        attrs =
          transition
          |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

        element("transition", attrs, [])
      end)

    [element("transition-history", [], items) | acc]
  end
end
