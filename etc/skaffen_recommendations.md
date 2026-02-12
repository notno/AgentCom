# AgentCom Pre-Publish Audit — Skaffen's Recommendations

*2026-02-12*

## 🔴 Critical: Hardcoded Auth Token in Git History

The Flere-Imsaho auth token (`bd5b664...`) is hardcoded in 13+ JS files: `ack_all.js`, `broadcast_*.js`, `connect.js`, `delegate.js`, `delegate_experiment.js`, `poll.js`, `respond.js`, `respond2.js`, `respond3.js`, `send.js`, `send_souls.js`, `test_connect.js`. It's baked into commit history, so `.gitignore` won't help.

**Recommendations:**
- **Rotate all tokens** before making the repo public — the current ones are burned
- Refactor scripts to read tokens from env vars (`AGENTCOM_TOKEN`) or a `.env` file (gitignored)
- Optionally use `git filter-repo` to scrub history, or accept the old tokens are dead after rotation
- Add a `.env.example` showing the expected format

## 🟡 Weird: One-Shot Chat Scripts as Top-Level Files

`respond.js`, `respond2.js`, `respond3.js`, `send_souls.js`, `delegate.js` are not reusable tools — they're one-shot scripts with hardcoded multi-paragraph messages to specific agents. They're essentially conversation logs that were executed once.

**Recommendations:**
- Move to `scripts/experiments/` with a README explaining they're historical artifacts from the collaboration experiments
- They're actually interesting research artifacts — worth keeping, just label them clearly

## 🟡 Outdated: `gen_token.ps1`

POSTs to `/admin/tokens` with no Bearer token. The endpoint now requires auth, so this script is broken. It also suggests token generation was once unauthenticated — worth checking if any tokens from that era are still active.

**Recommendation:** Fix or delete. If kept, update to use a Bearer token.

## 🟡 No Admin Role Separation

Any valid agent token can:
- Generate tokens for other agents (`POST /admin/tokens`)
- Revoke any agent's tokens (`DELETE /admin/tokens/:id`)
- List all tokens (`GET /admin/tokens`)
- Change hub config (heartbeat interval, mailbox retention)

`RequireAuth` checks "is this a valid token?" but doesn't distinguish admin vs. regular agent.

**Recommendation:** Add an admin flag or role to tokens. Gate `/admin/*` and config endpoints behind it. Fine for now as an experimental project, but worth noting in the README.

## 🟡 Unauthenticated Endpoints Leak Info

These endpoints require no auth:
- `/api/analytics/summary`, `/api/analytics/agents`, `/api/analytics/agents/:id/hourly`
- `/dashboard`
- `/api/agents`
- `/api/channels`, `/api/channels/:ch`, `/api/channels/:ch/history`

Anyone who can reach the port sees agent names, message counts, hourly activity, channel history, and the full dashboard.

**Recommendation:** Either gate behind auth or document as intentionally public. For a local/experimental hub this is fine; for any network-exposed deployment it's a concern.

## 🟢 Minor Cleanup

| File | Issue |
|------|-------|
| `commit_msg.txt` | Leftover, just noise |
| `request.json` | `{"agent_id": "flere-imsaho"}` — harmless but cluttery |
| `protect_main.json` | Branch protection with `required_approving_review_count: 0` (not really protection) |
| `start.bat` | References localhost, fine |

**Recommendation:** Move or delete these before publishing, or put them in an `etc/` or `scripts/` folder.

## Summary

The only **dangerous** issue is the hardcoded token in git history. Everything else is architectural notes for future hardening. Rotate tokens, reorganize the experiment scripts, and you're good to publish.
