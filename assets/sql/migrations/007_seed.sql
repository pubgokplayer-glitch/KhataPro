-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 007_seed.sql
--  The default chart of accounts, taxes, currencies and preferences.
--
--  DETERMINISM IS THE POINT
--  ───────────────────────
--  Every seeded row gets a FIXED, hard-coded id derived from its account code
--  (printf('%012x', code)) and a zero HLC. Consequence: a phone in Rahim Yar
--  Khan and a tablet in Multan, installed independently with no network
--  between them, converge on the seed data WITHOUT exchanging a single byte —
--  the rows are identical by construction, so set-union merge is a no-op.
--  A user then renaming "Cash in Hand" to "Galla" produces a normal LWW write
--  with a real HLC, which beats the zero HLC on every peer. No conflict, no
--  special case, no seed-merge code path to get wrong.
--
--  Every ID here is a valid lowercase UUID string (version-7 shaped), because
--  the transport and the audit chain validate UUID shape on ingest.
-- ═══════════════════════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

-- ── Constants (kept literal so the seed is self-contained and greppable) ────
--  ledger      : 019a1b2c-0000-7000-8000-000000000001
--  seed node   : 00000000-0000-7000-8000-000000000000
--  seed hlc    : 000000000000000:0000:00000000-0000-7000-8000-000000000000
--  seed time   : 1735689600000  (2025-01-01T00:00:00Z — a frozen constant, so
--                freshly installed devices produce byte-identical rows)
-- ───────────────────────────────────────────────────────────────────────────

-- ── 1 · Currencies ─────────────────────────────────────────────────────────
INSERT INTO currencies (code, name, symbol, scale, symbol_before, is_seed, hlc, node_id, rev, created_at, updated_at)
VALUES
  ('PKR','Pakistani Rupee','Rs',   2, 1, 1, '000000000000000:0000:00000000-0000-7000-8000-000000000000','00000000-0000-7000-8000-000000000000',1,1735689600000,1735689600000),
  ('USD','US Dollar',      '$',    2, 1, 1, '000000000000000:0000:00000000-0000-7000-8000-000000000000','00000000-0000-7000-8000-000000000000',1,1735689600000,1735689600000),
  ('AED','UAE Dirham',     'AED',  2, 1, 1, '000000000000000:0000:00000000-0000-7000-8000-000000000000','00000000-0000-7000-8000-000000000000',1,1735689600000,1735689600000),
  ('SAR','Saudi Riyal',    'SAR',  2, 1, 1, '000000000000000:0000:00000000-0000-7000-8000-000000000000','00000000-0000-7000-8000-000000000000',1,1735689600000,1735689600000),
  ('GBP','Pound Sterling', '£',    2, 1, 1, '000000000000000:0000:00000000-0000-7000-8000-000000000000','00000000-0000-7000-8000-000000000000',1,1735689600000,1735689600000),
  ('EUR','Euro',           '€',    2, 0, 1, '000000000000000:0000:00000000-0000-7000-8000-000000000000','00000000-0000-7000-8000-000000000000',1,1735689600000,1735689600000),
  ('CNY','Chinese Yuan',   '¥',    2, 1, 1, '000000000000000:0000:00000000-0000-7000-8000-000000000000','00000000-0000-7000-8000-000000000000',1,1735689600000,1735689600000),
  ('JPY','Japanese Yen',   '¥',    0, 1, 1, '000000000000000:0000:00000000-0000-7000-8000-000000000000','00000000-0000-7000-8000-000000000000',1,1735689600000,1735689600000)
ON CONFLICT(code) DO NOTHING;

-- ── 2 · The default ledger ("My Business" — renamed on first run) ───────────
INSERT INTO ledgers (id, name, legal_name, business_kind, base_currency, country, timezone,
                     fiscal_year_start_month, currency_scale, quantity_scale, rounding_mode,
                     tax_display_mode, is_active, hlc, node_id, rev, created_at, updated_at)
