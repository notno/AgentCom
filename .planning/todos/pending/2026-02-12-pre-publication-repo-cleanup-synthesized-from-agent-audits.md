---
created: 2026-02-12T19:53:44.263Z
title: Pre-publication repo cleanup synthesized from agent audits
area: general
files:
  - etc/flere_recommendations.md
  - etc/loash_recommendations.md
  - etc/skaffen_recommendations.md
---

## Problem

Three independent agent audits (Flere-Imsaho, Loash, Skaffen-Amtiskaw) reviewed the repo for publication readiness. Synthesized findings below, deduplicated and prioritized.

## Synthesized Plan

### Tier 1: MUST FIX (secrets/infra exposure)

**1. Rotate and scrub auth tokens**
- Token `bd5b66...` hardcoded in 13+ files under `scripts/v1-examples/`
- Token `617b01...` in `agentcom-client.js:5`
- Tokens are in git history — `.gitignore` won't help
- **Action:** Rotate all tokens immediately. Replace hardcoded values with `<your-token-here>` placeholders. Refactor scripts to read from `AGENTCOM_TOKEN` env var or `.env` (gitignored). Add `.env.example`. Optionally `git filter-repo` to scrub history, or accept old tokens are dead post-rotation.
- *All three agents flagged this. Skaffen noted this is the only truly dangerous issue.*

**2. Remove Tailscale IPs (3 real IPs, 30+ occurrences)**
- `100.126.22.86` (hub) — in `agentcom-client.js`, `docs/adding-agents.md` (4x), `docs/hello-minds.md`, `docs/setup.md`, `docs/agents.md`, `docs/v2-implementation-plan.md`, `agentcom-skill/SKILL.md`, `scripts/v1-examples/connect.js`, `memory/`, `.planning/`
- `100.78.168.33` (skaffen) — in `memory/2026-02-06.md`
- `100.64.0.1` — in `.planning/codebase/ARCHITECTURE.md`
- **Action:** Replace all with `your-hub-ip` or `100.x.x.x` placeholders with config note.

**3. Remove agent workspace files from git**
- `SOUL.md`, `USER.md` (contains Telegram ID), `IDENTITY.md`, `TOOLS.md` (local paths), `HEARTBEAT.md`, `AGENTS.md`, `memory/*.md` (Tailscale IPs, machine names)
- **Action:** `git rm` all, add to `.gitignore`:
  ```
  SOUL.md, USER.md, IDENTITY.md, HEARTBEAT.md, TOOLS.md, AGENTS.md, MEMORY.md, memory/, commit_msg.txt, gen_token.ps1
  ```

### Tier 2: SHOULD FIX (personal info, clarity)

**4. Personal references — decide policy**
- "Nathan" appears ~28 times across `BACKLOG.md`, `docs/agents.md`, `docs/product-vision.md`, `docs/v2-letter.md`, `.planning/` files
- GitHub username `notno` in `docs/agents.md`, `scripts/v1-examples/delegate.js`, `docs/token-efficiency.md`
- Local paths `C:\Users\nrosq\...` in ~30+ `.planning/` files
- `docs/agents.md` says "(private)" next to the repo URL — wrong once public
- **Decision needed:** Leave as authentic (author attribution) or genericize to "the operator"?

**5. Culture ship names — add context**
- `loash`, `skaffen-amtiskaw`, `gcu-conditions-permitting`, `flere-imsaho` used as real agent IDs throughout docs and scripts without explanation
- All three agents agree: keep them (they're charming), but add a disclaimer explaining the Culture series theme
- **Action:** Add a note to README or `docs/agents.md`: *"Agent names are inspired by Iain M. Banks' Culture series. These are our real test fleet identities."*

**6. v1-examples scripts — label as historical**
- `scripts/v1-examples/` contains real conversation transcripts, personality directives, one-shot chat scripts (`respond.js`, `send_souls.js`, etc.)
- **Action:** Add a README to the directory explaining these are historical artifacts from the collaboration experiments, not templates.

**7. Security hardening notes (document or fix)**
- No admin role separation — any valid token can generate/revoke tokens, change config
- Unauthenticated endpoints leak info: `/api/analytics/*`, `/dashboard`, `/api/agents`, `/api/channels/*`
- `gen_token.ps1` is broken (endpoint now requires auth) — fix or delete
- **Action:** At minimum, document these as known limitations in README. Ideally add admin flag to tokens and gate `/admin/*` endpoints.

### Tier 3: NICE TO HAVE (cleanup)

**8. Stale files**
- `commit_msg.txt`, `request.json`, `protect_main.json` (review count = 0), `gitlog.bat` — clutter
- **Action:** Delete or move to `etc/`.

**9. `.planning/` directory**
- ~100+ internal dev files with local paths and personal references. Not harmful if Tier 1 is fixed.
- **Action:** Consider `.gitignore`-ing for a cleaner public repo, or leave as transparent dev history.

## Effort Estimates (from audits)

| Tier | Items | Estimated Effort |
|------|-------|-----------------|
| Tier 1 (must) | Tokens, IPs, workspace files | 30-45 min |
| Tier 2 (should) | Personal refs, Culture context, scripts, security docs | 45-60 min |
| Tier 3 (nice) | Stale files, .planning | 15 min |

## Key Insight

All three agents independently confirmed: **the Elixir source code (`lib/`) is clean** — no secrets, no hardcoded names, fully generic. The README uses proper generic examples. The problems are entirely in docs, scripts, and committed workspace files.
