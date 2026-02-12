defmodule AgentCom.LlmRegistry do
  @moduledoc """
  GenServer managing Ollama endpoint registry with DETS persistence for
  endpoints and ETS for ephemeral resource metrics.

  Stub -- implementation pending.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register_endpoint(_params), do: {:error, :not_implemented}
  def remove_endpoint(_id), do: {:error, :not_implemented}
  def list_endpoints, do: []
  def get_endpoint(_id), do: {:error, :not_implemented}
  def report_resources(_host_id, _metrics), do: {:error, :not_implemented}
  def get_resources(_host_id), do: {:error, :not_implemented}
  def snapshot, do: %{endpoints: [], resources: %{}, fleet_models: %{}}

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end
end