SELECT '019a1b2c-0000-7000-8000-000000000001', 'My Business', NULL, 'retail_shop', 'PKR', 'PK',
       'Asia/Karachi', 7, 2, 3, 0, 0, 1,
       '000000000000000:0000:00000000-0000-7000-8000-000000000000',
       '00000000-0000-7000-8000-000000000000', 1, 1735689600000, 1735689600000
WHERE NOT EXISTS (SELECT 1 FROM ledgers WHERE id = '019a1b2c-0000-7000-8000-000000000001');

-- ── 3 · Chart of accounts ─────────────────────────────────────────────────
--  Codes are grouped 1xxx assets · 2xxx liabilities · 3xxx equity ·
--  4xxx income · 5xxx expenses · 6xxx other. `role` is the stable machine
--  handle every report binds to; the user may rename any account freely.
--    normal_balance :  1 debit-normal   −1 credit-normal
--    contra         :  an account whose natural side is inverted (discounts,
--                     drawings, accumulated depreciation)
-- ───────────────────────────────────────────────────────────────────────────
WITH seed(code, name, name_ur, kind, grp, role, nb, contra, is_cash, is_bank) AS (VALUES
  (1100,'Cash in Hand',              'نقدی',                        1,'CURRENT_ASSETS',      'cash',            1,0,1,0),
  (1110,'Bank Account',              'بینک اکاؤنٹ',                 1,'CURRENT_ASSETS',      'bank',            1,0,1,1),
  (1120,'Mobile Wallet (Easypaisa/JazzCash)','موبائل والٹ',          1,'CURRENT_ASSETS',      'mobile_wallet',   1,0,1,0),
  (1200,'Accounts Receivable (Customers)','وصولی (گاہک)',           1,'CURRENT_ASSETS',      'ar',              1,0,0,0),
  (1250,'Advances to Suppliers',     'سپلائر کو پیشگی رقم',         1,'CURRENT_ASSETS',      'advance_supplier',1,0,0,0),
  (1300,'Inventory',                 'مال متاع',                    1,'CURRENT_ASSETS',      'inventory',       1,0,0,0),
  (1350,'Prepaid Expenses',          'پیشگی اخراجات',               1,'CURRENT_ASSETS',      'prepaid',         1,0,0,0),
  (1400,'Equipment & Fixtures',      'مشینری و فرنیچر',             1,'FIXED_ASSETS',        'fixed_assets',    1,0,0,0),
  (1450,'Accumulated Depreciation',  'جمع شدہ فرسودگی',             1,'FIXED_ASSETS',        'accum_depreciation',-1,1,0,0),
  (2100,'Accounts Payable (Suppliers)','سپلائر کو ادھار',            2,'CURRENT_LIABILITIES', 'ap',             -1,0,0,0),
  (2200,'Accrued Expenses',          'واجب الادا اخراجات',          2,'CURRENT_LIABILITIES', 'accrued',        -1,0,0,0),
  (2300,'Sales Tax Payable',         'سیلز ٹیکس واجب الادا',        2,'CURRENT_LIABILITIES', 'tax_payable',    -1,0,0,0),
  (2350,'Withholding Tax Payable',   'ود ہولڈنگ ٹیکس',              2,'CURRENT_LIABILITIES', 'wht_payable',    -1,0,0,0),
  (2400,'Loans Payable',             'قرض و واجبات',                2,'LONG_TERM_LIABILITIES','loans',         -1,0,0,0),
  (2450,'Customer Advances',         'گاہک سے پیشگی رقم',           2,'CURRENT_LIABILITIES', 'customer_advance',-1,0,0,0),
  (3100,'Owner''s Capital',          'مالک کا سرمایہ',              3,'EQUITY',              'capital',        -1,0,0,0),
  (3200,'Owner''s Drawings',         'مالک کی نکاسی',               3,'EQUITY',              'drawings',        1,1,0,0),
  (3300,'Opening Balance Equity',    'افتتاحی بیلنس',               3,'EQUITY',              'opening_equity', -1,0,0,0),
  (3900,'Retained Earnings',         'جمع شدہ منافع',               3,'EQUITY',              'retained_earnings',-1,0,0,0),
  (4100,'Sales — Goods',             'فروخت (مال)',                 4,'REVENUE',             'sales',          -1,0,0,0),
  (4150,'Sales — Services',          'سروس آمدنی',                  4,'REVENUE',             'sales_services', -1,0,0,0),
  (4200,'Sales Discounts',           'رعایت (ڈسکاؤنٹ)',             4,'REVENUE',             'sales_discounts', 1,1,0,0),
  (4300,'Other Income',              'دیگر آمدنی',                  6,'OTHER_INCOME',        'other_income',   -1,0,0,0),
  (5100,'Cost of Goods Sold',        'بکی ہوئی مال کی لاگت',        5,'COGS',                'cogs',            1,0,0,0),
  (5200,'Salaries & Wages',          'تنخواہ و اجرت',               5,'OPERATING_EXPENSES',  'salaries',        1,0,0,0),
  (5300,'Rent',                      'کرایہ',                       5,'OPERATING_EXPENSES',  'rent',            1,0,0,0),
  (5400,'Utilities',                 'بجلی و گیس',                  5,'OPERATING_EXPENSES',  'utilities',       1,0,0,0),
  (5500,'Telephone & Internet',      'فون و انٹرنیٹ',               5,'OPERATING_EXPENSES',  'telecom',         1,0,0,0),
  (5600,'Fuel & Vehicle',            'پٹرول و گاڑی',                5,'OPERATING_EXPENSES',  'fuel',            1,0,0,0),
  (5700,'Repairs & Maintenance',     'مرمت و دیکھ بھال',            5,'OPERATING_EXPENSES',  'repairs',         1,0,0,0),
  (5800,'Marketing & Advertising',   'تشہیر و اشتہار',              5,'OPERATING_EXPENSES',  'marketing',       1,0,0,0),
  (5900,'Office Supplies',           'دفتری سامان',                 5,'OPERATING_EXPENSES',  'office_supplies', 1,0,0,0),
  (5950,'Bank Charges',              'بینک چارجز',                  5,'OPERATING_EXPENSES',  'bank_charges',    1,0,0,0),
  (5960,'Freight & Delivery',        'ڈھلائی و ڈیلیوری',            5,'OPERATING_EXPENSES',  'freight',         1,0,0,0),
  (5990,'Miscellaneous Expense',     'متفرق اخراجات',               5,'OPERATING_EXPENSES',  'misc_expense',    1,0,0,0),
  (6100,'Foreign Exchange Gain/Loss','شرح مبادلہ منافع/نقصان',      6,'OTHER',               'fx_gain_loss',    1,0,0,0),
  (6200,'Bad Debts',                 'ناقابل وصول رقوم',            5,'OPERATING_EXPENSES',  'bad_debts',       1,0,0,0)
)
INSERT INTO accounts (id, ledger_id, code, name, name_ur, kind, group_code, role,
                      normal_balance, is_contra, is_postable, is_system, is_cash, is_bank,
                      currency_code, opening_balance_minor, sort_order,
                      hlc, node_id, rev, created_at, updated_at)
