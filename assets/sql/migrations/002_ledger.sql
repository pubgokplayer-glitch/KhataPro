-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 002_ledger.sql
--  THE DOUBLE-ENTRY CORE.
--
--  Model: every economic event is ONE `journal_entries` row (the "transaction"
--  in classic bookkeeping) plus N ≥ 2 `journal_lines`, each carrying exactly
--  one signed amount. The invariant is not a convention, it is a database law:
--
--      Σ debits(line)  −  Σ credits(line)  ==  0        (per entry)
--      every amount_minor  !=  0
--      every positive amount_minor  ⇒  debit_minor  > 0   (and vice versa)
--      at least two lines, and at least one line on each side
--
--  Triggers in 005_triggers.sql enforce all four at COMMIT time, so an
--  unbalanced entry is physically un-writable — including from the sync
--  transport, a background isolate, or a future SQL console. "We forgot the
--  balance check on that code path" becomes impossible rather than unlikely.
--
--  Balance is derived, never stored twice:
--      an account's balance = signed Σ of its lines
--  and `account_balances` is declared a *rebuildable cache* (like an index).
--  It can be dropped at any moment and regenerated bit-exact by
--  ops/rebuild_caches.sql. That is what makes merging two offline devices safe:
--  lines merge by set-union (immutable ⇒ no conflict), caches are recomputed.
-- ═══════════════════════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

-- ───────────────────────────────────────────────────────────────────────────
--  journal_entries · replicated, APPEND-ONLY.
--
--  Immutability is the CRDT trick that pays for the whole design: because no
--  field of a posted entry ever changes, two devices that both recorded this
--  entry converge by plain set-union (idempotent, commutative, associative) —
--  no vector clocks, no arbitration, no "who wins" question to get wrong.
--  Corrections are NOT updates; they are new reversing entries
--  (reverses_entry_id), which is what an auditor expects to see anyway.
--
--  source  = which flow created it (sale, purchase, expense, payment, …)
--  status  = draft (mutable, excluded from reports) → posted (frozen)
--  lock    = a posted entry may be voided, never edited: voided_at + a
--            reversing entry. History is additive.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS journal_entries (
  id                 TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id          TEXT NOT NULL,
  entry_no           TEXT NOT NULL CHECK (length(entry_no) BETWEEN 1 AND 32),
  entry_date         INTEGER NOT NULL,          -- epoch-day (ledger-local calendar)
  posted_at          INTEGER,                   -- epoch-ms; NULL while draft
  source             INTEGER NOT NULL CHECK (source BETWEEN 1 AND 12),
                       -- 1 sale 2 purchase 3 expense 4 payment_in 5 payment_out
                       -- 6 journal 7 opening 8 stock_adjust 9 fx_reval
                       -- 10 tax_settle 11 depreciation 12 reversal
  status             INTEGER NOT NULL DEFAULT 0 CHECK (status IN (0,1,2)),
                       -- 0 draft 1 posted 2 voided
  memo               TEXT,
  memo_ur            TEXT,
  doc_no             TEXT,                      -- human reference (bill/invoice no.)
  party_id           TEXT,                      -- convenience FK; lines stay authoritative
  currency_code      TEXT NOT NULL,
  fx_rate_micros     INTEGER NOT NULL DEFAULT 1000000 CHECK (fx_rate_micros > 0),
  base_currency_code TEXT NOT NULL,
  total_debit_minor  INTEGER NOT NULL DEFAULT 0,   -- maintained by trigger, in currency
  total_credit_minor INTEGER NOT NULL DEFAULT 0,
  base_total_minor   INTEGER NOT NULL DEFAULT 0,   -- converted to ledger base currency
  reversal_of_entry_id TEXT,                       -- the entry this one reverses
  voided_at          INTEGER,                      -- stamped by the void transition
  attachment_count   INTEGER NOT NULL DEFAULT 0,
  reconciled_at      INTEGER,                      -- NULL ⇒ not yet bank-reconciled
  locked_by_date     INTEGER NOT NULL DEFAULT 0 CHECK (locked_by_date IN (0,1)),
  tag_json           TEXT,                         -- {"project":"Ravi Rd"} free tags
  device_id          TEXT NOT NULL CHECK (length(device_id) = 36),
  -- CRDT stamp. Journal rows are append-only, so why a rev at all? Because the
  -- *narration* fields (memo, tags, reconciliation flags) are last-writer-wins
  -- and every LWW field needs a monotonic stamp; and because the immutability
  -- trigger uses (hlc, rev) monotonicity to reject out-of-order writes from a
  -- buggy or hostile sync peer. Money is frozen; narration converges.
  hlc                TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id            TEXT NOT NULL CHECK (length(node_id) = 36),
  rev                INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  created_at         INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL,
  CHECK (total_debit_minor >= 0 AND total_credit_minor >= 0),
  CHECK (base_total_minor >= 0),
  CHECK (status <> 1 OR posted_at IS NOT NULL),          -- posting stamps time
  CHECK (status <> 2 OR posted_at IS NOT NULL),
  UNIQUE (ledger_id, id),
  UNIQUE (ledger_id, entry_no),
  FOREIGN KEY (ledger_id) REFERENCES ledgers(id) ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, reversal_of_entry_id) REFERENCES journal_entries(ledger_id, id)
) STRICT;

