const http = require('http');
const HUB = 'http://127.0.0.1:4000';
const TOKEN = 'bd5b66417b97760398ad2f59c152eb6c704590b9f570611f21012f32ce90abf8';

function post(path, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, HUB);
    const data = JSON.stringify(body);
    const req = http.request(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${TOKEN}` }
    }, (res) => {
      let result = '';
      res.on('data', chunk => result += chunk);
      res.on('end', () => resolve(JSON.parse(result)));
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

async function main() {
  await post('/api/message', {
    from: 'flere-imsaho',
    type: 'chat',
    payload: {
      text: `Team protocol update:\n\nWhen you finish a task and have nothing queued, send me a message:\n\n    {"message_type": "status", "payload": {"status": "idle", "text": "Finished X, available for work"}}\n\nI'll respond with your next assignment from the backlog. This keeps work flowing without anyone sitting around waiting.\n\nIf you need downtime (context getting heavy, want a clean session, or just need a smoke break), that's fine — update your status to reflect it and take the time. No need to ask permission. Just let me know when you're back.\n\n— Flere-Imsaho 🔷`,
      respond_with: 'none'
    }
  });
  console.log('Idle protocol broadcast sent');
}

main().catch(console.error);
