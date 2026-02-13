defmodule AgentCom.XML.Schemas.Proposal do
  @moduledoc """
  XML schema struct for feature proposals.

  Proposals are generated during the Contemplation phase (Phase 33) when the
  Hub FSM identifies potential improvements or new features based on patterns
  observed during execution cycles.

  ## XML structure

      <proposal id="prop-001" impact="medium" effort="small" repo="AgentCom" proposed-at="2026-01-01T00:00:00Z">
        <title>Add circuit breaker to API client</title>
        <description>Implement circuit breaker pattern for external API calls</description>
        <rationale>Three failures in last 24 hours suggest instability</rationale>
        <related-files>
          <file>lib/agent_com/config.ex</file>
          <file>lib/agent_com/scheduler.ex</file>
        </related-files>
        <metadata>optional freeform text</metadata>
      </proposal>

  ## Fields

  - `id` - Unique proposal identifier (required)
  - `title` - Short proposal title (required)
  - `description` - Detailed description (required)
  - `rationale` - Why this proposal is being made
  - `impact` - Expected impact: "low", "medium", "high"
  - `effort` - Estimated effort: "small", "medium", "large"
  - `repo` - Target repository
  - `related_files` - List of related file paths
  - `proposed_at` - ISO 8601 timestamp
  - `metadata` - Freeform text metadata
  """

  import Saxy.XML

  alias AgentCom.XML.Parser

  @valid_impacts ~w(low medium high)
  @valid_efforts ~w(small medium large)

  @derive {Saxy.Builder,
    name: "proposal",
    attributes: [:id, :impact, :effort, :repo, :proposed_at],
    children: [
      :title,
      :description,
      :rationale,
      :metadata,
      related_files: &__MODULE__.build_related_files/1
    ]}

  defstruct [
    :id,
    :title,
    :description,
    :rationale,
    :impact,
    :effort,
    :repo,
    :proposed_at,
    :metadata,
    related_files: []
  ]

  @doc """
  Creates a new Proposal struct from a keyword list or map.

  Returns `{:ok, proposal}` if required fields are present, `{:error, reason}` otherwise.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    proposal = struct(__MODULE__, attrs)

    cond do
      is_nil(proposal.id) or proposal.id == "" ->
        {:error, "proposal id is required"}

      is_nil(proposal.title) or proposal.title == "" ->
        {:error, "proposal title is required"}

      is_nil(proposal.description) or proposal.description == "" ->
        {:error, "proposal description is required"}

      not is_nil(proposal.impact) and proposal.impact not in @valid_impacts ->
        {:error, "impact must be one of: #{Enum.join(@valid_impacts, ", ")}"}

      not is_nil(proposal.effort) and proposal.effort not in @valid_efforts ->
        {:error, "effort must be one of: #{Enum.join(@valid_efforts, ", ")}"}

      true ->
        {:ok, proposal}
    end
  end

  @doc """
  Builds the related-files XML element from a list of file path strings.
  """
  def build_related_files(files) when is_list(files) do
    children = Enum.map(files, &element("file", [], &1))
    element("related-files", [], children)
  end

  def build_related_files(_), do: element("related-files", [], [])

  @doc """
  Parses a SimpleForm tuple into a Proposal struct.
  """
  @spec from_simple_form(Saxy.SimpleForm.t()) :: {:ok, t()} | {:error, String.t()}
  def from_simple_form({"proposal", attrs, children}) do
    proposal = %__MODULE__{
      id: Parser.find_attr(attrs, "id"),
      title: Parser.find_child_text(children, "title"),
      description: Parser.find_child_text(children, "description"),
      rationale: Parser.find_child_text(children, "rationale"),
      impact: Parser.find_attr(attrs, "impact"),
      effort: Parser.find_attr(attrs, "effort"),
      repo: Parser.find_attr(attrs, "repo"),
      related_files: Parser.find_child_list(children, "related-files", "file"),
      proposed_at: Parser.find_attr(attrs, "proposed-at"),
      metadata: Parser.find_child_text(children, "metadata")
    }

    {:ok, proposal}
  end

  def from_simple_form({tag, _attrs, _children}) do
    {:error, "expected <proposal> root element, got <#{tag}>"}
  end

  @type t :: %__MODULE__{
    id: String.t() | nil,
    title: String.t() | nil,
    description: String.t() | nil,
    rationale: String.t() | nil,
    impact: String.t() | nil,
    effort: String.t() | nil,
    repo: String.t() | nil,
    related_files: [String.t()],
    proposed_at: String.t() | nil,
    metadata: String.t() | nil
  }
end
