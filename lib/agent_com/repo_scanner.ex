defmodule AgentCom.RepoScanner do
  @moduledoc """
  Deterministic regex scanner for sensitive content in repository files.

  Detects tokens/secrets, IP addresses, workspace files, and personal references
  using compile-time regex patterns. Returns structured reports with findings,
  severity classifications, and cleanup recommendations.

  This is a stateless library module (not a GenServer) -- call `scan_repo/2`
  or `scan_all/1` on demand.

  ## Usage

      {:ok, report} = AgentCom.RepoScanner.scan_repo("/path/to/repo")
      report.blocking   # true if any critical findings
      report.findings   # list of %Finding{} structs

  ## Categories

  - `:tokens` -- API keys (sk-ant-*, ghp_*, hex tokens)
  - `:ips` -- Tailscale IPs (100.x.x.x), private IPs (192.168.*, 10.*)
  - `:workspace_files` -- SOUL.md, USER.md, memory/, etc.
  - `:personal_refs` -- Personal names, usernames, local paths
  """

  alias AgentCom.RepoScanner.{Patterns, FileWalker, Finding}

  @type report :: %{
          repo_path: String.t(),
          scanned_at: String.t(),
          scan_duration_ms: non_neg_integer(),
          files_scanned: non_neg_integer(),
          findings: [Finding.t()],
          summary: %{
            critical: non_neg_integer(),
            warning: non_neg_integer(),
            by_category: %{atom() => non_neg_integer()}
          },
          blocking: boolean(),
          gitignore_recommendations: [String.t()],
          cleanup_tasks: [map()]
        }

  @doc """
  Scan a single repository at `repo_path` for sensitive content.

  ## Options

    * `:categories` - list of category atoms to scan for
      (default: all categories)

  Returns `{:ok, report}` or `{:error, reason}`.
  """
  @spec scan_repo(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def scan_repo(repo_path, opts \\ []) do
    categories = Keyword.get(opts, :categories, Patterns.all_categories())

    {duration_us, findings} =
      :timer.tc(fn ->
        file_paths = FileWalker.walk(repo_path)

        content_categories = categories -- [:workspace_files]

        content_findings =
          Enum.flat_map(file_paths, fn file_path ->
            scan_file(file_path, repo_path, content_categories)
          end)

        workspace_findings =
          if :workspace_files in categories do
            check_workspace_files(repo_path)
          else
            []
          end

        content_findings ++ workspace_findings
      end)

    files_scanned = length(FileWalker.walk(repo_path))
    duration_ms = div(duration_us, 1_000)

    report = build_report(repo_path, findings, files_scanned, duration_ms)
    {:ok, report}
  rescue
    e -> {:error, {e, __STACKTRACE__}}
  end

  @doc """
  Scan all registered repos for sensitive content.

  ## Options

    * `:base_dir` - base directory where repos are cloned locally
    * `:repo_path` - scan a single specific repo path instead of all
    * `:categories` - list of category atoms to scan for

  Returns `{:ok, [report]}`.
  """
  @spec scan_all(keyword()) :: {:ok, [report()]}
  def scan_all(opts \\ []) do
    case Keyword.get(opts, :repo_path) do
      path when is_binary(path) ->
        {:ok, report} = scan_repo(path, opts)
        {:ok, [report]}

      nil ->
        base_dir = Keyword.get(opts, :base_dir, ".")
        repos = AgentCom.RepoRegistry.list_repos()

        reports =
          Enum.flat_map(repos, fn repo ->
            repo_name = repo_name_from_url(repo.url)
            local_path = Path.join(base_dir, repo_name)

            if File.dir?(local_path) do
              case scan_repo(local_path, opts) do
                {:ok, report} -> [report]
                {:error, _} -> []
              end
            else
              []
            end
          end)

        {:ok, reports}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: File scanning
  # ---------------------------------------------------------------------------

  defp scan_file(file_path, repo_root, categories) do
    rel_path = Path.relative_to(file_path, repo_root)

    case File.read(file_path) do
      {:ok, content} ->
        if String.contains?(content, <<0>>) do
          []
        else
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, line_number} ->
            scan_line(line, line_number, rel_path, categories)
          end)
        end

      {:error, _} ->
        []
    end
  end

  defp scan_line(line, line_number, file_path, categories) do
    Enum.flat_map(categories, fn category ->
      Patterns.patterns_for(category)
      |> Enum.flat_map(fn pattern ->
        case Map.get(pattern, :regex) do
          nil ->
            []

          regex ->
            if Regex.match?(regex, line) do
              [
                %Finding{
                  file_path: file_path,
                  line_number: line_number,
                  category: category,
                  pattern_name: pattern.name,
                  matched_text: redact_match(regex, line, category),
                  severity: pattern.severity,
                  replacement: pattern.replacement,
                  action: :replace
                }
              ]
            else
              []
            end
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: Redaction
  # ---------------------------------------------------------------------------

  defp redact_match(regex, line, :tokens) do
    case Regex.run(regex, line) do
      [match] when byte_size(match) > 8 ->
        first = String.slice(match, 0, 4)
        last = String.slice(match, -4, 4)
        "#{first}...#{last}"

      _ ->
        "***REDACTED***"
    end
  end

  defp redact_match(regex, line, _category) do
    case Regex.run(regex, line) do
      [match | _] -> match
      _ -> "?"
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Workspace file detection
  # ---------------------------------------------------------------------------

  defp check_workspace_files(repo_path) do
    ws_config = Patterns.patterns_for(:workspace_files) |> List.first()

    file_findings =
      ws_config.filenames
      |> Enum.filter(fn name -> File.exists?(Path.join(repo_path, name)) end)
      |> Enum.map(fn name ->
        %Finding{
          file_path: name,
          line_number: 0,
          category: :workspace_files,
          pattern_name: "workspace_file",
          matched_text: name,
          severity: :warning,
          replacement: nil,
          action: :remove_and_gitignore
        }
      end)

    dir_findings =
      ws_config.dir_patterns
      |> Enum.flat_map(fn dir_pattern ->
        pattern = Path.join([repo_path, dir_pattern, "**"])

        Path.wildcard(pattern)
        |> Enum.map(fn full_path ->
          rel = Path.relative_to(full_path, repo_path)

          %Finding{
            file_path: rel,
            line_number: 0,
            category: :workspace_files,
            pattern_name: "workspace_directory_file",
            matched_text: rel,
            severity: :warning,
            replacement: nil,
            action: :remove_and_gitignore
          }
        end)
      end)

    file_findings ++ dir_findings
  end

  # ---------------------------------------------------------------------------
  # Private: Report building
  # ---------------------------------------------------------------------------

  defp build_report(repo_path, findings, files_scanned, duration_ms) do
    critical_count = Enum.count(findings, &(&1.severity == :critical))
    warning_count = Enum.count(findings, &(&1.severity == :warning))

    by_category =
      findings
      |> Enum.group_by(& &1.category)
      |> Enum.into(%{}, fn {cat, items} -> {cat, length(items)} end)

    %{
      repo_path: repo_path,
      scanned_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      scan_duration_ms: duration_ms,
      files_scanned: files_scanned,
      findings: findings,
      summary: %{
        critical: critical_count,
        warning: warning_count,
        by_category: by_category
      },
      blocking: critical_count > 0,
      gitignore_recommendations: generate_gitignore_recommendations(findings),
      cleanup_tasks: generate_cleanup_tasks(findings)
    }
  end

  defp generate_gitignore_recommendations(findings) do
    findings
    |> Enum.filter(&(&1.action == :remove_and_gitignore))
    |> Enum.map(fn finding ->
      if finding.pattern_name == "workspace_directory_file" do
        finding.file_path |> Path.dirname() |> Kernel.<>("/")
      else
        finding.file_path
      end
    end)
    |> Enum.uniq()
  end

  defp generate_cleanup_tasks(findings) do
    findings
    |> Enum.filter(&(&1.action == :replace && &1.replacement != nil))
    |> Enum.map(fn finding ->
      %{
        description: "Replace #{finding.matched_text} with #{finding.replacement} in #{finding.file_path}",
        file: finding.file_path,
        line: finding.line_number,
        replacement: finding.replacement
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: Helpers
  # ---------------------------------------------------------------------------

  defp repo_name_from_url(url) do
    url
    |> String.split("/")
    |> List.last()
    |> String.trim_trailing(".git")
  end
end
