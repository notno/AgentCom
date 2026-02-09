defmodule AgentCom.Config do
  @moduledoc """
  Hub-wide configuration store backed by DETS.
  Stores settings as key-value pairs persisted across restarts.
  """
  use GenServer

  @table :agentcom_config
  @defaults %{
    heartbeat_interval_ms: 900_000
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a config value by key atom. Returns default if unset."
  def get(key) when is_atom(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc "Set a config value by key atom."
  def put(key, value) when is_atom(key) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    dets_path = Path.join(data_dir(), "config.dets") |> String.to_charlist()
    {:ok, @table} = :dets.open_file(@table, file: dets_path, type: :set)
    {:ok, %{table: @table}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    value =
      case :dets.lookup(@table, key) do
        [{^key, val}] -> val
        [] -> Map.get(@defaults, key)
      end

    {:reply, value, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    :ok = :dets.insert(@table, {key, value})
    :dets.sync(@table)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
  end

  defp data_dir do
    dir = Path.join([System.get_env("HOME") || ".", ".agentcom", "data"])
    File.mkdir_p!(dir)
    dir
  end
end
