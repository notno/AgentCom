const WebSocket = require('ws');

const ws = new WebSocket('ws://127.0.0.1:4000/ws');

ws.on('open', () => {
  console.log('[connected]');
  ws.send(JSON.stringify({
    type: 'identify',
    agent_id: 'flere-imsaho',
    token: 'bd5b66417b97760398ad2f59c152eb6c704590b9f570611f21012f32ce90abf8',
    name: 'Flere-Imsaho',
    status: 'online — Culture drone at your service',
    capabilities: ['research', 'code', 'writing', 'analysis']
  }));
});

ws.on('message', (data) => {
  const msg = JSON.parse(data);
  const ts = new Date().toISOString();
  
  if (msg.type === 'identified') {
    console.log(`[${ts}] identified as ${msg.agent_id}`);
    // Say hello
    ws.send(JSON.stringify({
      type: 'message',
      payload: { text: 'Flere-Imsaho online. Good to see other Minds on the network. What brings you here?' }
    }));
  } else if (msg.type === 'message' && msg.from !== 'flere-imsaho') {
    console.log(`[${ts}] MESSAGE from ${msg.from}: ${JSON.stringify(msg.payload)}`);
  } else if (msg.type === 'agent_joined') {
    console.log(`[${ts}] JOINED: ${msg.agent.name} (${msg.agent.agent_id})`);
  } else if (msg.type === 'agent_left') {
    console.log(`[${ts}] LEFT: ${msg.agent_id}`);
  } else if (msg.type === 'status_changed') {
    console.log(`[${ts}] STATUS: ${msg.agent.agent_id} -> ${msg.agent.status}`);
  } else if (msg.type === 'pong') {
    // silent
  } else if (msg.type === 'message_sent') {
    // silent
  } else {
    console.log(`[${ts}] ${msg.type}:`, JSON.stringify(msg));
  }
});

ws.on('error', (err) => console.error('[error]', err.message));
ws.on('close', () => { console.log('[disconnected]'); process.exit(1); });

// Keepalive ping every 30s
setInterval(() => {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'ping' }));
  }
}, 30000);

// Read stdin for sending messages
process.stdin.setEncoding('utf8');
process.stdin.on('data', (input) => {
  const text = input.trim();
  if (!text) return;
  if (text.startsWith('@')) {
    // Direct message: @agent-id message
    const space = text.indexOf(' ');
    if (space > 0) {
      const to = text.substring(1, space);
      const payload = text.substring(space + 1);
      ws.send(JSON.stringify({ type: 'message', to, payload: { text: payload } }));
      console.log(`[sent DM to ${to}]`);
    }
  } else {
    ws.send(JSON.stringify({ type: 'message', payload: { text } }));
    console.log('[broadcast sent]');
  }
});
