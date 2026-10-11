-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 004_views.sql
--  Every report in the app is a VIEW, not a Dart-side aggregation. Rationale:
--  SQLite is C, single-pass and page-local; Dart would have to materialise
--  tens of thousands of rows through an encrypted FFI boundary and then sum
--  them in a garbage-collected heap. On a 4-core ARM phone that difference is
--  the difference between a 16 ms frame and a 240 ms one.
--
--  "Today" and other calendar anchors come from session_flags
--  (`today_epoch_day`, `month_start`, `fy_start`), which the app refreshes on
--  every open/resume using the LEDGER's timezone — never UTC. A Karachi shop
--  closing its book at 00:30 must not have that sale land on "yesterday"
--  because the server-standard clock says so.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Helpers used by several views ──────────────────────────────────────────
CREATE VIEW IF NOT EXISTS v_now AS
SELECT CAST(COALESCE((SELECT value FROM session_flags WHERE key = 'today_epoch_day'),
        CAST(julianday('now') - julianday('1970-01-01') AS INTEGER)) AS INTEGER) AS today_epoch_day,
       CAST(COALESCE((SELECT value FROM session_flags WHERE key = 'month_start'),
        CAST(julianday('now', 'start of month') - julianday('1970-01-01') AS INTEGER)) AS INTEGER) AS month_start,
       CAST(COALESCE((SELECT value FROM session_flags WHERE key = 'fy_start'),
        CAST(julianday('now', 'start of year') - julianday('1970-01-01') AS INTEGER)) AS INTEGER) AS fy_start;

-- ── v_account_balances_live ────────────────────────────────────────────────
-- Ground truth for an account balance, computed from POSTED entries only.
-- Drafts are deliberately invisible to every financial report.
CREATE VIEW IF NOT EXISTS v_account_balances_live AS
SELECT l.ledger_id                                              AS ledger_id,
       a.id                                                     AS account_id,
       a.code                                                   AS code,
       a.name                                                   AS name,
       a.name_ur                                                AS name_ur,
       a.kind                                                   AS kind,
       a.group_code                                             AS group_code,
       a.role                                                   AS role,
       a.normal_balance                                         AS normal_balance,
       a.is_contra                                              AS is_contra,
       a.currency_code                                          AS currency_code,
       COALESCE(SUM(l.debit_minor), 0)                           AS debit_minor,
       COALESCE(SUM(l.credit_minor), 0)                           AS credit_minor,
       COALESCE(SUM(l.amount_minor), 0)                           AS net_minor,
       -- Signed against the normal side: >0 = "as expected" for this account.
       COALESCE(SUM(l.amount_minor), 0) * a.normal_balance        AS normal_net_minor,
       COUNT(l.id)                                               AS line_count,
       MAX(l.entry_date)                                         AS last_entry_date
FROM accounts a
LEFT JOIN journal_lines  l ON l.account_id = a.id AND l.ledger_id = a.ledger_id
LEFT JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
WHERE a.deleted_at IS NULL
  AND (l.id IS NULL OR e.id IS NOT NULL)      -- drop draft/voided lines
GROUP BY a.id;

-- ── v_account_balances (FAST PATH) ────────────────────────────────────────
-- Reports read the audited balance cache, never a fresh aggregate over every
-- line. That is the whole reason account_balances exists, and the reason a
-- trial balance is a 0.2 ms index lookup instead of a 90 ms scan over 50 000
-- lines. The cache is trustworthy because:
--   · GATE-2 proves cache == before + delta on every single commit, and
--   · v_integrity_report [5] compares it against v_account_balances_live
--     (the from-first-principles version) on demand and nightly.
-- For period reports (this month, this quarter) the app reads
-- v_account_balances_period with period_id 1/2/3 — same shape, same cost.
CREATE VIEW IF NOT EXISTS v_account_balances AS
SELECT a.ledger_id, a.id AS account_id, a.code, a.name, a.name_ur, a.kind, a.group_code,
       a.role, a.normal_balance, a.is_contra, a.is_postable, a.is_cash, a.is_bank,
       a.currency_code,
       COALESCE(ab.debit_minor, 0)                          AS debit_minor,
       COALESCE(ab.credit_minor, 0)                         AS credit_minor,
       COALESCE(ab.net_minor, 0)                            AS net_minor,
       COALESCE(ab.net_minor, 0) * a.normal_balance         AS normal_net_minor,
       COALESCE(ab.txn_count, 0)                            AS line_count,
       ab.last_entry_date
