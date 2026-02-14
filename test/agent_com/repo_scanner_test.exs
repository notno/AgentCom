defmodule AgentCom.RepoScannerTest do
  use ExUnit.Case, async: true

  alias AgentCom.RepoScanner

  @moduletag :repo_scanner

  # Helper: create a temp directory with a unique name per test.
  # Normalize path separators for Windows compatibility with Path.wildcard.
  defp setup_temp_dir do
    base = Path.join(System.tmp_dir!(), "repo_scanner_test_#{:erlang.unique_integer([:positive])}")
    |> String.replace("\\", "/")
    File.mkdir_p!(base)
    base
  end

  defp cleanup(dir) do
    File.rm_rf!(dir)
  end

  # ---------------------------------------------------------------------------
  # Token detection tests
  # ---------------------------------------------------------------------------

  describe "token detection" do
    test "detects Anthropic API key with critical severity" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "config.env")
        File.write!(file, "ANTHROPIC_KEY=sk-ant-api03-abcdefghijklmnopqrst\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:tokens])

        assert length(report.findings) >= 1
        finding = Enum.find(report.findings, &(&1.pattern_name == "anthropic_api_key"))
        assert finding != nil
        assert finding.category == :tokens
        assert finding.severity == :critical
      after
        cleanup(dir)
      end
    end

    test "detects GitHub PAT with critical severity" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "secrets.txt")
        File.write!(file, "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:tokens])

        assert length(report.findings) >= 1
        finding = Enum.find(report.findings, &(&1.pattern_name == "github_pat"))
        assert finding != nil
        assert finding.category == :tokens
        assert finding.severity == :critical
      after
        cleanup(dir)
      end
    end

    test "token matched_text is redacted (first 4 + last 4 chars)" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "config.env")
        token = "sk-ant-api03-abcdefghijklmnopqrst"
        File.write!(file, "KEY=#{token}\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:tokens])

        finding = Enum.find(report.findings, &(&1.pattern_name == "anthropic_api_key"))
        assert finding != nil
        # Must NOT contain the full token
        refute finding.matched_text == token
        # Must contain ellipsis redaction pattern
        assert String.contains?(finding.matched_text, "...")
        # Must show first 4 and last 4 chars
        assert String.starts_with?(finding.matched_text, String.slice(token, 0, 4))
      after
        cleanup(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # IP detection tests
  # ---------------------------------------------------------------------------

  describe "IP detection" do
    test "detects Tailscale IP with critical severity" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "network.conf")
        File.write!(file, "host = 100.126.22.86\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:ips])

        finding = Enum.find(report.findings, &(&1.pattern_name == "tailscale_ip"))
        assert finding != nil
        assert finding.category == :ips
        assert finding.severity == :critical
        assert finding.replacement == "your-tailscale-ip"
      after
        cleanup(dir)
      end
    end

    test "detects private IP with warning severity" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "lan.conf")
        File.write!(file, "server = 192.168.1.100\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:ips])

        finding = Enum.find(report.findings, &(&1.pattern_name == "private_ip"))
        assert finding != nil
        assert finding.category == :ips
        assert finding.severity == :warning
      after
        cleanup(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Workspace file detection tests
  # ---------------------------------------------------------------------------

  describe "workspace file detection" do
    test "detects SOUL.md with remove_and_gitignore action" do
      dir = setup_temp_dir()

      try do
        File.write!(Path.join(dir, "SOUL.md"), "# Soul\nIdentity stuff\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:workspace_files])

        finding = Enum.find(report.findings, &(&1.matched_text == "SOUL.md"))
        assert finding != nil
        assert finding.category == :workspace_files
        assert finding.action == :remove_and_gitignore
      after
        cleanup(dir)
      end
    end

    test "detects USER.md" do
      dir = setup_temp_dir()

      try do
        File.write!(Path.join(dir, "USER.md"), "# User\nPreferences\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:workspace_files])

        finding = Enum.find(report.findings, &(&1.matched_text == "USER.md"))
        assert finding != nil
        assert finding.category == :workspace_files
      after
        cleanup(dir)
      end
    end

    test "detects files in memory/ directory" do
      dir = setup_temp_dir()

      try do
        memory_dir = Path.join(dir, "memory")
        File.mkdir_p!(memory_dir)
        File.write!(Path.join(memory_dir, "notes.md"), "# Notes\nSome memory\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:workspace_files])

        finding = Enum.find(report.findings, fn f ->
          f.pattern_name == "workspace_directory_file" and
            String.contains?(f.file_path, "memory")
        end)
        assert finding != nil
        assert finding.category == :workspace_files
      after
        cleanup(dir)
      end
    end

    test "gitignore_recommendations includes detected workspace files" do
      dir = setup_temp_dir()

      try do
        File.write!(Path.join(dir, "SOUL.md"), "# Soul\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:workspace_files])

        assert "SOUL.md" in report.gitignore_recommendations
      after
        cleanup(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Personal reference detection tests
  # ---------------------------------------------------------------------------

  describe "personal reference detection" do
    test "detects personal name Nathan" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "readme.txt")
        File.write!(file, "Created by Nathan for the project\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:personal_refs])

        finding = Enum.find(report.findings, &(&1.pattern_name == "personal_name"))
        assert finding != nil
        assert finding.category == :personal_refs
        assert finding.replacement == "YOUR_NAME"
      after
        cleanup(dir)
      end
    end

    test "detects username notno" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "credits.txt")
        File.write!(file, "github: notno\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:personal_refs])

        finding = Enum.find(report.findings, &(&1.pattern_name == "username_notno"))
        assert finding != nil
        assert finding.category == :personal_refs
      after
        cleanup(dir)
      end
    end

    test "detects Windows user path with backslashes" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "paths.txt")
        File.write!(file, "home = C:\\Users\\nrosq\\Documents\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:personal_refs])

        finding = Enum.find(report.findings, &(&1.pattern_name == "windows_user_path"))
        assert finding != nil
        assert finding.category == :personal_refs
      after
        cleanup(dir)
      end
    end

    test "detects Windows user path with forward slashes" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "paths2.txt")
        File.write!(file, "home = C:/Users/nrosq/src\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:personal_refs])

        finding = Enum.find(report.findings, &(&1.pattern_name == "windows_user_path"))
        assert finding != nil
        assert finding.category == :personal_refs
      after
        cleanup(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Exclusion tests
  # ---------------------------------------------------------------------------

  describe "exclusions" do
    test "skips .git directory" do
      dir = setup_temp_dir()

      try do
        git_dir = Path.join(dir, ".git")
        File.mkdir_p!(git_dir)
        File.write!(Path.join(git_dir, "config"), "sk-ant-api03-abcdefghijklmnopqrst\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:tokens])

        assert report.findings == []
      after
        cleanup(dir)
      end
    end

    test "skips node_modules directory" do
      dir = setup_temp_dir()

      try do
        nm_dir = Path.join(dir, "node_modules")
        File.mkdir_p!(nm_dir)
        File.write!(Path.join(nm_dir, "package.json"), "sk-ant-api03-abcdefghijklmnopqrst\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:tokens])

        assert report.findings == []
      after
        cleanup(dir)
      end
    end

    test "skips binary extension files" do
      dir = setup_temp_dir()

      try do
        File.write!(Path.join(dir, "app.beam"), "sk-ant-api03-abcdefghijklmnopqrst\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:tokens])

        assert report.findings == []
      after
        cleanup(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Report structure tests
  # ---------------------------------------------------------------------------

  describe "report structure" do
    test "report has all required keys" do
      dir = setup_temp_dir()

      try do
        File.write!(Path.join(dir, "clean.txt"), "nothing sensitive here\n")

        {:ok, report} = RepoScanner.scan_repo(dir)

        assert Map.has_key?(report, :repo_path)
        assert Map.has_key?(report, :scanned_at)
        assert Map.has_key?(report, :files_scanned)
        assert Map.has_key?(report, :findings)
        assert Map.has_key?(report, :summary)
        assert Map.has_key?(report, :blocking)
        assert Map.has_key?(report, :gitignore_recommendations)
        assert Map.has_key?(report, :cleanup_tasks)
      after
        cleanup(dir)
      end
    end

    test "blocking is true when critical findings exist" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "secrets.txt")
        File.write!(file, "sk-ant-api03-abcdefghijklmnopqrst\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:tokens])

        assert report.blocking == true
        assert report.summary.critical >= 1
      after
        cleanup(dir)
      end
    end

    test "blocking is false when only warning findings exist" do
      dir = setup_temp_dir()

      try do
        file = Path.join(dir, "info.txt")
        File.write!(file, "server = 192.168.1.100\n")

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:ips])

        assert report.blocking == false
        assert report.summary.warning >= 1
        assert report.summary.critical == 0
      after
        cleanup(dir)
      end
    end

    test "summary.by_category has correct counts" do
      dir = setup_temp_dir()

      try do
        File.write!(Path.join(dir, "mixed.txt"), """
        sk-ant-api03-abcdefghijklmnopqrst
        100.126.22.86
        Nathan wrote this
        """)

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:tokens, :ips, :personal_refs])

        assert report.summary.by_category[:tokens] >= 1
        assert report.summary.by_category[:ips] >= 1
        assert report.summary.by_category[:personal_refs] >= 1
      after
        cleanup(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Category filtering test
  # ---------------------------------------------------------------------------

  describe "category filtering" do
    test "only returns findings for requested categories" do
      dir = setup_temp_dir()

      try do
        File.write!(Path.join(dir, "mixed.txt"), """
        sk-ant-api03-abcdefghijklmnopqrst
        Nathan wrote this code
        """)

        {:ok, report} = RepoScanner.scan_repo(dir, categories: [:tokens])

        categories = report.findings |> Enum.map(& &1.category) |> Enum.uniq()
        assert :tokens in categories
        refute :personal_refs in categories
      after
        cleanup(dir)
      end
    end
  end
end
