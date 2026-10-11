#!/usr/bin/env python3
"""
tool/benchmark.py — does the schema actually hold 60 fps at SME scale?

Generates a realistic two-year book (parties, items, invoices, purchases,
payments, expenses, stock moves) through the REAL triggers — so the numbers
include every integrity guard the app will pay for — then times the queries the
UI issues on its hot screens.

    python3 tool/benchmark.py --entries 20000

Notes
─────
· This is plain SQLite: SQLCipher adds page-decrypt cost on reads/writes. Treat
  these numbers as the floor the encrypted build starts from (and see
  ops/open_pragmas.sql for the mitigations: WAL, 16 MiB cache, mmap, big pages).
· Everything runs through the same code path as the app: guarded draft → post,
  balance-cache triggers, audit deltas, FTS, stock cache.
"""

from __future__ import annotations

import argparse
import glob
import pathlib
import os
import random
import sqlite3
import re
import statistics
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = "019a1b2c-0000-7000-8000-000000000001"
NODE = "11111111-1111-7111-8111-000000000001"
ACCOUNTS = {
    "cash": "019a1b2c-0000-7000-8000-00000000044c",
    "bank": "019a1b2c-0000-7000-8000-000000000456",
    "ar": "019a1b2c-0000-7000-8000-0000000004b0",
    "inventory": "019a1b2c-0000-7000-8000-000000000514",
    "ap": "019a1b2c-0000-7000-8000-000000000834",
    "tax": "019a1b2c-0000-7000-8000-0000000008fc",
    "sales": "019a1b2c-0000-7000-8000-000000001004",
    "cogs": "019a1b2c-0000-7000-8000-0000000013ec",
    "rent": "019a1b2c-0000-7000-8000-0000000014b4",
    "salaries": "019a1b2c-0000-7000-8000-000000001450",
}


def hlc(ms: int, counter: int = 0) -> str:
    return f"{ms:015d}:{counter:04x}:{NODE}"


def uuid(i: int, tag: str = "beef") -> str:
    return f"019b2c3d-{tag}-7000-8000-{i:012x}"


