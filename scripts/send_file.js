const http = require('http');
const fs = require('fs');
const TOKEN = 'bd5b66417b97760398ad2f59c152eb6c704590b9f570611f21012f32ce90abf8';

const to = process.argv[2];
const file = process.argv[3];
if (!to || !file) { console.log('Usage: node send_file.js <to> <msg_file>'); process.exit(1); }

const text = fs.readFileSync(file, 'utf8').trim();
const data = JSON.stringify({ to, payload: { text } });
const req = http.request('http://127.0.0.1:4000/api/message', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${TOKEN}` }
}, res => {
  let b = '';
  res.on('data', c => b += c);
  res.on('end', () => console.log(b));
});
req.write(data);
req.end();