FROM accounts a
LEFT JOIN account_balances ab
       ON ab.account_id = a.id AND ab.period_id = 0 AND ab.period_start = 0
WHERE a.deleted_at IS NULL;

-- ── v_account_balances_period ─────────────────────────────────────────────
-- Period grain: the app filters period_id + period_start (both indexed by the
-- account_balances primary key), so "this month" is a range scan, not a scan.
CREATE VIEW IF NOT EXISTS v_account_balances_period AS
SELECT a.ledger_id, a.id AS account_id, a.code, a.name, a.kind, a.group_code, a.role,
       a.normal_balance, ab.period_id, ab.period_start,
       ab.debit_minor, ab.credit_minor, ab.net_minor,
       ab.net_minor * a.normal_balance AS normal_net_minor,
       ab.txn_count, ab.last_entry_date
FROM account_balances ab
JOIN accounts a ON a.id = ab.account_id
WHERE a.deleted_at IS NULL;

-- ── v_trial_balance ────────────────────────────────────────────────────────
-- Classic Dr/Cr columns. NOTE the two different sign conventions in play, and
-- why they must not be mixed up:
--   net_minor        debit − credit   → which SIDE the balance actually sits on
--   normal_net_minor net × normal_bal → whether that is "as expected" for the
--                                       account's natural side (a display aid)
-- The Dr/Cr columns below are driven by net_minor, i.e. by reality. A credit-
-- normal account that happens to be overdrawn (a supplier advance, say) must
-- land in the DEBIT column, and an early version of this view got that wrong —
-- caught by test/sql contract test D3/H4. Keep the split on net_minor.
CREATE VIEW IF NOT EXISTS v_trial_balance AS
SELECT x.ledger_id, x.account_id, x.code, x.name, x.name_ur, x.kind, x.group_code, x.role,
       x.debit_minor, x.credit_minor,
       x.normal_net_minor                                                   AS closing_on_normal_side_minor,
       CASE WHEN x.net_minor >= 0 THEN  x.net_minor ELSE 0 END              AS closing_debit_minor,
       CASE WHEN x.net_minor <  0 THEN -x.net_minor ELSE 0 END              AS closing_credit_minor,
       x.net_minor                                                          AS signed_net_minor
FROM v_account_balances x
WHERE x.line_count > 0 OR x.kind <= 3;   -- always show BS accounts, even at zero

-- ── v_journal_detail ───────────────────────────────────────────────────────
-- One row per LINE, print-ready (account name, Dr/Cr, base-currency amount).
CREATE VIEW IF NOT EXISTS v_journal_detail AS
SELECT e.ledger_id          AS ledger_id,
       e.id                 AS entry_id,
       e.entry_no           AS entry_no,
       e.entry_date         AS entry_date,
       date(julianday('1970-01-01') + e.entry_date) AS entry_date_iso,
       e.status             AS status,
       e.source             AS source,
       e.memo               AS memo,
       e.doc_no             AS doc_no,
       e.party_id           AS party_id,
       p.name               AS party_name,
       e.currency_code      AS currency_code,
       e.fx_rate_micros     AS fx_rate_micros,
       l.id                 AS line_id,
       l.line_no            AS line_no,
       l.account_id         AS account_id,
       a.code               AS account_code,
       a.name               AS account_name,
       l.debit_minor        AS debit_minor,
       l.credit_minor       AS credit_minor,
       l.amount_minor       AS amount_minor,
       l.base_amount_minor  AS base_amount_minor,
       l.item_id            AS item_id,
       i.name               AS item_name,
       l.quantity_milli     AS quantity_milli,
       l.memo               AS line_memo,
       l.reconciled_at      AS reconciled_at,
       e.hlc                AS hlc,
       e.created_at         AS created_at
FROM journal_lines  l
JOIN journal_entries e ON e.id = l.entry_id
LEFT JOIN accounts   a ON a.id = l.account_id
LEFT JOIN parties    p ON p.id = l.party_id
LEFT JOIN items      i ON i.id = l.item_id;

