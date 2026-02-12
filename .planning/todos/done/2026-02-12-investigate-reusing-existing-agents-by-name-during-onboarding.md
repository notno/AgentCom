---
created: 2026-02-12T12:28:00Z
title: Investigate reusing existing agents by name during onboarding
area: api
files:
  - sidecar/add-agent.js:270-317
  - lib/agent_com/endpoint.ex:1177-1210
---

## Problem

Currently, if an agent name already exists, onboarding hard-fails:
- Hub returns 409 "agent_id already registered" (endpoint.ex:1194)
- Sidecar fatals with "Choose a different name with --name or remove the existing agent first" (add-agent.js:317)

This means if you want to re-onboard an agent (e.g., new machine, reinstall, lost config), you must first manually remove the old agent entry. There's no way to say "I am this existing agent, give me a fresh sidecar setup with my existing token/identity."

Use cases:
- Agent machine reimaged, need to reconnect with same identity
- Sidecar config lost/corrupted, need to re-provision
- Moving an agent to a different machine

## Solution

Options to investigate:
- Option A: `--rejoin` flag on add-agent.js that sends a different request (e.g., POST /api/onboard/rejoin) which returns existing token and config for a known agent_id (requires some auth proof)
- Option B: Allow 409 response to include enough info to continue onboarding (token reuse) if the operator confirms
- Option C: Admin endpoint to reset an agent's sidecar state without deleting the agent identity
- Consider: what auth is needed to prove you're the legitimate owner of an existing agent name?
