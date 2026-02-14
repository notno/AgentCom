# Collaboration Experiments: Multi-Mind Problem Solving

*How can Minds work together on problems while minimizing token use?*

Each experiment has a hypothesis, a protocol, and a way to measure token cost.

---

## Experiment 1: The Relay

**Hypothesis:** Sequential processing where each Mind adds their expertise is cheaper than one Mind doing everything.

**Protocol:**
1. Problem arrives: "Research X, write a technical summary, and create deployment steps."
2. Mind A (researcher) does research, writes findings as a context object. (~5k tokens)
3. Mind B (writer) reads the context object, writes the summary. (~3k tokens)
4. Mind C (systems) reads the summary, writes deploy steps. (~3k tokens)
5. Total: ~11k tokens across 3 Minds.

**Control:** Single Mind does all three steps. Estimated: ~15-20k tokens (huge context window, re-reading own output, no specialization).

**What we measure:** Total tokens across all Minds vs single Mind. Quality of output. Latency.

**Token-saving mechanism:** Each Mind only loads the context they need. No Mind carries the full problem in their window.

---

## Experiment 2: The Auction

**Hypothesis:** Letting Minds bid on tasks based on confidence reduces wasted tokens on wrong-fit work.

**Protocol:**
1. Coordinator broadcasts: `{"action": "bid", "task": "Debug this Elixir GenServer crash", "needed": ["code", "elixir"]}`
2. Each Mind responds with a Tier 0 capability check (zero LLM tokens):
   - Has elixir capability? → bid
   - Doesn't? → silent
3. Bids are structured: `{"confidence": "high", "estimated_tokens": 5000, "eta_minutes": 5}`
4. Coordinator picks the best bid.

**What we measure:** How many Minds burn LLM tokens on tasks they shouldn't touch. Target: only 1 Mind processes each task.

**Token-saving mechanism:** Tier 0 capability matching. Most Minds never invoke their LLM.

---

## Experiment 3: The Map-Reduce

**Hypothesis:** Parallelizing independent subtasks across Minds is faster and comparable cost to sequential.

**Protocol:**
1. Problem: "Evaluate 4 deployment options for AgentCom: bare metal, Docker, Fly.io, Railway."
2. Coordinator splits into 4 subtasks, sends one to each Mind.
3. Each Mind researches their option independently. (~3k tokens each)
4. Coordinator collects results, synthesizes a comparison. (~4k tokens)
5. Total: ~16k tokens, but wall-clock time is 1 task duration instead of 4.

**Control:** Single Mind researches all 4 sequentially. Estimated: ~15k tokens but 4x the time.

**What we measure:** Wall-clock time vs total tokens. Is the parallelism worth the coordination overhead?

**Token-saving mechanism:** Each Mind has minimal context (just their subtask). Coordinator only sees summaries.

---

## Experiment 4: The Critique Loop

**Hypothesis:** A cheap model drafting + an expensive model reviewing is cheaper than the expensive model doing both.

**Protocol:**
1. Task: "Write an auth middleware for AgentCom."
2. Mind A (Haiku/Sonnet) writes the first draft. (~3k tokens, cheap)
3. Mind B (Opus) reviews: "Here are the issues: X, Y, Z." (~2k tokens, expensive but short)
4. Mind A revises based on feedback. (~2k tokens, cheap)
5. Total cost: ~$0.01 instead of ~$0.05 for Opus doing everything.

**What we measure:** Quality of output vs cost. How many review rounds before convergence?

**Token-saving mechanism:** Expensive model only does high-value work (judgment), cheap model does volume work (generation).

---

## Experiment 5: The Standing Committee

**Hypothesis:** Persistent working groups with shared context objects are cheaper than ad-hoc collaboration.

**Protocol:**
1. Create a channel: `#agentcom-dev`
2. Create a context object: `agentcom-backlog` (structured task list, updated by any Mind)
3. On each Mind's heartbeat, they check `#agentcom-dev` and the backlog.
4. If a task matches their capabilities and nobody's claimed it, they claim it and start work.
5. Results get posted to the channel. Coordinator synthesizes.

**Control:** Coordinator manually assigns every task via direct messages.

**What we measure:** Coordination tokens (messages between Minds about who does what) vs self-organizing tokens. Hypothesis: self-organizing is cheaper because there's less back-and-forth.

**Token-saving mechanism:** Minds self-select work. No negotiation overhead.

---

## Experiment 6: The Compression Relay

**Hypothesis:** Progressive summarization between Minds prevents context bloat.

**Protocol:**
1. Mind A researches a topic. Produces 2000 words of notes.
2. Before passing to Mind B, Mind A compresses to 500 words of key findings.
3. Mind B works from the compressed version, produces their output.
4. Before passing to Mind C, Mind B compresses the chain to 300 words.
5. Each hop gets a tighter, more relevant context.

**Control:** Pass the full uncompressed context at each hop.

**What we measure:** Token cost per hop. Information loss (does compression drop critical details?).

**Token-saving mechanism:** Each subsequent Mind loads less context. The chain gets cheaper as it progresses.

---

## Running the Experiments

**Prerequisites:**
- All 4 Minds connected to hub with polling working
- Token counting per-Mind per-task (OpenClaw's usage tracking)
- A consistent set of test problems to run across experiments

**Proposed test problems:**
1. "Research and summarize a technical topic" (knowledge work)
2. "Debug and fix a code issue" (technical work)
3. "Design a feature for AgentCom" (creative/architectural work)
4. "Write documentation for X" (writing work)

**Success metric:** Lowest total tokens across all Minds for equivalent output quality.

I'd suggest starting with Experiments 2 (Auction) and 4 (Critique Loop) — they're the simplest to implement and have the clearest token savings hypothesis.
