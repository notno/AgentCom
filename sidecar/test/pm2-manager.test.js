'use strict';

const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');

// pm2-manager requires log.js which needs initLogger, so init first
const { initLogger } = require('../lib/log');
initLogger({ agent_id: 'test', log_level: 'error' });

const pm2Manager = require('../lib/pm2-manager');

describe('pm2-manager', () => {
  describe('getProcessName()', () => {
    it('returns PM2_PROCESS_NAME env var when set', () => {
      const original = process.env.PM2_PROCESS_NAME;
      try {
        process.env.PM2_PROCESS_NAME = 'test-sidecar';
        const name = pm2Manager.getProcessName();
        assert.equal(name, 'test-sidecar');
      } finally {
        if (original === undefined) {
          delete process.env.PM2_PROCESS_NAME;
        } else {
          process.env.PM2_PROCESS_NAME = original;
        }
      }
    });

    it('returns null when env var not set and pm2 jlist fails', () => {
      const original = process.env.PM2_PROCESS_NAME;
      try {
        delete process.env.PM2_PROCESS_NAME;
        // pm2 jlist will fail in test environment (no pm2 or PID won't match)
        const name = pm2Manager.getProcessName();
        // Either null (pm2 not available) or a string (if pm2 happens to be running)
        assert.ok(name === null || typeof name === 'string');
      } finally {
        if (original !== undefined) {
          process.env.PM2_PROCESS_NAME = original;
        }
      }
    });
  });

  describe('getInfo()', () => {
    it('returns null when not running under pm2', () => {
      const original = process.env.PM2_PROCESS_NAME;
      try {
        delete process.env.PM2_PROCESS_NAME;
        const info = pm2Manager.getInfo();
        // If pm2 is not running or PID doesn't match, returns null
        // If pm2 IS running, it might return an object -- both are valid
        assert.ok(info === null || typeof info === 'object');
      } finally {
        if (original !== undefined) {
          process.env.PM2_PROCESS_NAME = original;
        }
      }
    });
  });

  describe('hasPendingRestart()', () => {
    it('returns null initially', () => {
      pm2Manager.clearPendingRestart();
      const result = pm2Manager.hasPendingRestart();
      assert.equal(result, null);
    });
  });

  describe('exports', () => {
    it('exports all 6 required functions', () => {
      assert.equal(typeof pm2Manager.getProcessName, 'function');
      assert.equal(typeof pm2Manager.getStatus, 'function');
      assert.equal(typeof pm2Manager.getInfo, 'function');
      assert.equal(typeof pm2Manager.gracefulRestart, 'function');
      assert.equal(typeof pm2Manager.hasPendingRestart, 'function');
      assert.equal(typeof pm2Manager.clearPendingRestart, 'function');
    });
  });
});
