defmodule AgentCom.WebhookEndpointTest do
  @moduledoc """
  Integration tests for the webhook HTTP endpoint.

  Covers push events, PR merge events, non-active repos, invalid signatures,
  missing signatures, webhook history endpoint, and webhook secret config.

  async: false -- uses GenServers (Config, RepoRegistry, HubFSM).
  """

  use ExUnit.Case, async: false

  alias AgentCom.TestHelpers.DetsHelpers
  alias AgentCom.HubFSM.History

  @test_secret "test-webhook-secret-key-minimum-16"
  @active_repo_url "https://github.com/owner/repo"

  setup do
    tmp_dir = DetsHelpers.full_test_setup()

    # Stop and restart HubFSM with clean history
    try do
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.HubFSM)
    catch
      :exit, _ -> :ok
    end

    History.init_table()
    History.clear()
    {:ok, _pid} = Supervisor.restart_child(AgentCom.Supervisor, AgentCom.HubFSM)

    # Configure webhook secret
    AgentCom.Config.put(:github_webhook_secret, @test_secret)

    # Register an active repo matching "owner/repo" (url_to_id: "owner-repo")
    {:ok, _repo} = AgentCom.RepoRegistry.add_repo(%{url: @active_repo_url, name: "test-repo"})

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

  defp webhook_conn(event_type, payload, secret) do
    body = Jason.encode!(payload)
    hmac = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    Plug.Test.conn(:post, "/api/webhooks/github", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-github-event", event_type)
    |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=#{hmac}")
    |> Plug.Conn.put_req_header("x-github-delivery", "test-delivery-#{System.unique_integer()}")
  end

  defp call_endpoint(conn) do
    AgentCom.Endpoint.call(conn, AgentCom.Endpoint.init([]))
  end

  defp push_payload(repo_full_name) do
    %{
      "ref" => "refs/heads/main",
      "repository" => %{"full_name" => repo_full_name},
      "head_commit" => %{"id" => "abc123def456"}
    }
  end

  defp pr_merge_payload(repo_full_name) do
    %{
      "action" => "closed",
      "pull_request" => %{
        "merged" => true,
        "number" => 42,
        "base" => %{"ref" => "main"}
      },
      "repository" => %{"full_name" => repo_full_name}
    }
  end

  defp pr_open_payload(repo_full_name) do
    %{
      "action" => "opened",
      "pull_request" => %{
        "merged" => false,
        "number" => 43,
        "base" => %{"ref" => "main"}
      },
      "repository" => %{"full_name" => repo_full_name}
    }
  end

  # ---------------------------------------------------------------------------
  # Push event tests
  # ---------------------------------------------------------------------------

  describe "push events" do
    test "push on active repo returns 200 accepted" do
      conn =
        webhook_conn("push", push_payload("owner/repo"), @test_secret)
        |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "accepted"
      assert body["event"] == "push"
    end

    test "push on non-active repo returns 200 ignored" do
      conn =
        webhook_conn("push", push_payload("unknown/other-repo"), @test_secret)
        |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ignored"
      assert body["reason"] == "repo not active"
    end
  end

  # ---------------------------------------------------------------------------
  # PR merge event tests
  # ---------------------------------------------------------------------------

  describe "pull_request events" do
    test "PR merge on active repo returns 200 accepted" do
      conn =
        webhook_conn("pull_request", pr_merge_payload("owner/repo"), @test_secret)
        |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "accepted"
      assert body["event"] == "pull_request_merged"
    end

    test "non-merge PR event returns 200 ignored" do
      conn =
        webhook_conn("pull_request", pr_open_payload("owner/repo"), @test_secret)
        |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ignored"
      assert body["reason"] == "not a merge"
    end
  end

  # ---------------------------------------------------------------------------
  # Signature verification tests
  # ---------------------------------------------------------------------------

  describe "signature verification" do
    test "invalid signature returns 401" do
      payload = push_payload("owner/repo")
      conn =
        webhook_conn("push", payload, "wrong-secret-that-is-long-enough")
        |> call_endpoint()

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_signature"
    end

    test "missing signature header returns 401" do
      payload = push_payload("owner/repo")
      body = Jason.encode!(payload)

      conn =
        Plug.Test.conn(:post, "/api/webhooks/github", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-github-event", "push")
        |> Plug.Conn.put_req_header("x-github-delivery", "test-delivery-nosig")
        |> call_endpoint()

      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # Webhook history endpoint
  # ---------------------------------------------------------------------------

  describe "webhook history endpoint" do
    test "GET /api/webhooks/github/history returns recorded events" do
      # Send a webhook event first to populate history
      webhook_conn("push", push_payload("owner/repo"), @test_secret)
      |> call_endpoint()

      # Now query history
      conn =
        Plug.Test.conn(:get, "/api/webhooks/github/history")
        |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["events"])
      assert length(body["events"]) >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Webhook secret config
  # ---------------------------------------------------------------------------

  describe "webhook secret config" do
    test "PUT /api/config/webhook-secret sets the secret (auth required)" do
      # Generate a token for auth
      {:ok, token} = AgentCom.Auth.generate("test-admin")

      new_secret = "a-new-secret-that-is-long-enough"

      conn =
        Plug.Test.conn(:put, "/api/config/webhook-secret", Jason.encode!(%{"secret" => new_secret}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> call_endpoint()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "updated"

      # Verify the secret was actually stored
      assert AgentCom.Config.get(:github_webhook_secret) == new_secret
    end

    test "PUT /api/config/webhook-secret rejects short secret" do
      {:ok, token} = AgentCom.Auth.generate("test-admin-2")

      conn =
        Plug.Test.conn(:put, "/api/config/webhook-secret", Jason.encode!(%{"secret" => "short"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> call_endpoint()

      assert conn.status == 422
    end
  end
end
