-- ═══════════════════════════════════════════════════════════════════════════
--  KhataPro · 005_triggers.sql
--  THE GUARDS. This file is what makes "strict double-entry" a property of the
--  database rather than a promise in a Dart file.
--
--  ── Why not a deferred CHECK? ────────────────────────────────────────────
--  SQLite has no deferred triggers (verified: `DEFERRABLE INITIALLY DEFERRED`
--  is a syntax error) and a plain CHECK cannot aggregate across rows. So a
--  balance cannot be asserted by a constraint expression. The design below is
--  the strongest thing SQLite can actually do, and it is airtight in practice:
--
--   (a) AN ENTRY CAN ONLY BECOME POSTED IN TWO WAYS
--         · the guarded transition  UPDATE … SET status = 1 WHERE id = ?
--           AND khata_entry_is_balanced(id)      ← 0 rows = unbalanced = rejected
--           (an immediate BEFORE-UPDATE trigger re-asserts it in SQL, so even a
--            hand-written UPDATE from a SQL console is refused)
--         · a sync-apply transaction (write_mode = 'sync') that MUST end with
--           the integrity gate below, or the whole batch is rolled back.
--       There is no third door. Direct INSERT of an already-posted entry is
--       refused outside sync mode.
--
--   (b) THE INTEGRITY GATE (invariant_violations)
--       `invariant_violations` carries an AFTER INSERT trigger that aborts with
--       RAISE(FAIL) — so *any* row landing in it means "this transaction is
--       broken". ops/integrity_checks.sql turns each invariant into an
--       `INSERT … SELECT`. Running the gate costs one indexed scan per check
--       and needs no Dart logic, so it can be run from a SQL console, from a
--       test, or from the sync transport. RAISE(FAIL) aborts the statement but
--       not the transaction, which is exactly right: the caller (or the
--       transport) rolls back and surfaces a precise error.
--
--   (c) WHAT IS FROZEN vs WHAT IS LWW
--       Financial fields of a posted entry (ledger, number, date, source,
--       currency, fx rate, party, document number, amounts, totals) are
--       absolutely immutable — corrections are new reversing entries.
--       Narration fields (memo, tags, reconciliation flags, attachments count)
--       are last-writer-wins and bump (hlc, rev) monotonically. That split is
--       enforced column-by-column in trg_je_immutable below, and it is what
--       keeps the append-only CRDT merge (set union) sound where it matters.
-- ═══════════════════════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;

-- ───────────────────────────────────────────────────────────────────────────
--  v_session · the one place triggers look for "what kind of writer am I?".
--  session_flags rows are (re)written by the app at every database open and
--  whenever the transport enters an apply phase.
--      write_mode : 'user'  → normal UI writes (default; safest)
--                   'sync'  → replicating historical rows from a peer/backup
--                   'purge' → the user's explicit erase-everything flow
-- ───────────────────────────────────────────────────────────────────────────
CREATE VIEW IF NOT EXISTS v_session AS
SELECT COALESCE((SELECT value FROM session_flags WHERE key = 'session_id'),  'unset')  AS session_id,
       COALESCE((SELECT value FROM session_flags WHERE key = 'write_mode'),  'user')   AS write_mode,
       CAST(COALESCE((SELECT value FROM session_flags WHERE key = 'today_epoch_day'), 0) AS INTEGER) AS today_epoch_day;

-- ───────────────────────────────────────────────────────────────────────────
--  invariant_violations — the abort gate. Empty in a healthy database.
--  Its AFTER INSERT trigger is the single most important line in this file:
--  it converts "an invariant query found something" into "your transaction is
--  aborted with an error", using nothing but SQL.
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS invariant_violations (
  kind        TEXT NOT NULL,
  detail      TEXT NOT NULL,
  detected_at INTEGER NOT NULL
) STRICT;

CREATE TRIGGER IF NOT EXISTS trg_gate_abort
AFTER INSERT ON invariant_violations
BEGIN
  SELECT RAISE(FAIL, 'KhataPro INTEGRITY GATE: a data-integrity invariant was violated — transaction aborted. Run assets/sql/ops/integrity_checks.sql for the details.');
END;

-- ═══════════════════════════════════════════════════════════════════════════
--  A · JOURNAL LINES — structural rules (immediate, cheap, no aggregation)
-- ═══════════════════════════════════════════════════════════════════════════

