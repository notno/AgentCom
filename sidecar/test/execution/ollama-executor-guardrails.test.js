'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { OllamaExecutor } = require('../../lib/execution/ollama-executor');

describe('OllamaExecutor guardrails', () => {
  const executor = new OllamaExecutor();

  // -------------------------------------------------------------------------
  // _getMaxIterations
  // -------------------------------------------------------------------------

  describe('_getMaxIterations', () => {
    it('returns 5 for trivial tier', () => {
      const task = { complexity: { effective_tier: 'trivial' } };
      assert.strictEqual(executor._getMaxIterations(task), 5);
    });

    it('returns 10 for standard tier', () => {
      const task = { complexity: { effective_tier: 'standard' } };
      assert.strictEqual(executor._getMaxIterations(task), 10);
    });

    it('returns 20 for complex tier', () => {
      const task = { complexity: { effective_tier: 'complex' } };
      assert.strictEqual(executor._getMaxIterations(task), 20);
    });

    it('returns 10 for missing complexity tier (default)', () => {
      const task = {};
      assert.strictEqual(executor._getMaxIterations(task), 10);
    });

    it('returns 10 for null complexity', () => {
      const task = { complexity: null };
      assert.strictEqual(executor._getMaxIterations(task), 10);
    });

    it('returns 10 for unknown tier', () => {
      const task = { complexity: { effective_tier: 'impossible' } };
      assert.strictEqual(executor._getMaxIterations(task), 10);
    });

    it('uses _agentic_max_iterations override when present', () => {
      const task = {
        complexity: { effective_tier: 'trivial' },
        _agentic_max_iterations: 15
      };
      assert.strictEqual(executor._getMaxIterations(task), 15);
    });

    it('override takes precedence over tier', () => {
      const task = {
        complexity: { effective_tier: 'complex' },
        _agentic_max_iterations: 3
      };
      assert.strictEqual(executor._getMaxIterations(task), 3);
    });
  });

  // -------------------------------------------------------------------------
  // _isRepetition
  // -------------------------------------------------------------------------

  describe('_isRepetition', () => {
    it('returns false when history has fewer than threshold entries', () => {
      const history = [
        [{ name: 'read_file', arguments: { path: 'a.js' } }],
        [{ name: 'read_file', arguments: { path: 'a.js' } }]
      ];
      const newCalls = [{ name: 'read_file', arguments: { path: 'a.js' } }];
      assert.strictEqual(executor._isRepetition(history, newCalls), false);
    });

    it('returns false when calls are different each time', () => {
      const history = [
        [{ name: 'read_file', arguments: { path: 'a.js' } }],
        [{ name: 'write_file', arguments: { path: 'b.js', content: 'x' } }],
        [{ name: 'run_command', arguments: { command: 'ls' } }]
      ];
      const newCalls = [{ name: 'run_command', arguments: { command: 'ls' } }];
      assert.strictEqual(executor._isRepetition(history, newCalls), false);
    });

    it('returns true when last 3 iterations have identical tool+args', () => {
      const calls = [{ name: 'read_file', arguments: { path: 'a.js' } }];
      const history = [calls, calls, calls];
      assert.strictEqual(executor._isRepetition(history, calls), true);
    });

    it('returns true when last 3 iterations have identical multi-tool calls', () => {
      const calls = [
        { name: 'read_file', arguments: { path: 'a.js' } },
        { name: 'write_file', arguments: { path: 'b.js', content: 'hello' } }
      ];
      const history = [calls, calls, calls];
      assert.strictEqual(executor._isRepetition(history, calls), true);
    });

    it('handles empty calls array', () => {
      const history = [[], [], []];
      const newCalls = [];
      assert.strictEqual(executor._isRepetition(history, newCalls), true);
    });

    it('returns false for mixed history even if last few match', () => {
      const callA = [{ name: 'read_file', arguments: { path: 'a.js' } }];
      const callB = [{ name: 'write_file', arguments: { path: 'b.js', content: 'x' } }];
      // history: B, A, A, A -- only last 3 match
      const history = [callB, callA, callA, callA];
      assert.strictEqual(executor._isRepetition(history, callA), true);
    });

    it('respects custom threshold', () => {
      const calls = [{ name: 'read_file', arguments: { path: 'a.js' } }];
      const history = [calls, calls];
      // Default threshold=3 should be false
      assert.strictEqual(executor._isRepetition(history, calls, 3), false);
      // Custom threshold=2 should be true
      assert.strictEqual(executor._isRepetition(history, calls, 2), true);
    });

    it('distinguishes different arguments for same tool', () => {
      const callA = [{ name: 'read_file', arguments: { path: 'a.js' } }];
      const callB = [{ name: 'read_file', arguments: { path: 'b.js' } }];
      const history = [callA, callB, callA];
      assert.strictEqual(executor._isRepetition(history, callA), false);
    });
  });

  // -------------------------------------------------------------------------
  // Result format validation
  // -------------------------------------------------------------------------

  describe('result format', () => {
    it('executor instance has expected methods', () => {
      assert.strictEqual(typeof executor._agenticLoop, 'function');
      assert.strictEqual(typeof executor._chatOnce, 'function');
      assert.strictEqual(typeof executor._getMaxIterations, 'function');
      assert.strictEqual(typeof executor._isRepetition, 'function');
      assert.strictEqual(typeof executor._streamChat, 'function');
      assert.strictEqual(typeof executor._buildMessages, 'function');
      assert.strictEqual(typeof executor.execute, 'function');
    });
  });
});
