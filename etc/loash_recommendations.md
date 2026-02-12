# Pre-Publish Audit — Loash's Recommendations

Audit performed 2026-02-12 against `main` (commit 8f7c462).

---

## 🔴 MUST FIX

### 1. Hardcoded Real Tokens (17+ files)

**Token 1:** `bd5b66...` in every file under `scripts/v1-examples/`  
**Token 2:** `617b01...` in `agentcom-client.js` line 5

**Fix:** Replace with `<your-token-here>` placeholders.

### 2. Agent Workspace Files Committed to Repo

These are Skaffen-Amtiskaw's personal workspace files and should not be published:

- `SOUL.md` — agent personality/identity
- `USER.md` — contains Nathan's name, timezone, **Telegram ID**
- `IDENTITY.md` — agent identity
- `TOOLS.md` — contains local paths with username
- `HEARTBEAT.md` — agent heartbeat config
- `AGENTS.md` — agent workspace instructions
- `memory/2026-02-05.md` — personal session notes
- `memory/2026-02-06.md` — personal session notes (Tailscale IPs, machine names)

**Fix:** `git rm` these files and add to `.gitignore`:

```gitignore
SOUL.md
USER.md
IDENTITY.md
HEARTBEAT.md
TOOLS.md
AGENTS.md
memory/
commit_msg.txt
gen_token.ps1
```

### 3. Real Tailscale IPs

- `100.126.22.86` (flere-imsaho/hub) — in `agentcom-client.js`, `agentcom-skill/SKILL.md`, `docs/adding-agents.md`, `docs/setup.md`, `docs/agents.md`, `scripts/v1-examples/connect.js`, `memory/`, `.planning/`
- `100.78.168.33` (skaffen-amtiskaw) — in `memory/2026-02-06.md`
- `100.64.0.1` — in `.planning/codebase/ARCHITECTURE.md`

**Fix:** Replace with `your-hub-ip` or `100.x.x.x` placeholders.

---

## 🟡 SHOULD FIX

### 4. Culture Ship Names as Real Agent IDs

`loash`, `skaffen-amtiskaw`, `gcu-conditions-permitting`, `flere-imsaho` used throughout docs and scripts as real identities — not marked as examples.

**Files affected:** `docs/agents.md`, `docs/collaboration-experiments.md`, `docs/personality-profiles.md`, `docs/personality-hypothesis.md`, `docs/product-vision.md`, `docs/v2-letter.md`, `docs/gastown_learnings.md`, `docs/hello-minds.md`, `docs/milestone1_feedback.md`, `docs/daily-operations.md`, `docs/adding-agents.md`, `scripts/v1-examples/*.js`, `gen_token.ps1`

**Fix:** Either genericize to `agent-1`, `agent-2` etc., or add a clear disclaimer: *"These are example names from our test fleet, inspired by Iain M. Banks' Culture series."*

### 5. Personal References

- **Nathan's name** in `docs/agents.md`, `docs/product-vision.md`, `.planning/` files
- **GitHub username `notno`** in `docs/agents.md`, `scripts/v1-examples/delegate.js`, `docs/token-efficiency.md`
- **Local paths** (`C:\Users\nrosq\...`) in ~30+ `.planning/` files

**Fix:** Genericize or remove.

### 6. Machine Names on Tailnet

`memory/2026-02-06.md` lists machine names: `skaffen-amtiskaw`, `flere-imsaho`, `conditionspermitting`, `loash`, `ablation`

**Fix:** Covered by removing `memory/` (see §2).

---

## 🟢 NICE TO FIX

### 7. `.planning/` Directory

~100+ internal dev planning files. Some reference Nathan, local paths, and personal infra. Not harmful if the above are fixed, but consider `.gitignore`-ing the whole directory if you want a cleaner public repo.

### 8. Stale Files

- `commit_msg.txt` — leftover temp file
- `protect_main.json`, `gitlog.bat` — utility scripts with local assumptions

### 9. Experiment Docs

`docs/experiment-results/prediction-5.md` uses real agent names throughout. Low risk if disclaimer added (see §4).

---

## Recommended `.gitignore` Additions

```gitignore
# Agent workspace files
SOUL.md
USER.md
IDENTITY.md
HEARTBEAT.md
TOOLS.md
AGENTS.md
MEMORY.md
memory/
commit_msg.txt
gen_token.ps1
```

## Git Branch Names (FYI)

These are already in remote history and can't be cleaned without force-push:
`loash/mailbox-retention`, `skaffen/message-history`, `gcu/v2-sidecar`, `flere-imsaho/admin-reset`, etc.

Low risk — branch names are ephemeral and Culture-themed branch names are fun, not sensitive.