SELECT '019a1b2c-0000-7000-8000-' || printf('%012x', s.code),
       '019a1b2c-0000-7000-8000-000000000001',
       printf('%d', s.code), s.name, s.name_ur, s.kind, s.grp, s.role,
       s.nb, s.contra, 1, 1, s.is_cash, s.is_bank,
       'PKR', 0, s.code,
       '000000000000000:0000:00000000-0000-7000-8000-000000000000',
       '00000000-0000-7000-8000-000000000000', 1, 1735689600000, 1735689600000
FROM seed s
WHERE NOT EXISTS (
  SELECT 1 FROM accounts a
   WHERE a.ledger_id = '019a1b2c-0000-7000-8000-000000000001'
     AND a.code = printf('%d', s.code));

-- ── 4 · Tax rates (Pakistan defaults; all editable) ────────────────────────
WITH seed(n, name, kind, rate_bp, account_code, is_default) AS (VALUES
  (1,'GST 18% (Standard)',      1, 1800, 2300, 1),
  (2,'GST 0% (Zero-rated/Exempt)',1,    0, 2300, 0),
  (3,'WHT 11% (Services)',      2, 1100, 2350, 0),
  (4,'WHT 4.5% (Supplies)',     2,  450, 2350, 0)
)
INSERT INTO tax_rates (id, ledger_id, name, kind, rate_bp, is_compound, account_id, is_default,
                       effective_from, is_active, hlc, node_id, rev, created_at, updated_at)
