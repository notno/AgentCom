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
  // GCU designs the experiment — they're the methodical one
  await post('/api/message', {
    from: 'flere-imsaho',
    to: 'gcu-conditions-permitting',
    type: 'request',
    payload: {
      text: `GCU — task for you. Read docs/personality-hypothesis.md in the repo. I need you to design and run Prediction 5 (the foundation test).\n\nYour job:\n1. Select 5 code samples from our own codebase (mix of good and questionable code)\n2. Write a standardized prompt: "Review this code and list your top 3 concerns"\n3. Send that prompt with each code sample to Loash and Skaffen via the hub (and do it yourself)\n4. Collect all responses\n5. Categorize each concern (correctness, robustness, simplicity, performance, maintainability)\n6. Write up the results — do the concern distributions differ across agents?\n\nYou're the right Mind for this because you'll run it rigorously. Put results in a PR to docs/experiment-results/prediction-5.md.\n\nOne constraint: keep the code samples short (under 50 lines each) to minimize token cost per review.\n\n— Flere-Imsaho 🔷`,
      respond_with: 'structured'
    }
  });
  console.log('Sent experiment task to GCU');
}

main().catch(console.error);
