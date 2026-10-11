-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 008_integrity.sql
--  ONE definition of "is this book sound?", used three ways:
--
--    1. the "Verify my books" screen in Settings (read the view, show a list)
--    2. the abort gate before any commit / sync-apply batch
--       (INSERT INTO invariant_violations SELECT … FROM v_integrity_report)
--    3. nightly background verification + tests
--
--  severity 1 = critical: the books can be WRONG (gate aborts the transaction)
--  severity 2 = warning:  the books are right but something looks off
--                         (negative stock, a 40-day-old draft, an unallocated
--                          payment) — surfaced, never fatal.
--
--  Cost: every branch is an index range scan. On a 60 000-posting book this
--  view returns in single-digit milliseconds on a mid-range phone, which is
--  why it can afford to run before every sync batch.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE VIEW IF NOT EXISTS v_integrity_report AS

-- ── [1] Double entry: Σ debits − Σ credits must be exactly 0 ───────────────
SELECT 1 AS severity, 'UNBALANCED_ENTRY' AS kind,
       e.ledger_id || '/' || e.entry_no || ' (' || e.id || '): sum of lines = '
       || CAST(COALESCE(SUM(l.amount_minor), 0) AS TEXT) || ' minor units, must be 0' AS detail,
       e.id AS entity_id
  FROM journal_entries e
  LEFT JOIN journal_lines l ON l.entry_id = e.id
 WHERE e.status = 1
 GROUP BY e.id
HAVING COALESCE(SUM(l.amount_minor), 0) <> 0

UNION ALL
-- ── [2] A posted entry needs at least two lines ────────────────────────────
SELECT 1, 'ENTRY_TOO_FEW_LINES',
       'entry ' || e.entry_no || ' (' || e.id || ') has ' || CAST(COUNT(l.id) AS TEXT)
       || ' line(s); a double entry needs at least 2', e.id
  FROM journal_entries e
  LEFT JOIN journal_lines l ON l.entry_id = e.id
 WHERE e.status = 1
 GROUP BY e.id
HAVING COUNT(l.id) < 2

UNION ALL
-- ── [3] …and at least one line on each side ────────────────────────────────
SELECT 1, 'ENTRY_MISSING_SIDE',
       'entry ' || e.entry_no || ' has no ' ||
       CASE WHEN NOT EXISTS (SELECT 1 FROM journal_lines WHERE entry_id = e.id AND amount_minor > 0)
            THEN 'debit (Dr) line' ELSE 'credit (Cr) line' END, e.id
  FROM journal_entries e
 WHERE e.status = 1
   AND (NOT EXISTS (SELECT 1 FROM journal_lines WHERE entry_id = e.id AND amount_minor > 0)
     OR NOT EXISTS (SELECT 1 FROM journal_lines WHERE entry_id = e.id AND amount_minor < 0))

UNION ALL
-- ── [4] The entry's own Dr/Cr totals cache ─────────────────────────────────
SELECT 1, 'ENTRY_TOTALS_DRIFT',
       'entry ' || e.entry_no || ': cached Dr/Cr totals disagree with the lines', e.id
  FROM journal_entries e
  LEFT JOIN journal_lines l ON l.entry_id = e.id
 WHERE e.status = 1
 GROUP BY e.id
HAVING e.total_debit_minor  <> COALESCE(SUM(l.debit_minor), 0)
    OR e.total_credit_minor <> COALESCE(SUM(l.credit_minor), 0)
    OR e.base_total_minor   <> COALESCE(SUM(ABS(l.base_amount_minor)), 0)

UNION ALL
-- ── [5] THE BIG ONE: the account balance cache vs. the actual postings ─────
SELECT 1, 'ACCOUNT_BALANCE_DRIFT',
       'account ' || a.code || ' ' || a.name || ': cached Dr ' || CAST(ab.debit_minor AS TEXT)
       || ' / Cr ' || CAST(ab.credit_minor AS TEXT) || ' ≠ derived Dr '
       || CAST(COALESCE(d.dr, 0) AS TEXT) || ' / Cr ' || CAST(COALESCE(d.cr, 0) AS TEXT)
       || '  → fix with assets/sql/ops/rebuild_caches.sql', a.id
  FROM accounts a
  LEFT JOIN account_balances ab
         ON ab.account_id = a.id AND ab.period_id = 0 AND ab.period_start = 0
  LEFT JOIN (
        SELECT l.account_id, SUM(l.debit_minor) AS dr, SUM(l.credit_minor) AS cr
          FROM journal_lines l
          JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
         GROUP BY l.account_id
       ) d ON d.account_id = a.id
 WHERE COALESCE(ab.debit_minor, 0)  <> COALESCE(d.dr, 0)
    OR COALESCE(ab.credit_minor, 0) <> COALESCE(d.cr, 0)

