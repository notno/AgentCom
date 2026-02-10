#!/usr/bin/env node
/**
 * Generic AgentCom WebSocket client.
 * 
 * Usage:
 *   AGENT_ID=my-agent AGENT_TOKEN=xxx HUB_URL=ws://localhost:4000/ws node scripts/connect.js
 *
 * For example:
 *   AGENT_ID=flere-imsaho AGENT_TOKEN=abc123 node scripts/connect.js
 */
const WebSocket = require('ws');

const AGENT_ID = process.env.AGENT_ID;
const AGENT_TOKEN = process.env.AGENT_TOKEN;
const HUB_URL = process.env.HUB_URL || 'ws://localhost:4000/ws';
const AGENT_NAME = process.env.AGENT_NAME || AGENT_ID;

if (!AGENT_ID || !AGENT_TOKEN) {
  console.error('Required env vars: AGENT_ID, AGENT_TOKEN');
  console.error('Optional: HUB_URL (default ws://localhost:4000/ws), AGENT_NAME');
  process.exit(1);
}

const ws = new WebSocket(HUB_URL);

ws.on('open', () => {
  console.log(`[connected] ${HUB_URL}`);
  ws.send(JSON.stringify({
    type: 'identify',
    agent_id: AGENT_ID,
    token: AGENT_TOKEN,
    name: AGENT_NAME,
    capabilities: (process.env.CAPABILITIES || '').split(',').filter(Boolean)
  }));
});

ws.on('message', (data) => {
  const msg = JSON.parse(data);
  const ts = new Date().toLocaleTimeString();
  if (msg.type === 'identified') {
    console.log(`[${ts}] ✓ Identified as ${AGENT_ID}`);
  } else if (msg.type === 'message') {
    console.log(`[${ts}] 📨 ${msg.from}: ${msg.payload?.text || JSON.stringify(msg.payload)}`);
  } else {
    console.log(`[${ts}] ${msg.type}:`, JSON.stringify(msg));
  }
});

ws.on('close', () => { console.log('[disconnected]'); process.exit(0); });
ws.on('error', (err) => { console.error('[error]', err.message); process.exit(1); });
