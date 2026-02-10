'use strict';

const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');

// =============================================================================
// 1. Config Loader
// =============================================================================

const CONFIG_PATH = path.join(__dirname, 'config.json');

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    console.error(
      'ERROR: config.json not found.\n' +
      'Copy config.json.example to config.json and fill in your values:\n' +
      '  cp config.json.example config.json\n'
    );
    process.exit(1);
  }

  const raw = fs.readFileSync(CONFIG_PATH, 'utf8');
  const config = JSON.parse(raw);

  const required = ['agent_id', 'token', 'hub_url'];
  for (const field of required) {
    if (!config[field]) {
      console.error(`ERROR: config.json missing required field: ${field}`);
      process.exit(1);
    }
  }

  // Defaults
  config.capabilities = config.capabilities || [];
  config.confirmation_timeout_ms = config.confirmation_timeout_ms || 30000;
  config.results_dir = config.results_dir || './results';
  config.log_file = config.log_file || './sidecar.log';

  // Resolve relative paths against __dirname
  if (!path.isAbsolute(config.log_file)) {
    config.log_file = path.join(__dirname, config.log_file);
  }
  if (!path.isAbsolute(config.results_dir)) {
    config.results_dir = path.join(__dirname, config.results_dir);
  }

  return config;
}

// =============================================================================
// 2. Structured Logging
// =============================================================================

let _config = null; // Will be set after config loads

function log(event, data = {}) {
  const entry = {
    ts: new Date().toISOString(),
    event,
    agent_id: _config ? _config.agent_id : 'unknown',
    ...data
  };

  const line = JSON.stringify(entry) + '\n';

  // Write to log file
  if (_config && _config.log_file) {
    try {
      fs.appendFileSync(_config.log_file, line);
    } catch (err) {
      console.error(`Failed to write to log file: ${err.message}`);
    }
  }

  // Also console.log for pm2 stdout capture
  console.log(`[${entry.ts}] ${event}`, Object.keys(data).length > 0 ? data : '');
}

// =============================================================================
// 3. HubConnection Class
// =============================================================================

class HubConnection {
  constructor(config) {
    this.config = config;
    this.ws = null;
    this.identified = false;
    this.reconnectDelay = 1000;       // Start at 1s
    this.maxReconnectDelay = 60000;   // Cap at 60s
    this.reconnectTimer = null;
    this.heartbeatInterval = null;
    this.pongTimer = null;
    this.lastPongTime = null;
    this.shuttingDown = false;
  }

  connect() {
    if (this.shuttingDown) return;

    log('ws_connecting', { hub_url: this.config.hub_url });

    try {
      this.ws = new WebSocket(this.config.hub_url);
    } catch (err) {
      log('ws_connect_error', { error: err.message });
      this.scheduleReconnect();
      return;
    }

    this.ws.on('open', () => {
      log('ws_open');
      this.reconnectDelay = 1000; // Reset backoff on successful connect
      this.identify();
      this.startHeartbeat();
    });

    this.ws.on('close', (code, reason) => {
      const reasonStr = reason ? reason.toString() : '';
      log('ws_close', { code, reason: reasonStr });
      this.identified = false;
      this.stopHeartbeat();
      this.scheduleReconnect();
    });

    this.ws.on('error', (err) => {
      // Error also triggers 'close', so reconnect is handled there
      log('ws_error', { error: err.message });
    });

    this.ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        this.handleMessage(msg);
      } catch (err) {
        log('ws_message_parse_error', { error: err.message });
      }
    });
  }

  identify() {
    this.send({
      type: 'identify',
      agent_id: this.config.agent_id,
      token: this.config.token,
      name: this.config.agent_id,
      status: 'idle',
      capabilities: this.config.capabilities,
      client_type: 'sidecar',
      protocol_version: 1
    });
    log('identify_sent');
  }

  scheduleReconnect() {
    if (this.shuttingDown) return;

    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(
      this.reconnectDelay * 2,
      this.maxReconnectDelay
    );

    log('reconnect_scheduled', { delay_ms: delay, next_delay_ms: this.reconnectDelay });

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  handleMessage(msg) {
    switch (msg.type) {
      case 'identified':
        this.identified = true;
        this.reconnectDelay = 1000; // Reset on successful identification
        log('identified', { agent_id: msg.agent_id });
        break;

      case 'error':
        log('hub_error', { error: msg.error });
        break;

      case 'pong':
        this.lastPongTime = Date.now();
        break;

      default:
        log('unhandled_message', { type: msg.type });
        break;
    }
  }

  send(obj) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      log('send_failed', { reason: 'not_connected', type: obj.type });
      return false;
    }

    const payload = { ...obj, protocol_version: 1 };
    try {
      this.ws.send(JSON.stringify(payload));
      return true;
    } catch (err) {
      log('send_error', { error: err.message, type: obj.type });
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Heartbeat: ping every 30s, expect pong within 10s
  // Detects silent WebSocket death (NAT timeout, firewall kill, network partition)
  // ---------------------------------------------------------------------------

  startHeartbeat() {
    this.stopHeartbeat(); // Clear any existing heartbeat

    this.heartbeatInterval = setInterval(() => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

      this.send({ type: 'ping' });

      // Set a timeout to check for pong response
      const pingTime = Date.now();
      this.pongTimer = setTimeout(() => {
        // If no pong received since we sent the ping, connection is dead
        if (!this.lastPongTime || this.lastPongTime < pingTime) {
          log('heartbeat_timeout', { last_pong: this.lastPongTime, ping_sent: pingTime });
          // Force close -- this triggers 'close' event which triggers reconnect
          if (this.ws) {
            try {
              this.ws.terminate();
            } catch (err) {
              // Ignore terminate errors
            }
          }
        }
      }, 10000); // 10s pong timeout
    }, 30000); // 30s ping interval
  }

  stopHeartbeat() {
    if (this.heartbeatInterval) {
      clearInterval(this.heartbeatInterval);
      this.heartbeatInterval = null;
    }
    if (this.pongTimer) {
      clearTimeout(this.pongTimer);
      this.pongTimer = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Shutdown
  // ---------------------------------------------------------------------------

  shutdown() {
    this.shuttingDown = true;

    // Cancel pending reconnect
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    this.stopHeartbeat();

    // Close WebSocket cleanly
    if (this.ws) {
      try {
        this.ws.close(1000, 'shutdown');
      } catch (err) {
        // Ignore close errors during shutdown
      }
    }
  }
}

// =============================================================================
// 4. Graceful Shutdown
// =============================================================================

function setupGracefulShutdown(hub) {
  const shutdown = (signal) => {
    log('shutdown', { signal });
    hub.shutdown();
    // Give a moment for the close frame to send, then exit
    setTimeout(() => {
      process.exit(0);
    }, 500);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  // Windows: handle SIGBREAK (Ctrl+Break)
  if (process.platform === 'win32') {
    process.on('SIGBREAK', () => shutdown('SIGBREAK'));
  }
}

// =============================================================================
// 5. Main Entry Point
// =============================================================================

function main() {
  // Load config
  const config = loadConfig();
  _config = config;

  log('startup', {
    agent_id: config.agent_id,
    hub_url: config.hub_url,
    capabilities: config.capabilities,
    version: '1.0.0'
  });

  // Create connection and connect
  const hub = new HubConnection(config);
  hub.connect();

  // Set up graceful shutdown
  setupGracefulShutdown(hub);

  log('ready', { agent_id: config.agent_id });
}

main();
