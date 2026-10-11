-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 011_dashboard_party_rollup.sql
--
--  Redefines `v_dashboard_metrics` so receivables and payables include the party
--  sub-ledgers. Nothing else about the view changes.
--
--  THE BUG (found by `tool/ui_db_verify.dart`, the D4 integration suite, running the
--  dashboard provider against a real database with real invoices in it):
--
--      (SELECT COALESCE(SUM(ab.net_minor * a.normal_balance), 0)
--         FROM account_balances ab JOIN accounts a ON a.id = ab.account_id
--        WHERE ab.ledger_id = g.id AND ab.period_id = 0 AND a.role = 'ar')
--
--  `a.role = 'ar'` matches the **control account only**. Every party's sub-ledger is a
--  child of that control with `role IS NULL` — deliberately, because the unique role
--  index allows exactly one account per role per ledger, and because the control owns
--  the account's nature (kind, normal balance, group) while the child only owns the
--  party. Credit sales post to the child.
--
--  So on a book with Rs 15,000 of opening receivables and Rs 6,300 of credit sales the
--  dashboard said "you are owed Rs 15,000": the opening balance, and none of the actual
--  trade. The number was wrong in the direction that costs money — a shopkeeper who
--  believes their receivables are Rs 15,000 stops chasing Rs 6,300. `payable_minor` had
--  the identical defect for suppliers.
--
--  WHY A NEW FILE RATHER THAN AN EDIT to 004: 004 has already run on developer installs,
--  and `SqlMigrationRunner.verifyAppliedChecksums` refuses to open a database whose
--  applied file changed. Editing 004 would make the app refuse its own database, which
--  is the guard working as intended — and the reason this is 011.
--
--  The roll-up is two levels deep (control → party), which is all the chart of accounts
--  has. A recursive walk would be more general and slower for every dashboard frame;
--  `v_account_balances` is rebuilt by triggers and this view reads the cache, so the
--  subquery is an index lookup on `ix_accounts_parent`.
-- ═══════════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS v_dashboard_metrics;

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
       -- receivables: positive = customers owe the business.
       -- The control account AND its party sub-ledgers. The sub-ledger accounts carry
       -- `role IS NULL` (the role belongs to the control they hang from, and the unique
       -- role index allows one control per role), so filtering on `a.role = 'ar'` alone
       -- counted the opening balances and *none* of the credit sales: a shop owed
       -- Rs 21,300 was told it was owed Rs 15,000. See 011.
       (SELECT COALESCE(SUM(ab.net_minor * a.normal_balance), 0)
          FROM account_balances ab JOIN accounts a ON a.id = ab.account_id
         WHERE ab.ledger_id = g.id AND ab.period_id = 0
           AND (a.role = 'ar'
                OR a.parent_id IN (SELECT c.id FROM accounts c
                                    WHERE c.ledger_id = g.id AND c.role = 'ar'))) AS receivable_minor,
       -- payables: positive = the business owes suppliers — rolled up the same way.
       (SELECT COALESCE(SUM(ab.net_minor * a.normal_balance), 0)
          FROM account_balances ab JOIN accounts a ON a.id = ab.account_id
         WHERE ab.ledger_id = g.id AND ab.period_id = 0
           AND (a.role = 'ap'
                OR a.parent_id IN (SELECT c.id FROM accounts c
                                    WHERE c.ledger_id = g.id AND c.role = 'ap'))) AS payable_minor,
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