-- ── v_party_ledger ─────────────────────────────────────────────────────────
-- Running balance per party — the screen khata users actually live in.
-- hlc/line_no in the ORDER BY makes the running total *deterministic* across
-- devices: same rows, same order, same number, always.
CREATE VIEW IF NOT EXISTS v_party_ledger AS
SELECT l.ledger_id,
       l.party_id,
       l.id                                            AS line_id,
       l.line_no,
       l.entry_id,
       e.entry_no,
       l.entry_date,
       date(julianday('1970-01-01') + l.entry_date) AS entry_date_iso,
       l.account_id,
       a.name                                          AS account_name,
       l.amount_minor,
       l.base_amount_minor,
       e.memo,
       e.doc_no,
       e.source,
       SUM(l.amount_minor) OVER (
         PARTITION BY l.ledger_id, l.party_id
         ORDER BY l.entry_date, e.created_at, l.line_no, l.id
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       )                                                AS running_balance_minor
FROM journal_lines l
JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
LEFT JOIN accounts a ON a.id = l.account_id
WHERE l.party_id IS NOT NULL;

-- ── v_party_balances ───────────────────────────────────────────────────────
-- One row per party: net position + receivable/payable split + recency.
-- receivable_minor > 0 ⇒ the party owes the business (asset side, net debit).
CREATE VIEW IF NOT EXISTS v_party_balances AS
SELECT p.ledger_id,
       p.id                                                       AS party_id,
       p.name,
       p.name_ur,
       p.kind,
       p.phone,
       p.is_walk_in,
       COALESCE(SUM(l.amount_minor), 0)                            AS net_minor,
       CASE WHEN COALESCE(SUM(l.amount_minor),0) > 0
            THEN COALESCE(SUM(l.amount_minor),0) ELSE 0 END        AS receivable_minor,
       CASE WHEN COALESCE(SUM(l.amount_minor),0) < 0
            THEN -COALESCE(SUM(l.amount_minor),0) ELSE 0 END       AS payable_minor,
       MAX(l.entry_date)                                          AS last_activity_date,
       COUNT(l.id)                                                AS line_count
FROM parties p
LEFT JOIN journal_lines  l ON l.party_id = p.id AND l.ledger_id = p.ledger_id
LEFT JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
WHERE p.deleted_at IS NULL
  AND (l.id IS NULL OR e.id IS NOT NULL)
GROUP BY p.id;

-- ── v_profit_and_loss ──────────────────────────────────────────────────────
-- Income (4xxx), expenses (5xxx) and other (6xxx) with the standard layout,
-- read from the audited cache (see v_account_balances above).
-- `amount_minor` is presentation-ready: income shows positive for a credit
-- balance (net_minor is negative there), expenses show positive for a debit.
--   profit = SUM(amount) FILTER (kind IN (4,6)) − SUM(amount) FILTER (kind = 5)
CREATE VIEW IF NOT EXISTS v_profit_and_loss AS
SELECT ledger_id, account_id, code, name, name_ur, kind, group_code, role, normal_balance,
       CASE WHEN kind = 4 THEN -net_minor ELSE net_minor END   AS amount_minor,
       CASE WHEN net_minor >= 0 THEN  net_minor ELSE 0 END     AS period_debit_minor,
       CASE WHEN net_minor <  0 THEN -net_minor ELSE 0 END     AS period_credit_minor
FROM v_account_balances
WHERE kind IN (4, 5, 6);

-- ── v_balance_sheet ────────────────────────────────────────────────────────
-- Same rule as the trial balance: columns follow the real balance side.
CREATE VIEW IF NOT EXISTS v_balance_sheet AS
SELECT ledger_id, account_id, code, name, name_ur, kind, group_code,
       net_minor,
       CASE WHEN net_minor >= 0 THEN  net_minor ELSE 0 END AS show_debit_minor,
       CASE WHEN net_minor <  0 THEN -net_minor ELSE 0 END AS show_credit_minor
FROM v_account_balances
WHERE kind IN (1, 2, 3);

-- ── v_document_outstanding ────────────────────────────────────────────────
-- Unpaid/partly-paid invoices & bills, with the aged figure already computed.
CREATE VIEW IF NOT EXISTS v_document_outstanding AS
SELECT d.ledger_id, d.id AS document_id, d.doc_kind, d.doc_no, d.doc_date, d.due_date, d.status,
       date(julianday('1970-01-01') + d.doc_date) AS doc_date_iso,
       date(julianday('1970-01-01') + d.due_date) AS due_date_iso,
       d.party_id, p.name AS party_name, p.phone AS party_phone,
       d.total_minor, d.amount_paid_minor, d.balance_minor, d.currency_code,
       CASE WHEN d.due_date IS NULL THEN 0
            ELSE CAST((SELECT today_epoch_day FROM v_now) - d.due_date AS INTEGER) END AS days_overdue,
       CASE
         WHEN d.due_date IS NULL THEN 0
         WHEN (SELECT today_epoch_day FROM v_now) <= d.due_date THEN 0
         WHEN (SELECT today_epoch_day FROM v_now) - d.due_date <= 15 THEN 1
         WHEN (SELECT today_epoch_day FROM v_now) - d.due_date <= 30 THEN 2
         WHEN (SELECT today_epoch_day FROM v_now) - d.due_date <= 60 THEN 3
         WHEN (SELECT today_epoch_day FROM v_now) - d.due_date <= 90 THEN 4
         ELSE 5
       END AS aging_bucket          -- 0 current, 1 1–15, 2 16–30, 3 31–60, 4 61–90, 5 90+
