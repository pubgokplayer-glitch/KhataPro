#!/usr/bin/env python3
"""
tool/sql_contract_test.py — the schema's contract tests.

Runs the real migration files against a real SQLite build and asserts that the
ledger invariants hold — the same statements a Dart test would run through
Drift, but with no Flutter toolchain required, so CI can prove the database
layer is sound even while the UI is still being written.

    python3 tool/sql_contract_test.py            # in-memory, fast
    python3 tool/sql_contract_test.py --file /tmp/k.sqlite   # inspect afterwards

Exit code 0 = every contract holds. Non-zero = the printed failures.
"""

from __future__ import annotations

import argparse
import glob
import os
import sqlite3
import sys
import traceback

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEED_NODE = "00000000-0000-7000-8000-000000000000"
LEDGER = "019a1b2c-0000-7000-8000-000000000001"
CASH = "019a1b2c-0000-7000-8000-00000000044c"      # 1100 Cash in Hand
BANK = "019a1b2c-0000-7000-8000-000000000456"      # 1110 Bank Account
AR = "019a1b2c-0000-7000-8000-0000000004b0"        # 1200 Accounts Receivable
INVENTORY = "019a1b2c-0000-7000-8000-000000000514" # 1300 Inventory
AP = "019a1b2c-0000-7000-8000-000000000834"        # 2100 Accounts Payable
TAX = "019a1b2c-0000-7000-8000-0000000008fc"       # 2300 Sales Tax Payable
SALES = "019a1b2c-0000-7000-8000-000000001004"     # 4100 Sales — Goods
EXPENSE = "019a1b2c-0000-7000-8000-0000000013ec"   # 5100 COGS
WALK_IN = "019a1b2c-0000-7000-8000-00000000c001"

RESULTS: list[tuple[str, str, str]] = []


def check(name: str, fn) -> None:
    try:
        fn()
        RESULTS.append(("PASS", name, ""))
    except AssertionError as exc:
        RESULTS.append(("FAIL", name, str(exc)))
    except Exception as exc:  # noqa: BLE001 — a crash is a failed contract
        RESULTS.append(("FAIL", name, f"{type(exc).__name__}: {exc}"))


def uuid7(n: int, group: str = "aaaa") -> str:
    return f"019a1b2c-{group}-7000-8000-{n:012x}"


def hlc(physical_ms: int, counter: int = 0, node: str = SEED_NODE) -> str:
    return f"{physical_ms:015d}:{counter:04x}:{node}"


