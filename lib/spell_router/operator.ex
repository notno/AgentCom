defmodule SpellRouter.Operator do
  @moduledoc """
  Behaviour for spell operators.
  
  An operator transforms a Signal, potentially:
  - Adjusting responder values (DSP-style transforms)
  - Adding trace information
  - Communicating with external processes
  
  Operators can be:
  - Pure Elixir modules
  - Wrappers around bash scripts
  - Remote agents connected via WebSocket
  """

  alias SpellRouter.Signal

  @doc "Transform a signal"
  @callback transform(signal :: Signal.t(), opts :: map()) :: 
    {:ok, Signal.t()} | {:error, term()}

  @doc "Operator name for tracing"
  @callback name() :: String.t()

  @doc "Apply an operator module to a signal"
  def apply(operator_module, %Signal{} = signal, opts \\ %{}) do
    case operator_module.transform(signal, opts) do
      {:ok, transformed} ->
        {:ok, Signal.add_trace(transformed, operator_module.name(), opts)}
      {:error, _} = error ->
        error
    end
  end
end

defmodule SpellRouter.Operator.Bash do
  @moduledoc """
  Run a bash script as an operator.
  
  The script receives the signal as JSON on stdin,
  and should output the transformed signal as JSON on stdout.
  
  Example script (hush.sh):
  
      #!/bin/bash
      # Read signal, attenuate, strengthen quiet_tide
      jq '.values.quiet_tide += 0.18 | .values.last_witness -= 0.08'
  """

  @behaviour SpellRouter.Operator
  
  alias SpellRouter.Signal

  defstruct [:script_path, :name, :timeout]

  def new(script_path, opts \\ []) do
    %__MODULE__{
      script_path: script_path,
      name: opts[:name] || Path.basename(script_path, ".sh"),
      timeout: opts[:timeout] || 5000
    }
  end

  @impl true
  def name, do: "bash"  # Overridden per instance

  @impl true
  def transform(_signal, _opts) do
    # Instance method below handles actual transformation
    {:error, :use_run_instead}
  end

  @doc "Run this bash operator on a signal"
  def run(%__MODULE__{} = op, %Signal{} = signal) do
    json_input = signal |> Signal.to_json() |> Jason.encode!()
    
    case System.cmd("bash", [op.script_path], 
           input: json_input, 
           stderr_to_stdout: true,
           timeout: op.timeout) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, json} -> 
            {:ok, Signal.from_json(json) |> Signal.add_trace(op.name, %{script: op.script_path})}
          {:error, _} -> 
            {:error, {:invalid_json, output}}
        end
      {output, code} ->
        {:error, {:script_failed, code, output}}
    end
  end
end