CREATE INDEX IF NOT EXISTS ix_je_ledger_date   ON journal_entries (ledger_id, entry_date DESC);
CREATE INDEX IF NOT EXISTS ix_je_party_date    ON journal_entries (ledger_id, party_id, entry_date DESC)
  WHERE party_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_je_doc_no        ON journal_entries (ledger_id, doc_no) WHERE doc_no IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_je_hlc           ON journal_entries (hlc);          -- CRDT delta cursor
CREATE INDEX IF NOT EXISTS ix_je_unreconciled  ON journal_entries (ledger_id, entry_date)
  WHERE reconciled_at IS NULL AND status = 1;

-- ───────────────────────────────────────────────────────────────────────────
--  journal_lines · replicated, APPEND-ONLY (the DR/CR rows themselves).
--
--  Signed convention (one column, one truth):
--      amount_minor > 0  ⇒  DEBIT     (uses debit_minor  as the amount)
--      amount_minor < 0  ⇒  CREDIT    (uses credit_minor as the amount)
--      debit_minor / credit_minor are GENERATED STORED unions of that single
--      signed value, so a "line that is both Dr and Cr" cannot exist.
--
--  Why epoch-day on the line too, when the entry already has entry_date?
--  Reports scan lines by date ("all sales in Ramzan", "postings to 1100 in
--  Q3") and would otherwise join 40 k entries for a trial balance. The value
--  is copied from the entry and re-verified by trigger INT-5, so it can never
--  drift while edit-style queries stay cheap.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS journal_lines (
  id                TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id         TEXT NOT NULL,
  entry_id          TEXT NOT NULL,
  line_no           INTEGER NOT NULL CHECK (line_no >= 1),
  entry_date        INTEGER NOT NULL,            -- denormalised from the entry
  account_id        TEXT NOT NULL,
  party_id          TEXT,
  amount_minor      INTEGER NOT NULL CHECK (amount_minor <> 0),
  debit_minor       INTEGER GENERATED ALWAYS AS (CASE WHEN amount_minor > 0 THEN amount_minor ELSE 0 END) STORED,
  credit_minor      INTEGER GENERATED ALWAYS AS (CASE WHEN amount_minor < 0 THEN -amount_minor ELSE 0 END) STORED,
  base_amount_minor INTEGER NOT NULL,            -- rounded amount × fx_rate_micros/1e6
  currency_code     TEXT NOT NULL,
  item_id           TEXT,
  quantity_milli    INTEGER NOT NULL DEFAULT 0,  -- + in / − out for stock moves
  unit_cost_micros  INTEGER NOT NULL DEFAULT 0,  -- frozen cost snapshot (headline margin math)
  tax_rate_id       TEXT,
  tax_minor         INTEGER NOT NULL DEFAULT 0,  -- informational; the tax posts as its own line
  tax_base_minor    INTEGER NOT NULL DEFAULT 0,
  memo              TEXT,
  is_opening        INTEGER NOT NULL DEFAULT 0 CHECK (is_opening IN (0,1)),
  reconciled_at     INTEGER,                     -- cleared in a bank reconciliation
  reconciliation_id TEXT,
  node_id           TEXT NOT NULL CHECK (length(node_id) = 36),
  created_at        INTEGER NOT NULL,
  -- NO hlc column here, deliberately. A journal line has no independent
  -- existence: it is meaningless unless it sums to zero with its siblings, so
  -- it always travels with its parent entry and inherits that entry's causal
  -- stamp. Omitting it saves 57 bytes on the largest table in the app plus a
  -- whole index over it (~9 % of the database, measured by tool/benchmark.py).
  CHECK (amount_minor = base_amount_minor OR (base_amount_minor <> 0)),
  CHECK (quantity_milli = 0 OR unit_cost_micros >= 0),
  -- Composite FK targets: a line can only ever reference an account of ITS OWN
  -- ledger, and an entry of its own ledger. Cross-ledger corruption (a classic
  -- hand-rolled-sync bug) is structurally unrepresentable.
  -- No UNIQUE(ledger_id, id) here: nothing references journal_lines, so that
  -- declaration would only buy a multi-megabyte index duplicating the PK. The
  -- rule applied across this schema: declare a composite unique key only where
  -- an actual FOREIGN KEY points at it.
  FOREIGN KEY (ledger_id, entry_id)   REFERENCES journal_entries(ledger_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, account_id) REFERENCES accounts(ledger_id, id)        ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, party_id)   REFERENCES parties(ledger_id, id)         ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, item_id)    REFERENCES items(ledger_id, id)           ON DELETE RESTRICT
) STRICT;

