defmodule AgentCom.SelfImprovement.DeterministicScanner do
  @moduledoc """
  Deterministic improvement scanner that identifies codebase issues without
  any external tool or LLM dependencies.

  Performs three types of analysis:

  1. **Test gaps** - Modules in `lib/` without corresponding test files in `test/`
  2. **Doc gaps** - Modules with `defmodule` but no `@moduledoc`
  3. **Dead dependencies** - Dependencies declared in `mix.exs` but not referenced
     in any source file

  All analysis is pure file-system based. Returns a list of Finding structs
  with appropriate severity and effort classifications. Never raises on errors.
  """

  alias AgentCom.SelfImprovement.Finding

  require Logger

  # Dependencies that are often used implicitly via macros, configs, or
  # compile-time hooks rather than direct module references in source code.
  @implicit_deps ~w(
    phoenix plug jason telemetry plug_cowboy
    cowboy cowlib ranch mime
    phoenix_html phoenix_live_view phoenix_live_dashboard
    telemetry_metrics telemetry_poller
    ecto_sql postgrex
    gettext
    castore mint finch
    swoosh gen_smtp
    floki
    esbuild tailwind dart_sass
    heroicons
    credo dialyxir ex_doc
    mix_test_watch
  )

  # Boilerplate modules that typically don't need dedicated test files
  @skip_test_patterns ~w(application.ex repo.ex)

  @doc """
  Scan a repository for test gaps, doc gaps, and dead dependencies.

  Returns a list of Finding structs. Returns `[]` if the repo has no `lib/`
  directory or any error occurs.
  """
  @spec scan(String.t()) :: [Finding.t()]
  def scan(repo_path) do
    Logger.debug("DeterministicScanner: starting scan of #{repo_path}")

    lib_dir = Path.join(repo_path, "lib")

    findings =
      if File.dir?(lib_dir) do
        test_findings = safe_scan(fn -> test_gaps(repo_path) end, "test_gaps")
        doc_findings = safe_scan(fn -> doc_gaps(repo_path) end, "doc_gaps")
        dep_findings = safe_scan(fn -> dead_deps(repo_path) end, "dead_deps")

        test_findings ++ doc_findings ++ dep_findings
      else
        []
      end

    Logger.debug("DeterministicScanner: finished scan of #{repo_path}, found #{length(findings)} issues")
    findings
  end

  # -- Test Gap Detection --

  defp test_gaps(repo_path) do
    repo_path
    |> find_lib_modules()
    |> Enum.reject(&skip_test_file?/1)
    |> Enum.flat_map(fn relative_path ->
      expected_test =
        relative_path
        |> String.replace_leading("lib/", "test/")
        |> String.replace_trailing(".ex", "_test.exs")

      full_test_path = Path.join(repo_path, expected_test)

      if File.exists?(full_test_path) do
        []
      else
        [
          %Finding{
            file_path: relative_path,
            line_number: 0,
            scan_type: "test_gap",
            description: "Module has no corresponding test file (expected #{expected_test})",
            severity: "medium",
            suggested_action: "Create #{expected_test}",
            effort: "medium",
            scanner: :deterministic
          }
        ]
      end
    end)
  end

  defp skip_test_file?(relative_path) do
    basename = Path.basename(relative_path)
    Enum.member?(@skip_test_patterns, basename)
  end

  # -- Doc Gap Detection --

  defp doc_gaps(repo_path) do
    repo_path
    |> find_lib_modules()
    |> Enum.flat_map(fn relative_path ->
      full_path = Path.join(repo_path, relative_path)

      case File.read(full_path) do
        {:ok, content} ->
          if has_defmodule?(content) and not has_moduledoc?(content) and not pure_struct?(content) do
            [
              %Finding{
                file_path: relative_path,
                line_number: 1,
                scan_type: "doc_gap",
                description: "Module missing @moduledoc",
                severity: "low",
                suggested_action: "Add @moduledoc to module in #{relative_path}",
                effort: "small",
                scanner: :deterministic
              }
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp has_defmodule?(content), do: String.contains?(content, "defmodule")
  defp has_moduledoc?(content), do: String.contains?(content, "@moduledoc")

  defp pure_struct?(content) do
    # A pure struct definition has defstruct but no public function definitions
    String.contains?(content, "defstruct") and
      not Regex.match?(~r/\bdef\s+\w+/, content)
  end

  # -- Dead Dependency Detection --

  defp dead_deps(repo_path) do
    mix_exs_path = Path.join(repo_path, "mix.exs")

    case File.read(mix_exs_path) do
      {:ok, mix_content} ->
        declared_deps = extract_dep_names(mix_content)
        all_source = read_all_source(repo_path)

        declared_deps
        |> Enum.reject(fn dep_name -> dep_name in @implicit_deps end)
        |> Enum.flat_map(fn dep_name ->
          module_name = Macro.camelize(dep_name)

          if String.contains?(all_source, module_name) do
            []
          else
            [
              %Finding{
                file_path: "mix.exs",
                line_number: 1,
                scan_type: "dead_dep",
                description: "Dependency :#{dep_name} may be unused (#{module_name} not found in source)",
                severity: "low",
                suggested_action: "Verify if :#{dep_name} is still needed",
                effort: "small",
                scanner: :deterministic
              }
            ]
          end
        end)

      _ ->
        []
    end
  end

  defp extract_dep_names(mix_content) do
    ~r/\{:(\w+),/
    |> Regex.scan(mix_content, capture: :all_but_first)
    |> List.flatten()
  end

  defp read_all_source(repo_path) do
    lib_files = Path.wildcard(Path.join([repo_path, "lib", "**", "*.ex"]))
    test_files = Path.wildcard(Path.join([repo_path, "test", "**", "*.exs"]))

    (lib_files ++ test_files)
    |> Enum.map(fn path ->
      case File.read(path) do
        {:ok, content} -> content
        _ -> ""
      end
    end)
    |> Enum.join("\n")
  end

  # -- Helpers --

  defp find_lib_modules(repo_path) do
    Path.join([repo_path, "lib", "**", "*.ex"])
    |> Path.wildcard()
    |> Enum.map(fn full_path ->
      Path.relative_to(full_path, repo_path)
      |> String.replace("\\", "/")
    end)
  end

  defp safe_scan(scan_fn, label) do
    try do
      scan_fn.()
    rescue
      e ->
        Logger.debug("DeterministicScanner: #{label} failed: #{inspect(e)}")
        []
    end
  end
end
