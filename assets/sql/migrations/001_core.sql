-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 001_core.sql
--  Identity, tenancy, chart of accounts, parties, items, tax, settings.
--  Engine target: SQLite 3.45+ (bundled by package:sqlite3 3.x) under SQLCipher 4
--
--  GLOBAL CONVENTIONS — every migration must obey these
--  ─────────────────────────────────────────────────────────────────────────
--   · ids            TEXT  UUIDv7, lowercase, 36 chars, time-ordered.
--                          Time-ordering keeps B-tree inserts append-mostly,
--                          which matters a lot when the *whole file* is
--                          AES-encrypted and every dirty page costs CPU.
--   · money          INTEGER minor units (paise). NEVER REAL/FLOAT. STRICT
--                          tables + CHECK(typeof(..)='integer') make floats
--                          a hard error instead of a rounding ghost.
--   · *_date         INTEGER epoch-day  = days since 1970-01-01 (LOCAL day)
--                          A sale at 23:00 Karachi belongs to that day, not
--                          to UTC's next day. So we store the *calendar day*
--                          the user chose, never a UTC instant.
--   · *_at / *_time  INTEGER epoch-millis UTC (instants: audit, HLC, sync)
--   · *_bp           INTEGER basis points   (18%  → 1800)
--   · *_milli        INTEGER thousandths    (2.5 kg → 2500)
--   · *_micros       INTEGER millionths     (1 USD = 278.45 PKR → 278450000)
--   · CRDT envelope  hlc TEXT(57) · node_id TEXT(36) · rev INTEGER
--                    created_at · updated_at · deleted_at
--                    hlc = 'PPPPPPPPPPPPPPP:CCCC:NNNNNNNN-NNNN-NNNN-NNNN-NNNNNNNNNNNN'
--                    (15-digit fixed-point ms, 4-hex counter, node uuid).
--                    Fixed width + zero padding ⇒ SQLite's default BINARY
--                    collation orders it exactly as causal time orders it.
--   · All tables     STRICT. No lurking TEXT '123' in an INTEGER column.
--   · Replication    Tables carrying the envelope replicate; tables marked
--                    LOCAL-ONLY never leave the device.
-- ═══════════════════════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

-- ───────────────────────────────────────────────────────────────────────────
--  schema_meta · LOCAL-ONLY. Migration bookkeeping (owned by migrate.dart).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schema_meta (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at INTEGER NOT NULL
) STRICT;

