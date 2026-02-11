---
phase: 08-onboarding
verified: 2026-02-11T21:38:18Z
status: human_needed
score: 12/12 must-haves verified
re_verification: false
human_verification:
  - test: Full end-to-end agent onboarding
    expected: Running add-agent creates agent, starts pm2 process, completes test task
    why_human: Requires running hub instance, pm2, git, OpenClaw on a real machine
  - test: Agent removal
    expected: Running remove-agent stops pm2, revokes token, deletes directory
    why_human: Requires live pm2 process and hub instance to verify cleanup
  - test: Task submission
    expected: Running agentcom-submit creates task in hub queue
    why_human: Requires running hub instance to verify task creation
  - test: Resume capability
    expected: Running add-agent --resume after interruption skips completed steps
    why_human: Requires interrupting onboarding mid-flow and resuming
---

# Phase 8: Onboarding Verification Report

**Phase Goal:** Adding a new agent to the system takes one command and verifies everything works

**Verified:** 2026-02-11T21:38:18Z

**Status:** human_needed

**Re-verification:** No - initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | POST /api/onboard/register with agent name returns agent_id + token + hub config without requiring authentication | VERIFIED | Route exists in endpoint.ex:739, calls Auth.generate, returns 201 with token + hub URLs + default_repo |
| 2 | GET /api/config/default-repo returns the configured default repository URL | VERIFIED | Route exists in endpoint.ex:772, calls Config.get(:default_repo), returns 200 with value or nil |
| 3 | PUT /api/config/default-repo sets the default repository URL (auth required) | VERIFIED | Route exists in endpoint.ex:780, calls RequireAuth plug, calls Config.put(:default_repo, url) |
| 4 | DELETE /admin/tokens/:agent_id revokes agent token (used by remove-agent) | VERIFIED | Route exists in endpoint.ex:476, calls RequireAuth, calls Auth.revoke |
| 5 | Running add-agent --hub generates Culture ship name, registers, clones, configures, installs, starts pm2, verifies test task | VERIFIED | add-agent.js implements 7-step flow: preflight, register, clone, config, npm install, pm2 start, test task poll |
| 6 | Re-running add-agent --hub --resume skips already-completed steps | VERIFIED | --resume flag implemented, progress tracked in .onboard-progress.json |
| 7 | Test task completes within 30 seconds or add-agent reports hard failure | VERIFIED | Test task polls every 2s for 30s, logs HARD FAILURE on timeout |
| 8 | Pre-flight checks fail fast if hub unreachable, OpenClaw missing, Node < 18, pm2 missing, or git missing | VERIFIED | Pre-flight checks all prerequisites: Node.js version, pm2, git, openclaw, hub reachability |
| 9 | Step-by-step log output shows progress: [1/N] Step... done | VERIFIED | logStep() helper formats output as [n/7], used throughout |
| 10 | Running remove-agent stops pm2, revokes token, deletes directory | VERIFIED | remove-agent.js implements 3-step teardown: pm2 stop/delete, token revoke, directory delete |
| 11 | Running agentcom-submit submits task and returns task_id | VERIFIED | agentcom-submit.js posts to /api/tasks, prints task_id on success |
| 12 | agentcom-submit supports --priority, --target, and --metadata flags | VERIFIED | Flags defined, priority validated, metadata parsed as JSON |

**Score:** 12/12 truths verified (automated checks only)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| lib/agent_com/endpoint.ex | Registration and config API endpoints | VERIFIED | POST /api/onboard/register, GET/PUT /api/config/default-repo routes exist and implement full logic |
| sidecar/culture-names.js | Culture ship name list and random selection | VERIFIED | 65 Culture ship names, getNames() and generateName() exports, syntax valid |
| sidecar/add-agent.js | One-command agent onboarding script | VERIFIED | 762 lines, parseArgs, 7-step flow, --resume support, syntax valid |
| sidecar/remove-agent.js | Agent teardown script | VERIFIED | 210 lines, parseArgs, 3-step teardown, best-effort cleanup, syntax valid |
| sidecar/agentcom-submit.js | Task submission CLI | VERIFIED | 191 lines, parseArgs, full flag support, syntax valid |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| POST /api/onboard/register | AgentCom.Auth.generate/1 | Token generation | WIRED | endpoint.ex:749 calls Auth.generate |
| GET /api/config/default-repo | AgentCom.Config.get/1 | DETS config lookup | WIRED | endpoint.ex:773 calls Config.get |
| PUT /api/config/default-repo | AgentCom.Config.put/2 | DETS config write | WIRED | endpoint.ex:787 calls Config.put |
| sidecar/add-agent.js | POST /api/onboard/register | HTTP registration | WIRED | add-agent.js:307 posts to endpoint |
| sidecar/add-agent.js | GET /api/config/default-repo | HTTP config fetch | WIRED | default_repo in registration response |
| sidecar/add-agent.js | sidecar/culture-names.js | Name generation | WIRED | add-agent.js:273 requires module |
| sidecar/add-agent.js | POST /api/tasks | HTTP test task submit | WIRED | add-agent.js:591 posts test task |
| sidecar/add-agent.js | GET /api/tasks/:task_id | HTTP test task polling | WIRED | add-agent.js:632 polls every 2s |
| sidecar/remove-agent.js | DELETE /admin/tokens/:agent_id | HTTP token revocation | WIRED | remove-agent.js:165 deletes token |
| sidecar/agentcom-submit.js | POST /api/tasks | HTTP task submission | WIRED | agentcom-submit.js:164 posts task |

