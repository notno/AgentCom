'use strict';

const { parseArgs } = require('node:util');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');

// ---------------------------------------------------------------------------
// CLI flag parsing
// ---------------------------------------------------------------------------

const options = {
  name:  { type: 'string' },
  hub:   { type: 'string' },
  token: { type: 'string' },
  help:  { type: 'boolean', short: 'h' }
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
Usage: node remove-agent.js --name <agent-name> --hub <hub-url> --token <token>

Flags:
  --name   (required)  Agent name to remove
  --hub    (required)  Hub API URL (e.g. http://localhost:4000)
  --token  (optional)  Auth token. If omitted, reads from agent config.

Performs clean teardown:
  1. Stops and deletes pm2 process
  2. Revokes hub token
  3. Deletes agent directory (~/.agentcom/<name>/)
`.trim());
}

// ---------------------------------------------------------------------------
// Validate required flags
// ---------------------------------------------------------------------------

const name = args.values.name;
const hub = args.values.hub;

if (!name) {
  console.error('Error: --name is required');
  printUsage();
  process.exit(1);
}

if (!hub) {
  console.error('Error: --hub is required');
  printUsage();
  process.exit(1);
}

// Resolve token: from flag, or from agent config file
let token = args.values.token;
if (!token) {
  const homeDir = process.env.HOME || process.env.USERPROFILE;
  const configPath = path.join(homeDir, '.agentcom', name, 'repo', 'sidecar', 'config.json');
  if (fs.existsSync(configPath)) {
    try {
      const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      token = config.token;
      if (token) {
        console.log(`  (Read token from ${configPath})`);
      }
    } catch {
      // config exists but can't be parsed -- continue without token
    }
  }
  if (!token) {
    console.error(`Error: --token is required (could not read token from ${configPath || '~/.agentcom/' + name + '/repo/sidecar/config.json'})`);
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// HTTP helper (async, inline -- standalone script, no shared modules)
// ---------------------------------------------------------------------------

function httpRequest(method, url, headers = {}) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const lib = parsed.protocol === 'https:' ? https : http;

    const opts = {
      method,
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname + parsed.search,
      headers
    };

    const req = lib.request(opts, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        let data;
        try { data = JSON.parse(body); } catch { data = body; }
        resolve({ status: res.statusCode, data });
      });
    });

    req.on('error', (err) => reject(err));
    req.setTimeout(15000, () => {
      req.destroy(new Error('Request timed out'));
    });
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Teardown steps
// ---------------------------------------------------------------------------

async function main() {
  console.log(`\nRemoving agent "${name}"...\n`);

  let failures = 0;

  // Step 1: Stop pm2 process
  const pm2Name = `agentcom-${name}`;
  console.log(`[1/3] Stopping pm2 process "${pm2Name}"...`);
  try {
    try {
      execSync(`pm2 stop ${pm2Name}`, { stdio: 'pipe', windowsHide: true });
    } catch {
      // process may not exist -- that's fine
    }
    try {
      execSync(`pm2 delete ${pm2Name}`, { stdio: 'pipe', windowsHide: true });
    } catch {
      // process may not exist -- that's fine
    }
    try {
      execSync('pm2 save', { stdio: 'pipe', windowsHide: true });
    } catch {
      // pm2 save failure is non-critical
    }
    console.log('      done');
  } catch (err) {
    console.warn(`      warning: ${err.message}`);
    failures++;
  }

  // Step 2: Revoke token from hub
  console.log('[2/3] Revoking hub token...');
  try {
    const hubUrl = hub.replace(/\/$/, '');
    const res = await httpRequest('DELETE', `${hubUrl}/admin/tokens/${name}`, {
      'Authorization': `Bearer ${token}`
    });
    if (res.status === 200) {
      console.log('      done');
    } else {
      console.warn(`      warning: hub returned status ${res.status}`);
      failures++;
    }
  } catch (err) {
    console.warn(`      warning: ${err.message}`);
    failures++;
  }

  // Step 3: Delete agent directory
  const homeDir = process.env.HOME || process.env.USERPROFILE;
  const agentDir = path.join(homeDir, '.agentcom', name);
  console.log(`[3/3] Removing agent directory "${agentDir}"...`);
  try {
    if (fs.existsSync(agentDir)) {
      fs.rmSync(agentDir, { recursive: true, force: true });
      console.log('      done');
    } else {
      console.log('      already removed');
    }
  } catch (err) {
    console.warn(`      warning: ${err.message}`);
    failures++;
  }

  // Summary
  console.log(`\nAgent "${name}" has been removed.`);
  console.log(`- pm2 process stopped and deleted`);
  console.log(`- Hub token revoked`);
  console.log(`- Directory ~/.agentcom/${name}/ deleted`);

  if (failures === 3) {
    console.error('\nAll steps failed -- check errors above.');
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(`Unexpected error: ${err.message}`);
  process.exit(1);
});
