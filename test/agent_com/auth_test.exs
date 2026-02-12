defmodule AgentCom.AuthTest do
  use ExUnit.Case, async: false

  alias AgentCom.Auth
  alias AgentCom.TestHelpers.DetsHelpers

  setup do
    tmp_dir = DetsHelpers.full_test_setup()
    # Stop Scheduler to prevent interference
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.Scheduler)
    on_exit(fn ->
      Supervisor.restart_child(AgentCom.Supervisor, AgentCom.Scheduler)
      DetsHelpers.full_test_teardown(tmp_dir)
    end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "generate/1" do
    test "returns {:ok, token_string} where token is a hex string" do
      {:ok, token} = Auth.generate("agent-alpha")
      assert is_binary(token)
      assert String.length(token) == 64
      assert token =~ ~r/^[a-f0-9]{64}$/
    end

    test "for same agent_id generates a new distinct token (both remain valid)" do
      {:ok, token1} = Auth.generate("agent-dup")
      {:ok, token2} = Auth.generate("agent-dup")
      refute token1 == token2
      # Auth.generate adds tokens (does not revoke old ones)
      # Both tokens should verify to the same agent
      assert {:ok, "agent-dup"} == Auth.verify(token1)
      assert {:ok, "agent-dup"} == Auth.verify(token2)
    end
  end

  describe "verify/1" do
    test "with valid token returns {:ok, agent_id}" do
      {:ok, token} = Auth.generate("agent-verify")
      assert {:ok, "agent-verify"} == Auth.verify(token)
    end

    test "with invalid token returns :error" do
      assert :error == Auth.verify("nonexistent_token_abcdef1234567890")
    end
  end

  describe "revoke/1" do
    test "removes the token, verify after revoke returns :error" do
      {:ok, token} = Auth.generate("agent-revoke")
      assert {:ok, "agent-revoke"} == Auth.verify(token)
      :ok = Auth.revoke("agent-revoke")
      assert :error == Auth.verify(token)
    end
  end

  describe "multiple agents" do
    test "can have separate tokens simultaneously" do
      {:ok, token_a} = Auth.generate("agent-a")
      {:ok, token_b} = Auth.generate("agent-b")
      {:ok, token_c} = Auth.generate("agent-c")

      assert {:ok, "agent-a"} == Auth.verify(token_a)
      assert {:ok, "agent-b"} == Auth.verify(token_b)
      assert {:ok, "agent-c"} == Auth.verify(token_c)

      # Revoking one doesn't affect others
      Auth.revoke("agent-b")
      assert {:ok, "agent-a"} == Auth.verify(token_a)
      assert :error == Auth.verify(token_b)
      assert {:ok, "agent-c"} == Auth.verify(token_c)
    end
  end

  describe "persistence across restart" do
    test "token survives Auth GenServer restart" do
      {:ok, token} = Auth.generate("agent-persist")
      assert {:ok, "agent-persist"} == Auth.verify(token)

      # Terminate and restart Auth GenServer
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.Auth)
      {:ok, _pid} = Supervisor.restart_child(AgentCom.Supervisor, AgentCom.Auth)

      # Token should still verify after restart (JSON file persistence)
      assert {:ok, "agent-persist"} == Auth.verify(token)
    end
  end

  describe "list/0" do
    test "returns all registered agent_ids with token prefixes" do
      {:ok, _} = Auth.generate("agent-list-1")
      {:ok, _} = Auth.generate("agent-list-2")

      entries = Auth.list()
      assert is_list(entries)

      agent_ids = Enum.map(entries, & &1.agent_id)
      assert "agent-list-1" in agent_ids
      assert "agent-list-2" in agent_ids

      # Each entry has a truncated token prefix
      Enum.each(entries, fn entry ->
        assert Map.has_key?(entry, :token_prefix)
        assert String.ends_with?(entry.token_prefix, "...")
      end)
    end
  end
end
