import Config

config :agent_com,
  port: 4002,
  task_queue_path: "tmp/test/task_queue",
  tokens_path: "tmp/test/tokens.json",
  mailbox_path: "tmp/test/mailbox.dets",
  message_history_path: "tmp/test/message_history.dets",
  channels_path: "tmp/test/channels",
  config_data_dir: "tmp/test/config",
  threads_data_dir: "tmp/test/threads",
  backup_dir: "tmp/test/backups"

# Disable HubFSM tick to prevent auto-transitions that spawn System.cmd("claude", ...)
# which hangs in test env. Tests that need ticks call send(pid, :tick) directly.
config :agent_com, hub_fsm_tick_enabled: false

# Use claude_cli backend in test (OllamaClient tested directly with mocks)
config :agent_com, llm_backend: :claude_cli

config :logger, level: :warning