-- ───────────────────────────────────────────────────────────────────────────
--  session_flags · LOCAL-ONLY, volatile. Wreckage markers.
--  Set `dirty_open=1` on every open, cleared after a clean checkpoint. If the
--  app finds `dirty_open='1'` at boot, the previous run died mid-write: we run
--  quick_check + cache re-derivation (assets/sql/ops/rebuild_caches.sql).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS session_flags (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;

-- ───────────────────────────────────────────────────────────────────────────
--  node_identity (a.k.a. nodes) · replicated.
--  One row per *device* that has ever written to this ledger. `node_id` is
--  embedded in every HLC and is the final tie-breaker of the CRDT, so it must
--  be stable for the lifetime of the install and unique across reinstalls
--  (UUIDv7 is time-ordered ⇒ two devices can never collide, even offline).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS nodes (
  node_id       TEXT PRIMARY KEY CHECK (length(node_id) = 36 AND node_id = lower(node_id)),
  device_name   TEXT NOT NULL,
  platform      TEXT NOT NULL CHECK (platform IN ('android','ios','macos','windows','linux')),
  app_version   TEXT NOT NULL,
  public_key    TEXT,                                   -- Ed25519, for peer pinning
  is_this_device INTEGER NOT NULL DEFAULT 0 CHECK (is_this_device IN (0,1)),
  paired_at     INTEGER,
  last_seen_at  INTEGER,
  revoked_at    INTEGER,                                -- device removed by owner
  hlc           TEXT NOT NULL CHECK (length(hlc) = 57),
  rev           INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at    INTEGER,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS ux_nodes_self
  ON nodes (is_this_device) WHERE is_this_device = 1 AND deleted_at IS NULL;

-- ───────────────────────────────────────────────────────────────────────────
--  ledgers · replicated. Tenant boundary.
--  One install can hold several books (e.g. shop + workshop). Every financial
--  table carries a composite FK (ledger_id, id) so a line can never point at
--  an account of another ledger — referential integrity that survives sync
--  (rows may arrive from a peer in any order; see 005_triggers.sql INT-7).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ledgers (
  id                   TEXT PRIMARY KEY CHECK (length(id) = 36),
  name                 TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
  legal_name           TEXT,
  business_kind        TEXT NOT NULL DEFAULT 'generic',
  base_currency        TEXT NOT NULL DEFAULT 'PKR' REFERENCES currencies(code),
  country              TEXT NOT NULL DEFAULT 'PK',
  timezone             TEXT NOT NULL DEFAULT 'Asia/Karachi',
  fiscal_year_start_month INTEGER NOT NULL DEFAULT 7
                         CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
  currency_scale       INTEGER NOT NULL DEFAULT 2 CHECK (currency_scale BETWEEN 0 AND 4),
  quantity_scale       INTEGER NOT NULL DEFAULT 3 CHECK (quantity_scale BETWEEN 0 AND 6),
  rounding_mode        INTEGER NOT NULL DEFAULT 0 CHECK (rounding_mode IN (0,1)), -- 0 half-up, 1 bankers
  tax_display_mode     INTEGER NOT NULL DEFAULT 0 CHECK (tax_display_mode IN (0,1)), -- 0 exclusive, 1 inclusive
  lock_after_date      INTEGER,                     -- epoch-day; entries ≤ this are frozen
  is_active            INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
  hlc                  TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id              TEXT NOT NULL CHECK (length(node_id) = 36),
  rev                  INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at           INTEGER,
  created_at           INTEGER NOT NULL,
  updated_at           INTEGER NOT NULL,
  UNIQUE (id, base_currency)
) STRICT;

-- ───────────────────────────────────────────────────────────────────────────
--  currencies · seed rows + user extensions. `scale` = exponent of 10.
--  PKR/PKR_store as 2; JPY 0; KWD 3. Stored explicitly so a rounding rule is
--  never guessed from a locale string.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS currencies (
  code          TEXT PRIMARY KEY CHECK (length(code) = 3 AND code = upper(code)),
  name          TEXT NOT NULL,
  symbol        TEXT NOT NULL,
  scale         INTEGER NOT NULL CHECK (scale BETWEEN 0 AND 4),
  symbol_before INTEGER NOT NULL DEFAULT 1 CHECK (symbol_before IN (0,1)),
  is_seed       INTEGER NOT NULL DEFAULT 0 CHECK (is_seed IN (0,1)),
  hlc           TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id       TEXT NOT NULL CHECK (length(node_id) = 36),
  rev           INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at    INTEGER,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
) STRICT;

-- ───────────────────────────────────────────────────────────────────────────
--  fx_rates · replicated, APPEND-ONLY (the rate on the day of the entry is
--  history, it must not be editable — otherwise a re-print of last month's
--  invoice would silently change). One row per (base, quote, day, source).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fx_rates (
  id          TEXT PRIMARY KEY CHECK (length(id) = 36),
  base_code   TEXT NOT NULL REFERENCES currencies(code),
  quote_code  TEXT NOT NULL REFERENCES currencies(code),
  as_of_date  INTEGER NOT NULL,                       -- epoch-day
  rate_micros INTEGER NOT NULL CHECK (rate_micros > 0),
  source      INTEGER NOT NULL DEFAULT 0 CHECK (source IN (0,1,2)), -- 0 manual, 1 SBP, 2 peer
  hlc         TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id     TEXT NOT NULL CHECK (length(node_id) = 36),
  created_at  INTEGER NOT NULL,
  CHECK (base_code <> quote_code)
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS ux_fx_rate
  ON fx_rates (base_code, quote_code, as_of_date, source);

-- ───────────────────────────────────────────────────────────────────────────
--  accounts · replicated. THE chart of accounts.
--  A parent account carries `is_postable = 0`: journal lines may only touch
--  postable leaves, which keeps roll-ups from double counting.
--  `normal_balance`: 1 = debit-normal (assets, expenses), -1 = credit-normal.
--  `role` is the *stable machine handle* ("cash", "ar", "sales"…). Reports and
--  automations bind to the role, never to a user-editable name or code — the
--  user may rename "Cash in Hand" to "Galla" and nothing breaks.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS accounts (
  id               TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id        TEXT NOT NULL,
  parent_id        TEXT,
  code             TEXT NOT NULL CHECK (length(code) BETWEEN 1 AND 24),
  name             TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
  name_ur          TEXT,
  kind             INTEGER NOT NULL CHECK (kind BETWEEN 1 AND 6),
                     -- 1 asset 2 liability 3 equity 4 income 5 expense 6 other
  group_code       TEXT,        -- 'CURRENT_ASSETS', 'FIXED_ASSETS', 'OPERATING_EXPENSES'…
  role             TEXT,        -- stable handle; see ROLE_* constants in Dart
  normal_balance   INTEGER NOT NULL CHECK (normal_balance IN (1, -1)),
  is_contra        INTEGER NOT NULL DEFAULT 0 CHECK (is_contra IN (0,1)),
  is_postable      INTEGER NOT NULL DEFAULT 1 CHECK (is_postable IN (0,1)),
  is_system        INTEGER NOT NULL DEFAULT 0 CHECK (is_system IN (0,1)),
                     -- 1 ⇒ seeded/default account: may be renamed, never deleted
  is_cash          INTEGER NOT NULL DEFAULT 0 CHECK (is_cash IN (0,1)),
  is_bank          INTEGER NOT NULL DEFAULT 0 CHECK (is_bank IN (0,1)),
  party_id         TEXT,        -- sub-ledger account: "(AR) — Ahmed Traders"
  currency_code    TEXT NOT NULL,
  opening_balance_minor INTEGER NOT NULL DEFAULT 0,
  notes            TEXT,
  sort_order       INTEGER NOT NULL DEFAULT 0,
  hlc              TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id          TEXT NOT NULL CHECK (length(node_id) = 36),
  rev              INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at       INTEGER,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  CHECK (is_contra = 0 OR is_postable = 1),
  CHECK (parent_id IS NULL OR parent_id <> id),
  CHECK (normal_balance = 1 OR normal_balance = -1),
  -- Composite targets for the composite FKs used everywhere else in the schema.
  UNIQUE (ledger_id, id),
  UNIQUE (ledger_id, currency_code, id),
  FOREIGN KEY (ledger_id) REFERENCES ledgers(id) ON DELETE RESTRICT
) STRICT;

-- Codes are unique per ledger among live rows. Partial index ⇒ a deleted
-- account does not squat on its code forever (soft delete keeps history intact).
CREATE UNIQUE INDEX IF NOT EXISTS ux_accounts_code
  ON accounts (ledger_id, code) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_accounts_role
  ON accounts (ledger_id, role) WHERE role IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_accounts_ledger_kind
  ON accounts (ledger_id, kind, deleted_at);
CREATE INDEX IF NOT EXISTS ix_accounts_parent
  ON accounts (ledger_id, parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_accounts_party
  ON accounts (ledger_id, party_id) WHERE party_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_accounts_hlc ON accounts (hlc);   -- CRDT delta scan

-- ───────────────────────────────────────────────────────────────────────────
--  parties · replicated. Customers, suppliers, employees, "walk-in".
--  Balance is NEVER stored here: it is derived from the journal via
--  v_party_balances. A denormalised balance column is how accounting apps
--  drift out of truth (a rule we break deliberately for account_balances only,
--  where it is a pure, rebuildable cache — see ops/rebuild_caches.sql).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS parties (
  id                  TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id           TEXT NOT NULL,
  name                TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 160),
  name_ur             TEXT,
  kind                INTEGER NOT NULL DEFAULT 1 CHECK (kind BETWEEN 1 AND 4),
                        -- 1 customer 2 supplier 3 employee 4 other
  is_walk_in          INTEGER NOT NULL DEFAULT 0 CHECK (is_walk_in IN (0,1)),
  phone               TEXT,
  alt_phone           TEXT,
  email               TEXT,
  cnic                TEXT,          -- 13-digit CNIC, stored digits-only
  ntn                 TEXT,          -- FBR National Tax Number
  strn                TEXT,          -- Sales Tax Registration No.
  company             TEXT,
  address_line1       TEXT,
  address_line2       TEXT,
  city                TEXT,
  province            TEXT,
  postal_code         TEXT,
  country             TEXT NOT NULL DEFAULT 'PK',
  opening_balance_minor INTEGER NOT NULL DEFAULT 0,
  opening_balance_date  INTEGER,
  credit_limit_minor  INTEGER NOT NULL DEFAULT 0,
  payment_term_days   INTEGER NOT NULL DEFAULT 0 CHECK (payment_term_days BETWEEN 0 AND 365),
  remind_enabled      INTEGER NOT NULL DEFAULT 1 CHECK (remind_enabled IN (0,1)),
  remind_after_days   INTEGER NOT NULL DEFAULT 7 CHECK (remind_after_days BETWEEN 0 AND 365),
  notes               TEXT,
  photo_path          TEXT,          -- relative path inside the encrypted vault
  is_active           INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
  hlc                 TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id             TEXT NOT NULL CHECK (length(node_id) = 36),
  rev                 INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at          INTEGER,
  created_at          INTEGER NOT NULL,
  updated_at          INTEGER NOT NULL,
  UNIQUE (ledger_id, id),
  FOREIGN KEY (ledger_id) REFERENCES ledgers(id) ON DELETE RESTRICT,
  -- CNIC: hard format guarantee in pure SQL (13 digits, digits only) so the
  -- migrations run in ANY SQLite tool with no custom functions registered.
  -- The NADRA checksum is verified in the app as a *soft* warning, because the
  -- authoritative rule is a lookup, not arithmetic we can prove offline.
  CHECK (cnic IS NULL OR (length(cnic) = 13 AND cnic NOT GLOB '*[^0-9]*'))
) STRICT;

CREATE INDEX IF NOT EXISTS ix_parties_ledger_name  ON parties (ledger_id, name)  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_parties_ledger_phone ON parties (ledger_id, phone) WHERE phone IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_parties_ledger_active ON parties (ledger_id, is_active, kind) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_parties_hlc ON parties (hlc);

-- Multi-contact rows: a party often has the owner's Mobi, the muneem's phone…
CREATE TABLE IF NOT EXISTS party_contacts (
  id          TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id   TEXT NOT NULL,
  party_id    TEXT NOT NULL,
  name        TEXT NOT NULL,
  phone       TEXT,
  relation    TEXT,
  is_primary  INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0,1)),
  hlc         TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id     TEXT NOT NULL CHECK (length(node_id) = 36),
  rev         INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at  INTEGER,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  FOREIGN KEY (ledger_id, party_id) REFERENCES parties(ledger_id, id) ON DELETE CASCADE
) STRICT;

CREATE INDEX IF NOT EXISTS ix_party_contacts_party
  ON party_contacts (ledger_id, party_id) WHERE deleted_at IS NULL;

-- ───────────────────────────────────────────────────────────────────────────
--  items · replicated. Products and services with a moving-average cost.
--  `average_cost_micros` is a CACHE (rebuildable from stock_moves) — never a
--  source of truth, exactly like account_balances.
--  Sell/buy prices are stored WITH and WITHOUT tax so a rate change cannot
--  retroactively rewrite a historical margin.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS items (
  id                    TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id             TEXT NOT NULL,
  sku                   TEXT,
  barcode               TEXT,
  name                  TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 160),
  name_ur               TEXT,
  description           TEXT,
  kind                  INTEGER NOT NULL DEFAULT 1 CHECK (kind IN (0,1,2)),
                          -- 0 product 1 service 2 bundle
  unit                  TEXT NOT NULL DEFAULT 'pcs',
  is_stocked            INTEGER NOT NULL DEFAULT 1 CHECK (is_stocked IN (0,1)),
  track_batches         INTEGER NOT NULL DEFAULT 0 CHECK (track_batches IN (0,1)),
  has_expiry            INTEGER NOT NULL DEFAULT 0 CHECK (has_expiry IN (0,1)),
  sale_price_minor      INTEGER NOT NULL DEFAULT 0 CHECK (sale_price_minor >= 0),
  sale_price_incl_minor INTEGER NOT NULL DEFAULT 0 CHECK (sale_price_incl_minor >= 0),
  purchase_price_minor  INTEGER NOT NULL DEFAULT 0 CHECK (purchase_price_minor >= 0),
  tax_rate_id           TEXT,
  tax_inclusive         INTEGER NOT NULL DEFAULT 0 CHECK (tax_inclusive IN (0,1)),
  reorder_level_milli   INTEGER NOT NULL DEFAULT 0 CHECK (reorder_level_milli >= 0),
  average_cost_micros   INTEGER NOT NULL DEFAULT 0,
  inventory_account_id  TEXT,
  cogs_account_id       TEXT,
  income_account_id     TEXT,
  image_path            TEXT,
  is_active             INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
  hlc                   TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id               TEXT NOT NULL CHECK (length(node_id) = 36),
  rev                   INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at            INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  UNIQUE (ledger_id, id),
  FOREIGN KEY (ledger_id) REFERENCES ledgers(id) ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, inventory_account_id) REFERENCES accounts(ledger_id, id) ON DELETE SET NULL,
  FOREIGN KEY (ledger_id, cogs_account_id)      REFERENCES accounts(ledger_id, id) ON DELETE SET NULL,
  FOREIGN KEY (ledger_id, income_account_id)    REFERENCES accounts(ledger_id, id) ON DELETE SET NULL
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS ux_items_sku
  ON items (ledger_id, sku) WHERE sku IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_items_barcode
  ON items (ledger_id, barcode) WHERE barcode IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_items_name_ledger ON items (ledger_id, name) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_items_low_stock
  ON items (ledger_id, is_active) WHERE is_stocked = 1 AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_items_hlc ON items (hlc);