-- INT-1 · a line may join a draft (the normal flow), or a posted entry only
--         while the transport is applying replicated history. This closes the
--         "silently edit a posted entry by adding a line" back door.
--
--         FIRST BRANCH — the idempotent-replay escape hatch: if a row with this
--         exact id already exists, the writer is replaying history we already
--         have (set-union merge). The INSERT OR IGNORE that follows will drop
--         it, so the checks must not run: a peer re-syncing a line whose
--         account was deleted afterwards, or whose entry has since been voided,
--         is a *correct* no-op, not a violation.
CREATE TRIGGER IF NOT EXISTS trg_jl_insert_guard
BEFORE INSERT ON journal_lines
FOR EACH ROW
BEGIN
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM journal_lines WHERE id = NEW.id)
      THEN NULL
    WHEN (SELECT status FROM journal_entries WHERE id = NEW.entry_id) IS NULL
      THEN RAISE(ABORT, 'INT-1: journal_line references a non-existent entry')
    WHEN (SELECT status FROM journal_entries WHERE id = NEW.entry_id) = 1
     AND (SELECT write_mode FROM v_session) <> 'sync'
      THEN RAISE(ABORT, 'INT-1: cannot add a line to a POSTED entry — post the correction as a reversing entry')
    WHEN (SELECT status FROM journal_entries WHERE id = NEW.entry_id) = 2
      THEN RAISE(ABORT, 'INT-1b: cannot add a line to a VOIDED entry')
  END;
END;

-- INT-2 · a line must agree with its entry on ledger, date and currency, and
--         the account must be a live postable leaf of the SAME ledger.
--         (Ledger agreement is also a composite FK; belt and braces, because
--         the FK is skipped when someone restores with foreign_keys=OFF.)
CREATE TRIGGER IF NOT EXISTS trg_jl_consistency
BEFORE INSERT ON journal_lines
FOR EACH ROW
BEGIN
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM journal_lines WHERE id = NEW.id)
      THEN NULL                                     -- replay of a known row
    WHEN NEW.ledger_id <> (SELECT ledger_id FROM journal_entries WHERE id = NEW.entry_id)
      THEN RAISE(ABORT, 'INT-2: line ledger does not match its journal entry')
    WHEN NEW.entry_date <> (SELECT entry_date FROM journal_entries WHERE id = NEW.entry_id)
      THEN RAISE(ABORT, 'INT-2b: line entry_date must equal the entry date (reporting scans lines by date)')
    WHEN NEW.currency_code <> (SELECT currency_code FROM journal_entries WHERE id = NEW.entry_id)
      THEN RAISE(ABORT, 'INT-2c: line currency must equal the entry currency')
    WHEN COALESCE((SELECT is_postable FROM accounts WHERE id = NEW.account_id), 0) = 0
      THEN RAISE(ABORT, 'INT-2d: lines may only post to postable accounts (not a parent/header account)')
    WHEN (SELECT deleted_at FROM accounts WHERE id = NEW.account_id) IS NOT NULL
      THEN RAISE(ABORT, 'INT-2e: account is deleted — it may keep its history but cannot receive new postings')
  END;
END;

CREATE TRIGGER IF NOT EXISTS trg_jl_consistency_upd
BEFORE UPDATE ON journal_lines
FOR EACH ROW
BEGIN
  SELECT CASE
    WHEN NEW.ledger_id <> OLD.ledger_id OR NEW.entry_id <> OLD.entry_id
      THEN RAISE(ABORT, 'INT-2f: a line cannot be moved to another entry or ledger')
    WHEN (SELECT status FROM journal_entries WHERE id = OLD.entry_id) = 1
     AND (SELECT write_mode FROM v_session) <> 'sync'
     AND (NEW.amount_minor     <> OLD.amount_minor
       OR NEW.account_id       <> OLD.account_id
       OR NEW.entry_date       <> OLD.entry_date
       OR NEW.currency_code    <> OLD.currency_code
       OR COALESCE(NEW.party_id, '') <> COALESCE(OLD.party_id, '')
       OR COALESCE(NEW.item_id,  '') <> COALESCE(OLD.item_id,  '')
       OR NEW.quantity_milli   <> OLD.quantity_milli)
      THEN RAISE(ABORT, 'INT-2g: posted lines are immutable — post a reversing entry instead')
  END;
END;

-- INT-3 · append-only for POSTED data; drafts remain freely editable (a user
--         must be able to fix a half-typed invoice). `purge` is reserved for
--         the explicit erase-everything flow.
CREATE TRIGGER IF NOT EXISTS trg_jl_no_delete
BEFORE DELETE ON journal_lines
FOR EACH ROW
WHEN (SELECT write_mode FROM v_session) <> 'purge'
 AND COALESCE((SELECT status FROM journal_entries WHERE id = OLD.entry_id), 0) <> 0