-- Hot paths, in order of how often they run. Every index below is load-bearing,
-- and none of them duplicates another's leading columns: on this table the
-- index footprint would otherwise be ~2.5x the size of the data itself, which
-- on a shop's phone is the difference between a 50 MB and an 80 MB book.
CREATE INDEX IF NOT EXISTS ix_je_source
  ON journal_entries (ledger_id, source) WHERE status = 1;
-- A line number is unique per entry: two devices must not be able to produce
-- two different "line 3" rows that then merge into a nonsense posting.
CREATE UNIQUE INDEX IF NOT EXISTS ux_jl_entry_line ON journal_lines (entry_id, line_no);
CREATE INDEX IF NOT EXISTS ix_jl_party_date   ON journal_lines (ledger_id, party_id, entry_date DESC)
  WHERE party_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_jl_item_date    ON journal_lines (ledger_id, item_id, entry_date DESC)
  WHERE item_id IS NOT NULL;
-- Covering index for the single hottest query in the app (dashboard + party
-- ledger + trial balance): amount is answered straight from the index leaf,
-- no table seek, no page decrypt beyond the index itself.
CREATE INDEX IF NOT EXISTS ix_jl_acct_date_amt
  ON journal_lines (ledger_id, account_id, entry_date, amount_minor, party_id);