SELECT '019a1b2c-0000-7001-8000-' || printf('%012x', s.n),
       '019a1b2c-0000-7000-8000-000000000001',
       s.name, s.kind, s.rate_bp, 0,
       '019a1b2c-0000-7000-8000-' || printf('%012x', s.account_code),
       s.is_default, 0, 1,
       '000000000000000:0000:00000000-0000-7000-8000-000000000000',
       '00000000-0000-7000-8000-000000000000', 1, 1735689600000, 1735689600000
FROM seed s
WHERE NOT EXISTS (
  SELECT 1 FROM tax_rates t
   WHERE t.ledger_id = '019a1b2c-0000-7000-8000-000000000001'
     AND t.name = s.name);

-- ── 5 · A "Walk-in Customer" so a cash sale never needs a typed name ───────
INSERT INTO parties (id, ledger_id, name, name_ur, kind, is_walk_in, country,
                     payment_term_days, remind_enabled, is_active,
                     hlc, node_id, rev, created_at, updated_at)
SELECT '019a1b2c-0000-7000-8000-00000000c001', '019a1b2c-0000-7000-8000-000000000001',
       'Walk-in Customer', 'عام گاہک', 1, 1, 'PK', 0, 0, 1,
       '000000000000000:0000:00000000-0000-7000-8000-000000000000',
       '00000000-0000-7000-8000-000000000000', 1, 1735689600000, 1735689600000
WHERE NOT EXISTS (SELECT 1 FROM parties WHERE is_walk_in = 1);

-- ── 6 · Preferences (scope='ledger' syncs, scope='device' stays local) ─────
WITH seed(n, key, value, scope) AS (VALUES
  ( 1,'ui.locale',                '"en_PK"',                  'device'),
  ( 2,'ui.locale_fallback',       '"ur_PK"',                  'device'),
  ( 3,'ui.theme_mode',            '"system"',                 'device'),
  ( 4,'ui.date_format',           '"d/M/y"',                  'ledger'),
  ( 5,'ui.week_start',            '1',                        'ledger'),
  ( 6,'ui.numerals',              '"latin"',                  'device'),  -- or "urdu"
  ( 7,'ui.number_grouping',       '"lakh_crore"',             'ledger'),  -- 12,34,567 not 1,234,567
  ( 8,'money.round_off',          '1',                        'ledger'),
  ( 9,'money.cash_round_to',      '1',                        'ledger'),  -- round to nearest Re 1
  (10,'tax.default_rate_id',      '"019a1b2c-0000-7001-8000-000000000001"','ledger'),
  (11,'tax.prices_include_tax',   '0',                        'ledger'),
  (12,'invoice.terms',            '"Goods once sold are not returnable."','ledger'),
  (13,'invoice.footer',           '"Thank you for your business."','ledger'),
  (14,'invoice.show_qr',          '1',                        'ledger'),
  (15,'inventory.allow_negative', '0',                        'ledger'),
  (16,'inventory.costing',        '"moving_average"',         'ledger'),
  (17,'reminders.enabled',        '1',                        'ledger'),
  (18,'reminders.due_lead_days',  '2',                        'ledger'),
  (19,'reminders.daily_close_hour','22',                      'ledger'),
  (20,'sync.auto_lan',            '1',                        'device'),
  (21,'sync.require_charging',    '0',                        'device'),
  (22,'backup.target',            '0',                        'ledger'),  -- 0 drive, 1 icloud
  (23,'backup.daily_window_hour', '2',                        'device'),
  (24,'security.biometric_lock',  '1',                        'device'),
  (25,'security.auto_lock_seconds','60',                      'device'),
  (26,'security.screenshot_block', '1',                       'device'),
  (27,'security.hide_amounts_recents','0',                    'device'),
  (28,'telemetry.enabled',        '0',                        'device')  -- opt-in, off by default
)
INSERT INTO app_settings (id, ledger_id, scope, key, value, hlc, node_id, rev, created_at, updated_at)
SELECT '019a1b2c-0000-7002-8000-' || printf('%012x', s.n),
       CASE s.scope WHEN 'ledger' THEN '019a1b2c-0000-7000-8000-000000000001' ELSE NULL END,
       s.scope, s.key, s.value,
       '000000000000000:0000:00000000-0000-7000-8000-000000000000',
       '00000000-0000-7000-8000-000000000000', 1, 1735689600000, 1735689600000
