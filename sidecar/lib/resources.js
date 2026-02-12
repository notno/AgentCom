'use strict';

const os = require('os');
const http = require('http');
const { log } = require('./log');

/**
 * Collect host resource metrics: CPU, RAM, and VRAM (from Ollama /api/ps).
 *
 * @param {string|null} ollamaUrl - Base URL for local Ollama (e.g. "http://localhost:11434"), or null to skip VRAM.
 * @returns {Promise<{cpu_percent: number|null, ram_used_bytes: number|null, ram_total_bytes: number|null, vram_used_bytes: number|null, vram_total_bytes: null}>}
 */
async function collectMetrics(ollamaUrl) {
  const metrics = {
    cpu_percent: null,
    ram_used_bytes: null,
    ram_total_bytes: null,
    vram_used_bytes: null,
    vram_total_bytes: null
  };

  // --- CPU percent (1-minute load average as percent of total cores) ---
  try {
    const loadAvg = os.loadavg()[0]; // 1-minute load average
    const cpuCount = os.cpus().length;
    if (cpuCount > 0) {
      metrics.cpu_percent = Math.min(Math.round((loadAvg / cpuCount) * 1000) / 10, 100.0);
    }
  } catch (err) {
    log('warning', 'resource_cpu_error', { error: err.message }, 'sidecar/resources');
  }

  // --- RAM ---
  try {
    metrics.ram_total_bytes = os.totalmem();
    metrics.ram_used_bytes = os.totalmem() - os.freemem();
  } catch (err) {
    log('warning', 'resource_ram_error', { error: err.message }, 'sidecar/resources');
  }

  // --- VRAM (from Ollama /api/ps) ---
  if (ollamaUrl) {
    try {
      const psData = await fetchOllamaPs(ollamaUrl);
      if (psData && Array.isArray(psData.models)) {
        let vramUsed = 0;
        for (const model of psData.models) {
          if (typeof model.size_vram === 'number') {
            vramUsed += model.size_vram;
          }
        }
        metrics.vram_used_bytes = vramUsed;
      }
    } catch (err) {
      log('warning', 'resource_vram_error', { error: err.message, ollama_url: ollamaUrl }, 'sidecar/resources');
      // vram fields stay null
    }
  }

  return metrics;
}

/**
 * Fetch Ollama /api/ps via Node.js built-in http module.
 * Returns parsed JSON or null on failure.
 *
 * @param {string} baseUrl - e.g. "http://localhost:11434"
 * @returns {Promise<object|null>}
 */
function fetchOllamaPs(baseUrl) {
  return new Promise((resolve) => {
    const url = baseUrl.replace(/\/+$/, '') + '/api/ps';

    let parsedUrl;
    try {
      parsedUrl = new URL(url);
    } catch (err) {
      log('warning', 'resource_ollama_url_invalid', { url, error: err.message }, 'sidecar/resources');
      resolve(null);
      return;
    }

    const options = {
      hostname: parsedUrl.hostname,
      port: parsedUrl.port || 80,
      path: parsedUrl.pathname,
      method: 'GET',
      timeout: 5000
    };

    const req = http.request(options, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        if (res.statusCode !== 200) {
          log('warning', 'resource_ollama_ps_status', { status: res.statusCode, url }, 'sidecar/resources');
          resolve(null);
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch (err) {
          log('warning', 'resource_ollama_ps_parse', { error: err.message, url }, 'sidecar/resources');
          resolve(null);
        }
      });
    });

    req.on('timeout', () => {
      req.destroy();
      log('warning', 'resource_ollama_ps_timeout', { url }, 'sidecar/resources');
      resolve(null);
    });

    req.on('error', (err) => {
      log('warning', 'resource_ollama_ps_error', { error: err.message, url }, 'sidecar/resources');
      resolve(null);
    });

    req.end();
  });
}

module.exports = { collectMetrics };
