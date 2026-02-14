defmodule AgentCom.ClaudeClient do
  @moduledoc """
  GenServer wrapping the Claude Code CLI for structured LLM calls.

  Provides the hub's three core LLM operations -- goal decomposition,
  completion verification, and improvement identification -- plus a
  `set_hub_state/1` API for HubFSM integration.

  Every invocation checks `CostLedger.check_budget/1` before spawning the
  CLI and records via `CostLedger.record_invocation/2` after completion
  (including errors and timeouts). CLI calls are wrapped in `Task.async`
  with configurable timeouts to prevent GenServer blocking.

  ## Configuration

  | Key                        | Default      | Description                 |
  |----------------------------|--------------|-----------------------------|
  | `:claude_cli_path`         | `"claude"`   | Path to Claude Code binary  |
  | `:claude_model`            | `"sonnet"`   | Model name for `--model`    |
  | `:claude_timeout_ms`       | `120_000`    | Task timeout in milliseconds|

  ## Usage

      AgentCom.ClaudeClient.decompose_goal(goal, context)
      AgentCom.ClaudeClient.verify_completion(goal, results)
      AgentCom.ClaudeClient.identify_improvements(repo, diff)
      AgentCom.ClaudeClient.set_hub_state(:improving)
  """
  use GenServer
  require Logger

  @default_timeout_ms 120_000
  @default_model "sonnet"
  @valid_hub_states [:executing, :improving, :contemplating]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Decompose a goal into executable tasks via Claude Code CLI.

  Returns `{:ok, [map()]}` with a list of task maps, or `{:error, term()}`.
  """
  @spec decompose_goal(map(), map()) :: {:ok, [map()]} | {:error, term()}
  def decompose_goal(goal, context) do
    GenServer.call(
      __MODULE__,
      {:invoke, :decompose, %{goal: goal, context: context}},
      call_timeout()
    )
  end

  @doc """
  Verify whether a goal has been completed based on results.

  Returns `{:ok, map()}` with verification details, or `{:error, term()}`.
  """
  @spec verify_completion(map(), map()) :: {:ok, map()} | {:error, term()}
  def verify_completion(goal, results) do
    GenServer.call(
      __MODULE__,
      {:invoke, :verify, %{goal: goal, results: results}},
      call_timeout()
    )
  end

  @doc """
  Identify potential improvements for a repository given a diff.

  Returns `{:ok, [map()]}` with improvement suggestions, or `{:error, term()}`.
  """
  @spec identify_improvements(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def identify_improvements(repo, diff) do
    GenServer.call(
      __MODULE__,
      {:invoke, :identify_improvements, %{repo: repo, diff: diff}},
      call_timeout()
    )
  end

  @doc """
  Update the hub state used for CostLedger budget checks.

  Called by HubFSM on state transitions. Valid states:
  `:executing`, `:improving`, `:contemplating`.
  """
  @spec set_hub_state(atom()) :: :ok
  def set_hub_state(new_state) when new_state in @valid_hub_states do
    GenServer.call(__MODULE__, {:set_hub_state, new_state})
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.metadata(module: __MODULE__)

    state = %{
      cli_path: Application.get_env(:agent_com, :claude_cli_path, "claude"),
      model: Application.get_env(:agent_com, :claude_model, @default_model),
      timeout_ms: Application.get_env(:agent_com, :claude_timeout_ms, @default_timeout_ms),
      hub_state: :executing
    }

    Logger.info("claude_client_started")
    {:ok, state}
  end

  @impl true
  def handle_call({:invoke, prompt_type, params}, _from, state) do
    case AgentCom.CostLedger.check_budget(state.hub_state) do
      :budget_exhausted ->
        {:reply, {:error, :budget_exhausted}, state}

      :ok ->
        start_time = System.monotonic_time(:millisecond)

        task =
          Task.async(fn ->
            AgentCom.ClaudeClient.Cli.invoke(prompt_type, params, state)
          end)

        result =
          case Task.yield(task, state.timeout_ms) || Task.shutdown(task) do
            {:ok, result} -> result
            {:exit, reason} -> {:error, {:cli_crash, reason}}
            nil -> {:error, :timeout}
          end

        duration_ms = System.monotonic_time(:millisecond) - start_time

        # Always record invocation -- even on errors and timeouts
        AgentCom.CostLedger.record_invocation(state.hub_state, %{
          duration_ms: duration_ms,
          prompt_type: prompt_type
        })

        # Emit telemetry
        :telemetry.execute(
          [:agent_com, :hub, :claude_call],
          %{duration_ms: duration_ms, count: 1},
          %{hub_state: state.hub_state, prompt_type: prompt_type}
        )

        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:set_hub_state, new_state}, _from, state) do
    {:reply, :ok, %{state | hub_state: new_state}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp call_timeout do
    Application.get_env(:agent_com, :claude_timeout_ms, @default_timeout_ms) + 5_000
  end
end