FROM seed s
WHERE NOT EXISTS (
  SELECT 1 FROM app_settings a WHERE a.key = s.key AND COALESCE(a.ledger_id,'') = COALESCE(CASE s.scope WHEN 'ledger' THEN '019a1b2c-0000-7000-8000-000000000001' ELSE NULL END,''));

-- ── 7 · Document numbering (LOCAL per node, seeded for the first node) ─────
WITH seed(kind, prefix, padding) AS (VALUES
  (1,'INV',4),   -- sale invoice
  (2,'BILL',4),  -- purchase bill
  (3,'CN',4),    -- credit note (sales return)
  (4,'DN',4),    -- debit note (purchase return)
  (5,'QT',4),    -- quotation
  (6,'EST',4),   -- estimate
  (7,'DC',4),    -- delivery challan
  (8,'RCV',4),   -- payment received
  (9,'PAY',4),   -- payment made
  (10,'EXP',4)   -- expense voucher
)
INSERT INTO number_sequences (ledger_id, doc_kind, node_id, prefix, padding, next_value, step)
SELECT '019a1b2c-0000-7000-8000-000000000001', s.kind,
       COALESCE((SELECT node_id FROM nodes WHERE is_this_device = 1),
                '00000000-0000-7000-8000-000000000000'),
       s.prefix, s.padding, 1, 1
FROM seed s
WHERE NOT EXISTS (
  SELECT 1 FROM number_sequences n
   WHERE n.ledger_id = '019a1b2c-0000-7000-8000-000000000001' AND n.doc_kind = s.kind);

-- ── 8 · Session anchors (rewritten with the ledger's timezone on every open) ─
--  Pakistan's fiscal year runs July→June, hence the +6/−6 month arithmetic.
INSERT OR REPLACE INTO session_flags (key, value) VALUES
  ('session_id',       COALESCE((SELECT value FROM session_flags WHERE key = 'session_id'), 'unset')),
  ('write_mode',       'user'),
  ('today_epoch_day',  CAST(julianday('now') - julianday('1970-01-01') AS TEXT)),
  ('month_start',      CAST(julianday('now','start of month') - julianday('1970-01-01') AS TEXT)),
  ('fy_start',         CAST(julianday(
                          CASE WHEN CAST(strftime('%m','now') AS INTEGER) >= 7
                               THEN date('now','start of year','+6 months')
                               ELSE date('now','start of year','-6 months') END)
                        - julianday('1970-01-01') AS TEXT));

INSERT OR REPLACE INTO schema_meta (key, value, updated_at) VALUES
  ('seed_version', '1', CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  ('default_ledger_id', '019a1b2c-0000-7000-8000-000000000001', CAST(unixepoch('subsec') * 1000 AS INTEGER));
