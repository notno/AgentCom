# Codebase Concerns

**Analysis Date:** 2026-02-09

## Tech Debt

**Message Queue Not Implemented:**
- Issue: `lib/agent_com/router.ex` line 7 contains TODO comment: "Undeliverable messages are stored for later (TODO: message queue)"
- Files: `lib/agent_com/router.ex`
- Impact: Router has no formal message queue system for permanently failed deliveries. Messages that cannot be delivered to offline agents or broadcast subscribers are dropped without retry or persistence.
- Fix approach: Implement persistent message queue (DETS-backed or separate store) for messages that fail initial delivery. Add retry mechanism with exponential backoff.

**Test Coverage Completely Missing:**
- Issue: No test files found in codebase (`*.test.exs`, `*.spec.exs`, `_test.exs`, `_spec.exs`)
- Files: All `lib/agent_com/*.ex` files
- Impact: No automated testing means regressions go undetected. Core systems like routing, auth, mailbox, and channels have zero coverage.
- Fix approach: Set up ExUnit test framework. Start with critical path tests for Router, Auth, and Socket. Add continuous integration.

**Token Storage in Plain Text:**
- Issue: Authentication tokens stored in plain JSON file with no encryption
- Files: `lib/agent_com/auth.ex` (line 95-96), `priv/tokens.json`
- Impact: If `priv/tokens.json` is exposed, all agent tokens are compromised. File-based storage is vulnerable to filesystem access bypasses.
- Fix approach: Encrypt token store at rest using :crypto. Consider moving to a more secure storage backend (encrypted config store, external secrets manager). Add filesystem permission checks.

**Hardcoded Admin Agent List:**
- Issue: Admin agents defined via environment variable read at compile time, not runtime
- Files: `lib/agent_com/endpoint.ex` (line 420), reads `ADMIN_AGENTS` as module attribute
- Impact: Changing admin agents requires restart. Cannot revoke admin access without code change.
- Fix approach: Store admin agent list in Config module (already DETS-backed). Provide HTTP endpoint to manage admins at runtime.

**No Input Validation/Sanitization:**
- Issue: WebSocket messages and HTTP params accepted with minimal validation
- Files: `lib/agent_com/socket.ex` (lines 163-179), `lib/agent_com/endpoint.ex` (lines 66-89)
- Impact: Malformed payloads could cause runtime errors. No size limits on agent_id, payload, or lists could enable denial-of-service.
- Fix approach: Add schema validation (e.g., `valisdate` lib) for all incoming messages. Set hard limits on string lengths and array sizes.

**DETS Database Fragmentation:**
- Issue: Multiple DETS tables (.dets files) with no compaction or maintenance routine
- Files: `lib/agent_com/mailbox.ex`, `lib/agent_com/message_history.ex`, `lib/agent_com/channels.ex`, `lib/agent_com/config.ex`, `lib/agent_com/threads.ex`
- Impact: DETS files grow monotonically with deletions leaving gaps. Long-running hubs will experience disk waste and slower queries.
- Fix approach: Implement periodic DETS compaction. Provide admin endpoint to manually trigger compaction.

---

## Known Bugs

**Registry Lookup Inconsistency in Reaper:**
- Symptoms: Stale connection reaper may fail to evict agents if atom/string mismatch in presence data
- Files: `lib/agent_com/reaper.ex` (line 43)
- Trigger: Agent ID stored as atom in one place, string in another; reaper matches on atom key
- Workaround: Ensure agent_id is always string throughout codebase

**Channel History Pagination Bug:**
- Symptoms: `Enum.take(-limit)` on line 198 of `lib/agent_com/channels.ex` always returns last N items regardless of `since`
- Files: `lib/agent_com/channels.ex` (line 198)
- Trigger: Call `history(channel, limit: 10, since: 5)` — always gets last 10, not 10 after seq 5
- Workaround: Use limit without since, or manually filter results client-side

---

## Security Considerations

**No Rate Limiting:**
- Risk: Attacker with valid token can spam messages, create channels, or exhaust server resources
- Files: `lib/agent_com/endpoint.ex`, `lib/agent_com/socket.ex`
- Current mitigation: None
- Recommendations: Implement per-agent rate limiting on message sends (e.g., 100 msgs/min). Add bucket-based cost limits for expensive operations (channel creation, mailbox polling).

**Token Exposed in Logs:**
- Risk: Tokens visible in HTTP request logs or debug output if token leaked in headers
- Files: `lib/agent_com/endpoint.ex` (Plug.Logger on line 28)
- Current mitigation: Logger configured but no redaction of Authorization headers
- Recommendations: Add custom logging plug that redacts Bearer tokens from logs.

