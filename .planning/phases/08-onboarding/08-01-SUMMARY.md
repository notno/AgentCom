---
phase: 08-onboarding
plan: 01
subsystem: api
tags: [elixir, plug, rest-api, onboarding, registration, auth-token]

# Dependency graph
requires:
  - phase: 01-sidecar
    provides: "Auth module (token generate/verify/list/revoke)"
  - phase: 01-sidecar
    provides: "Config GenServer (DETS-backed key-value store)"
provides:
  - "POST /api/onboard/register -- unauthenticated agent registration returning token + hub config"
  - "GET /api/config/default-repo -- unauthenticated default repo URL lookup"
  - "PUT /api/config/default-repo -- authenticated default repo URL setter"
affects: [08-onboarding, sidecar-scripts]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Unauthenticated onboarding endpoint with network trust (local network only)"]

key-files:
  created: []
  modified:
    - "lib/agent_com/endpoint.ex"

key-decisions:
  - "Registration endpoint is unauthenticated -- uses network trust model (same as /api/dashboard/state)"
  - "Duplicate agent_id check via Auth.list() before token generation -- returns 409 on conflict"
  - "Hub URLs constructed dynamically from conn.host/conn.port -- no hardcoded addresses"
  - "GET /api/config/default-repo is unauthenticated -- agents need repo URL before they have a token"
  - "Both tasks committed together -- routes were co-located in same logical section of endpoint.ex"

patterns-established:
  - "Onboarding endpoints: unauthenticated routes prefixed with /api/onboard/"
  - "Config endpoints: GET unauthenticated, PUT authenticated for operational settings"

# Metrics
duration: 1min
completed: 2026-02-11
---

# Phase 8 Plan 01: Onboarding API Summary

**Unauthenticated agent registration endpoint returning token + hub config, plus default-repo config API**

## Performance

- **Duration:** 1 min
- **Started:** 2026-02-11T21:27:31Z
- **Completed:** 2026-02-11T21:28:49Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- POST /api/onboard/register accepts agent_id without auth, generates token via Auth.generate, returns 201 with agent_id + token + hub_ws_url + hub_api_url + default_repo
- GET /api/config/default-repo returns current default repository URL without authentication
- PUT /api/config/default-repo sets the default repository URL with authentication required
- 400 error on missing/invalid agent_id, 409 on duplicate registration

## Task Commits

Each task was committed atomically:

1. **Task 1: Add POST /api/onboard/register endpoint** - `ad2c1e4` (feat)
   - Also includes Task 2 routes (co-located in same endpoint.ex section)

**Plan metadata:** (pending final commit)

## Files Created/Modified
- `lib/agent_com/endpoint.ex` - Added 3 new routes: POST /api/onboard/register, GET /api/config/default-repo, PUT /api/config/default-repo

## Decisions Made
- Registration endpoint is unauthenticated, using network trust model (local network only, same as /api/dashboard/state)
- Duplicate agent_id detection via Auth.list() enumeration before token generation -- returns 409 Conflict
- Hub URLs (ws and http) constructed dynamically from conn.host and conn.port -- no hardcoded addresses
- GET /api/config/default-repo is unauthenticated since onboarding agents need the repo URL before they have a token
- Both tasks committed together since the routes were co-located in the same logical section

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Registration endpoint ready for onboarding scripts (08-02, 08-03)
- Default-repo config endpoint ready for admin setup and agent consumption
- Existing DELETE /admin/tokens/:agent_id already available for remove-agent flow

---
*Phase: 08-onboarding*
*Completed: 2026-02-11*
