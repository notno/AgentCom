'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { interpolateWakeCommand, execCommand, RETRY_DELAYS } = require('../lib/wake');

describe('Wake Trigger', () => {

  describe('interpolateWakeCommand', () => {
    it('replaces ${TASK_ID} with task.task_id', () => {
      const result = interpolateWakeCommand('run --task ${TASK_ID}', { task_id: 'abc-123' });
      assert.strictEqual(result, 'run --task abc-123');
    });

    it('replaces ${TASK_DESCRIPTION} with task.description', () => {
      const result = interpolateWakeCommand('echo "${TASK_DESCRIPTION}"', {
        task_id: 'x',
        description: 'Fix the bug'
      });
      assert.strictEqual(result, 'echo "Fix the bug"');
    });

    it('replaces ${TASK_JSON} with JSON-encoded task (with escaped quotes)', () => {
      const task = { task_id: 'task-1', description: 'test' };
      const result = interpolateWakeCommand('run ${TASK_JSON}', task);
      // The JSON should have its double quotes escaped with backslashes
      const expectedJson = JSON.stringify(task).replace(/"/g, '\\"');
      assert.strictEqual(result, `run ${expectedJson}`);
    });

    it('handles missing task fields gracefully', () => {
      // task_id is undefined -> replaced with empty string
      const result = interpolateWakeCommand('run ${TASK_ID} "${TASK_DESCRIPTION}"', {});
      assert.strictEqual(result, 'run  ""');
    });

    it('with no template variables returns command unchanged', () => {
      const cmd = 'echo hello world';
      const result = interpolateWakeCommand(cmd, { task_id: 'x', description: 'y' });
      assert.strictEqual(result, cmd);
    });

    it('replaces multiple occurrences of the same variable', () => {
      const result = interpolateWakeCommand('${TASK_ID}-${TASK_ID}', { task_id: 'abc' });
      assert.strictEqual(result, 'abc-abc');
    });

    it('escapes double quotes in description', () => {
      const result = interpolateWakeCommand('echo ${TASK_DESCRIPTION}', {
        task_id: 'x',
        description: 'say "hello"'
      });
      assert.strictEqual(result, 'echo say \\"hello\\"');
    });
  });

  describe('RETRY_DELAYS', () => {
    it('has 3 entries: [5000, 15000, 30000]', () => {
      assert.deepStrictEqual(RETRY_DELAYS, [5000, 15000, 30000]);
    });
  });

  describe('execCommand', () => {
    it('resolves with exit code 0 for a simple command', async () => {
      const result = await execCommand('node -e "console.log(\'ok\')"');
      assert.strictEqual(result.code, 0);
      assert.ok(result.stdout.includes('ok'));
    });

    it('rejects with error info for a failing command', async () => {
      await assert.rejects(
        () => execCommand('node -e "process.exit(1)"'),
        (err) => {
          assert.ok(err.message || err.code, 'Error should have message or code');
          return true;
        }
      );
    });
  });
});
