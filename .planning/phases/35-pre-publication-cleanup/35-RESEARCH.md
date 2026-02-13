# Phase 35: Pre-Publication Cleanup - Research

**Researched:** 2026-02-13
**Domain:** Regex-based sensitive content scanning for Elixir/Node.js repos
**Confidence:** HIGH

## Summary

This phase implements a deterministic regex scanner that detects sensitive content (tokens, IPs, personal references, workspace files) across all repos registered in `AgentCom.RepoRegistry`. The scanning is pure Elixir regex matching against files on disk -- no LLM, no external dependencies, no new libraries needed.

The codebase already has all the building blocks: `RepoRegistry` for repo discovery, the `AgentCom.XML` system for structured output (with `ScanResult` schema already defined for Phase 32), the endpoint pattern for API routes, and Jason for JSON. The scanner is a library module (not a GenServer) since it has no state to maintain -- it runs on demand and returns results.

**Primary recommendation:** Implement as a stateless library module `AgentCom.RepoScanner` with a configurable pattern library defined in code (module attributes). Output as structured Elixir maps (not XML) since the consumer is the API endpoint and dashboard, not the autonomous loop. Add a single API endpoint `POST /api/admin/repo-scanner/scan` to trigger scans.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
1. **Scanning Categories (from audit)**:
   - Tokens/secrets: Regex patterns for API key formats (sk-ant-*, ghp_*, bd5b66..., 617b01...)
   - IP addresses: Tailscale IPs (100.x.x.x pattern), any hardcoded IPs
   - Workspace files: SOUL.md, USER.md, IDENTITY.md, TOOLS.md, HEARTBEAT.md, AGENTS.md, memory/*.md, commit_msg.txt, gen_token.ps1
   - Personal references: "Nathan", "notno", "C:\Users\nrosq\", local machine paths

2. **Output**: Blocking report with file/line/category/severity, cleanup recommendations with replacement values, can generate cleanup tasks for GoalBacklog

3. **Scanning Approach**: Deterministic regex scanning (no LLM), configurable pattern library, scans all registered repos, triggered manually (API endpoint) or by HubFSM

### Claude's Discretion
- Report format (XML per FORMAT-01 decision, or structured Elixir map)
- Whether to auto-generate .gitignore entries
- Whether scanning should be a GenServer or library module
- Pattern library storage (config file vs code)

### Deferred Ideas (OUT OF SCOPE)
None specified.
</user_constraints>

## Discretion Recommendations

### Report Format: Structured Elixir Map (not XML)
**Rationale:** The existing `ScanResult` XML schema (Phase 32) is for improvement scan results in the autonomous loop. Pre-publication cleanup findings are consumed by the API endpoint (JSON response) and potentially the dashboard. Using Elixir maps that serialize to JSON via Jason is simpler and more appropriate. The findings structure is different from `ScanResult` (has `line_number`, `category`, `severity_tier`, `replacement`). No benefit to XML round-tripping here.

### Auto-generate .gitignore Entries: Yes
**Rationale:** When workspace files are found, the scanner should output recommended `.gitignore` additions. This is cheap to implement (just string formatting) and directly actionable. The scan report includes a `gitignore_recommendations` list.

### GenServer vs Library Module: Library Module
**Rationale:** The scanner has zero state. It reads patterns, walks files, returns results. A GenServer would add supervision complexity for no benefit. If scan-in-progress tracking is ever needed, wrap the call in a Task. The `AgentCom.RepoScanner` module exposes `scan_repo/2` and `scan_all/1`.

### Pattern Library Storage: Code (Module Attributes)
**Rationale:** Patterns are derived from the 3-agent audit and change rarely. Storing in code means they are version-controlled, testable, and have zero config-loading complexity. A `@patterns` module attribute in `AgentCom.RepoScanner.Patterns` keeps them organized by category. If runtime configurability is ever needed, it can be added later by merging `@patterns` with `Config.get(:scanner_patterns)`.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir Regex | built-in | Pattern matching | `Regex.scan/3`, `Regex.run/3` -- native, fast, no deps |
| File | built-in | File system traversal and reading | `File.ls!/1`, `File.read!/1`, `Path.wildcard/1` |
| Jason | ~> 1.4 | JSON serialization of reports | Already in deps |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Path | built-in | Path manipulation | Joining repo paths, matching extensions |
| AgentCom.RepoRegistry | existing | Repo discovery | `list_repos/0` returns registered repos with URLs |

### No New Dependencies Required
This phase requires zero new deps. Everything is built on Elixir stdlib + existing project deps.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  repo_scanner.ex              # Public API: scan_repo/2, scan_all/1
  repo_scanner/
    patterns.ex                # Pattern definitions by category
    file_walker.ex             # File traversal with exclusions
    finding.ex                 # Finding struct definition

test/agent_com/
  repo_scanner_test.exs        # Unit tests for scanner
  repo_scanner/
    patterns_test.exs          # Pattern regex tests
    file_walker_test.exs       # File traversal tests
```

### Pattern 1: Stateless Library Module with Struct Returns

**What:** `RepoScanner` is a plain module (no `use GenServer`) that takes a repo path and options, returns a report struct.

**When to use:** When the operation is pure computation with no state management needs.

**Example:**
```elixir
defmodule AgentCom.RepoScanner do
  alias AgentCom.RepoScanner.{Patterns, FileWalker, Finding}

  @type scan_opts :: [
    categories: [:tokens | :ips | :workspace_files | :personal_refs],
    repo_path: String.t()
  ]

  @spec scan_repo(String.t(), scan_opts()) :: {:ok, report()} | {:error, term()}
  def scan_repo(repo_path, opts \\ []) do
    categories = Keyword.get(opts, :categories, Patterns.all_categories())

    findings =
      FileWalker.walk(repo_path)
      |> Enum.flat_map(fn file_path ->
        scan_file(file_path, repo_path, categories)
      end)

    report = build_report(repo_path, findings)
    {:ok, report}
  end

  @spec scan_all(scan_opts()) :: {:ok, [report()]}
  def scan_all(opts \\ []) do
    repos = AgentCom.RepoRegistry.list_repos()
    reports = Enum.map(repos, fn repo ->
      path = resolve_repo_path(repo)
      {:ok, report} = scan_repo(path, opts)
      report
    end)
    {:ok, reports}
  end
end
```

### Pattern 2: Pattern Library as Module Attributes

**What:** Regex patterns organized by category with metadata (severity, replacement suggestion).

**Example:**
```elixir
defmodule AgentCom.RepoScanner.Patterns do
  @patterns %{
    tokens: [
      %{
        name: "anthropic_api_key",
        regex: ~r/sk-ant-[a-zA-Z0-9_-]{20,}/,
        severity: :critical,
        replacement: "sk-ant-REDACTED"
      },
      %{
        name: "github_pat",
        regex: ~r/ghp_[a-zA-Z0-9]{36}/,
        severity: :critical,
        replacement: "ghp_REDACTED"
      },
      %{
        name: "hex_token_bd5b66",
        regex: ~r/bd5b66[a-f0-9]{10,}/,
        severity: :critical,
        replacement: "REDACTED_TOKEN"
      },
      %{
        name: "hex_token_617b01",
        regex: ~r/617b01[a-f0-9]{10,}/,
        severity: :critical,
        replacement: "REDACTED_TOKEN"
      }
    ],
    ips: [
      %{
        name: "tailscale_ip",
        regex: ~r/\b100\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/,
        severity: :critical,
        replacement: "your-tailscale-ip"
      },
      %{
        name: "private_ip",
        regex: ~r/\b(192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/,
        severity: :warning,
        replacement: "your-private-ip"
      }
    ],
    workspace_files: [
      %{
        name: "workspace_file",
        # This category uses filename matching, not content regex
        filenames: ~w(SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md AGENTS.md commit_msg.txt gen_token.ps1),
        dir_patterns: ["memory/"],
        severity: :warning,
        action: :remove_and_gitignore
      }
    ],
    personal_refs: [
      %{
        name: "personal_name",
        regex: ~r/\bNathan\b/i,
        severity: :warning,
        replacement: "YOUR_NAME"
      },
      %{
        name: "username_notno",
        regex: ~r/\bnotno\b/,
        severity: :warning,
        replacement: "YOUR_USERNAME"
      },
      %{
        name: "windows_user_path",
        regex: ~r{C:\\Users\\nrosq\\|C:/Users/nrosq/},
        severity: :warning,
        replacement: "C:\\Users\\YOUR_USER\\"
      }
    ]
  }

  def all_categories, do: Map.keys(@patterns)
  def patterns_for(category), do: Map.get(@patterns, category, [])
  def all_patterns, do: @patterns
end
```

### Pattern 3: Finding Struct with Severity Tiers

**What:** Each finding is a struct with enough context for both the blocking report and cleanup recommendations.

**Example:**
```elixir
defmodule AgentCom.RepoScanner.Finding do
  defstruct [
    :file_path,       # relative to repo root
    :line_number,     # 1-based
    :category,        # :tokens | :ips | :workspace_files | :personal_refs
    :pattern_name,    # e.g., "anthropic_api_key"
    :matched_text,    # the actual match (redacted for tokens)
    :severity,        # :critical | :warning
    :replacement,     # suggested replacement value
    :action           # :replace | :remove_and_gitignore
  ]
end
```

### Pattern 4: Report Structure

**Example:**
```elixir
%{
  repo: "AgentCom",
  repo_path: "/path/to/AgentCom",
  scanned_at: "2026-02-13T10:00:00Z",
  scan_duration_ms: 245,
  files_scanned: 142,
  findings: [%Finding{}, ...],
  summary: %{
    critical: 3,
    warning: 12,
    by_category: %{tokens: 2, ips: 1, workspace_files: 5, personal_refs: 7}
  },
  blocking: true,  # true if any critical findings
  gitignore_recommendations: ["SOUL.md", "USER.md", "memory/", ...],
  cleanup_tasks: [
    %{description: "Replace 100.126.22.86 with placeholder in docs/setup.md", ...}
  ]
}
```

### Anti-Patterns to Avoid
- **Reading entire files into memory for huge repos:** Use `File.stream!/1` with `Stream.with_index/1` for line-by-line scanning. Most files are small, but binary files should be skipped entirely.
- **Scanning binary files:** Skip files matching common binary extensions (.beam, .gz, .png, .jpg, .exe, .dll, etc.) and files that fail UTF-8 validation.
- **Scanning .git directory:** Always exclude `.git/`, `_build/`, `deps/`, `node_modules/` from traversal.
- **Exposing matched secrets in reports:** For token findings, show only the pattern name and first/last 4 chars, never the full token value.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| File traversal with exclusions | Custom recursive walker | `Path.wildcard/2` + filter | Handles symlinks, permissions correctly |
| JSON serialization | Manual map building | Jason.encode with deriving | Already in deps, handles edge cases |
| Regex compilation | Runtime compilation each scan | Module attribute `~r//` sigils | Compiled once at module load |
| Line-number tracking | Manual counter | `File.stream!` + `Stream.with_index` | Elixir idiom, lazy evaluation |

**Key insight:** This is a straightforward file-scanning problem. The complexity is in getting the regex patterns right and handling edge cases (binary files, encoding, large files), not in architecture.

## Common Pitfalls

### Pitfall 1: URL-to-Path Resolution
**What goes wrong:** `RepoRegistry` stores repo URLs (e.g., `https://github.com/user/AgentCom`), but the scanner needs local filesystem paths.
**Why it happens:** The registry was designed for repo identity, not local cloning.
**How to avoid:** Need a mapping function or convention. Options: (a) derive from URL using a known clone directory convention, (b) add a `local_path` field to repo registry entries, (c) accept path as parameter to `scan_repo/2`. Recommendation: option (c) for now -- the API endpoint or HubFSM caller provides the local path. `scan_all/1` can use a configurable base directory.
**Warning signs:** Scanner returns `{:error, :enoent}` for all repos.

### Pitfall 2: False Positives on IP Patterns
**What goes wrong:** `100.x.x.x` regex matches version numbers, port numbers, or other numeric sequences in code.
**Why it happens:** Overly broad regex without context.
**How to avoid:** Add negative lookahead/lookbehind for common false positive contexts. For example, skip matches inside version strings like `"1.0.0"` or after `port:`. Also maintain a whitelist for known safe matches (e.g., `100.0.0.0/8` in documentation about CGNAT).
**Warning signs:** Scan report has dozens of IP findings that are all version numbers.

### Pitfall 3: Scanning Binary Files Causes Crashes
**What goes wrong:** Reading `.beam` or image files as text causes encoding errors or massive memory use.
**Why it happens:** Naive `File.read!` on every file in the repo.
**How to avoid:** Skip files by extension (`.beam`, `.gz`, `.png`, `.jpg`, `.gif`, `.ico`, `.woff`, `.ttf`, `.exe`, `.dll`, `.dets`, `.db`). Also skip files larger than a size threshold (e.g., 1MB). Check for null bytes in first 512 bytes as a binary detection heuristic.
**Warning signs:** Scanner crashes with `{:error, :invalid_encoding}` or takes minutes on a small repo.

### Pitfall 4: Windows Path Separators
**What goes wrong:** Regex for `C:\Users\nrosq\` doesn't match because backslashes need double-escaping in regex.
**Why it happens:** The project runs on Windows, and paths in source files may use either `/` or `\`.
**How to avoid:** Pattern must match both: `~r{C:[/\\]Users[/\\]nrosq[/\\]}`. Test with both separator styles.
**Warning signs:** Personal path references in PowerShell scripts or batch files are missed.

### Pitfall 5: Scanning deps/ and _build/
**What goes wrong:** Scanner finds "secrets" in third-party dependencies or compiled artifacts.
**Why it happens:** No directory exclusion list.
**How to avoid:** Default exclusion list: `.git/`, `_build/`, `deps/`, `node_modules/`, `.elixir_ls/`, `priv/static/` (if vendored). Make exclusions configurable.
**Warning signs:** Hundreds of findings from hex packages.

## Code Examples

### File Walker with Exclusions
```elixir
defmodule AgentCom.RepoScanner.FileWalker do
  @default_excludes [
    ".git", "_build", "deps", "node_modules",
    ".elixir_ls", "priv/static"
  ]

  @binary_extensions ~w(.beam .gz .tar .zip .png .jpg .jpeg .gif .ico
    .woff .woff2 .ttf .eot .exe .dll .so .dylib .dets .db .sqlite3)

  @max_file_size 1_048_576  # 1 MB

  @spec walk(String.t(), keyword()) :: [String.t()]
  def walk(repo_path, opts \\ []) do
    excludes = Keyword.get(opts, :excludes, @default_excludes)

    repo_path
    |> do_walk(repo_path, excludes)
    |> List.flatten()
  end

  defp do_walk(dir, repo_root, excludes) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full_path = Path.join(dir, entry)
          rel_path = Path.relative_to(full_path, repo_root)

          cond do
            excluded?(rel_path, entry, excludes) -> []
            File.dir?(full_path) -> do_walk(full_path, repo_root, excludes)
            binary_file?(entry) -> []
            too_large?(full_path) -> []
            true -> [full_path]
          end
        end)

      {:error, _} -> []
    end
  end

  defp excluded?(rel_path, entry, excludes) do
    Enum.any?(excludes, fn ex ->
      entry == ex or String.starts_with?(rel_path, ex <> "/")
    end)
  end

  defp binary_file?(filename) do
    ext = Path.extname(filename) |> String.downcase()
    ext in @binary_extensions
  end

  defp too_large?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size > @max_file_size
      _ -> true
    end
  end
end
```

### Line-by-Line Scanning
```elixir
defp scan_file(file_path, repo_root, categories) do
  rel_path = Path.relative_to(file_path, repo_root)

  case File.read(file_path) do
    {:ok, content} ->
      # Check for binary content (null bytes)
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

    {:error, _} -> []
  end
end

defp scan_line(line, line_number, file_path, categories) do
  Enum.flat_map(categories, fn category ->
    Patterns.patterns_for(category)
    |> Enum.flat_map(fn pattern ->
      case Map.get(pattern, :regex) do
        nil -> []
        regex ->
          if Regex.match?(regex, line) do
            [%Finding{
              file_path: file_path,
              line_number: line_number,
              category: category,
              pattern_name: pattern.name,
              matched_text: redact_match(regex, line, category),
              severity: pattern.severity,
              replacement: pattern.replacement,
              action: :replace
            }]
          else
            []
          end
      end
    end)
  end)
end

defp redact_match(_regex, line, :tokens) do
  # Never expose full token - show first 4 and last 4 chars
  case Regex.run(~r/[a-zA-Z0-9_-]{8,}/, line) do
    [match] when byte_size(match) > 8 ->
      first = String.slice(match, 0, 4)
      last = String.slice(match, -4, 4)
      "#{first}...#{last}"
    _ -> "***REDACTED***"
  end
end

defp redact_match(regex, line, _category) do
  case Regex.run(regex, line) do
    [match | _] -> match
    _ -> "?"
  end
end
```

### Workspace File Detection (different from content scanning)
```elixir
defp check_workspace_files(repo_path) do
  workspace_patterns = Patterns.patterns_for(:workspace_files)
  ws_config = List.first(workspace_patterns)

  filenames = ws_config.filenames
  dir_patterns = ws_config.dir_patterns

  # Check root-level workspace files
  file_findings =
    filenames
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

  # Check directory patterns (e.g., memory/*.md)
  dir_findings =
    dir_patterns
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
```

### API Endpoint Pattern
```elixir
# In endpoint.ex, following existing patterns:
post "/api/admin/repo-scanner/scan" do
  conn = AgentCom.Plugs.RequireAuth.call(conn, [])
  if conn.halted do
    conn
  else
    opts = []
    opts = if p = conn.body_params["repo_path"], do: [{:repo_path, p} | opts], else: opts
    opts = if p = conn.body_params["categories"], do: [{:categories, parse_categories(p)} | opts], else: opts

    case conn.body_params do
      %{"repo_path" => path} when is_binary(path) ->
        case AgentCom.RepoScanner.scan_repo(path, opts) do
          {:ok, report} -> send_json(conn, 200, report)
          {:error, reason} -> send_json(conn, 422, %{"error" => inspect(reason)})
        end

      _ ->
        # Scan all registered repos
        case AgentCom.RepoScanner.scan_all(opts) do
          {:ok, reports} -> send_json(conn, 200, %{"reports" => reports})
        end
    end
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual grep for secrets | Structured regex scanning with reports | This phase | Systematized, repeatable |
| Ad-hoc .gitignore additions | Scanner-generated gitignore recommendations | This phase | Nothing missed |

**Note:** Tools like `gitleaks`, `truffleHog`, and `detect-secrets` exist in the broader ecosystem for secret scanning, but they are external tools (Python/Go). The decision here is to build a focused, Elixir-native scanner that covers the specific patterns identified by the 3-agent audit. This is appropriate because: (1) the pattern set is small and known, (2) no new deps needed, (3) it integrates directly with RepoRegistry and the API.

## Open Questions

1. **URL-to-local-path resolution for scan_all**
   - What we know: RepoRegistry stores URLs, scanner needs filesystem paths
   - What's unclear: Where repos are cloned locally -- is there a convention?
   - Recommendation: Accept `base_dir` option in `scan_all/1` that defaults to a config value. Each repo's local path is derived as `Path.join(base_dir, repo.id)`. The API caller can also pass `repo_path` explicitly for single-repo scans.

2. **GoalBacklog task generation**
   - What we know: CONTEXT says "can generate cleanup tasks for GoalBacklog (Phase 27)"
   - What's unclear: Whether GoalBacklog is implemented yet and what its task submission API looks like
   - Recommendation: Build the `cleanup_tasks` list in the report as data. Add a separate function `generate_goals/1` that converts findings to Goal XML structs using the existing `AgentCom.XML.Schemas.Goal` schema. This can be wired up when GoalBacklog is ready.

3. **HubFSM trigger integration**
   - What we know: Scanner can be triggered by HubFSM
   - What's unclear: What HubFSM state/event triggers a scan
   - Recommendation: Defer HubFSM integration. The scanner's API is a simple function call -- HubFSM can call `RepoScanner.scan_all/1` whenever it's appropriate. No scanner-side changes needed.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `lib/agent_com/repo_registry.ex` -- RepoRegistry API, stores repos by URL
- Codebase analysis: `lib/agent_com/xml/schemas/scan_result.ex` -- Existing scan result schema (Phase 32, different purpose)
- Codebase analysis: `lib/agent_com/endpoint.ex` -- API route patterns, auth patterns
- Codebase analysis: `lib/agent_com/xml/xml.ex` -- XML encode/decode system
- Codebase analysis: `mix.exs` -- Dependencies (Jason, Saxy, Plug)

### Secondary (MEDIUM confidence)
- CONTEXT.md audit findings -- specific patterns (sk-ant-*, ghp_*, IPs, file names) from 3-agent audit
- Elixir stdlib documentation -- File, Path, Regex, Stream modules (well-known stable APIs)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - No new dependencies, all Elixir stdlib
- Architecture: HIGH - Follows existing codebase patterns exactly (library modules, endpoint routes, struct returns)
- Pitfalls: HIGH - Based on direct codebase analysis (Windows paths, binary files, dep directories all visible in repo)
- Patterns: HIGH - Regex patterns are specified in CONTEXT.md from audit, just need encoding

**Research date:** 2026-02-13
**Valid until:** 2026-03-13 (stable -- no external dependencies to version-drift)
