defmodule AgentCom.XML.Parser do
  @moduledoc """
  Shared parsing utilities for converting Saxy SimpleForm tuples into schema structs.

  Provides helper functions used by all schema modules in their `from_simple_form/1`
  implementations. Uses Saxy's SimpleForm representation (not raw SAX events) as the
  intermediate format, which is the idiomatic Saxy approach for document-level parsing.

  SimpleForm tuples have the shape: `{tag_name, [{attr_name, attr_value}], children}`
  where children are either nested tuples or text binaries.

  ## Conventions

  - XML element names use kebab-case (`scan-result`, `success-criteria`)
  - Elixir struct fields use snake_case (`:scan_result`, `:success_criteria`)
  - Attributes hold scalar identifiers, types, and timestamps
  - Child elements hold text content (title, description) and lists
  """

  @doc """
  Finds an attribute value by name from a SimpleForm attribute list.

  Returns `nil` if the attribute is not found.

  ## Examples

      iex> AgentCom.XML.Parser.find_attr([{"id", "g-001"}, {"priority", "high"}], "id")
      "g-001"

  """
  @spec find_attr([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def find_attr(attrs, name) when is_list(attrs) and is_binary(name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  @doc """
  Finds the text content of a child element by tag name.

  Returns `nil` if the element is not found or has no text content.

  ## Examples

      children = [{"title", [], ["My Goal"]}, {"description", [], ["A description"]}]
      AgentCom.XML.Parser.find_child_text(children, "title")
      #=> "My Goal"

  """
  @spec find_child_text(list(), String.t()) :: String.t() | nil
  def find_child_text(children, tag_name) when is_list(children) and is_binary(tag_name) do
    children
    |> Enum.find_value(fn
      {^tag_name, _attrs, content} -> extract_text(content)
      _ -> nil
    end)
  end

  @doc """
  Finds a list of text values from repeated child elements within a parent element.

  For example, `<success-criteria>` containing multiple `<criterion>` elements:

      <success-criteria>
        <criterion>First</criterion>
        <criterion>Second</criterion>
      </success-criteria>

  Returns an empty list if the parent element is not found.

  ## Examples

      children = [{"success-criteria", [], [{"criterion", [], ["First"]}, {"criterion", [], ["Second"]}]}]
      AgentCom.XML.Parser.find_child_list(children, "success-criteria", "criterion")
      #=> ["First", "Second"]

  """
  @spec find_child_list(list(), String.t(), String.t()) :: [String.t()]
  def find_child_list(children, parent_tag, item_tag)
      when is_list(children) and is_binary(parent_tag) and is_binary(item_tag) do
    case find_child_element(children, parent_tag) do
      {_, _, items} ->
        Enum.flat_map(items, fn
          {^item_tag, _attrs, content} ->
            case extract_text(content) do
              nil -> []
              text -> [text]
            end

          _ ->
            []
        end)

      nil ->
        []
    end
  end

  @doc """
  Finds a list of maps from repeated child elements within a parent element.

  Each child element's attributes become map keys. Used for structured list
  items like transition history entries.

  ## Examples

      children = [
        {"transition-history", [], [
          {"transition", [{"from", "resting"}, {"to", "executing"}, {"at", "2026-01-01T00:00:00Z"}], []}
        ]}
      ]
      AgentCom.XML.Parser.find_child_map_list(children, "transition-history", "transition")
      #=> [%{"from" => "resting", "to" => "executing", "at" => "2026-01-01T00:00:00Z"}]

  """
  @spec find_child_map_list(list(), String.t(), String.t()) :: [map()]
  def find_child_map_list(children, parent_tag, item_tag) do
    case find_child_element(children, parent_tag) do
      {_, _, items} ->
        Enum.flat_map(items, fn
          {^item_tag, attrs, _content} ->
            [Map.new(attrs)]

          _ ->
            []
        end)

      nil ->
        []
    end
  end

  @doc """
  Converts a kebab-case XML element name to a snake_case atom.

  ## Examples

      iex> AgentCom.XML.Parser.kebab_to_snake_atom("scan-result")
      :scan_result

  """
  @spec kebab_to_snake_atom(String.t()) :: atom()
  def kebab_to_snake_atom(kebab_string) do
    kebab_string
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  end

  @doc """
  Converts a snake_case atom to a kebab-case XML element name.

  ## Examples

      iex> AgentCom.XML.Parser.snake_to_kebab("scan_result")
      "scan-result"

  """
  @spec snake_to_kebab(String.t()) :: String.t()
  def snake_to_kebab(snake_string) do
    String.replace(snake_string, "_", "-")
  end

  # Private helpers

  defp find_child_element(children, tag_name) do
    Enum.find(children, fn
      {^tag_name, _attrs, _content} -> true
      _ -> false
    end)
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp extract_text(_), do: nil
end