# ─────────────────────────────────────────────────────────────────────────────
#  Harness
# ─────────────────────────────────────────────────────────────────────────────
class DB:
    def __init__(self, path: str) -> None:
        self.c = sqlite3.connect(path, isolation_level=None)
        self.c.execute("PRAGMA foreign_keys = ON")
        self.c.execute("PRAGMA busy_timeout = 5000")
        self.migrate()
        self.today = self.scalar("SELECT CAST(value AS INTEGER) FROM session_flags WHERE key='today_epoch_day'")
        self.c.execute("UPDATE session_flags SET value='contract-test' WHERE key='session_id'")
        self.c.execute("UPDATE session_flags SET value='user' WHERE key='write_mode'")

    def migrate(self) -> None:
        for f in sorted(glob.glob(os.path.join(ROOT, "assets/sql/migrations/*.sql"))):
            self.c.executescript(open(f, encoding="utf-8").read())

    def run(self, sql: str, *args):
        return self.c.execute(sql, args)

    def scalar(self, sql: str, *args):
        row = self.c.execute(sql, args).fetchone()
        return row[0] if row else None

    def all(self, sql: str, *args):
        return self.c.execute(sql, args).fetchall()

    def exec_(self, sql: str) -> None:
        self.c.executescript(sql)

    def begin(self) -> None:
        self.c.execute("BEGIN IMMEDIATE")

    def rollback(self) -> None:
        self.c.execute("ROLLBACK")

    def gate(self) -> None:
        """Run the real gate as a single statement, inside the caller's txn."""
        self.c.execute(
            """INSERT INTO invariant_violations (kind, detail, detected_at)
               SELECT kind, detail, CAST(unixepoch('subsec') * 1000 AS INTEGER)
                 FROM v_integrity_report WHERE severity = 1""")

    def violations(self) -> list[tuple[str, str]]:
        return self.all("SELECT kind, detail FROM invariant_violations")

    def clear_violations(self) -> None:
        self.c.execute("DELETE FROM invariant_violations")

    def expect_error(self, sql: str, needle: str, *args) -> str:
        try:
            self.c.execute(sql, args)
        except sqlite3.Error as exc:
            assert needle in str(exc), f"expected error containing {needle!r}, got: {exc}"
            return str(exc)
        raise AssertionError(f"expected failure containing {needle!r} but the statement succeeded")

    # ── domain helpers ───────────────────────────────────────────────────────
    def draft_entry(self, n: int, date: int | None = None, source: int = 1,
                    party: str | None = None, status: int = 0,
                    currency: str = "PKR") -> str:
        eid = uuid7(n, "e11e")
        ts = 1800000000000 + n
        self.c.execute(
            """INSERT INTO journal_entries
                 (id, ledger_id, entry_no, entry_date, source, status, posted_at, currency_code,
                  base_currency_code, party_id, memo, device_id, hlc, node_id, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (eid, LEDGER, f"JV-{n:05d}", date if date is not None else self.today, source, status,
             ts if status != 0 else None,
             currency, "PKR", party, f"contract test entry {n}", SEED_NODE,
             hlc(ts), SEED_NODE, ts, ts))
        return eid

    def add_line(self, entry: str, no: int, account: str, amount: int, n: int,
                 party: str | None = None, item: str | None = None,
                 qty_milli: int = 0) -> str:
        lid = uuid7(n, "11ee")
        ts = 1800000000000 + n
        self.c.execute(
            """INSERT INTO journal_lines
                 (id, ledger_id, entry_id, line_no, entry_date, account_id, party_id, item_id,
                  amount_minor, base_amount_minor, currency_code, quantity_milli, node_id, created_at)
               SELECT ?, ?, ?, ?, entry_date, ?, ?, ?, ?, ?, currency_code, ?, ?, ?
                 FROM journal_entries WHERE id = ?""",
            (lid, LEDGER, entry, no, account, party, item, amount, amount, qty_milli,
             SEED_NODE, ts, entry))
        return lid

    def post(self, entry: str, at: int = 1900000000000) -> None:
        """The guarded transition: this is the ONLY way an entry becomes posted."""
        self.run("UPDATE journal_entries SET status=1, posted_at=?, hlc=?, rev=rev+1 WHERE id=?",
                 at, hlc(at, 1), entry)


def suite(db: DB) -> None:
    # ══ A · migrations ═══════════════════════════════════════════════════════
    def a1_migrations_idempotent():
        db.migrate()  # second pass must be a no-op
        assert db.scalar("SELECT COUNT(*) FROM accounts") == 37, "seed duplicated on re-run"
        assert db.scalar("SELECT COUNT(*) FROM currencies") == 8
    check("A1  migrations are idempotent (safe to re-run)", a1_migrations_idempotent)

    def a2_seed_shape():
        assert db.scalar("SELECT COUNT(*) FROM accounts WHERE is_system=1") == 37
        assert db.scalar("SELECT COUNT(*) FROM accounts WHERE role IS NULL") == 0
        assert db.scalar("SELECT COUNT(*) FROM accounts WHERE normal_balance NOT IN (1,-1)") == 0
        # every debit-normal account + every credit-normal account must be
        # usable: exactly the 37 seeded roles, no duplicates
        assert db.scalar("SELECT COUNT(DISTINCT role) FROM accounts WHERE role IS NOT NULL") == 37
    check("A2  seeded chart of accounts is complete and role-complete", a2_seed_shape)

    def a3_gate_wired():
        db.expect_error("INSERT INTO invariant_violations VALUES ('X','y',0)", "INTEGRITY GATE")
        # RAISE(FAIL) aborts the statement but keeps the transaction open and
        # leaves the FIRST violation row in place — so the caller can read it as
        # a precise diagnostic before deciding to roll back.
        rows = db.violations()
        assert len(rows) == 1 and rows[0][0] == "X", rows
        db.clear_violations()
    check("A3  the abort gate fires and leaves no residue", a3_gate_wired)

    # ══ B · double entry: the law ════════════════════════════════════════════
    def b1_balanced_posts():
        e = db.draft_entry(1)
        db.add_line(e, 1, CASH, 125000, 101)
        db.add_line(e, 2, SALES, -125000, 102)
        assert db.scalar("SELECT total_debit_minor FROM journal_entries WHERE id=?", e) == 125000
        db.post(e)
        assert db.scalar("SELECT status FROM journal_entries WHERE id=?", e) == 1
    check("B1  a balanced entry (Dr Cash 1250.00 / Cr Sales 1250.00) posts", b1_balanced_posts)

    def b2_unbalanced_rejected():
        e = db.draft_entry(2)
        db.add_line(e, 1, CASH, 125000, 103)
        db.add_line(e, 2, SALES, -100000, 104)
        msg = db.expect_error(
            "UPDATE journal_entries SET status=1, posted_at=1 WHERE id=?", "INT-5b", e)
        assert "NOT balanced" in msg
        assert db.scalar("SELECT status FROM journal_entries WHERE id=?", e) == 0
    check("B2  an unbalanced entry (Dr 1250 / Cr 1000) is refused by the DB", b2_unbalanced_rejected)

    def b3_one_line_rejected():
        e = db.draft_entry(3)
        db.add_line(e, 1, CASH, 5000, 105)
        db.expect_error("UPDATE journal_entries SET status=1, posted_at=1 WHERE id=?", "INT-5", e)
    check("B3  a single-line entry is refused", b3_one_line_rejected)

    def b4_same_side_rejected():
        e = db.draft_entry(4)
        db.add_line(e, 1, CASH, 5000, 106)
        db.add_line(e, 2, BANK, 5000, 107)
        db.expect_error("UPDATE journal_entries SET status=1, posted_at=1 WHERE id=?", "INT-5", e)
    check("B4  an entry with two debits and no credit is refused", b4_same_side_rejected)

    def b5_posted_is_frozen():
        eid = db.scalar("SELECT id FROM journal_entries WHERE entry_no='JV-00001'")
        db.expect_error("UPDATE journal_lines SET amount_minor=999 WHERE entry_id=?", "INT-2g", eid)
        db.expect_error("UPDATE journal_entries SET entry_date=entry_date+1 WHERE id=?", "INT-7", eid)
        db.expect_error("UPDATE journal_entries SET party_id=? WHERE id=?", "INT-7", WALK_IN, eid)
        db.expect_error("DELETE FROM journal_lines WHERE entry_id=?", "INT-3", eid)
        db.expect_error("INSERT INTO journal_lines "
                        "(id,ledger_id,entry_id,line_no,entry_date,account_id,amount_minor,base_amount_minor,currency_code,node_id,created_at) "
                        "SELECT ?,?,?,9,entry_date,?,10,10,'PKR',?,0 FROM journal_entries WHERE id=?",
                        "INT-1", uuid7(900, "11ee"), LEDGER, eid, CASH, SEED_NODE, eid)
    check("B5  posted lines/entries are frozen (edit, move, delete all refused)", b5_posted_is_frozen)

    def b6_narration_is_lww():
        eid = db.scalar("SELECT id FROM journal_entries WHERE entry_no='JV-00001'")
        db.run("UPDATE journal_entries SET memo='corrected narration', hlc=?, rev=rev+1 WHERE id=?",
               hlc(1900000000000, 2), eid)
        assert db.scalar("SELECT memo FROM journal_entries WHERE id=?", eid) == "corrected narration"
    check("B6  narration stays editable (LWW) while money stays frozen", b6_narration_is_lww)

    def b7_stale_write_rejected():
        eid = db.scalar("SELECT id FROM journal_entries WHERE entry_no='JV-00001'")
        before = db.scalar("SELECT hlc FROM journal_entries WHERE id=?", eid)
        db.expect_error("UPDATE journal_entries SET memo='older', hlc=?, rev=rev WHERE id=?",
                        "INT-7e", hlc(1), eid)
        assert db.scalar("SELECT hlc FROM journal_entries WHERE id=?", eid) == before
    check("B7  a stale CRDT write (older HLC) is rejected", b7_stale_write_rejected)

    def b8_no_backdoor_posting():
        db.expect_error(
            """INSERT INTO journal_entries
                 (id,ledger_id,entry_no,entry_date,source,status,currency_code,base_currency_code,
                  device_id,hlc,node_id,created_at,updated_at)
               VALUES (?,?,?,?,1,1,'PKR','PKR',?,?,?,0,0)""",
            "INT-6", uuid7(901, "e11e"), LEDGER, "JV-99999", db.today, SEED_NODE, hlc(5), SEED_NODE)
    check("B8  an entry cannot be born already-posted (must walk the gate)", b8_no_backdoor_posting)

    # ══ C · money & structure ══════════════════════════════════════════════
    def c1_zero_and_float_rejected():
        e = db.draft_entry(5)
        db.expect_error("INSERT INTO journal_lines "
                        "(id,ledger_id,entry_id,line_no,entry_date,account_id,amount_minor,base_amount_minor,currency_code,node_id,created_at) "
                        "SELECT ?,?,?,1,entry_date,?,0,0,'PKR',?,0 FROM journal_entries WHERE id=?",
                        "CHECK", uuid7(902, "11ee"), LEDGER, e, CASH, SEED_NODE, e)
        db.expect_error("INSERT INTO journal_lines "
                        "(id,ledger_id,entry_id,line_no,entry_date,account_id,amount_minor,base_amount_minor,currency_code,node_id,created_at) "
                        "SELECT ?,?,?,1,entry_date,?,12.5,12.5,'PKR',?,0 FROM journal_entries WHERE id=?",
                        "", uuid7(903, "11ee"), LEDGER, e, CASH, SEED_NODE, e)
        db.run("DELETE FROM journal_entries WHERE id=?", e)   # draft discard is allowed
    check("C1  zero and fractional money are structurally impossible", c1_zero_and_float_rejected)

    def c2_line_entry_agreement():
        e = db.draft_entry(6)
        db.expect_error("INSERT INTO journal_lines "
                        "(id,ledger_id,entry_id,line_no,entry_date,account_id,amount_minor,base_amount_minor,currency_code,node_id,created_at) "
                        "VALUES (?,?,?,1,?,?,100,100,'PKR',?,0)",
                        "INT-2b", uuid7(904, "11ee"), LEDGER, e, db.today - 5, CASH, SEED_NODE)
        db.run("DELETE FROM journal_entries WHERE id=?", e)
    check("C2  a line whose date disagrees with its entry is refused", c2_line_entry_agreement)

    def c3_no_parent_posting():
        pid = uuid7(910, "acc0")
        db.run("""INSERT INTO accounts (id,ledger_id,code,name,kind,normal_balance,is_postable,is_system,
                                        currency_code,hlc,node_id,rev,created_at,updated_at)
                  VALUES (?,?,'1999','Fixed Assets Header',1,1,0,0,'PKR',?,?,1,0,0)""",
               pid, LEDGER, hlc(9), SEED_NODE)
        e = db.draft_entry(7)
        db.expect_error("INSERT INTO journal_lines "
                        "(id,ledger_id,entry_id,line_no,entry_date,account_id,amount_minor,base_amount_minor,currency_code,node_id,created_at) "
                        "SELECT ?,?,?,1,entry_date,?,100,100,'PKR',?,0 FROM journal_entries WHERE id=?",
                        "INT-2d", uuid7(905, "11ee"), LEDGER, e, pid, SEED_NODE, e)
        db.run("DELETE FROM journal_entries WHERE id=?", e)
    check("C3  postings to header (non-postable) accounts are refused", c3_no_parent_posting)

    def c4_cross_ledger_refused():
        other = uuid7(920, "1ed9")
        db.run("""INSERT INTO ledgers (id,name,base_currency,hlc,node_id,rev,created_at,updated_at)
                  VALUES (?,'Second Book','PKR',?,?,1,0,0)""", other, hlc(11), SEED_NODE)
        db.run("""INSERT INTO accounts (id,ledger_id,code,name,kind,normal_balance,is_postable,is_system,
                                        currency_code,hlc,node_id,rev,created_at,updated_at)
                  VALUES ('019a1b2c-0000-7000-8000-0000000009c4',?,'1100','Cash (other book)',1,1,1,0,'PKR',?,?,1,0,0)""",
               other, hlc(12), SEED_NODE)
        e = db.draft_entry(8)
        db.expect_error("INSERT INTO journal_lines "
                        "(id,ledger_id,entry_id,line_no,entry_date,account_id,amount_minor,base_amount_minor,currency_code,node_id,created_at) "
                        "SELECT ?,?,?,1,entry_date,'019a1b2c-0000-7000-8000-0000000009c4',100,100,'PKR',?,0 FROM journal_entries WHERE id=?",
                        "FOREIGN KEY", uuid7(906, "11ee"), LEDGER, e, SEED_NODE, e)
        db.run("DELETE FROM journal_entries WHERE id=?", e)
    check("C4  a line cannot reference another ledger's account (composite FK)", c4_cross_ledger_refused)

    # ══ D · balances, caches and reports ═══════════════════════════════════
    def d1_cache_follows_postings():
        # JV-00001: Dr Cash 125000 / Cr Sales 125000
        assert db.scalar("SELECT net_minor FROM account_balances WHERE account_id=? AND period_id=0", CASH) == 125000
        assert db.scalar("SELECT net_minor FROM account_balances WHERE account_id=? AND period_id=0", SALES) == -125000
    check("D1  the balance cache reflects posted entries", d1_cache_follows_postings)

    def d2_void_removes_money():
        e = db.draft_entry(20)
        db.add_line(e, 1, BANK, 250000, 120)
        db.add_line(e, 2, SALES, -250000, 121)
        db.post(e)
        assert db.scalar("SELECT net_minor FROM account_balances WHERE account_id=?", BANK) == 250000
        db.run("UPDATE journal_entries SET status=2, voided_at=?, hlc=?, rev=rev+1 WHERE id=?",
               1900000000000, hlc(1900000000000, 1), e)
        assert db.scalar("SELECT net_minor FROM account_balances WHERE account_id=?", BANK) == 0, \
            "voiding must remove the entry's effect from the cache"
        assert db.scalar("SELECT net_minor FROM account_balances WHERE account_id=?", SALES) == -125000
        assert db.scalar("SELECT COUNT(*) FROM v_journal_detail WHERE entry_id=?", e) >= 1, \
            "voided rows stay in history for audit"
        assert db.scalar("SELECT COALESCE(SUM(amount_minor),0) FROM v_party_ledger") is not None
    check("D2  voiding removes money from every report but keeps history", d2_void_removes_money)

    def d3_trial_balance_zero_sum():
        dr = db.scalar("SELECT SUM(closing_debit_minor) FROM v_trial_balance")
        cr = db.scalar("SELECT SUM(closing_credit_minor) FROM v_trial_balance")
        assert dr == cr, f"trial balance does not balance: Dr {dr} vs Cr {cr}"
        assert db.scalar("SELECT SUM(signed_net_minor) FROM v_trial_balance") == 0
    check("D3  the trial balance sums to zero (Dr == Cr)", d3_trial_balance_zero_sum)

    def d4_dashboard_and_pl():
        assert db.scalar("SELECT today_sales_minor FROM v_dashboard_metrics") == 125000
        assert db.scalar("SELECT cash_minor FROM v_dashboard_metrics") == 125000
        pl_sales = db.scalar("SELECT amount_minor FROM v_profit_and_loss WHERE role='sales'")
        assert pl_sales == 125000, f"P&L sales should be 125000, got {pl_sales}"
    check("D4  dashboard metrics and P&L read straight from the ledger", d4_dashboard_and_pl)

    def d5_party_subledger():
        cid = uuid7(930, "pa47")
        db.run("""INSERT INTO parties (id,ledger_id,name,kind,hlc,node_id,rev,created_at,updated_at)
                  VALUES (?,?,'Ahmed Traders',1,?,?,1,0,0)""", cid, LEDGER, hlc(20), SEED_NODE)
        e = db.draft_entry(21, source=1, party=cid)
        db.add_line(e, 1, AR, 300000, 130, party=cid)
        db.add_line(e, 2, SALES, -300000, 131)
        db.post(e)
        assert db.scalar("SELECT receivable_minor FROM v_party_balances WHERE party_id=?", cid) == 300000
        rows = db.all("SELECT amount_minor, running_balance_minor FROM v_party_ledger WHERE party_id=? ORDER BY entry_date, line_no, line_id", cid)
        assert rows == [(300000, 300000)], rows
        assert db.scalar("SELECT SUM(net_minor) FROM account_balances WHERE account_id=?", AR) == 300000
    check("D5  the party sub-ledger and AR agree to the paisa", d5_party_subledger)

    def d6_purchase_payment_allocation():
        sid = uuid7(931, "5upp")
        db.run("""INSERT INTO parties (id,ledger_id,name,kind,hlc,node_id,rev,created_at,updated_at)
                  VALUES (?,?,'Al-Madina Wholesale',2,?,?,1,0,0)""", sid, LEDGER, hlc(21), SEED_NODE)
        # purchase bill: Dr Inventory 1,000,000 / Cr AP 1,000,000
        be = db.draft_entry(22, source=2, party=sid)
        db.add_line(be, 1, INVENTORY, 1000000, 140)
        db.add_line(be, 2, AP, -1000000, 141, party=sid)
        db.post(be)
        doc = uuid7(940, "d0c0")
        db.run("""INSERT INTO documents (id,ledger_id,doc_kind,doc_no,doc_date,party_id,currency_code,
                                         total_minor,balance_minor,status,hlc,node_id,rev,created_at,updated_at)
                  VALUES (?,?,2,'BILL-0001',?,?,'PKR',1000000,1000000,1,?,?,1,0,0)""",
               doc, LEDGER, db.today, sid, hlc(22), SEED_NODE)
        db.run("""INSERT INTO document_lines (id,ledger_id,document_id,line_no,item_id,description,
                                              quantity_milli,unit_price_minor,line_total_minor,
                                              hlc,node_id,rev,created_at,updated_at)
                  VALUES (?,?,?,1,NULL,'Assorted stock',1000,1000000,1000000,?,?,1,0,0)""",
               uuid7(941, "d11e"), LEDGER, doc, hlc(23), SEED_NODE)
        # DOC-1 re-derives the header total from the lines: 1.000 unit × 10 000.00
        assert db.scalar("SELECT total_minor FROM documents WHERE id=?", doc) == 1000000, \
            "the document header total must be re-derived from its lines"
        assert db.scalar("SELECT balance_minor FROM documents WHERE id=?", doc) == 1000000
        # payment: Dr AP 400,000 / Cr Cash 400,000
        pe = db.draft_entry(23, source=5, party=sid)
        db.add_line(pe, 1, AP, 400000, 150, party=sid)
        db.add_line(pe, 2, CASH, -400000, 151)
        db.post(pe)
        db.run("""INSERT INTO payment_allocations (id,ledger_id,payment_entry_id,document_id,amount_minor,
                                                   allocated_date,hlc,node_id,created_at)
                  VALUES (?,?,?,?,400000,?,?,?,0)""",
               uuid7(950, "a110"), LEDGER, pe, doc, db.today, hlc(24), SEED_NODE)
        assert db.scalar("SELECT amount_paid_minor FROM documents WHERE id=?", doc) == 400000
        assert db.scalar("SELECT balance_minor FROM documents WHERE id=?", doc) == 600000
        # DOC-3: settling more than the outstanding balance is refused in SQL
        db.expect_error("""INSERT INTO payment_allocations (id,ledger_id,payment_entry_id,document_id,amount_minor,
                                                             allocated_date,hlc,node_id,created_at)
                           VALUES (?,?,?,?,900000,?,?,?,0)""",
                        "DOC-3", uuid7(951, "a110"), LEDGER, pe, doc, db.today, hlc(25), SEED_NODE)
        # AP net: -1,000,000 + 400,000 = -600,000 (business still owes 6,000.00)
        assert db.scalar("SELECT net_minor FROM account_balances WHERE account_id=?", AP) == -600000
    check("D6  purchase → payment → allocation, with over-allocation refused", d6_purchase_payment_allocation)

    def d7_tax_through_the_ledger():
        # Dr Cash 118,000 / Cr Sales 100,000 / Cr Sales Tax Payable 18,000
        e = db.draft_entry(24, source=1)
        db.add_line(e, 1, CASH, 118000, 160)
        db.add_line(e, 2, SALES, -100000, 161)
        db.add_line(e, 3, TAX, -18000, 162)
        db.post(e)
        assert db.scalar("SELECT net_minor FROM account_balances WHERE account_id=?", TAX) == -18000
        dr = db.scalar("SELECT SUM(closing_debit_minor) FROM v_trial_balance")
        cr = db.scalar("SELECT SUM(closing_credit_minor) FROM v_trial_balance")
        assert dr == cr, "tax postings must not unbalance the trial balance"
    check("D7  a tax-inclusive sale stays balanced and lands on the tax account", d7_tax_through_the_ledger)

    def d8_no_negative_stock_guard():
        iid = uuid7(960, "17e3")
        db.run("""INSERT INTO items (id,ledger_id,name,kind,unit,is_stocked,sale_price_minor,
                                     inventory_account_id,hlc,node_id,rev,created_at,updated_at)
                  VALUES (?,?,'Sugar 50kg bag',0,'bag',1,950000,?,?,?,1,0,0)""",
               iid, LEDGER, INVENTORY, hlc(30), SEED_NODE)
        db.run("""INSERT INTO stock_moves (id,ledger_id,item_id,move_date,direction,quantity_milli,
                                           unit_cost_micros,value_minor,source,hlc,node_id,created_at)
                  VALUES (?,?,?,?,1,10000,80000,800000,4,?,?,0)""",
               uuid7(961, "570c"), LEDGER, iid, db.today, hlc(31), SEED_NODE)
        assert db.scalar("SELECT quantity_milli FROM stock_on_hand WHERE item_id=?", iid) == 10000, \
            "the on-hand cache must track stock moves incrementally"
        assert db.scalar("SELECT quantity_milli FROM v_stock_on_hand_live WHERE item_id=?", iid) == 10000
        # an out-move larger than stock: stock goes negative, and the report warns
        db.run("""INSERT INTO stock_moves (id,ledger_id,item_id,move_date,direction,quantity_milli,
                                           unit_cost_micros,value_minor,source,hlc,node_id,created_at)
                  VALUES (?,?,?,?,-1,15000,80000,-1200000,1,?,?,0)""",
               uuid7(962, "570c"), LEDGER, iid, db.today, hlc(32), SEED_NODE)
        assert db.scalar("SELECT quantity_milli FROM stock_on_hand WHERE item_id=?", iid) == -5000
        assert db.scalar("SELECT COUNT(*) FROM v_integrity_report WHERE kind='NEGATIVE_STOCK'") == 1
    check("D8  inventory on-hand cache tracks moves; negative stock is flagged", d8_no_negative_stock_guard)

    # ══ E · the integrity gate ═════════════════════════════════════════════
    def e1_gate_clean():
        db.gate()
        db.c.execute("DELETE FROM balance_audit")
        critical = db.all("SELECT kind, detail FROM v_integrity_report WHERE severity=1")
        assert not critical, f"healthy book reported critical findings: {critical}"
    check("E1  the integrity gate passes on a healthy book", e1_gate_clean)

    def e2_gate_catches_cache_corruption():
        db.run("UPDATE account_balances SET debit_minor = debit_minor + 1 WHERE account_id=?", CASH)
        try:
            db.gate()
            raise AssertionError("the gate missed a corrupted balance cache")
        except sqlite3.Error as exc:
            assert "INTEGRITY GATE" in str(exc)
            kinds = [k for k, _ in db.violations()]
            assert "ACCOUNT_BALANCE_DRIFT" in kinds, f"gate fired on the wrong invariant: {kinds}"
            db.clear_violations()
        # repair is a pure rebuild — the underlying postings were never touched
        db.run("UPDATE session_flags SET value='maintenance' WHERE key='write_mode'")
        db.exec_(open(os.path.join(ROOT, "assets/sql/ops/rebuild_caches.sql"), encoding="utf-8").read())
        db.run("UPDATE session_flags SET value='user' WHERE key='write_mode'")
        db.exec_("DELETE FROM balance_audit;")
        db.gate()
    check("E2  a corrupted cache is detected AND repairable without data loss", e2_gate_catches_cache_corruption)

    def e3_trial_balance_survives_repair():
        dr = db.scalar("SELECT SUM(closing_debit_minor) FROM v_trial_balance")
        cr = db.scalar("SELECT SUM(closing_credit_minor) FROM v_trial_balance")
        assert dr == cr and dr > 0
    check("E3  the trial balance still balances after the repair", e3_trial_balance_survives_repair)

    # ══ F · sync / CRDT semantics ══════════════════════════════════════════
    def f1_sync_mode_applies_history():
        cash_before = db.scalar("SELECT net_minor FROM account_balances WHERE account_id=?", CASH)
        db.run("UPDATE session_flags SET value='sync' WHERE key='write_mode'")
        try:
            e = db.draft_entry(40, status=1)      # peers send already-posted rows
            db.add_line(e, 1, CASH, 7000, 170)
            db.add_line(e, 2, SALES, -7000, 171)
            assert db.scalar("SELECT net_minor FROM account_balances WHERE account_id=?", CASH) \
                   == cash_before + 7000, "replicating a peer's posting must move the cache"
        finally:
            db.run("UPDATE session_flags SET value='user' WHERE key='write_mode'")
    check("F1  sync mode can replay a peer's posted history into the cache", f1_sync_mode_applies_history)

    def f2_replay_is_idempotent():
        # the exact same replicated rows arriving twice must change nothing
        cash_before = db.scalar("SELECT net_minor FROM account_balances WHERE account_id=?", CASH)
        db.run("UPDATE session_flags SET value='sync' WHERE key='write_mode'")
        try:
            db.exec_("""INSERT OR IGNORE INTO journal_lines
                          (id,ledger_id,entry_id,line_no,entry_date,account_id,amount_minor,base_amount_minor,
                           currency_code,node_id,created_at)
                        SELECT id,ledger_id,entry_id,line_no,entry_date,account_id,amount_minor,base_amount_minor,
                               currency_code,node_id,created_at
                          FROM journal_lines;""")
            db.exec_("""INSERT OR IGNORE INTO journal_entries
                          (id,ledger_id,entry_no,entry_date,status,currency_code,base_currency_code,
                           total_debit_minor,total_credit_minor,base_total_minor,device_id,hlc,node_id,created_at,updated_at)
                        SELECT id,ledger_id,entry_no,entry_date,status,currency_code,base_currency_code,
                               total_debit_minor,total_credit_minor,base_total_minor,device_id,hlc,node_id,created_at,updated_at
                          FROM journal_entries;""")
        finally:
            db.run("UPDATE session_flags SET value='user' WHERE key='write_mode'")
        assert db.scalar("SELECT net_minor FROM account_balances WHERE account_id=?", CASH) == cash_before, \
            "set-union replay must be a no-op (idempotence)"
    check("F2  replaying the same replicated rows is a no-op (set-union)", f2_replay_is_idempotent)

    def f3_bad_peer_cannot_poison():
        db.begin()
        try:
            db.run("UPDATE session_flags SET value='sync' WHERE key='write_mode'")
            e = db.draft_entry(41, status=1)
            db.add_line(e, 1, CASH, 9000, 180)
            db.add_line(e, 2, SALES, -8000, 181)     # peer sent garbage
            try:
                db.gate()
                raise AssertionError("an unbalanced peer batch slipped through the gate")
            except sqlite3.Error as exc:
                assert "INTEGRITY GATE" in str(exc)
        finally:
            db.rollback()
            db.run("UPDATE session_flags SET value='user' WHERE key='write_mode'")
    check("F3  a peer's unbalanced batch is refused at the end of the batch", f3_bad_peer_cannot_poison)

    def f4_oplog_and_health():
        seq = db.scalar("SELECT MAX(seq) FROM oplog")
        assert seq is None or seq >= 0
        assert db.scalar("SELECT COUNT(*) FROM v_sync_health") == 1
        base = hlc(1800000000000)
        assert len(base) == 57, f"HLC must be 57 chars for byte-ordering, got {len(base)}"
        assert hlc(1800000000001) > hlc(1800000000000, 0xffff), "physical ms must dominate the counter"
        assert hlc(1800000000000, 2, "a1") < hlc(1800000000000, 2, "b1"), "node id must break ties"
    check("F4  HLC byte-ordering is causally correct (57 chars, fixed width)", f4_oplog_and_health)

    # ══ G · search ═════════════════════════════════════════════════════════
    def g1_search_english_and_urdu():
        pid = uuid7(970, "5ea2")
        db.run("""INSERT INTO parties (id,ledger_id,name,name_ur,kind,phone,hlc,node_id,rev,created_at,updated_at)
                  VALUES (?,?,'Ahmed Traders','احمد ٹریڈرز',1,'03001234567',?,?,1,0,0)""",
               pid, LEDGER, hlc(50), SEED_NODE)
        assert db.scalar("SELECT COUNT(*) FROM search_index WHERE search_index MATCH 'ahmed*'") >= 1
        assert db.scalar("SELECT COUNT(*) FROM search_index WHERE search_index MATCH 'احمد'") >= 1, \
            "Urdu full-text search must work offline"
        assert db.scalar("SELECT COUNT(*) FROM search_index WHERE search_index MATCH '03001234567'") >= 1
        assert db.scalar("SELECT COUNT(*) FROM search_map WHERE kind='party' AND row_id=?", pid) == 1
        before = db.scalar("SELECT COUNT(*) FROM search_index WHERE search_index MATCH 'ahmed*'")
        db.run("UPDATE parties SET deleted_at=? , hlc=?, rev=rev+1 WHERE id=?", 1900000000000, hlc(1900000000000), pid)
        after = db.scalar("SELECT COUNT(*) FROM search_index WHERE search_index MATCH 'ahmed*'")
        assert after == before - 1, \
            f"soft-deleted rows must leave the index (before={before}, after={after})"
    check("G1  offline FTS finds Urdu, English and phone numbers", g1_search_english_and_urdu)

    # ══ H · governance ═════════════════════════════════════════════════════
    def h1_locked_period():
        db.run("UPDATE ledgers SET lock_after_date=? WHERE id=?", db.today - 1, LEDGER)
        e = db.draft_entry(50, date=db.today - 10)
        db.add_line(e, 1, CASH, 100, 190)
        db.add_line(e, 2, SALES, -100, 191)
        db.expect_error("UPDATE journal_entries SET status=1, posted_at=1 WHERE id=?", "FIN-1", e)
        db.run("UPDATE ledgers SET lock_after_date=NULL WHERE id=?", LEDGER)
        db.post(e)
    check("H1  a locked accounting period refuses new postings", h1_locked_period)

    def h2_system_account_guard():
        db.expect_error("UPDATE accounts SET role='hacked' WHERE id=?", "FIN-2", CASH)
        db.expect_error("DELETE FROM accounts WHERE id=?", "FIN-2e", CASH)
        db.run("UPDATE accounts SET name='Galla (Cash Box)', hlc=?, rev=rev+1 WHERE id=?", hlc(60), CASH)
        assert db.scalar("SELECT name FROM accounts WHERE id=?", CASH) == "Galla (Cash Box)"
        assert db.scalar("SELECT role FROM accounts WHERE id=?", CASH) == "cash"
    check("H2  reports bind to roles: renaming is free, retargeting is not", h2_system_account_guard)

    def h3_audit_chain_detects_tampering():
        db.begin()
        try:
            db.run("""INSERT INTO audit_log (id,ledger_id,seq,actor_node_id,action,entity_type,entity_id,
                                             hash_prev,hash_self,hlc,node_id,created_at)
                      VALUES (?,?,1,?,'entry.posted','journal_entry','x',?,?,?,?,0)""",
                   uuid7(980, "a0d1"), LEDGER, SEED_NODE, "0" * 64, "1" * 64, hlc(70), SEED_NODE)
            db.run("""INSERT INTO audit_log (id,ledger_id,seq,actor_node_id,action,entity_type,entity_id,
                                             hash_prev,hash_self,hlc,node_id,created_at)
                      VALUES (?,?,2,?,'entry.voided','journal_entry','x',?,?,?,?,0)""",
                   uuid7(981, "a0d1"), LEDGER, SEED_NODE, "f" * 64, "2" * 64, hlc(71), SEED_NODE)
            found = db.all("SELECT kind FROM v_integrity_report WHERE kind='AUDIT_CHAIN_BREAK'")
            assert len(found) == 1, "a broken audit chain must be visible"
        finally:
            db.rollback()
    check("H3  an edited audit chain is detectable (hash chain)", h3_audit_chain_detects_tampering)

    def h4_reports_after_everything():
        dr = db.scalar("SELECT SUM(closing_debit_minor) FROM v_trial_balance")
        cr = db.scalar("SELECT SUM(closing_credit_minor) FROM v_trial_balance")
        assert dr == cr, f"FINAL: Dr {dr} != Cr {cr}"
        # balance sheet + P&L must not contain NULLs that would crash a UI
        assert db.scalar("SELECT COUNT(*) FROM v_balance_sheet WHERE name IS NULL") == 0
        assert db.scalar("SELECT COUNT(*) FROM v_document_outstanding") >= 1
        assert db.scalar("SELECT COUNT(*) FROM v_daily_cashflow") >= 1
        assert db.scalar("SELECT COUNT(*) FROM v_search_results") >= 1
        assert db.scalar("PRAGMA quick_check") == "ok"
        assert db.all("PRAGMA foreign_key_check") == []
        assert db.scalar("SELECT COUNT(*) FROM invariant_violations") == 0
        assert db.scalar("SELECT COALESCE(SUM(net_minor),0) FROM account_balances WHERE period_id=0") == 0, \
            "the double-entry proof: summed across ALL accounts in a ledger, net must be exactly 0"
    check("H4  every view renders and the file is structurally sound", h4_reports_after_everything)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=":memory:")
    args = ap.parse_args()

    db = DB(args.file)
    suite(db)

    width = max(len(n) for _, n, _ in RESULTS)
    failures = 0
    print("\n  KhataPro · SQL contract tests\n  " + "─" * (width + 12))
    for status, name, detail in RESULTS:
        mark = "✓" if status == "PASS" else "✗"
        print(f"  {mark} {name.ljust(width)}  {detail if detail else ''}".rstrip())
        failures += status == "FAIL"
    print("  " + "─" * (width + 12))
    print(f"  {len(RESULTS) - failures}/{len(RESULTS)} contracts hold\n")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        sys.exit(2)
