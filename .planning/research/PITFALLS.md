# Domain Pitfalls: Smart Agent Pipeline (v1.2)

**Domain:** Adding LLM mesh routing, model-aware task scheduling, enriched task format, and agent self-verification to existing Elixir/BEAM + Node.js distributed agent coordination system
**Researched:** 2026-02-12
**Overall Confidence:** HIGH (codebase analysis of all core modules + Ollama API documentation + distributed systems research + LLM routing literature)

---

## Critical Pitfalls

Mistakes that cause rewrites, broken production pipelines, or cascading failures across the existing system.

---

### Pitfall 1: Enriching the Task Format Breaks the Entire Existing Pipeline

**What goes wrong:** The current task map in `TaskQueue` has a flat structure with 18 fields (id, description, metadata, priority, status, assigned_to, generation, etc.). Adding enrichment fields (context, success_criteria, verification_steps, complexity_class, model_assignment, llm_endpoint) changes the shape of every task in DETS. Existing tasks in the `task_queue.dets` and `task_dead_letter.dets` files do not have these fields. The scheduler, socket, sidecar, and dashboard all pattern-match or destructure task maps -- every consumer breaks when fields are missing or unexpected.

**Why it happens:** The task map is a plain Elixir map (not a struct), so there is no compile-time enforcement of field presence. The `TaskQueue.submit/1` handler (line 206-229 of task_queue.ex) builds the task map inline with `Map.get` fallbacks. The `Scheduler.do_assign/2` (line 229-268 of scheduler.ex) extracts `task_id`, `description`, `metadata`, `generation` from the task and pushes them to the socket. The `Socket.handle_info({:push_task, task})` (line 170-185 of socket.ex) reads these fields with `||` fallbacks. The sidecar `handleTaskAssign` (line 506-560 of sidecar/index.js) expects `task_id`, `description`, `metadata`, `generation`, `assigned_at`. Every layer in the pipeline has its own assumption about what a task looks like.

**Consequences:**
- Tasks persisted before the enrichment update lack new fields; `Map.get(task, :complexity_class)` returns `nil`, which breaks routing logic that pattern-matches on complexity
- Sidecar crashes or silently ignores new fields it does not understand (metadata is a catch-all map, but new top-level fields are not)
- Dashboard renders break if it tries to display verification steps or model assignment for old tasks
- Task history entries become inconsistent -- some have enrichment data, some do not
- DETS stores the raw map term, so old records persist indefinitely with the old schema

**Prevention:**
- Define enrichment fields as OPTIONAL with sane defaults in `TaskQueue.submit/1` -- every new field must have a fallback: `complexity_class: Map.get(params, :complexity_class, "unclassified")`, `model_assignment: nil`, `verification_steps: []`
- Add a `task_version` field to the task map (start at 2, existing tasks are implicitly version 1) -- this allows downstream code to branch on version
- Carry enrichment data INSIDE the existing `metadata` map for the sidecar transport layer, avoiding new top-level fields in the WebSocket protocol: `metadata.enrichment.complexity_class`, `metadata.enrichment.model_assignment`
- Write a one-time migration function that runs on startup: scan DETS, backfill missing fields with defaults for any task in `queued` or `assigned` status
- Update validation schemas LAST (after hub and sidecar are both handling the new fields) to avoid rejecting messages from lagging sidecars

**Detection:**
- Tasks stuck in `queued` status because scheduler cannot classify them
- Sidecar logs showing `undefined` for new fields
- Dashboard errors when rendering enriched tasks
- `FunctionClauseError` in pattern matches that expect new fields to exist

**Confidence:** HIGH -- directly observed: task map is untyped, every layer destructures independently, no migration mechanism exists.

**Phase impact:** Must be the FIRST thing addressed in v1.2. Every other feature (routing, verification, model assignment) depends on the enriched task format.

---

### Pitfall 2: Complexity Classification Overfits to Keyword Heuristics

**What goes wrong:** The scheduler needs to classify tasks as trivial/simple/complex to route them to the appropriate model (local Ollama vs. cloud Claude). The natural first implementation is keyword-based heuristics: if the description contains "rename", "delete", "move" => trivial; if it mentions "refactor", "architect", "design" => complex. This approach overfits to category heuristics and misroutes tasks in both directions -- simple tasks sent to expensive Claude, complex tasks sent to weak local models that produce garbage.

**Why it happens:** 2025-2026 research on LLM routing confirms this is the dominant failure mode. Empirical analyses reveal that many routers overfit to category heuristics, sending nearly all coding and math queries to high-cost models regardless of actual complexity. A task described as "rename the database migration file" (trivial) and "rename the entire authentication architecture" (complex) both contain "rename" but require vastly different capability levels. The scheduler has no training data -- v1.0/v1.1 treated all tasks as equivalent, so there is zero historical signal about task complexity.

**Consequences:**
- Cost explosion: trivial git operations sent to Claude burn API credits for no benefit
- Quality collapse: complex design tasks sent to a 7B local model produce unusable results that fail self-verification and retry endlessly
- Retry storms: misrouted complex tasks fail, retry (up to `max_retries: 3`), fail again on the same weak model, dead-letter
- False confidence: the classifier "works" on test cases but fails on real task diversity

**Prevention:**
- Start with a WHITELIST approach, not a classifier. Explicitly define trivial operations by task type, not description parsing: `{type: "git_checkout"}`, `{type: "file_move"}`, `{type: "status_check"}` => trivial. Everything else defaults to the strongest available model
- Use the `metadata` field to carry explicit complexity hints from the task submitter (the human or upstream agent knows if this is trivial): `metadata.complexity: "trivial" | "standard" | "complex"`
- Default to Claude (expensive but correct) and DEMOTE to local Ollama only when explicitly flagged or when the task type is on the trivial whitelist -- this is the safe direction because an overqualified model wastes money but still succeeds, while an underqualified model fails
- Defer ML-based classification until you have 50+ completed tasks with outcome data to train against (the same threshold already established for the Flere-Imsaho PR reviewer role)
- Log every routing decision with the classification rationale for post-hoc analysis

