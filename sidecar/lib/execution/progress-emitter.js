'use strict';

/**
 * ProgressEmitter -- batches high-frequency token events into 100ms
 * windows to prevent WebSocket backpressure (research pitfall #6).
 *
 * Only `type: 'token'` events are batched.  All other event types
 * (status, error, stdout, stderr) flush immediately because they
 * represent discrete state changes.
 */

class ProgressEmitter {
  /**
   * @param {function} onFlush - Callback receiving an array of events to send
   * @param {object}   opts
   * @param {number}   opts.batchIntervalMs - Batch window in ms (default 100)
   */
  constructor(onFlush, { batchIntervalMs = 100 } = {}) {
    this._onFlush = onFlush;
    this._batchIntervalMs = batchIntervalMs;

    // Token batching state
    this._tokenBuffer = '';
    this._tokensSoFar = 0;
    this._hasPendingTokens = false;
    this._batchTimer = null;
    this._destroyed = false;
  }

  /**
   * Emit an event.  Token events are batched; all others flush immediately.
   * @param {object} event - Event object with at least a `type` field
   */
  emit(event) {
    if (this._destroyed) return;

    if (event.type === 'token') {
      this._handleToken(event);
    } else {
      // Non-token events bypass batching entirely
      this._onFlush([event]);
    }
  }

  /**
   * Manually flush any accumulated token buffer immediately.
   */
  flush() {
    if (this._hasPendingTokens) {
      this._flushTokenBuffer();
    }
  }

  /**
   * Flush remaining tokens, clear timers, mark as destroyed.
   */
  destroy() {
    if (this._destroyed) return;
    this._destroyed = true;

    this.flush();

    if (this._batchTimer !== null) {
      clearInterval(this._batchTimer);
      this._batchTimer = null;
    }
  }

  // --- Internal ---

  _handleToken(event) {
    if (!this._hasPendingTokens) {
      // First token since last flush -- emit immediately and start batch window
      this._onFlush([event]);
      this._startBatchWindow();
    } else {
      // Accumulate into buffer
      this._tokenBuffer += (event.text || '');
      this._tokensSoFar = event.tokens_so_far;
    }
  }

  _startBatchWindow() {
    this._hasPendingTokens = true;
    this._tokenBuffer = '';
    this._tokensSoFar = 0;

    if (this._batchTimer === null) {
      this._batchTimer = setInterval(() => {
        if (this._tokenBuffer.length > 0) {
          this._flushTokenBuffer();
        }
      }, this._batchIntervalMs);
    }
  }

  _flushTokenBuffer() {
    if (this._tokenBuffer.length === 0) {
      return;
    }

    const event = {
      type: 'token',
      text: this._tokenBuffer,
      tokens_so_far: this._tokensSoFar,
    };

    this._tokenBuffer = '';
    this._tokensSoFar = 0;
    this._onFlush([event]);
  }
}

module.exports = { ProgressEmitter };
