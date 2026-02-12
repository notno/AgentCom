defmodule AgentCom.RateLimiter.Config do
  @moduledoc """
  Action tier classification and default thresholds for rate limiting.

  Classifies every WebSocket message type and HTTP action into one of three tiers:
  - `:light` -- high-frequency, low-cost actions (heartbeat, listing, status)
  - `:normal` -- standard operational actions (messages, subscriptions, task updates)
  - `:heavy` -- expensive or infrequent actions (identify, task submit, channel create)

  Default capacities use internal units (tokens * 1000) for integer precision.
  """

  # --- WS message type classification ---

  @light_ws ["ping", "list_agents", "list_channels", "status", "channel_history"]
  @normal_ws [
    "message", "channel_publish", "channel_subscribe", "channel_unsubscribe",
    "task_accepted", "task_progress", "task_complete", "task_failed", "task_recovering"
  ]
  @heavy_ws ["identify"]

  @doc """
  Classify a WebSocket message type string into a rate limit tier.

  Returns `:light`, `:normal`, or `:heavy`. Unknown types default to `:normal`.
  """
  @spec ws_tier(String.t()) :: :light | :normal | :heavy
  def ws_tier(message_type) when message_type in @light_ws, do: :light
  def ws_tier(message_type) when message_type in @normal_ws, do: :normal
  def ws_tier(message_type) when message_type in @heavy_ws, do: :heavy
  def ws_tier(_unknown), do: :normal

  # --- HTTP action classification ---

  @light_http [:get_agents, :get_channels, :get_tasks, :get_metrics, :get_health,
               :get_mailbox, :get_schemas, :get_dashboard_state]
  @normal_http [:post_message, :post_channel_publish, :post_channel_subscribe,
                :post_channel_unsubscribe, :post_mailbox_ack,
                :get_messages, :get_task_detail, :get_channel_info, :post_task_retry]
  @heavy_http [:post_task, :post_channel, :post_admin_push_task, :post_onboard_register]

  @doc """
  Classify an HTTP action atom into a rate limit tier.

  Returns `:light`, `:normal`, or `:heavy`. Unknown actions default to `:normal`.
  """
  @spec http_tier(atom()) :: :light | :normal | :heavy
  def http_tier(action) when action in @light_http, do: :light
  def http_tier(action) when action in @normal_http, do: :normal
  def http_tier(action) when action in @heavy_http, do: :heavy
  def http_tier(_unknown), do: :normal

  # --- Default thresholds per tier ---

  @doc """
  Return `{capacity, refill_rate_per_ms}` for a given tier.

  Capacity is in internal units (real tokens * 1000).
  Refill rate is tokens-in-internal-units per millisecond.

  - `:light`  -- 120 tokens/min => capacity 120_000, refill ~2.0/ms
  - `:normal` -- 60 tokens/min  => capacity 60_000, refill ~1.0/ms
  - `:heavy`  -- 10 tokens/min  => capacity 10_000, refill ~0.1667/ms
  """
  @spec defaults(:light | :normal | :heavy) :: {non_neg_integer(), float()}
  def defaults(:light), do: {120_000, 120_000 / 60_000.0}
  def defaults(:normal), do: {60_000, 60_000 / 60_000.0}
  def defaults(:heavy), do: {10_000, 10_000 / 60_000.0}
end