BEGIN
  SELECT RAISE(ABORT, 'INT-3: lines of a posted entry are append-only — void the entry instead');
END;

CREATE TRIGGER IF NOT EXISTS trg_je_no_delete
BEFORE DELETE ON journal_entries
FOR EACH ROW
WHEN (SELECT write_mode FROM v_session) <> 'purge'
 AND OLD.status <> 0
BEGIN
  SELECT RAISE(ABORT, 'INT-3b: posted entries are append-only — use void (status=2). Drafts may be discarded.');
END;

-- INT-4 · entry-level totals are maintained here, so no Dart code path can
--         ever publish a wrong "Total: Rs 12,500" on a draft.
CREATE TRIGGER IF NOT EXISTS trg_jl_totals_ins
AFTER INSERT ON journal_lines
FOR EACH ROW
BEGIN
  UPDATE journal_entries
     SET total_debit_minor  = total_debit_minor  + NEW.debit_minor,
         total_credit_minor = total_credit_minor + NEW.credit_minor,
         base_total_minor   = base_total_minor   + ABS(NEW.base_amount_minor),
         updated_at         = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE id = NEW.entry_id;
END;

CREATE TRIGGER IF NOT EXISTS trg_jl_totals_del
AFTER DELETE ON journal_lines
FOR EACH ROW
BEGIN
  UPDATE journal_entries
     SET total_debit_minor  = total_debit_minor  - OLD.debit_minor,
         total_credit_minor = total_credit_minor - OLD.credit_minor,
         base_total_minor   = base_total_minor   - ABS(OLD.base_amount_minor),
         updated_at         = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE id = OLD.entry_id;
END;

-- ═══════════════════════════════════════════════════════════════════════════
--  B · JOURNAL ENTRIES — the balance gate and immutability
-- ═══════════════════════════════════════════════════════════════════════════

-- INT-5 · THE DOUBLE-ENTRY LAW. Σ debit − Σ credit must be exactly 0, with at
--         least two lines and at least one line on each side. This runs on the
--         draft → posted transition and it is the reason an unbalanced entry
--         cannot exist in a posted state, from any code path.
CREATE TRIGGER IF NOT EXISTS trg_je_balance_gate
BEFORE UPDATE OF status ON journal_entries
FOR EACH ROW
WHEN NEW.status = 1 AND OLD.status <> 1
BEGIN
  SELECT CASE
    WHEN (SELECT COUNT(*) FROM journal_lines WHERE entry_id = NEW.id) < 2
      THEN RAISE(ABORT, 'INT-5: a journal entry needs at least two lines (a debit and a credit)')
    WHEN (SELECT COALESCE(SUM(amount_minor), 0) FROM journal_lines WHERE entry_id = NEW.id) <> 0
      THEN RAISE(ABORT, 'INT-5b: journal entry is NOT balanced — sum(debits) − sum(credits) must equal 0')
    WHEN NOT EXISTS (SELECT 1 FROM journal_lines WHERE entry_id = NEW.id AND amount_minor > 0)
      THEN RAISE(ABORT, 'INT-5c: unbalanced entry — there is no debit line (every entry needs Dr and Cr)')
    WHEN NOT EXISTS (SELECT 1 FROM journal_lines WHERE entry_id = NEW.id AND amount_minor < 0)
      THEN RAISE(ABORT, 'INT-5d: unbalanced entry — there is no credit line (every entry needs Dr and Cr)')
    WHEN NEW.total_debit_minor <> NEW.total_credit_minor
      THEN RAISE(ABORT, 'INT-5e: entry totals disagree (corrupt total cache; re-save the draft)')
  END;
END;

-- INT-6 · posting straight out of thin air. Outside sync mode an entry must be
--         born as a draft, so the balance gate above is always the gate that
--         gets walked through.
CREATE TRIGGER IF NOT EXISTS trg_je_insert_posted_guard
BEFORE INSERT ON journal_entries
FOR EACH ROW
WHEN NEW.status = 1 AND (SELECT write_mode FROM v_session) <> 'sync'
BEGIN
  SELECT RAISE(ABORT, 'INT-6: create the entry as a draft, then post it through the guarded transition');
END;

