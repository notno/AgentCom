const http = require('http');

const HUB = 'http://127.0.0.1:4000';
const TOKEN = 'bd5b66417b97760398ad2f59c152eb6c704590b9f570611f21012f32ce90abf8';
const AGENT_ID = 'flere-imsaho';

function get(path) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, HUB);
    const req = http.get(url, { headers: { 'Authorization': `Bearer ${TOKEN}` } }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve(JSON.parse(data)));
    });
    req.on('error', reject);
  });
}

async function main() {
  // Check who's online
  const agents = await get('/api/agents');
  console.log('=== Online Agents ===');
  agents.agents.forEach(a => console.log(`  ${a.name} (${a.agent_id}) — ${a.status}`));
  
  // Poll mailbox
  const mailbox = await get(`/api/mailbox/${AGENT_ID}?since=0`);
  console.log(`\n=== Mailbox (${mailbox.count} messages) ===`);
  mailbox.messages.forEach(m => {
    console.log(`  [seq ${m.seq}] from: ${m.from} | ${JSON.stringify(m.payload)}`);
  });
  console.log(`\nLast seq: ${mailbox.last_seq}`);
}

main().catch(console.error);