**WebSocket Accepts Untrusted JSON:**
- Risk: Malformed JSON can crash Socket handler if decoder fails on edge cases
- Files: `lib/agent_com/socket.ex` (line 62)
- Current mitigation: Jason.decode error handled, but payload structure not validated
- Recommendations: Validate incoming message structure against explicit schema. Reject oversized payloads (e.g., >1MB).

**Admin Reset Endpoint Spawn Race:**
- Risk: Supervisor restart spawned in background (line 436 of endpoint.ex) — timing-dependent, could restart twice if endpoint called again
- Files: `lib/agent_com/endpoint.ex` (lines 436-445)
- Current mitigation: 500ms delay before restart
- Recommendations: Use GenServer callback or message queue instead of spawn. Prevent duplicate resets within cooldown period.

---

## Performance Bottlenecks

**Full Table Scans in Mailbox Polling:**
- Problem: `poll/2` scans all mailbox entries with DETS select, no index on agent_id
- Files: `lib/agent_com/mailbox.ex` (lines 97-103)
- Cause: DETS select with sequential scan across `{agent_id, seq}` tuples
- Improvement path: Verify DETS is indexed on agent_id (currently is — composite key works). For large mailboxes (>10k msgs per agent), consider ETS cache layer or time-series DB.

**Analytics Hourly Recalculation:**
- Problem: `hourly/1` and `stats/1` recalculate buckets on every call (no caching)
- Files: `lib/agent_com/analytics.ex` (lines 114-126, 65-112)
- Cause: Loops through 24 buckets and queries ETS for each; no memoization
- Improvement path: Cache aggregated hourly stats in separate ETS table. Invalidate hourly on each bucket boundary.

**Message History Query with Post-Filter:**
- Problem: Pulls all messages after cursor from DETS, then filters in-memory by agent/channel/time
- Files: `lib/agent_com/message_history.ex` (lines 87-102)
- Cause: DETS select can only filter by seq; time/agent/channel filters are Elixir-side
- Improvement path: Consider secondary indexes or time-partitioned DETS tables for faster range queries.

**Presence Broadcast on Every Status Update:**
- Problem: Status update triggers PubSub broadcast to all agents (line 95 in presence.ex)
- Files: `lib/agent_com/presence.ex` (line 95)
- Cause: All agents receive status_changed event even if they don't care
- Improvement path: Add agent subscription to status updates they care about, or batch status broadcasts.

---

## Fragile Areas

**Socket State Machine:**
- Files: `lib/agent_com/socket.ex`
- Why fragile: Identify must happen first (line 159 check), but no explicit state machine. If identify fails and agent retries, socket processes second identify without cleanup of first. Multiple identify calls could cause duplicate Registry entries.
- Safe modification: Add explicit state guard (identified flag prevents re-identify). Add tests for identify replay.
- Test coverage: No tests for WebSocket protocol edge cases (duplicate identify, malformed json, missing payloads).

**DETS Recovery on Startup:**
- Files: `lib/agent_com/mailbox.ex` (line 33), `lib/agent_com/message_history.ex` (line 26)
- Why fragile: Both modules recover sequence counter via full table scan on init. If DETS file is corrupted, init fails silently with GenServer timeout.
- Safe modification: Add error handling in recover_seq. Log failures and continue with seq=0.
- Test coverage: No tests for DETS corruption recovery.

**Reaper TTL Configuration:**
- Files: `lib/agent_com/reaper.ex`, `lib/agent_com/socket.ex`
- Why fragile: Reaper uses hardcoded 60s TTL (line 16); Socket updates last_seen via ping. If agent sends ping within 60s but router crashes, agent is still marked online.
- Safe modification: Make TTL configurable via Config module. Document assumption that ping proves online.
- Test coverage: No tests for reaper behavior or TTL edge cases.

**Router Broadcast Queue Race:**
- Files: `lib/agent_com/router.ex` (lines 40-52)
- Why fragile: `queue_for_offline/1` runs inside Router.send_message, queries Auth.list() to find all agents, then checks Registry. But between list() and Registry.lookup, agent could connect/disconnect, causing inconsistent mailbox state.
- Safe modification: Snapshot online agents at message time, use that snapshot for both PubSub and mailbox decisions.
- Test coverage: No tests for race conditions between online/offline agent states.

---

## Scaling Limits

**DETS File Size Growth:**
- Current capacity: Mailbox limited to 100 msgs per agent (line 13 in mailbox.ex); history limited to 10k global (line 13 in message_history.ex); channel history 200 per channel
- Limit: Long-running hub with 100 agents sending 10 msgs/hour = 24,000 msgs stored daily. 10k history = 10 hours of data. After refresh, data is lost.
- Scaling path: Implement data archival to external storage (S3/blob). Add retention policy config. Consider streaming DETS to time-series DB.

