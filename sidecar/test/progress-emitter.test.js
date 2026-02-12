'use strict';

const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');
const { ProgressEmitter } = require('../lib/execution/progress-emitter');

describe('ProgressEmitter', () => {
  let emitter;
  let flushed;

  beforeEach(() => {
    flushed = [];
  });

  afterEach(() => {
    if (emitter) {
      emitter.destroy();
      emitter = null;
    }
  });

  it('emits single token event immediately if no pending batch', () => {
    emitter = new ProgressEmitter((events) => flushed.push(...events), { batchIntervalMs: 100 });
    emitter.emit({ type: 'token', text: 'hello', tokens_so_far: 1 });
    // First token should flush immediately (no pending batch)
    assert.strictEqual(flushed.length, 1);
    assert.strictEqual(flushed[0].text, 'hello');
    assert.strictEqual(flushed[0].tokens_so_far, 1);
  });

  it('batches multiple rapid token events within 100ms window', async () => {
    emitter = new ProgressEmitter((events) => flushed.push(...events), { batchIntervalMs: 100 });

    // First token flushes immediately
    emitter.emit({ type: 'token', text: 'a', tokens_so_far: 1 });
    assert.strictEqual(flushed.length, 1);

    // Subsequent tokens within the window are batched
    emitter.emit({ type: 'token', text: 'b', tokens_so_far: 2 });
    emitter.emit({ type: 'token', text: 'c', tokens_so_far: 3 });
    assert.strictEqual(flushed.length, 1); // Still only the first flush

    // Wait for batch interval to flush
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.strictEqual(flushed.length, 2);
    assert.strictEqual(flushed[1].text, 'bc');
    assert.strictEqual(flushed[1].tokens_so_far, 3);
  });

  it('flushes status events immediately (never batched)', () => {
    emitter = new ProgressEmitter((events) => flushed.push(...events), { batchIntervalMs: 100 });
    emitter.emit({ type: 'status', message: 'Ollama retry 1/2...' });
    assert.strictEqual(flushed.length, 1);
    assert.strictEqual(flushed[0].type, 'status');
    assert.strictEqual(flushed[0].message, 'Ollama retry 1/2...');
  });

  it('flushes stdout events immediately (never batched)', () => {
    emitter = new ProgressEmitter((events) => flushed.push(...events), { batchIntervalMs: 100 });
    emitter.emit({ type: 'stdout', text: 'line1\n' });
    assert.strictEqual(flushed.length, 1);
    assert.strictEqual(flushed[0].type, 'stdout');
    assert.strictEqual(flushed[0].text, 'line1\n');
  });

  it('flushes error events immediately (never batched)', () => {
    emitter = new ProgressEmitter((events) => flushed.push(...events), { batchIntervalMs: 100 });
    emitter.emit({ type: 'error', message: 'something broke' });
    assert.strictEqual(flushed.length, 1);
    assert.strictEqual(flushed[0].type, 'error');
  });

  it('flush() sends accumulated tokens immediately', async () => {
    emitter = new ProgressEmitter((events) => flushed.push(...events), { batchIntervalMs: 100 });

    // First token flushes immediately
    emitter.emit({ type: 'token', text: 'a', tokens_so_far: 1 });
    // Second token is buffered
    emitter.emit({ type: 'token', text: 'b', tokens_so_far: 2 });
    assert.strictEqual(flushed.length, 1);

    // Manual flush sends buffered tokens
    emitter.flush();
    assert.strictEqual(flushed.length, 2);
    assert.strictEqual(flushed[1].text, 'b');
    assert.strictEqual(flushed[1].tokens_so_far, 2);
  });

  it('destroy() flushes remaining and clears interval', () => {
    emitter = new ProgressEmitter((events) => flushed.push(...events), { batchIntervalMs: 100 });

    emitter.emit({ type: 'token', text: 'first', tokens_so_far: 1 });
    emitter.emit({ type: 'token', text: 'second', tokens_so_far: 2 });

    emitter.destroy();
    // Should have flushed: first immediately + second on destroy
    assert.strictEqual(flushed.length, 2);
    assert.strictEqual(flushed[1].text, 'second');
    emitter = null; // Already destroyed
  });

  it('token batching accumulates text and updates tokens_so_far to latest', async () => {
    emitter = new ProgressEmitter((events) => flushed.push(...events), { batchIntervalMs: 100 });

    emitter.emit({ type: 'token', text: 'Hello', tokens_so_far: 5 });
    emitter.emit({ type: 'token', text: ' world', tokens_so_far: 7 });
    emitter.emit({ type: 'token', text: '!', tokens_so_far: 8 });

    // First flushes immediately, rest batched
    assert.strictEqual(flushed.length, 1);
    assert.strictEqual(flushed[0].text, 'Hello');

    emitter.flush();
    assert.strictEqual(flushed.length, 2);
    assert.strictEqual(flushed[1].text, ' world!');
    assert.strictEqual(flushed[1].tokens_so_far, 8); // Latest value
  });
});
