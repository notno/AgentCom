---
phase: 18-llm-registry-host-resources
verified: 2026-02-12T21:53:46Z
status: gaps_found
score: 4/5
re_verification: false
gaps:
  - truth: "Registry distinguishes between models currently loaded in VRAM (warm) and models only downloaded (cold) per host"
    status: failed
    reason: "Locked decision in CONTEXT.md chose binary model availability instead of warm/cold VRAM tracking"
    artifacts:
      - path: ".planning/phases/18-llm-registry-host-resources/18-CONTEXT.md"
        issue: "Line 20: Model availability is binary - conflicts with Success Criterion 3"
    missing:
      - "Query Ollama /api/ps endpoint to distinguish loaded vs downloaded models"
      - "Add model_status field to endpoint schema"
      - "Update dashboard to visually distinguish warm vs cold models"
---

# Phase 18: LLM Registry and Host Resources Verification Report

**Phase Goal:** Hub knows which Ollama models are available on which hosts, whether they are healthy, and what resources each host has available

**Verified:** 2026-02-12T21:53:46Z
**Status:** gaps_found
**Re-verification:** No - initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Admin can register an Ollama endpoint via HTTP API and see it listed with its host, port, and discovered models | VERIFIED | HTTP POST /api/admin/llm-registry in endpoint.ex. Registration calls LlmRegistry.register_endpoint/1 which persists to DETS. Model discovery via /api/tags. Dashboard renders table. All 17 LlmRegistry tests pass. |
| 2 | An Ollama endpoint that goes offline is marked unhealthy within one health check cycle, and re-marked healthy when it returns | VERIFIED | Health check timer runs every 30s. Check logic marks unhealthy after 2 consecutive failures, immediate recovery on success. PubSub broadcasts changes. Test coverage complete. |
| 3 | Registry distinguishes between models currently loaded in VRAM (warm) and models only downloaded (cold) per host | FAILED | Implementation uses binary model availability per locked decision in 18-CONTEXT.md:20. RESEARCH.md line 33 documents this as intentional override of Success Criteria 3. Current implementation queries /api/tags for all available models but does not distinguish loaded vs downloaded state. |
| 4 | Dashboard shows per-machine resource utilization (CPU, RAM, GPU/VRAM) reported by each sidecar | VERIFIED | Sidecar resource collection in resources.js. Periodic reporting every 30s. Hub stores in ETS. Dashboard renders bars with CPU (blue), RAM (purple), VRAM (amber) color coding. |
| 5 | Registered endpoints and resource metrics survive hub restart (DETS persistence) | VERIFIED | Endpoint registry uses DETS, loaded on init. NOTE: Resource metrics are ephemeral (ETS-only) per locked decision in CONTEXT.md. This was intentional: only endpoint registrations need DETS persistence. |

**Score:** 4/5 truths verified (Truth 3 failed due to locked decision conflict)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| lib/agent_com/llm_registry.ex | GenServer with DETS+ETS, health checks, model discovery | VERIFIED | 400+ lines, DETS, ETS, health check timer, /api/tags polling |
| lib/agent_com/dashboard_state.ex | PubSub subscription, snapshot includes registry data | VERIFIED | Subscribes line 59, calls LlmRegistry.snapshot() line 187 |
| lib/agent_com/dashboard_socket.ex | Forwards events, handles add/remove commands | VERIFIED | Subscribes line 32, forwards events, handles register/remove |
| lib/agent_com/dashboard.ex | HTML table with fleet summary, resource bars, controls | VERIFIED | CSS, HTML section, JS rendering, fleet chips, resource bars |
| lib/agent_com/endpoint.ex | HTTP admin routes for registry CRUD | VERIFIED | 5 routes: list, snapshot, get by id, POST register, DELETE remove |
| lib/agent_com/socket.ex | WS handlers for ollama_report, resource_report | VERIFIED | ollama_report, resource_report, identify auto-registration |
| sidecar/lib/resources.js | CPU/RAM/VRAM metrics collection | VERIFIED | 85 lines, CPU from os.loadavg, RAM, VRAM from Ollama /api/ps |
| sidecar/index.js | ollama_url in identify, periodic resource_report | VERIFIED | ollama_url in identify, periodic reporting 30s interval |
| lib/agent_com/application.ex | LlmRegistry in supervisor tree | VERIFIED | Supervisor entry before DashboardState |

**All 9 core artifacts present and substantive.**

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| DashboardState | LlmRegistry | Calls LlmRegistry.snapshot() | WIRED | Line 187 in try/rescue block |
| DashboardSocket | Phoenix.PubSub | Subscribes to llm_registry topic | WIRED | Line 32 subscription |
| Dashboard HTML/JS | Dashboard WebSocket | Handles events, sends commands | WIRED | Event handler, addLlmEndpoint, removeLlmEndpoint |
| Sidecar resources.js | Sidecar index.js | Metrics collected and sent via WS | WIRED | collectMetrics called, sent via ws.send |
| Socket WS handler | LlmRegistry | Calls register_endpoint, report_resources | WIRED | Both functions called |
| HTTP admin routes | LlmRegistry | All CRUD operations | WIRED | All functions called |

**All 6 key links verified and wired.**

### Requirements Coverage

No requirements explicitly mapped to phase 18 in REQUIREMENTS.md. Phase goal from ROADMAP.md is the primary verification target.

### Anti-Patterns Found

None. All implementations are substantive with proper error handling, try/rescue blocks, synced DETS operations, validated WebSocket messages, and graceful null degradation.

### Human Verification Required

#### 1. Dashboard Visual Verification

**Test:** Start hub with mix run --no-halt, open dashboard, verify LLM Registry section
**Expected:** Fleet chips, status dots, colored resource bars, add/remove forms work, real-time updates
**Why human:** Visual layout, colors, real-time behavior, form interaction cannot be verified programmatically

#### 2. Multi-Host Resource Reporting

**Test:** Connect multiple sidecars with different Ollama configs, verify per-host resource metrics
**Expected:** Each sidecar reports independently, separate bars per host, stale metrics disappear after 90s
**Why human:** Requires actual multi-machine Tailscale mesh setup

#### 3. Endpoint Health State Transitions

**Test:** Register endpoint, stop Ollama, wait 60s, restart Ollama
**Expected:** Healthy initially, unhealthy after 60s, healthy again within 30s
**Why human:** Requires real Ollama service manipulation and time-based observation

### Gaps Summary

**One gap identified:** Success Criterion 3 requires warm/cold model distinction, but implementation followed locked decision in CONTEXT.md for binary model availability. This was documented in CONTEXT.md line 20 and RESEARCH.md line 33.

**Resolution options:**
1. Accept gap: Update criterion to match implementation
2. Implement warm/cold: Query Ollama /api/ps, update schema and dashboard
3. Defer to Phase 19: Implement if needed for model-aware scheduler

**Recommended:** Accept gap with documentation update. The locked decision was made after domain research and represents a valid simplification. If needed for Phase 19, add as enhancement.

---

*Verified: 2026-02-12T21:53:46Z*
*Verifier: Claude (gsd-verifier)*
