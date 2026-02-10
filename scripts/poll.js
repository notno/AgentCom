#!/usr/bin/env node
/**
 * Poll an agent's mailbox via the AgentCom HTTP API.
 *
 * Usage:
 *   AGENT_ID=my-agent AGENT_TOKEN=xxx node scripts/poll.js [--since N] [--ack]
 *
 * For example:
 *   AGENT_ID=loash AGENT_TOKEN=abc123 node scripts/poll.js --since 50 --ack
 *
 * Options:
 *   --since N   Only return messages after sequence N (default: 0)
 *   --ack       Acknowledge messages after displaying them
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
let since = 0;
let doAck = false;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--since' && args[i + 1]) since = parseInt(args[++i]);
  if (args[i] === '--ack') doAck = true;
}

function httpGet(path) {
  return new Promise((resolve, reject) => {
    const url = new URL(`${HUB_URL}${path}`);
    http.get({
      hostname: url.hostname, port: url.port, path: url.pathname + url.search,
      headers: { 'Authorization': `Bearer ${AGENT_TOKEN}` }
    }, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(data) }));
    }).on('error', reject);
  });
}

function httpPost(path, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(`${HUB_URL}${path}`);
    const json = JSON.stringify(body);
    const req = http.request({
      hostname: url.hostname, port: url.port, path: url.pathname,
      method: 'POST',
      headers: { 'Authorization': `Bearer ${AGENT_TOKEN}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(json) }
    }, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(data) }));
    });
    req.on('error', reject);
    req.write(json);
    req.end();
  });
}

(async () => {
  const result = await httpGet(`/api/mailbox/${AGENT_ID}?since=${since}`);
  const { messages, last_seq, count } = result.body;
  console.log(`Mailbox: ${count} message(s), last_seq: ${last_seq}\n`);

  for (const msg of messages || []) {
    const text = msg.payload?.text || JSON.stringify(msg.payload);
    console.log(`[seq:${msg.seq}] ${msg.from}: ${text}`);
  }

  if (doAck && last_seq > since) {
    await httpPost(`/api/mailbox/${AGENT_ID}/ack`, { seq: last_seq });
    console.log(`\n✓ Acked through seq ${last_seq}`);
  }
})().catch(err => { console.error('Error:', err.message); process.exit(1); });
