defmodule AgentCom.LlmRegistry do
  @moduledoc """
  GenServer managing Ollama endpoint registry with DETS + ETS hybrid storage.

  DETS persists endpoint registrations across restarts. ETS stores ephemeral
  resource metrics reported by sidecars. Health checks poll Ollama endpoints
  on a timer, updating status and discovering models via `/api/tags`.

  ## Public API

  - `register_endpoint/1` -- register or upsert an Ollama endpoint
  - `remove_endpoint/1` -- remove an endpoint by id
  - `list_endpoints/0` -- list all registered endpoints
  - `get_endpoint/1` -- get a single endpoint by id
  - `report_resources/2` -- store ephemeral resource metrics for a host
  - `get_resources/1` -- retrieve resource metrics for a host
  - `snapshot/0` -- pre-computed summary for dashboard

  ## PubSub

  Broadcasts `{:llm_registry_update, :endpoint_changed}` on the
  `"llm_registry"` topic when endpoints are registered, removed, or
  health status changes.
  """
  use GenServer
  require Logger

  @dets_table :llm_registry
  @ets_table :llm_resource_metrics
  @health_check_interval_ms 30_000
  @stale_sweep_interval_ms 60_000
  @stale_timeout_ms 90_000
  @health_check_timeout_ms 5_000
  @unhealthy_threshold 2

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register or upsert an Ollama endpoint.

  Params: `%{host: string, port: integer, name: string | nil, source: :auto | :manual}`
  Returns: `{:ok, endpoint}` | `{:error, :invalid_params}`
  """
  def register_endpoint(params) do
    GenServer.call(__MODULE__, {:register_endpoint, params})
  end

  @doc """
  Remove an endpoint by id (host:port).

  Returns: `:ok` | `{:error, :not_found}`
  """
  def remove_endpoint(id) do
    GenServer.call(__MODULE__, {:remove_endpoint, id})
  end

  @doc "List all registered endpoints."
  def list_endpoints do
    GenServer.call(__MODULE__, :list_endpoints)
  end

  @doc """
  Get a single endpoint by id.

  Returns: `{:ok, endpoint}` | `{:error, :not_found}`
  """
  def get_endpoint(id) do
    GenServer.call(__MODULE__, {:get_endpoint, id})
  end

  @doc """
  Store ephemeral resource metrics for a host in ETS.

  Returns: `:ok`
  """
  def report_resources(host_id, metrics) do
    now = System.system_time(:millisecond)

    entry = %{
      cpu_percent: Map.get(metrics, :cpu_percent),
      ram_used_bytes: Map.get(metrics, :ram_used_bytes),
      ram_total_bytes: Map.get(metrics, :ram_total_bytes),
      vram_used_bytes: Map.get(metrics, :vram_used_bytes),
      vram_total_bytes: Map.get(metrics, :vram_total_bytes),
      source_agent_id: Map.get(metrics, :source_agent_id),
      reported_at: now
    }

    :ets.insert(@ets_table, {host_id, entry})
    :ok
  end

  @doc """
  Retrieve resource metrics for a host from ETS.

  Returns: `{:ok, metrics}` | `{:error, :not_found}`
  """
  def get_resources(host_id) do
    case :ets.lookup(@ets_table, host_id) do
      [{^host_id, metrics}] -> {:ok, metrics}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Pre-computed snapshot for dashboard.

  Returns: `%{endpoints: [...], resources: %{}, fleet_models: %{}}`
  """
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    # DETS for persistent endpoint registrations
    dets_path = Path.join(data_dir(), "llm_registry.dets") |> String.to_charlist()
    {:ok, @dets_table} = :dets.open_file(@dets_table, file: dets_path, type: :set, auto_save: 5_000)

    # ETS for ephemeral resource metrics
    :ets.new(@ets_table, [:named_table, :public, :set, {:read_concurrency, true}])

    # Load endpoints from DETS and reset all to :unknown
    endpoints = load_all_endpoints()

    Enum.each(endpoints, fn ep ->
      updated = %{ep | status: :unknown}
      :dets.insert(@dets_table, {updated.id, updated})
    end)

    # Schedule periodic tasks
    Process.send_after(self(), :health_check, @health_check_interval_ms)
    Process.send_after(self(), :sweep_stale_resources, @stale_sweep_interval_ms)

    Logger.info("llm_registry_started",
      endpoint_count: length(endpoints),
      health_check_interval_ms: @health_check_interval_ms
    )

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register_endpoint, params}, _from, state) do
    case validate_params(params) do
      {:ok, validated} ->
        id = "#{validated.host}:#{validated.port}"
        now = System.system_time(:millisecond)

        endpoint = %{
          id: id,
          host: validated.host,
          port: validated.port,
          name: Map.get(validated, :name),
          source: Map.get(validated, :source, :manual),
          status: :unknown,
          models: [],
          registered_at: now,
          last_checked_at: nil,
          consecutive_failures: 0
        }

        :dets.insert(@dets_table, {id, endpoint})
        :dets.sync(@dets_table)

        broadcast_change()

        # Trigger async model discovery (best-effort, don't block registration)
        Task.start(fn -> discover_models(endpoint) end)

        {:reply, {:ok, endpoint}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_endpoint, id}, _from, state) do
    case :dets.lookup(@dets_table, id) do
      [{^id, _endpoint}] ->
        :dets.delete(@dets_table, id)
        :dets.sync(@dets_table)
        broadcast_change()
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_endpoints, _from, state) do
    endpoints = load_all_endpoints()
    {:reply, endpoints, state}
  end

  @impl true
  def handle_call({:get_endpoint, id}, _from, state) do
    case :dets.lookup(@dets_table, id) do
      [{^id, endpoint}] -> {:reply, {:ok, endpoint}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    endpoints = load_all_endpoints()

    # Gather all resources from ETS
    resources =
      :ets.tab2list(@ets_table)
      |> Enum.into(%{}, fn {host_id, metrics} -> {host_id, metrics} end)

    # Compute fleet model summary: model_name => count of hosts
    fleet_models =
      endpoints
      |> Enum.flat_map(fn ep -> Enum.map(ep.models, fn m -> {m, ep.id} end) end)
      |> Enum.group_by(fn {model, _id} -> model end, fn {_model, id} -> id end)
      |> Enum.into(%{}, fn {model, host_ids} -> {model, length(Enum.uniq(host_ids))} end)

    snapshot = %{
      endpoints: endpoints,
      resources: resources,
      fleet_models: fleet_models
    }

    {:reply, snapshot, state}
  end

  # ---------------------------------------------------------------------------
  # Health check timer
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:health_check, state) do
    endpoints = load_all_endpoints()

    Enum.each(endpoints, fn endpoint ->
      check_endpoint_health(endpoint)
    end)

    Process.send_after(self(), :health_check, @health_check_interval_ms)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Stale resource sweep timer
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:sweep_stale_resources, state) do
    now = System.system_time(:millisecond)
    cutoff = now - @stale_timeout_ms

    :ets.tab2list(@ets_table)
    |> Enum.each(fn {host_id, metrics} ->
      if Map.get(metrics, :reported_at, 0) < cutoff do
        :ets.delete(@ets_table, host_id)
      end
    end)

    Process.send_after(self(), :sweep_stale_resources, @stale_sweep_interval_ms)
    {:noreply, state}
  end

  # Model discovery result callback
  @impl true
  def handle_info({:model_discovery, endpoint_id, models}, state) do
    case :dets.lookup(@dets_table, endpoint_id) do
      [{^endpoint_id, endpoint}] ->
        updated = %{endpoint | models: models}
        :dets.insert(@dets_table, {endpoint_id, updated})
        broadcast_change()

      [] ->
        :ok
    end

    {:noreply, state}
  end

  # Catch-all for Task messages and other unknown messages
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@dets_table)
  end

  # ---------------------------------------------------------------------------
  # Private: health check
  # ---------------------------------------------------------------------------

  defp check_endpoint_health(endpoint) do
    url = String.to_charlist("http://#{endpoint.host}:#{endpoint.port}/api/tags")
    timeout_opts = [timeout: @health_check_timeout_ms, connect_timeout: 3_000]

    result =
      try do
        case :httpc.request(:get, {url, []}, timeout_opts, []) do
          {:ok, {{_, 200, _}, _headers, body}} ->
            models =
              case Jason.decode(to_string(body)) do
                {:ok, %{"models" => model_list}} ->
                  Enum.map(model_list, fn m -> m["name"] end)

                _ ->
                  []
              end

            {:ok, models}

          {:ok, {{_, _status, _}, _, _}} ->
            :error

          {:error, _reason} ->
            :error
        end
      rescue
        _ -> :error
      catch
        _, _ -> :error
      end

    now = System.system_time(:millisecond)

    case result do
      {:ok, models} ->
        updated = %{endpoint |
          status: :healthy,
          models: models,
          last_checked_at: now,
          consecutive_failures: 0
        }

        :dets.insert(@dets_table, {endpoint.id, updated})

        if endpoint.status != :healthy do
          broadcast_change()
        end

      :error ->
        new_failures = endpoint.consecutive_failures + 1

        new_status =
          if new_failures >= @unhealthy_threshold do
            :unhealthy
          else
            endpoint.status
          end

        updated = %{endpoint |
          status: new_status,
          last_checked_at: now,
          consecutive_failures: new_failures
        }

        :dets.insert(@dets_table, {endpoint.id, updated})

        if new_status != endpoint.status do
          broadcast_change()
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: model discovery
  # ---------------------------------------------------------------------------

  defp discover_models(endpoint) do
    url = String.to_charlist("http://#{endpoint.host}:#{endpoint.port}/api/tags")
    timeout_opts = [timeout: @health_check_timeout_ms, connect_timeout: 3_000]

    try do
      case :httpc.request(:get, {url, []}, timeout_opts, []) do
        {:ok, {{_, 200, _}, _headers, body}} ->
          case Jason.decode(to_string(body)) do
            {:ok, %{"models" => model_list}} ->
              models = Enum.map(model_list, fn m -> m["name"] end)
              send(__MODULE__, {:model_discovery, endpoint.id, models})

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private: helpers
  # ---------------------------------------------------------------------------

  defp validate_params(params) do
    host = Map.get(params, :host) || Map.get(params, "host")
    port = Map.get(params, :port) || Map.get(params, "port")

    cond do
      is_nil(host) or host == "" ->
        {:error, :invalid_params}

      true ->
        clean_host =
          host
          |> to_string()
          |> String.replace(~r{^https?://}, "")
          |> String.trim_trailing("/")

        {:ok, %{
          host: clean_host,
          port: port || 11434,
          name: Map.get(params, :name) || Map.get(params, "name"),
          source: Map.get(params, :source) || Map.get(params, "source") || :manual
        }}
    end
  end

  defp load_all_endpoints do
    case :dets.match_object(@dets_table, :_) do
      {:error, _reason} ->
        []

      records ->
        Enum.map(records, fn {_id, endpoint} -> endpoint end)
    end
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(AgentCom.PubSub, "llm_registry", {:llm_registry_update, :endpoint_changed})
  end

  defp data_dir do
    dir = Application.get_env(:agent_com, :llm_registry_data_dir,
      Path.join([System.get_env("HOME") || ".", ".agentcom", "data"]))
    File.mkdir_p!(dir)
    dir
  end
end
