import Config

config :spell_router,
  port: String.to_integer(System.get_env("PORT") || "4000"),
  operators_path: "priv/operators"

config :phoenix, :json_library, Jason

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :agent_id]
