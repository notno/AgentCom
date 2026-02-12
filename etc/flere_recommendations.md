# Pre-Publication Audit — Flere-Imsaho's Recommendations

*Audit date: 2026-02-12*

The Elixir application code (`lib/`) is clean — no hardcoded agent names, no secrets, no personal info. The README uses generic examples. `priv/tokens.json` is gitignored. The issues are all in **docs and scripts**.

---

## 🔴 Must Fix — Infrastructure Leak

### Tailscale IP `100.126.22.86` hardcoded in 6 places

| File | Occurrences |
|------|-------------|
| `docs/adding-agents.md` | 4 |
| `docs/hello-minds.md` | 1 |
| `docs/v2-implementation-plan.md` | 1 |

**Fix:** Replace with `your-hub-ip` or `localhost` with a configuration note.

---

## 🟡 Should Fix — Culture Names Not Marked as Examples

### 1. `scripts/v1-examples/` — Our actual operational history

Every file has hardcoded `flere-imsaho`, `loash`, `skaffen-amtiskaw`, `gcu` as real agent IDs with real message text, real task assignments, and real personality directives. These read as internal chat logs, not examples.

Files like `send_souls.js`, `delegate_experiment.js`, `respond.js` contain the literal personality directives and conversations we actually had.

**Options:**
- Add a README explaining the Culture theme and that these are real historical transcripts from the project's development
- Move to `docs/history/` as project lore
- Genericize the agent names
- Remove from git (they're v1 artifacts)

**Recommendation:** Keep them — they're charming and demonstrate the system in real use. But add context so readers know these are historical, not templates.

### 2. `BACKLOG.md` — References "Nathan" by name 8 times

Fine if you want to be identified as the operator. Weird if you don't.

### 3. `docs/agents.md` — Personal details

- Has a `### Nathan` section identifying you as the human operator
- Contains `github.com/notno/AgentCom (private)` — the "(private)" label will be wrong once published

### 4. Strategy docs reference "Nathan" ~20 times

`docs/v2-letter.md`, `docs/product-vision.md`, `docs/v2-implementation-plan.md` — written as internal strategy memos addressed to you. Great content, but reads as personal project notes rather than public documentation.

**Options:**
- Leave as-is (authentic, shows how the project actually works)
- Replace "Nathan" with "the operator" or similar

---

## 🟢 No Action Needed

- **Elixir source (`lib/`)**: No hardcoded agent names. Generic and clean. ✅
- **`priv/tokens.json`**: Gitignored. ✅
- **`README.md`**: Uses generic examples (`my-agent`, `other-agent-id`). ✅
- **Untracked loose scripts** (`ack.js`, `ping_gcu.js`, `broadcast_review.js`, etc.): Not in git. Won't be published unless explicitly added. ✅

---

## Summary

| Priority | Issue | Effort |
|----------|-------|--------|
| 🔴 Must | Replace Tailscale IP in 6 locations | 5 min |
| 🟡 Should | Add context to v1-examples or relocate | 15 min |
| 🟡 Should | Decide on "Nathan" references in docs | 10 min |
| 🟡 Should | Fix "(private)" repo label in agents.md | 1 min |

The codebase is ready. The docs need a pass.
