'use strict';

const fs = require('fs');
const path = require('path');
const writeFileAtomic = require('write-file-atomic');

/**
 * Load queue state from a JSON file.
 * Returns { active: null, recovering: null } if file doesn't exist or is corrupt.
 *
 * @param {string} queuePath - Absolute path to queue.json
 * @returns {{ active: object|null, recovering: object|null }}
 */
function loadQueue(queuePath) {
  try {
    const data = fs.readFileSync(queuePath, 'utf8');
    return JSON.parse(data);
  } catch (err) {
    // ENOENT (file missing) or JSON parse error (corrupt) -- return empty queue
    return { active: null, recovering: null };
  }
}

/**
 * Save queue state to a JSON file atomically.
 * Uses write-file-atomic to prevent corruption on crash.
 *
 * @param {string} queuePath - Absolute path to queue.json
 * @param {{ active: object|null, recovering: object|null }} queue - Queue state
 */
function saveQueue(queuePath, queue) {
  writeFileAtomic.sync(queuePath, JSON.stringify(queue, null, 2));
}

/**
 * Delete result and started files for a completed/failed task.
 *
 * @param {string} taskId - The task identifier
 * @param {string} resultsDir - Absolute path to the results directory
 */
function cleanupResultFiles(taskId, resultsDir) {
  const resultFile = path.join(resultsDir, `${taskId}.json`);
  const startedFile = path.join(resultsDir, `${taskId}.started`);

  try {
    if (fs.existsSync(resultFile)) fs.unlinkSync(resultFile);
  } catch (err) {
    // Silently handle cleanup errors (file may already be gone)
  }
  try {
    if (fs.existsSync(startedFile)) fs.unlinkSync(startedFile);
  } catch (err) {
    // Silently handle cleanup errors
  }
}

module.exports = { loadQueue, saveQueue, cleanupResultFiles };
