defmodule AgentCom.ClaudeClient.Response do
  @moduledoc """
  Response parser for Claude Code CLI output and Ollama JSON responses.

  ## Claude CLI Parsing (XML)

  Handles the JSON wrapper produced by `--output-format json` and extracts the
  inner XML content based on the prompt type. The parsing pipeline is:

  1. **Exit code check** -- Non-zero exit codes are immediate errors.
  2. **Empty output check** -- Empty or whitespace-only output is an error.
  3. **JSON wrapper decode** -- `--output-format json` wraps the response in a
     JSON object with a `"result"` field containing the text response.
  4. **XML extraction** -- Strip markdown fences, find the expected root element.
  5. **Type-specific parsing** -- Parse child elements into typed Elixir maps.

  ## Ollama Parsing (JSON)

  `parse_ollama/2` handles plain text containing JSON from Ollama responses.
  Strips thinking blocks and markdown fences, extracts JSON arrays/objects,
  and maps them to the same Elixir map shapes as XML parsing.

  ## Error Types

  All errors use tagged tuples for consistent pattern matching:

  - `{:error, :empty_response}` -- empty CLI output
  - `{:error, {:exit_code, integer}}` -- non-zero exit code
  - `{:error, {:unexpected_format, term}}` -- JSON structure doesn't match expected shapes
  - `{:error, {:parse_error, string}}` -- XML/JSON extraction or element parsing failure
  """

  # ---------------------------------------------------------------------------
  # Ollama response parsing (JSON)
  # ---------------------------------------------------------------------------

  @doc """
  Parse Ollama response content (plain text containing JSON) into typed Elixir maps.

  Handles all 4 prompt types: `:decompose`, `:verify`, `:identify_improvements`,
  `:generate_proposals`. Strips thinking blocks and markdown fences before
  extracting JSON.
  """
  @spec parse_ollama(String.t(), atom()) :: {:ok, term()} | {:error, term()}

  def parse_ollama(content, :decompose) do
    case extract_json(content) do
      {:ok, items} when is_list(items) ->
        tasks =
          Enum.map(items, fn item ->
            depends_on = normalize_depends_on(Map.get(item, "depends_on", []))

            %{
              title: Map.get(item, "title", ""),
              description: Map.get(item, "description", ""),
              success_criteria: Map.get(item, "success_criteria", ""),
              depends_on: depends_on
            }
          end)

        {:ok, tasks}

      {:ok, _other} ->
        {:error, {:parse_error, "expected JSON array for decompose"}}

      {:error, reason} ->
        {:error, {:parse_error, "failed to extract JSON: #{inspect(reason)}"}}
    end
  end

  def parse_ollama(content, :verify) do
    case extract_json(content) do
      {:ok, %{"verdict" => verdict_str} = item} ->
        verdict =
          case String.downcase(to_string(verdict_str)) do
            "pass" -> :pass
            "fail" -> :fail
            other -> other
          end

        gaps =
          Map.get(item, "gaps", [])
          |> Enum.map(fn gap ->
            %{
              description: Map.get(gap, "description", ""),
              severity: Map.get(gap, "severity", "minor")
            }
          end)

        {:ok, %{verdict: verdict, reasoning: Map.get(item, "reasoning", ""), gaps: gaps}}

      {:ok, _other} ->
        {:error, {:parse_error, "expected JSON object with verdict for verify"}}

      {:error, reason} ->
        {:error, {:parse_error, "failed to extract JSON: #{inspect(reason)}"}}
    end
  end

  def parse_ollama(content, :identify_improvements) do
    case extract_json(content) do
      {:ok, items} when is_list(items) ->
        improvements =
          Enum.map(items, fn item ->
            files =
              case Map.get(item, "files", []) do
                f when is_list(f) -> f
                f when is_binary(f) -> String.split(f, ",", trim: true) |> Enum.map(&String.trim/1)
                _ -> []
              end

            %{
              title: Map.get(item, "title", ""),
              description: Map.get(item, "description", ""),
              category: Map.get(item, "category", ""),
              effort: Map.get(item, "effort", ""),
              files: files
            }
          end)

        {:ok, improvements}

      {:ok, _other} ->
        {:error, {:parse_error, "expected JSON array for identify_improvements"}}

      {:error, reason} ->
        {:error, {:parse_error, "failed to extract JSON: #{inspect(reason)}"}}
    end
  end

  def parse_ollama(content, :generate_proposals) do
    case extract_json(content) do
      {:ok, items} when is_list(items) ->
        proposals =
          Enum.map(items, fn item ->
            dependencies =
              case Map.get(item, "dependencies", []) do
                d when is_list(d) -> d
                _ -> []
              end

            related_files =
              case Map.get(item, "related_files", []) do
                f when is_list(f) -> f
                _ -> []
              end

            %{
              title: Map.get(item, "title", ""),
              problem: Map.get(item, "problem", ""),
              solution: Map.get(item, "solution", ""),
              description: Map.get(item, "description", ""),
              rationale: Map.get(item, "rationale", ""),
              why_now: Map.get(item, "why_now", ""),
              why_not: Map.get(item, "why_not", ""),
              impact: Map.get(item, "impact", "medium"),
              effort: Map.get(item, "effort", "medium"),
              dependencies: dependencies,
              related_files: related_files
            }
          end)

        {:ok, proposals}

      {:ok, _other} ->
        {:error, {:parse_error, "expected JSON array for generate_proposals"}}

      {:error, reason} ->
        {:error, {:parse_error, "failed to extract JSON: #{inspect(reason)}"}}
    end
  end

  def parse_ollama(_content, unknown_type) do
    {:error, {:parse_error, "unknown prompt type: #{inspect(unknown_type)}"}}
  end

  # ---------------------------------------------------------------------------
  # Claude CLI response parsing (XML)
  # ---------------------------------------------------------------------------

  @spec parse(String.t(), non_neg_integer(), atom()) :: {:ok, term()} | {:error, term()}

  def parse(_raw_output, exit_code, _prompt_type) when exit_code != 0 do
    {:error, {:exit_code, exit_code}}
  end

  def parse(raw_output, 0, _prompt_type) when raw_output in ["", nil] do
    {:error, :empty_response}
  end

  def parse(raw_output, 0, prompt_type) do
    trimmed = String.trim(raw_output)

    if trimmed == "" do
      {:error, :empty_response}
    else
      case Jason.decode(trimmed) do
        {:ok, %{"result" => result}} when is_binary(result) ->
          parse_inner(result, prompt_type)

        {:ok, %{"result" => %{"content" => [%{"text" => text} | _]}}} when is_binary(text) ->
          parse_inner(text, prompt_type)

        {:ok, other} ->
          {:error, {:unexpected_format, other}}

        {:error, _} ->
          # Fallback: maybe plain text from --output-format text
          parse_inner(trimmed, prompt_type)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Inner parse functions (per prompt type)
  # ---------------------------------------------------------------------------

  defp parse_inner(text, :decompose) do
    case extract_xml_block(text, "tasks") do
      {:ok, xml_block} ->
        tasks =
          extract_all_elements(xml_block, "task")
          |> Enum.map(&parse_task_element/1)

        {:ok, tasks}

      {:error, :not_found} ->
        {:error, {:parse_error, "no <tasks> block found in response"}}
    end
  end

  defp parse_inner(text, :verify) do
    case extract_xml_block(text, "verification") do
      {:ok, xml_block} ->
        verdict_str = extract_child_text(xml_block, "verdict")
        reasoning = extract_child_text(xml_block, "reasoning")

        verdict =
          case verdict_str do
            "pass" -> :pass
            "fail" -> :fail
            other -> other
          end

        gaps =
          extract_all_elements(xml_block, "gap")
          |> Enum.map(fn gap_xml ->
            %{
              description: extract_child_text(gap_xml, "description") || "",
              severity: extract_child_text(gap_xml, "severity") || "minor"
            }
          end)

        {:ok, %{verdict: verdict, reasoning: reasoning || "", gaps: gaps}}

      {:error, :not_found} ->
        {:error, {:parse_error, "no <verification> block found in response"}}
    end
  end

  defp parse_inner(text, :identify_improvements) do
    case extract_xml_block(text, "improvements") do
      {:ok, xml_block} ->
        improvements =
          extract_all_elements(xml_block, "improvement")
          |> Enum.map(&parse_improvement_element/1)

        {:ok, improvements}

      {:error, :not_found} ->
        {:error, {:parse_error, "no <improvements> block found in response"}}
    end
  end

  defp parse_inner(text, :generate_proposals) do
    case extract_xml_block(text, "proposals") do
      {:ok, xml_block} ->
        proposals =
          extract_all_elements(xml_block, "proposal")
          |> Enum.map(&parse_proposal_element/1)

        {:ok, proposals}

      {:error, :not_found} ->
        {:error, {:parse_error, "no <proposals> block found in response"}}
    end
  end

  defp parse_inner(_text, unknown_type) do
    {:error, {:parse_error, "unknown prompt type: #{inspect(unknown_type)}"}}
  end

  # ---------------------------------------------------------------------------
  # Element parsers
  # ---------------------------------------------------------------------------

  defp parse_task_element(task_xml) do
    depends_on_str = extract_child_text(task_xml, "depends-on") || ""

    depends_on =
      depends_on_str
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn s ->
        case Integer.parse(s) do
          {n, _} -> [n]
          :error -> []
        end
      end)

    %{
      title: extract_child_text(task_xml, "title") || "",
      description: extract_child_text(task_xml, "description") || "",
      success_criteria: extract_child_text(task_xml, "success-criteria") || "",
      depends_on: depends_on
    }
  end

  defp parse_improvement_element(imp_xml) do
    files_str = extract_child_text(imp_xml, "files") || ""

    files =
      files_str
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{
      title: extract_child_text(imp_xml, "title") || "",
      description: extract_child_text(imp_xml, "description") || "",
      category: extract_child_text(imp_xml, "category") || "",
      effort: extract_child_text(imp_xml, "effort") || "",
      files: files
    }
  end

  defp parse_proposal_element(prop_xml) do
    # Extract dependencies list
    deps_str = extract_child_text(prop_xml, "dependencies") || ""

    dependencies =
      Regex.scan(~r/<dependency>\s*(.*?)\s*<\/dependency>/s, deps_str)
      |> Enum.map(fn [_, content] -> String.trim(content) end)
      |> Enum.reject(&(&1 == ""))

    # Extract related files list
    files_str = extract_child_text(prop_xml, "related-files") || ""

    related_files =
      Regex.scan(~r/<file>\s*(.*?)\s*<\/file>/s, files_str)
      |> Enum.map(fn [_, content] -> String.trim(content) end)
      |> Enum.reject(&(&1 == ""))

    %{
      title: extract_child_text(prop_xml, "title") || "",
      problem: extract_child_text(prop_xml, "problem") || "",
      solution: extract_child_text(prop_xml, "solution") || "",
      description: extract_child_text(prop_xml, "description") || "",
      rationale: extract_child_text(prop_xml, "rationale") || "",
      why_now: extract_child_text(prop_xml, "why-now") || "",
      why_not: extract_child_text(prop_xml, "why-not") || "",
      impact: extract_child_text(prop_xml, "impact") || "medium",
      effort: extract_child_text(prop_xml, "effort") || "medium",
      dependencies: dependencies,
      related_files: related_files
    }
  end

  # ---------------------------------------------------------------------------
  # XML extraction helpers
  # ---------------------------------------------------------------------------

  @doc false
  # Extract an XML block between opening and closing root tags.
  # Strips markdown code fences if present.
  defp extract_xml_block(text, root_tag) do
    # Strip markdown code fences if present
    cleaned = Regex.replace(~r/```(?:xml)?\n?/, text, "")
    cleaned = Regex.replace(~r/```\s*$/, cleaned, "", global: true)

    # Match the root element including attributes (e.g., <tasks attr="val">)
    pattern = Regex.compile!("<#{Regex.escape(root_tag)}[\\s>].*?</#{Regex.escape(root_tag)}>", "s")

    case Regex.run(pattern, cleaned) do
      [xml_block] -> {:ok, xml_block}
      nil -> {:error, :not_found}
    end
  end

  # Extract text content between a child element's opening and closing tags.
  # Returns the trimmed text or nil if not found.
  defp extract_child_text(xml, tag) do
    pattern = Regex.compile!("<#{Regex.escape(tag)}>\\s*(.*?)\\s*</#{Regex.escape(tag)}>", "s")

    case Regex.run(pattern, xml) do
      [_, content] ->
        trimmed = String.trim(content)
        if trimmed == "", do: nil, else: trimmed

      nil ->
        nil
    end
  end

  # Find all occurrences of an element by tag name.
  # Returns a list of the full XML strings for each occurrence.
  defp extract_all_elements(xml, tag) do
    pattern = Regex.compile!("<#{Regex.escape(tag)}>.*?</#{Regex.escape(tag)}>", "s")
    Regex.scan(pattern, xml) |> Enum.map(fn [match] -> match end)
  end

  # ---------------------------------------------------------------------------
  # JSON extraction helpers (for Ollama responses)
  # ---------------------------------------------------------------------------

  defp extract_json(text) do
    cleaned = strip_thinking(text) |> String.trim()
    # Strip markdown code fences
    cleaned = Regex.replace(~r/```(?:json)?\n?/, cleaned, "")
    cleaned = Regex.replace(~r/```\s*$/, cleaned, "", global: true)
    cleaned = String.trim(cleaned)

    case Jason.decode(cleaned) do
      {:ok, result} ->
        {:ok, result}

      {:error, _} ->
        # Try to extract JSON array or object via regex
        cond do
          String.contains?(cleaned, "[") ->
            case Regex.run(~r/\[.*\]/s, cleaned) do
              [json] -> Jason.decode(json)
              nil -> {:error, :no_json_found}
            end

          String.contains?(cleaned, "{") ->
            case Regex.run(~r/\{.*\}/s, cleaned) do
              [json] -> Jason.decode(json)
              nil -> {:error, :no_json_found}
            end

          true ->
            {:error, :no_json_found}
        end
    end
  end

  defp strip_thinking(content) do
    Regex.replace(~r/<think>.*?<\/think>/s, content, "") |> String.trim()
  end

  defp normalize_depends_on(deps) when is_list(deps) do
    Enum.flat_map(deps, fn
      n when is_integer(n) -> [n]
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} -> [n]
          :error -> []
        end
      _ -> []
    end)
  end

  defp normalize_depends_on(_), do: []
end