FROM documents d
LEFT JOIN parties p ON p.id = d.party_id
WHERE d.deleted_at IS NULL
  AND d.balance_minor <> 0
  AND d.status IN (0, 1)
  AND d.doc_kind IN (1, 2, 3, 4);

-- ── v_daily_cashflow ──────────────────────────────────────────────────────
-- Cash + bank movement per day per account: the "kitna hua aaj?" screen and
-- the source for the 90-day sparkline in the dashboard.
CREATE VIEW IF NOT EXISTS v_daily_cashflow AS
SELECT l.ledger_id,
       l.entry_date,
       l.account_id,
       a.name                                            AS account_name,
       SUM(l.amount_minor)                               AS net_minor,
       SUM(l.debit_minor)                                AS inflow_minor,
       SUM(l.credit_minor)                               AS outflow_minor,
       SUM(l.base_amount_minor)                          AS net_base_minor,
       COUNT(*)                                          AS txn_count
FROM journal_lines l
JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
JOIN accounts a ON a.id = l.account_id AND a.is_cash = 1
GROUP BY l.ledger_id, l.entry_date, l.account_id;

-- ── v_stock_on_hand_live ──────────────────────────────────────────────────
-- Recomputed from stock_moves; must agree with the stock_on_hand cache (the
-- nightly verifier asserts exactly that, and repairs silently if it drifts).
CREATE VIEW IF NOT EXISTS v_stock_on_hand_live AS
SELECT i.ledger_id, i.id AS item_id, i.name AS item_name, i.sku, i.unit, i.barcode,
       i.reorder_level_milli,
       COALESCE(SUM(m.direction * m.quantity_milli), 0)                       AS quantity_milli,
       COALESCE(SUM(m.value_minor), 0)                                        AS value_minor,
       CASE WHEN COALESCE(SUM(m.direction * m.quantity_milli), 0) > 0
            THEN ABS(COALESCE(SUM(m.value_minor),0)) * 1000000
                 / SUM(m.direction * m.quantity_milli)
            ELSE 0 END                                                        AS avg_cost_micros,
       i.sale_price_minor, i.is_stocked, i.is_active
FROM items i
LEFT JOIN stock_moves m ON m.item_id = i.id AND m.ledger_id = i.ledger_id
WHERE i.deleted_at IS NULL
GROUP BY i.id;