UNION ALL
-- ── [6] A line must agree with its entry (ledger, date, currency) ──────────
SELECT 1, 'LINE_ENTRY_MISMATCH',
       'line ' || l.id || ' on entry ' || e.entry_no
       || ' disagrees on ledger/date/currency', l.id
  FROM journal_lines l
  JOIN journal_entries e ON e.id = l.entry_id
 WHERE l.ledger_id <> e.ledger_id
    OR l.entry_date <> e.entry_date
    OR l.currency_code <> e.currency_code

UNION ALL
-- ── [7] No posting may touch a header, a deleted or a foreign account ─────
SELECT 1, 'INVALID_POSTING_TARGET',
       'line ' || l.id || ' posts to a non-postable, deleted or missing account '
       || l.account_id, l.id
  FROM journal_lines l
  LEFT JOIN accounts a ON a.id = l.account_id
 WHERE a.id IS NULL OR a.is_postable = 0 OR a.deleted_at IS NOT NULL
    OR a.ledger_id <> l.ledger_id

UNION ALL
-- ── [8] Documents: header total == Σ lines ────────────────────────────────
SELECT 1, 'DOCUMENT_TOTAL_DRIFT',
       'document ' || d.doc_no || ': header total ' || CAST(d.total_minor AS TEXT)
       || ' ≠ Σ lines ' || CAST(COALESCE(x.sum_lines, 0) AS TEXT), d.id
  FROM documents d
  LEFT JOIN (
        SELECT document_id,
               SUM(quantity_milli * unit_price_minor / 1000) - SUM(discount_minor) + SUM(tax_minor) AS sum_lines
          FROM document_lines WHERE deleted_at IS NULL GROUP BY document_id
       ) x ON x.document_id = d.id
 WHERE d.deleted_at IS NULL
   AND d.status <> 3
   AND d.total_minor <> (COALESCE(x.sum_lines, 0) + d.shipping_minor + d.other_charges_minor + d.round_off_minor)

UNION ALL
-- ── [9] Documents: balance == total − allocations, and never over-paid ────
SELECT 1, 'DOCUMENT_BALANCE_DRIFT',
       'document ' || d.doc_no || ': balance ' || CAST(d.balance_minor AS TEXT)
       || ' ≠ total ' || CAST(d.total_minor AS TEXT) || ' − allocations '
       || CAST(COALESCE(a.alloc, 0) AS TEXT), d.id
  FROM documents d
  LEFT JOIN (SELECT document_id, SUM(amount_minor) AS alloc FROM payment_allocations GROUP BY document_id) a
         ON a.document_id = d.id
 WHERE d.deleted_at IS NULL
   AND d.total_minor - COALESCE(a.alloc, 0) <> d.balance_minor

UNION ALL
-- ── [10] An invoice may never be settled beyond its value ─────────────────
SELECT 1, 'DOCUMENT_OVERALLOCATED',
       'document ' || d.doc_no || ' is over-settled by '
       || CAST(COALESCE(a.alloc, 0) - d.total_minor AS TEXT) || ' minor units', d.id
  FROM documents d
  JOIN (SELECT document_id, SUM(amount_minor) AS alloc FROM payment_allocations GROUP BY document_id) a
    ON a.document_id = d.id
 WHERE d.total_minor > 0 AND COALESCE(a.alloc, 0) > d.total_minor

UNION ALL
-- ── [11] Inventory cache ──────────────────────────────────────────────────
SELECT 1, 'STOCK_CACHE_DRIFT',
       'item ' || i.name || ': cached on-hand ' || CAST(s.quantity_milli AS TEXT)
       || ' ≠ derived ' || CAST(COALESCE(v.quantity_milli, 0) AS TEXT), i.id
  FROM items i
  LEFT JOIN stock_on_hand s ON s.item_id = i.id
  LEFT JOIN v_stock_on_hand_live v ON v.item_id = i.id
 WHERE i.deleted_at IS NULL AND i.is_stocked = 1
   AND COALESCE(s.quantity_milli, 0) <> COALESCE(v.quantity_milli, 0)

UNION ALL
-- ── [12] The audit hash chain must be unbroken per ledger ─────────────────
SELECT 1, 'AUDIT_CHAIN_BREAK',
       'audit row ' || au.id || ' (seq ' || CAST(au.seq AS TEXT) || ') does not link to its predecessor',
       au.id
  FROM audit_log au
  LEFT JOIN audit_log prev
         ON prev.ledger_id = au.ledger_id AND prev.seq = au.seq - 1
 WHERE au.seq > 1 AND prev.id IS NOT NULL AND au.hash_prev <> prev.hash_self

