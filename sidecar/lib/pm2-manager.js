'use strict';

const { execSync } = require('child_process');
const { log } = require('./log');

// Module-level state for pending restart
let _pendingRestart = null;

/**
 * Get the pm2 process name for this sidecar.
 * Primary: PM2_PROCESS_NAME env var (set in ecosystem.config.js).
 * Fallback: discover via `pm2 jlist` and PID matching.
 * Returns null if not running under pm2.
 */
function getProcessName() {
  if (process.env.PM2_PROCESS_NAME) {
    return process.env.PM2_PROCESS_NAME;
  }

  try {
    const output = execSync('pm2 jlist', { encoding: 'utf8', timeout: 5000 });
    const processes = JSON.parse(output);
    const self = processes.find(p => p.pid === process.pid);
    return self ? self.name : null;
  } catch (err) {
    log('debug', 'pm2_discovery_failed', { error: err.message }, 'sidecar/lib/pm2-manager');
    return null;
  }
}

/**
 * Get the pm2 process status string ("online", "stopped", "errored") or null.
 * Uses `pm2 jlist` and matches by process name from getProcessName().
 */
function getStatus() {
  const name = getProcessName();
  if (!name) return null;

  try {
    const output = execSync('pm2 jlist', { encoding: 'utf8', timeout: 5000 });
    const processes = JSON.parse(output);
    const self = processes.find(p => p.name === name);
    return self ? self.pm2_env.status : null;
  } catch (err) {
    log('debug', 'pm2_status_failed', { error: err.message }, 'sidecar/lib/pm2-manager');
    return null;
  }
}

/**
 * Get pm2 process info object or null.
 * Returns { name, status, uptime_ms, restart_count, memory_bytes }.
 */
function getInfo() {
  const name = getProcessName();
  if (!name) return null;

  try {
    const output = execSync('pm2 jlist', { encoding: 'utf8', timeout: 5000 });
    const processes = JSON.parse(output);
    const self = processes.find(p => p.name === name);
    if (!self) return null;

    const now = Date.now();
    const pmUptime = self.pm2_env ? self.pm2_env.pm_uptime : null;
    const uptimeMs = pmUptime ? now - pmUptime : null;

    return {
      name: self.name,
      status: self.pm2_env ? self.pm2_env.status : 'unknown',
      uptime_ms: uptimeMs,
      restart_count: self.pm2_env ? (self.pm2_env.restart_time || 0) : 0,
      memory_bytes: self.monit ? (self.monit.memory || 0) : 0
    };
  } catch (err) {
    log('debug', 'pm2_info_failed', { error: err.message }, 'sidecar/lib/pm2-manager');
    return null;
  }
}

/**
 * Graceful restart: finish active task first, then exit cleanly.
 * pm2 auto-restart handles the actual restart.
 *
 * If a task is actively working, sets a pending restart flag.
 * The caller should check hasPendingRestart() after task completion.
 *
 * @param {object} hub - HubConnection instance with send() method
 * @param {object} queue - Queue object with { active: { status } }
 * @param {string} reason - Restart reason for logging
 */
function gracefulRestart(hub, queue, reason) {
  if (queue.active && queue.active.status === 'working') {
    log('info', 'restart_deferred', { reason, task_id: queue.active.task_id }, 'sidecar/lib/pm2-manager');
    _pendingRestart = { hub, reason };
    return;
  }

  log('info', 'restart_executing', { reason }, 'sidecar/lib/pm2-manager');
  hub.send({ type: 'agent_restarting', reason });
  setTimeout(() => process.exit(0), 500);
}

/**
 * Check if a restart is pending (deferred because task was active).
 * Returns the pending restart object { hub, reason } or null.
 */
function hasPendingRestart() {
  return _pendingRestart;
}

/**
 * Clear the pending restart flag.
 */
function clearPendingRestart() {
  _pendingRestart = null;
}

module.exports = {
  getProcessName,
  getStatus,
  getInfo,
  gracefulRestart,
  hasPendingRestart,
  clearPendingRestart
};