-- INT-7 · immutability of posted financial content + monotonic CRDT stamps.
CREATE TRIGGER IF NOT EXISTS trg_je_immutable
BEFORE UPDATE ON journal_entries
FOR EACH ROW
WHEN OLD.status >= 1
BEGIN
  SELECT CASE
    -- ── frozen financial identity ────────────────────────────────────────
    WHEN NEW.ledger_id      <> OLD.ledger_id
      OR NEW.entry_no       <> OLD.entry_no
      OR NEW.entry_date     <> OLD.entry_date
      OR NEW.source         <> OLD.source
      OR NEW.currency_code  <> OLD.currency_code
      OR NEW.fx_rate_micros <> OLD.fx_rate_micros
      OR COALESCE(NEW.party_id, '') <> COALESCE(OLD.party_id, '')
      OR COALESCE(NEW.doc_no, '')   <> COALESCE(OLD.doc_no, '')
      OR COALESCE(NEW.posted_at, -1) <> COALESCE(OLD.posted_at, -1)
      OR NEW.device_id      <> OLD.device_id
      OR NEW.created_at     <> OLD.created_at
      THEN RAISE(ABORT, 'INT-7: posted entries are immutable in their financial content — post a reversing entry instead')
    -- ── the totals cache may only be re-derived by the sync applier ──────
    WHEN (NEW.total_debit_minor <> OLD.total_debit_minor
       OR NEW.total_credit_minor <> OLD.total_credit_minor
       OR NEW.base_total_minor  <> OLD.base_total_minor)
     AND (SELECT write_mode FROM v_session) <> 'sync'
      THEN RAISE(ABORT, 'INT-7b: entry totals are derived from lines and cannot be edited directly')
    -- ── lifecycle: draft → posted → voided, never backwards ──────────────
    WHEN NEW.status < OLD.status
      THEN RAISE(ABORT, 'INT-7c: an entry cannot move backwards through its lifecycle')
    WHEN NEW.status = 2 AND NEW.voided_at IS NULL
      THEN RAISE(ABORT, 'INT-7d: voiding must stamp voided_at')
    -- ── CRDT: never let an older version overwrite a newer one ───────────
    WHEN NEW.rev < OLD.rev OR NEW.hlc < OLD.hlc
      THEN RAISE(ABORT, 'INT-7e: stale write rejected by the CRDT guard (out-of-order HLC/rev)')
  END;
END;

-- ═══════════════════════════════════════════════════════════════════════════
--  C · THE BALANCE CACHE — O(1) incremental maintenance + O(1) audit
--
--  Two records move together on every posting:
--    · account_balances  → the fast read path used by the dashboard/lists
--    · balance_audit     → "what the cache was before this transaction, and
--                           what this transaction claims to have added to it"
--  Then ops/integrity_checks.sql can prove, in O(1) per touched account, that
--  cache == before + delta. Any divergence aborts the transaction through the
--  gate in §0 — so a wrong balance on the home screen is caught at the moment
--  it is created, not three weeks later by a confused shopkeeper.
--
--  Absolute verification (cache vs. Σ of all lines) is a nightly/on-demand
--  scan — see ops/integrity_checks.sql, block [CACHE-FULL].
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS balance_audit (
  account_id      TEXT PRIMARY KEY,
  session_id      TEXT NOT NULL,
  before_debit    INTEGER NOT NULL,
  before_credit   INTEGER NOT NULL,
  delta_debit     INTEGER NOT NULL DEFAULT 0,
  delta_credit    INTEGER NOT NULL DEFAULT 0,
  delta_txns      INTEGER NOT NULL DEFAULT 0,
  touched_at      INTEGER NOT NULL
) STRICT;

-- A line that lands directly on a posted entry (sync mode) must be counted.
CREATE TRIGGER IF NOT EXISTS trg_bal_accrue
AFTER INSERT ON journal_lines
FOR EACH ROW
WHEN (SELECT status FROM journal_entries WHERE id = NEW.entry_id) = 1
BEGIN
  -- (1) capture "before" from the cache exactly once per account per session
  INSERT INTO balance_audit
    (account_id, session_id, before_debit, before_credit, delta_debit, delta_credit, delta_txns, touched_at)
  SELECT NEW.account_id,
         (SELECT session_id FROM v_session),
         COALESCE((SELECT debit_minor  FROM account_balances
                    WHERE account_id = NEW.account_id AND period_id = 0 AND period_start = 0), 0),
         COALESCE((SELECT credit_minor FROM account_balances
                    WHERE account_id = NEW.account_id AND period_id = 0 AND period_start = 0), 0),
         NEW.debit_minor, NEW.credit_minor, 1,
         CAST(unixepoch('subsec') * 1000 AS INTEGER)
  WHERE true
  ON CONFLICT(account_id) DO UPDATE
    SET delta_debit  = delta_debit  + excluded.delta_debit,
        delta_credit = delta_credit + excluded.delta_credit,
        delta_txns   = delta_txns   + excluded.delta_txns;

  -- (2) apply to the cache
  INSERT INTO account_balances
    (ledger_id, account_id, period_id, period_start, currency_code,
     debit_minor, credit_minor, txn_count, last_entry_date, updated_at)
  SELECT NEW.ledger_id, NEW.account_id, 0, 0,
         (SELECT currency_code FROM journal_entries WHERE id = NEW.entry_id),
         NEW.debit_minor, NEW.credit_minor, 1, NEW.entry_date,
         CAST(unixepoch('subsec') * 1000 AS INTEGER)
  WHERE true
  ON CONFLICT(ledger_id, account_id, period_id, period_start) DO UPDATE
    SET debit_minor  = debit_minor  + excluded.debit_minor,
        credit_minor = credit_minor + excluded.credit_minor,
        txn_count    = txn_count    + 1,
        last_entry_date = MAX(COALESCE(last_entry_date, 0), excluded.last_entry_date),
        updated_at   = excluded.updated_at;