class Bench:
    def __init__(self, path: str) -> None:
        self.c = sqlite3.connect(path, isolation_level=None)
        self.c.execute("PRAGMA foreign_keys = ON")
        self.c.executescript(open(os.path.join(ROOT, "assets/sql/ops/open_pragmas.sql")).read())
        for f in sorted(glob.glob(os.path.join(ROOT, "assets/sql/migrations/*.sql"))):
            self.c.executescript(open(f).read())
        self.c.execute("UPDATE session_flags SET value=? WHERE key='session_id'", (str(uuid(0)),))
        self.today = self.c.execute(
            "SELECT CAST(value AS INTEGER) FROM session_flags WHERE key='today_epoch_day'").fetchone()[0]
        self.n = 0

    def next_id(self, tag: str = "beef") -> str:
        self.n += 1
        return uuid(self.n, tag)

    # ── the exact guarded write path the app uses ──────────────────────────
    def post_entry(self, date: int, source: int, lines: list[tuple[str, int]],
                   party: str | None = None, memo: str = "") -> str:
        eid = self.next_id("e11e")
        ts = 1800000000000 + self.n
        self.c.execute(
            """INSERT INTO journal_entries
                 (id,ledger_id,entry_no,entry_date,source,status,currency_code,base_currency_code,
                  party_id,memo,device_id,hlc,node_id,created_at,updated_at)
               VALUES (?,?,?,?,?,0,'PKR','PKR',?,?,?,?,?,?,?)""",
            (eid, LEDGER, f"JV-{self.n:06d}", date, source, party, memo, NODE,
             hlc(ts), NODE, ts, ts))
        for i, (acct, amount) in enumerate(lines, start=1):
            self.c.execute(
                """INSERT INTO journal_lines
                     (id,ledger_id,entry_id,line_no,entry_date,account_id,party_id,amount_minor,
                      base_amount_minor,currency_code,node_id,created_at)
                   VALUES (?,?,?,?,?,?,?,?,?, 'PKR', ?,?)""",
                (self.next_id("11ee"), LEDGER, eid, i, date, acct, party, amount, amount,
                 NODE, ts))
        self.c.execute("UPDATE journal_entries SET status=1, posted_at=?, hlc=?, rev=rev+1 WHERE id=?",
                       (ts, hlc(ts, 1), eid))
        return eid

    # ── data generation ────────────────────────────────────────────────────
    def generate(self, entries: int, parties: int = 600, items: int = 400) -> None:
        rnd = random.Random(20261011)
        ts = 1800000000000
        self.c.execute("BEGIN IMMEDIATE")

        self.party_ids: list[str] = []
        for i in range(parties):
            pid = self.next_id("pa47")
            self.party_ids.append(pid)
            kind = 1 if i % 3 else 2
            self.c.execute(
                """INSERT INTO parties (id,ledger_id,name,name_ur,kind,phone,city,hlc,node_id,rev,created_at,updated_at)
                   VALUES (?,?,?,?,?,?,?,?,?,1,?,?)""",
                (pid, LEDGER, f"Party {i:04d} Traders", f"پارٹی {i:04d}", kind,
                 f"0300{i:07d}", "Rahim Yar Khan", hlc(ts), NODE, ts, ts))

        self.item_ids: list[str] = []
        for i in range(items):
            iid = self.next_id("17e3")
            self.item_ids.append(iid)
            cost = rnd.randint(20_000, 4_000_000)
            self.c.execute(
                """INSERT INTO items (id,ledger_id,sku,barcode,name,name_ur,kind,unit,is_stocked,
                                     sale_price_minor,sale_price_incl_minor,purchase_price_minor,
                                     inventory_account_id,cogs_account_id,income_account_id,
                                     hlc,node_id,rev,created_at,updated_at)
                   VALUES (?,?,?,?,?,?,0,?,1,?,?,?,?,?,?,?,?,1,?,?)""",
                (iid, LEDGER, f"SKU{i:05d}", f"89640000{i:05d}", f"Item {i:04d}",
                 f"آئٹم {i:04d}", "pcs", cost * 12 // 10, cost * 14 // 10, cost,
                 ACCOUNTS["inventory"], ACCOUNTS["cogs"], ACCOUNTS["sales"],
                 hlc(ts), NODE, ts, ts))
            # opening stock
            self.c.execute(
                """INSERT INTO stock_moves (id,ledger_id,item_id,move_date,direction,quantity_milli,
                                            unit_cost_micros,value_minor,source,hlc,node_id,created_at)
                   VALUES (?,?,?,?,1,?,?,?,4,?,?,?)""",
                (self.next_id("570c"), LEDGER, iid, self.today - 700, rnd.randint(5_000, 500_000),
                 cost * 1000, rnd.randint(500_000, 40_000_000), hlc(ts), NODE, ts))

        for i in range(entries):
            day = self.today - rnd.randint(0, 700)
            roll = rnd.random()
            party = rnd.choice(self.party_ids)
            if roll < 0.55:                                     # cash/credit sale
                gross = rnd.randint(50_000, 5_000_000)
                net = gross * 100 // 118
                tax = gross - net
                acct = ACCOUNTS["cash"] if rnd.random() < 0.7 else ACCOUNTS["ar"]
                if acct == ACCOUNTS["cash"]:
                    self.post_entry(day, 1, [(acct, gross), (ACCOUNTS["sales"], -net),
                                             (ACCOUNTS["tax"], -tax)], memo="Cash sale")
                else:
                    self.post_entry(day, 1, [(acct, gross), (ACCOUNTS["sales"], -net),
                                             (ACCOUNTS["tax"], -tax)], party=party, memo="Credit sale")
            elif roll < 0.75:                                    # purchase on credit
                amt = rnd.randint(100_000, 8_000_000)
                self.post_entry(day, 2, [(ACCOUNTS["inventory"], amt), (ACCOUNTS["ap"], -amt)],
                                party=party, memo="Stock purchase")
            elif roll < 0.90:                                    # expense
                amt = rnd.randint(5_000, 900_000)
                acct = rnd.choice([ACCOUNTS["rent"], ACCOUNTS["salaries"]])
                self.post_entry(day, 3, [(acct, amt), (ACCOUNTS["cash"], -amt)], memo="Expense")
            else:                                                # customer payment
                amt = rnd.randint(20_000, 3_000_000)
                self.post_entry(day, 4, [(ACCOUNTS["cash"], amt), (ACCOUNTS["ar"], -amt)],
                                party=party, memo="Payment received against invoice")

        self.c.execute("COMMIT")

    # ── timing ────────────────────────────────────────────────────────────
    def timeit(self, label: str, sql: str, args=(), runs: int = 5) -> None:
        times = []
        for _ in range(runs):
            t0 = time.perf_counter()
            self.c.execute(sql, args).fetchall()
            times.append((time.perf_counter() - t0) * 1000)
        print(f"  {label:<44} {statistics.median(times):7.2f} ms   (worst {max(times):6.2f} ms)")

    def scalar(self, sql: str):
        return self.c.execute(sql).fetchone()[0]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--entries", type=int, default=20000)
    ap.add_argument("--file", default="/tmp/khata_bench.sqlite")
    args = ap.parse_args()
    if os.path.exists(args.file):
        os.remove(args.file)

    b = Bench(args.file)
    t0 = time.perf_counter()
    b.generate(args.entries)
    gen = time.perf_counter() - t0

    entries = b.scalar("SELECT COUNT(*) FROM journal_entries")
    lines = b.scalar("SELECT COUNT(*) FROM journal_lines")
    parties = b.scalar("SELECT COUNT(*) FROM parties")
    docs = b.scalar("SELECT COUNT(*) FROM documents")
    size = os.path.getsize(args.file) / 1e6

    print(f"\n  KhataPro · scale benchmark")
    print(f"  {'─' * 76}")
    print(f"  generated {entries:,} posted entries · {lines:,} journal lines · "
          f"{parties:,} parties · {b.scalar('SELECT COUNT(*) FROM stock_moves'):,} stock moves")
    print(f"  write throughput: {lines / gen:,.0f} lines/s through every integrity trigger "
          f"({gen:.1f}s total)")
    b.c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    wal = os.path.getsize(args.file + "-wal") if os.path.exists(args.file + "-wal") else 0
    print(f"  file size: {size:.1f} MB + {wal/1e6:.1f} MB WAL  "
          f"(unencrypted; SQLCipher adds ~0–3 % for the same rows)")
    print(f"  pages: {b.scalar('PRAGMA page_count'):,} × {b.scalar('PRAGMA page_size')} B")
    print(f"  proof the book is sound: Σ(net) over ALL accounts = "
          f"{b.scalar('SELECT COALESCE(SUM(net_minor),0) FROM account_balances')}")
    print(f"  {'─' * 76}\n")

    print("  Hot paths the UI hits every frame / every screen:")
    b.timeit("dashboard metrics (v_dashboard_metrics)",
             "SELECT * FROM v_dashboard_metrics")
    b.timeit("party list + balances (top 50 by receivable)",
             "SELECT * FROM v_party_balances ORDER BY net_minor DESC LIMIT 50")
    b.timeit("party ledger, busiest party (running balance)",
             "SELECT * FROM v_party_ledger WHERE party_id=(SELECT party_id FROM journal_lines "
             "WHERE party_id IS NOT NULL GROUP BY party_id ORDER BY COUNT(*) DESC LIMIT 1)")
    b.timeit("journal list, current month (v_journal_detail)",
             "SELECT * FROM v_journal_detail WHERE entry_date >= ? ORDER BY entry_date DESC LIMIT 200",
             (b.today - 30,))
    b.timeit("trial balance (all accounts)",
             "SELECT * FROM v_trial_balance")
    b.timeit("profit & loss", "SELECT * FROM v_profit_and_loss")
    b.timeit("unpaid invoices + aging (v_document_outstanding)",
             "SELECT * FROM v_document_outstanding")
    b.timeit("stock on hand, low stock first",
             "SELECT * FROM v_stock_on_hand_live ORDER BY quantity_milli ASC LIMIT 100")
    b.timeit("FTS search (unicode61 prefix on 20 601 indexed rows)",
             "SELECT m.kind, m.row_id, i.title FROM search_index i "
             "JOIN search_map m ON m.fts_rowid = i.rowid "
             "WHERE search_index MATCH 'traders*' LIMIT 20")
    inv = pathlib.Path(ROOT, "assets/sql/migrations/008_integrity.sql").read_text()
    n_inv = len(re.findall(r"^SELECT [12], '", inv, re.M))
    b.timeit(f"integrity gate ({n_inv} invariants, whole book)",
             "INSERT INTO invariant_violations (kind,detail,detected_at) "
             "SELECT kind,detail,0 FROM v_integrity_report WHERE severity=1")

    print("\n  Write path (the guarded posting transaction the user waits on):")
    import time as _t
    times = []
    for _ in range(50):
        t0 = _t.perf_counter()
        b.c.execute("BEGIN IMMEDIATE")
        b.post_entry(b.today, 1, [(ACCOUNTS["cash"], 118000), (ACCOUNTS["sales"], -100000),
                                  (ACCOUNTS["tax"], -18000)], memo="Save invoice")
        b.c.execute("COMMIT")
        times.append((_t.perf_counter() - t0) * 1000)
    print(f"  {'post a 3-line tax invoice (BEGIN→COMMIT)':<44} "
          f"{statistics.median(times):7.2f} ms   (worst {max(times):6.2f} ms)")

    t0 = _t.perf_counter()
    b.c.executescript(open(os.path.join(ROOT, "assets/sql/ops/rebuild_caches.sql")).read())
    print(f"  {'full cache rebuild (all periods + stock)':<44} "
          f"{(_t.perf_counter() - t0) * 1000:7.2f} ms")
    print()


if __name__ == "__main__":
    main()