-- ───────────────────────────────────────────────────────────────────────────
--  tax_rates · replicated. Rates are basis points; the *account* they post to
--  is data, not code, so a Pakistani shop can point GST at 2300 and a future
--  jurisdiction can add its own without touching a line of Dart.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tax_rates (
  id             TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id      TEXT NOT NULL,
  name           TEXT NOT NULL,
  kind           INTEGER NOT NULL DEFAULT 1 CHECK (kind IN (1,2,3,4)),
                   -- 1 sales_tax 2 withholding 3 income_tax 4 custom
  rate_bp        INTEGER NOT NULL CHECK (rate_bp BETWEEN 0 AND 10000),
  is_compound    INTEGER NOT NULL DEFAULT 0 CHECK (is_compound IN (0,1)),
  account_id     TEXT,
  is_default     INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)),
  effective_from INTEGER,                              -- epoch-day
  effective_to   INTEGER,
  is_active      INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
  hlc            TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id        TEXT NOT NULL CHECK (length(node_id) = 36),
  rev            INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at     INTEGER,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  UNIQUE (ledger_id, id),
  FOREIGN KEY (ledger_id) REFERENCES ledgers(id) ON DELETE RESTRICT,
  FOREIGN KEY (ledger_id, account_id) REFERENCES accounts(ledger_id, id) ON DELETE SET NULL,
  CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from)
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS ux_tax_default_sales
  ON tax_rates (ledger_id, kind) WHERE is_default = 1 AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_tax_rates_ledger ON tax_rates (ledger_id, kind) WHERE deleted_at IS NULL;

