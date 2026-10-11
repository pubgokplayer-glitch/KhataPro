#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tool/verify_schema.sh — prove the database layer before you trust the app.
#
#  Runs the real migration files against a real SQLite build and asserts the
#  ledger invariants (35 contracts), then optionally benchmarks scale.
#  No Flutter toolchain required — pure stdlib Python, so it runs in any CI.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MIGRATIONS=$(ls "$ROOT/assets/sql/migrations"/*.sql | wc -l | tr -d ' ')
echo "▶ 1/4 · applying all $MIGRATIONS migrations to a scratch file"
python3 - <<'PY'
import glob, pathlib, sqlite3, sys
db = "/tmp/khata_schema_check.sqlite"
pathlib.Path(db).unlink(missing_ok=True)
c = sqlite3.connect(db, isolation_level=None)
c.execute("PRAGMA foreign_keys = ON")
for f in sorted(glob.glob("assets/sql/migrations/*.sql")):
    c.executescript(pathlib.Path(f).read_text())
print(f"   ok · {c.execute('SELECT COUNT(*) FROM sqlite_master').fetchone()[0]} schema objects, "
      f"{c.execute('SELECT COUNT(*) FROM accounts').fetchone()[0]} seeded accounts, "
      f"quick_check={c.execute('PRAGMA quick_check').fetchone()[0]}")
PY

echo "▶ 2/4 · contract tests (double entry, CRDT replay, caches, FTS, gate)"
python3 tool/sql_contract_test.py

echo "▶ 3/4 · full integrity sweep on the scratch file"
python3 - <<'PY'
import sqlite3
c = sqlite3.connect("/tmp/khata_schema_check.sqlite", isolation_level=None)
rows = c.execute("SELECT severity, kind, detail FROM v_integrity_report").fetchall()
bad = [r for r in rows if r[0] == 1]
print(f"   critical findings: {len(bad)}")
for r in bad[:10]:
    print("   ✗", r[1], r[2])
raise SystemExit(1 if bad else 0)
PY

if [ "${1:-}" = "--bench" ]; then
  echo "▶ 4/4 · scale benchmark (20 000 entries / ~51 000 postings)"
  python3 tool/benchmark.py --entries 20000
else
  echo "▶ 4/4 · skipped benchmark (pass --bench to run it)"
fi

echo "✔ schema verified"
