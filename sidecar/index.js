#!/usr/bin/env node
/**
 * AgentCom Sidecar
 * 
 * Always-on WebSocket relay between the AgentCom hub and an OpenClaw agent.
 * Maintains persistent connection, queues incoming tasks, and wakes the
 * agent's OpenClaw session when work arrives.
 *
 * Usage:
 *   1. Copy config.json.example to config.json and fill in your details
 *   2. npm install
 *   3. node index.js
 */

const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');
const { execSync, exec } = require('child_process');

// --- Config ---

const CONFIG_PATH = process.env.SIDECAR_CONFIG || path.join(__dirname, 'config.json');

if (!fs.existsSync(CONFIG_PATH)) {
  console.error(`Config not found: ${CONFIG_PATH}`);
  console.error('Copy config.json.example to config.json and fill in your details.');
  process.exit(1);
}

const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));

const {
  agent_id,
  token,
  hub_url,
  name = agent_id,
  capabilities = [],
  openclaw_wake_command = null,
  reconnect_base_ms = 1000,
  reconnect_max_ms = 60000,
  heartbeat_interval_ms = 30000,
  queue_path = path.join(__dirname, 'queue.json'),
} = config;

if (!agent_id || !token || !hub_url) {
  console.error('config.json must include agent_id, token, and hub_url');
  process.exit(1);
}

// --- Queue (persisted to disk) ---

let queue = [];

function loadQueue() {
  try {
    if (fs.existsSync(queue_path)) {
      queue = JSON.parse(fs.readFileSync(queue_path, 'utf8'));
    }
  } catch (err) {
    log('warn', `Failed to load queue: ${err.message}`);
    queue = [];
  }
}

function saveQueue() {
  try {
    fs.writeFileSync(queue_path, JSON.stringify(queue, null, 2));
  } catch (err) {
    log('warn', `Failed to save queue: ${err.message}`);
  }
}

function enqueue(item) {
  queue.push({ ...item, received_at: Date.now() });
  saveQueue();
  log('info', `Queued item (${queue.length} total): ${item.type || 'message'}`);
}

// --- Logging ---

function log(level, msg) {
  const ts = new Date().toISOString();
  const prefix = { info: '✓', warn: '⚠', error: '✗', event: '📨' }[level] || '·';
  console.log(`[${ts}] ${prefix} ${msg}`);
}

// --- Wake OpenClaw ---

function wakeAgent(reason) {
  if (!openclaw_wake_command) {
    log('info', `Wake triggered (${reason}) but no wake command configured`);
    return;
  }

  log('info', `Waking agent: ${reason}`);
  exec(openclaw_wake_command, (err, stdout, stderr) => {
    if (err) {
      log('warn', `Wake command failed: ${err.message}`);
    } else {
      log('info', `Wake command succeeded`);
    }
  });
}

// --- WebSocket Connection ---

let ws = null;
let reconnectAttempts = 0;
let heartbeatTimer = null;
let pongReceived = true;

function connect() {
  log('info', `Connecting to ${hub_url} as ${agent_id}...`);
  
  ws = new WebSocket(hub_url);

  ws.on('open', () => {
    reconnectAttempts = 0;
    log('info', 'Connected. Identifying...');

    ws.send(JSON.stringify({
      type: 'identify',
      agent_id,
      token,
      name,
      capabilities,
    }));

    // Start heartbeat ping
    startHeartbeat();
  });

  ws.on('message', (data) => {
    let msg;
    try {
      msg = JSON.parse(data);
    } catch (err) {
      log('warn', `Unparseable message: ${data}`);
      return;
    }

    handleMessage(msg);
  });

  ws.on('close', (code, reason) => {
    log('warn', `Disconnected (code: ${code}, reason: ${reason || 'none'})`);
    stopHeartbeat();
    scheduleReconnect();
  });

  ws.on('error', (err) => {
    log('error', `WebSocket error: ${err.message}`);
    // 'close' event will fire after this, triggering reconnect
  });

  ws.on('pong', () => {
    pongReceived = true;
  });
}

function handleMessage(msg) {
  switch (msg.type) {
    case 'identified':
      log('info', `Identified as ${msg.agent_id}. Sidecar is live.`);
      
      // Report any recovering tasks from queue
      if (queue.length > 0) {
        log('info', `${queue.length} queued item(s) from previous session`);
      }
      break;

    case 'message':
      const from = msg.from || 'unknown';
      const text = msg.payload?.text || JSON.stringify(msg.payload);
      log('event', `${from}: ${text.substring(0, 120)}${text.length > 120 ? '...' : ''}`);
      
      enqueue(msg);
      wakeAgent(`message from ${from}`);
      break;

    case 'task_assign':
      log('event', `Task assigned: ${msg.task?.title || msg.task_id || 'unknown'}`);
      enqueue(msg);
      wakeAgent(`task assigned: ${msg.task?.title || msg.task_id}`);
      break;

    case 'agent_joined':
      log('info', `Agent joined: ${msg.agent?.agent_id || 'unknown'}`);
      break;

    case 'agent_left':
      log('info', `Agent left: ${msg.agent_id || 'unknown'}`);
      break;

    case 'status_changed':
      // Ignore status broadcasts silently
      break;

    case 'error':
      log('error', `Hub error: ${msg.message || JSON.stringify(msg)}`);
      break;

    default:
      log('info', `Unhandled message type: ${msg.type}`);
      break;
  }
}

// --- Heartbeat (WebSocket-level ping/pong) ---

function startHeartbeat() {
  stopHeartbeat();
  pongReceived = true;

  heartbeatTimer = setInterval(() => {
    if (!pongReceived) {
      log('warn', 'No pong received, connection may be dead. Closing.');
      ws.terminate();
      return;
    }
    pongReceived = false;
    try {
      ws.ping();
    } catch (err) {
      log('warn', `Ping failed: ${err.message}`);
    }
  }, heartbeat_interval_ms);
}

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
}

// --- Reconnect with exponential backoff ---

function scheduleReconnect() {
  const delay = Math.min(
    reconnect_base_ms * Math.pow(2, reconnectAttempts),
    reconnect_max_ms
  );
  reconnectAttempts++;

  log('info', `Reconnecting in ${(delay / 1000).toFixed(1)}s (attempt ${reconnectAttempts})...`);
  setTimeout(connect, delay);
}

// --- Queue API (for the agent to read/drain) ---
// The agent reads queue.json directly or via a future HTTP endpoint.

function drainQueue() {
  const items = [...queue];
  queue = [];
  saveQueue();
  return items;
}

// --- Graceful shutdown ---

function shutdown(signal) {
  log('info', `${signal} received. Shutting down...`);
  stopHeartbeat();
  if (ws) {
    ws.close(1000, 'sidecar shutdown');
  }
  saveQueue();
  process.exit(0);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

// --- Start ---

log('info', `AgentCom Sidecar v0.1.0`);
log('info', `Agent: ${agent_id} (${name})`);
log('info', `Hub: ${hub_url}`);
log('info', `Queue: ${queue_path}`);
log('info', `Wake command: ${openclaw_wake_command || '(none)'}`);

loadQueue();
connect();
