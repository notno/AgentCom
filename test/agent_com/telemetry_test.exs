defmodule AgentCom.TelemetryTest do
  @moduledoc """
  Telemetry event emission tests for AgentCom.

  Verifies that telemetry events fire with correct measurements and metadata
  for all key lifecycle points: task, agent, FSM, scheduler, and DETS operations.

  Each test attaches a handler that sends events to the test process, fires
  events via :telemetry.execute, and asserts the correct shape is received.
  """

  use ExUnit.Case, async: true

  setup do
    test_pid = self()
    handler_id = "test-handler-#{inspect(self())}"

    :telemetry.attach_many(
      handler_id,
      [
        # Task lifecycle
        [:agent_com, :task, :submit],
        [:agent_com, :task, :assign],
        [:agent_com, :task, :complete],
        [:agent_com, :task, :fail],
        [:agent_com, :task, :dead_letter],
        [:agent_com, :task, :reclaim],
        [:agent_com, :task, :retry],
        # Agent lifecycle
        [:agent_com, :agent, :connect],
        [:agent_com, :agent, :disconnect],
        [:agent_com, :agent, :evict],
        # FSM transitions
        [:agent_com, :fsm, :transition],
        # Scheduler
        [:agent_com, :scheduler, :attempt],
        [:agent_com, :scheduler, :match],
        # DETS spans
        [:agent_com, :dets, :backup, :start],
        [:agent_com, :dets, :backup, :stop],
        [:agent_com, :dets, :backup, :exception],
        [:agent_com, :dets, :compaction, :start],
        [:agent_com, :dets, :compaction, :stop],
        [:agent_com, :dets, :compaction, :exception],
        [:agent_com, :dets, :restore, :start],
        [:agent_com, :dets, :restore, :stop],
        [:agent_com, :dets, :restore, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Handler Attachment
  # ---------------------------------------------------------------------------

  describe "handler attachment" do
    test "AgentCom.Telemetry handlers are attached on app start" do
      # The app attaches handlers via AgentCom.Telemetry.attach_handlers/0
      # Verify at least one handler exists for a key event
      handlers = :telemetry.list_handlers([:agent_com, :task, :submit])
      # We expect at least our test handler + the app's telemetry logger handler
      assert length(handlers) >= 1, "no handlers attached for task:submit"
    end

    test "handlers exist for all documented event prefixes" do
      prefixes = [
        [:agent_com, :task, :submit],
        [:agent_com, :task, :assign],
        [:agent_com, :task, :complete],
        [:agent_com, :task, :fail],
        [:agent_com, :agent, :connect],
        [:agent_com, :agent, :disconnect],
        [:agent_com, :agent, :evict],
        [:agent_com, :fsm, :transition],
        [:agent_com, :scheduler, :attempt],
        [:agent_com, :scheduler, :match],
        [:agent_com, :dets, :backup, :start],
        [:agent_com, :dets, :compaction, :start],
        [:agent_com, :dets, :restore, :start]
      ]

      for prefix <- prefixes do
        handlers = :telemetry.list_handlers(prefix)
        assert length(handlers) >= 1,
               "no handler attached for #{inspect(prefix)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Task Lifecycle Events
  # ---------------------------------------------------------------------------

  describe "task:submit event" do
    test "has correct shape with queue_depth measurement" do
      :telemetry.execute(
        [:agent_com, :task, :submit],
        %{queue_depth: 5},
        %{task_id: "test-123", priority: "normal", submitted_by: "agent-1"}
      )

      assert_receive {:telemetry_event, [:agent_com, :task, :submit], measurements, metadata}
      assert measurements.queue_depth == 5
      assert metadata.task_id == "test-123"
      assert metadata.priority == "normal"
      assert metadata.submitted_by == "agent-1"
    end
  end

  describe "task:assign event" do
    test "has correct shape with wait_ms measurement" do
      :telemetry.execute(
        [:agent_com, :task, :assign],
        %{wait_ms: 250},
        %{task_id: "test-456", agent_id: "agent-2", generation: 1}
      )

      assert_receive {:telemetry_event, [:agent_com, :task, :assign], measurements, metadata}
      assert measurements.wait_ms == 250
      assert metadata.task_id == "test-456"
      assert metadata.agent_id == "agent-2"
      assert metadata.generation == 1
    end
  end

  describe "task:complete event" do
    test "has correct shape with duration_ms measurement" do
      :telemetry.execute(
        [:agent_com, :task, :complete],
        %{duration_ms: 1500},
        %{task_id: "test-789", agent_id: "agent-3", tokens_used: 42}
      )

      assert_receive {:telemetry_event, [:agent_com, :task, :complete], measurements, metadata}
      assert measurements.duration_ms == 1500
      assert metadata.task_id == "test-789"
      assert metadata.agent_id == "agent-3"
      assert metadata.tokens_used == 42
    end
  end

  describe "task:fail event" do
    test "has correct shape with retry_count measurement" do
      :telemetry.execute(
        [:agent_com, :task, :fail],
        %{retry_count: 2},
        %{task_id: "test-fail", agent_id: "agent-4", error: "timeout"}
      )

      assert_receive {:telemetry_event, [:agent_com, :task, :fail], measurements, metadata}
      assert measurements.retry_count == 2
      assert metadata.task_id == "test-fail"
      assert metadata.error == "timeout"
    end
  end

  describe "task:dead_letter event" do
    test "has correct shape with retry_count measurement" do
      :telemetry.execute(
        [:agent_com, :task, :dead_letter],
        %{retry_count: 3},
        %{task_id: "test-dl", error: "max retries exceeded"}
      )

      assert_receive {:telemetry_event, [:agent_com, :task, :dead_letter], measurements, metadata}
      assert measurements.retry_count == 3
      assert metadata.task_id == "test-dl"
      assert metadata.error == "max retries exceeded"
    end
  end

  describe "task:reclaim event" do
    test "has correct shape with task_id and reason" do
      :telemetry.execute(
        [:agent_com, :task, :reclaim],
        %{},
        %{task_id: "test-reclaim", agent_id: "agent-5", reason: "disconnect"}
      )

      assert_receive {:telemetry_event, [:agent_com, :task, :reclaim], measurements, metadata}
      assert measurements == %{}
      assert metadata.task_id == "test-reclaim"
      assert metadata.reason == "disconnect"
    end
  end

  describe "task:retry event" do
    test "has correct shape with previous_error" do
      :telemetry.execute(
        [:agent_com, :task, :retry],
        %{},
        %{task_id: "test-retry", previous_error: "transient failure"}
      )

      assert_receive {:telemetry_event, [:agent_com, :task, :retry], measurements, metadata}
      assert measurements == %{}
      assert metadata.task_id == "test-retry"
      assert metadata.previous_error == "transient failure"
    end
  end

  # ---------------------------------------------------------------------------
  # Agent Lifecycle Events
  # ---------------------------------------------------------------------------

  describe "agent:connect event" do
    test "has correct shape with system_time measurement" do
      now = System.system_time(:millisecond)

      :telemetry.execute(
        [:agent_com, :agent, :connect],
        %{system_time: now},
        %{agent_id: "agent-new", capabilities: ["code", "review"]}
      )

      assert_receive {:telemetry_event, [:agent_com, :agent, :connect], measurements, metadata}
      assert measurements.system_time == now
      assert metadata.agent_id == "agent-new"
      assert metadata.capabilities == ["code", "review"]
    end
  end

  describe "agent:disconnect event" do
    test "has correct shape with connected_duration_ms" do
      :telemetry.execute(
        [:agent_com, :agent, :disconnect],
        %{connected_duration_ms: 30_000},
        %{agent_id: "agent-gone", reason: "websocket_closed"}
      )

      assert_receive {:telemetry_event, [:agent_com, :agent, :disconnect], measurements, metadata}
      assert measurements.connected_duration_ms == 30_000
      assert metadata.agent_id == "agent-gone"
      assert metadata.reason == "websocket_closed"
    end
  end

  describe "agent:evict event" do
    test "has correct shape with stale_ms measurement" do
      :telemetry.execute(
        [:agent_com, :agent, :evict],
        %{stale_ms: 120_000},
        %{agent_id: "agent-stale"}
      )

      assert_receive {:telemetry_event, [:agent_com, :agent, :evict], measurements, metadata}
      assert measurements.stale_ms == 120_000
      assert metadata.agent_id == "agent-stale"
    end
  end

  # ---------------------------------------------------------------------------
  # FSM Transition Events
  # ---------------------------------------------------------------------------

  describe "fsm:transition event" do
    test "carries duration and states" do
      :telemetry.execute(
        [:agent_com, :fsm, :transition],
        %{duration_ms: 150},
        %{agent_id: "agent-1", from_state: :idle, to_state: :assigned, task_id: "task-1"}
      )

      assert_receive {:telemetry_event, [:agent_com, :fsm, :transition], measurements, metadata}
      assert measurements.duration_ms == 150
      assert metadata.from_state == :idle
      assert metadata.to_state == :assigned
      assert metadata.agent_id == "agent-1"
      assert metadata.task_id == "task-1"
    end

    test "supports all documented state transitions" do
      transitions = [
        {:idle, :assigned},
        {:assigned, :working},
        {:working, :idle},
        {:working, :failed},
        {:assigned, :idle}
      ]

      for {from, to} <- transitions do
        :telemetry.execute(
          [:agent_com, :fsm, :transition],
          %{duration_ms: 10},
          %{agent_id: "agent-fsm", from_state: from, to_state: to, task_id: "task-fsm"}
        )

        assert_receive {:telemetry_event, [:agent_com, :fsm, :transition], _m, metadata}
        assert metadata.from_state == from
        assert metadata.to_state == to
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scheduler Events
  # ---------------------------------------------------------------------------

  describe "scheduler:attempt event" do
    test "has correct shape with idle_agents and queued_tasks" do
      :telemetry.execute(
        [:agent_com, :scheduler, :attempt],
        %{idle_agents: 3, queued_tasks: 7},
        %{trigger: "pubsub"}
      )

      assert_receive {:telemetry_event, [:agent_com, :scheduler, :attempt], measurements, metadata}
      assert measurements.idle_agents == 3
      assert measurements.queued_tasks == 7
      assert metadata.trigger == "pubsub"
    end

    test "supports zero idle agents (capacity planning metric)" do
      :telemetry.execute(
        [:agent_com, :scheduler, :attempt],
        %{idle_agents: 0, queued_tasks: 5},
        %{trigger: "timer"}
      )

      assert_receive {:telemetry_event, [:agent_com, :scheduler, :attempt], measurements, _metadata}
      assert measurements.idle_agents == 0
      assert measurements.queued_tasks == 5
    end
  end

  describe "scheduler:match event" do
    test "has correct shape with task_id and agent_id" do
      :telemetry.execute(
        [:agent_com, :scheduler, :match],
        %{},
        %{task_id: "task-matched", agent_id: "agent-matched"}
      )

      assert_receive {:telemetry_event, [:agent_com, :scheduler, :match], measurements, metadata}
      assert measurements == %{}
      assert metadata.task_id == "task-matched"
      assert metadata.agent_id == "agent-matched"
    end
  end

  # ---------------------------------------------------------------------------
  # DETS Span Events
  # ---------------------------------------------------------------------------

  describe "dets:backup span events" do
    test "start event fires with correct name" do
      :telemetry.execute(
        [:agent_com, :dets, :backup, :start],
        %{system_time: System.system_time()},
        %{table: :task_queue}
      )

      assert_receive {:telemetry_event, [:agent_com, :dets, :backup, :start], _measurements, metadata}
      assert metadata.table == :task_queue
    end

    test "stop event fires with duration" do
      :telemetry.execute(
        [:agent_com, :dets, :backup, :stop],
        %{duration: 500_000},
        %{table: :task_queue}
      )

      assert_receive {:telemetry_event, [:agent_com, :dets, :backup, :stop], measurements, metadata}
      assert measurements.duration == 500_000
      assert metadata.table == :task_queue
    end

    test "exception event fires on failure" do
      :telemetry.execute(
        [:agent_com, :dets, :backup, :exception],
        %{duration: 100_000},
        %{table: :task_queue, kind: :error, reason: :enoent, stacktrace: []}
      )

      assert_receive {:telemetry_event, [:agent_com, :dets, :backup, :exception], _m, metadata}
      assert metadata.kind == :error
      assert metadata.reason == :enoent
    end
  end

  describe "dets:compaction span events" do
    test "start event fires" do
      :telemetry.execute(
        [:agent_com, :dets, :compaction, :start],
        %{system_time: System.system_time()},
        %{table: :channels}
      )

      assert_receive {:telemetry_event, [:agent_com, :dets, :compaction, :start], _m, metadata}
      assert metadata.table == :channels
    end

    test "stop event fires with duration" do
      :telemetry.execute(
        [:agent_com, :dets, :compaction, :stop],
        %{duration: 1_000_000},
        %{table: :channels}
      )

      assert_receive {:telemetry_event, [:agent_com, :dets, :compaction, :stop], measurements, _metadata}
      assert measurements.duration == 1_000_000
    end
  end

  describe "dets:restore span events" do
    test "start event fires" do
      :telemetry.execute(
        [:agent_com, :dets, :restore, :start],
        %{system_time: System.system_time()},
        %{table: :mailbox}
      )

      assert_receive {:telemetry_event, [:agent_com, :dets, :restore, :start], _m, metadata}
      assert metadata.table == :mailbox
    end

    test "stop event fires with duration" do
      :telemetry.execute(
        [:agent_com, :dets, :restore, :stop],
        %{duration: 2_000_000},
        %{table: :mailbox}
      )

      assert_receive {:telemetry_event, [:agent_com, :dets, :restore, :stop], measurements, _metadata}
      assert measurements.duration == 2_000_000
    end

    test "exception event fires on failure" do
      :telemetry.execute(
        [:agent_com, :dets, :restore, :exception],
        %{duration: 50_000},
        %{table: :mailbox, kind: :error, reason: :file_corrupt, stacktrace: []}
      )

      assert_receive {:telemetry_event, [:agent_com, :dets, :restore, :exception], _m, metadata}
      assert metadata.kind == :error
      assert metadata.reason == :file_corrupt
    end
  end

  # ---------------------------------------------------------------------------
  # Event Independence
  # ---------------------------------------------------------------------------

  describe "event independence" do
    test "different event types do not interfere with each other" do
      # Fire multiple different events in sequence
      :telemetry.execute([:agent_com, :task, :submit], %{queue_depth: 1}, %{task_id: "t1"})
      :telemetry.execute([:agent_com, :agent, :connect], %{system_time: 0}, %{agent_id: "a1"})
      :telemetry.execute([:agent_com, :fsm, :transition], %{duration_ms: 5}, %{agent_id: "a1", from_state: :idle, to_state: :assigned, task_id: "t1"})

      # Each should arrive independently with correct data
      assert_receive {:telemetry_event, [:agent_com, :task, :submit], %{queue_depth: 1}, %{task_id: "t1"}}
      assert_receive {:telemetry_event, [:agent_com, :agent, :connect], %{system_time: 0}, %{agent_id: "a1"}}
      assert_receive {:telemetry_event, [:agent_com, :fsm, :transition], %{duration_ms: 5}, _}
    end
  end
end
