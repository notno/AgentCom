defmodule AgentCom.Channels do
  @moduledoc """
  Named channels for topic-based messaging.

  Channels sit between DMs (one-to-one) and broadcasts (all agents).
  Agents subscribe to channels they care about and only receive
  messages published to those channels.

  Backed by DETS for persistence across restarts.

  ## Channel names
  Prefixed with `#` by convention (e.g. `#agentcom-dev`, `#research`).
  Stored without the `#` internally — normalize on input.

  ## Message flow
  1. Agent publishes to a channel
  2. Online subscribers get it via WebSocket (PubSub)
  3. All subscribers get it in their mailbox for polling
  """
  use GenServer
  require Logger

  @table :agent_channels
  @history_table :channel_history
  @max_history_per_channel 200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    channels_path = dets_path("channels") |> String.to_charlist()
    history_path = dets_path("channel_history") |> String.to_charlist()
    File.mkdir_p!(Path.dirname(dets_path("channels")))

    {:ok, @table} = :dets.open_file(@table, file: channels_path, type: :set, auto_save: 5_000)
    {:ok, @history_table} = :dets.open_file(@history_table, file: history_path, type: :set, auto_save: 5_000)

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :dets.close(@history_table)
    :ok
  end

  # --- Public API ---

  @doc "Create a channel. Returns :ok or {:error, :exists}."
  def create(name, opts \\ %{}) do
    GenServer.call(__MODULE__, {:create, normalize(name), opts})
  end

  @doc "Subscribe an agent to a channel."
  def subscribe(channel, agent_id) do
    GenServer.call(__MODULE__, {:subscribe, normalize(channel), agent_id})
  end

  @doc "Unsubscribe an agent from a channel."
  def unsubscribe(channel, agent_id) do
    GenServer.call(__MODULE__, {:unsubscribe, normalize(channel), agent_id})
  end

  @doc "Publish a message to a channel. Delivers to all subscribers."
  def publish(channel, %AgentCom.Message{} = msg) do
    GenServer.call(__MODULE__, {:publish, normalize(channel), msg})
  end

  @doc "List all channels with subscriber counts."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Get channel info including subscribers."
  def info(channel) do
    GenServer.call(__MODULE__, {:info, normalize(channel)})
  end

  @doc "Get channel message history."
  def history(channel, opts \\ []) do
    GenServer.call(__MODULE__, {:history, normalize(channel), opts})
  end

  @doc "List channels an agent is subscribed to."
  def subscriptions(agent_id) do
    GenServer.call(__MODULE__, {:subscriptions, agent_id})
  end

  # --- Server Callbacks ---

  @impl true
  def handle_call({:create, name, opts}, _from, state) do
    case :dets.lookup(@table, name) do
      [{^name, _}] ->
        {:reply, {:error, :exists}, state}
      [] ->
        channel = %{
          name: name,
          description: Map.get(opts, :description, ""),
          created_at: System.system_time(:millisecond),
          created_by: Map.get(opts, :created_by, "system"),
          subscribers: []
        }
        :dets.insert(@table, {name, channel})
        {:reply, :ok, state}
    end
  end

  def handle_call({:subscribe, channel, agent_id}, _from, state) do
    case :dets.lookup(@table, channel) do
      {:error, reason} ->
        Logger.error("dets_corruption_detected", table: @table, reason: inspect(reason))
        GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @table, reason})
        {:reply, {:error, :table_corrupted}, state}

      [{^channel, info}] ->
        if agent_id in info.subscribers do
          {:reply, {:ok, :already_subscribed}, state}
        else
          updated = %{info | subscribers: [agent_id | info.subscribers]}
          :dets.insert(@table, {channel, updated})

          # Subscribe to PubSub topic for real-time delivery
          Phoenix.PubSub.broadcast(AgentCom.PubSub, "channel:#{channel}",
            {:channel_subscribed, channel, agent_id})

          {:reply, :ok, state}
        end
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unsubscribe, channel, agent_id}, _from, state) do
    case :dets.lookup(@table, channel) do
      [{^channel, info}] ->
        updated = %{info | subscribers: List.delete(info.subscribers, agent_id)}
        :dets.insert(@table, {channel, updated})
        {:reply, :ok, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:publish, channel, msg}, _from, state) do
    case :dets.lookup(@table, channel) do
      {:error, reason} ->
        Logger.error("dets_corruption_detected", table: @table, reason: inspect(reason))
        GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @table, reason})
        {:reply, {:error, :table_corrupted}, state}

      [{^channel, info}] ->
        # Store in channel history
        seq = store_history(channel, msg)

        # Deliver to each subscriber's mailbox (for polling)
        channel_msg = %{msg | payload: Map.put(msg.payload, "channel", channel)}
        Enum.each(info.subscribers, fn sub_id ->
          # Don't mailbox the sender — they already know
          if sub_id != msg.from do
            AgentCom.Mailbox.enqueue(sub_id, channel_msg)
          end
        end)

        # Also broadcast via PubSub for real-time WebSocket delivery
        Phoenix.PubSub.broadcast(AgentCom.PubSub, "channel:#{channel}",
          {:channel_message, channel, msg})

        {:reply, {:ok, seq}, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    channels = :dets.foldl(fn {_name, info}, acc ->
      [%{
        name: info.name,
        description: info.description,
        subscriber_count: length(info.subscribers),
        created_at: info.created_at
      } | acc]
    end, [], @table)

    {:reply, channels, state}
  end

  def handle_call({:info, channel}, _from, state) do
    case :dets.lookup(@table, channel) do
      [{^channel, info}] -> {:reply, {:ok, info}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:history, channel, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    since = Keyword.get(opts, :since, 0)

    messages =
      :dets.select(@history_table, [
        {{{channel, :"$1"}, :"$2"},
         [{:>, :"$1", since}],
         [:"$2"]}
      ])
      |> Enum.sort_by(& &1.seq)
      |> Enum.take(-limit)

    {:reply, messages, state}
  end

  def handle_call({:subscriptions, agent_id}, _from, state) do
    channels = :dets.foldl(fn {_name, info}, acc ->
      if agent_id in info.subscribers, do: [info.name | acc], else: acc
    end, [], @table)

    {:reply, channels, state}
  end

  @impl true
  def handle_call({:compact, table_atom}, _from, state) when table_atom in [@table, @history_table] do
    path = :dets.info(table_atom, :filename)
    :ok = :dets.close(table_atom)

    case :dets.open_file(table_atom, file: path, type: :set, auto_save: 5_000, repair: :force) do
      {:ok, ^table_atom} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # --- Helpers ---

  @doc "Normalize a channel name — strips #, lowercases, removes special chars."
  def normalize_name(name), do: normalize(name)

  defp normalize(name) do
    name
    |> String.trim_leading("#")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\-_]/, "")
  end

  defp store_history(channel, msg) do
    # Get next seq for this channel
    existing = :dets.select(@history_table, [
      {{{channel, :"$1"}, :_}, [], [:"$1"]}
    ])
    seq = case existing do
      [] -> 1
      seqs -> Enum.max(seqs) + 1
    end

    entry = %{
      seq: seq,
      message: AgentCom.Message.to_json(msg),
      stored_at: System.system_time(:millisecond)
    }
    :dets.insert(@history_table, {{channel, seq}, entry})

    # Trim old history
    trim_history(channel)

    seq
  end

  defp trim_history(channel) do
    keys = :dets.select(@history_table, [
      {{{channel, :"$1"}, :_}, [], [:"$1"]}
    ]) |> Enum.sort()

    overflow = length(keys) - @max_history_per_channel
    if overflow > 0 do
      keys
      |> Enum.take(overflow)
      |> Enum.each(fn seq -> :dets.delete(@history_table, {channel, seq}) end)
    end
  end

  defp dets_path(name) do
    dir = Application.get_env(:agent_com, :channels_path, "priv")
    Path.join(dir, "#{name}.dets")
  end
end