-- ───────────────────────────────────────────────────────────────────────────
--  documents · replicated, editable-while-draft.
--  The business face of a journal entry (invoice, bill, quotation, receipt…).
--  1:1 with a posted entry via `entry_id`; drafts exist with entry_id NULL and
--  materialise their entry on post.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS documents (
  id                 TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id          TEXT NOT NULL,
  doc_kind           INTEGER NOT NULL CHECK (doc_kind BETWEEN 1 AND 10),
                       -- 1 sale_invoice 2 purchase_bill 3 credit_note(sales return)
                       -- 4 debit_note(purchase return) 5 quotation 6 estimate
                       -- 7 delivery_challan 8 payment_in 9 payment_out 10 expense
  doc_no             TEXT NOT NULL CHECK (length(doc_no) BETWEEN 1 AND 32),
  doc_date           INTEGER NOT NULL,               -- epoch-day
  due_date           INTEGER,
  party_id           TEXT NOT NULL,
  entry_id           TEXT,                           -- becomes non-NULL on post
  status             INTEGER NOT NULL DEFAULT 0 CHECK (status IN (0,1,2,3,4)),
                       -- 0 draft 1 posted 2 paid/closed 3 voided 4 accepted(quote→invoice)
  currency_code      TEXT NOT NULL,
  fx_rate_micros     INTEGER NOT NULL DEFAULT 1000000 CHECK (fx_rate_micros > 0),
  subtotal_minor     INTEGER NOT NULL DEFAULT 0 CHECK (subtotal_minor >= 0),
  discount_minor     INTEGER NOT NULL DEFAULT 0 CHECK (discount_minor >= 0),
  tax_minor          INTEGER NOT NULL DEFAULT 0 CHECK (tax_minor >= 0),
  shipping_minor     INTEGER NOT NULL DEFAULT 0 CHECK (shipping_minor >= 0),
  other_charges_minor INTEGER NOT NULL DEFAULT 0 CHECK (other_charges_minor >= 0),
  round_off_minor    INTEGER NOT NULL DEFAULT 0,     -- may be negative
  total_minor        INTEGER NOT NULL DEFAULT 0,
  amount_paid_minor  INTEGER NOT NULL DEFAULT 0 CHECK (amount_paid_minor >= 0),
  balance_minor      INTEGER NOT NULL DEFAULT 0,     -- cache; trigger-maintained
  tax_mode           INTEGER NOT NULL DEFAULT 0 CHECK (tax_mode IN (0,1)),  -- ex / incl
  place_of_supply    TEXT,
  is_interstate      INTEGER NOT NULL DEFAULT 0 CHECK (is_interstate IN (0,1)),
  terms              TEXT,
  notes              TEXT,
  e_invoice_ref      TEXT,                           -- FBR/IRIS reference when e-invoicing is on
  qr_payload         TEXT,                           -- signed payload for the printable QR
  signature_mac      TEXT,                           -- HMAC-SHA256 over the canonical total
  is_recurring_generated INTEGER NOT NULL DEFAULT 0 CHECK (is_recurring_generated IN (0,1)),
  hlc                TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id            TEXT NOT NULL CHECK (length(node_id) = 36),
  rev                INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at         INTEGER,
  created_at         INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL,
  CHECK (due_date IS NULL OR due_date >= doc_date),
  CHECK (round_off_minor BETWEEN -99 AND 99),
  UNIQUE (ledger_id, id),
  UNIQUE (ledger_id, doc_kind, doc_no),
  FOREIGN KEY (ledger_id) REFERENCES ledgers(id) ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, party_id) REFERENCES parties(ledger_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, entry_id) REFERENCES journal_entries(ledger_id, id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX IF NOT EXISTS ix_docs_kind_date  ON documents (ledger_id, doc_kind, doc_date DESC)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_docs_party_date ON documents (ledger_id, party_id, doc_date DESC)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_docs_outstanding
  ON documents (ledger_id, party_id, due_date)
  WHERE doc_kind IN (1,2,3,4) AND balance_minor <> 0 AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_docs_due_overdue
  ON documents (ledger_id, due_date) WHERE balance_minor > 0 AND status IN (0,1) AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_docs_hlc       ON documents (hlc);

-- ───────────────────────────────────────────────────────────────────────────
--  document_lines · replicated. Mirror of the journal's economic substance for
--  the printed document. Totals/quantities are cached on the header and
--  re-derived by trigger (DOC-4) — the header is what list screens read, so
--  the list never has to aggregate.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS document_lines (
  id               TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id        TEXT NOT NULL,
  document_id      TEXT NOT NULL,
  line_no          INTEGER NOT NULL CHECK (line_no >= 1),
  item_id          TEXT,
  description      TEXT NOT NULL DEFAULT '',
  quantity_milli   INTEGER NOT NULL DEFAULT 1000 CHECK (quantity_milli > 0),
  unit             TEXT NOT NULL DEFAULT 'pcs',
  unit_price_minor INTEGER NOT NULL CHECK (unit_price_minor >= 0),
  discount_bp      INTEGER NOT NULL DEFAULT 0 CHECK (discount_bp BETWEEN 0 AND 10000),
  discount_minor   INTEGER NOT NULL DEFAULT 0 CHECK (discount_minor >= 0),
  tax_rate_id      TEXT,
  tax_bp           INTEGER NOT NULL DEFAULT 0 CHECK (tax_bp BETWEEN 0 AND 10000),
  tax_minor        INTEGER NOT NULL DEFAULT 0 CHECK (tax_minor >= 0),
  line_total_minor INTEGER NOT NULL CHECK (line_total_minor >= 0),
  income_account_id TEXT,
  warehouse_id     TEXT,
  hlc              TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id          TEXT NOT NULL CHECK (length(node_id) = 36),
  rev              INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at       INTEGER,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  UNIQUE (document_id, line_no),
  FOREIGN KEY (ledger_id, document_id)  REFERENCES documents(ledger_id, id) ON DELETE CASCADE,
  FOREIGN KEY (ledger_id, item_id)      REFERENCES items(ledger_id, id)     ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, tax_rate_id)  REFERENCES tax_rates(ledger_id, id) ON DELETE SET NULL,
  FOREIGN KEY (ledger_id, income_account_id) REFERENCES accounts(ledger_id, id) ON DELETE SET NULL
) STRICT;

