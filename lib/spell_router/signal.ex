defmodule SpellRouter.Signal do
  @moduledoc """
  A 16-dimensional semantic signal.
  
  Each dimension is a "responder" - a named aspect of meaning
  that operators can strengthen or attenuate.
  
  The signal flows through operators in a pipeline,
  each transforming it before passing it on.
  """

  @responders [
    :spark_lord,
    :quiet_tide,
    :binder_who_smiles,
    :last_witness,
    :hollow_crown,
    :dream_eater,
    :iron_promise,
    :soft_betrayal,
    :ember_heart,
    :void_singer,
    :golden_liar,
    :storm_bringer,
    :pale_hunter,
    :silk_shadow,
    :bone_reader,
    :star_child
  ]

  @type t :: %__MODULE__{
    values: %{atom() => float()},
    trace: [map()],
    metadata: map()
  }

  defstruct values: %{},
            trace: [],
            metadata: %{}

  @doc "List of all responder names"
  def responders, do: @responders

  @doc "Create a new signal with all responders at 0.0"
  def new do
    values = Map.new(@responders, fn r -> {r, 0.0} end)
    %__MODULE__{values: values, trace: [], metadata: %{}}
  end

  @doc "Create a signal from a source pattern"
  def from_source(source_name, pattern \\ %{}) do
    new()
    |> struct(values: Map.merge(new().values, normalize_keys(pattern)))
    |> add_trace("source", %{name: source_name, pattern: pattern})
  end

  @doc "Get a responder value"
  def get(%__MODULE__{values: values}, responder) when responder in @responders do
    Map.get(values, responder, 0.0)
  end

  @doc "Set a responder value"
  def put(%__MODULE__{values: values} = signal, responder, value) 
      when responder in @responders and is_number(value) do
    %{signal | values: Map.put(values, responder, clamp(value))}
  end

  @doc "Adjust a responder by delta"
  def adjust(%__MODULE__{} = signal, responder, delta) when responder in @responders do
    current = get(signal, responder)
    put(signal, responder, current + delta)
  end

  @doc "Apply multiple adjustments"
  def adjust_many(%__MODULE__{} = signal, adjustments) do
    Enum.reduce(adjustments, signal, fn {responder, delta}, acc ->
      adjust(acc, responder, delta)
    end)
  end

  @doc "Add a trace entry for debugging/visualization"
  def add_trace(%__MODULE__{trace: trace} = signal, operator, details \\ %{}) do
    entry = %{
      operator: operator,
      timestamp: System.system_time(:millisecond),
      values_snapshot: signal.values,
      details: details
    }
    %{signal | trace: trace ++ [entry]}
  end

  @doc "Encode signal to JSON-compatible map"
  def to_json(%__MODULE__{values: values, trace: trace, metadata: metadata}) do
    %{
      "values" => stringify_keys(values),
      "trace" => Enum.map(trace, &stringify_trace_entry/1),
      "metadata" => stringify_keys(metadata)
    }
  end

  @doc "Decode signal from JSON map"
  def from_json(%{"values" => values} = json) do
    %__MODULE__{
      values: normalize_keys(values),
      trace: Map.get(json, "trace", []) |> Enum.map(&parse_trace_entry/1),
      metadata: normalize_keys(Map.get(json, "metadata", %{}))
    }
  end

  # Helpers
  
  defp clamp(value), do: max(-1.0, min(1.0, value))

  defp normalize_keys(map) do
    Map.new(map, fn {k, v} -> {to_atom(k), v} end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)

  defp stringify_trace_entry(%{operator: op, timestamp: ts, values_snapshot: vals, details: details}) do
    %{
      "operator" => to_string(op),
      "timestamp" => ts,
      "values" => stringify_keys(vals),
      "details" => stringify_keys(details)
    }
  end

  defp parse_trace_entry(entry) do
    %{
      operator: Map.get(entry, "operator"),
      timestamp: Map.get(entry, "timestamp"),
      values_snapshot: normalize_keys(Map.get(entry, "values", %{})),
      details: normalize_keys(Map.get(entry, "details", %{}))
    }
  end
end
