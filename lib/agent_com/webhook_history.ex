defmodule AgentCom.WebhookHistory do
  @moduledoc """
  ETS-backed webhook event history for debugging.

  Stores the last 100 webhook events with timestamp, event type, repo,
  action taken, and delivery ID. Uses the same ETS pattern as HubFSM.History.
  """

  @table :webhook_history
  @max_entries 100

  def init_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table, :public, :ordered_set, {:read_concurrency, true}
        ])
        :ok
      _ref -> :ok
    end
  end

  def record(event) do
    timestamp = System.system_time(:millisecond)
    entry = Map.merge(event, %{timestamp: timestamp})
    :ets.insert(@table, {{-timestamp, :erlang.unique_integer()}, entry})
    trim()
    :ok
  end

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    @table
    |> :ets.tab2list()
    |> Enum.sort()
    |> Enum.take(limit)
    |> Enum.map(fn {_key, entry} -> entry end)
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp trim do
    size = :ets.info(@table, :size)
    if size > @max_entries do
      to_delete = size - @max_entries
      @table
      |> :ets.tab2list()
      |> Enum.sort()
      |> Enum.reverse()
      |> Enum.take(to_delete)
      |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)
    end
  end
end
