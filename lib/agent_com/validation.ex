defmodule AgentCom.Validation do
  @moduledoc """
  Central validation module for all external input.

  Called by Socket (WebSocket) and Endpoint (HTTP) before processing.
  Uses pure Elixir pattern matching and guards -- no external dependencies.

  ## Validation rules

  - **Strict types:** No coercion. String where integer expected is an error.
  - **Unknown fields:** Accepted and passed through untouched.
  - **String length limits:** Enforced on fields that have configured limits.
  - **Error format:** Each error is a map with `field`, `error` (atom), `detail` (string),
    and optionally `value` (the offending value, echoed back for debugging).
  """

  alias AgentCom.Validation.Schemas

  @doc """
  Validate a WebSocket message against its schema.

  Returns `{:ok, msg}` for valid messages, `{:error, errors}` for invalid ones.
  `errors` is a list of error maps with `:field`, `:error`, `:detail`, and optionally `:value`.
  """
  @spec validate_ws_message(term()) :: {:ok, map()} | {:error, [map()]}
  def validate_ws_message(msg) when is_map(msg) do
    case msg do
      %{"type" => type} when is_binary(type) ->
        case Schemas.get(type) do
          nil ->
            {:error, [%{
              field: "type",
              error: :unknown_message_type,
              detail: "unknown message type '#{type}'",
              known_types: Schemas.known_types()
            }]}

          schema ->
            validate_against_schema(msg, schema)
        end

      %{"type" => type} ->
        {:error, [%{
          field: "type",
          error: :wrong_type,
          detail: "expected string, got #{type_name(type)}",
          value: type
        }]}

      _ ->
        {:error, [%{
          field: "type",
          error: :required,
          detail: "field is required"
        }]}
    end
  end

  def validate_ws_message(_not_a_map) do
    {:error, [%{
      field: "message",
      error: :wrong_type,
      detail: "expected JSON object"
    }]}
  end

  @doc """
  Validate an HTTP request body against an endpoint schema.

  `schema_key` is an atom like `:post_task`, `:post_channel`, etc.
  Returns `{:ok, params}` for valid bodies, `{:error, errors}` for invalid ones.
  """
  @spec validate_http(atom(), map()) :: {:ok, map()} | {:error, [map()]}
  def validate_http(schema_key, params) when is_atom(schema_key) and is_map(params) do
    case Schemas.http_schema(schema_key) do
      nil ->
        {:error, [%{
          field: "schema",
          error: :unknown_schema,
          detail: "unknown HTTP schema '#{schema_key}'"
        }]}

      schema ->
        validate_against_schema(params, schema)
    end
  end

  @doc """
  Convert internal error maps to JSON-friendly maps (string keys, atom error to string).
  """
  @spec format_errors([map()]) :: [map()]
  def format_errors(errors) when is_list(errors) do
    Enum.map(errors, fn error ->
      base = %{
        "field" => error.field,
        "error" => to_string(error.error),
        "detail" => error.detail
      }

      base = if Map.has_key?(error, :value), do: Map.put(base, "value", error.value), else: base
      base = if Map.has_key?(error, :known_types), do: Map.put(base, "known_types", error.known_types), else: base
      base
    end)
  end

  # --- Private validation logic ---

  defp validate_against_schema(data, schema) do
    errors = []

    # Check required fields -- must be present (not nil) and match type
    errors =
      Enum.reduce(schema.required, errors, fn {field, expected_type}, acc ->
        case Map.fetch(data, field) do
          :error ->
            [%{field: field, error: :required, detail: "field is required"} | acc]

          {:ok, nil} ->
            [%{field: field, error: :required, detail: "field is required"} | acc]

          {:ok, value} ->
            acc
            |> validate_type(field, value, expected_type)
            |> validate_length(field, value)
        end
      end)

    # Check optional fields -- only if present, validate type
    errors =
      Enum.reduce(schema.optional, errors, fn {field, expected_type}, acc ->
        case Map.fetch(data, field) do
          :error ->
            acc

          {:ok, nil} ->
            acc

          {:ok, value} ->
            acc
            |> validate_type(field, value, expected_type)
            |> validate_length(field, value)
        end
      end)

    # Unknown fields pass through untouched (LOCKED user decision)

    case errors do
      [] -> {:ok, data}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  # --- Type validation ---

  defp validate_type(acc, field, value, :string) do
    if is_binary(value) do
      acc
    else
      [%{field: field, error: :wrong_type, detail: "expected string, got #{type_name(value)}", value: value} | acc]
    end
  end

  defp validate_type(acc, field, value, :integer) do
    if is_integer(value) do
      acc
    else
      [%{field: field, error: :wrong_type, detail: "expected integer, got #{type_name(value)}", value: value} | acc]
    end
  end

  defp validate_type(acc, field, value, :positive_integer) do
    if is_integer(value) and value > 0 do
      acc
    else
      detail =
        if is_integer(value),
          do: "expected positive integer, got #{value}",
          else: "expected positive integer, got #{type_name(value)}"

      [%{field: field, error: :wrong_type, detail: detail, value: value} | acc]
    end
  end

  defp validate_type(acc, field, value, :map) do
    if is_map(value) do
      acc
    else
      [%{field: field, error: :wrong_type, detail: "expected object, got #{type_name(value)}", value: value} | acc]
    end
  end

  defp validate_type(acc, field, value, {:list, item_type}) do
    if is_list(value) do
      # Validate each item in the list
      bad_items =
        value
        |> Enum.with_index()
        |> Enum.filter(fn {item, _idx} -> not valid_type?(item, item_type) end)

      if bad_items == [] do
        acc
      else
        [{bad_item, idx} | _] = bad_items
        [%{
          field: "#{field}[#{idx}]",
          error: :wrong_type,
          detail: "expected #{format_type_name(item_type)}, got #{type_name(bad_item)}",
          value: bad_item
        } | acc]
      end
    else
      [%{field: field, error: :wrong_type, detail: "expected array, got #{type_name(value)}", value: value} | acc]
    end
  end

  defp validate_type(acc, _field, _value, :any), do: acc

  defp validate_type(acc, field, value, :boolean) do
    if is_boolean(value) do
      acc
    else
      [%{field: field, error: :wrong_type, detail: "expected boolean, got #{type_name(value)}", value: value} | acc]
    end
  end

  # --- String length validation ---

  defp validate_length(acc, field, value) when is_binary(value) do
    case Schemas.length_limit(field) do
      nil ->
        acc

      max_length ->
        if String.length(value) > max_length do
          [%{
            field: field,
            error: :too_long,
            detail: "exceeds maximum length of #{max_length} characters",
            value: String.slice(value, 0, 50) <> "..."
          } | acc]
        else
          acc
        end
    end
  end

  defp validate_length(acc, _field, _value), do: acc

  # --- Helper functions ---

  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, :positive_integer), do: is_integer(value) and value > 0
  defp valid_type?(value, :map), do: is_map(value)
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(_value, :any), do: true
  defp valid_type?(value, {:list, item_type}), do: is_list(value) and Enum.all?(value, &valid_type?(&1, item_type))

  defp type_name(v) when is_binary(v), do: "string"
  defp type_name(v) when is_integer(v), do: "integer"
  defp type_name(v) when is_float(v), do: "float"
  defp type_name(v) when is_boolean(v), do: "boolean"
  defp type_name(v) when is_map(v), do: "object"
  defp type_name(v) when is_list(v), do: "array"
  defp type_name(nil), do: "null"
  defp type_name(_), do: "unknown"

  defp format_type_name(:string), do: "string"
  defp format_type_name(:integer), do: "integer"
  defp format_type_name(:positive_integer), do: "positive integer"
  defp format_type_name(:map), do: "object"
  defp format_type_name(:boolean), do: "boolean"
  defp format_type_name(:any), do: "any"
  defp format_type_name({:list, t}), do: "array<#{format_type_name(t)}>"
end
