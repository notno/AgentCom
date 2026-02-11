'use strict';

const { parseArgs } = require('node:util');
const http = require('http');
const https = require('https');

// ---------------------------------------------------------------------------
// CLI flag parsing
// ---------------------------------------------------------------------------

const options = {
  description: { type: 'string' },
  hub:         { type: 'string' },
  token:       { type: 'string' },
  priority:    { type: 'string' },
  target:      { type: 'string' },
  metadata:    { type: 'string' },
  help:        { type: 'boolean', short: 'h' }
};

let args;
try {
  args = parseArgs({ options, allowPositionals: false });
} catch (err) {
  console.error(`Error: ${err.message}`);
  printUsage();
  process.exit(1);
}

if (args.values.help) {
  printUsage();
  process.exit(0);
}

function printUsage() {
  console.error(`
Usage: node agentcom-submit.js --description "..." --hub <hub-url> --token <token>

Flags:
  --description  (required)  Task description
  --hub          (required)  Hub API URL (e.g. http://localhost:4000)
  --token        (required)  Auth token for API access
  --priority     (optional)  Priority: low, normal (default), urgent, critical
  --target       (optional)  Target agent name for directed task
  --metadata     (optional)  JSON string of additional metadata

Examples:
  node agentcom-submit.js --description "Fix the login bug" --hub http://hub:4000 --token abc123
  node agentcom-submit.js --description "Deploy v2" --hub http://hub:4000 --token abc123 --priority urgent
  node agentcom-submit.js --description "Fix issue #42" --hub http://hub:4000 --token abc123 --metadata '{"issue": 42}'
`.trim());
}

// ---------------------------------------------------------------------------
// Validate required flags
// ---------------------------------------------------------------------------

const description = args.values.description;
const hub = args.values.hub;
const token = args.values.token;
const priority = args.values.priority || 'normal';
const target = args.values.target;
const metadataRaw = args.values.metadata;

if (!description) {
  console.error('Error: --description is required');
  printUsage();
  process.exit(1);
}

if (!hub) {
  console.error('Error: --hub is required');
  printUsage();
  process.exit(1);
}

if (!token) {
  console.error('Error: --token is required');
  printUsage();
  process.exit(1);
}

// Validate priority
const VALID_PRIORITIES = ['low', 'normal', 'urgent', 'critical'];
if (!VALID_PRIORITIES.includes(priority)) {
  console.error(`Error: --priority must be one of: ${VALID_PRIORITIES.join(', ')}`);
  process.exit(1);
}

// Parse metadata JSON if provided
let metadata = {};
if (metadataRaw) {
  try {
    metadata = JSON.parse(metadataRaw);
    if (typeof metadata !== 'object' || Array.isArray(metadata)) {
      console.error('Error: --metadata must be a JSON object');
      process.exit(1);
    }
  } catch (err) {
    console.error(`Error: --metadata is not valid JSON: ${err.message}`);
    process.exit(1);
  }
}

// Add target agent to metadata if provided
if (target) {
  metadata.target_agent = target;
}

// ---------------------------------------------------------------------------
// HTTP helper (async, inline -- standalone script, no shared modules)
// ---------------------------------------------------------------------------

function httpRequest(method, url, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const lib = parsed.protocol === 'https:' ? https : http;
    const payload = body ? JSON.stringify(body) : null;

    const opts = {
      method,
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname + parsed.search,
      headers: {
        ...headers,
        ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {})
      }
    };

    const req = lib.request(opts, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        let parsed;
        try { parsed = JSON.parse(data); } catch { parsed = data; }
        resolve({ status: res.statusCode, data: parsed });
      });
    });

    req.on('error', (err) => reject(err));
    req.setTimeout(15000, () => {
      req.destroy(new Error('Request timed out'));
    });
    if (payload) req.write(payload);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Submit task
// ---------------------------------------------------------------------------

async function main() {
  const hubUrl = hub.replace(/\/$/, '');
  const taskPayload = {
    description,
    priority,
    metadata,
    needed_capabilities: []
  };

  try {
    const res = await httpRequest('POST', `${hubUrl}/api/tasks`, taskPayload, {
      'Authorization': `Bearer ${token}`
    });

    if (res.status === 201) {
      const task = res.data;
      console.log(`\nTask submitted successfully.`);
      console.log(`  Task ID:   ${task.task_id}`);
      console.log(`  Priority:  ${task.priority}`);
      console.log(`  Status:    ${task.status || 'queued'}`);
      console.log(`  Created:   ${task.created_at}`);
      console.log('');
      console.log(`Track: curl -H "Authorization: Bearer ${token}" ${hubUrl}/api/tasks/${task.task_id}`);
    } else {
      console.error(`\nError submitting task (HTTP ${res.status}):`);
      console.error(typeof res.data === 'string' ? res.data : JSON.stringify(res.data, null, 2));
      process.exit(1);
    }
  } catch (err) {
    console.error(`\nError: ${err.message}`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(`Unexpected error: ${err.message}`);
  process.exit(1);
});
