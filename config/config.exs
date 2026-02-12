import Config

config :agent_com,
  port: String.to_integer(System.get_env("PORT") || "4000"),
  backup_dir: "priv/backups"

# Structured JSON logging via LoggerJSON (Phase 13)
#
# Compile-time metadata: Elixir Logger injects :mfa (module/function/arity)
# and :line at compile time. LoggerJSON.Formatters.Basic includes them when
# metadata is set to {:all_except, [...]}, giving us full trace metadata in
# every log entry per locked decision.
#
# Uses tuple format {Module, opts} because config.exs is evaluated before
# deps are compiled -- Module.new/1 is not available at config time.
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic,
    metadata: {:all_except, [:conn, :crash_reason]},
    redactors: [
      {LoggerJSON.Redactors.RedactKeys, ["token", "auth_token", "secret"]}
    ]
  }

# Import environment-specific config (e.g., config/test.exs for MIX_ENV=test)
import_config "#{config_env()}.exs"
