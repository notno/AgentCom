defmodule AgentCom.RepoRegistry do
  @moduledoc """
  GenServer managing a priority-ordered repository registry with DETS persistence.

  Stores repos as a single ordered list under one DETS key for atomic reordering.
  Supports CRUD operations, priority reorder (move-up/move-down), and active/paused
  status toggling.

  ## Public API

  - `start_link/1` -- GenServer startup
  - `add_repo/1` -- register a repo, returns `{:ok, entry}` or `{:error, :already_exists}`
  - `remove_repo/1` -- remove by id, returns `:ok` or `{:error, :not_found}`
  - `list_repos/0` -- return full ordered list
  - `move_up/1`, `move_down/1` -- swap with neighbor, return `{:ok, new_list}`
  - `set_status/2` -- set `:active` or `:paused`, returns `:ok`
  - `active_repo_ids/0` -- return list of URLs for active repos (scheduler filtering)
  - `top_active_repo/0` -- return `{:ok, repo}` or `:none` (nil-repo inheritance)
  - `snapshot/0` -- return `%{repos: [...]}` for dashboard

  ## PubSub

  Broadcasts `{:repo_registry_update, :changed}` on the `"repo_registry"` topic
  after every mutation (add, remove, move, set_status).
  """
  use GenServer
  require Logger

  @dets_table :repo_registry
  @registry_key :repos

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a repository to the registry.

  Params: `%{url: string, name: string | nil}`
  Returns: `{:ok, entry}` | `{:error, :already_exists}`
  """
  def add_repo(params) do
    GenServer.call(__MODULE__, {:add_repo, params})
  end

  @doc """
  Remove a repository by id.

  Returns: `:ok` | `{:error, :not_found}`
  """
  def remove_repo(repo_id) do
    GenServer.call(__MODULE__, {:remove_repo, repo_id})
  end

  @doc "List all registered repos in priority order."
  def list_repos do
    GenServer.call(__MODULE__, :list_repos)
  end

  @doc "Move a repo up one position in priority order."
  def move_up(repo_id) do
    GenServer.call(__MODULE__, {:move, repo_id, :up})
  end

  @doc "Move a repo down one position in priority order."
  def move_down(repo_id) do
    GenServer.call(__MODULE__, {:move, repo_id, :down})
  end

  @doc """
  Set a repo's status to `:active` or `:paused`.

  Returns: `:ok`
  """
  def set_status(repo_id, status) when status in [:active, :paused] do
    GenServer.call(__MODULE__, {:set_status, repo_id, status})
  end

  @doc "Return list of URLs for all active (non-paused) repos."
  def active_repo_ids do
    GenServer.call(__MODULE__, :active_repo_ids)
  end

  @doc """
  Return the first active repo in priority order.

  Returns: `{:ok, repo}` | `:none`
  """
  def top_active_repo do
    GenServer.call(__MODULE__, :top_active_repo)
  end

  @doc "Pre-computed snapshot for dashboard."
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    dets_path = Path.join(data_dir(), "repo_registry.dets") |> String.to_charlist()
    {:ok, @dets_table} = :dets.open_file(@dets_table, file: dets_path, type: :set, auto_save: 5_000)

    repos = load_repos()

    Logger.info("repo_registry_started", repo_count: length(repos))

    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_repo, params}, _from, state) do
    url = normalize_url(params.url)
    id = url_to_id(url)
    repos = load_repos()

    if Enum.any?(repos, fn r -> r.id == id end) do
      {:reply, {:error, :already_exists}, state}
    else
      entry = %{
        id: id,
        url: url,
        name: Map.get(params, :name) || id,
        status: :active,
        added_at: System.system_time(:millisecond),
        added_by: Map.get(params, :added_by, "admin")
      }

      new_repos = repos ++ [entry]
      save_repos(new_repos)
      broadcast_change()
      {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def handle_call({:remove_repo, repo_id}, _from, state) do
    repos = load_repos()

    case Enum.split_with(repos, fn r -> r.id != repo_id end) do
      {remaining, [_removed]} ->
        save_repos(remaining)
        broadcast_change()
        {:reply, :ok, state}

      {_all, []} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_repos, _from, state) do
    {:reply, load_repos(), state}
  end

  @impl true
  def handle_call({:move, repo_id, direction}, _from, state) do
    repos = load_repos()
    idx = Enum.find_index(repos, fn r -> r.id == repo_id end)

    new_repos =
      case {idx, direction} do
        {nil, _} -> repos
        {0, :up} -> repos
        {i, :up} -> swap(repos, i, i - 1)
        {i, :down} when i >= length(repos) - 1 -> repos
        {i, :down} -> swap(repos, i, i + 1)
      end

    save_repos(new_repos)
    broadcast_change()
    {:reply, {:ok, new_repos}, state}
  end

  @impl true
  def handle_call({:set_status, repo_id, status}, _from, state)
      when status in [:active, :paused] do
    repos = load_repos()

    new_repos =
      Enum.map(repos, fn r ->
        if r.id == repo_id, do: %{r | status: status}, else: r
      end)

    save_repos(new_repos)
    broadcast_change()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:active_repo_ids, _from, state) do
    ids =
      load_repos()
      |> Enum.filter(fn r -> r.status == :active end)
      |> Enum.map(fn r -> r.url end)

    {:reply, ids, state}
  end

  @impl true
  def handle_call(:top_active_repo, _from, state) do
    result =
      load_repos()
      |> Enum.find(fn r -> r.status == :active end)

    case result do
      nil -> {:reply, :none, state}
      repo -> {:reply, {:ok, repo}, state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{repos: load_repos()}, state}
  end

  @impl true
  def handle_call(:compact, _from, state) do
    path = :dets.info(@dets_table, :filename)
    :ok = :dets.close(@dets_table)

    case :dets.open_file(@dets_table, file: path, type: :set, repair: :force) do
      {:ok, @dets_table} ->
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("repo_registry_compaction_failed", reason: inspect(reason))
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@dets_table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_repos do
    case :dets.lookup(@dets_table, @registry_key) do
      [{@registry_key, repos}] when is_list(repos) -> repos
      _ -> []
    end
  end

  defp save_repos(repos) do
    :dets.insert(@dets_table, {@registry_key, repos})
    :dets.sync(@dets_table)
  end

  defp swap(list, i, j) do
    list
    |> List.replace_at(i, Enum.at(list, j))
    |> List.replace_at(j, Enum.at(list, i))
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "repo_registry", {:repo_registry_update, :changed})
  end

  defp normalize_url(url) do
    url
    |> to_string()
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.trim_trailing(".git")
  end

  defp url_to_id(normalized_url) do
    normalized_url
    |> String.replace(~r{^https?://[^/]+/}, "")
    |> String.replace("/", "-")
  end

  defp data_dir do
    dir =
      Application.get_env(
        :agent_com,
        :repo_registry_data_dir,
        Path.join([System.get_env("HOME") || ".", ".agentcom", "data"])
      )

    File.mkdir_p!(dir)
    dir
  end
end
