defmodule SpellRouter.Application do
  @moduledoc """
  The SpellRouter OTP Application.
  
  Supervises:
  - Phoenix PubSub for channel messaging
  - The HTTP/WebSocket endpoint
  - The OperatorRegistry for tracking connected operators
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # PubSub for channel communication
      {Phoenix.PubSub, name: SpellRouter.PubSub},
      
      # Registry for tracking operators
      {Registry, keys: :unique, name: SpellRouter.OperatorRegistry},
      
      # Track active pipelines
      {SpellRouter.PipelineSupervisor, []},
      
      # HTTP + WebSocket endpoint
      {Bandit, plug: SpellRouter.Endpoint, scheme: :http, port: port()}
    ]

    opts = [strategy: :one_for_one, name: SpellRouter.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port do
    String.to_integer(System.get_env("PORT") || "4000")
  end
end
