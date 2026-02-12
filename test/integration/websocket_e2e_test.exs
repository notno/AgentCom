defmodule AgentCom.Integration.WebsocketE2eTest do
  @moduledoc """
  Full WebSocket end-to-end integration test.

  This is the ONE realistic E2E test per the locked decision. It connects
  via real WebSocket to the Bandit HTTP server on port 4002 (test port),
  identifies as an agent, receives a task_assign message via WebSocket,
  sends task_accepted and task_complete, and verifies the task reaches
  :completed status in TaskQueue.

  Exercises: real TCP connection -> HTTP upgrade -> WebSocket frames ->
  JSON protocol -> Scheduler assignment -> task lifecycle via WS protocol.
  """

  use ExUnit.Case, async: false

  @tag :e2e

  setup do
    tmp_dir = AgentCom.TestHelpers.DetsHelpers.full_test_setup()

    on_exit(fn ->
      AgentCom.TestHelpers.DetsHelpers.full_test_teardown(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "full WebSocket lifecycle: connect -> identify -> receive task -> complete" do
    agent_id = "ws-e2e-test-agent"

    # 1. Generate auth token for the test agent
    {:ok, token} = AgentCom.Auth.generate(agent_id)

    # 2. Start WsClient and connect to real Bandit server on port 4002
    {:ok, ws} = AgentCom.TestHelpers.WsClient.start_link(url: "ws://localhost:4002/ws")

    # 3. Connect and identify via WebSocket
    :ok = AgentCom.TestHelpers.WsClient.connect_and_identify(ws, agent_id, token)

    # 4. Wait for identification to complete
    :ok = AgentCom.TestHelpers.WsClient.wait_for_identified(ws, 10_000)

    # 5. Verify agent appears in Presence
    presence = AgentCom.Presence.get(agent_id)
    assert presence != nil
    assert presence.agent_id == agent_id

    # 6. Submit a task via TaskQueue (not WebSocket -- we're testing receiving via WS)
    {:ok, task} = AgentCom.TaskQueue.submit(%{
      description: "ws e2e test task",
      needed_capabilities: [],
      submitted_by: "e2e-test"
    })

    # 7. Wait for the WS client to receive a task_assign message
    #    The Scheduler will assign the task to our WS agent and push it via
    #    the Socket's handle_info({:push_task, ...})
    Smoke.Assertions.wait_for(fn ->
      msgs = AgentCom.TestHelpers.WsClient.messages(ws)
      Enum.any?(msgs, fn m -> m["type"] == "task_assign" end)
    end, timeout: 10_000)

    # 8. Extract task_id and generation from the task_assign message
    messages = AgentCom.TestHelpers.WsClient.messages(ws)
    task_assign_msg = Enum.find(messages, fn m -> m["type"] == "task_assign" end)
    assert task_assign_msg != nil
    assert task_assign_msg["task_id"] == task.id

    ws_task_id = task_assign_msg["task_id"]
    ws_generation = task_assign_msg["generation"]

    # 9. Send task_accepted via WebSocket
    :ok = AgentCom.TestHelpers.WsClient.send_json(ws, %{
      "type" => "task_accepted",
      "task_id" => ws_task_id,
      "protocol_version" => 1
    })

    # Brief wait for the hub to process the accepted message
    Process.sleep(200)

    # 10. Send task_complete via WebSocket with generation
    :ok = AgentCom.TestHelpers.WsClient.send_json(ws, %{
      "type" => "task_complete",
      "task_id" => ws_task_id,
      "generation" => ws_generation,
      "result" => %{"status" => "success", "output" => "e2e-test-result"},
      "tokens_used" => 42,
      "protocol_version" => 1
    })

    # 11. Wait for task to reach :completed status in TaskQueue
    Smoke.Assertions.assert_task_completed(task.id, timeout: 10_000)

    # 12. Verify via TaskQueue.get that the task is completed with correct result
    {:ok, completed} = AgentCom.TaskQueue.get(task.id)
    assert completed.status == :completed
    assert completed.result == %{"status" => "success", "output" => "e2e-test-result"}
    assert completed.tokens_used == 42

    # 13. Verify the WS client received task_ack messages
    final_messages = AgentCom.TestHelpers.WsClient.messages(ws)

    assert Enum.any?(final_messages, fn m ->
      m["type"] == "task_ack" and m["status"] == "accepted"
    end)

    assert Enum.any?(final_messages, fn m ->
      m["type"] == "task_ack" and m["status"] == "complete"
    end)

    # 14. Clean up
    AgentCom.TestHelpers.WsClient.stop(ws)
    AgentCom.Auth.revoke(agent_id)
  end
end
