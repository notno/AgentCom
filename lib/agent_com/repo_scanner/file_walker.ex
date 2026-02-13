defmodule AgentCom.RepoScanner.FileWalker do
  @moduledoc """
  Recursive file traversal with directory and binary-file exclusions.

  Walks a directory tree, skipping excluded directories (`.git`, `_build`, etc.),
  binary file extensions, and files exceeding `@max_file_size`. Uses `File.ls/1`
  (not `File.ls!/1`) to handle permission errors gracefully.
  """

  @default_excludes [
    ".git",
    "_build",
    "deps",
    "node_modules",
    ".elixir_ls",
    "priv/static"
  ]

  @binary_extensions ~w(.beam .gz .tar .zip .png .jpg .jpeg .gif .ico
    .woff .woff2 .ttf .eot .exe .dll .so .dylib .dets .db .sqlite3)

  @max_file_size 1_048_576

  @doc """
  Walk `repo_path` recursively, returning a list of absolute file paths.

  ## Options

    * `:excludes` - list of directory names/prefixes to skip
      (default: #{inspect(@default_excludes)})
  """
  @spec walk(String.t(), keyword()) :: [String.t()]
  def walk(repo_path, opts \\ []) do
    excludes = Keyword.get(opts, :excludes, @default_excludes)
    do_walk(repo_path, repo_path, excludes)
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

      {:error, _} ->
        []
    end
  end

  defp excluded?(rel_path, entry, excludes) do
    Enum.any?(excludes, fn ex ->
      entry == ex or String.starts_with?(rel_path, ex <> "/") or
        String.starts_with?(rel_path, ex <> "\\")
    end)
  end

  defp binary_file?(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    ext in @binary_extensions
  end

  defp too_large?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size > @max_file_size
      _ -> true
    end
  end
end
