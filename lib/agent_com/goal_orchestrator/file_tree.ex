defmodule AgentCom.GoalOrchestrator.FileTree do
  @moduledoc """
  Cross-platform file tree gathering and reference validation.

  Provides utilities for listing repository files and validating that
  task descriptions reference files that actually exist in the repository.
  Uses Elixir stdlib (Path.wildcard, Path.expand) for cross-platform compatibility.
  """

  @excluded_dirs ~w(.git .elixir_ls _build deps node_modules)

  @file_ref_regex ~r"(?:lib|test|sidecar|config|priv)/[\w/.\-]+\.\w+"

  @doc """
  Recursively lists all regular files under `repo_path`, returning
  relative paths sorted alphabetically.

  Excludes hidden directories (starting with `.`) and common noise
  directories: #{inspect(@excluded_dirs)}.

  Returns `{:ok, [String.t()]}` on success or
  `{:error, {:not_a_directory, path}}` if the path doesn't exist or isn't a directory.
  """
  @spec gather(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def gather(repo_path) do
    if File.dir?(repo_path) do
      # Path.expand normalizes separators on Windows, making Path.wildcard work
      expanded = Path.expand(repo_path)

      files =
        expanded
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, expanded))
        |> Enum.reject(&excluded?/1)
        |> Enum.sort()

      {:ok, files}
    else
      {:error, {:not_a_directory, repo_path}}
    end
  end

  @doc """
  Validates that file references in task descriptions exist in the file tree.

  Takes a list of task maps (each with a `:description` field) and a list
  of file paths (from `gather/1`). Returns `{valid_tasks, invalid_tasks}`
  where `invalid_tasks` is a list of `{task, missing_files}` tuples.

  Tasks with no file references in their description are considered valid.
  """
  @spec validate_references([map()], [String.t()]) :: {[map()], [{map(), [String.t()]}]}
  def validate_references(tasks, file_paths) do
    file_set = MapSet.new(file_paths)

    Enum.reduce(tasks, {[], []}, fn task, {valid, invalid} ->
      desc = Map.get(task, :description, "")
      referenced = extract_file_references(desc)

      case referenced do
        [] ->
          {[task | valid], invalid}

        refs ->
          missing = Enum.reject(refs, &MapSet.member?(file_set, &1))

          if missing == [] do
            {[task | valid], invalid}
          else
            {valid, [{task, missing} | invalid]}
          end
      end
    end)
    |> then(fn {valid, invalid} ->
      {Enum.reverse(valid), Enum.reverse(invalid)}
    end)
  end

  @doc false
  @spec extract_file_references(String.t()) :: [String.t()]
  def extract_file_references(text) do
    Regex.scan(@file_ref_regex, text)
    |> List.flatten()
    |> Enum.uniq()
  end

  # --- Private ---

  defp excluded?(relative_path) do
    parts = Path.split(relative_path)

    Enum.any?(parts, fn part ->
      part in @excluded_dirs or (String.starts_with?(part, ".") and part != ".")
    end)
  end
end