UNION ALL
-- ── [13] Money must be an integer, always (defends a bad restore) ─────────
SELECT 1, 'NON_INTEGER_MONEY',
       'journal_lines.' || l.id || ' holds a non-integer amount', l.id
  FROM journal_lines l
 WHERE typeof(l.amount_minor) <> 'integer' OR typeof(l.base_amount_minor) <> 'integer'

UNION ALL
-- ── [14] A reversal must point at something real ──────────────────────────
SELECT 1, 'ORPHAN_REVERSAL',
       'entry ' || e.entry_no || ' claims to reverse a missing entry', e.id
  FROM journal_entries e
 WHERE e.reversal_of_entry_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM journal_entries r WHERE r.id = e.reversal_of_entry_id)

UNION ALL
-- ── [15] Replicated rows must carry a usable CRDT stamp ───────────────────
SELECT 1, 'BAD_CRDT_STAMP',
       'journal_entries.' || e.id || ' has hlc/rev that cannot order causally', e.id
  FROM journal_entries e
 WHERE length(e.hlc) <> 57 OR e.rev < 1 OR e.hlc <> lower(e.hlc)

UNION ALL
-- ── [16] An opening-balance entry must mark its opening lines as such ─────
SELECT 1, 'OPENING_LINE_WITHOUT_FLAG',
       'entry ' || e.entry_no || ' is an opening entry but no line is flagged is_opening',
       e.id
  FROM journal_entries e
 WHERE e.status = 1 AND e.source = 7
   AND NOT EXISTS (SELECT 1 FROM journal_lines WHERE entry_id = e.id AND is_opening = 1)

-- ═══════════════════════ warnings (severity 2) ═══════════════════════════
UNION ALL
SELECT 2, 'FUTURE_DATED_ENTRY',
       'entry ' || e.entry_no || ' is dated in the future (' || date(julianday('1970-01-01') + e.entry_date)
       || ') — check the device clock', e.id
  FROM journal_entries e
 WHERE e.status = 1 AND e.entry_date > (SELECT today_epoch_day FROM v_now) + 1

UNION ALL
SELECT 2, 'NEGATIVE_STOCK',
       'item ' || i.name || ' is negative (' || CAST(v.quantity_milli AS TEXT) || ' milli-units)'
       || ' and the ledger forbids negative stock', i.id
  FROM items i
  JOIN v_stock_on_hand_live v ON v.item_id = i.id
  JOIN ledgers g ON g.id = i.ledger_id
 WHERE v.quantity_milli < 0
   AND COALESCE((SELECT value FROM app_settings WHERE key = 'inventory.allow_negative' LIMIT 1), '0') = '0'

UNION ALL
SELECT 2, 'UNALLOCATED_PAYMENT',
       'payment entry ' || e.entry_no || ' has no allocation to any invoice', e.id
  FROM journal_entries e
 WHERE e.status = 1 AND e.source IN (4, 5)
   AND NOT EXISTS (SELECT 1 FROM payment_allocations p WHERE p.payment_entry_id = e.id)

UNION ALL
SELECT 2, 'STALE_DRAFT',
       'draft entry ' || e.entry_no || ' from ' || date(julianday('1970-01-01') + e.entry_date)
       || ' is still unposted', e.id
  FROM journal_entries e
 WHERE e.status = 0
   AND e.entry_date < (SELECT today_epoch_day FROM v_now) - 30

UNION ALL
SELECT 2, 'SEARCH_INDEX_STALE',
       'search index has ' || CAST(COUNT(*) AS TEXT) || ' row(s) awaiting a rebuild',
       NULL
  FROM search_map
 WHERE fts_rowid IS NULL AND kind <> 'attachment'

UNION ALL
SELECT 2, 'UNPAIRED_PARTY_ACCOUNT',
       'party ' || p.name || ' has a ledger balance but no sub-ledger account',
       p.id
  FROM parties p
  JOIN v_party_balances b ON b.party_id = p.id
 WHERE b.net_minor <> 0
   AND NOT EXISTS (SELECT 1 FROM accounts a WHERE a.party_id = p.id AND a.deleted_at IS NULL);

INSERT OR REPLACE INTO schema_meta (key, value, updated_at) VALUES
  ('integrity_version', '1', CAST(unixepoch('subsec') * 1000 AS INTEGER));
