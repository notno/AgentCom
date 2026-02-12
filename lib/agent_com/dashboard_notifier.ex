defmodule AgentCom.DashboardNotifier do
  @moduledoc """
  GenServer managing browser push notifications for dashboard alerts.

  Sends push notifications when:
  - An agent goes offline (via PubSub presence :agent_left)
  - Health degrades (polling DashboardState every 60s)

  VAPID keys are loaded from env vars (VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY)
  or generated ephemerally on startup (subscriptions reset on restart -- acceptable for v1).
  """
  use GenServer
  require Logger

  @health_check_interval 60_000

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Add a push subscription (from browser PushManager.subscribe)."
  def subscribe(subscription) do
    GenServer.cast(__MODULE__, {:subscribe, subscription})
  end

  @doc "Returns the VAPID public key (base64url-encoded, needed by client to subscribe)."
  def get_vapid_public_key do
    GenServer.call(__MODULE__, :get_vapid_public_key)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # Subscribe to PubSub for agent offline events and backup/compaction alerts
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "presence")
    Phoenix.PubSub.subscribe(AgentCom.PubSub, "backups")

    # Load or generate VAPID keys
    {vapid_public, vapid_private} = load_or_generate_vapid_keys()

    # Configure web_push_elixir application env
    Application.put_env(:web_push_elixir, :vapid_public_key, vapid_public)
    Application.put_env(:web_push_elixir, :vapid_private_key, vapid_private)
    Application.put_env(:web_push_elixir, :vapid_subject, "mailto:admin@agentcom.local")

    # Schedule periodic health check
    Process.send_after(self(), :check_health, @health_check_interval)

    {:ok, %{
      subscriptions: MapSet.new(),
      vapid_public: vapid_public,
      vapid_private: vapid_private,
      last_health_status: :ok
    }}
  end

  @impl true
  def handle_call(:get_vapid_public_key, _from, state) do
    {:reply, state.vapid_public, state}
  end

  @impl true
  def handle_cast({:subscribe, subscription}, state) do
    # Subscription is a map with endpoint, keys.p256dh, keys.auth
    sub_json = if is_binary(subscription), do: subscription, else: Jason.encode!(subscription)
    {:noreply, %{state | subscriptions: MapSet.put(state.subscriptions, sub_json)}}
  end

  @impl true
  def handle_info({:agent_left, agent_id}, state) do
    payload = Jason.encode!(%{
      title: "AgentCom Alert",
      body: "Agent offline: #{agent_id}",
      icon: "/favicon.ico"
    })

    new_subscriptions = send_to_all(state.subscriptions, payload)
    {:noreply, %{state | subscriptions: new_subscriptions}}
  end

  def handle_info(:check_health, state) do
    new_state =
      try do
        snapshot = AgentCom.DashboardState.snapshot()
        health = Map.get(snapshot, :health) || Map.get(snapshot, "health") || %{}
        current_status = get_health_status(health)

        if state.last_health_status == :ok and current_status in [:warning, :critical] do
          conditions = get_health_conditions(health)
          condition_text = if conditions != [], do: Enum.join(conditions, "; "), else: "Health degraded"

          payload = Jason.encode!(%{
            title: "AgentCom Alert",
            body: "Health #{current_status}: #{condition_text}",
            icon: "/favicon.ico"
          })

          new_subs = send_to_all(state.subscriptions, payload)
          %{state | subscriptions: new_subs, last_health_status: current_status}
        else
          %{state | last_health_status: current_status}
        end
      rescue
        e ->
          Logger.warning("DashboardNotifier health check failed: #{inspect(e)}")
          state
      end

    Process.send_after(self(), :check_health, @health_check_interval)
    {:noreply, new_state}
  end

  # -- Compaction/recovery push notifications (failures and auto-restores only) --

  def handle_info({:compaction_failed, info}, state) do
    tables = info.failures |> Enum.map(fn f -> to_string(f.table) end) |> Enum.join(", ")
    payload = Jason.encode!(%{
      title: "AgentCom Alert",
      body: "DETS compaction failed: #{tables}",
      icon: "/favicon.ico"
    })
    new_subs = send_to_all(state.subscriptions, payload)
    {:noreply, %{state | subscriptions: new_subs}}
  end

  def handle_info({:recovery_complete, %{trigger: :auto} = info}, state) do
    # Push notification for auto-restores only (per locked decision)
    payload = Jason.encode!(%{
      title: "AgentCom Alert",
      body: "DETS auto-restore: #{info.table} restored from backup",
      icon: "/favicon.ico"
    })
    new_subs = send_to_all(state.subscriptions, payload)
    {:noreply, %{state | subscriptions: new_subs}}
  end

  def handle_info({:recovery_failed, info}, state) do
    payload = Jason.encode!(%{
      title: "AgentCom Critical",
      body: "DETS recovery FAILED: #{info.table} -- #{inspect(info[:reason])}",
      icon: "/favicon.ico"
    })
    new_subs = send_to_all(state.subscriptions, payload)
    {:noreply, %{state | subscriptions: new_subs}}
  end

  # Catch-all for unexpected PubSub messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private helpers ---

  defp load_or_generate_vapid_keys do
    vapid_public = System.get_env("VAPID_PUBLIC_KEY")
    vapid_private = System.get_env("VAPID_PRIVATE_KEY")

    if vapid_public && vapid_private do
      {vapid_public, vapid_private}
    else
      # Generate ephemeral VAPID keys (subscriptions reset on restart)
      {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
      {
        Base.url_encode64(public_key, padding: false),
        Base.url_encode64(private_key, padding: false)
      }
    end
  end

  defp send_to_all(subscriptions, payload) do
    Enum.reduce(subscriptions, MapSet.new(), fn sub_json, acc ->
      case send_push(sub_json, payload) do
        :ok -> MapSet.put(acc, sub_json)
        :error -> acc  # Remove failed subscription
      end
    end)
  end

  defp send_push(subscription_json, payload) do
    try do
      case WebPushElixir.send_notification(subscription_json, payload) do
        {:ok, %{status_code: status}} when status in 200..299 ->
          :ok
        {:ok, %{status_code: 410}} ->
          # Gone -- subscription expired
          Logger.debug("Push subscription expired, removing")
          :error
        {:ok, %{status_code: 404}} ->
          # Not found -- subscription invalid
          Logger.debug("Push subscription not found, removing")
          :error
        {:ok, %{status_code: status}} ->
          Logger.debug("Push notification returned status #{status}")
          :ok  # Keep subscription, might be transient
        {:error, reason} ->
          Logger.debug("Push notification failed: #{inspect(reason)}")
          :ok  # Keep subscription, might be transient
      end
    rescue
      e ->
        Logger.debug("Push notification error: #{inspect(e)}")
        :ok  # Keep subscription on unexpected errors
    end
  end

  defp get_health_status(health) do
    status = Map.get(health, :status) || Map.get(health, "status") || "ok"
    case to_string(status) do
      "ok" -> :ok
      "warning" -> :warning
      "critical" -> :critical
      _ -> :ok
    end
  end

  defp get_health_conditions(health) do
    (Map.get(health, :conditions) || Map.get(health, "conditions") || [])
  end
end