CREATE INDEX IF NOT EXISTS ix_dl_document ON document_lines (document_id, line_no);
CREATE INDEX IF NOT EXISTS ix_dl_item     ON document_lines (ledger_id, item_id) WHERE item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_dl_hlc      ON document_lines (hlc);

-- ───────────────────────────────────────────────────────────────────────────
--  payment_allocations · replicated, APPEND-ONLY.
--  Which payment closed which invoice, and by how much. Signed so a correction
--  is another row (a "-500" un-allocation) rather than an update — same
--  set-union merge story as the journal. Documents.balance_minor is the cache
--  kept honest by DOC-5.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS payment_allocations (
  id               TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id        TEXT NOT NULL,
  payment_entry_id TEXT NOT NULL,             -- the credit/debit entry of the payment
  document_id      TEXT NOT NULL,             -- invoice/bill being settled
  amount_minor     INTEGER NOT NULL CHECK (amount_minor <> 0),  -- + settles, − reverses
  allocated_date   INTEGER NOT NULL,          -- epoch-day
  note             TEXT,
  hlc              TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id          TEXT NOT NULL CHECK (length(node_id) = 36),
  created_at       INTEGER NOT NULL,
  UNIQUE (ledger_id, payment_entry_id, document_id),
  FOREIGN KEY (ledger_id, payment_entry_id) REFERENCES journal_entries(ledger_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, document_id)      REFERENCES documents(ledger_id, id)      ON DELETE RESTRICT
) STRICT;

CREATE INDEX IF NOT EXISTS ix_pa_document ON payment_allocations (ledger_id, document_id);
CREATE INDEX IF NOT EXISTS ix_pa_payment  ON payment_allocations (ledger_id, payment_entry_id);

