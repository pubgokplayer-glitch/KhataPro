-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 009_conflict_receipts.sql
--
--  Makes merge receipts IDEMPOTENT.
--
--  `conflict_log` records what the LWW resolver overwrote, so the user can
--  review and reverse a merge. The resolver runs on every apply, and the sync
--  protocol deliberately re-sends freely (duplicate delivery is expected, not
--  an error — see 003_crdt_sync.sql). Without a dedupe key, replaying a batch
--  would append a duplicate receipt for every losing field on every pass, and
--  the "review my merges" screen would fill with noise the user cannot act on.
--
--  The natural key of a receipt is:
--      (row, field, losing version's stamp)
--  which is what `row_id`, `field_name` and `local_hlc` hold (`local_*` is the
--  value that was overwritten; `remote_*` records which version superseded it
--  at the time of the merge).
--
--  The winner is deliberately NOT part of the key: a stale row re-sent on a
--  later pass is compared against whatever the local state is *then*, so the
--  winner differs between passes while the loss is identical. Keying on the
--  loser's stamp gives exact-once receipts across passes, which is what keeps
--  the review queue bounded for two devices that have disagreed for weeks.
--  A unique index on that key lets the applier use `INSERT OR IGNORE`.
--
--  Note this is a UNIQUE INDEX, not a UNIQUE table constraint, so it does not
--  need to be added to `allTables` in database.dart on upgrade paths that
--  predate it.
-- ═══════════════════════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

-- Both HLC columns are always populated by FieldConflict.toConflictLogRow and
-- are 57-char stamps, so a plain (non-partial) unique index is correct. A
-- tombstone flip is recorded under field_name = 'deleted_at'.
CREATE UNIQUE INDEX IF NOT EXISTS ux_conflict_receipt
  ON conflict_log (row_id, field_name, local_hlc);

-- The review screen lists unreviewed receipts newest-first and groups them by
-- row; this covering-ish index answers both without a table scan.
CREATE INDEX IF NOT EXISTS ix_conflict_review_queue
  ON conflict_log (table_name, row_id, detected_at DESC)
  WHERE reviewed_at IS NULL;

INSERT OR REPLACE INTO schema_meta (key, value, updated_at) VALUES
  ('conflict_receipts_version', '1', CAST(unixepoch('subsec') * 1000 AS INTEGER));
