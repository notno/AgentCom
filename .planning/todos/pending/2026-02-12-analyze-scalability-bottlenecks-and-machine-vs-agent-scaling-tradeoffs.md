---
created: 2026-02-12T19:48:06.374Z
title: Analyze scalability bottlenecks and machine vs agent scaling tradeoffs
area: architecture
files:
  - lib/agent_com/scheduler.ex
  - lib/agent_com/task_queue.ex
  - lib/agent_com/endpoint.ex
  - sidecar/ws.js
---

## Problem

As the system scales (more machines, more agents, more LLM endpoints), we need to understand where bottlenecks will appear and make informed decisions about scaling strategy. Key unknowns:

1. **Internet bandwidth**: When do we hit internet bandwidth limits? Claude API calls go over the internet — at what agent count does concurrent API traffic saturate the uplink? How does Tailscale mesh overhead factor in?

2. **Local hub/gateway bandwidth**: The hub is a single Erlang node handling all WebSocket connections, task routing, and DETS writes. At what scale does the hub become the bottleneck — number of concurrent WS connections, message throughput, DETS contention?

3. **Machine scaling vs agent scaling**: What's the marginal benefit of adding a new machine (with or without GPU/LLM capability) vs adding more named agents on existing machines? Considerations:
   - More machines = more Ollama endpoints = more parallel local LLM inference
   - More agents on same machine = shared CPU/RAM/GPU contention
   - GPU machines enable local model inference (standard-tier tasks offloaded from Claude API)
   - Non-GPU machines can still run trivial tasks and serve as additional sidecar hosts
   - Agent-per-machine vs multiple-agents-per-machine tradeoffs

4. **LLM inference bottleneck**: Local Ollama is GPU-bound (one inference at a time per GPU). Multiple agents on a GPU machine queue behind each other. Is it better to have 1 agent per GPU machine or multiple agents sharing the queue?

## Solution

Research task — produce a scaling analysis document:

- Model the system's data flow paths and identify bandwidth-sensitive segments
- Estimate per-task network costs (Claude API request/response sizes, WS message sizes)
- Calculate hub throughput limits (WS connections, message rate, DETS write rate)
- Analyze GPU utilization patterns (Ollama concurrent inference, VRAM limits)
- Produce scaling recommendations: when to add machines vs agents, with/without GPU
- Consider: should the hub itself eventually be distributed? At what scale?
