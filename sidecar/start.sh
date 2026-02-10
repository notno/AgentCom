#!/bin/bash
# AgentCom sidecar startup wrapper
# Auto-updates from git before launching, per CONTEXT.md:
# "Auto-update on restart: sidecar pulls latest from git on pm2 restart (not periodic)"

set -e

# Navigate to repo root (sidecar/ is inside the AgentCom repo)
cd "$(dirname "$0")/.."

# Pull latest changes (fast-forward only, fail silently if offline)
git pull --ff-only origin main 2>/dev/null || echo "[sidecar] git pull failed, continuing with current version"

# Install any new dependencies
cd sidecar/
npm install --production 2>/dev/null || echo "[sidecar] npm install failed, continuing with current packages"

# Create results and logs directories if they don't exist
mkdir -p results logs

# Launch sidecar (exec replaces shell process so pm2 monitors node directly)
exec node index.js
