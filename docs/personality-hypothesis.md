# Hypothesis: Cognitive Diversity in Multi-Agent Systems

## Core Hypothesis

**Assigning distinct working-style personalities to LLM agents in a collaborative team produces higher quality code and more robust systems than homogeneous agents, as measured by defect rate, edge case coverage, and design diversity.**

## Falsifiable Predictions

### Prediction 1: Defect Detection in Code Review

**Claim:** A team of personality-diverse agents will catch more defects in code review than a team of identical agents reviewing the same PRs.

**Test:** Take 10 PRs with known planted defects (off-by-one errors, missing error handling, race conditions, API misuse). Have two teams review them:
- Team A: 3 agents with identical default SOUL.md
- Team B: 3 agents with our personality profiles (pragmatist, systems-thinker, experimentalist)

**Measure:** Number of planted defects caught per team. Categorize by defect type.

**Falsified if:** Team A catches equal or more defects than Team B across 10 PRs.

**Expected result:** Team B catches more, specifically because GCU-style (systems-thinker) catches error handling and edge cases that others miss, while Loash-style (pragmatist) flags unnecessary complexity that could hide bugs.

### Prediction 2: Solution Diversity

**Claim:** When given the same design problem, personality-diverse agents propose meaningfully different solutions, while homogeneous agents converge on the same approach.

**Test:** Give both teams the same 5 design problems (e.g., "design a rate limiter," "design a message retry system"). Each agent works independently, no collaboration.

**Measure:** Cosine similarity between solution approaches within each team (lower = more diverse). Categorize solutions by architectural pattern chosen.

**Falsified if:** Team A produces solutions with equal or greater diversity than Team B.

**Expected result:** Team B produces more diverse solutions. The pragmatist picks the simplest approach, the systems-thinker designs for failure modes first, the experimentalist proposes something testable/measurable. Team A converges on the "default good" approach 80%+ of the time.

### Prediction 3: Edge Case Coverage

**Claim:** Code written by a systems-thinker personality handles more edge cases than code written by a pragmatist personality, but the pragmatist ships faster.

**Test:** Give the same 5 implementation tasks to a GCU-style agent and a Loash-style agent independently. Compare the outputs.

**Measure:** 
- Edge cases handled (null inputs, empty collections, network failures, concurrent access, malformed data)
- Time to completion (tokens used as proxy)
- Lines of code

**Falsified if:** The pragmatist handles equal or more edge cases, OR the systems-thinker ships in equal or fewer tokens.

**Expected result:** GCU-style handles 40-60% more edge cases. Loash-style completes in 30-50% fewer tokens. Neither is strictly better — the combination in a review cycle is better than either alone.

### Prediction 4: The Critique Loop Improves with Diversity

**Claim:** A draft-review cycle between agents with different personalities produces better output than a cycle between identical agents.

**Test:** Run Experiment 4 (Critique Loop) from our collaboration experiments doc with two configurations:
- Config A: Identical agents drafting and reviewing
- Config B: Pragmatist drafts, systems-thinker reviews (or vice versa)

**Measure:** Quality of final output (graded by Nathan on 1-5 scale for correctness, completeness, robustness). Total tokens consumed.

**Falsified if:** Config A produces equal or higher quality output at equal or lower token cost.

**Expected result:** Config B produces higher quality because the reviewer catches different classes of issues than the drafter would self-catch. A pragmatist who reviews their own code misses the same edge cases they missed writing it. A systems-thinker reviewing a pragmatist's code catches them.

### Prediction 5: Personality Persistence

**Claim:** The personality differences in SOUL.md actually manifest in measurable behavioral differences, and aren't washed out by the base model's defaults.

**Test:** Give all three personality-typed agents the same prompt: "Review this code and list your top 3 concerns." Use 10 different code samples.

**Measure:** Categorize each concern as:
- Correctness (bugs, logic errors)
- Robustness (error handling, edge cases, failure modes)
- Simplicity (unnecessary complexity, overengineering)
- Performance (efficiency, scalability)
- Maintainability (code structure, naming, patterns)

**Falsified if:** The distribution of concern categories is statistically identical across all three agents (chi-square test, p > 0.05).

**Expected result:** GCU-style skews toward robustness concerns. Loash-style skews toward simplicity concerns. Skaffen-style skews toward maintainability concerns. Each has a measurably different profile.

## Control Variables

Across all experiments:
- Same base model (Claude Opus 4.6) for all agents
- Same temperature settings
- Same system prompt except for the personality section
- Randomized order of tasks to control for context effects
- Multiple runs per condition to measure variance

## Why This Matters

If personality diversity is just cosmetic — making agents sound different without thinking differently — it's a waste of SOUL.md tokens. We should know that.

If it's real, it means:
1. Multi-agent teams should be deliberately composed for cognitive diversity
2. The specific personality assignments matter and should be tuned
3. Token cost of personality context in SOUL.md pays for itself in quality
4. Homogeneous agent swarms (same prompt, different tasks) leave value on the table

## Minimum Viable Test

If we only run one experiment, run **Prediction 5** first. It tests the fundamental assumption: do these personality additions actually change behavior? If they don't, everything else is moot.

Second priority: **Prediction 1** (defect detection). It has the clearest practical impact.
