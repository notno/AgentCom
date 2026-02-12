'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { calculateCost, COST_TABLE } = require('../lib/execution/cost-calculator');

describe('Cost Calculator', () => {
  describe('COST_TABLE', () => {
    it('includes all Claude model entries', () => {
      const expectedModels = [
        'claude-sonnet-4.5',
        'claude-opus-4.5',
        'claude-haiku-4.5',
        'claude-opus-4.6',
        '_claude_equivalent',
      ];
      for (const model of expectedModels) {
        assert.ok(COST_TABLE[model], `COST_TABLE missing entry for ${model}`);
        assert.strictEqual(typeof COST_TABLE[model].input, 'number');
        assert.strictEqual(typeof COST_TABLE[model].output, 'number');
      }
    });
  });

  describe('calculateCost', () => {
    it('returns correct cost for claude-sonnet-4.5', () => {
      const result = calculateCost('claude-sonnet-4.5', 1000, 500);
      // 3.00/M * 1000 + 15.00/M * 500 = 0.003 + 0.0075 = 0.0105
      assert.strictEqual(result.cost_usd, 0.0105);
      assert.strictEqual(result.equivalent_claude_cost_usd, null);
    });

    it('returns correct cost for claude-opus-4.6', () => {
      const result = calculateCost('claude-opus-4.6', 1000, 500);
      // 5.00/M * 1000 + 25.00/M * 500 = 0.005 + 0.0125 = 0.0175
      assert.strictEqual(result.cost_usd, 0.0175);
      assert.strictEqual(result.equivalent_claude_cost_usd, null);
    });

    it('returns $0 cost for Ollama models with equivalent Claude cost', () => {
      const result = calculateCost('llama3.2:latest', 1000, 500);
      assert.strictEqual(result.cost_usd, 0);
      // equivalent uses _claude_equivalent (Sonnet baseline): 3.00/M * 1000 + 15.00/M * 500 = 0.0105
      assert.strictEqual(result.equivalent_claude_cost_usd, 0.0105);
    });

    it('returns $0 for trivial task with no tokens', () => {
      const result = calculateCost('none', 0, 0);
      assert.strictEqual(result.cost_usd, 0);
      assert.strictEqual(result.equivalent_claude_cost_usd, null);
    });

    it('handles null model edge case', () => {
      const result = calculateCost(null, 0, 0);
      assert.strictEqual(result.cost_usd, 0);
      assert.strictEqual(result.equivalent_claude_cost_usd, null);
    });

    it('prefix-matches model variants with tags', () => {
      const result = calculateCost('claude-sonnet-4.5:latest', 1000, 0);
      // 3.00/M * 1000 = 0.003
      assert.strictEqual(result.cost_usd, 0.003);
      assert.strictEqual(result.equivalent_claude_cost_usd, null);
    });

    it('returns $0 equivalent for Ollama model with zero tokens', () => {
      const result = calculateCost('llama3.2:latest', 0, 0);
      assert.strictEqual(result.cost_usd, 0);
      // No tokens means no equivalent cost
      assert.strictEqual(result.equivalent_claude_cost_usd, null);
    });
  });
});
