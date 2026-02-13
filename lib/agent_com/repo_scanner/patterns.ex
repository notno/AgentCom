defmodule AgentCom.RepoScanner.Patterns do
  @moduledoc """
  Pattern definitions for sensitive-content scanning across 4 categories:
  tokens, IPs, workspace files, and personal references.

  Regex patterns are compiled at module load via `~r//` sigils.
  Workspace files use filename matching rather than content regex.
  """

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
        filenames:
          ~w(SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md AGENTS.md commit_msg.txt gen_token.ps1),
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
        regex: ~r{C:[/\\]Users[/\\]nrosq[/\\]},
        severity: :warning,
        replacement: "C:\\Users\\YOUR_USER\\"
      }
    ]
  }

  @doc "Return all scanning category atoms."
  @spec all_categories() :: [atom()]
  def all_categories, do: Map.keys(@patterns)

  @doc "Return pattern definitions for a specific category."
  @spec patterns_for(atom()) :: [map()]
  def patterns_for(category), do: Map.get(@patterns, category, [])

  @doc "Return the full pattern map across all categories."
  @spec all_patterns() :: map()
  def all_patterns, do: @patterns
end
