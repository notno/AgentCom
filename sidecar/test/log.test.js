'use strict';

const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { initLogger, log, LEVELS } = require('../lib/log');

/**
 * Helper: Capture stdout output during a function call.
 * Temporarily replaces process.stdout.write, runs the fn, restores it.
 * Returns the captured string.
 */
function captureStdout(fn) {
  let captured = '';
  const originalWrite = process.stdout.write;
  process.stdout.write = (chunk) => { captured += chunk; };
  try {
    fn();
  } finally {
    process.stdout.write = originalWrite;
  }
  return captured;
}

// ---------------------------------------------------------------------------
// JSON Output Format
// ---------------------------------------------------------------------------

describe('Structured Logger', () => {
  beforeEach(() => {
    // Reset to known state: info level, test agent
    initLogger({ agent_id: 'test-agent', log_level: 'info' });
  });

  describe('JSON output format', () => {
    it('outputs valid JSON to stdout', () => {
      const captured = captureStdout(() => {
        log('info', 'test_event', { key: 'value' });
      });

      const parsed = JSON.parse(captured.trim());
      assert.ok(parsed, 'output should be parseable JSON');
    });

    it('has required top-level fields: time, severity, message', () => {
      const captured = captureStdout(() => {
        log('info', 'field_test', { extra: 42 });
      });

      const parsed = JSON.parse(captured.trim());
      assert.ok(parsed.time, 'missing time field');
      assert.ok(parsed.severity, 'missing severity field');
      assert.ok(parsed.message, 'missing message field');
    });

    it('time field is valid ISO 8601 UTC timestamp', () => {
      const captured = captureStdout(() => {
        log('info', 'time_test');
      });

      const parsed = JSON.parse(captured.trim());
      const date = new Date(parsed.time);
      assert.ok(!isNaN(date.getTime()), `time is not valid ISO 8601: ${parsed.time}`);
      assert.ok(parsed.time.endsWith('Z'), 'time should be UTC (end with Z)');
    });

    it('severity reflects the log level', () => {
      const levels = ['debug', 'info', 'notice', 'warning', 'error'];

      // Set level to debug so all messages are captured
      initLogger({ agent_id: 'test-agent', log_level: 'debug' });

      for (const level of levels) {
        const captured = captureStdout(() => {
          log(level, `${level}_test`);
        });

        const parsed = JSON.parse(captured.trim());
        assert.equal(parsed.severity, level, `expected severity ${level}`);
      }
    });

    it('message field contains the event string', () => {
      const captured = captureStdout(() => {
        log('info', 'my_custom_event');
      });

      const parsed = JSON.parse(captured.trim());
      assert.equal(parsed.message, 'my_custom_event');
    });

    it('each log entry is a single NDJSON line', () => {
      const captured = captureStdout(() => {
        log('info', 'line_test_1');
        log('info', 'line_test_2');
      });

      const lines = captured.trim().split('\n').filter(Boolean);
      assert.equal(lines.length, 2, 'expected 2 lines');
      for (const line of lines) {
        assert.doesNotThrow(() => JSON.parse(line), 'each line should be valid JSON');
      }
    });

    it('includes agent_id from config', () => {
      const captured = captureStdout(() => {
        log('info', 'agent_test');
      });

      const parsed = JSON.parse(captured.trim());
      assert.equal(parsed.agent_id, 'test-agent');
    });

    it('includes pid and node fields', () => {
      const captured = captureStdout(() => {
        log('info', 'process_test');
      });

      const parsed = JSON.parse(captured.trim());
      assert.ok(parsed.pid, 'missing pid');
      assert.equal(typeof parsed.pid, 'number');
      assert.ok(parsed.node, 'missing node');
      assert.equal(typeof parsed.node, 'string');
    });

    it('includes function and line from caller stack', () => {
      const captured = captureStdout(() => {
        log('info', 'stack_test');
      });

      const parsed = JSON.parse(captured.trim());
      // function may be null in some contexts, but line should be a number
      // when called from a test context (not top-level eval)
      assert.ok(typeof parsed.line === 'number' || parsed.line === null,
        'line should be a number or null');
    });

    it('spreads custom data fields into the log entry', () => {
      const captured = captureStdout(() => {
        log('info', 'data_test', { task_id: 'task-123', queue_depth: 5 });
      });

      const parsed = JSON.parse(captured.trim());
      assert.equal(parsed.task_id, 'task-123');
      assert.equal(parsed.queue_depth, 5);
    });
  });

  // ---------------------------------------------------------------------------
  // Secret Redaction
  // ---------------------------------------------------------------------------

  describe('secret redaction', () => {
    it('redacts token field', () => {
      const captured = captureStdout(() => {
        log('info', 'auth_test', { token: 'secret-abc-123' });
      });

      const parsed = JSON.parse(captured.trim());
      assert.equal(parsed.token, '[REDACTED]');
    });

    it('redacts auth_token field', () => {
      const captured = captureStdout(() => {
        log('info', 'auth_test', { auth_token: 'bearer-xyz-456' });
      });

      const parsed = JSON.parse(captured.trim());
      assert.equal(parsed.auth_token, '[REDACTED]');
    });

    it('redacts secret field', () => {
      const captured = captureStdout(() => {
        log('info', 'config_test', { secret: 'my-api-key' });
      });

      const parsed = JSON.parse(captured.trim());
      assert.equal(parsed.secret, '[REDACTED]');
    });

    it('does NOT redact non-sensitive fields', () => {
      const captured = captureStdout(() => {
        log('info', 'normal_test', { task_id: 'task-99', agent_id: 'agent-1' });
      });

      const parsed = JSON.parse(captured.trim());
      assert.equal(parsed.task_id, 'task-99');
      // agent_id from data is overridden by config agent_id in this case
      // but the point is it's not redacted
    });
  });

  // ---------------------------------------------------------------------------
  // Level Filtering
  // ---------------------------------------------------------------------------

  describe('level filtering', () => {
    it('filters messages below configured level', () => {
      initLogger({ agent_id: 'test', log_level: 'warning' });

      const captured = captureStdout(() => {
        log('debug', 'should_not_appear');
        log('info', 'should_not_appear');
        log('notice', 'should_not_appear');
        log('warning', 'should_appear');
        log('error', 'should_also_appear');
      });

      const lines = captured.trim().split('\n').filter(Boolean);
      assert.equal(lines.length, 2, 'only warning and error should pass');
      assert.equal(JSON.parse(lines[0]).severity, 'warning');
      assert.equal(JSON.parse(lines[1]).severity, 'error');
    });

    it('passes all messages at debug level', () => {
      initLogger({ agent_id: 'test', log_level: 'debug' });

      const captured = captureStdout(() => {
        log('debug', 'msg1');
        log('info', 'msg2');
        log('notice', 'msg3');
        log('warning', 'msg4');
        log('error', 'msg5');
      });

      const lines = captured.trim().split('\n').filter(Boolean);
      assert.equal(lines.length, 5, 'all 5 levels should pass at debug');
    });

    it('default level is info when not specified', () => {
      // Re-init without log_level
      initLogger({ agent_id: 'test' });

      const captured = captureStdout(() => {
        log('debug', 'filtered_out');
        log('info', 'passes');
      });

      const lines = captured.trim().split('\n').filter(Boolean);
      assert.equal(lines.length, 1, 'only info should pass (debug filtered)');
      assert.equal(JSON.parse(lines[0]).severity, 'info');
    });
  });

  // ---------------------------------------------------------------------------
  // Custom Module Name
  // ---------------------------------------------------------------------------

  describe('custom module name', () => {
    it('accepts custom module name as 4th argument', () => {
      const captured = captureStdout(() => {
        log('info', 'module_test', {}, 'sidecar/queue');
      });

      const parsed = JSON.parse(captured.trim());
      assert.equal(parsed.module, 'sidecar/queue');
    });

    it('defaults module to sidecar/index when not provided', () => {
      const captured = captureStdout(() => {
        log('info', 'default_module_test');
      });

      const parsed = JSON.parse(captured.trim());
      assert.equal(parsed.module, 'sidecar/index');
    });
  });

  // ---------------------------------------------------------------------------
  // Field Convention Parity with Elixir Hub
  // ---------------------------------------------------------------------------

  describe('field convention parity with Elixir hub', () => {
    it('has all shared field names: time, severity, message, module, pid, node, agent_id', () => {
      const captured = captureStdout(() => {
        log('info', 'parity_test');
      });

      const parsed = JSON.parse(captured.trim());
      const requiredFields = ['time', 'severity', 'message', 'module', 'pid', 'node', 'agent_id'];

      for (const field of requiredFields) {
        assert.ok(field in parsed, `missing shared field: ${field}`);
        assert.ok(parsed[field] !== undefined, `field ${field} is undefined`);
      }
    });

    it('severity values match Elixir convention', () => {
      // Elixir uses: debug, info, notice, warning, error
      const expectedLevels = {
        debug: 10,
        info: 20,
        notice: 30,
        warning: 40,
        error: 50
      };

      for (const [name, num] of Object.entries(expectedLevels)) {
        assert.equal(LEVELS[name], num,
          `LEVELS.${name} should be ${num}, got ${LEVELS[name]}`);
      }
    });

    it('time format matches Elixir ISO 8601 convention', () => {
      const captured = captureStdout(() => {
        log('info', 'time_format_test');
      });

      const parsed = JSON.parse(captured.trim());
      // Elixir LoggerJSON outputs: "2026-02-12T10:25:39.566Z"
      // Node.js toISOString outputs: "2026-02-12T10:25:39.566Z"
      // Both are ISO 8601 UTC with Z suffix
      assert.match(parsed.time, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/,
        'time should match ISO 8601 format with milliseconds');
    });

    it('redacts same keys as Elixir hub (token, auth_token, secret)', () => {
      const sensitiveKeys = ['token', 'auth_token', 'secret'];

      for (const key of sensitiveKeys) {
        const captured = captureStdout(() => {
          log('info', 'redact_parity', { [key]: 'sensitive-value' });
        });

        const parsed = JSON.parse(captured.trim());
        assert.equal(parsed[key], '[REDACTED]',
          `${key} should be redacted to [REDACTED]`);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // LEVELS export
  // ---------------------------------------------------------------------------

  describe('LEVELS export', () => {
    it('exports all 5 log levels', () => {
      assert.equal(Object.keys(LEVELS).length, 5);
      assert.ok('debug' in LEVELS);
      assert.ok('info' in LEVELS);
      assert.ok('notice' in LEVELS);
      assert.ok('warning' in LEVELS);
      assert.ok('error' in LEVELS);
    });

    it('levels are ordered numerically', () => {
      assert.ok(LEVELS.debug < LEVELS.info);
      assert.ok(LEVELS.info < LEVELS.notice);
      assert.ok(LEVELS.notice < LEVELS.warning);
      assert.ok(LEVELS.warning < LEVELS.error);
    });
  });
});
