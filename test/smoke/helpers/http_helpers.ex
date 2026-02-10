defmodule Smoke.Http do
  @moduledoc """
  HTTP helpers for smoke tests.

  Uses :httpc (built into Erlang/OTP) to submit tasks and query the
  task queue via the AgentCom HTTP API. All functions take an optional
  `hub_url` defaulting to `"http://localhost:4000"`.
  """

  @default_hub_url "http://localhost:4000"

  @doc """
  Submit a task via POST /api/tasks.

  Returns `{:ok, decoded_body}` or `{:error, reason}`.

  ## Options
    - `:priority` - Task priority (default "normal")
    - `:needed_capabilities` - List of required capabilities (default [])
    - `:metadata` - Task metadata map (default %{})
    - `:hub_url` - Override hub URL
  """
  def submit_task(description, token, opts \\ []) do
    hub_url = Keyword.get(opts, :hub_url, @default_hub_url)

    body = Jason.encode!(%{
      "description" => description,
      "priority" => Keyword.get(opts, :priority, "normal"),
      "needed_capabilities" => Keyword.get(opts, :needed_capabilities, []),
      "metadata" => Keyword.get(opts, :metadata, %{})
    })

    post_json("/api/tasks", body, token, hub_url)
  end

  @doc """
  Get a task by ID via GET /api/tasks/:task_id.

  Returns `{:ok, decoded_body}` or `{:error, reason}`.
  """
  def get_task(task_id, token, opts \\ []) do
    hub_url = Keyword.get(opts, :hub_url, @default_hub_url)
    get_json("/api/tasks/#{task_id}", token, hub_url)
  end

  @doc """
  List tasks via GET /api/tasks.

  Returns `{:ok, decoded_body}` or `{:error, reason}`.

  ## Options
    - `:status` - Filter by status (e.g., "queued", "assigned", "completed")
    - `:hub_url` - Override hub URL
  """
  def list_tasks(token, opts \\ []) do
    hub_url = Keyword.get(opts, :hub_url, @default_hub_url)

    query =
      opts
      |> Keyword.take([:status, :priority, :assigned_to])
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
      |> Enum.join("&")

    path = if query == "", do: "/api/tasks", else: "/api/tasks?#{query}"
    get_json(path, token, hub_url)
  end

  @doc """
  Get queue statistics via GET /api/tasks/stats.

  Returns `{:ok, decoded_body}` or `{:error, reason}`.
  """
  def get_stats(token, opts \\ []) do
    hub_url = Keyword.get(opts, :hub_url, @default_hub_url)
    get_json("/api/tasks/stats", token, hub_url)
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp post_json(path, body, token, hub_url) do
    url = String.to_charlist("#{hub_url}#{path}")
    auth_header = String.to_charlist("Bearer #{token}")

    result = :httpc.request(
      :post,
      {url,
       [{~c"authorization", auth_header},
        {~c"content-type", ~c"application/json"}],
       ~c"application/json",
       String.to_charlist(body)},
      [],
      []
    )

    parse_response(result)
  end

  defp get_json(path, token, hub_url) do
    url = String.to_charlist("#{hub_url}#{path}")
    auth_header = String.to_charlist("Bearer #{token}")

    result = :httpc.request(
      :get,
      {url,
       [{~c"authorization", auth_header}]},
      [],
      []
    )

    parse_response(result)
  end

  defp parse_response({:ok, {{_version, status_code, _reason}, _headers, body}}) do
    body_str = to_string(body)

    case Jason.decode(body_str) do
      {:ok, decoded} ->
        if status_code >= 200 and status_code < 300 do
          {:ok, decoded}
        else
          {:error, {:http_error, status_code, decoded}}
        end

      {:error, _} ->
        {:error, {:invalid_json, body_str}}
    end
  end

  defp parse_response({:error, reason}) do
    {:error, {:request_failed, reason}}
  end
end
