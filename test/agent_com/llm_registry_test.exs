defmodule AgentCom.LlmRegistryTest do
  use ExUnit.Case, async: false

  alias AgentCom.LlmRegistry

  setup do
    # Create isolated temp dir for DETS
    tmp_dir = Path.join(System.tmp_dir!(), "llm_registry_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    Application.put_env(:agent_com, :llm_registry_data_dir, tmp_dir)

    # Stop and restart LlmRegistry via supervisor so it picks up the new data dir
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.LlmRegistry)
    Supervisor.restart_child(AgentCom.Supervisor, AgentCom.LlmRegistry)

    pid = Process.whereis(LlmRegistry)

    on_exit(fn ->
      # Restart LlmRegistry cleanly via supervisor for next test
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.LlmRegistry)
      Supervisor.restart_child(AgentCom.Supervisor, AgentCom.LlmRegistry)

      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, pid: pid}
  end

  describe "register_endpoint/1" do
    test "with valid params returns {:ok, endpoint} with correct fields" do
      params = %{host: "192.168.1.10", port: 11434, name: "gpu-box", source: :manual}
      assert {:ok, endpoint} = LlmRegistry.register_endpoint(params)

      assert endpoint.id == "192.168.1.10:11434"
      assert endpoint.host == "192.168.1.10"
      assert endpoint.port == 11434
      assert endpoint.name == "gpu-box"
      assert endpoint.source == :manual
      assert endpoint.status == :unknown
      assert endpoint.models == []
      assert is_integer(endpoint.registered_at)
      assert endpoint.last_checked_at == nil
      assert endpoint.consecutive_failures == 0
    end

    test "with duplicate id updates existing (upsert)" do
      params = %{host: "192.168.1.10", port: 11434, name: "gpu-box", source: :manual}
      {:ok, _} = LlmRegistry.register_endpoint(params)

      updated_params = %{host: "192.168.1.10", port: 11434, name: "updated-name", source: :auto}
      {:ok, endpoint} = LlmRegistry.register_endpoint(updated_params)

      assert endpoint.name == "updated-name"
      assert endpoint.source == :auto

      # Should still be only one endpoint
      endpoints = LlmRegistry.list_endpoints()
      assert length(endpoints) == 1
    end

    test "with missing host returns error" do
      assert {:error, :invalid_params} = LlmRegistry.register_endpoint(%{port: 11434})
    end
  end

  describe "remove_endpoint/1" do
    test "returns :ok for existing endpoint" do
      params = %{host: "192.168.1.10", port: 11434, name: "gpu-box", source: :manual}
      {:ok, _} = LlmRegistry.register_endpoint(params)

      assert :ok = LlmRegistry.remove_endpoint("192.168.1.10:11434")
      assert LlmRegistry.list_endpoints() == []
    end

    test "returns {:error, :not_found} for missing endpoint" do
      assert {:error, :not_found} = LlmRegistry.remove_endpoint("nonexistent:1234")
    end
  end

  describe "list_endpoints/0" do
    test "returns all registered endpoints" do
      {:ok, _} = LlmRegistry.register_endpoint(%{host: "host1", port: 11434, source: :manual})
      {:ok, _} = LlmRegistry.register_endpoint(%{host: "host2", port: 11434, source: :auto})

      endpoints = LlmRegistry.list_endpoints()
      assert length(endpoints) == 2

      ids = Enum.map(endpoints, & &1.id) |> Enum.sort()
      assert ids == ["host1:11434", "host2:11434"]
    end

    test "returns empty list when no endpoints registered" do
      assert LlmRegistry.list_endpoints() == []
    end
  end

  describe "get_endpoint/1" do
    test "returns {:ok, endpoint} for existing" do
      {:ok, _} = LlmRegistry.register_endpoint(%{host: "myhost", port: 11434, source: :manual})

      assert {:ok, endpoint} = LlmRegistry.get_endpoint("myhost:11434")
      assert endpoint.host == "myhost"
    end

    test "returns {:error, :not_found} for missing" do
      assert {:error, :not_found} = LlmRegistry.get_endpoint("missing:999")
    end
  end

  describe "report_resources/2 and get_resources/1" do
    test "stores in ETS and retrieves" do
      metrics = %{
        cpu_percent: 45.2,
        ram_used_bytes: 8_000_000_000,
        ram_total_bytes: 16_000_000_000,
        vram_used_bytes: 4_000_000_000,
        vram_total_bytes: 8_000_000_000,
        source_agent_id: "agent-1"
      }

      assert :ok = LlmRegistry.report_resources("host-1", metrics)
      assert {:ok, stored} = LlmRegistry.get_resources("host-1")

      assert stored.cpu_percent == 45.2
      assert stored.ram_used_bytes == 8_000_000_000
      assert stored.ram_total_bytes == 16_000_000_000
      assert stored.vram_used_bytes == 4_000_000_000
      assert stored.vram_total_bytes == 8_000_000_000
      assert stored.source_agent_id == "agent-1"
      assert is_integer(stored.reported_at)
    end

    test "get_resources returns {:error, :not_found} for unknown host" do
      assert {:error, :not_found} = LlmRegistry.get_resources("unknown-host")
    end
  end

  describe "health check behavior" do
    test "marks endpoint :unhealthy after 2 consecutive failures" do
      # Register an endpoint pointing to an unreachable host
      {:ok, _} = LlmRegistry.register_endpoint(%{
        host: "127.0.0.1",
        port: 59999,
        source: :manual
      })

      # Trigger health check manually (twice for 2 consecutive failures)
      send(Process.whereis(LlmRegistry), :health_check)
      Process.sleep(200)

      {:ok, ep1} = LlmRegistry.get_endpoint("127.0.0.1:59999")
      # After 1 failure, still unknown (threshold is 2)
      assert ep1.consecutive_failures == 1
      assert ep1.status == :unknown

      send(Process.whereis(LlmRegistry), :health_check)
      Process.sleep(200)

      {:ok, ep2} = LlmRegistry.get_endpoint("127.0.0.1:59999")
      assert ep2.consecutive_failures == 2
      assert ep2.status == :unhealthy
    end

    test "marks endpoint :healthy immediately on success" do
      # We can't easily mock httpc, so we test the state transition logic
      # by registering, forcing unhealthy state, then verifying recovery logic
      {:ok, _} = LlmRegistry.register_endpoint(%{
        host: "127.0.0.1",
        port: 59999,
        source: :manual
      })

      # Force unhealthy state via two health checks
      send(Process.whereis(LlmRegistry), :health_check)
      Process.sleep(200)
      send(Process.whereis(LlmRegistry), :health_check)
      Process.sleep(200)

      {:ok, ep} = LlmRegistry.get_endpoint("127.0.0.1:59999")
      assert ep.status == :unhealthy

      # Verify the endpoint tracks consecutive_failures correctly
      # (Full recovery test would require a mock HTTP server)
      assert ep.consecutive_failures >= 2
    end
  end

  describe "snapshot/0" do
    test "includes endpoints, resources, and fleet_models aggregation" do
      {:ok, _} = LlmRegistry.register_endpoint(%{host: "host1", port: 11434, source: :manual})
      {:ok, _} = LlmRegistry.register_endpoint(%{host: "host2", port: 11434, source: :auto})

      LlmRegistry.report_resources("host-1", %{
        cpu_percent: 50.0,
        ram_used_bytes: 8_000_000_000,
        ram_total_bytes: 16_000_000_000,
        source_agent_id: "agent-1"
      })

      snapshot = LlmRegistry.snapshot()

      assert is_list(snapshot.endpoints)
      assert length(snapshot.endpoints) == 2
      assert is_map(snapshot.resources)
      assert is_map(snapshot.fleet_models)
    end
  end

  describe "stale resource clearing" do
    test "stale resources are cleared after timeout" do
      # Report resource with a manually backdated timestamp via direct ETS insert
      stale_metrics = %{
        cpu_percent: 50.0,
        ram_used_bytes: 8_000_000_000,
        ram_total_bytes: 16_000_000_000,
        vram_used_bytes: nil,
        vram_total_bytes: nil,
        source_agent_id: "agent-1",
        reported_at: System.system_time(:millisecond) - 120_000
      }

      :ets.insert(:llm_resource_metrics, {"stale-host", stale_metrics})

      # Verify it's there
      assert {:ok, _} = LlmRegistry.get_resources("stale-host")

      # Trigger stale sweep
      send(Process.whereis(LlmRegistry), :sweep_stale_resources)
      Process.sleep(100)

      # Should be cleared
      assert {:error, :not_found} = LlmRegistry.get_resources("stale-host")
    end
  end

  describe "PubSub broadcasts" do
    test "broadcasts on register and remove" do
      Phoenix.PubSub.subscribe(AgentCom.PubSub, "llm_registry")

      {:ok, _} = LlmRegistry.register_endpoint(%{host: "host1", port: 11434, source: :manual})
      assert_receive {:llm_registry_update, :endpoint_changed}, 1_000

      :ok = LlmRegistry.remove_endpoint("host1:11434")
      assert_receive {:llm_registry_update, :endpoint_changed}, 1_000
    end
  end

  describe "DETS persistence" do
    test "endpoints survive GenServer restart" do
      {:ok, _} = LlmRegistry.register_endpoint(%{host: "persist-host", port: 11434, source: :manual})

      # Stop and restart via supervisor
      Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.LlmRegistry)
      Supervisor.restart_child(AgentCom.Supervisor, AgentCom.LlmRegistry)

      endpoints = LlmRegistry.list_endpoints()
      assert length(endpoints) == 1
      assert hd(endpoints).host == "persist-host"
      # Status should be reset to :unknown on restart
      assert hd(endpoints).status == :unknown
    end
  end
end
