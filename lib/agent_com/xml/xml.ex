defmodule AgentCom.XML do
  @moduledoc """
  Public API for encoding and decoding AgentCom XML documents.

  AgentCom uses XML as the format for all machine-consumed documents in the
  v1.3 autonomous loop. This module provides the centralized encode/decode
  interface that all downstream phases (GoalBacklog, HubFSM, Improvement
  Scanning, Contemplation) use to produce and consume structured documents.

  ## Supported schema types

  - `:goal` - Goal definitions (Phase 27, 30)
  - `:scan_result` - Improvement scan results (Phase 32)
  - `:fsm_snapshot` - Hub FSM state exports (Phase 29)
  - `:improvement` - Improvement findings (Phase 32)
  - `:proposal` - Feature proposals (Phase 33)

  ## Usage

      goal = %AgentCom.XML.Schemas.Goal{id: "g-001", title: "Test", priority: "normal"}
      {:ok, xml} = AgentCom.XML.encode(goal)
      {:ok, decoded} = AgentCom.XML.decode(xml, :goal)
      decoded.id
      #=> "g-001"

  """

  alias AgentCom.XML.Schemas.{Goal, ScanResult, FsmSnapshot, Improvement, Proposal}

  @schema_types [:goal, :scan_result, :fsm_snapshot, :improvement, :proposal]

  @schema_modules %{
    goal: Goal,
    scan_result: ScanResult,
    fsm_snapshot: FsmSnapshot,
    improvement: Improvement,
    proposal: Proposal
  }

  @doc """
  Returns all supported schema type atoms.
  """
  @spec schema_types() :: [atom()]
  def schema_types, do: @schema_types

  @doc """
  Encodes an XML schema struct to an XML binary string.

  Returns `{:ok, xml_string}` on success or `{:error, reason}` on failure.
  """
  @spec encode(struct()) :: {:ok, String.t()} | {:error, term()}
  def encode(%mod{} = struct) when mod in [Goal, ScanResult, FsmSnapshot, Improvement, Proposal] do
    simple_form = Saxy.Builder.build(struct)
    xml = Saxy.encode!(simple_form, version: "1.0")
    {:ok, xml}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def encode(_other), do: {:error, "unsupported struct type"}

  @doc """
  Encodes an XML schema struct to an XML binary string.

  Raises on error.
  """
  @spec encode!(struct()) :: String.t()
  def encode!(struct) do
    case encode(struct) do
      {:ok, xml} -> xml
      {:error, reason} -> raise ArgumentError, "XML encode failed: #{reason}"
    end
  end

  @doc """
  Decodes an XML binary string into a schema struct.

  The `schema_type` atom determines which struct to decode into.
  Returns `{:ok, struct}` on success or `{:error, reason}` on failure.

  ## Examples

      {:ok, goal} = AgentCom.XML.decode(xml_string, :goal)

  """
  @spec decode(String.t(), atom()) :: {:ok, struct()} | {:error, term()}
  def decode(xml_string, schema_type) when is_binary(xml_string) and schema_type in @schema_types do
    case Saxy.SimpleForm.parse_string(xml_string) do
      {:ok, simple_form} ->
        module = Map.fetch!(@schema_modules, schema_type)
        module.from_simple_form(simple_form)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def decode(_xml, schema_type) when schema_type not in @schema_types do
    {:error, "unknown schema type: #{inspect(schema_type)}"}
  end

  def decode(_xml, _schema_type), do: {:error, "xml must be a binary string"}

  @doc """
  Decodes an XML binary string into a schema struct.

  Raises on error.
  """
  @spec decode!(String.t(), atom()) :: struct()
  def decode!(xml_string, schema_type) do
    case decode(xml_string, schema_type) do
      {:ok, struct} -> struct
      {:error, reason} -> raise ArgumentError, "XML decode failed: #{inspect(reason)}"
    end
  end

  @doc """
  Converts any schema struct to a plain map with string keys.

  Useful for JSON serialization or DETS storage of parsed XML data.
  """
  @spec to_map(struct()) :: map()
  def to_map(%mod{} = struct) when mod in [Goal, ScanResult, FsmSnapshot, Improvement, Proposal] do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.new()
  end
end
