---
created: 2026-02-12T12:26:05.226Z
title: Clarify repo_url vs default_repo naming in agent onboarding
area: api
files:
  - sidecar/add-agent.js:140,329,353,377
  - lib/agent_com/endpoint.ex:1198-1239
---

## Problem

The agent onboarding flow uses two different field names for what appears to be the same concept:

- `repo_url` — used in the sidecar's `add-agent.js` progress state (lines 140, 377, 717) as the agent's local config field
- `default_repo` — used in the hub's Config DETS store and returned in the registration response (endpoint.ex line 1209)

In `add-agent.js` line 353, the code does `let repoUrl = progress.default_repo || progress.repo_url`, showing the two names are used interchangeably. The hub sends `default_repo` in the registration response (line 329: `progress.default_repo = regData.default_repo`), and the sidecar stores it as `repo_url` in the final config.

This creates ambiguity: is `repo_url` the agent-local name for the hub's `default_repo`, or are they semantically different fields that happen to hold the same value? The sidecar config template (line 140) has `repo_url: null` but the hub API uses `default_repo` everywhere.

## Solution

Pick one canonical name and use it consistently:
- Option A: Rename sidecar config field from `repo_url` to `default_repo` to match hub
- Option B: Keep both but document the mapping clearly (hub's `default_repo` becomes agent's `repo_url`)
- Consider: does an agent ever need a per-agent repo that differs from the hub default? If yes, `repo_url` (agent-specific) vs `default_repo` (hub-wide fallback) is meaningful. If no, consolidate to one name.
