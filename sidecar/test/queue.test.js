'use strict';

const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { loadQueue, saveQueue, cleanupResultFiles } = require('../lib/queue');

describe('Queue Management', () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-queue-test-'));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  describe('loadQueue', () => {
    it('returns empty queue when file does not exist', () => {
      const queuePath = path.join(tmpDir, 'queue.json');
      const result = loadQueue(queuePath);
      assert.deepStrictEqual(result, { active: null, recovering: null });
    });

    it('returns empty queue on corrupt JSON file', () => {
      const queuePath = path.join(tmpDir, 'queue.json');
      fs.writeFileSync(queuePath, 'not json{{{');
      const result = loadQueue(queuePath);
      assert.deepStrictEqual(result, { active: null, recovering: null });
    });

    it('parses valid queue file correctly', () => {
      const queuePath = path.join(tmpDir, 'queue.json');
      const queueData = {
        active: { task_id: 'task-123', status: 'working' },
        recovering: null
      };
      fs.writeFileSync(queuePath, JSON.stringify(queueData));
      const result = loadQueue(queuePath);
      assert.deepStrictEqual(result, queueData);
    });

    it('handles empty file gracefully', () => {
      const queuePath = path.join(tmpDir, 'queue.json');
      fs.writeFileSync(queuePath, '');
      const result = loadQueue(queuePath);
      assert.deepStrictEqual(result, { active: null, recovering: null });
    });
  });

  describe('saveQueue', () => {
    it('writes valid JSON that loadQueue can read back (round-trip)', () => {
      const queuePath = path.join(tmpDir, 'queue.json');
      const queueData = {
        active: { task_id: 'task-456', description: 'test task', status: 'accepted' },
        recovering: null
      };
      saveQueue(queuePath, queueData);
      const result = loadQueue(queuePath);
      assert.deepStrictEqual(result, queueData);
    });

    it('creates file if it does not exist', () => {
      const queuePath = path.join(tmpDir, 'queue.json');
      assert.strictEqual(fs.existsSync(queuePath), false);
      saveQueue(queuePath, { active: null, recovering: null });
      assert.strictEqual(fs.existsSync(queuePath), true);
    });

    it('overwrites existing file', () => {
      const queuePath = path.join(tmpDir, 'queue.json');
      saveQueue(queuePath, { active: { task_id: 'old' }, recovering: null });
      saveQueue(queuePath, { active: { task_id: 'new' }, recovering: null });
      const result = loadQueue(queuePath);
      assert.strictEqual(result.active.task_id, 'new');
    });
  });

  describe('cleanupResultFiles', () => {
    it('removes .json and .started files for a task_id', () => {
      const resultFile = path.join(tmpDir, 'task-789.json');
      const startedFile = path.join(tmpDir, 'task-789.started');
      fs.writeFileSync(resultFile, '{"status":"success"}');
      fs.writeFileSync(startedFile, '');

      cleanupResultFiles('task-789', tmpDir);

      assert.strictEqual(fs.existsSync(resultFile), false);
      assert.strictEqual(fs.existsSync(startedFile), false);
    });

    it('handles missing files gracefully (no throw)', () => {
      // Should not throw when files don't exist
      assert.doesNotThrow(() => {
        cleanupResultFiles('nonexistent-task', tmpDir);
      });
    });

    it('removes only the matching task files', () => {
      const otherFile = path.join(tmpDir, 'other-task.json');
      fs.writeFileSync(otherFile, '{}');
      fs.writeFileSync(path.join(tmpDir, 'task-abc.json'), '{}');

      cleanupResultFiles('task-abc', tmpDir);

      assert.strictEqual(fs.existsSync(otherFile), true, 'other task file should remain');
      assert.strictEqual(fs.existsSync(path.join(tmpDir, 'task-abc.json')), false);
    });
  });
});
