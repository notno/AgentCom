defmodule Smoke.Assertions do
  @moduledoc """
  Polling assertion helpers for smoke tests.

  Provides timeout-based assertions that poll TaskQueue for expected
  state changes, avoiding fragile Process.sleep-based synchronization.
  """

  @doc """
  Wait for all task_ids to reach `:completed` status.

  Polls TaskQueue.get for each task_id until all are completed.
  Raises a descriptive error on timeout showing which tasks are
  incomplete and their current status.

  ## Options
    - `:timeout` - Maximum wait time in ms (default 30_000)
    - `:interval` - Poll interval in ms (default 200)
  """
  def assert_all_completed(task_ids, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    interval = Keyword.get(opts, :interval, 200)
    deadline = System.system_time(:millisecond) + timeout

    do_poll_all(task_ids, interval, deadline)
  end

  @doc """
  Wait for a single task_id to reach `:completed` status.

  ## Options
    - `:timeout` - Maximum wait time in ms (default 30_000)
    - `:interval` - Poll interval in ms (default 200)
  """
  def assert_task_completed(task_id, opts \\ []) do
    assert_all_completed([task_id], opts)
  end

  @doc """
  Generic polling helper. Calls `fun.()` repeatedly until it returns
  a truthy value.

  ## Options
    - `:timeout` - Maximum wait time in ms (default 10_000)
    - `:interval` - Poll interval in ms (default 100)
  """
  def wait_for(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    interval = Keyword.get(opts, :interval, 100)
    deadline = System.system_time(:millisecond) + timeout

    do_poll_fun(fun, interval, deadline)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_poll_all(task_ids, interval, deadline) do
    now = System.system_time(:millisecond)

    if now > deadline do
      incomplete =
        task_ids
        |> Enum.map(fn id ->
          case AgentCom.TaskQueue.get(id) do
            {:ok, task} -> {id, task.status}
            {:error, :not_found} -> {id, :not_found}
          end
        end)
        |> Enum.reject(fn {_id, status} -> status == :completed end)

      status_summary =
        Enum.map(incomplete, fn {id, status} -> "  #{id}: #{status}" end)
        |> Enum.join("\n")

      raise """
      Timeout waiting for tasks to complete.
      #{length(incomplete)} of #{length(task_ids)} tasks not completed:
      #{status_summary}
      """
    end

    remaining =
      Enum.filter(task_ids, fn id ->
        case AgentCom.TaskQueue.get(id) do
          {:ok, %{status: :completed}} -> false
          _ -> true
        end
      end)

    if remaining == [] do
      :ok
    else
      Process.sleep(interval)
      do_poll_all(remaining, interval, deadline)
    end
  end

  defp do_poll_fun(fun, interval, deadline) do
    now = System.system_time(:millisecond)

    if now > deadline do
      raise "Timeout waiting for condition to be true"
    end

    if fun.() do
      :ok
    else
      Process.sleep(interval)
      do_poll_fun(fun, interval, deadline)
    end
  end
end
