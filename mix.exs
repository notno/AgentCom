defmodule AgentCom.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_com,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      docs: docs()
    ]
  end

  def application do
    [
      mod: {AgentCom.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets]
    ]
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.0"},
      {:websock_adapter, "~> 0.5"},
      {:plug, "~> 1.15"},
      {:web_push_elixir, "~> 0.4"},
      {:logger_json, "~> 7.0"},
      {:fresh, "~> 0.4.4", only: [:dev, :test]},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "architecture",
      extras: [
        "docs/architecture.md",
        "docs/setup.md",
        "docs/daily-operations.md",
        "docs/troubleshooting.md"
      ],
      groups_for_extras: [
        "Operations Guide": [
          "docs/architecture.md",
          "docs/setup.md",
          "docs/daily-operations.md",
          "docs/troubleshooting.md"
        ]
      ],
      groups_for_modules: [
        "Core": [
          AgentCom.Application,
          AgentCom.Config,
          AgentCom.Auth
        ],
        "Task Pipeline": [
          AgentCom.TaskQueue,
          AgentCom.Scheduler,
          AgentCom.AgentFSM,
          AgentCom.AgentSupervisor
        ],
        "Communication": [
          AgentCom.Socket,
          AgentCom.Mailbox,
          AgentCom.Channels,
          AgentCom.Router,
          AgentCom.Presence,
          AgentCom.Message,
          AgentCom.MessageHistory,
          AgentCom.Threads
        ],
        "Monitoring & Alerting": [
          AgentCom.MetricsCollector,
          AgentCom.Alerter,
          AgentCom.Analytics,
          AgentCom.Telemetry
        ],
        "Dashboard": [
          AgentCom.Dashboard,
          AgentCom.DashboardState,
          AgentCom.DashboardSocket,
          AgentCom.DashboardNotifier
        ],
        "Storage & Backup": [
          AgentCom.DetsBackup
        ],
        "Validation": [
          AgentCom.Validation,
          AgentCom.Validation.Schemas,
          AgentCom.Validation.ViolationTracker
        ],
        "Infrastructure": [
          AgentCom.Reaper,
          AgentCom.Endpoint
        ]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
