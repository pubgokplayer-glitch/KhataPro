-- ═══════════════════════════════════════════════════════════════════════════
--  ops/integrity_checks.sql — NOT a migration. Run on demand / before commit.
--
--  Callers
--  ───────
--   · Dart:  `await db.customStatement(gateSql)` inside the same transaction as
--            the write batch (see OrderBook.commitChecked() in
--            lib/data/repositories/order_book.dart). On failure the statement
--            throws and the DAO rolls the transaction back.
--   · Sync:  the transport runs the same statement as the last step of every
--            apply batch, so a peer cannot inject a broken ledger.
--   · CLI:   sqlite3 app.sqlite < ops/integrity_checks.sql   (read + gate)
--   · Nightly: WorkManager job; also runs REBUILD + PRUNE afterwards.
--
--  Reading it as a pure diagnostic (no writes):
--      SELECT * FROM v_integrity_report ORDER BY severity DESC, kind;
-- ═══════════════════════════════════════════════════════════════════════════

-- ── [GATE-1] Absolute invariants ───────────────────────────────────────────
-- Any row produced here trips the AFTER INSERT trigger on invariant_violations
-- (005_triggers.sql, trg_gate_abort) and aborts the statement with a message.
-- That is intentional: RAISE(FAIL) kills the statement but leaves the
-- transaction open, so the caller decides between rollback and repair.
INSERT INTO invariant_violations (kind, detail, detected_at)
SELECT kind, detail, CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM v_integrity_report
 WHERE severity = 1;

-- ── [GATE-2] Transaction-scoped cache audit (O(1) per touched account) ─────
-- Proves that everything this transaction added to account_balances equals
-- before + delta as recorded by the trigger chain. A drift here means a code
-- path (or a trigger) mutated the cache without going through the audited
-- route — a bug we want to know about *now*, not next month.
-- Skipped in maintenance mode, where caches are rebuilt wholesale on purpose.
INSERT INTO invariant_violations (kind, detail, detected_at)
SELECT 'BALANCE_DELTA_MISMATCH',
       'account ' || ba.account_id || ': cache shows Dr ' || CAST(COALESCE(ab.debit_minor, 0) AS TEXT)
       || '/Cr ' || CAST(COALESCE(ab.credit_minor, 0) AS TEXT)
       || ' but this transaction expected Dr ' || CAST(ba.before_debit + ba.delta_debit AS TEXT)
       || '/Cr ' || CAST(ba.before_credit + ba.delta_credit AS TEXT),
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM balance_audit ba
  LEFT JOIN account_balances ab
         ON ab.account_id = ba.account_id AND ab.period_id = 0 AND ab.period_start = 0
 WHERE ba.session_id = (SELECT session_id FROM v_session)
   AND (SELECT write_mode FROM v_session) IN ('user', 'sync')
   AND (COALESCE(ab.debit_minor, 0)  <> ba.before_debit  + ba.delta_debit
     OR COALESCE(ab.credit_minor, 0) <> ba.before_credit + ba.delta_credit);

-- ── [GATE-3] Clear this session's audit trail (only after GATE-2 passed) ───
-- balance_audit is a per-transaction scratch pad; leaving rows behind would
-- corrupt the next transaction's expectations. Stale rows from a crashed
-- session are removed by ops/prune.sql.
DELETE FROM balance_audit
 WHERE session_id = (SELECT session_id FROM v_session);

-- ── [REPORT] What the "Verify my books" screen shows ───────────────────────
-- SELECT severity, kind, detail FROM v_integrity_report ORDER BY severity DESC, kind;

-- ── [REPAIR] In the rare case a critical finding does occur ────────────────
-- 1. ALWAYS take a backup first (Settings → Backup now), and keep the file:
--      the point of a repair is to be reversible.
-- 2. ACCOUNT_BALANCE_DRIFT / BALANCE_DELTA_MISMATCH  → ops/rebuild_caches.sql
-- 3. ENTRY_TOTALS_DRIFT / DOCUMENT_TOTAL_DRIFT       → ops/rebuild_caches.sql
--      (both caches are pure functions of rows that are still intact)
-- 4. UNBALANCED_ENTRY / ENTRY_MISSING_SIDE           → this one is real data,
--      and it can only arrive from outside (a hand-edited file or a peer with a
--      broken build). Find it with:
--        SELECT * FROM v_journal_detail WHERE entry_id = '<id>' ORDER BY line_no;
--      then either post a correcting entry, or void the entry and re-enter it.
--      Never "fix" it with a raw UPDATE.
-- 5. AUDIT_CHAIN_BREAK → the audit trail was edited out of band. Treat the
--      affected ledger as untrusted, restore from the last verified backup, and
--      rotate peer keys (Settings → Devices → Revoke).
-- 6. SEARCH_INDEX_STALE / STOCK_CACHE_DRIFT → ops/rebuild_search.sql /
--      ops/rebuild_caches.sql. Both are derived data; no bookkeeping is at risk.