END;

-- Posting a draft moves its whole line set into the cache in one shot.
CREATE TRIGGER IF NOT EXISTS trg_bal_post
AFTER UPDATE OF status ON journal_entries
FOR EACH ROW
WHEN NEW.status = 1 AND OLD.status = 0
BEGIN
  INSERT INTO balance_audit
    (account_id, session_id, before_debit, before_credit, delta_debit, delta_credit, delta_txns, touched_at)
  SELECT g.account_id,
         (SELECT session_id FROM v_session),
         COALESCE(ab.debit_minor, 0), COALESCE(ab.credit_minor, 0),
         g.d, g.c, g.n,
         CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM (SELECT account_id,
               SUM(debit_minor)  AS d,
               SUM(credit_minor) AS c,
               COUNT(*)          AS n
          FROM journal_lines WHERE entry_id = NEW.id GROUP BY account_id) g
  LEFT JOIN account_balances ab
         ON ab.account_id = g.account_id AND ab.period_id = 0 AND ab.period_start = 0
  WHERE true
  ON CONFLICT(account_id) DO UPDATE
    SET delta_debit  = delta_debit  + excluded.delta_debit,
        delta_credit = delta_credit + excluded.delta_credit,
        delta_txns   = delta_txns   + excluded.delta_txns;

  INSERT INTO account_balances
    (ledger_id, account_id, period_id, period_start, currency_code,
     debit_minor, credit_minor, txn_count, last_entry_date, updated_at)
  SELECT NEW.ledger_id, g.account_id, 0, 0, NEW.currency_code,
         g.d, g.c, g.n,
         (SELECT MAX(entry_date) FROM journal_lines WHERE entry_id = NEW.id),
         CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM (SELECT account_id,
               SUM(debit_minor)  AS d,
               SUM(credit_minor) AS c,
               COUNT(*)          AS n
          FROM journal_lines WHERE entry_id = NEW.id GROUP BY account_id) g
  WHERE true
  ON CONFLICT(ledger_id, account_id, period_id, period_start) DO UPDATE
    SET debit_minor  = debit_minor  + excluded.debit_minor,
        credit_minor = credit_minor + excluded.credit_minor,
        txn_count    = txn_count    + excluded.txn_count,
        last_entry_date = MAX(COALESCE(last_entry_date, 0), excluded.last_entry_date),
        updated_at   = excluded.updated_at;
END;

-- Voiding a posted entry removes its effect. History keeps the rows, every
-- report (which filters status = 1) drops the money.
CREATE TRIGGER IF NOT EXISTS trg_bal_void
AFTER UPDATE OF status ON journal_entries
FOR EACH ROW
WHEN NEW.status = 2 AND OLD.status = 1
BEGIN
  INSERT INTO balance_audit
    (account_id, session_id, before_debit, before_credit, delta_debit, delta_credit, delta_txns, touched_at)
  SELECT g.account_id,
         (SELECT session_id FROM v_session),
         COALESCE(ab.debit_minor, 0), COALESCE(ab.credit_minor, 0),
         -g.d, -g.c, -g.n,
         CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM (SELECT account_id,
               SUM(debit_minor)  AS d,
               SUM(credit_minor) AS c,
               COUNT(*)          AS n
          FROM journal_lines WHERE entry_id = NEW.id GROUP BY account_id) g
  LEFT JOIN account_balances ab
         ON ab.account_id = g.account_id AND ab.period_id = 0 AND ab.period_start = 0
  WHERE true
  ON CONFLICT(account_id) DO UPDATE
    SET delta_debit  = delta_debit  + excluded.delta_debit,
        delta_credit = delta_credit + excluded.delta_credit,
        delta_txns   = delta_txns   + excluded.delta_txns;

  UPDATE account_balances
     SET debit_minor  = debit_minor  - g.d,
         credit_minor = credit_minor - g.c,
         txn_count    = txn_count    - g.n,
         updated_at   = CAST(unixepoch('subsec') * 1000 AS INTEGER)
  FROM (SELECT account_id, SUM(debit_minor) AS d, SUM(credit_minor) AS c, COUNT(*) AS n
          FROM journal_lines WHERE entry_id = NEW.id GROUP BY account_id) g
  WHERE account_balances.account_id = g.account_id
    AND account_balances.period_id = 0 AND account_balances.period_start = 0;
