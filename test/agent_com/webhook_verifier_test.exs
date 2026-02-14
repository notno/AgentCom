defmodule AgentCom.WebhookVerifierTest do
  @moduledoc """
  Unit tests for WebhookVerifier HMAC-SHA256 signature verification.

  Covers valid signatures, invalid signatures, missing headers,
  no secret configured, empty body, and malformed header prefix.

  async: false -- reads from Config GenServer.
  """

  use ExUnit.Case, async: false

  alias AgentCom.WebhookVerifier
  alias AgentCom.TestHelpers.DetsHelpers

  @test_secret "test-webhook-secret-key"

  setup do
    tmp_dir = DetsHelpers.full_test_setup()

    # Configure a known webhook secret
    AgentCom.Config.put(:github_webhook_secret, @test_secret)

    on_exit(fn ->
      DetsHelpers.full_test_teardown(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp compute_hmac(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp build_conn(body, opts \\ []) do
    secret = Keyword.get(opts, :secret, @test_secret)
    include_header = Keyword.get(opts, :include_header, true)
    custom_signature = Keyword.get(opts, :custom_signature, nil)

    conn =
      Plug.Test.conn(:post, "/api/webhooks/github", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:raw_body, [body])

    if include_header do
      signature = custom_signature || "sha256=#{compute_hmac(secret, body)}"
      Plug.Conn.put_req_header(conn, "x-hub-signature-256", signature)
    else
      conn
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "verify_signature/1" do
    test "accepts valid HMAC signature" do
      body = ~s({"ref":"refs/heads/main"})
      conn = build_conn(body)

      assert {:ok, _conn} = WebhookVerifier.verify_signature(conn)
    end

    test "rejects invalid HMAC signature" do
      body = ~s({"ref":"refs/heads/main"})
      conn = build_conn(body, custom_signature: "sha256=deadbeef0000000000000000000000000000000000000000000000000000cafe")

      assert {:error, :invalid_signature} = WebhookVerifier.verify_signature(conn)
    end

    test "returns error when signature header is missing" do
      body = ~s({"ref":"refs/heads/main"})
      conn = build_conn(body, include_header: false)

      assert {:error, :missing_signature} = WebhookVerifier.verify_signature(conn)
    end

    test "returns error when no webhook secret is configured" do
      AgentCom.Config.put(:github_webhook_secret, nil)

      body = ~s({"ref":"refs/heads/main"})
      conn = build_conn(body)

      assert {:error, :no_secret_configured} = WebhookVerifier.verify_signature(conn)
    end

    test "handles empty body correctly" do
      body = ""
      conn = build_conn(body)

      assert {:ok, _conn} = WebhookVerifier.verify_signature(conn)
    end

    test "rejects malformed header without sha256= prefix" do
      body = ~s({"ref":"refs/heads/main"})
      hmac = compute_hmac(@test_secret, body)
      conn = build_conn(body, custom_signature: hmac)

      assert {:error, :missing_signature} = WebhookVerifier.verify_signature(conn)
    end
  end
end
