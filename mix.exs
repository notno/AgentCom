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
      {:saxy, "~> 1.6"},
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
      ],
      before_closing_body_tag: fn
        :html ->
          """
          <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
          <script>
            document.addEventListener("DOMContentLoaded", function () {
              mermaid.initialize({ startOnLoad: false, theme: "default" });
              var i = 0;
              var codeBlocks = document.querySelectorAll("pre code.mermaid");
              codeBlocks.forEach(function (codeBlock) {
                var pre = codeBlock.parentElement;
                var graphDefinition = codeBlock.textContent;
                var containerId = "mermaid-graph-" + i;
                var div = document.createElement("div");
                div.id = containerId;
                pre.parentElement.insertBefore(div, pre);
                try {
                  mermaid.render(containerId, graphDefinition).then(function (result) {
                    div.innerHTML = result.svg;
                    pre.style.display = "none";
                  });
                } catch (e) {
                  console.error("Mermaid rendering failed for block " + i, e);
                }
                i++;
              });
            });
          </script>
          """

        _ ->
          ""
      end
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
