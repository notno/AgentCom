import Config

config :agent_com,
  port: String.to_integer(System.get_env("PORT") || "4000")

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :agent_id]
