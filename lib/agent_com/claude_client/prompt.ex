defmodule AgentCom.ClaudeClient.Prompt do
  @moduledoc """
  Prompt template builder for the three core hub LLM operations.

  Each function clause of `build/2` produces a structured prompt instructing
  Claude to respond with a specific XML root element:

  - `:decompose` -- Decomposes a goal into 3-8 executable tasks.
    Expected response: `<tasks>` root with `<task>` children, each containing
    `<title>`, `<description>`, `<success-criteria>`, and `<depends-on>`.

  - `:verify` -- Verifies whether a goal has been completed based on results.
    Expected response: `<verification>` root with `<verdict>` (pass/fail),
    `<reasoning>`, and `<gaps>` (list of `<gap>` elements with `<description>`
    and `<severity>`).

  - `:identify_improvements` -- Identifies codebase improvements from a diff.
    Expected response: `<improvements>` root with `<improvement>` children,
    each containing `<title>`, `<description>`, `<category>`, `<effort>`,
    and `<files>`.

  All prompts embed input data as XML within the prompt text and end with
  a clear instruction to respond only with XML.
  """

  @spec build(atom(), map()) :: String.t()

  def build(:decompose, %{goal: goal, context: context}) do
    """
    You are a goal decomposition agent. Your task is to break down a goal into
    small, executable tasks using elephant carpaccio slicing -- each task should
    be a thin vertical slice that delivers observable value independently.

    <goal>
    #{goal_to_xml(goal)}
    </goal>

    <context>
    #{context_to_xml(context)}
    </context>

    ## Instructions

    Decompose the goal into 3-8 tasks. Each task must be:
    - A small vertical slice (touches all layers needed, but minimally)
    - Independently verifiable (has clear success criteria)
    - Ordered by dependency (earlier tasks have fewer dependencies)

    Validate that any referenced files exist in the context before including them.

    ## Response Format

    Respond with a `<tasks>` root element containing `<task>` children.
    Each `<task>` must contain:
    - `<title>` -- Short descriptive name
    - `<description>` -- What the task does and why
    - `<success-criteria>` -- How to verify the task is complete
    - `<depends-on>` -- Comma-separated indices (1-based) of tasks this depends on, or empty if none

    Example:
    <tasks>
      <task>
        <title>Add user model</title>
        <description>Create the User schema with name and email fields.</description>
        <success-criteria>User schema compiles and has name/email fields.</success-criteria>
        <depends-on></depends-on>
      </task>
      <task>
        <title>Add user API endpoint</title>
        <description>Create GET /users endpoint returning all users.</description>
        <success-criteria>GET /users returns 200 with JSON array.</success-criteria>
        <depends-on>1</depends-on>
      </task>
    </tasks>

    Respond ONLY with the XML. Do not include any text before or after the XML.
    """
  end

  def build(:verify, %{goal: goal, results: results}) do
    """
    You are a completion verification agent. Your task is to evaluate whether
    a goal has been fully achieved based on the provided results.

    <goal>
    #{goal_to_xml(goal)}
    </goal>

    <results>
    #{results_to_xml(results)}
    </results>

    ## Instructions

    Compare the results against the goal's success criteria. Determine whether
    every criterion has been met. Be strict -- partial completion is a fail.

    ## Response Format

    Respond with a `<verification>` root element containing:
    - `<verdict>` -- Either "pass" or "fail"
    - `<reasoning>` -- Explanation of why the goal passed or failed
    - `<gaps>` -- List of `<gap>` elements (empty if pass). Each `<gap>` contains:
      - `<description>` -- What is missing or incomplete
      - `<severity>` -- "critical" or "minor"

    Example:
    <verification>
      <verdict>fail</verdict>
      <reasoning>The API endpoint was created but tests are missing.</reasoning>
      <gaps>
        <gap>
          <description>No unit tests for the user endpoint.</description>
          <severity>critical</severity>
        </gap>
      </gaps>
    </verification>

    Respond ONLY with the XML. Do not include any text before or after the XML.
    """
  end

  def build(:identify_improvements, %{repo: repo, diff: diff}) do
    """
    You are a codebase improvement identification agent. Your task is to analyze
    recent changes and identify potential improvements to the repository.

    <repo>
    #{repo_to_xml(repo)}
    </repo>

    <diff>
    #{escape_xml(to_string(diff))}
    </diff>

    ## Instructions

    Analyze the diff and repository context. Identify concrete improvements that
    would enhance code quality, performance, maintainability, or test coverage.
    Focus on actionable items with clear scope.

    Each improvement should fall into one of these categories:
    - refactor -- Code structure or clarity improvements
    - test -- Missing or improved test coverage
    - docs -- Documentation gaps or improvements
    - dependency -- Dependency updates or replacements
    - performance -- Performance optimizations

    ## Response Format

    Respond with an `<improvements>` root element containing `<improvement>` children.
    Each `<improvement>` must contain:
    - `<title>` -- Short descriptive name
    - `<description>` -- What to improve and why
    - `<category>` -- One of: refactor, test, docs, dependency, performance
    - `<effort>` -- One of: small, medium, large
    - `<files>` -- Comma-separated file paths affected

    Example:
    <improvements>
      <improvement>
        <title>Extract validation logic</title>
        <description>The validation logic in UserController is duplicated. Extract to a shared module.</description>
        <category>refactor</category>
        <effort>small</effort>
        <files>lib/my_app/user_controller.ex, lib/my_app/validators.ex</files>
      </improvement>
    </improvements>

    Respond ONLY with the XML. Do not include any text before or after the XML.
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp goal_to_xml(goal) when is_map(goal) do
    title = get_field(goal, :title, "Untitled")
    description = get_field(goal, :description, "")
    criteria = get_field(goal, :success_criteria, "")

    """
    <title>#{escape_xml(title)}</title>
    <description>#{escape_xml(description)}</description>
    <success-criteria>#{escape_xml(format_criteria(criteria))}</success-criteria>
    """
    |> String.trim()
  end

  defp goal_to_xml(_), do: "<title>Unknown</title>"

  defp context_to_xml(context) when is_map(context) do
    repo = get_field(context, :repo, "")
    files = get_field(context, :files, [])
    constraints = get_field(context, :constraints, "")

    parts = []

    parts =
      if repo != "" do
        parts ++ ["<repo-name>#{escape_xml(to_string(repo))}</repo-name>"]
      else
        parts
      end

    parts =
      if is_list(files) and files != [] do
        file_items =
          files
          |> Enum.map(fn f -> "  <file>#{escape_xml(to_string(f))}</file>" end)
          |> Enum.join("\n")

        parts ++ ["<files>\n#{file_items}\n</files>"]
      else
        parts
      end

    parts =
      if constraints != "" do
        parts ++ ["<constraints>#{escape_xml(to_string(constraints))}</constraints>"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  defp context_to_xml(_), do: ""

  defp results_to_xml(results) when is_map(results) do
    summary = get_field(results, :summary, "")
    files_modified = get_field(results, :files_modified, [])
    test_outcomes = get_field(results, :test_outcomes, "")

    parts = []

    parts =
      if summary != "" do
        parts ++ ["<summary>#{escape_xml(to_string(summary))}</summary>"]
      else
        parts
      end

    parts =
      if is_list(files_modified) and files_modified != [] do
        file_items =
          files_modified
          |> Enum.map(fn f -> "  <file>#{escape_xml(to_string(f))}</file>" end)
          |> Enum.join("\n")

        parts ++ ["<files-modified>\n#{file_items}\n</files-modified>"]
      else
        parts
      end

    parts =
      if test_outcomes != "" do
        parts ++ ["<test-outcomes>#{escape_xml(to_string(test_outcomes))}</test-outcomes>"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  defp results_to_xml(results) when is_list(results) do
    results
    |> Enum.map(fn item ->
      "<result>#{escape_xml(to_string(inspect(item)))}</result>"
    end)
    |> Enum.join("\n")
  end

  defp results_to_xml(_), do: ""

  defp repo_to_xml(repo) when is_map(repo) do
    name = get_field(repo, :name, "")
    description = get_field(repo, :description, "")
    tech_stack = get_field(repo, :tech_stack, "")

    parts = []

    parts =
      if name != "" do
        parts ++ ["<name>#{escape_xml(to_string(name))}</name>"]
      else
        parts
      end

    parts =
      if description != "" do
        parts ++ ["<description>#{escape_xml(to_string(description))}</description>"]
      else
        parts
      end

    parts =
      if tech_stack != "" do
        parts ++ ["<tech-stack>#{escape_xml(to_string(tech_stack))}</tech-stack>"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  defp repo_to_xml(repo) when is_binary(repo) do
    "<name>#{escape_xml(repo)}</name>"
  end

  defp repo_to_xml(_), do: ""

  # Retrieve a field from a map supporting both atom and string keys.
  defp get_field(map, key, default) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key), default)
      value -> value
    end
  end

  # Format success criteria which may be a string or a list.
  defp format_criteria(criteria) when is_list(criteria), do: Enum.join(criteria, "; ")
  defp format_criteria(criteria), do: to_string(criteria)

  # Escape XML special characters in text content.
  defp escape_xml(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(other), do: escape_xml(to_string(other))
end
