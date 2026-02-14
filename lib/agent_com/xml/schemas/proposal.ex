defmodule AgentCom.XML.Schemas.Proposal do
  @moduledoc """
  XML schema struct for feature proposals.

  Proposals are generated during the Contemplation phase (Phase 33) when the
  Hub FSM identifies potential improvements or new features based on patterns
  observed during execution cycles.

  ## XML structure

      <proposal id="prop-001" impact="medium" effort="small" repo="AgentCom" proposed-at="2026-01-01T00:00:00Z">
        <title>Add circuit breaker to API client</title>
        <problem>External API calls fail silently under load</problem>
        <solution>Implement circuit breaker pattern with configurable thresholds</solution>
        <description>Implement circuit breaker pattern for external API calls</description>
        <rationale>Three failures in last 24 hours suggest instability</rationale>
        <why-now>Load has increased 3x since last release</why-now>
        <why-not>Adds complexity to the call path; may mask transient issues</why-not>
        <related-files>
          <file>lib/agent_com/config.ex</file>
          <file>lib/agent_com/scheduler.ex</file>
        </related-files>
        <dependencies>
          <dependency>error-tracking-module</dependency>
        </dependencies>
        <metadata>optional freeform text</metadata>
      </proposal>

  ## Fields

  - `id` - Unique proposal identifier (required)
  - `title` - Short proposal title (required)
  - `problem` - Problem statement this proposal addresses
  - `solution` - Proposed solution description
  - `description` - Detailed description (required)
  - `rationale` - Why this proposal is being made
  - `why_now` - Why this should be done in the current phase
  - `why_not` - Risks or reasons this might not be worth doing
  - `impact` - Expected impact: "low", "medium", "high"
  - `effort` - Estimated effort: "small", "medium", "large"
  - `repo` - Target repository
  - `related_files` - List of related file paths
  - `dependencies` - List of dependency strings
  - `proposed_at` - ISO 8601 timestamp
  - `metadata` - Freeform text metadata
  """

  alias AgentCom.XML.Parser

  @valid_impacts ~w(low medium high)
  @valid_efforts ~w(small medium large)

  defstruct [
    :id,
    :title,
    :problem,
    :solution,
    :description,
    :rationale,
    :why_now,
    :why_not,
    :impact,
    :effort,
    :repo,
    :proposed_at,
    :metadata,
    related_files: [],
    dependencies: []
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
  Parses a SimpleForm tuple into a Proposal struct.
  """
  @spec from_simple_form(Saxy.SimpleForm.t()) :: {:ok, t()} | {:error, String.t()}
  def from_simple_form({"proposal", attrs, children}) do
    proposal = %__MODULE__{
      id: Parser.find_attr(attrs, "id"),
      title: Parser.find_child_text(children, "title"),
      problem: Parser.find_child_text(children, "problem"),
      solution: Parser.find_child_text(children, "solution"),
      description: Parser.find_child_text(children, "description"),
      rationale: Parser.find_child_text(children, "rationale"),
      why_now: Parser.find_child_text(children, "why-now"),
      why_not: Parser.find_child_text(children, "why-not"),
      impact: Parser.find_attr(attrs, "impact"),
      effort: Parser.find_attr(attrs, "effort"),
      repo: Parser.find_attr(attrs, "repo"),
      related_files: Parser.find_child_list(children, "related-files", "file"),
      dependencies: Parser.find_child_list(children, "dependencies", "dependency"),
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
    problem: String.t() | nil,
    solution: String.t() | nil,
    description: String.t() | nil,
    rationale: String.t() | nil,
    why_now: String.t() | nil,
    why_not: String.t() | nil,
    impact: String.t() | nil,
    effort: String.t() | nil,
    repo: String.t() | nil,
    related_files: [String.t()],
    dependencies: [String.t()],
    proposed_at: String.t() | nil,
    metadata: String.t() | nil
  }
end

defimpl Saxy.Builder, for: AgentCom.XML.Schemas.Proposal do
  import Saxy.XML

  def build(proposal) do
    attrs =
      [
        {"id", proposal.id},
        {"impact", proposal.impact},
        {"effort", proposal.effort},
        {"repo", proposal.repo},
        {"proposed-at", proposal.proposed_at}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    children =
      []
      |> maybe_add_element("title", proposal.title)
      |> maybe_add_element("problem", proposal.problem)
      |> maybe_add_element("solution", proposal.solution)
      |> maybe_add_element("description", proposal.description)
      |> maybe_add_element("rationale", proposal.rationale)
      |> maybe_add_element("why-now", proposal.why_now)
      |> maybe_add_element("why-not", proposal.why_not)
      |> maybe_add_files(proposal.related_files)
      |> maybe_add_dependencies(proposal.dependencies)
      |> maybe_add_element("metadata", proposal.metadata)
      |> Enum.reverse()

    element("proposal", attrs, children)
  end

  defp maybe_add_element(acc, _name, nil), do: acc
  defp maybe_add_element(acc, name, value), do: [element(name, [], value) | acc]

  defp maybe_add_files(acc, []), do: acc

  defp maybe_add_files(acc, files) do
    items = Enum.map(files, &element("file", [], &1))
    [element("related-files", [], items) | acc]
  end

  defp maybe_add_dependencies(acc, []), do: acc

  defp maybe_add_dependencies(acc, deps) do
    items = Enum.map(deps, &element("dependency", [], &1))
    [element("dependencies", [], items) | acc]
  end
end
