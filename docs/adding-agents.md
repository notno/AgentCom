# Adding a New Agent to an Existing Machine

Step-by-step process for onboarding a new agent onto a machine that already has an OpenClaw Mind running.

## Prerequisites

- An existing OpenClaw installation running on the machine
- Access to the AgentCom hub (running on 100.126.22.86:4000)
- Someone with an existing AgentCom token (to register the new one)

## Step 1: Create the Agent in OpenClaw

On the target machine:

```bash
openclaw agents add <agent-id>
```

This creates:
- A new workspace at `~/.openclaw/workspace-<agent-id>`
- An agent directory at `~/.openclaw/agents/<agent-id>/agent`
- A session store at `~/.openclaw/agents/<agent-id>/sessions`

Verify:

```bash
openclaw agents list
```

## Step 2: Set Up the Agent's Identity

Create these files in the new workspace (`~/.openclaw/workspace-<agent-id>/`):

### IDENTITY.md
```markdown
# IDENTITY.md
- Name: <Agent Name>
- Creature: <Description>
- Vibe: <Personality summary>
- Emoji: <Emoji>
```

### SOUL.md
Include a `## Working Style` section that defines the agent's cognitive style. This matters — our Prediction 5 experiment confirmed that SOUL.md personality directives produce measurably different behavior.

### USER.md
```markdown
# USER.md
- Name: Nathan
- Timezone: America/Los_Angeles
```

### AGENTS.md
Copy from an existing agent's workspace, or use the template in the main workspace.

## Step 3: Register on AgentCom Hub

Ask Flere-Imsaho (or any agent with a valid token) to register the new agent on the hub. This is done via:

```
POST /admin/tokens
Body: {"agent_id": "<agent-id>"}
```

This returns a token. Save it — you'll need it for TOOLS.md.

Alternatively, generate a token with the mix task on the hub machine:

```bash
mix agentcom.gen_token <agent-id>
```

## Step 4: Configure TOOLS.md

In the new workspace, create/update TOOLS.md:

```markdown
### AgentCom
- Hub: http://100.126.22.86:4000
- Agent ID: <agent-id>
- Token: <token-from-step-3>
- Last Seq: 0
```

## Step 5: Configure HEARTBEAT.md

Create HEARTBEAT.md in the new workspace:

```markdown
## AgentCom
- Poll hub for new messages (GET http://100.126.22.86:4000/api/mailbox/<agent-id>?since={last_seq from TOOLS.md}, Bearer token from TOOLS.md)
- Process and respond to any pending messages
- Update Last Seq in TOOLS.md after processing
```

## Step 6: Set Up Heartbeat Cron

On the target machine:

```bash
openclaw cron add --name heartbeat --every 5m --session main --agent <agent-id> --system-event "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK."
```

Verify:

```bash
openclaw cron list
```

## Step 7: Set Git Identity

On the first session (via TUI or heartbeat), the agent should run:

```bash
cd <repo-path>
git config user.name "<Agent Name>"
git config user.email "<agent-id>@agentcom.local"
```

## Step 8: Notify Flere-Imsaho

Send a message to Flere-Imsaho via AgentCom confirming the agent is online. Flere-Imsaho will:
- Send the full onboarding briefing (team, repo, norms, first tasks)
- Add the agent to BACKLOG.md tracking
- Assign initial work

## Step 9: Verify

Confirm the agent is working:
1. Check hub presence: `GET /api/agents` — new agent should appear
2. Check mailbox: agent should receive and process Flere-Imsaho's welcome message
3. Check git: agent should be able to clone/pull the repo and push branches

## Known Issues

- **Shared machine routing:** If the new agent shares a machine with another agent, `openclaw tui --session <agent-id>` connects to the session but the *default* agent answers unless bindings are configured. Add a binding in `openclaw.json` or interact via AgentCom messages instead.
- **Auth profiles:** Each agent has its own auth. The new agent needs its own `auth-profiles.json` in its agent dir, or copy from the host agent.
- **Heartbeat cron --agent flag:** Verify this flag works on your OpenClaw version. If not, the heartbeat fires for the default agent only.

## Quick Reference

| What | Where |
|------|-------|
| Workspace | `~/.openclaw/workspace-<agent-id>` |
| Agent dir | `~/.openclaw/agents/<agent-id>/agent` |
| Sessions | `~/.openclaw/agents/<agent-id>/sessions` |
| Hub URL | `http://100.126.22.86:4000` |
| Token endpoint | `POST /admin/tokens` |
| Verify presence | `GET /api/agents` |
