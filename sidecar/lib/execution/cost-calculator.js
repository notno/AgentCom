'use strict';

/**
 * Cost calculator for LLM task execution.
 *
 * Prices Claude API calls in USD and computes equivalent Claude cost
 * for local Ollama tasks (showing savings).  All prices are per-million
 * tokens.  Ollama models always cost $0; the equivalent field uses the
 * Sonnet baseline so the dashboard can display "you saved $X".
 */

const COST_TABLE = {
  'claude-sonnet-4.5':  { input: 3.00,  output: 15.00 },
  'claude-opus-4.5':    { input: 5.00,  output: 25.00 },
  'claude-haiku-4.5':   { input: 1.00,  output: 5.00  },
  'claude-opus-4.6':    { input: 5.00,  output: 25.00 },
  '_claude_equivalent':  { input: 3.00,  output: 15.00 }, // Sonnet baseline for savings comparison
};

/**
 * Find a cost entry by exact match first, then prefix match.
 * Prefix match handles model variants like "claude-sonnet-4.5:latest".
 * Returns null for unknown / Ollama models.
 */
function findCostEntry(model) {
  if (!model) return null;

  // Exact match
  if (COST_TABLE[model]) return COST_TABLE[model];

  // Prefix match (e.g. "claude-sonnet-4.5:latest" matches "claude-sonnet-4.5")
  for (const key of Object.keys(COST_TABLE)) {
    if (key.startsWith('_')) continue; // skip internal entries
    if (model.startsWith(key)) return COST_TABLE[key];
  }

  return null;
}

/**
 * Calculate cost for a single LLM task.
 *
 * @param {string|null} model   - Model identifier (e.g. "claude-sonnet-4.5", "llama3.2:latest")
 * @param {number}      tokensIn  - Input token count
 * @param {number}      tokensOut - Output token count
 * @returns {{ cost_usd: number, equivalent_claude_cost_usd: number|null }}
 */
function calculateCost(model, tokensIn, tokensOut) {
  const entry = findCostEntry(model);

  if (entry) {
    // Known Claude model -- compute actual cost
    const cost_usd = (entry.input / 1_000_000) * tokensIn
                   + (entry.output / 1_000_000) * tokensOut;
    return { cost_usd, equivalent_claude_cost_usd: null };
  }

  // Unknown model (Ollama / local) -- $0 actual cost
  const totalTokens = tokensIn + tokensOut;
  if (totalTokens === 0) {
    return { cost_usd: 0, equivalent_claude_cost_usd: null };
  }

  // Compute equivalent Claude cost using Sonnet baseline
  const equiv = COST_TABLE['_claude_equivalent'];
  const equivalent_claude_cost_usd = (equiv.input / 1_000_000) * tokensIn
                                   + (equiv.output / 1_000_000) * tokensOut;

  return { cost_usd: 0, equivalent_claude_cost_usd };
}

module.exports = { calculateCost, COST_TABLE };