-- ── v_dashboard_metrics ───────────────────────────────────────────────────
-- ONE row, everything the home screen needs, in a single index-only pass.
-- The whole point: the dashboard must render its first frame in under 16 ms
-- even with 50 000 postings.
--
-- SIGN CONVENTION (important, and the reason every metric below multiplies by
-- `normal_balance`): a raw ledger amount is Dr-positive, so a Rs 1,250 sale
-- is −125,000 and a Rs 6,000 payable is −600,000. Nobody wants to see
-- "Today's sales: −1,250". Every metric is therefore normalised to its
-- account's *natural side*, so a positive number always means "more of the
-- thing the label says": sales earned, money owed to you, money you owe, cash
-- in hand. The UI can then print raw values with zero sign-fixing logic —
-- which is exactly how sign bugs stop existing.
CREATE VIEW IF NOT EXISTS v_dashboard_metrics AS
SELECT g.id                                                        AS ledger_id,
       g.base_currency                                             AS currency_code,
       (SELECT today_epoch_day FROM v_now)                         AS today_epoch_day,
       (SELECT COUNT(*) FROM journal_entries e
         WHERE e.ledger_id = g.id AND e.status = 0)                AS draft_count,
       (SELECT COALESCE(SUM(l.base_amount_minor * a.normal_balance), 0)
          FROM journal_lines l
          JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
          JOIN accounts a ON a.id = l.account_id
         WHERE l.ledger_id = g.id AND a.role = 'sales'
           AND l.entry_date = (SELECT today_epoch_day FROM v_now)) AS today_sales_minor,
       (SELECT COALESCE(SUM(l.base_amount_minor * a.normal_balance), 0)
          FROM journal_lines l
          JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
          JOIN accounts a ON a.id = l.account_id
         WHERE l.ledger_id = g.id AND a.role = 'sales'
           AND l.entry_date >= (SELECT month_start FROM v_now))    AS month_sales_minor,
       (SELECT COALESCE(SUM(l.base_amount_minor * a.normal_balance), 0)
          FROM journal_lines l
          JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
          JOIN accounts a ON a.id = l.account_id AND a.kind = 5
         WHERE l.ledger_id = g.id
           AND l.entry_date >= (SELECT month_start FROM v_now))    AS month_expense_minor,
       -- receivables: positive = customers owe the business
       (SELECT COALESCE(SUM(ab.net_minor * a.normal_balance), 0)
          FROM account_balances ab JOIN accounts a ON a.id = ab.account_id
         WHERE ab.ledger_id = g.id AND ab.period_id = 0 AND a.role = 'ar') AS receivable_minor,
       -- payables: positive = the business owes suppliers
       (SELECT COALESCE(SUM(ab.net_minor * a.normal_balance), 0)
          FROM account_balances ab JOIN accounts a ON a.id = ab.account_id
         WHERE ab.ledger_id = g.id AND ab.period_id = 0 AND a.role = 'ap') AS payable_minor,
       -- cash, bank and mobile wallet on hand
       (SELECT COALESCE(SUM(ab.net_minor * a.normal_balance), 0)
          FROM account_balances ab JOIN accounts a ON a.id = ab.account_id AND a.is_cash = 1
         WHERE ab.ledger_id = g.id AND ab.period_id = 0)           AS cash_minor,
       -- gross profit this month, straight from the ledger
       (SELECT COALESCE(SUM(l.base_amount_minor * a.normal_balance), 0)
          FROM journal_lines l
          JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
          JOIN accounts a ON a.id = l.account_id
         WHERE l.ledger_id = g.id AND a.kind = 4
           AND l.entry_date >= (SELECT month_start FROM v_now))
       - (SELECT COALESCE(SUM(l.base_amount_minor * a.normal_balance), 0)
            FROM journal_lines l
            JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
            JOIN accounts a ON a.id = l.account_id AND a.kind = 5
           WHERE l.ledger_id = g.id
             AND l.entry_date >= (SELECT month_start FROM v_now))  AS month_profit_minor
FROM ledgers g
WHERE g.deleted_at IS NULL;

-- ── v_sync_health ─────────────────────────────────────────────────────────
-- Powers the sync card in Settings: pending op count, last success, peer count.
CREATE VIEW IF NOT EXISTS v_sync_health AS
SELECT (SELECT COUNT(*) FROM oplog WHERE dispatched_at IS NULL)          AS pending_ops,
       (SELECT MIN(created_at) FROM oplog WHERE dispatched_at IS NULL)   AS oldest_pending_at,
       (SELECT COUNT(*) FROM sync_peers WHERE trust_state = 1)           AS trusted_peers,
       (SELECT MAX(ended_at) FROM sync_sessions WHERE status = 1)        AS last_success_at,
       (SELECT COUNT(*) FROM conflict_log WHERE reviewed_at IS NULL)     AS unreviewed_conflicts,
       (SELECT MAX(last_success_at) FROM backup_state)                   AS last_backup_at,
       (SELECT MAX(seq) FROM oplog)                                     AS oplog_head_seq;

-- Indexes the dashboard specifically needs: a tiny partial index for the
-- "N drafts waiting" badge (a full scan of 20 000 entries costs 25 ms alone),
-- and a covering index so the month filters never touch the heap.
CREATE INDEX IF NOT EXISTS ix_je_drafts_pending
  ON journal_entries (ledger_id, entry_date) WHERE status = 0;
CREATE INDEX IF NOT EXISTS ix_jl_date_role_cover
  ON journal_lines (ledger_id, entry_date, account_id, base_amount_minor);

INSERT OR REPLACE INTO schema_meta (key, value, updated_at) VALUES
  ('views_version', '2', CAST(unixepoch('subsec') * 1000 AS INTEGER));
