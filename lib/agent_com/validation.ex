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

  @valid_complexity_tiers ~w(trivial standard complex unknown)

  @doc """
  Validate enrichment fields after standard schema validation passes.

  Performs nested validation on `file_hints`, `verification_steps`, and
  `complexity_tier` fields. Returns `{:ok, params}` or `{:error, errors}`.
  """
  @spec validate_enrichment_fields(map()) :: {:ok, map()} | {:error, [map()]}
  def validate_enrichment_fields(params) when is_map(params) do
    errors = []

    # Validate file_hints items
    errors =
      case Map.get(params, "file_hints") do
        nil -> errors
        hints when is_list(hints) ->
          hints
          |> Enum.with_index()
          |> Enum.reduce(errors, fn {hint, idx}, acc ->
            cond do
              not is_map(hint) ->
                [%{field: "file_hints[#{idx}]", error: :wrong_type,
                   detail: "expected object, got #{type_name(hint)}"} | acc]

              not is_binary(Map.get(hint, "path")) or Map.get(hint, "path") == "" ->
                [%{field: "file_hints[#{idx}].path", error: :required,
                   detail: "file hint must have a non-empty string 'path'"} | acc]

              Map.has_key?(hint, "reason") and not is_binary(Map.get(hint, "reason")) ->
                [%{field: "file_hints[#{idx}].reason", error: :wrong_type,
                   detail: "expected string, got #{type_name(Map.get(hint, "reason"))}"} | acc]

              true ->
                acc
            end
          end)
        _ -> errors
      end

    # Validate verification_steps items
    errors =
      case Map.get(params, "verification_steps") do
        nil -> errors
        steps when is_list(steps) ->
          steps
          |> Enum.with_index()
          |> Enum.reduce(errors, fn {step, idx}, acc ->
            cond do
              not is_map(step) ->
                [%{field: "verification_steps[#{idx}]", error: :wrong_type,
                   detail: "expected object, got #{type_name(step)}"} | acc]

              not is_binary(Map.get(step, "type")) or Map.get(step, "type") == "" ->
                [%{field: "verification_steps[#{idx}].type", error: :required,
                   detail: "verification step must have a non-empty string 'type'"} | acc]

              not is_binary(Map.get(step, "target")) or Map.get(step, "target") == "" ->
                [%{field: "verification_steps[#{idx}].target", error: :required,
                   detail: "verification step must have a non-empty string 'target'"} | acc]

              Map.has_key?(step, "description") and not is_binary(Map.get(step, "description")) ->
                [%{field: "verification_steps[#{idx}].description", error: :wrong_type,
                   detail: "expected string, got #{type_name(Map.get(step, "description"))}"} | acc]

              true ->
                acc
            end
          end)
        _ -> errors
      end

    # Validate complexity_tier
    errors =
      case Map.get(params, "complexity_tier") do
        nil -> errors
        tier when is_binary(tier) ->
          if tier in @valid_complexity_tiers do
            errors
          else
            [%{field: "complexity_tier", error: :invalid_value,
               detail: "must be one of: #{Enum.join(@valid_complexity_tiers, ", ")}",
               value: tier} | errors]
          end
        _ -> errors
      end

    case errors do
      [] -> {:ok, params}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Check if verification_steps exceeds the soft limit (10).

  Returns `:ok` or `{:warn, message}`.
  """
  @spec verify_step_soft_limit(map()) :: :ok | {:warn, String.t()}
  def verify_step_soft_limit(params) when is_map(params) do
    case Map.get(params, "verification_steps") do
      steps when is_list(steps) and length(steps) > 10 ->
        {:warn, "Task has #{length(steps)} verification steps (soft limit: 10). Consider splitting into smaller tasks."}
      _ ->
        :ok
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

  defp validate_type(acc, field, value, :number) do
    if is_number(value) do
      acc
    else
      [%{field: field, error: :wrong_type, detail: "expected number, got #{type_name(value)}", value: value} | acc]
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
  defp valid_type?(value, :number), do: is_number(value)
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
  defp format_type_name(:number), do: "number"
  defp format_type_name(:positive_integer), do: "positive integer"
  defp format_type_name(:map), do: "object"
  defp format_type_name(:boolean), do: "boolean"
  defp format_type_name(:any), do: "any"
  defp format_type_name({:list, t}), do: "array<#{format_type_name(t)}>"
end
