#!/usr/bin/env node
'use strict';

const { parseArgs } = require('node:util');
const http = require('http');
const https = require('https');

// ---------------------------------------------------------------------------
// CLI flag parsing
// ---------------------------------------------------------------------------

const options = {
  description: { type: 'string' },
  criteria:    { type: 'string', multiple: true },
  hub:         { type: 'string' },
  token:       { type: 'string' },
  priority:    { type: 'string' },
  tags:        { type: 'string' },
  repo:        { type: 'string' },
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
Usage: node agentcom-submit-goal.js --description "..." --criteria "..." --hub <hub-url> --token <token>

Flags:
  --description  (required)  Goal description
  --criteria     (required)  Success criteria (repeatable, one per flag)
  --hub          (optional)  Hub API URL (default: http://localhost:4000)
  --token        (required)  Auth token for API access
  --priority     (optional)  Priority: urgent, high, normal (default), low
  --tags         (optional)  Comma-separated tags
  --repo         (optional)  Target repository URL

Examples:
  node agentcom-submit-goal.js \\
    --description "Implement rate limiting" \\
    --criteria "Returns 429 after 100 req/min" \\
    --criteria "Configurable via Config" \\
    --hub http://localhost:4000 \\
    --token abc123

  node agentcom-submit-goal.js \\
    --description "Fix login bug" \\
    --criteria "Login succeeds with valid creds" \\
    --token abc123 \\
    --priority urgent \\
    --tags security,auth \\
    --repo https://github.com/user/repo
`.trim());
}

// ---------------------------------------------------------------------------
// Validate required flags
// ---------------------------------------------------------------------------

const description = args.values.description;
const criteria = args.values.criteria;
const hub = args.values.hub || 'http://localhost:4000';
const token = args.values.token;
const priority = args.values.priority || 'normal';
const tagsRaw = args.values.tags;
const repo = args.values.repo;

if (!description) {
  console.error('Error: --description is required');
  printUsage();
  process.exit(1);
}

if (!criteria || criteria.length === 0) {
  console.error('Error: --criteria is required (at least one)');
  printUsage();
  process.exit(1);
}

if (!token) {
  console.error('Error: --token is required');
  printUsage();
  process.exit(1);
}

// Validate priority
const VALID_PRIORITIES = ['urgent', 'high', 'normal', 'low'];
if (!VALID_PRIORITIES.includes(priority)) {
  console.error(`Error: --priority must be one of: ${VALID_PRIORITIES.join(', ')}`);
  process.exit(1);
}

// Parse tags
const tags = tagsRaw ? tagsRaw.split(',').map(t => t.trim()).filter(Boolean) : [];

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
// Submit goal
// ---------------------------------------------------------------------------

async function main() {
  const hubUrl = hub.replace(/\/$/, '');
  const goalPayload = {
    description,
    success_criteria: criteria,
    priority,
    source: 'cli',
    tags,
  };

  if (repo) {
    goalPayload.repo = repo;
  }

  try {
    const res = await httpRequest('POST', `${hubUrl}/api/goals`, goalPayload, {
      'Authorization': `Bearer ${token}`
    });

    if (res.status === 201) {
      const goal = res.data;
      console.log(`Goal submitted: ${goal.goal_id}`);
    } else {
      console.error(`Error submitting goal (HTTP ${res.status}):`);
      console.error(typeof res.data === 'string' ? res.data : JSON.stringify(res.data, null, 2));
      process.exit(1);
    }
  } catch (err) {
    console.error(`Connection error: ${err.message}`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(`Unexpected error: ${err.message}`);
  process.exit(1);
});
