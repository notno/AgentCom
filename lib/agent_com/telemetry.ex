defmodule AgentCom.Telemetry do
  @moduledoc """
  Telemetry event definitions and handler attachment for AgentCom.

  All telemetry events follow the Erlang/OTP naming convention using atom lists.
  Handlers are attached on application start via `attach_handlers/0`.

  ## Standard Metadata Keys

  The following metadata keys are used across events:

  - `module` - Source module emitting the event
  - `agent_id` - Agent identifier (when applicable)
  - `task_id` - Task identifier (when applicable)
  - `request_id` - Correlation ID for request tracing
  - `table` - DETS table atom (for DETS operations)

  ## Event Catalog

  ### Task Lifecycle

  - `[:agent_com, :task, :submit]` - Task submitted to queue
    measurements: `%{queue_depth: integer}`
    metadata: `%{task_id, priority, submitted_by}`

  - `[:agent_com, :task, :assign]` - Task assigned to agent
    measurements: `%{wait_ms: integer}`
    metadata: `%{task_id, agent_id, generation}`

  - `[:agent_com, :task, :complete]` - Task completed successfully
    measurements: `%{duration_ms: integer}`
    metadata: `%{task_id, agent_id, tokens_used}`

  - `[:agent_com, :task, :fail]` - Task failed
    measurements: `%{retry_count: integer}`
    metadata: `%{task_id, agent_id, error}`

  - `[:agent_com, :task, :dead_letter]` - Task moved to dead letter queue
    measurements: `%{retry_count: integer}`
    metadata: `%{task_id, error}`

  - `[:agent_com, :task, :reclaim]` - Task reclaimed from disconnected agent
    measurements: `%{}`
    metadata: `%{task_id, agent_id, reason}`

  - `[:agent_com, :task, :retry]` - Dead-letter task retried
    measurements: `%{}`
    metadata: `%{task_id, previous_error}`

  ### Agent Lifecycle

  - `[:agent_com, :agent, :connect]` - Agent connected via WebSocket
    measurements: `%{system_time: integer}`
    metadata: `%{agent_id, capabilities}`

  - `[:agent_com, :agent, :disconnect]` - Agent disconnected
    measurements: `%{connected_duration_ms: integer}`
    metadata: `%{agent_id, reason}`

  - `[:agent_com, :agent, :evict]` - Agent evicted by Reaper (stale)
    measurements: `%{stale_ms: integer}`
    metadata: `%{agent_id}`

  ### FSM Transitions

  - `[:agent_com, :fsm, :transition]` - Any FSM state change
    measurements: `%{duration_ms: integer}`
    metadata: `%{agent_id, from_state, to_state, task_id}`

  ### Scheduler

  - `[:agent_com, :scheduler, :attempt]` - Scheduling loop triggered
    measurements: `%{idle_agents: integer, queued_tasks: integer}`
    metadata: `%{trigger}`

  - `[:agent_com, :scheduler, :match]` - Task-agent match found
    measurements: `%{}`
    metadata: `%{task_id, agent_id}`

  ### Scheduler Routing

  - `[:agent_com, :scheduler, :route]` - Task routing decision made
    measurements: `%{candidate_count: integer, scoring_duration_us: integer}`
    metadata: `%{task_id, effective_tier, target_type, selected_endpoint, selected_model,
                  fallback_used, fallback_reason, classification_reason, estimated_cost_tier}`

  - `[:agent_com, :scheduler, :fallback]` - Fallback timer fired for a task
    measurements: `%{wait_ms: integer}`
    metadata: `%{task_id, original_tier, fallback_tier}`

  ### DETS Operations (span events with :start/:stop/:exception)

  - `[:agent_com, :dets, :backup, :start/:stop/:exception]` - Backup operation
  - `[:agent_com, :dets, :compaction, :start/:stop/:exception]` - Compaction operation
  - `[:agent_com, :dets, :restore, :start/:stop/:exception]` - Restore operation

  Span events are emitted by `:telemetry.span/3` which automatically provides
  `system_time` and `monotonic_time` on `:start`, and `duration` on `:stop` and
  `:exception`.
  """

  require Logger

  @doc """
  Attach all telemetry handlers. Called from Application.start/2.

  Uses module function capture (`&__MODULE__.handle_event/4`) for performance
  per telemetry best practices.
  """
  def attach_handlers do
    events = [
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
      # Scheduler Routing
      [:agent_com, :scheduler, :route],
      [:agent_com, :scheduler, :fallback],
      # DETS spans (start/stop/exception for each operation)
      [:agent_com, :dets, :backup, :start],
      [:agent_com, :dets, :backup, :stop],
      [:agent_com, :dets, :backup, :exception],
      [:agent_com, :dets, :compaction, :start],
      [:agent_com, :dets, :compaction, :stop],
      [:agent_com, :dets, :compaction, :exception],
      [:agent_com, :dets, :restore, :start],
      [:agent_com, :dets, :restore, :stop],
      [:agent_com, :dets, :restore, :exception]
    ]

    :telemetry.attach_many(
      "agent-com-telemetry-logger",
      events,
      &__MODULE__.handle_event/4,
      %{}
    )
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    try do
      Logger.info(
        %{
          telemetry_event: Enum.join(event, "."),
          measurements: measurements,
          metadata: metadata
        }
      )
    rescue
      e ->
        Logger.error("Telemetry handler crashed: #{inspect(e)}")
    end
  end
end
