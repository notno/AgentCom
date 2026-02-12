# Phase 10: DETS Backup + Monitoring - Context

**Gathered:** 2026-02-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Automated backup, manual trigger, and health monitoring for all DETS tables. Protects data against corruption and provides visibility into storage health. Compaction and recovery procedures are Phase 11.

</domain>

<decisions>
## Implementation Decisions

### Backup strategy
- Store backups on same machine in a separate directory (e.g., priv/backups/)
- Retain the last 3 backups per table, delete older ones automatically
- Timestamped filenames (e.g., tasks_2026-02-11T14-30-00.dets) for clear ordering and browsing
- Individual table backup failures continue with remaining tables (best-effort)

### Schedule + triggers
- Automatic backup runs once daily
- Manual backup via authenticated API endpoint -- returns synchronously with backup details (waits for completion)
- After successful backup: structured log entry + PubSub broadcast so dashboard can show last backup time live

### Health reporting
- Metrics: table sizes (record count, file size), fragmentation ratio, time since last backup
- Visible via both JSON API endpoint and a DETS health card on the command center dashboard
- Unhealthy thresholds: warn on stale backup (>48h for daily schedule) OR high fragmentation (>50% wasted space)
- Integrate into existing DashboardState.compute_health -- overall system health includes DETS storage health

### Claude's Discretion
- Backup copy method (full file copy vs DETS traverse + dump) -- pick based on DETS internals
- Which tables to back up (audit all DETS tables, decide which are critical vs orphaned)
- Write consistency approach during backup (sync-then-copy vs as-is copy)
- Table discovery method (hardcoded list vs dynamic directory scan)
- API endpoint path (consistent with existing admin endpoint patterns)

</decisions>

<specifics>
## Specific Ideas

No specific requirements -- open to standard approaches. Follow existing codebase patterns for GenServer design, PubSub events, and endpoint routing.

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope.

</deferred>

---

*Phase: 10-dets-backup*
*Context gathered: 2026-02-11*
