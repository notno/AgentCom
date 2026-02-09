defmodule AgentCom.Application do
  @moduledoc """
  AgentCom OTP Application.

  A lightweight message hub for OpenClaw agents across installations.
  Agents connect via WebSocket, announce presence, and exchange messages.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: AgentCom.PubSub},
      {Registry, keys: :unique, name: AgentCom.AgentRegistry},
      {AgentCom.Auth, []},
      {AgentCom.Mailbox, []},
      {AgentCom.Channels, []},
      {AgentCom.Presence, []},
      {AgentCom.Analytics, []},
      {AgentCom.Reaper, []},
      {Bandit, plug: AgentCom.Endpoint, scheme: :http, port: port()}
    ]

    opts = [strategy: :one_for_one, name: AgentCom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port do
    Application.get_env(:agent_com, :port, 4000)
  end
end
