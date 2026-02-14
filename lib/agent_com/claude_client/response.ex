defmodule AgentCom.ClaudeClient.Response do
  @moduledoc """
  Response parser for Claude Code CLI output.

  Handles the JSON wrapper produced by `--output-format json` and extracts the
  inner XML content based on the prompt type. The parsing pipeline is:

  1. **Exit code check** -- Non-zero exit codes are immediate errors.
  2. **Empty output check** -- Empty or whitespace-only output is an error.
  3. **JSON wrapper decode** -- `--output-format json` wraps the response in a
     JSON object with a `"result"` field containing the text response.
  4. **XML extraction** -- Strip markdown fences, find the expected root element.
  5. **Type-specific parsing** -- Parse child elements into typed Elixir maps.

  ## JSON Wrapper Formats

  The `--output-format json` mode may return different structures:

  - `%{"result" => "text response"}` -- simple string result
  - `%{"result" => %{"content" => [%{"text" => "text response"}, ...]}}` -- nested content array

  If JSON decoding fails, the raw output is tried as plain text (fallback for
  `--output-format text` or unexpected formats).

  ## Error Types

  All errors use tagged tuples for consistent pattern matching:

  - `{:error, :empty_response}` -- empty CLI output
  - `{:error, {:exit_code, integer}}` -- non-zero exit code
  - `{:error, {:unexpected_format, term}}` -- JSON structure doesn't match expected shapes
  - `{:error, {:parse_error, string}}` -- XML extraction or element parsing failure
  """

  @doc """
  Parse Ollama response content. Delegates to `parse/3` with exit_code 0,
  treating the raw content as successful CLI output.
  """
  @spec parse_ollama(String.t(), atom()) :: {:ok, term()} | {:error, term()}
  def parse_ollama(content, prompt_type), do: parse(content, 0, prompt_type)

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
end
