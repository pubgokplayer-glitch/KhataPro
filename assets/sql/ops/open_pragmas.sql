-- ═══════════════════════════════════════════════════════════════════════════
--  ops/open_pragmas.sql — applied by Database.onOpen (lib/data/db/database.dart)
--  on EVERY connection open, before any read or write.
--
--  These settings are the difference between "SQLCipher is 5–15 % slower" and
--  "SQLCipher is faster than an unencrypted default-configured SQLite". The
--  encryption cost is CPU per page touched; almost everything below is about
--  touching fewer pages, in bigger and more sequential runs.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1 · Durability & concurrency ──────────────────────────────────────────
-- WAL: readers never block the writer, and the UI keeps scrolling while a
-- save happens. synchronous=NORMAL is safe under WAL (the DB cannot corrupt on
-- power loss; only the very last transaction can be lost) and avoids an fsync
-- per commit — the single biggest write win on Android eMMC/UFS storage.
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA wal_autocheckpoint = 512;      -- pages; keeps the -wal file small on 32-bit phones
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;
PRAGMA recursive_triggers = ON;       -- required: our trigger chain depends on it

-- ── 2 · The encryption tax: pay it on fewer, larger I/Os ─────────────────
-- 4 KiB pages are the SQLCipher default; on modern flash 4 KiB is already the
-- physical unit, and 1 KiB pages would double the PBKDF2/HMAC work per byte.
PRAGMA page_size = 4096;
-- 16 MiB page cache ≈ 4096 pages. Every cache hit is a decrypt we never pay
-- for twice; every miss is a SQLCipher page decrypt plus PVFS overhead.
PRAGMA cache_size = -16000;
-- Memory-map the database file. mmap is the closest thing to "free decryption"
-- we can get: pages arrive through the page cache without a syscall per read.
PRAGMA mmap_size = 268435456;         -- 256 MiB; ignored where unsupported
PRAGMA temp_store = MEMORY;           -- sorts/aggregates never hit disk
PRAGMA cache_spill = OFF;             -- a spill is 1 extra encrypted write

-- ── 3 · Plan stability for a book that grows for a decade ────────────────
PRAGMA analysis_limit = 400;          -- PRAGMA optimize stays cheap & bounded
PRAGMA automatic_index = OFF;         -- we index every hot path by hand; a
                                      -- surprise auto-index is an unplanned write

-- ── 4 · Session markers written by the app once these are applied ────────
--   UPDATE session_flags SET value = <new uuid> WHERE key = 'session_id';
--   UPDATE session_flags SET value = 'user'     WHERE key = 'write_mode';
--   UPDATE session_flags SET value = <epoch-day in the LEDGER's timezone>
--     WHERE key = 'today_epoch_day';   -- and month_start, fy_start likewise
-- The session_id change invalidates any balance_audit rows left behind by a
-- crashed run, so a stale scratch pad can never poison the next transaction.
