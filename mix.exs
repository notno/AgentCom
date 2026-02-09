defmodule AgentCom.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_com,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {AgentCom.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.0"},
      {:websock_adapter, "~> 0.5"},
      {:plug, "~> 1.15"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
