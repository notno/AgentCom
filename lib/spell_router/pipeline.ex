defmodule SpellRouter.Pipeline do
  @moduledoc """
  Orchestrates signal flow through a sequence of operators.
  
  A pipeline is defined as a list of operator references:
  
      pipeline = Pipeline.new([
        {:builtin, :source, %{name: "fire", pattern: %{spark_lord: 0.8}}},
        {:bash, "priv/operators/hush.sh"},
        {:bash, "priv/operators/veil.sh"},
        {:remote, "agent_123"},  # Connected via WebSocket
        {:builtin, :commit},
        {:builtin, :emit}
      ])
  
  Signals flow left-to-right, each operator transforming before passing on.
  """

  alias SpellRouter.Signal
  alias SpellRouter.Operator.Bash

  defstruct [:id, :steps, :current_step, :signal, :status, :error]

  @type step :: 
    {:builtin, atom(), map()} |
    {:bash, String.t()} |
    {:remote, String.t()}

  @doc "Create a new pipeline from steps"
  def new(steps, opts \\ []) do
    %__MODULE__{
      id: opts[:id] || generate_id(),
      steps: steps,
      current_step: 0,
      signal: nil,
      status: :pending,
      error: nil
    }
  end

  @doc "Execute the pipeline synchronously"
  def run(%__MODULE__{steps: steps} = pipeline) do
    initial_signal = find_source_signal(steps)
    
    steps
    |> Enum.reject(&is_source?/1)
    |> Enum.reduce_while({:ok, initial_signal, []}, fn step, {:ok, signal, trace} ->
      case execute_step(step, signal) do
        {:ok, new_signal} ->
          {:cont, {:ok, new_signal, trace ++ [step]}}
        {:error, reason} ->
          {:halt, {:error, reason, step, signal}}
      end
    end)
    |> case do
      {:ok, final_signal, _trace} ->
        {:ok, %{pipeline | signal: final_signal, status: :completed}}
      {:error, reason, failed_step, last_signal} ->
        {:error, %{pipeline | 
          signal: last_signal, 
          status: :failed, 
          error: {reason, failed_step}
        }}
    end
  end

  @doc "Execute a single step"
  def execute_step({:builtin, :source, %{name: name, pattern: pattern}}, _signal) do
    {:ok, Signal.from_source(name, pattern)}
  end

  def execute_step({:builtin, :commit}, signal) do
    # commit transitions from plan-space to resolve-space
    {:ok, Signal.add_trace(signal, "commit", %{note: "transitioning to resolve-space"})}
  end

  def execute_step({:builtin, :emit}, signal) do
    # emit finalizes the spell
    {:ok, Signal.add_trace(signal, "emit", %{note: "spell complete"})}
  end

  def execute_step({:bash, script_path}, signal) do
    op = Bash.new(script_path)
    Bash.run(op, signal)
  end

  def execute_step({:remote, agent_id}, signal) do
    # Send to remote agent via PubSub, wait for response
    SpellRouter.RemoteOperator.call(agent_id, signal)
  end

  def execute_step({:elixir, module}, signal) when is_atom(module) do
    SpellRouter.Operator.apply(module, signal)
  end

  # Helpers

  defp find_source_signal(steps) do
    case Enum.find(steps, &is_source?/1) do
      {:builtin, :source, %{name: name, pattern: pattern}} ->
        Signal.from_source(name, pattern)
      {:builtin, :source, %{name: name}} ->
        Signal.from_source(name)
      nil ->
        Signal.new()
    end
  end

  defp is_source?({:builtin, :source, _}), do: true
  defp is_source?(_), do: false

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

defmodule SpellRouter.PipelineSupervisor do
  @moduledoc "Supervises running pipelines"
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