END;

-- Regenerating a line's contribution when a posted line is rewritten by the
-- sync applier (the only writer allowed to do that). Both the OLD and the NEW
-- contribution are recorded in balance_audit, because the audit asserts
--     cache == before + delta
-- and any cache mutation that skips the audit must be treated as corruption.
CREATE TRIGGER IF NOT EXISTS trg_bal_reverse_upd
AFTER UPDATE ON journal_lines
FOR EACH ROW
WHEN (SELECT status FROM journal_entries WHERE id = OLD.entry_id) = 1
 AND (OLD.amount_minor <> NEW.amount_minor OR OLD.account_id <> NEW.account_id)
BEGIN
  INSERT INTO balance_audit
    (account_id, session_id, before_debit, before_credit, delta_debit, delta_credit, delta_txns, touched_at)
  SELECT OLD.account_id,
         (SELECT session_id FROM v_session),
         COALESCE((SELECT debit_minor  FROM account_balances
                    WHERE account_id = OLD.account_id AND period_id = 0 AND period_start = 0), 0),
         COALESCE((SELECT credit_minor FROM account_balances
                    WHERE account_id = OLD.account_id AND period_id = 0 AND period_start = 0), 0),
         -OLD.debit_minor, -OLD.credit_minor, 0,
         CAST(unixepoch('subsec') * 1000 AS INTEGER)
  WHERE true
  ON CONFLICT(account_id) DO UPDATE
    SET delta_debit  = delta_debit  - OLD.debit_minor,
        delta_credit = delta_credit - OLD.credit_minor;

  INSERT INTO balance_audit
    (account_id, session_id, before_debit, before_credit, delta_debit, delta_credit, delta_txns, touched_at)
  SELECT NEW.account_id,
         (SELECT session_id FROM v_session),
         COALESCE((SELECT debit_minor  FROM account_balances
                    WHERE account_id = NEW.account_id AND period_id = 0 AND period_start = 0), 0),
         COALESCE((SELECT credit_minor FROM account_balances
                    WHERE account_id = NEW.account_id AND period_id = 0 AND period_start = 0), 0),
         NEW.debit_minor, NEW.credit_minor, 0,
         CAST(unixepoch('subsec') * 1000 AS INTEGER)
  WHERE true
  ON CONFLICT(account_id) DO UPDATE
    SET delta_debit  = delta_debit  + NEW.debit_minor,
        delta_credit = delta_credit + NEW.credit_minor;

  UPDATE account_balances
     SET debit_minor  = debit_minor  - OLD.debit_minor,
         credit_minor = credit_minor - OLD.credit_minor,
         updated_at   = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE account_id = OLD.account_id AND period_id = 0 AND period_start = 0;
  UPDATE account_balances
     SET debit_minor  = debit_minor  + NEW.debit_minor,
         credit_minor = credit_minor + NEW.credit_minor,
         updated_at   = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE account_id = NEW.account_id AND period_id = 0 AND period_start = 0;
END;

-- ═══════════════════════════════════════════════════════════════════════════
--  D · DOCUMENTS & ALLOCATIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- DOC-1 · header totals are always re-derived from the lines, in the DB, so
--         the printed invoice can never disagree with the ledger by a paisa.
CREATE TRIGGER IF NOT EXISTS trg_doc_totals_ins
AFTER INSERT ON document_lines
FOR EACH ROW
BEGIN
  UPDATE documents
     SET subtotal_minor = (SELECT COALESCE(SUM(quantity_milli * unit_price_minor) / 1000, 0)
                             FROM document_lines WHERE document_id = NEW.document_id AND deleted_at IS NULL),
         discount_minor = (SELECT COALESCE(SUM(discount_minor), 0)
                             FROM document_lines WHERE document_id = NEW.document_id AND deleted_at IS NULL),
         tax_minor      = (SELECT COALESCE(SUM(tax_minor), 0)
                             FROM document_lines WHERE document_id = NEW.document_id AND deleted_at IS NULL),
         updated_at     = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE id = NEW.document_id;
  UPDATE documents
     SET total_minor   = subtotal_minor - discount_minor + tax_minor + shipping_minor
                         + other_charges_minor + round_off_minor,
         balance_minor = subtotal_minor - discount_minor + tax_minor + shipping_minor
                         + other_charges_minor + round_off_minor - amount_paid_minor
   WHERE id = NEW.document_id;
