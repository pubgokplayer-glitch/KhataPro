-- ═══════════════════════════════════════════════════════════════════════════
--  ops/prune.sql — NOT a migration. Housekeeping for the zero-cost promise.
--
--  This is the file that keeps KhataPro alive on a 16 GB phone for ten years:
--  a shop doing 80 vouchers a day writes ~29 000 entries/year, and the oplog,
--  session telemetry and FTS segments grow faster than the ledger itself.
--  Nothing here touches bookkeeping rows.
--
--  Runs nightly inside the backup window (WorkManager / BGTaskScheduler).
--  Everything is bounded by a parameter you can raise if a device ever runs
--  low on space: :oplog_keep_days, :session_keep_days, :conflict_keep_days.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1 · Oplog: drop rows every known peer has already acknowledged ─────────
-- A row may only go when EVERY trusted peer's cursor is past it, otherwise the
-- next sync would silently skip that change (the classic "my edit never
-- arrived" bug). Dispatched-and-older-than-30-days is the second safety net,
-- for peers that were revoked and will never advance their cursor again.
DELETE FROM oplog
 WHERE seq < COALESCE((SELECT MIN(CAST(substr(last_sent_hlc, 1, 15) AS INTEGER))
                         FROM sync_cursors c
                         JOIN sync_peers p ON p.peer_node_id = c.peer_node_id
                        WHERE p.trust_state = 1), 9223372036854775807)
   AND seq < COALESCE((SELECT MIN(seq) FROM oplog WHERE dispatched_at IS NULL), 9223372036854775807);

DELETE FROM oplog
 WHERE dispatched_at IS NOT NULL
   AND created_at < (CAST(unixepoch('subsec') * 1000 AS INTEGER) - 30 * 86400000);

-- ── 2 · Session telemetry (keep 90 days for the sync-health chart) ─────────
DELETE FROM sync_sessions
 WHERE started_at < (CAST(unixepoch('subsec') * 1000 AS INTEGER) - 90 * 86400000);

-- ── 3 · Reviewed merge receipts (keep 30 days after review) ───────────────
DELETE FROM conflict_log
 WHERE reviewed_at IS NOT NULL
   AND reviewed_at < (CAST(unixepoch('subsec') * 1000 AS INTEGER) - 30 * 86400000);

-- ── 4 · Stale scratch pads from crashed sessions ──────────────────────────
DELETE FROM balance_audit
 WHERE session_id <> (SELECT session_id FROM v_session)
   AND touched_at < (CAST(unixepoch('subsec') * 1000 AS INTEGER) - 7 * 86400000);

-- ── 5 · Old snapshots (keep the newest 3 per account per quarter) ─────────
DELETE FROM balance_snapshots
 WHERE as_of_date IN (
   SELECT as_of_date FROM (
     SELECT as_of_date,
            ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY as_of_date DESC) AS rn
       FROM balance_snapshots)
    WHERE rn > 12);

-- ── 6 · Orphaned attachments after a hard delete of their owner ───────────
-- (Soft deletes keep their files; only genuinely orphaned metadata goes.)
DELETE FROM attachments
 WHERE deleted_at IS NOT NULL
   AND deleted_at < (CAST(unixepoch('subsec') * 1000 AS INTEGER) - 90 * 86400000);

-- ── 7 · FTS housekeeping ──────────────────────────────────────────────────
INSERT INTO search_index (search_index) VALUES ('optimize');

-- ── 8 · Planner statistics + WAL checkpoint ───────────────────────────────
-- PRAGMA optimize is what keeps the query planner honest as a book grows from
-- 500 to 60 000 postings; without it, index choices stop matching reality and
-- report screens get slow for no visible reason.
PRAGMA optimize;
PRAGMA wal_checkpoint(TRUNCATE);
