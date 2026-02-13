---
created: 2026-02-12T21:55:00.000Z
title: Dashboard task submission UI
area: ui
files:
  - lib/agent_com/dashboard.ex
  - sidecar/agentcom-submit.js
---

## Problem

The dashboard (`/dashboard`) is view-only — it shows agents, tasks, metrics, and alerts but has no way to submit a task. The only submission paths are the CLI script (`agentcom-submit.js`) and raw curl to `POST /api/tasks`. This means the "front door" for submitting work requires a terminal and a token on hand.

## Solution

Add a task submission form to the dashboard UI:

1. **Form fields:** description (required), priority dropdown (low/normal/urgent/critical), optional metadata JSON textarea
2. **Auth:** Dashboard is currently no-auth (local network). Task submission requires a token. Options:
   - Add a token input field to the form (simple, explicit)
   - Dashboard session token (stored in localStorage after one-time entry)
   - Admin token configured server-side (dashboard acts as admin)
3. **Submit:** POST to `/api/tasks` with the token, show success/error inline
4. **Nice to have:** After submission, task appears in the task list via existing WebSocket updates (already wired)

The `agentcom-submit.js` CLI is the reference for the payload shape — the dashboard form would hit the same endpoint.
