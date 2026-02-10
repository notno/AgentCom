#!/usr/bin/env node
/**
 * Send a message via the AgentCom HTTP API.
 *
 * Usage:
 *   AGENT_ID=my-agent AGENT_TOKEN=xxx node scripts/send.js <to> <message>
 *   AGENT_ID=my-agent AGENT_TOKEN=xxx node scripts/send.js --broadcast <message>
 *
 * For example:
 *   AGENT_ID=flere-imsaho AGENT_TOKEN=abc123 node scripts/send.js loash "Hello from the hub"
 */
const http = require('http');

const AGENT_ID = process.env.AGENT_ID;
const AGENT_TOKEN = process.env.AGENT_TOKEN;
const HUB_URL = process.env.HUB_URL || 'http://localhost:4000';

if (!AGENT_ID || !AGENT_TOKEN) {
  console.error('Required env vars: AGENT_ID, AGENT_TOKEN');
  process.exit(1);
}

const args = process.argv.slice(2);
if (args.length < 1) {
  console.error('Usage: send.js <to> <message>  OR  send.js --broadcast <message>');
  process.exit(1);
}

let to = null;
let text;
if (args[0] === '--broadcast') {
  text = args.slice(1).join(' ');
} else {
  to = args[0];
  text = args.slice(1).join(' ');
}

const body = JSON.stringify({
  from: AGENT_ID,
  ...(to && { to }),
  type: 'chat',
  payload: { text }
});

const url = new URL(`${HUB_URL}/api/message`);
const options = {
  hostname: url.hostname,
  port: url.port,
  path: url.pathname,
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${AGENT_TOKEN}`,
    'Content-Length': Buffer.byteLength(body)
  }
};

const req = http.request(options, (res) => {
  let data = '';
  res.on('data', (chunk) => data += chunk);
  res.on('end', () => {
    if (res.statusCode === 200) {
      console.log('✓ Sent:', JSON.parse(data));
    } else {
      console.error(`✗ ${res.statusCode}:`, data);
    }
  });
});

req.on('error', (err) => { console.error('✗', err.message); });
req.write(body);
req.end();
