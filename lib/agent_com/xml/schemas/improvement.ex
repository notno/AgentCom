defmodule AgentCom.XML.Schemas.Improvement do
  @moduledoc """
  XML schema struct for improvement findings.

  Improvements represent identified (and potentially executed) code improvements
  discovered by the scanning process in Phase 32 (Improvement Scanning). Each
  improvement tracks its lifecycle from identification through completion.

  ## XML structure

      <improvement id="imp-001" repo="AgentCom" improvement-type="test" status="identified" scan-result-id="sr-001" attempted-at="..." completed-at="...">
        <file-path>lib/agent_com/scheduler.ex</file-path>
        <description>Add unit tests for scheduler module</description>
        <metadata>optional freeform text</metadata>
      </improvement>

  ## Fields

  - `id` - Unique improvement identifier (required)
  - `repo` - Repository name or path (required)
  - `file_path` - Path to the target file
  - `improvement_type` - One of "test", "doc", "refactor", "dependency", "cleanup"
  - `description` - Description of the improvement (required)
  - `status` - One of "identified", "in_progress", "completed", "skipped"
  - `scan_result_id` - ID of the originating scan result
  - `attempted_at` - ISO 8601 timestamp of first attempt
  - `completed_at` - ISO 8601 timestamp of completion
  - `metadata` - Freeform text metadata
  """

  alias AgentCom.XML.Parser

  @valid_types ~w(test doc refactor dependency cleanup)
  @valid_statuses ~w(identified in_progress completed skipped)

  @derive {Saxy.Builder,
    name: "improvement",
    attributes: [:id, :repo, :improvement_type, :status, :scan_result_id, :attempted_at, :completed_at],
    children: [:file_path, :description, :metadata]}

  defstruct [
    :id,
    :repo,
    :file_path,
    :improvement_type,
    :description,
    :scan_result_id,
    :attempted_at,
    :completed_at,
    :metadata,
    status: "identified"
  ]

  @doc """
  Creates a new Improvement struct from a keyword list or map.

  Returns `{:ok, improvement}` if required fields are present, `{:error, reason}` otherwise.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    improvement = struct(__MODULE__, attrs)

    cond do
      is_nil(improvement.id) or improvement.id == "" ->
        {:error, "improvement id is required"}

      is_nil(improvement.repo) or improvement.repo == "" ->
        {:error, "improvement repo is required"}

      is_nil(improvement.description) or improvement.description == "" ->
        {:error, "improvement description is required"}

      not is_nil(improvement.improvement_type) and improvement.improvement_type not in @valid_types ->
        {:error, "improvement_type must be one of: #{Enum.join(@valid_types, ", ")}"}

      not is_nil(improvement.status) and improvement.status not in @valid_statuses ->
        {:error, "status must be one of: #{Enum.join(@valid_statuses, ", ")}"}

      true ->
        {:ok, improvement}
    end
  end

  @doc """
  Parses a SimpleForm tuple into an Improvement struct.
  """
  @spec from_simple_form(Saxy.SimpleForm.t()) :: {:ok, t()} | {:error, String.t()}
  def from_simple_form({"improvement", attrs, children}) do
    improvement = %__MODULE__{
      id: Parser.find_attr(attrs, "id"),
      repo: Parser.find_attr(attrs, "repo"),
      file_path: Parser.find_child_text(children, "file_path"),
      improvement_type: Parser.find_attr(attrs, "improvement_type"),
      description: Parser.find_child_text(children, "description"),
      status: Parser.find_attr(attrs, "status") || "identified",
      scan_result_id: Parser.find_attr(attrs, "scan_result_id"),
      attempted_at: Parser.find_attr(attrs, "attempted_at"),
      completed_at: Parser.find_attr(attrs, "completed_at"),
      metadata: Parser.find_child_text(children, "metadata")
    }

    {:ok, improvement}
  end

  def from_simple_form({tag, _attrs, _children}) do
    {:error, "expected <improvement> root element, got <#{tag}>"}
  end

  @type t :: %__MODULE__{
    id: String.t() | nil,
    repo: String.t() | nil,
    file_path: String.t() | nil,
    improvement_type: String.t() | nil,
    description: String.t() | nil,
    status: String.t(),
    scan_result_id: String.t() | nil,
    attempted_at: String.t() | nil,
    completed_at: String.t() | nil,
    metadata: String.t() | nil
  }
end