**ETS Analytics Table No Limits:**
- Current capacity: One entry per agent per metric bucket. With 1000 agents × 24 hours of buckets × 5 metrics = 120k entries
- Limit: ETS is in-memory. At scale, analytics table grows unbounded (metrics reset on restart, but no explicit cleanup)
- Scaling path: Implement periodic aggregation and rolloff. Archive old data to cold storage. Add metrics table size monitoring.

**Registry Linear Scans:**
- Current capacity: Registry scales fine to 1000 agents on a single BEAM node
- Limit: Reaper sweeps all agents every 30s (line 31 in reaper.ex). At 10k agents, sweep becomes expensive
- Scaling path: Implement partitioned presence tracking. Move to external registry if >1k agents planned.

**WebSocket Connection Limit:**
- Current capacity: BEAM default 65k file descriptors per system
- Limit: Single-node deployment limited to ~1000-5000 concurrent WebSocket connections (depends on message throughput)
- Scaling path: Implement multi-hub federation (cross-hub routing). Add load balancer in front. Consider worker pools.

---

## Dependencies at Risk

**No Testing Framework Dependency:**
- Risk: Project claims development supports `mix test` (line 207 in README) but no test framework in mix.exs. Command will fail.
- Impact: Blocks automated testing. Developers cannot run tests.
- Migration plan: Add ExUnit (builtin). Add mock library (e.g., Mox). Set up test configuration.

**No Security Dependencies:**
- Risk: No password hashing (tokens are bare hex), no input validation libs, no rate limiting middleware
- Impact: Authentication relies on tokens with no cryptographic hardening. Tokens are equally valuable if attacker gets them.
- Migration plan: Add Argon2 for future password auth. Add Valisdate for schema validation. Add Hammer for rate limiting.

**DETS as Primary Database:**
- Risk: DETS is single-machine, no replication, no backup tooling in codebase
- Impact: Data loss on disk corruption. No disaster recovery plan documented.
- Migration plan: Document DETS backup procedure. Consider Mnesia (clustered DETS) for multi-hub setup.

---

## Missing Critical Features

**No Data Persistence Verification:**
- Problem: Hub resets lose all message history, mailbox, and channel subscriptions
- Blocks: Agents cannot reliably retrieve missed messages after reconnection (mailbox evicts after 7 days, history evicts after 10k messages)
- Fix: Implement WAL (write-ahead log) for critical messages. Add dump/restore endpoints for backup.

**No Message Encryption:**
- Problem: All messages stored in plain text in DETS files
- Blocks: Sensitive data (credentials, keys, personal info) transmitted via hub with no encryption-at-rest
- Fix: Add optional per-message encryption. Store keys separately.

**No Admin Dashboard:**
- Problem: No UI for managing agents, tokens, channels, or hub configuration
- Blocks: Hub admins must use curl/CLI for all operations. No visibility into hub health without parsing logs.
- Fix: Build dashboard (partially started in dashboard.ex) with agent list, token mgmt, channel mgmt, analytics view.

---

## Test Coverage Gaps

**Router Message Routing:**
- What's not tested: Direct messages to offline agents, broadcast routing, undeliverable message handling, race conditions between online/offline
- Files: `lib/agent_com/router.ex`
- Risk: Routing logic could fail silently (messages lost, wrong recipient, inbox corruption)
- Priority: High

**Auth Token Generation and Verification:**
- What's not tested: Token format validation, token revocation, token reuse after revocation, multiple tokens per agent
- Files: `lib/agent_com/auth.ex`
- Risk: Authentication bypass, token leaks not detected
- Priority: High

**Socket WebSocket Protocol:**
- What's not tested: All message types (identify, message, status, channel ops), error cases, session handling, reconnection
- Files: `lib/agent_com/socket.ex`
- Risk: Protocol violations cause crashes or state inconsistency
- Priority: High

**Mailbox Poll and Acknowledge:**
- What's not tested: Pagination with since/cursor, acknowledge edge cases, expired message eviction, race conditions
- Files: `lib/agent_com/mailbox.ex`
- Risk: Lost messages, duplicate delivery, inability to retrieve queued messages
- Priority: High

**Channels Subscribe/Publish:**
- What's not tested: Subscribe/unsubscribe state, publish to non-existent channel, subscriber notification, history pagination
- Files: `lib/agent_com/channels.ex`
- Risk: Subscription state corruption, lost channel messages
- Priority: Medium

**Reaper Stale Connection Eviction:**
- What's not tested: TTL expiration logic, Registry cleanup, Presence consistency after eviction
- Files: `lib/agent_com/reaper.ex`
- Risk: Stale agents not evicted, resources leak, ghost agents in presence
- Priority: Medium

---

*Concerns audit: 2026-02-09*
