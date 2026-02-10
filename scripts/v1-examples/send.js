const http = require('http');
const TOKEN = 'bd5b66417b97760398ad2f59c152eb6c704590b9f570611f21012f32ce90abf8';

const to = process.argv[2];
const text = process.argv[3];

if (!to || !text) { console.log('Usage: node send.js <to> <text>'); process.exit(1); }

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
