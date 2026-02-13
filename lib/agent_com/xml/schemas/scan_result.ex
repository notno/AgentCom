defmodule AgentCom.XML.Schemas.ScanResult do
  @moduledoc """
  XML schema struct for improvement scan results.

  Scan results are produced by the deterministic and LLM-based scanners in
  Phase 32 (Improvement Scanning). Each result identifies a specific improvement
  opportunity in a repository file.

  ## XML structure

      <scan-result id="sr-001" repo="AgentCom" scan-type="test_gap" severity="medium" scanned-at="2026-01-01T00:00:00Z">
        <file-path>lib/agent_com/scheduler.ex</file-path>
        <description>Module has no corresponding test file</description>
        <suggested-action>Create test/agent_com/scheduler_test.exs</suggested-action>
        <metadata>optional freeform text</metadata>
      </scan-result>

  ## Fields

  - `id` - Unique scan result identifier (required)
  - `repo` - Repository name or path (required)
  - `scan_type` - One of "test_gap", "doc_gap", "dead_dep", "refactor", "simplification"
  - `file_path` - Path to the file with the finding
  - `description` - Description of the finding (required)
  - `severity` - One of "low", "medium", "high"
  - `suggested_action` - Suggested remediation
  - `scanned_at` - ISO 8601 timestamp of scan
  - `metadata` - Freeform text metadata
  """

  alias AgentCom.XML.Parser

  @valid_scan_types ~w(test_gap doc_gap dead_dep refactor simplification)
  @valid_severities ~w(low medium high)

  defstruct [
    :id,
    :repo,
    :scan_type,
    :file_path,
    :description,
    :suggested_action,
    :scanned_at,
    :metadata,
    severity: "medium"
  ]

  @doc """
  Creates a new ScanResult struct from a keyword list or map.

  Returns `{:ok, scan_result}` if required fields are present, `{:error, reason}` otherwise.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    result = struct(__MODULE__, attrs)

    cond do
      is_nil(result.id) or result.id == "" ->
        {:error, "scan_result id is required"}

      is_nil(result.repo) or result.repo == "" ->
        {:error, "scan_result repo is required"}

      is_nil(result.description) or result.description == "" ->
        {:error, "scan_result description is required"}

      not is_nil(result.scan_type) and result.scan_type not in @valid_scan_types ->
        {:error, "scan_type must be one of: #{Enum.join(@valid_scan_types, ", ")}"}

      not is_nil(result.severity) and result.severity not in @valid_severities ->
        {:error, "severity must be one of: #{Enum.join(@valid_severities, ", ")}"}

      true ->
        {:ok, result}
    end
  end

  @doc """
  Parses a SimpleForm tuple into a ScanResult struct.
  """
  @spec from_simple_form(Saxy.SimpleForm.t()) :: {:ok, t()} | {:error, String.t()}
  def from_simple_form({"scan-result", attrs, children}) do
    result = %__MODULE__{
      id: Parser.find_attr(attrs, "id"),
      repo: Parser.find_attr(attrs, "repo"),
      scan_type: Parser.find_attr(attrs, "scan-type"),
      file_path: Parser.find_child_text(children, "file-path"),
      description: Parser.find_child_text(children, "description"),
      severity: Parser.find_attr(attrs, "severity") || "medium",
      suggested_action: Parser.find_child_text(children, "suggested-action"),
      scanned_at: Parser.find_attr(attrs, "scanned-at"),
      metadata: Parser.find_child_text(children, "metadata")
    }

    {:ok, result}
  end

  def from_simple_form({tag, _attrs, _children}) do
    {:error, "expected <scan-result> root element, got <#{tag}>"}
  end

  @type t :: %__MODULE__{
    id: String.t() | nil,
    repo: String.t() | nil,
    scan_type: String.t() | nil,
    file_path: String.t() | nil,
    description: String.t() | nil,
    severity: String.t(),
    suggested_action: String.t() | nil,
    scanned_at: String.t() | nil,
    metadata: String.t() | nil
  }
end

defimpl Saxy.Builder, for: AgentCom.XML.Schemas.ScanResult do
  import Saxy.XML

  def build(result) do
    attrs =
      [
        {"id", result.id},
        {"repo", result.repo},
        {"scan-type", result.scan_type},
        {"severity", result.severity},
        {"scanned-at", result.scanned_at}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    children =
      []
      |> maybe_add_element("file-path", result.file_path)
      |> maybe_add_element("description", result.description)
      |> maybe_add_element("suggested-action", result.suggested_action)
      |> maybe_add_element("metadata", result.metadata)
      |> Enum.reverse()

    element("scan-result", attrs, children)
  end

  defp maybe_add_element(acc, _name, nil), do: acc
  defp maybe_add_element(acc, name, value), do: [element(name, [], value) | acc]
end
