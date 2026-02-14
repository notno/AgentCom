defmodule AgentCom.HubEndpointTest do
  @moduledoc """
  Integration tests for Hub FSM HTTP endpoints.

  Covers GET /api/hub/state, POST pause/resume/stop/start,
  GET history, and GET healing-history. Uses Plug.Test for
  request simulation.

  async: false -- uses named GenServers.
  """

  use ExUnit.Case, async: false

  alias AgentCom.HubFSM
  alias AgentCom.HubFSM.History
  alias AgentCom.TestHelpers.DetsHelpers

  setup do
    tmp_dir = DetsHelpers.full_test_setup()

    try do
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.HubFSM)
    catch
      :exit, _ -> :ok
    end

    History.init_table()
    History.clear()
    AgentCom.HubFSM.HealingHistory.init_table()
    AgentCom.HubFSM.HealingHistory.clear()

    {:ok, _pid} = Supervisor.restart_child(AgentCom.Supervisor, AgentCom.HubFSM)

    on_exit(fn ->
      try do
        Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.HubFSM)
      catch
        :exit, _ -> :ok
      end

      DetsHelpers.full_test_teardown(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp call_endpoint(conn) do
    AgentCom.Endpoint.call(conn, AgentCom.Endpoint.init([]))
  end

  defp auth_conn(method, path, body \\ nil) do
    {:ok, token} = AgentCom.Auth.generate("test-hub-admin")

    conn =
      if body do
        Plug.Test.conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        Plug.Test.conn(method, path)
      end

    conn |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end

  defp noauth_conn(method, path) do
    Plug.Test.conn(method, path)
  end

  # ---------------------------------------------------------------------------
  # GET /api/hub/state
  # ---------------------------------------------------------------------------

  describe "GET /api/hub/state" do
    test "returns current FSM state (no auth required)" do
      conn = noauth_conn(:get, "/api/hub/state") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["fsm_state"] == "resting"
      assert body["paused"] == false
      assert is_integer(body["cycle_count"])
      assert is_integer(body["transition_count"])
      assert is_integer(body["last_state_change"])
    end

    test "returns correct state after force_transition" do
      :ok = HubFSM.force_transition(:executing, "endpoint test")

      conn = noauth_conn(:get, "/api/hub/state") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["fsm_state"] == "executing"
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/hub/pause
  # ---------------------------------------------------------------------------

  describe "POST /api/hub/pause" do
    test "with auth pauses FSM and returns 200" do
      conn = auth_conn(:post, "/api/hub/pause") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "paused"
      assert HubFSM.get_state().paused == true
    end

    test "without auth returns 401" do
      conn = noauth_conn(:post, "/api/hub/pause") |> call_endpoint()

      assert conn.status == 401
    end

    test "when already paused returns already_paused" do
      HubFSM.pause()

      conn = auth_conn(:post, "/api/hub/pause") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "already_paused"
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/hub/resume
  # ---------------------------------------------------------------------------

  describe "POST /api/hub/resume" do
    test "with auth resumes FSM and returns 200" do
      HubFSM.pause()

      conn = auth_conn(:post, "/api/hub/resume") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "resumed"
      assert HubFSM.get_state().paused == false
    end

    test "when not paused returns not_paused" do
      conn = auth_conn(:post, "/api/hub/resume") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "not_paused"
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/hub/stop and /api/hub/start
  # ---------------------------------------------------------------------------

  describe "POST /api/hub/stop and /api/hub/start" do
    test "stop pauses and transitions to resting" do
      :ok = HubFSM.force_transition(:executing, "setup for stop")

      conn = auth_conn(:post, "/api/hub/stop") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "stopped"

      state = HubFSM.get_state()
      assert state.paused == true
      assert state.fsm_state == :resting
    end

    test "start resumes from stopped state" do
      HubFSM.stop_fsm()

      conn = auth_conn(:post, "/api/hub/start") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "started"
      assert HubFSM.get_state().paused == false
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/hub/history
  # ---------------------------------------------------------------------------

  describe "GET /api/hub/history" do
    test "returns transition history array" do
      conn = noauth_conn(:get, "/api/hub/history") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["transitions"])
      # At least the initial nil->resting entry
      assert length(body["transitions"]) >= 1
    end

    test "respects limit parameter" do
      # Force a few transitions to ensure we have more than 2
      Process.sleep(5)
      :ok = HubFSM.force_transition(:executing, "history limit 1")
      Process.sleep(5)
      :ok = HubFSM.force_transition(:resting, "history limit 2")
      Process.sleep(5)
      :ok = HubFSM.force_transition(:executing, "history limit 3")

      conn = noauth_conn(:get, "/api/hub/history?limit=2") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["transitions"]) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/hub/healing-history
  # ---------------------------------------------------------------------------

  describe "GET /api/hub/healing-history" do
    test "returns healing history (empty initially)" do
      conn = noauth_conn(:get, "/api/hub/healing-history") |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["history"])
      assert body["count"] == 0
    end
  end
end