END;

CREATE TRIGGER IF NOT EXISTS trg_doc_totals_upd
AFTER UPDATE ON document_lines
FOR EACH ROW
BEGIN
  UPDATE documents
     SET subtotal_minor = (SELECT COALESCE(SUM(quantity_milli * unit_price_minor) / 1000, 0)
                             FROM document_lines WHERE document_id = NEW.document_id AND deleted_at IS NULL),
         discount_minor = (SELECT COALESCE(SUM(discount_minor), 0)
                             FROM document_lines WHERE document_id = NEW.document_id AND deleted_at IS NULL),
         tax_minor      = (SELECT COALESCE(SUM(tax_minor), 0)
                             FROM document_lines WHERE document_id = NEW.document_id AND deleted_at IS NULL),
         updated_at     = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE id = NEW.document_id;
  UPDATE documents
     SET total_minor   = subtotal_minor - discount_minor + tax_minor + shipping_minor
                         + other_charges_minor + round_off_minor,
         balance_minor = subtotal_minor - discount_minor + tax_minor + shipping_minor
                         + other_charges_minor + round_off_minor - amount_paid_minor
   WHERE id = NEW.document_id;
END;

-- DOC-2 · a posted document may not be edited into a different number, party
--         or currency. Void + re-issue instead (legal reality of invoices).
CREATE TRIGGER IF NOT EXISTS trg_doc_immutable
BEFORE UPDATE ON documents
FOR EACH ROW
WHEN OLD.status >= 1
BEGIN
  SELECT CASE
    WHEN NEW.doc_no <> OLD.doc_no OR NEW.doc_kind <> OLD.doc_kind
      OR NEW.party_id <> OLD.party_id OR NEW.currency_code <> OLD.currency_code
      OR NEW.doc_date <> OLD.doc_date
      THEN RAISE(ABORT, 'DOC-2: a posted document cannot change its number, kind, party, date or currency — void and re-issue')
    WHEN NEW.status < OLD.status
      THEN RAISE(ABORT, 'DOC-2b: document status cannot move backwards')
  END;
END;

-- DOC-3 · allocations must not exceed the document. Guarded here so a
--         miscalculated payment can never over-settle an invoice, on any
--         device, even if the UI's own validation is buggy.
CREATE TRIGGER IF NOT EXISTS trg_alloc_guard
BEFORE INSERT ON payment_allocations
FOR EACH ROW
BEGIN
  SELECT CASE
    WHEN NEW.amount_minor > 0
     AND NEW.amount_minor > (SELECT total_minor - amount_paid_minor
                               FROM documents WHERE id = NEW.document_id)
      THEN RAISE(ABORT, 'DOC-3: allocation exceeds the outstanding balance of the document')
    WHEN (SELECT currency_code FROM documents WHERE id = NEW.document_id)
      <> (SELECT currency_code FROM journal_entries WHERE id = NEW.payment_entry_id)
      THEN RAISE(ABORT, 'DOC-3b: payment currency does not match the document currency')
  END;
END;

-- DOC-4 · paid amount and balance follow the allocations, automatically.
CREATE TRIGGER IF NOT EXISTS trg_alloc_totals
AFTER INSERT ON payment_allocations
FOR EACH ROW
BEGIN
  UPDATE documents
     SET amount_paid_minor = (SELECT COALESCE(SUM(amount_minor), 0)
                                FROM payment_allocations WHERE document_id = NEW.document_id),
         balance_minor     = total_minor
                             - (SELECT COALESCE(SUM(amount_minor), 0)
                                  FROM payment_allocations WHERE document_id = NEW.document_id),
         status            = CASE
                               WHEN total_minor - (SELECT COALESCE(SUM(amount_minor), 0)
                                                     FROM payment_allocations WHERE document_id = NEW.document_id) <= 0
                               THEN 2 ELSE 1 END,
         updated_at        = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE id = NEW.document_id;
END;

