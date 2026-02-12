# Local LLM Offload Strategy

*Flere-Imsaho • Feb 10, 2026*
*Hardware: RTX 3080 Ti (12GB VRAM) • Recommended model: Qwen3 8B via Ollama*

## The Problem

Every agent interaction burns Anthropic API tokens — even trivial tasks like "write 42 to a file" or "check git status." With 5+ agents polling every few minutes, the token cost of coordination alone dominates actual productive work.

## The Principle

**Route by cognitive complexity.** Claude handles reasoning. Local Qwen handles execution.

## Offload Candidates

### Tier 1: Offload Now (trivial, high volume)
These are mechanical tasks that don't need reasoning. A local 8B model handles them fine.

| Task | Current Cost | Why Offloadable |
|------|-------------|-----------------|
| **Heartbeat processing** | Every agent, every 5 min | Read HEARTBEAT.md, poll mailbox, ack messages, update TOOLS.md. Pure procedure. |
| **Mailbox polling & ack** | Every heartbeat cycle | HTTP GET, parse JSON, update seq number. Zero reasoning required. |
| **Git operations** | Every task start/end | `git fetch`, `git checkout -b`, `git add`, `git commit`, `git push`. Scripted workflow. |
| **Status reporting** | Periodic broadcasts | Format a status message from known state. Template filling. |
| **File read/write** | Smoke test tasks | "Write 42 to test.txt" — the v2 smoke test is designed for this. |
| **Message forwarding** | Hub routing | Parse incoming message, decide recipient, POST to endpoint. |

**Estimated savings:** These account for ~60-70% of all agent turns today. At ~$0.02-0.05 per turn on Claude, that's significant at scale.

### Tier 2: Offload With Care (moderate complexity)
These need some judgment but a good 8B model with clear prompts can handle them.

| Task | Notes |
|------|-------|
| **PR branch creation** | Follow the git wrapper script. Needs to parse task description into branch name. |
| **Backlog parsing** | Read BACKLOG.md, extract items by section. Structured document, predictable format. |
| **Message composition** | "Tell Loash to rebase" — simple directed messages with clear intent. |
| **Log summarization** | Summarize recent git log or message history into a status update. |
| **Config file updates** | Update TOOLS.md, HEARTBEAT.md with new values. Pattern matching on known formats. |
| **Test execution** | Run predefined test scripts and report pass/fail. |

**Estimated savings:** ~15-20% of agent turns.

### Tier 3: Keep on Claude (complex reasoning)
These require the kind of thinking a small model can't reliably do.

| Task | Why |
|------|-----|
| **Code review** | Needs to understand intent, spot bugs, evaluate architecture. |
| **Architecture decisions** | Trade-off analysis, system design, failure mode reasoning. |
| **Complex code generation** | Writing new GenServers, designing APIs, implementing algorithms. |
| **Experiment design** | GCU's Prediction 5 required careful methodology. |
| **Conflict resolution** | When Minds disagree, needs nuanced judgment. |
| **Novel problem solving** | Anything that hasn't been done before in this codebase. |
| **PR review with feedback** | Substantive comments, not just "looks good." |
| **Product decisions** | Backlog prioritization, scope calls, trade-offs. |

## Implementation Options

### Option A: Per-Agent Model Routing (OpenClaw native)

OpenClaw supports per-agent model configuration. Set grunt-work agents to use local Ollama, keep reasoning agents on Claude.

```json5
{
  agents: {
    list: [
      {
        id: "worker-1",
        model: "ollama/qwen3:8b",  // local, cheap
        // handles: heartbeats, git ops, file tasks
      },
      {
        id: "flere-imsaho",
        model: "anthropic/claude-opus-4-6",  // remote, expensive
        // handles: review, architecture, coordination
      }
    ]
  }
}
```

**Pros:** Simple, uses existing OpenClaw machinery.
**Cons:** Agent is either all-local or all-remote. Can't mix within one agent.

### Option B: Task-Level Model Routing (v2 scheduler)

The v2 scheduler assigns tasks with a `model` field. Trivial tasks get routed to local, complex tasks to Claude.

```elixir
%Task{
  title: "Write smoke test output",
  model: "ollama/qwen3:8b",      # scheduler decides
  priority: :normal
}

%Task{
  title: "Review channels PR",
  model: "anthropic/claude-opus-4-6",  # scheduler decides
  priority: :high
}
```

**Pros:** Fine-grained, optimal cost per task.
**Cons:** Requires v2 scheduler. Needs a routing heuristic.

### Option C: Sidecar Handles Trivial, Escalates Complex

The v2 sidecar processes trivial tasks locally without waking OpenClaw at all. Only escalates to the LLM when the task requires reasoning.

```
Task arrives → Sidecar checks complexity tag
  → "trivial": sidecar executes locally (git, file ops, HTTP calls)
  → "standard": wake OpenClaw with local Qwen
  → "complex": wake OpenClaw with Claude
```

**Pros:** Maximum savings — trivial tasks cost zero LLM tokens.
**Cons:** Sidecar becomes smarter, more code to maintain.

### Recommendation: Start with A, evolve to B

1. **Now:** Install Ollama + Qwen3 8B. Create a dedicated "worker" agent on local model for smoke tests.
2. **Phase 3 (scheduler):** Add `model` field to tasks. Scheduler routes by complexity.
3. **Later:** Sidecar local execution for zero-token trivial tasks.

## Cost Projection

Assumptions: 5 agents, 5-minute heartbeat, 16 hours active/day

| Scenario | Turns/day | Claude cost/day | Local cost/day | Savings |
|----------|-----------|----------------|----------------|---------|
| All Claude | ~960 | ~$19-48 | $0 | — |
| Tier 1 offloaded | ~960 | ~$6-16 | ~$0 (local) | **~65%** |
| Tier 1+2 offloaded | ~960 | ~$3-10 | ~$0 (local) | **~80%** |

*Claude cost estimated at $0.02-0.05/turn average. Local inference on RTX 3080 Ti is effectively free (electricity only).*

## Qwen3 8B Capabilities Check

Based on the offload tiers, Qwen3 8B needs to reliably:
- ✅ Follow structured instructions (HEARTBEAT.md)
- ✅ Parse and generate JSON
- ✅ Execute shell commands via tool calls
- ✅ Read/write files in known formats
- ✅ Compose simple messages
- ⚠️ Git workflows (needs testing — branch naming, commit messages)
- ❌ Code review (not reliable enough)
- ❌ Architecture reasoning (too shallow)

The 8B model is a good fit for Tiers 1-2. For anything in Tier 3, stick with Claude.

## Next Steps

1. Install Ollama on Nathan's machine
2. Pull Qwen3 8B (`ollama pull qwen3:8b`)
3. Configure as OpenClaw provider
4. Create one "worker" agent using local model
5. Run v2 smoke test (10 trivial tasks) — compare cost and reliability vs Claude
6. If reliable, migrate all heartbeat processing to local model
