defmodule AgentCom.ClaudeClientTest do
  @moduledoc """
  Integration tests for ClaudeClient GenServer.

  Covers: budget gating via CostLedger, set_hub_state/1 state changes,
  GenServer start_link, and telemetry emission.

  Uses DetsHelpers for DETS isolation. async: false due to shared GenServer state.
  The cli_path is overridden to a non-existent binary so System.cmd fails predictably.
  """

  use ExUnit.Case, async: false

  alias AgentCom.ClaudeClient
  alias AgentCom.CostLedger

  setup do
    tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()

    # Override cli_path to a non-existent binary so CLI calls fail fast
    # without actually invoking the Claude CLI
    Application.put_env(:agent_com, :claude_cli_path, "__nonexistent_claude_binary__")
    Application.put_env(:agent_com, :claude_timeout_ms, 5_000)

    # Restart ClaudeClient so it picks up the new config
    try do
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.ClaudeClient)
    catch
      :exit, _ -> :ok
    end

    try do
      Supervisor.restart_child(AgentCom.Supervisor, AgentCom.ClaudeClient)
    catch
      :exit, _ -> :ok
    end

    on_exit(fn ->
      # Restore defaults
      Application.delete_env(:agent_com, :claude_cli_path)
      Application.delete_env(:agent_com, :claude_timeout_ms)
      AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  describe "GenServer lifecycle" do
    test "starts via supervision tree and accepts calls" do
      # If we got here, setup already restarted ClaudeClient successfully
      assert Process.whereis(AgentCom.ClaudeClient) != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Budget gating
  # ---------------------------------------------------------------------------

  describe "budget gating" do
    test "returns {:error, :budget_exhausted} when budget is exhausted" do
      # Exhaust the budget by recording many invocations
      # Default executing limit is 20/hr
      for _ <- 1..20 do
        CostLedger.record_invocation(:executing, %{duration_ms: 100})
      end

      assert :budget_exhausted = CostLedger.check_budget(:executing)

      # Now ClaudeClient should refuse to invoke
      result = ClaudeClient.decompose_goal(%{title: "test"}, %{})
      assert {:error, :budget_exhausted} = result
    end

    test "budget check happens before CLI invocation" do
      # Exhaust budget first
      for _ <- 1..20 do
        CostLedger.record_invocation(:executing, %{duration_ms: 100})
      end

      # All three API functions should return budget_exhausted without CLI call
      assert {:error, :budget_exhausted} = ClaudeClient.decompose_goal(%{title: "t"}, %{})
      assert {:error, :budget_exhausted} = ClaudeClient.verify_completion(%{title: "t"}, %{})
      assert {:error, :budget_exhausted} = ClaudeClient.identify_improvements("repo", "diff")
    end
  end

  # ---------------------------------------------------------------------------
  # set_hub_state/1
  # ---------------------------------------------------------------------------

  describe "set_hub_state/1" do
    test "changes the state used for budget checks" do
      # Default state is :executing. Set custom budget for :improving
      AgentCom.Config.put(:hub_invocation_budgets, %{
        executing: %{max_per_hour: 100, max_per_day: 200},
        improving: %{max_per_hour: 1, max_per_day: 1},
        contemplating: %{max_per_hour: 5, max_per_day: 15}
      })

      # With :executing state (default), budget should be fine
      assert :ok = CostLedger.check_budget(:executing)

      # Switch to :improving
      assert :ok = ClaudeClient.set_hub_state(:improving)

      # Record one invocation under :improving
      CostLedger.record_invocation(:improving, %{duration_ms: 100})

      # Now :improving budget should be exhausted
      assert :budget_exhausted = CostLedger.check_budget(:improving)

      # ClaudeClient should use :improving for its budget check now
      result = ClaudeClient.decompose_goal(%{title: "test"}, %{})
      assert {:error, :budget_exhausted} = result
    end

    test "accepts all valid hub states" do
      assert :ok = ClaudeClient.set_hub_state(:executing)
      assert :ok = ClaudeClient.set_hub_state(:improving)
      assert :ok = ClaudeClient.set_hub_state(:contemplating)
    end

    test "rejects invalid hub states" do
      assert_raise FunctionClauseError, fn ->
        ClaudeClient.set_hub_state(:invalid_state)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # CLI error handling (non-budget path)
  # ---------------------------------------------------------------------------

  describe "CLI invocation with non-existent binary" do
    test "returns error when CLI binary does not exist" do
      # With budget available and a non-existent binary, System.cmd raises :enoent
      # which Cli.invoke rescues and wraps as {:error, {:cli_error, :enoent}}
      result = ClaudeClient.decompose_goal(%{title: "test goal"}, %{repo: "test"})

      assert {:error, {:cli_error, :enoent}} = result
    end
  end
end