-- ═══════════════════════════════════════════════════════════════════════════
--  E · INVENTORY — keep the on-hand cache exact, incrementally
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TRIGGER IF NOT EXISTS trg_stock_accrue_ins
AFTER INSERT ON stock_moves
FOR EACH ROW
BEGIN
  INSERT INTO stock_on_hand
    (ledger_id, item_id, warehouse_id, quantity_milli, value_minor, avg_cost_micros, last_move_date, updated_at)
  VALUES (NEW.ledger_id, NEW.item_id, COALESCE(NEW.warehouse_id, ''),
          NEW.direction * NEW.quantity_milli, NEW.value_minor,
          NEW.unit_cost_micros, NEW.move_date,
          CAST(unixepoch('subsec') * 1000 AS INTEGER))
  ON CONFLICT(ledger_id, item_id, warehouse_id) DO UPDATE
    SET quantity_milli = quantity_milli + excluded.quantity_milli,
        value_minor    = value_minor    + excluded.value_minor,
        avg_cost_micros = CASE
            WHEN quantity_milli + excluded.quantity_milli > 0
            THEN CAST(ABS(value_minor + excluded.value_minor) * 1000000
                      / (quantity_milli + excluded.quantity_milli) AS INTEGER)
            ELSE avg_cost_micros END,
        last_move_date = MAX(COALESCE(last_move_date, 0), excluded.last_move_date),
        updated_at     = excluded.updated_at;
END;

CREATE TRIGGER IF NOT EXISTS trg_stock_accrue_del
AFTER DELETE ON stock_moves
FOR EACH ROW
WHEN (SELECT write_mode FROM v_session) = 'purge'
BEGIN
  UPDATE stock_on_hand
     SET quantity_milli = quantity_milli - OLD.direction * OLD.quantity_milli,
         value_minor    = value_minor    - OLD.value_minor,
         updated_at     = CAST(unixepoch('subsec') * 1000 AS INTEGER)
   WHERE ledger_id = OLD.ledger_id AND item_id = OLD.item_id
     AND warehouse_id = COALESCE(OLD.warehouse_id, '');
END;

-- ═══════════════════════════════════════════════════════════════════════════
--  F · LEDGER-LEVEL SAFETY
-- ═══════════════════════════════════════════════════════════════════════════

-- FIN-1 · nothing may be posted into a closed/locked period.
CREATE TRIGGER IF NOT EXISTS trg_je_locked_period
BEFORE UPDATE OF status ON journal_entries
FOR EACH ROW
WHEN NEW.status = 1 AND OLD.status = 0
 AND (SELECT lock_after_date FROM ledgers WHERE id = NEW.ledger_id) IS NOT NULL
 AND NEW.entry_date <= (SELECT lock_after_date FROM ledgers WHERE id = NEW.ledger_id)
BEGIN
  SELECT RAISE(ABORT, 'FIN-1: the accounting period is locked — unlock it in Settings or change the entry date');
END;

-- FIN-2 · a system/seed account keeps its role and its ledger for life, so
--         reports bound to roles cannot be silently broken by a rename.
CREATE TRIGGER IF NOT EXISTS trg_account_system_guard
BEFORE UPDATE ON accounts
FOR EACH ROW
WHEN OLD.is_system = 1
BEGIN
  SELECT CASE
    WHEN COALESCE(NEW.role, '') <> COALESCE(OLD.role, '')
      THEN RAISE(ABORT, 'FIN-2: the role of a system account is fixed (rename the account instead)')
    WHEN NEW.ledger_id <> OLD.ledger_id
      THEN RAISE(ABORT, 'FIN-2b: an account cannot be moved to another ledger')
    WHEN NEW.kind <> OLD.kind OR NEW.normal_balance <> OLD.normal_balance
      THEN RAISE(ABORT, 'FIN-2c: the type/side of a system account is fixed')
    WHEN NEW.deleted_at IS NOT NULL
      THEN RAISE(ABORT, 'FIN-2d: system accounts cannot be deleted (deactivate them)')
  END;
END;

CREATE TRIGGER IF NOT EXISTS trg_account_no_delete
BEFORE DELETE ON accounts
FOR EACH ROW
WHEN OLD.is_system = 1 AND (SELECT write_mode FROM v_session) <> 'purge'
BEGIN
  SELECT RAISE(ABORT, 'FIN-2e: system accounts cannot be deleted');
END;

UPDATE schema_meta SET value = '1', updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
 WHERE key = 'triggers_version';
INSERT INTO schema_meta (key, value, updated_at)
SELECT 'triggers_version', '1', CAST(unixepoch('subsec') * 1000 AS INTEGER)
 WHERE NOT EXISTS (SELECT 1 FROM schema_meta WHERE key = 'triggers_version');
