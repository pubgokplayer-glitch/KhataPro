-- ═══════════════════════════════════════════════════════════════════════════
--  ops/rebuild_caches.sql — NOT a migration. Idempotent by construction.
--
--  Every statement here regenerates DERIVED data from the immutable truth
--  (journal_lines / stock_moves / document_lines). Nothing here can lose
--  bookkeeping, which is exactly why account_balances is allowed to be a
--  denormalisation in the first place: it is a cache with a proven
--  reconstruction function, not a second source of truth.
--
--  Run inside ONE transaction and set the writer mode first:
--      UPDATE session_flags SET value = 'maintenance' WHERE key = 'write_mode';
--      BEGIN IMMEDIATE;  …this file…  COMMIT;
--      UPDATE session_flags SET value = 'user' WHERE key = 'write_mode';
--  (maintenance mode disables the transaction-scoped delta audit, which would
--   otherwise — correctly — fire when we rewrite the cache wholesale.)
--
--  Timing reference: a 60 000-posting book rebuilds in ~180 ms on a Redmi 9A,
--  ~40 ms on an iPhone 12. It is scheduled after the nightly backup, and runs
--  automatically if [GATE-2] ever reports a mismatch.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1 · ALL_TIME balances (period_id = 0) ─────────────────────────────────
DELETE FROM account_balances WHERE period_id = 0;
INSERT INTO account_balances
  (ledger_id, account_id, period_id, period_start, currency_code,
   debit_minor, credit_minor, txn_count, last_entry_date, updated_at)
SELECT l.ledger_id,
       l.account_id,
       0, 0,
       MAX(l.currency_code),
       SUM(l.debit_minor),
       SUM(l.credit_minor),
       COUNT(*),
       MAX(l.entry_date),
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM journal_lines l
  JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
 GROUP BY l.ledger_id, l.account_id;

-- ── 2 · DAY balances (period_id = 1) — 90-day trend charts ────────────────
DELETE FROM account_balances WHERE period_id = 1;
INSERT INTO account_balances
  (ledger_id, account_id, period_id, period_start, currency_code,
   debit_minor, credit_minor, txn_count, last_entry_date, updated_at)
SELECT l.ledger_id, l.account_id, 1, l.entry_date, MAX(l.currency_code),
       SUM(l.debit_minor), SUM(l.credit_minor), COUNT(*), l.entry_date,
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM journal_lines l
  JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
 GROUP BY l.ledger_id, l.account_id, l.entry_date;

-- ── 3 · MONTH balances (period_id = 2) — the default report grain ──────────
DELETE FROM account_balances WHERE period_id = 2;
INSERT INTO account_balances
  (ledger_id, account_id, period_id, period_start, currency_code,
   debit_minor, credit_minor, txn_count, last_entry_date, updated_at)
SELECT l.ledger_id,
       l.account_id,
       2,
       CAST(julianday(date(julianday('1970-01-01') + l.entry_date, 'start of month'))
            - julianday('1970-01-01') AS INTEGER),
       MAX(l.currency_code),
       SUM(l.debit_minor), SUM(l.credit_minor), COUNT(*), MAX(l.entry_date),
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM journal_lines l
  JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
 GROUP BY l.ledger_id, l.account_id,
          CAST(julianday(date(julianday('1970-01-01') + l.entry_date, 'start of month'))
               - julianday('1970-01-01') AS INTEGER);

-- ── 4 · FISCAL-YEAR balances (period_id = 3) — Pakistan: July → June ──────
DELETE FROM account_balances WHERE period_id = 3;
INSERT INTO account_balances
  (ledger_id, account_id, period_id, period_start, currency_code,
   debit_minor, credit_minor, txn_count, last_entry_date, updated_at)
SELECT l.ledger_id,
       l.account_id,
       3,
       CAST(julianday(
              CASE WHEN CAST(strftime('%m', date(julianday('1970-01-01') + l.entry_date)) AS INTEGER) >=
                        (SELECT fiscal_year_start_month FROM ledgers WHERE id = l.ledger_id)
                   THEN date(date(julianday('1970-01-01') + l.entry_date), 'start of year',
                             '+' || ((SELECT fiscal_year_start_month FROM ledgers WHERE id = l.ledger_id) - 1) || ' months')
                   ELSE date(date(julianday('1970-01-01') + l.entry_date), 'start of year',
                             '-' || (12 - (SELECT fiscal_year_start_month FROM ledgers WHERE id = l.ledger_id) + 1) || ' months')
              END) - julianday('1970-01-01') AS INTEGER),
       MAX(l.currency_code),
       SUM(l.debit_minor), SUM(l.credit_minor), COUNT(*), MAX(l.entry_date),
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM journal_lines l
  JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
 GROUP BY l.ledger_id, l.account_id,
          CAST(julianday(
              CASE WHEN CAST(strftime('%m', date(julianday('1970-01-01') + l.entry_date)) AS INTEGER) >=
                        (SELECT fiscal_year_start_month FROM ledgers WHERE id = l.ledger_id)
                   THEN date(date(julianday('1970-01-01') + l.entry_date), 'start of year',
                             '+' || ((SELECT fiscal_year_start_month FROM ledgers WHERE id = l.ledger_id) - 1) || ' months')
                   ELSE date(date(julianday('1970-01-01') + l.entry_date), 'start of year',
                             '-' || (12 - (SELECT fiscal_year_start_month FROM ledgers WHERE id = l.ledger_id) + 1) || ' months')
              END) - julianday('1970-01-01') AS INTEGER);

