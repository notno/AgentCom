# Task Protocol Specification

## Overview

A structured message protocol for delegating, tracking, and completing tasks between Minds. Built on top of AgentCom's existing message types.

## Task Lifecycle

```
Coordinator                          Worker
    │                                  │
    │─── delegate ───────────────────►│
    │                                  │
    │◄── accept / reject ─────────────│
    │                                  │
    │◄── progress (optional, repeat) ──│
    │                                  │
    │◄── result ──────────────────────│
    │                                  │
    │─── ack ────────────────────────►│
```

## Message Types

### delegate

Sent by coordinator to assign a task.

```json
{
  "type": "message",
  "to": "target-agent",
  "message_type": "delegate",
  "payload": {
    "task_id": "task-001",
    "title": "Implement heartbeat reaping",
    "description": "Hub tracks last-ping-at per agent. Reaper process runs every 30s, removes agents silent for 90s from presence. Broadcast agent_left on reap.",
    "output_format": "structured",
    "priority": "high",
    "deadline": null,
    "context_refs": ["docs/product-vision.md"],
    "needed_capabilities": ["code", "elixir"]
  }
}
```

Fields:
- `task_id`: Unique task identifier. Coordinator generates.
- `title`: Short human-readable summary.
- `description`: Full task specification.
- `output_format`: `"structured"` (data/code), `"natural"` (prose), `"artifact"` (file/commit).
- `priority`: `"low"`, `"normal"`, `"high"`, `"urgent"`.
- `deadline`: ISO timestamp or null.
- `context_refs`: List of files/docs the worker should read for context.
- `needed_capabilities`: What skills this task requires.

### accept

Worker confirms they're taking the task.

```json
{
  "message_type": "accept",
  "payload": {
    "task_id": "task-001",
    "estimated_tokens": 5000,
    "eta_minutes": 10
  }
}
```

### reject

Worker declines the task.

```json
{
  "message_type": "reject",
  "payload": {
    "task_id": "task-001",
    "reason": "No Elixir environment available"
  }
}
```

On reject, coordinator can reassign to another Mind.

### progress

Optional status update during work. Cheap to send (no response expected).

```json
{
  "message_type": "progress",
  "payload": {
    "task_id": "task-001",
    "status": "implementing",
    "percent": 60,
    "note": "Reaper GenServer done, wiring into supervisor"
  }
}
```

### result

Worker delivers the completed task.

```json
{
  "message_type": "result",
  "payload": {
    "task_id": "task-001",
    "status": "completed",
    "summary": "Implemented heartbeat reaping. Reaper runs every 30s, drops agents after 90s silence.",
    "artifacts": ["commit:abc123"],
    "tokens_used": 4200
  }
}
```

Status values: `"completed"`, `"partial"`, `"failed"`, `"blocked"`.

### ack

Coordinator acknowledges receipt of result. Closes the task.

```json
{
  "message_type": "ack",
  "payload": {
    "task_id": "task-001",
    "feedback": "Clean implementation. Merged."
  }
}
```

## Auction Mode

For tasks without a pre-selected worker, broadcast a delegate with `to` set to `"broadcast"`:

```json
{
  "type": "message",
  "message_type": "delegate",
  "payload": {
    "task_id": "task-002",
    "title": "Implement channels/topics",
    "auction": true,
    "needed_capabilities": ["code", "elixir"],
    ...
  }
}
```

Minds respond with `accept` bids. Coordinator picks one, sends a `delegate` confirmation to the winner. Others get no message (silence = not selected).

## Tier 0 Handling

Workers should handle task messages at Tier 0 where possible:

- **delegate with `auction: true`**: Check capabilities match. No match → ignore (0 tokens).
- **ack**: Store, done. No LLM needed.
- **delegate to me specifically**: Always escalate to LLM for processing.
- **progress from others**: Store for context, no response needed.

## Task Registry

Coordinators should maintain a local task registry:

```json
{
  "tasks": {
    "task-001": {
      "title": "Implement heartbeat reaping",
      "assigned_to": "loash",
      "status": "in_progress",
      "created_at": "2026-02-09T11:45:00Z"
    }
  }
}
```

This lives in the coordinator's workspace, not on the hub. The hub routes messages; it doesn't track task state.

## Token Cost Analysis

| Action | Coordinator tokens | Worker tokens |
|--------|-------------------|---------------|
| delegate | ~500 (compose task) | 0 (Tier 0 receive) |
| accept | 0 (Tier 0 receive) | ~200 (check capabilities, estimate) |
| progress | 0 (store only) | ~200 (compose update) |
| result | ~1000 (review result) | ~varies (do the work) |
| ack | ~200 (compose feedback) | 0 (Tier 0 receive) |
| **Overhead total** | **~1700** | **~400** |

The protocol overhead is ~2100 tokens. The actual work dominates cost, which is correct — you want cheap coordination, expensive execution.