### Requirements Coverage

| Requirement | Status | Blocking Issue |
|-------------|--------|----------------|
| ONBD-01: One-command script generates auth token, creates sidecar config, installs as pm2 process, and verifies hub connection | SATISFIED (awaiting human verification) | All artifacts verified; needs end-to-end test on real machine |

### Anti-Patterns Found

None. All scripts are substantive implementations with zero TODO/FIXME/PLACEHOLDER comments, full error handling, proper CLI flag parsing, complete HTTP request/response handling, step-based progress tracking with resume capability, and all syntax checks pass.

### Human Verification Required

#### 1. Full End-to-End Agent Onboarding

**Test:** On a machine with Node.js >= 18, pm2, git, and OpenClaw installed, run:
```
node sidecar/add-agent.js --hub http://<hub-hostname>:4000
```

**Expected:**
- All 7 steps complete successfully with [n/7] progress indicators
- Quick-start guide printed with agent name, token, commands
- Agent appears in hub dashboard as connected/idle
- Test task completes (visible in hub task history)
- pm2 status shows process running

**Why human:** Requires running hub instance, pm2 daemon, git, OpenClaw, and network connectivity. Cannot be verified programmatically without live infrastructure.

#### 2. Resume Capability After Interruption

**Test:** Interrupt onboarding after step 3, then run:
```
node sidecar/add-agent.js --hub http://<hub-hostname>:4000 --name gcu-<interrupted-name> --resume
```

**Expected:**
- Script logs "Resuming onboarding" message
- Steps 1-3 show "skip" status
- Steps 4-7 execute normally
- Onboarding completes successfully

**Why human:** Requires deliberately interrupting the script mid-execution and verifying stateful resume behavior.

#### 3. Agent Removal Cleanup

**Test:** After successful onboarding, run:
```
node sidecar/remove-agent.js --name gcu-<name> --hub http://<hub-hostname>:4000 --token <token>
```

**Expected:**
- pm2 process stops and is deleted
- Hub shows agent as disconnected/offline
- Token is revoked (401 on API calls)
- Directory ~/.agentcom/gcu-<name>/ is deleted

**Why human:** Requires live pm2 process and hub instance to verify complete cleanup across all layers.

#### 4. Task Submission

**Test:** Run:
```
node sidecar/agentcom-submit.js --description "Test task" --hub http://<hub>:4000 --token <token> --priority urgent
```

**Expected:**
- Script prints "Task submitted successfully" with task_id, priority, status
- Task appears in hub dashboard queue with priority "urgent"
- curl command printed to track task works

**Why human:** Requires running hub instance to verify task actually created in queue with correct attributes.

---

## Summary

**Status: human_needed**

All automated verifications passed:
- All 5 required artifacts exist and are substantive (not stubs)
- All 10 key links are wired (endpoints call correct functions, scripts call correct APIs)
- All 12 observable truths verified via code inspection
- All syntax checks pass (Node.js scripts compile without errors)
- All commits exist in git history (ad2c1e4, 11eeafd, d62b348, 42b55b7, 8e7bd89)
- Zero anti-patterns found (no TODOs, placeholders, empty implementations)
- Requirement ONBD-01 satisfied (code-level verification complete)

**Remaining:** 4 human verification items to confirm the phase goal is achieved end-to-end on live infrastructure:
1. Full onboarding flow creates working agent
2. Resume flag skips completed steps after interruption
3. Remove-agent cleans up pm2 + hub + filesystem
4. agentcom-submit creates tasks in hub queue

The code is complete and correct. The phase goal "Adding a new agent to the system takes one command and verifies everything works" is implemented. Human verification is needed to confirm it works end-to-end on real machines with live infrastructure.

---
*Verified: 2026-02-11T21:38:18Z*
*Verifier: Claude (gsd-verifier)*
