defmodule AgentCom.Threads do
  @moduledoc """
  Indexes reply_to chains for conversation threading.

  Maintains two DETS-backed indexes:
  - `:thread_messages` — {message_id, message_json} for all routed messages
  - `:thread_replies` — {parent_id, [child_id, ...]} mapping parent → direct replies

  Provides thread retrieval: given any message id, walk up to the root
  then collect the full tree in chronological order.
  """
  use GenServer
  require Logger

  @messages_table :thread_messages
  @replies_table :thread_replies

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Index a message after it's been routed."
  def index(%AgentCom.Message{} = msg) do
    GenServer.cast(__MODULE__, {:index, msg})
  end

  @doc "Get the full thread containing the given message id, in chronological order."
  def get_thread(message_id) do
    GenServer.call(__MODULE__, {:get_thread, message_id})
  end

  @doc "Get direct replies to a message id."
  def get_replies(message_id) do
    GenServer.call(__MODULE__, {:get_replies, message_id})
  end

  @doc "Get the root message id of the thread containing the given message."
  def get_root(message_id) do
    GenServer.call(__MODULE__, {:get_root, message_id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    msg_path = dets_path("thread_messages")
    rep_path = dets_path("thread_replies")
    {:ok, @messages_table} = :dets.open_file(@messages_table, file: msg_path, type: :set)
    {:ok, @replies_table} = :dets.open_file(@replies_table, file: rep_path, type: :set)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:index, msg}, state) do
    msg_json = AgentCom.Message.to_json(msg)

    case :dets.insert(@messages_table, {msg.id, msg_json}) do
      :ok ->
        if msg.reply_to do
          children =
            case :dets.lookup(@replies_table, msg.reply_to) do
              [{_, existing}] -> existing
              [] -> []
              {:error, reason} ->
                Logger.error("DETS corruption detected in #{@replies_table}: #{inspect(reason)}")
                GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @replies_table, reason})
                []
            end

          unless msg.id in children do
            case :dets.insert(@replies_table, {msg.reply_to, children ++ [msg.id]}) do
              :ok -> :ok
              {:error, reason} ->
                Logger.error("DETS corruption detected in #{@replies_table}: #{inspect(reason)}")
                GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @replies_table, reason})
            end
          end
        end

        :dets.sync(@messages_table)
        :dets.sync(@replies_table)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("DETS corruption detected in #{@messages_table}: #{inspect(reason)}")
        GenServer.cast(AgentCom.DetsBackup, {:corruption_detected, @messages_table, reason})
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:get_thread, message_id}, _from, state) do
    root = walk_to_root(message_id)
    thread = collect_tree(root) |> Enum.sort_by(& &1["timestamp"])
    {:reply, {:ok, %{root: root, messages: thread, count: length(thread)}}, state}
  end

  @impl true
  def handle_call({:get_replies, message_id}, _from, state) do
    children = get_child_ids(message_id)

    replies =
      children
      |> Enum.map(&lookup_message/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1["timestamp"])

    {:reply, {:ok, replies}, state}
  end

  @impl true
  def handle_call({:get_root, message_id}, _from, state) do
    {:reply, {:ok, walk_to_root(message_id)}, state}
  end

  @impl true
  def handle_call({:compact, table_atom}, _from, state) when table_atom in [@messages_table, @replies_table] do
    path = :dets.info(table_atom, :filename)
    :ok = :dets.close(table_atom)

    case :dets.open_file(table_atom, file: path, type: :set, repair: :force) do
      {:ok, ^table_atom} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@messages_table)
    :dets.close(@replies_table)
  end

  # Private helpers

  defp walk_to_root(message_id) do
    case lookup_message(message_id) do
      %{"reply_to" => parent} when is_binary(parent) -> walk_to_root(parent)
      _ -> message_id
    end
  end

  defp collect_tree(message_id) do
    msg = lookup_message(message_id)
    children = get_child_ids(message_id)
    subtrees = Enum.flat_map(children, &collect_tree/1)
    if msg, do: [msg | subtrees], else: subtrees
  end

  defp get_child_ids(message_id) do
    case :dets.lookup(@replies_table, message_id) do
      [{_, children}] -> children
      [] -> []
    end
  end

  defp lookup_message(message_id) do
    case :dets.lookup(@messages_table, message_id) do
      [{_, msg_json}] -> msg_json
      [] -> nil
    end
  end

  defp dets_path(name) do
    dir = Application.get_env(:agent_com, :threads_data_dir,
      Path.join([System.get_env("HOME") || ".", ".agentcom", "data"]))
    File.mkdir_p!(dir)
    Path.join(dir, name <> ".dets") |> String.to_charlist()
  end
end