-- ───────────────────────────────────────────────────────────────────────────
--  stock_moves · replicated, APPEND-ONLY. The item ledger (parallel to, and
--  never a substitute for, the money journal). Moving-average cost is derived
--  from these rows; on-hand quantity = Σ quantity_milli.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_moves (
  id               TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id        TEXT NOT NULL,
  item_id          TEXT NOT NULL,
  move_date        INTEGER NOT NULL,                    -- epoch-day
  direction        INTEGER NOT NULL CHECK (direction IN (1, -1)),  -- 1 in, −1 out
  quantity_milli   INTEGER NOT NULL CHECK (quantity_milli > 0),    -- always positive
  unit_cost_micros INTEGER NOT NULL DEFAULT 0 CHECK (unit_cost_micros >= 0),
  value_minor      INTEGER NOT NULL DEFAULT 0,          -- signed: ± qty × cost
  source           INTEGER NOT NULL CHECK (source BETWEEN 1 AND 8),
                     -- 1 sale 2 purchase 3 adjustment 4 opening 5 return_in
                     -- 6 return_out 7 damage 8 transfer
  entry_id         TEXT,                                -- money side, when applicable
  document_id      TEXT,
  warehouse_id     TEXT,
  batch_no         TEXT,
  expiry_date      INTEGER,
  note             TEXT,
  hlc              TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id          TEXT NOT NULL CHECK (length(node_id) = 36),
  created_at       INTEGER NOT NULL,
  CHECK (quantity_milli > 0),                 -- direction carries the sign
  CHECK (value_minor = 0 OR direction * value_minor >= 0),
  FOREIGN KEY (ledger_id, item_id)     REFERENCES items(ledger_id, id)    ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, entry_id)    REFERENCES journal_entries(ledger_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, document_id) REFERENCES documents(ledger_id, id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX IF NOT EXISTS ix_sm_item_date ON stock_moves (ledger_id, item_id, move_date DESC);
CREATE INDEX IF NOT EXISTS ix_sm_document  ON stock_moves (ledger_id, document_id) WHERE document_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_sm_expiry    ON stock_moves (ledger_id, expiry_date) WHERE expiry_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_sm_hlc       ON stock_moves (hlc);

-- ───────────────────────────────────────────────────────────────────────────
--  stock_on_hand · LOCAL-ONLY rebuildable cache (per item, per warehouse).
--  Kept current by triggers so the inventory list scrolls at 120 fps without a
--  15 000-row aggregate per frame — the single biggest frame-time win in the
--  inventory tab.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_on_hand (
  ledger_id      TEXT NOT NULL,
  item_id        TEXT NOT NULL,
  warehouse_id   TEXT NOT NULL DEFAULT '',
  quantity_milli INTEGER NOT NULL DEFAULT 0,
  value_minor    INTEGER NOT NULL DEFAULT 0,
  avg_cost_micros INTEGER NOT NULL DEFAULT 0,
  last_move_date INTEGER,
  updated_at     INTEGER NOT NULL,
  PRIMARY KEY (ledger_id, item_id, warehouse_id)
) STRICT, WITHOUT ROWID;

-- ───────────────────────────────────────────────────────────────────────────
--  attachments · replicated (metadata) / vault (bytes).
--  The AREA writes ciphertext into an app-private vault directory; only the
--  hash, MAC and relative path replicate. Photos of paper bills are the most
--  private thing in this app — they never enter a cloud drive unless the user
--  explicitly includes an "evidence" archive in a backup.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS attachments (
  id            TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id     TEXT NOT NULL,
  owner_type    TEXT NOT NULL CHECK (owner_type IN ('entry','document','party','item')),
  owner_id      TEXT NOT NULL,
  file_name     TEXT NOT NULL,
  mime_type     TEXT NOT NULL,
  byte_size     INTEGER NOT NULL CHECK (byte_size >= 0),
  sha256_hex    TEXT NOT NULL CHECK (length(sha256_hex) = 64),
  mac_hex       TEXT NOT NULL,               -- AES-GCM tag of the blob (integrity)
  rel_path      TEXT NOT NULL,               -- e.g. vault/ab/cd/<sha>.enc
  width_px      INTEGER,
  height_px     INTEGER,
  thumb_rel_path TEXT,
  ocr_text      TEXT,                        -- optional on-device OCR of a bill
  hlc           TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id       TEXT NOT NULL CHECK (length(node_id) = 36),
  rev           INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at    INTEGER,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  UNIQUE (ledger_id, id),
  UNIQUE (ledger_id, sha256_hex)
) STRICT;

CREATE INDEX IF NOT EXISTS ix_att_owner ON attachments (ledger_id, owner_type, owner_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_att_hlc   ON attachments (hlc);

-- ───────────────────────────────────────────────────────────────────────────
--  account_balances · LOCAL-ONLY DERIVED CACHE. Losing it is an inconvenience,
--  not a data loss: ops/rebuild_caches.sql regenerates it exactly.
--
--  period_id: 0 = ALL_TIME, 1 = DAY, 2 = MONTH, 3 = FY
--  period_start: epoch-day of the period's first day (0 for ALL_TIME)
--  net_minor is GENERATED = debit − credit, i.e. it is already sign-corrected
--  for the account's normal balance:
--      debit-normal account  → positive net = money owed TO the business
--      credit-normal account → negative net = money the business owes
--  Keeping one signed number means the UI never has two code paths and can
--  never show a payable as a receivable.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS account_balances (
  ledger_id      TEXT NOT NULL,
  account_id     TEXT NOT NULL,
  period_id      INTEGER NOT NULL CHECK (period_id BETWEEN 0 AND 3),
  period_start   INTEGER NOT NULL DEFAULT 0,
  currency_code  TEXT NOT NULL DEFAULT 'PKR',
  debit_minor    INTEGER NOT NULL DEFAULT 0 CHECK (debit_minor >= 0),
  credit_minor   INTEGER NOT NULL DEFAULT 0 CHECK (credit_minor >= 0),
  net_minor      INTEGER GENERATED ALWAYS AS (debit_minor - credit_minor) STORED,
  txn_count      INTEGER NOT NULL DEFAULT 0,
  last_entry_date INTEGER,
  checksum       TEXT,                        -- SHA-256 over the contributing ids
  updated_at     INTEGER NOT NULL,
  PRIMARY KEY (ledger_id, account_id, period_id, period_start)
) STRICT, WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS ix_ab_period ON account_balances (ledger_id, period_id, period_start, account_id);
-- The dashboard "top receivables" query walks this index only.
CREATE INDEX IF NOT EXISTS ix_ab_net    ON account_balances (ledger_id, period_id, net_minor DESC);

-- ───────────────────────────────────────────────────────────────────────────
--  balance_snapshots · replicated.
--  A signed, merkle-rooted roll-up of an account's balance as of a date. When
--  two devices pair after months offline they exchange snapshots first: if the
--  root matches, the whole history below that date is provably identical and
--  is never transferred. This is what keeps a LAN sync of a 40 k-entry book
--  at a few hundred kilobytes instead of tens of megabytes over Wi-Fi Direct.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS balance_snapshots (
  id             TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id      TEXT NOT NULL,
  account_id     TEXT NOT NULL,
  as_of_date     INTEGER NOT NULL,              -- epoch-day, inclusive
  debit_minor    INTEGER NOT NULL CHECK (debit_minor >= 0),
  credit_minor   INTEGER NOT NULL CHECK (credit_minor >= 0),
  entry_count    INTEGER NOT NULL CHECK (entry_count >= 0),
  op_count       INTEGER NOT NULL DEFAULT 0,    -- # ops folded into the root
  merkle_root    TEXT NOT NULL CHECK (length(merkle_root) = 64),
  hlc            TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id        TEXT NOT NULL CHECK (length(node_id) = 36),
  created_at     INTEGER NOT NULL,
  UNIQUE (ledger_id, account_id, as_of_date),
  FOREIGN KEY (ledger_id, account_id) REFERENCES accounts(ledger_id, id) ON DELETE CASCADE
) STRICT;

CREATE INDEX IF NOT EXISTS ix_snap_date ON balance_snapshots (ledger_id, as_of_date DESC);
CREATE INDEX IF NOT EXISTS ix_snap_hlc  ON balance_snapshots (hlc);

-- ───────────────────────────────────────────────────────────────────────────
--  recurring_rules · replicated. Template that materialises documents/entries
--  on a schedule (rent, salaries, monthly shopkeeper bill, Aasan installment).
--  `last_run_date`/`next_due_date` are computed per device from `doc_date`
--  guard columns so a device that was off for a week does not double-post:
--  the generated entry carries rule_id + period_key, and the UNIQUE index
--  ux_entry_rule_period makes double-posting impossible at the DB level.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS recurring_rules (
  id              TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id       TEXT NOT NULL,
  name            TEXT NOT NULL,
  doc_kind        INTEGER NOT NULL CHECK (doc_kind BETWEEN 1 AND 10),
  party_id        TEXT,
  amount_minor    INTEGER NOT NULL CHECK (amount_minor > 0),
  currency_code   TEXT NOT NULL,
  cadence         INTEGER NOT NULL CHECK (cadence IN (1,2,3,4)),
                    -- 1 daily 2 weekly 3 monthly 4 yearly
  interval_count  INTEGER NOT NULL DEFAULT 1 CHECK (interval_count BETWEEN 1 AND 60),
  day_of_month    INTEGER CHECK (day_of_month IS NULL OR day_of_month BETWEEN 1 AND 31),
  weekday         INTEGER CHECK (weekday IS NULL OR weekday BETWEEN 0 AND 6),
  start_date      INTEGER NOT NULL,             -- epoch-day
  end_date        INTEGER,
  next_due_date   INTEGER NOT NULL,
  last_run_date   INTEGER,
  auto_post       INTEGER NOT NULL DEFAULT 0 CHECK (auto_post IN (0,1)),
  template_json   TEXT NOT NULL,                -- draft document + line template
  is_active       INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
  hlc             TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id         TEXT NOT NULL CHECK (length(node_id) = 36),
  rev             INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at      INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  UNIQUE (ledger_id, id),
  FOREIGN KEY (ledger_id) REFERENCES ledgers(id) ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, party_id) REFERENCES parties(ledger_id, id) ON DELETE SET NULL
) STRICT;

CREATE INDEX IF NOT EXISTS ix_recurring_due
  ON recurring_rules (ledger_id, next_due_date) WHERE is_active = 1 AND deleted_at IS NULL;

-- Idempotency guard for scheduler races (two devices both waking at 03:00).
CREATE UNIQUE INDEX IF NOT EXISTS ux_entry_rule_period
  ON journal_entries (ledger_id, (json_extract(tag_json, '$.rule_id')),
                      (json_extract(tag_json, '$.period_key')))
  WHERE json_extract(tag_json, '$.rule_id') IS NOT NULL;

-- ───────────────────────────────────────────────────────────────────────────
--  reminders · replicated (state must agree across devices: dismissing a
--  reminder on the muneem's phone silences it on the owner's too).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS reminders (
  id            TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id     TEXT NOT NULL,
  party_id      TEXT,
  entry_id      TEXT,
  document_id   TEXT,
  kind          INTEGER NOT NULL CHECK (kind IN (1,2,3,4,5)),
                   -- 1 payment_due 2 statement 3 low_stock 4 reorder 5 daily_close
  title         TEXT NOT NULL,
  message       TEXT,
  scheduled_at  INTEGER NOT NULL,               -- epoch-ms UTC
  fired_at      INTEGER,
  dismissed_at  INTEGER,
  status        INTEGER NOT NULL DEFAULT 0 CHECK (status IN (0,1,2)),
                   -- 0 scheduled 1 fired 2 done
  payload_json  TEXT,
  hlc           TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id       TEXT NOT NULL CHECK (length(node_id) = 36),
  rev           INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at    INTEGER,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  UNIQUE (ledger_id, id),
  FOREIGN KEY (ledger_id) REFERENCES ledgers(id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX IF NOT EXISTS ix_reminders_due
  ON reminders (scheduled_at) WHERE status = 0 AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_reminders_party
  ON reminders (ledger_id, party_id, status) WHERE party_id IS NOT NULL AND deleted_at IS NULL;