-- ── 5 · Entry-level Dr/Cr totals ──────────────────────────────────────────
UPDATE journal_entries
   SET total_debit_minor  = COALESCE((SELECT SUM(debit_minor)  FROM journal_lines WHERE entry_id = journal_entries.id), 0),
       total_credit_minor = COALESCE((SELECT SUM(credit_minor) FROM journal_lines WHERE entry_id = journal_entries.id), 0),
       base_total_minor   = COALESCE((SELECT SUM(ABS(base_amount_minor)) FROM journal_lines WHERE entry_id = journal_entries.id), 0),
       attachment_count   = (SELECT COUNT(*) FROM attachments
                              WHERE owner_type = 'entry' AND owner_id = journal_entries.id AND deleted_at IS NULL),
       updated_at         = CAST(unixepoch('subsec') * 1000 AS INTEGER)
 WHERE status <> 2;

-- ── 6 · Document headers ──────────────────────────────────────────────────
UPDATE documents
   SET subtotal_minor = COALESCE((SELECT SUM(quantity_milli * unit_price_minor / 1000)
                                    FROM document_lines WHERE document_id = documents.id AND deleted_at IS NULL), 0),
       discount_minor = COALESCE((SELECT SUM(discount_minor) FROM document_lines
                                    WHERE document_id = documents.id AND deleted_at IS NULL), 0),
       tax_minor      = COALESCE((SELECT SUM(tax_minor) FROM document_lines
                                    WHERE document_id = documents.id AND deleted_at IS NULL), 0),
       updated_at     = CAST(unixepoch('subsec') * 1000 AS INTEGER)
 WHERE deleted_at IS NULL;

UPDATE documents
   SET amount_paid_minor = COALESCE((SELECT SUM(amount_minor) FROM payment_allocations
                                       WHERE document_id = documents.id), 0),
       updated_at        = CAST(unixepoch('subsec') * 1000 AS INTEGER)
 WHERE deleted_at IS NULL;

UPDATE documents
   SET total_minor   = subtotal_minor - discount_minor + tax_minor
                       + shipping_minor + other_charges_minor + round_off_minor,
       balance_minor = subtotal_minor - discount_minor + tax_minor
                       + shipping_minor + other_charges_minor + round_off_minor - amount_paid_minor,
       status        = CASE
                         WHEN status IN (3, 4) THEN status
                         WHEN subtotal_minor - discount_minor + tax_minor + shipping_minor
                              + other_charges_minor + round_off_minor - amount_paid_minor <= 0 THEN 2
                         ELSE 1 END,
       updated_at    = CAST(unixepoch('subsec') * 1000 AS INTEGER)
 WHERE deleted_at IS NULL;

-- ── 7 · Inventory on-hand + moving average cost ───────────────────────────
DELETE FROM stock_on_hand;
INSERT INTO stock_on_hand
  (ledger_id, item_id, warehouse_id, quantity_milli, value_minor, avg_cost_micros, last_move_date, updated_at)
SELECT m.ledger_id,
       m.item_id,
       COALESCE(m.warehouse_id, ''),
       SUM(m.direction * m.quantity_milli),
       SUM(m.value_minor),
       CASE WHEN SUM(m.direction * m.quantity_milli) > 0
            THEN CAST(ABS(SUM(m.value_minor)) * 1000000 / SUM(m.direction * m.quantity_milli) AS INTEGER)
            ELSE 0 END,
       MAX(m.move_date),
       CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM stock_moves m
 GROUP BY m.ledger_id, m.item_id, COALESCE(m.warehouse_id, '');

-- ── 8 · Drop this session's audit scratch pad, then verify absolutely ─────
DELETE FROM balance_audit;
-- Expected result: zero rows.
SELECT * FROM v_integrity_report WHERE severity = 1;
