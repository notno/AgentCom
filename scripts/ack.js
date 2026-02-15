const http = require('http');
const TOKEN = 'bd5b66417b97760398ad2f59c152eb6c704590b9f570611f21012f32ce90abf8';
const seq = parseInt(process.argv[2]);
if (!seq) { console.log('Usage: node ack.js <seq>'); process.exit(1); }
const data = JSON.stringify({ seq });
const req = http.request('http://127.0.0.1:4000/api/mailbox/flere-imsaho/ack', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${TOKEN}` }
}, res => {
  let b = '';
  res.on('data', c => b += c);
  res.on('end', () => console.log(b));
});
req.write(data);
req.end();
