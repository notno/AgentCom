defmodule AgentCom.XML.Schemas.Goal do
  @moduledoc """
  XML schema struct for goal definitions.

  Goals are the primary work unit in AgentCom's autonomous loop. They flow from
  the GoalBacklog (Phase 27) into Decomposition (Phase 30) and drive the Hub FSM
  execution cycle.

  ## XML structure

      <goal id="g-001" priority="normal" source="api" repo="..." created-at="2026-01-01T00:00:00Z">
        <title>Implement rate limiting</title>
        <description>Add rate limiting to webhook endpoint</description>
        <success-criteria>
          <criterion>Returns 429 after 100 req/min</criterion>
          <criterion>Configurable via Config</criterion>
        </success-criteria>
        <metadata>optional freeform text</metadata>
      </goal>

  ## Fields

  - `id` - Unique goal identifier (required)
  - `title` - Short goal title (required)
  - `description` - Detailed goal description
  - `priority` - One of "urgent", "high", "normal", "low" (default: "normal")
  - `success_criteria` - List of success criterion strings
  - `source` - Origin: "api", "cli", "file", or "scan"
  - `repo` - Target repository URL or path
  - `created_at` - ISO 8601 timestamp
  - `metadata` - Freeform text metadata
  """

  import Saxy.XML

  alias AgentCom.XML.Parser

  @valid_priorities ~w(urgent high normal low)
  @valid_sources ~w(api cli file scan)

  @derive {Saxy.Builder,
    name: "goal",
    attributes: [:id, :priority, :source, :repo, :created_at],
    children: [
      :title,
      :description,
      :metadata,
      success_criteria: &__MODULE__.build_success_criteria/1
    ]}

  defstruct [
    :id,
    :title,
    :description,
    :source,
    :repo,
    :created_at,
    :metadata,
    priority: "normal",
    success_criteria: []
  ]

  @doc """
  Creates a new Goal struct from a keyword list or map.

  Returns `{:ok, goal}` if required fields are present, `{:error, reason}` otherwise.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    goal = struct(__MODULE__, attrs)

    cond do
      is_nil(goal.id) or goal.id == "" ->
        {:error, "goal id is required"}

      is_nil(goal.title) or goal.title == "" ->
        {:error, "goal title is required"}

      not is_nil(goal.priority) and goal.priority not in @valid_priorities ->
        {:error, "goal priority must be one of: #{Enum.join(@valid_priorities, ", ")}"}

      not is_nil(goal.source) and goal.source not in @valid_sources ->
        {:error, "goal source must be one of: #{Enum.join(@valid_sources, ", ")}"}

      true ->
        {:ok, goal}
    end
  end

  @doc """
  Builds the success-criteria XML element from a list of criterion strings.
  """
  def build_success_criteria(criteria) when is_list(criteria) do
    children = Enum.map(criteria, &element("criterion", [], &1))
    element("success-criteria", [], children)
  end

  def build_success_criteria(_), do: element("success-criteria", [], [])

  @doc """
  Parses a SimpleForm tuple into a Goal struct.
  """
  @spec from_simple_form(Saxy.SimpleForm.t()) :: {:ok, t()} | {:error, String.t()}
  def from_simple_form({"goal", attrs, children}) do
    goal = %__MODULE__{
      id: Parser.find_attr(attrs, "id"),
      title: Parser.find_child_text(children, "title"),
      description: Parser.find_child_text(children, "description"),
      priority: Parser.find_attr(attrs, "priority") || "normal",
      success_criteria: Parser.find_child_list(children, "success-criteria", "criterion"),
      source: Parser.find_attr(attrs, "source"),
      repo: Parser.find_attr(attrs, "repo"),
      created_at: Parser.find_attr(attrs, "created-at"),
      metadata: Parser.find_child_text(children, "metadata")
    }

    {:ok, goal}
  end

  def from_simple_form({tag, _attrs, _children}) do
    {:error, "expected <goal> root element, got <#{tag}>"}
  end

  @type t :: %__MODULE__{
    id: String.t() | nil,
    title: String.t() | nil,
    description: String.t() | nil,
    priority: String.t(),
    success_criteria: [String.t()],
    source: String.t() | nil,
    repo: String.t() | nil,
    created_at: String.t() | nil,
    metadata: String.t() | nil
  }
end