**Detection:**
- Dead-letter rate increases after enabling routing (tasks that used to succeed now fail because they were sent to weaker models)
- Token cost does not decrease (heuristics routing everything to Claude anyway)
- Completion time variance increases dramatically (some tasks fast on local, some impossibly slow)

**Confidence:** HIGH -- confirmed by [RouterEval benchmark research](https://aclanthology.org/2025.findings-emnlp.208.pdf) and [routing collapse analysis](https://arxiv.org/html/2602.03478) showing this is the dominant failure mode in LLM routing systems.

**Phase impact:** Model-aware scheduler routing phase. Must resist the temptation to build a "smart" classifier on day one.

---

### Pitfall 3: Ollama Model Cold Start Makes Health Checks Unreliable

**What goes wrong:** The LLM endpoint registry health-checks Ollama instances across the Tailscale mesh. A health check calls `GET /api/tags` or `GET /api/ps` and marks the endpoint as healthy. But "healthy" (Ollama process running, API responding) does not mean "ready to serve inference." Ollama unloads models after 5 minutes of inactivity by default. The first real request after idle triggers model loading, which takes 10-120 seconds depending on model size and hardware. During this loading time, subsequent requests queue (up to `OLLAMA_MAX_QUEUE=512`) or return 503 errors. The health check says "green" but the endpoint is effectively unavailable for 30+ seconds.

**Why it happens:** Ollama's health model is process-level, not model-level. `GET /` returns 200 if the Ollama daemon is running. `GET /api/tags` returns the list of downloaded models, not loaded models. `GET /api/ps` returns currently loaded models -- this is the correct endpoint, but models expire from memory after the `keep_alive` period (default: 5 minutes). A hub health check at minute 4 sees the model loaded; a task routed at minute 6 hits a cold start. The health check becomes a lagging indicator, not a leading one.

**Consequences:**
- Tasks routed to "healthy" Ollama endpoints timeout waiting for model load (default sidecar confirmation timeout is 30 seconds -- model load for a 30B model can exceed 120 seconds)
- Thundering herd: if all 5 agents simultaneously get tasks routed to the same Ollama instance, parallel model loads exhaust VRAM. Ollama handles this by queuing, but the queue depth causes cascading timeouts
- False failover: health check marks endpoint unhealthy after timeout, routes to cloud Claude (expensive), then Ollama finishes loading and becomes idle again -- oscillating between cold-start failure and expensive fallback
- Parallel requests during loading multiply context memory: "parallel request processing for a given model results in increasing the context size by the number of parallel requests" -- 4 parallel requests on a 2K context becomes 8K context with doubled memory allocation

**Prevention:**
- Use `GET /api/ps` (not `/api/tags`) for health checks -- this shows models currently loaded in memory, their VRAM usage, and their expiration time
- Implement a "warm" check: an endpoint is `healthy` only if `GET /api/ps` shows the expected model loaded AND the model's expiration time is more than 60 seconds away
- Send periodic keep-alive requests to critical Ollama endpoints: a lightweight `POST /api/generate` with `keep_alive: "30m"` and a tiny prompt keeps the model loaded without burning significant GPU time
- Set `OLLAMA_KEEP_ALIVE=-1` on dedicated inference hosts to prevent automatic unloading (but be aware of [GitHub issue #9410](https://github.com/ollama/ollama/issues/9410) where this setting may not be fully reliable)
- Implement request queuing at the hub level: do not route more than 2 concurrent tasks to the same Ollama endpoint (use the model's loaded context to determine capacity)
- Add a `model_load_timeout_ms` per endpoint in the registry that is distinct from the request timeout -- model loading should have a 180-second timeout, while generation should have a 60-second timeout

**Detection:**
- First task after idle period consistently fails with timeout
- Ollama endpoint oscillates between healthy and unhealthy in the registry
- Token costs spike because cold-start failures cascade to cloud fallback
- Sidecar logs showing `confirmation_timeout` (existing 30-second timeout is too short for model loading)

**Confidence:** HIGH -- confirmed by [Ollama FAQ](https://docs.ollama.com/faq) documenting 5-minute keep_alive default, [Ollama GitHub issue #4350](https://github.com/ollama/ollama/issues/4350) documenting model loading timeout problems, and [Ollama /api/ps documentation](https://docs.ollama.com/api/ps) showing runtime model state.

**Phase impact:** LLM endpoint registry phase. Health checking must be model-aware, not just process-aware.

---

### Pitfall 4: Self-Verification is an LLM Judging Its Own Work (Dunning-Kruger for Machines)

**What goes wrong:** Agent self-verification means the same LLM (or same-class model) that produced the output also evaluates whether the output meets success criteria. This creates a systematic bias: the model that confidently generated wrong code will confidently verify it as correct. Research shows that LLMs trained with next-token objectives and common leaderboards learn to reward confident guessing over calibrated uncertainty. A model that hallucinated a function name will also hallucinate that the function name is correct when asked to verify.

**Why it happens:** The proposed architecture has the sidecar call an LLM to do work, then call the same (or similar) LLM to check the work against success criteria. The verification LLM has the same training biases, the same knowledge gaps, and no access to ground truth (it cannot compile the code, run tests, or check the filesystem). It is asked "does this output satisfy these criteria?" and generates a plausible-sounding "yes" because that is what LLMs do -- generate plausible text.

**Consequences:**
- Bad PRs submitted with "verification passed" status, creating false confidence
- Subtle errors compound: a misnamed variable passes self-verification, the next task builds on the wrong name, the third task cannot find the function and fails
- Self-verification adds latency and cost (an additional LLM call per task) for near-zero actual quality improvement on tasks the model was already wrong about
- The system appears to work during testing (models get easy test tasks right and also verify them correctly) but fails in production on harder tasks where verification is most needed

**Prevention:**
- **Ground truth verification first, LLM verification second.** The verification pipeline should prioritize mechanical checks: does the code compile? Do existing tests pass? Does `git diff` show changes in the expected files? Can the changed file be parsed? These are cheap, fast, and 100% reliable
- Structure success criteria as a checklist with two tiers:
  - **Mechanical checks** (the sidecar runs these directly -- zero LLM tokens): file exists, tests pass, no syntax errors, branch is clean, diff is non-empty
  - **Semantic checks** (LLM evaluates these -- but only after mechanical checks pass): does the implementation match the intent? Are there edge cases?
- Use a DIFFERENT model for verification than for generation when possible. If generation used a 7B local model, verify with Claude. If generation used Claude, verify with a different Claude call with explicit adversarial prompting ("find problems with this code, assume it has bugs")
- Set a verification confidence threshold: the LLM must express specific concerns, not just "LGTM." Require the verification prompt to output a structured JSON with `{passed: bool, issues: [{severity, description}], confidence: float}` -- reject if confidence is below threshold or if issues list is empty (suspiciously clean verification = likely rubber-stamped)
- Log verification decisions alongside outcomes. After 50+ tasks, analyze: did tasks that passed self-verification actually succeed? This builds the feedback loop needed for calibration

**Detection:**
- Self-verification pass rate above 95% (suspiciously high -- means it is rubber-stamping)
- PRs that passed verification getting rejected by human reviewers
- Verification always passes when the same model is used for generation and verification
- Verification latency/cost not correlated with task complexity (all tasks take the same time to verify regardless of difficulty)

**Confidence:** HIGH -- confirmed by [2025 survey on agent hallucinations](https://arxiv.org/html/2509.18970v1), [Chain-of-Verification research](https://learnprompting.org/docs/advanced/self_criticism/chain_of_verification), and [HaluGate token-level verification](https://blog.vllm.ai/2025/12/14/halugate.html) all documenting the limitations of LLM self-judgment.

**Phase impact:** Self-verification phase. Design verification as a mechanical-first pipeline, not an LLM-judgment pipeline.

---

### Pitfall 5: Touching the Scheduler Breaks the Battle-Tested Assignment Loop

**What goes wrong:** The current `Scheduler.try_schedule_all/1` and `do_match_loop/2` are simple, stateless, and proven correct across v1.0 and v1.1 (48 + 153 commits, smoke tested). Adding model-aware routing means the scheduler must now consider: task complexity class, available LLM endpoints, endpoint health status, model capabilities, agent proximity to endpoints, and current endpoint load. This turns a 100-line stateless matcher into a complex scheduling engine with external state dependencies (endpoint registry queries mid-loop). A bug in the new routing logic causes ALL task assignment to fail, not just LLM-routed tasks.

**Why it happens:** The current scheduler is beautifully simple: query idle agents, query queued tasks, match by capabilities, assign. It holds no state (`%{}`). Adding model routing means the scheduler must:
1. Classify each task's complexity (new logic)
2. Query the endpoint registry for available models (new dependency)
3. Match task complexity to model capability (new matching dimension)
4. Consider endpoint health and load (new external state)
5. Pick the best agent based on proximity to the endpoint (new optimization)

Each of these is a new failure mode. If the endpoint registry is down, the scheduler blocks. If the complexity classifier throws, the entire match loop crashes. If the model assignment logic has an off-by-one in the capability comparison, tasks pile up in the queue.

**Consequences:**
- Scheduler GenServer crashes, stopping ALL task assignment until restart (even for tasks that do not need LLM routing)
- Tasks with `complexity_class: nil` (old-format tasks) have no routing path and accumulate indefinitely
- Endpoint registry query latency adds to every scheduling attempt, slowing the reactive loop that currently responds to PubSub events in microseconds
- The `30_000ms` stuck sweep cannot distinguish between "task stuck because agent crashed" and "task stuck because model is loading" -- it reclaims tasks that are legitimately waiting for model load

**Prevention:**
- Keep the existing match loop UNTOUCHED. Add model routing as a SEPARATE step that runs AFTER the basic capability match. The scheduler assigns a task to an agent (existing logic), then the agent/sidecar handles model selection (new logic). This keeps the scheduler simple and pushes complexity to the edges
- If routing MUST be in the scheduler, implement it as a pre-processing enrichment step: before the match loop, annotate each task with its model assignment. The match loop itself still just checks capabilities -- but capabilities now include `can_reach_claude`, `can_reach_ollama_7b`, etc.
- Add a fallback path: if complexity classification fails, default to "standard" routing (strongest available model). Never let a classification failure block assignment
- Wrap all new scheduler logic in try/rescue that falls back to the existing simple matching. Log classification failures but do not crash the scheduler
- Increase the stuck sweep threshold for LLM-routed tasks: add a `task_type` field that distinguishes mechanical tasks (5-minute timeout) from LLM tasks (15-minute timeout, because model loading + inference + verification takes longer)

**Detection:**
- Queue depth increasing without agent assignment (scheduler crashed or routing is blocking)
- All tasks being routed to Claude (fallback path triggering because local routing is broken)
- Scheduling attempt telemetry showing increased latency per attempt
- `scheduler_assign_failed` log entries increasing after routing deployment

**Confidence:** HIGH -- directly observed: `Scheduler.do_match_loop/2` is 15 lines of clean recursive matching; any change to its structure risks the proven behavior.

**Phase impact:** Model-aware scheduler routing phase. The routing decision should be OUTSIDE the core match loop, either as a pre-enrichment step or pushed to the sidecar.

---

## Moderate Pitfalls

Mistakes that cause significant rework, degraded performance, or incorrect behavior.

---

### Pitfall 6: Thundering Herd on Ollama Endpoint Recovery

**What goes wrong:** An Ollama endpoint goes unhealthy (host reboots, model crashes, network blip). While unhealthy, tasks accumulate in the queue or get routed to cloud fallback. The endpoint recovers and the health check marks it healthy. The scheduler immediately routes ALL queued tasks that match that endpoint's capabilities, overwhelming the just-recovered instance with concurrent requests. Ollama responds with 503 errors (`OLLAMA_MAX_QUEUE` exceeded) or extreme latency from parallel model loading.

**Why it happens:** The scheduler is event-driven and reacts to scheduling opportunities greedily: `try_schedule_all/1` processes the entire queue of waiting tasks against all available agents. When an endpoint transitions from unhealthy to healthy, this creates a burst of assignments. Ollama's concurrency model is limited: `OLLAMA_NUM_PARALLEL` defaults to 1, meaning requests are serialized by default. Even with parallel mode enabled, "parallel request processing for a given model results in increasing the context size by the number of parallel requests" -- 4 parallel requests quadruple memory usage.

**Consequences:**
- Recovered endpoint immediately overwhelmed, goes unhealthy again (oscillation)
- VRAM exhaustion from parallel context multiplication crashes the Ollama process
- Tasks assigned during the burst all fail simultaneously, triggering retry storms that amplify the problem
- Cloud fallback costs spike during oscillation periods

**Prevention:**
- Implement endpoint capacity tracking in the registry: each endpoint has a `max_concurrent` limit (default: 1 for Ollama, higher for cloud APIs). The scheduler checks `current_in_flight < max_concurrent` before routing
- Add a recovery grace period: when an endpoint transitions from unhealthy to healthy, it enters a "warming" state where only 1 task is routed. After that task succeeds, capacity ramps up linearly (1, 2, 4, max)
- Use a circuit breaker pattern per endpoint: after N consecutive failures, the endpoint enters an "open" state that rejects new tasks for a cooldown period. The `fuse` Erlang library or `ExternalService` Elixir library provides this pattern
- Decouple health check frequency from routing decisions: health checks can run every 30 seconds, but routing recovery should be gradual over minutes

**Detection:**
- Endpoint flapping between healthy/unhealthy in rapid succession
- Bursts of task failures immediately following endpoint recovery
- Ollama process restarting (OOM kill) visible in host system logs
- Sudden spikes in cloud API usage correlated with endpoint recovery events

**Confidence:** MEDIUM -- based on [thundering herd patterns](https://distributed-computing-musings.com/2025/08/thundering-herd-problem-preventing-the-stampede/) and Ollama's documented concurrency limitations. Not directly observed in this system yet, but the architecture creates the conditions.

**Phase impact:** LLM endpoint registry phase. Capacity tracking and circuit breakers must be designed alongside health checking.

---

### Pitfall 7: Sidecar Complexity Explosion From Simple Relay to LLM Orchestrator

**What goes wrong:** The current sidecar (`sidecar/index.js`) is a 780-line Node.js script that does three things: maintain a WebSocket connection, manage a task queue (max 1 active), and watch for result files. The v1.2 changes require the sidecar to: route LLM calls to the correct endpoint (local Ollama or cloud API), manage model selection per task, handle streaming responses from Ollama, run mechanical verification checks (compile, test, file parse), execute LLM-based semantic verification, handle trivial tasks without any LLM call, and manage verification retry loops. This transforms a simple relay script into a stateful orchestration engine.

**Why it happens:** The sidecar is the natural place for LLM call execution (it runs on the agent's machine, close to local Ollama). But the current architecture is a thin relay -- the `HubConnection` class handles task assignment by persisting the task, running a wake command, and watching for result files. There is no LLM client, no HTTP request logic (beyond WebSocket), no streaming handler, no verification pipeline. Adding all of this to a single `index.js` file creates a maintenance nightmare.

**Consequences:**
- Single-file sidecar grows from 780 lines to 2000+ lines, making bugs hard to find
- Error handling becomes fragmented: wake errors, LLM API errors, verification errors, streaming errors all handled differently
- The pm2-managed sidecar process is not designed for long-running LLM inference calls (120+ seconds) -- pm2's restart logic may interfere
- Testing becomes impossible: the current sidecar has zero tests; a complex orchestrator without tests is a ticking timebomb
- Configuration explosion: each sidecar needs Ollama URLs, API keys, model preferences, verification settings, timeout values, retry policies

**Prevention:**
- Decompose the sidecar into modules BEFORE adding LLM features. Create `lib/llm-client.js` (Ollama/Claude HTTP calls), `lib/verification.js` (mechanical + semantic checks), `lib/task-executor.js` (orchestrates wake + LLM call + verification), keeping `index.js` as the thin relay it was designed to be
- Add the LLM routing configuration to `config.json` with a clear structure: `{ "llm_endpoints": [{"url": "http://localhost:11434", "type": "ollama", "models": ["qwen2.5-coder:7b"]}], "cloud_api_key": "..." }`
- Implement an HTTP client wrapper that handles Ollama-specific gotchas (streaming, timeouts, model loading delays, 503 handling) in one place, not scattered through the codebase
- Consider whether some of this logic belongs in the Elixir hub instead of the Node.js sidecar. The hub already has GenServer supervision, circuit breakers via `fuse`, and telemetry. The sidecar should remain a thin executor; the hub should make the routing decisions
- Add basic sidecar tests using a mock Ollama server before shipping LLM features

**Detection:**
- Sidecar `index.js` exceeds 1500 lines
- Multiple developers unable to understand the sidecar flow
- Sidecar crashes from unhandled promise rejections in LLM call chains
- pm2 restarting the sidecar during long inference calls

**Confidence:** HIGH -- directly observed: sidecar is 780 lines in a single file with zero tests and no module structure beyond basic `lib/` extraction.

**Phase impact:** Should be addressed early -- decompose the sidecar BEFORE adding LLM features to it.

---

### Pitfall 8: Ollama Streaming Gotchas Break the Sidecar Request Pipeline

**What goes wrong:** The sidecar needs to call Ollama's `/api/generate` or `/api/chat` endpoints. Ollama streams responses by default (NDJSON chunks). The sidecar's HTTP handling must correctly buffer streaming chunks, detect completion, handle mid-stream errors, and enforce timeouts. Several Ollama-specific behaviors break naive HTTP clients:
1. Streaming with tools enabled returns a single complete response, not streamed chunks (breaking stream parsers)
2. Long context processing can take 30+ seconds before the FIRST token appears (causing premature timeout)
3. Model loading delay occurs BEFORE streaming starts (adding 10-120 seconds of silence)
4. 503 errors when queue is full are returned as HTTP, not as streaming chunks
5. Ollama returns `done: true` in the final chunk, but connection may not close immediately

**Why it happens:** Ollama's API has evolved rapidly and has several behaviors that differ from standard HTTP streaming conventions. The sidecar currently uses the `ws` library for WebSocket but has no HTTP client for REST API calls. Whatever HTTP client is added must handle NDJSON streaming, which is not native to Node.js `fetch` or most HTTP libraries without explicit stream parsing.

**Consequences:**
- Sidecar treats model loading silence as a timeout and fails the task prematurely
- Streaming parser crashes on tool-enabled responses that arrive as a single block
- Memory leak from unbounded stream buffering on large responses
- 503 errors not distinguished from successful empty responses
- Task reported as failed when Ollama was actually processing correctly (just slowly)

**Prevention:**
- Use `stream: false` for the initial implementation. This is simpler, avoids all streaming gotchas, and is sufficient for task-oriented work (not interactive chat). Add streaming later as an optimization
- If streaming is needed, implement a proper NDJSON parser that handles partial lines, buffering, and the `done: true` sentinel
- Implement THREE distinct timeouts: (1) connection timeout (5s -- is Ollama reachable?), (2) first-token timeout (180s -- accounts for model loading + context processing), (3) inter-token timeout (30s -- if streaming stops mid-response, something is wrong)
- Always check the HTTP status code BEFORE attempting to parse the response body. 503 means "queue full, retry later" not "empty response"
- Test with `stream: false` first to validate the pipeline, then add streaming as a separate change

**Detection:**
- Task failures with "timeout" that succeed on immediate retry (cold start)
- Sidecar memory growing during long inference calls (stream buffering)
- Inconsistent response parsing between tool and non-tool calls
- Tasks succeeding in test (small models, fast load) but failing in production (large models, slow load)

**Confidence:** HIGH -- confirmed by [Ollama streaming docs](https://docs.ollama.com/api/streaming), [Ollama issue #9084](https://github.com/ollama/ollama/issues/9084) (tools breaking streaming), [Ollama issue #7685](https://github.com/ollama/ollama/issues/7685) (gateway timeout on streaming), and [Ollama issue #4350](https://github.com/ollama/ollama/issues/4350) (model loading timeout).

**Phase impact:** Sidecar model routing phase. Start with `stream: false` and non-tool calls.

---

### Pitfall 9: Tailscale Mesh Latency Makes Synchronous Health Checks Expensive

**What goes wrong:** The LLM endpoint registry needs to health-check Ollama instances running on different machines across the Tailscale mesh. Each health check is an HTTP request over Tailscale (WireGuard tunnel). Tailscale typically adds 1-5ms latency for direct connections, but can spike to 50-200ms when connections relay through DERP servers (when NAT traversal fails). With 5+ Ollama endpoints to check every 30 seconds, synchronous health checks take 250-1000ms per cycle, blocking the registry GenServer.

**Why it happens:** The registry GenServer naturally implements health checking as a periodic task (like the existing `sweep_stuck` in the Scheduler). If health checks are synchronous HTTP calls inside a GenServer `handle_info`, the GenServer is blocked for the duration of ALL health checks. During this time, endpoint queries from the scheduler are queued, adding latency to every task assignment. Worse, if a host is unreachable, the HTTP timeout (typically 5-10 seconds) blocks the GenServer for the full duration.

**Consequences:**
- Registry becomes a bottleneck: scheduler queries queue behind health checks
- Single unreachable host blocks the entire health check cycle for its timeout duration
- Cascading delays: scheduler latency increases, task assignment slows, agents sit idle
- Health check data becomes stale if checks take longer than the check interval

**Prevention:**
- Run health checks asynchronously using `Task.async` or `Task.Supervisor.async_nolink` -- the GenServer starts health check tasks and processes results when they complete, without blocking
- Set aggressive HTTP timeouts for health checks: 2-second connect timeout, 3-second response timeout. A healthy Ollama responds to `/api/ps` in under 100ms; anything slower is effectively unhealthy
- Stagger health checks: do not check all endpoints simultaneously. Check one endpoint per second to spread the load
- Cache health status with a TTL: the scheduler reads cached status from ETS (fast), the health checker updates ETS asynchronously (slow but non-blocking)
- Use `Mint` (already a dependency via Bandit) for HTTP calls to Ollama endpoints rather than adding HTTPoison/Req -- avoid new dependencies when a capable HTTP client is already available

**Detection:**
- Endpoint registry query latency visible in scheduler telemetry
- Health check cycle taking longer than the check interval (falling behind)
- Agents sitting idle while tasks are queued (scheduler blocked on registry)

**Confidence:** MEDIUM -- based on [Tailscale performance issues](https://github.com/tailscale/tailscale/issues/14791) and general distributed systems patterns. Latency depends heavily on network topology.

**Phase impact:** LLM endpoint registry phase. Design the registry as an async actor with ETS-cached state.

---

### Pitfall 10: WebSocket Protocol Changes Require Coordinated Hub + Sidecar Deployment

**What goes wrong:** The enriched task format and model routing information need to flow from the hub to the sidecar via the existing WebSocket `task_assign` message. Adding new fields to `task_assign` (like `model_endpoint`, `complexity_class`, `verification_steps`) means the hub sends data the sidecar does not understand. If the hub is updated first, sidecars receive unknown fields and may break. If sidecars are updated first, they expect fields the hub does not send. Unlike a typical web service where the server controls the deployment, this system has independently-deployed sidecars on 5 different machines managed by pm2.

**Why it happens:** The current WebSocket protocol is implicit -- there is no version negotiation beyond the `protocol_version: 1` field in the identify message (which is sent but never checked by the hub). The sidecar's `handleTaskAssign` destructures specific fields (`msg.task_id`, `msg.description`, `msg.metadata`). New fields like `msg.model_endpoint` or `msg.verification_steps` will be `undefined` in old sidecars. Conversely, a new sidecar sending `task_complete` with verification results will confuse an old hub.

**Consequences:**
- Partial deployment (some sidecars updated, some not) creates inconsistent behavior across agents
- Updated hub sends model routing info that old sidecars ignore, leading to tasks executed on wrong models
- Updated sidecars send verification results that old hub does not store, losing verification data
- Rolling updates become a multi-machine coordination problem across the Tailscale mesh

**Prevention:**
- Use the existing `protocol_version` field: bump to `2` for v1.2. The hub checks the version in the `identify` message and sends version-appropriate `task_assign` payloads
- Design all new fields as ADDITIVE (backward compatible): old sidecars ignore unknown fields in `task_assign` (JavaScript naturally handles this), new sidecars receive enrichment data in `metadata.enrichment` rather than top-level fields
- Implement feature detection: the sidecar's `identify` message includes `capabilities` -- add capability strings like `"model_routing"`, `"self_verification"` so the hub knows which sidecars support v1.2 features
- Deploy hub first with backward compatibility, then update sidecars one at a time. The hub should work with a mix of v1 and v2 sidecars simultaneously
- Add a `GET /api/sidecar/version` expectation or include version in the identify response so operators can see which sidecars are updated

**Detection:**
- Some agents executing tasks without model routing while others use it
- Missing verification results for tasks that should have been verified
- Sidecar logs showing `undefined` for new fields
- Hub logs showing unknown message fields from updated sidecars

**Confidence:** HIGH -- directly observed: `protocol_version: 1` is sent by the sidecar but never checked by the hub; `handleTaskAssign` destructures specific fields.

**Phase impact:** Should be addressed in the first phase. Establish the v2 protocol contract before building features on it.

---

## Minor Pitfalls

Mistakes that cause inconvenience, tech debt, or suboptimal behavior.

---

### Pitfall 11: Endpoint Registry DETS Table Adds a 9th Persistence Point

**What goes wrong:** The natural implementation of the LLM endpoint registry uses DETS for persistence (consistent with the rest of the system). This adds a 9th DETS table to the existing 8, increasing backup/compaction surface area, DETS file size monitoring scope, and potential corruption exposure. Each new DETS table is another file that can corrupt on hard crash, another table to compact, another backup target.

**Why it happens:** The system uses DETS for everything persistent. Adding another DETS table follows the established pattern. But the endpoint registry has different persistence characteristics than the task queue or mailbox: endpoint configuration is small (dozens of entries, not thousands), changes infrequently (operator adds/removes endpoints), and can be reconstructed from a config file.

**Prevention:**
- Store endpoint configuration in a JSON/TOML config file, not DETS. The registry loads from config on startup and enriches with runtime health data kept in ETS
- Health state (last check time, current status, loaded models) is ephemeral and belongs in ETS, not DETS. If the hub restarts, health state is rebuilt from fresh checks within 30 seconds
- Only persist endpoint configuration that requires operator action to change: URL, name, model list, capacity limits. Runtime state like health, load, and response time is regenerated

**Detection:**
- DETS backup job taking longer after adding registry table
- Registry corruption blocking task routing (all endpoints appear unhealthy)

**Confidence:** HIGH -- design recommendation based on observed DETS complexity in existing codebase.

**Phase impact:** LLM endpoint registry phase. Use config file + ETS, not another DETS table.

---

### Pitfall 12: Verification Step Timeout Extends Task Duration Beyond Existing Sweeps

**What goes wrong:** Adding self-verification adds 10-60 seconds to every task execution (mechanical checks + LLM verification call). The existing stuck assignment sweep in the scheduler fires at 300 seconds (5 minutes) and the `complete_by` overdue sweep runs every 30 seconds. A task that takes 4 minutes for execution plus 1 minute for verification hits the 5-minute stuck threshold and gets reclaimed while the agent is running verification. The agent then tries to complete a task that has been reclaimed and given to another agent.

**Why it happens:** The stuck sweep threshold was calibrated for v1.0 tasks which had no verification step. The `@stuck_threshold_ms 300_000` in `scheduler.ex` line 51 does not account for the additional time needed for post-execution verification. The generation fencing (TASK-05) catches the stale completion attempt (`{:error, :stale_generation}`), but the task is now duplicated: the new agent is also working on it.

**Prevention:**
- Send `task_progress` messages during verification (the protocol already supports this, and the sidecar already has the code path at line 389-393 of socket.ex). This updates `updated_at`, preventing the stuck sweep from reclaiming
- Add a `verification_in_progress` status to the task lifecycle (not just `assigned` and `working`) so the stuck sweep knows to use a longer threshold for tasks being verified
- Alternatively, increase the default timeout for LLM-routed tasks via a per-task `stuck_threshold_ms` field rather than a global constant
- The sidecar should send progress updates at least once per minute during verification to maintain the heartbeat

**Detection:**
- Tasks being reclaimed during the verification phase
- Duplicate task execution (two agents working on the same task)
- `stale_generation` errors in task completion logs
- Agent utilization metrics showing agents "idle" when they are actually verifying

**Confidence:** HIGH -- directly observed: `@stuck_threshold_ms 300_000` is hardcoded in scheduler.ex, `update_progress` is already available but verification would need to call it.

**Phase impact:** Self-verification phase. Must integrate with existing sweep mechanisms.

---

### Pitfall 13: Trivial Task Execution Bypasses the Entire LLM Pipeline

**What goes wrong:** The "sidecar trivial execution" feature means some tasks (git checkout, file move, status check) run without any LLM call. This creates a second execution path in the sidecar that bypasses the LLM client, verification pipeline, and model routing. Bugs in the trivial path (no progress reporting, no verification, no result formatting) are different from bugs in the LLM path. Testing must cover both paths, and future changes must update both paths.

**Why it happens:** The optimization is sound: why burn LLM tokens on `git checkout main`? But the implementation creates a fork in the execution logic that can diverge. The trivial path needs its own error handling, timeout management, result reporting, and progress heartbeat -- parallel to but different from the LLM path.

**Prevention:**
- Implement trivial execution as a "model" in the routing framework, not as a separate code path. The model router selects `"local_exec"` as the model, and the LLM client has a `local_exec` handler that runs shell commands directly. This keeps the pipeline unified: route -> execute -> verify -> complete, regardless of whether execution involved an LLM
- Even trivial tasks should go through (simplified) verification: did the git command succeed? Is the working directory clean? Did the file actually move?
- Use the same result format for trivial and LLM tasks so the hub does not need to distinguish them

**Detection:**
- Trivial tasks not appearing in metrics (they bypass the instrumented LLM pipeline)
- Trivial task failures not triggering retry logic (different error handling path)
- Inconsistent task result format between trivial and LLM tasks breaking dashboard display

**Confidence:** MEDIUM -- design recommendation based on general software engineering patterns. The specific risk depends on implementation.

**Phase impact:** Sidecar trivial execution phase. Implement as a "null model" in the routing framework.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation | Severity |
|---|---|---|---|
| **Task Format Enrichment** | Breaking existing pipeline (Pitfall 1) | Optional fields with defaults, carry in metadata, migration on startup | Critical |
| **Task Format Enrichment** | DETS schema evolution (old tasks lack new fields) | Backfill migration function, task_version field | Critical |
| **Task Format Enrichment** | Validation schema update rejects old sidecar messages | Update validation LAST, not FIRST | Moderate |
| **LLM Endpoint Registry** | Health check lag vs. cold start (Pitfall 3) | Use /api/ps not /api/tags, keep-alive pings, warm check | Critical |
| **LLM Endpoint Registry** | Synchronous health checks block GenServer (Pitfall 9) | Async tasks + ETS cache | Moderate |
| **LLM Endpoint Registry** | Adding 9th DETS table (Pitfall 11) | Config file + ETS, not DETS | Minor |
| **LLM Endpoint Registry** | Thundering herd on recovery (Pitfall 6) | Capacity tracking, circuit breaker, recovery grace period | Moderate |
| **Model-Aware Scheduling** | Overfitting complexity classifier (Pitfall 2) | Whitelist approach, default to strongest model, explicit hints | Critical |
| **Model-Aware Scheduling** | Breaking the match loop (Pitfall 5) | Routing as pre-enrichment, not inside match loop | Critical |
| **Model-Aware Scheduling** | Stuck sweep reclaims tasks during model loading | Per-task timeout based on model type | Moderate |
| **Sidecar Model Routing** | Complexity explosion (Pitfall 7) | Decompose into modules BEFORE adding LLM features | Critical |
| **Sidecar Model Routing** | Ollama streaming gotchas (Pitfall 8) | Start with stream: false, three-tier timeouts | Critical |
| **Sidecar Model Routing** | Protocol version mismatch (Pitfall 10) | Bump protocol_version, feature detection in capabilities | Moderate |
| **Sidecar Trivial Execution** | Separate code path divergence (Pitfall 13) | Implement as "null model" in routing framework | Minor |
| **Self-Verification** | LLM judging own work (Pitfall 4) | Mechanical checks first, different model for verification | Critical |
| **Self-Verification** | Verification extends task beyond sweep threshold (Pitfall 12) | Progress heartbeat during verification, per-task timeouts | Moderate |
| **Self-Verification** | Verification cost/latency for trivial tasks | Skip semantic verification for trivial tasks, mechanical only | Minor |

---

## Integration Pitfalls (Cross-Cutting)

### Adding features in the wrong order causes compounding problems

**Recommended order and rationale:**

1. **Enriched task format first** -- because every other feature (routing, verification, model assignment) depends on the task carrying enrichment data. Cannot route without complexity_class; cannot verify without verification_steps
2. **Protocol version negotiation second** -- because the sidecar must understand the new task format before receiving enriched tasks. Hub backward compatibility with v1 sidecars established here
3. **LLM endpoint registry third** -- because model-aware routing needs to know what endpoints are available before making routing decisions. Health checking is foundational
4. **Sidecar decomposition fourth** -- restructure sidecar into modules before adding LLM client code. Prevents the 780-line file from becoming a 2500-line file
5. **Sidecar model routing fifth** -- the sidecar can now call Ollama/Claude based on task assignment, using the decomposed module structure
6. **Model-aware scheduler routing sixth** -- the scheduler enriches tasks with model assignments, using endpoint registry data. This is the integration point
7. **Self-verification last** -- because it requires: enriched tasks (success criteria), sidecar LLM client (verification calls), and endpoint registry (model selection for verification). It is the highest-complexity feature with the most dependencies

**Anti-pattern: Adding self-verification before sidecar decomposition.** Verification logic crammed into the monolithic sidecar creates an untestable mess.

**Anti-pattern: Adding model-aware scheduling before the endpoint registry.** The scheduler cannot make routing decisions without knowing what models are available and healthy.

**Anti-pattern: Building a smart complexity classifier on day one.** Without historical task data, any classifier is speculation. Start with explicit hints and a whitelist.

**Anti-pattern: Modifying the scheduler match loop to include routing logic.** The match loop is proven correct. Push routing to the edges (pre-enrichment or sidecar-side).

---

## Codebase-Specific Gotchas Relevant to v1.2

Specific landmines found by reading the AgentCom source code that will affect v1.2 implementation.

| File | Issue | Impact on v1.2 |
|---|---|---|
| `scheduler.ex:163-192` | `try_schedule_all/1` queries `AgentFSM.list_all()` and `TaskQueue.list(status: :queued)` on every event -- adding endpoint registry queries here multiplies the per-event cost | Must cache routing decisions or query endpoint status from ETS, not via GenServer call |
| `scheduler.ex:210-226` | `agent_matches_task?/2` only checks `needed_capabilities` as string subset -- model routing needs a richer capability model | Extend capabilities to include model-access capabilities: `["model:qwen2.5-coder:7b", "model:claude-opus"]` |
| `socket.ex:170-185` | `handle_info({:push_task, task})` builds the `task_assign` payload with hardcoded field list -- new enrichment fields must be added here | Must remain backward compatible; carry enrichment in `metadata` sub-map |
| `task_queue.ex:206-229` | Task map built inline with `Map.get` fallbacks -- no struct, no type enforcement, no migration | Add `task_version` field and default all new fields |
| `sidecar/index.js:506-560` | `handleTaskAssign` destructures `msg.task_id`, `msg.description`, `msg.metadata` -- enrichment fields in `metadata.enrichment` would be backward compatible | Enrichment in metadata.enrichment avoids breaking this code |
| `sidecar/index.js:86-142` | `wakeAgent` has hardcoded retry/timeout logic -- LLM task execution needs completely different timeout semantics | Do not reuse wake logic for LLM calls; build separate execution pipeline |
| `validation/schemas.ex:245-254` | `post_task` schema allows `metadata: :map` -- enrichment fields nested in metadata pass validation without schema changes | Leverage this for backward-compatible enrichment delivery |
| `config.exs` / `test.exs` | All DETS paths are configurable via `Application.get_env` (fixed in v1.1) -- endpoint registry should follow this pattern | Use config for registry, not hardcoded paths |

---

## Sources

- [Ollama FAQ - keep_alive, concurrency, VRAM management](https://docs.ollama.com/faq) -- model loading behavior, parallel request memory multiplication
- [Ollama /api/tags documentation](https://docs.ollama.com/api/tags) -- model listing endpoint format
- [Ollama /api/ps documentation](https://docs.ollama.com/api/ps) -- running model state endpoint
- [Ollama GitHub issue #4350](https://github.com/ollama/ollama/issues/4350) -- configurable model loading timeout
- [Ollama GitHub issue #7685](https://github.com/ollama/ollama/issues/7685) -- streaming behind gateway with timeout
- [Ollama GitHub issue #8699](https://github.com/ollama/ollama/issues/8699) -- custom timeout with API call
- [Ollama GitHub issue #9084](https://github.com/ollama/ollama/issues/9084) -- tools breaking stream=True on /v1 endpoint
- [Ollama GitHub issue #9410](https://github.com/ollama/ollama/issues/9410) -- OLLAMA_KEEP_ALIVE reliability issues
- [RouterEval: Comprehensive Benchmark for LLM Routing](https://aclanthology.org/2025.findings-emnlp.208.pdf) -- routing evaluation methodology
- [When Routing Collapses: Degenerate Convergence of LLM Routers](https://arxiv.org/html/2602.03478) -- routing failure modes
- [Top 5 LLM Routing Techniques (2025)](https://www.getmaxim.ai/articles/top-5-llm-routing-techniques/) -- cascading, heuristic, and ML-based routing patterns
- [LLM Agent Hallucination Survey (2025)](https://arxiv.org/html/2509.18970v1) -- agent-specific hallucination taxonomy
- [Chain-of-Verification (CoVe)](https://learnprompting.org/docs/advanced/self_criticism/chain_of_verification) -- self-verification techniques and limitations
- [HaluGate: Token-Level Hallucination Detection](https://blog.vllm.ai/2025/12/14/halugate.html) -- alternative to LLM-as-judge verification
- [Thundering Herd Problem: Preventing the Stampede](https://distributed-computing-musings.com/2025/08/thundering-herd-problem-preventing-the-stampede/) -- recovery surge patterns
- [ExternalService - Elixir circuit breaker library](https://github.com/jvoegele/external_service) -- circuit breaker pattern for Elixir
- [Fuse - Erlang circuit breaker](https://hex.pm/packages/fuse) -- battle-tested circuit breaker for BEAM
- [Tailscale performance issue #14791](https://github.com/tailscale/tailscale/issues/14791) -- TCP bandwidth problems
- [Tailscale SSH latency issue #17993](https://github.com/tailscale/tailscale/issues/17993) -- high-latency link performance
- Direct codebase analysis: scheduler.ex, task_queue.ex, agent_fsm.ex, socket.ex, validation/schemas.ex, sidecar/index.js reviewed in full

---
*Pitfalls research for: Smart Agent Pipeline v1.2 (LLM mesh routing, model-aware scheduling, agent self-verification)*
*Researched: 2026-02-12*
