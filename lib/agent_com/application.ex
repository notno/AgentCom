defmodule AgentCom.Application do
  @moduledoc """
  AgentCom OTP Application.

  A lightweight message hub for OpenClaw agents across installations.
  Agents connect via WebSocket, announce presence, and exchange messages.
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Attach telemetry handlers FIRST, before any child process starts
    # emitting events. This ensures no early events are missed.
    AgentCom.Telemetry.attach_handlers()

    # Add rotating file handler for JSON log output (Phase 13)
    # Programmatic because Config.config/2 only accepts keyword lists,
    # and OTP handler tuples are {:handler, name, module, config}.
    setup_file_log_handler()

    # Create ETS table for validation backoff tracking before any child starts.
    # Public so Socket processes can read/write directly. :set for unique agent_id keys.
    :ets.new(:validation_backoff, [:named_table, :public, :set])

    # Create ETS tables for rate limiting (Phase 15).
    # :rate_limit_buckets -- token bucket state keyed by {agent_id, channel, tier}
    # :rate_limit_overrides -- per-agent override limits and whitelist
    # Both :public so Socket and Plug processes can read/write directly.
    :ets.new(:rate_limit_buckets, [:named_table, :public, :set])
    :ets.new(:rate_limit_overrides, [:named_table, :public, :set])

    children = [
      {Phoenix.PubSub, name: AgentCom.PubSub},
      {Registry, keys: :unique, name: AgentCom.AgentRegistry},
      {AgentCom.Config, []},
      {AgentCom.Auth, []},
      {AgentCom.Mailbox, []},
      {AgentCom.Channels, []},
      {AgentCom.Presence, []},
      {AgentCom.Analytics, []},
      {AgentCom.Threads, []},
      {AgentCom.MessageHistory, []},
      {AgentCom.Reaper, []},
      {Registry, keys: :unique, name: AgentCom.AgentFSMRegistry},
      {AgentCom.AgentSupervisor, []},
      {AgentCom.TaskQueue, []},
      {AgentCom.Scheduler, []},
      {AgentCom.MetricsCollector, []},
      {AgentCom.Alerter, []},
      {AgentCom.RateLimiter.Sweeper, []},
      {AgentCom.LlmRegistry, []},
      {AgentCom.DashboardState, []},
      {AgentCom.DashboardNotifier, []},
      {AgentCom.DetsBackup, []},
      {Bandit, plug: AgentCom.Endpoint, scheme: :http, port: port()}
    ]

    opts = [strategy: :one_for_one, name: AgentCom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port do
    Application.get_env(:agent_com, :port, 4000)
  end

  # Adds a rotating file handler for structured JSON log output.
  # 10MB per file, 5 rotated files, compressed on rotation.
  # Uses the same LoggerJSON formatter as the default stdout handler.
  defp setup_file_log_handler do
    log_dir = Path.join(File.cwd!(), "priv/logs")
    File.mkdir_p!(log_dir)

    formatter = LoggerJSON.Formatters.Basic.new(
      metadata: {:all_except, [:conn, :crash_reason]},
      redactors: [
        LoggerJSON.Redactors.RedactKeys.new(["token", "auth_token", "secret"])
      ]
    )

    :logger.add_handler(:file_handler, :logger_std_h, %{
      config: %{
        file: String.to_charlist(Path.join(log_dir, "agent_com.log")),
        max_no_bytes: 10_000_000,
        max_no_files: 5,
        compress_on_rotate: true
      },
      formatter: formatter
    })
  end
end