-- ───────────────────────────────────────────────────────────────────────────
--  app_settings · replicated (per-ledger preferences) + LOCAL-ONLY rows via
--  scope = 'device'. Key/value so a new preference ships without a migration.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS app_settings (
  id         TEXT PRIMARY KEY CHECK (length(id) = 36),
  ledger_id  TEXT,                       -- NULL ⇒ global / applies to all books
  scope      TEXT NOT NULL DEFAULT 'ledger' CHECK (scope IN ('ledger','device')),
  key        TEXT NOT NULL CHECK (length(key) BETWEEN 1 AND 80),
  value      TEXT NOT NULL,              -- JSON scalar (bool/int/string)
  hlc        TEXT NOT NULL CHECK (length(hlc) = 57),
  node_id    TEXT NOT NULL CHECK (length(node_id) = 36),
  rev        INTEGER NOT NULL DEFAULT 1 CHECK (rev >= 1),
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (ledger_id, scope, key)
) STRICT;

CREATE INDEX IF NOT EXISTS ix_app_settings_scope ON app_settings (scope, key);
CREATE INDEX IF NOT EXISTS ix_app_settings_hlc   ON app_settings (hlc);

-- ───────────────────────────────────────────────────────────────────────────
--  number_sequences · LOCAL-ONLY. Document numbering per (ledger, kind, node).
--  Each device owns its own counter range so two offline phones can both cut
--  "INV-0007" without colliding: numbering is an identity concern and CRDTs
--  must never arbitrate it. The printed number carries a node suffix when the
--  ledger is synced across devices (see docs/DB_SCHEMA.md §numbering).
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS number_sequences (
  ledger_id  TEXT NOT NULL,
  doc_kind   INTEGER NOT NULL,         -- matches documents.doc_kind
  node_id    TEXT NOT NULL,
  prefix     TEXT NOT NULL DEFAULT '',
  padding    INTEGER NOT NULL DEFAULT 4 CHECK (padding BETWEEN 1 AND 10),
  next_value INTEGER NOT NULL DEFAULT 1 CHECK (next_value >= 1),
  step       INTEGER NOT NULL DEFAULT 1 CHECK (step >= 1),
  PRIMARY KEY (ledger_id, doc_kind, node_id)
) STRICT, WITHOUT ROWID;

-- ───────────────────────────────────────────────────────────────────────────
--  device_profile · LOCAL-ONLY. Non-sensitive UI/preferences cache so the
--  very first frame after unlock needs no joins.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS device_profile (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at INTEGER NOT NULL
) STRICT;

INSERT OR REPLACE INTO schema_meta (key, value, updated_at) VALUES
  ('schema_version', '1', CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  ('money_encoding', 'integer_minor_units', CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  ('date_encoding',  'integer_epoch_day_local', CAST(unixepoch('subsec') * 1000 AS INTEGER));
