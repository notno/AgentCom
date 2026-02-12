# Phase 11: DETS Compaction + Recovery - Context

**Gathered:** 2026-02-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Scheduled compaction/defragmentation for all DETS tables and a documented, tested recovery procedure that restores tables from backup after corruption. Backup creation is Phase 10 (already exists). Monitoring endpoints are Phase 10. This phase adds compaction scheduling, recovery automation, and extends existing dashboard/API surfaces.

</domain>

<decisions>
## Implementation Decisions

### Recovery workflow
- Auto-restore on corruption detection — detect corruption, restore from latest backup automatically, notify operator after the fact
- Always use the latest backup — no backup version selection needed
- Verify restored data integrity before resuming normal operations (record count, open/close test)
- Expose manual restore endpoint — operators can force-restore a table from backup at any time (e.g., to roll back bad data)

### Compaction scheduling
- Schedule approach: Claude's discretion (fixed interval vs cron-style)
- Per-table vs global schedule: Claude's discretion (based on actual table usage patterns)
- Manual compaction trigger via API — operators can compact a specific table or all tables on-demand
- Threshold-based skip: Claude's discretion (based on DETS compaction cost characteristics)

### Failure handling
- Compaction failure protection: Claude's discretion (safest approach based on DETS internals — likely copy-and-swap)
- Restore failure behavior: Claude's discretion (based on how critical each DETS table is to system operation)
- No pre-compaction backup — rely on Phase 10's scheduled backups as the safety net
- Retry once on compaction failure, then wait for next scheduled run

### Operator visibility
- Dashboard + push notifications for compaction/recovery events
- Push notifications for failures and auto-restores only — successful compaction is silent
- Dashboard shows compaction history log: recent events with time, table, result, duration
- Extend existing Phase 10 DETS health card with compaction/recovery info (single place for all DETS status)

### Claude's Discretion
- Compaction schedule type (interval vs cron) and frequency
- Per-table vs global scheduling
- Whether to skip compaction below a fragmentation threshold
- Compaction failure protection strategy (copy-and-swap vs alternative)
- Behavior when both table and backup are corrupted (graceful shutdown vs degraded mode)

</decisions>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 11-dets-compaction*
*Context gathered: 2026-02-11*
