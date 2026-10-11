# KhataPro — Architecture

**Zero servers. Zero cost. Offline-first. Double-entry. Encrypted at rest.**
This document records the decisions and the numbers behind them, so the next
engineer can change the code without breaking the invariants.

---

## 1 · The cost model (what "zero cost" actually constrains)

| Layer | Component | Who pays | Failure mode we designed out |
|---|---|---|---|
| Storage of record | SQLCipher file inside the app sandbox | nobody | no row/request billing, no quota to exceed |
| Device sync | WebRTC data channels on the LAN | nobody | no signaling server, no TURN relay, no per-MAU fee |
| Backup | Google Drive `drive.file` scope, or iCloud ubiquity container | **the user's own free quota** | we never hold a bucket, a key, or a bill |
| Auth | the OS (Android Keystore / iOS Keychain) | nobody | no identity provider to pay or to lose |
| Analytics/crash | opt-in, self-hosted or off | nobody | no SaaS SDK phoning home by default |
| Compute | the phone's own CPU | the user's battery | no serverless bill that scales with success |

**The rule that keeps it true:** no code path may require a network round-trip
to complete a user's action. Network is an *optimisation and a safety net*
(backup, peer catch-up), never a dependency. Every feature must be fully
testable in airplane mode — `test/integration/offline_test.dart` enforces it.

## 2 · Data flow (offline-first, one source of truth)

```
UI (Riverpod streams) ── watch ──▶ Drift SQL (SQLCipher, WAL)
      ▲                                   │ triggers: double-entry law,
      │                                   │ balance cache, audit deltas, FTS
      └──── reactive invalidation ────────┘
                 │
      ┌──────────┴──────────┐
      ▼                     ▼
 oplog (local)        attachments vault
      │                     │
      ├─▶ LAN peer sync (WebRTC/DTLS, mDNS, QR pairing)
      └─▶ BYOC snapshot packs (Drive / iCloud / SD card)
```

* The database is authoritative. Dart objects are transient views of it.
* All writes go through `OrderBook` (a domain service), never straight to
  tables: it allocates numbers, builds balanced line sets, and commits with the
  integrity gate.
* Reads are Drift `watch()` streams → SQLite writes invalidate exactly the
  affected queries. No manual cache invalidation anywhere in the app.

## 3 · CRDT design (why two devices merge losslessly without a server)

**Stamp.** Every mutable replicated row carries an HLC:
`PPPPPPPPPPPPPPP:CCCC:NNNNNNNN-NNNN-NNNN-NNNN-NNNNNNNNNNNN`
(15-digit fixed-point ms, 4-hex counter, node UUID = 57 chars). Fixed width +
zero padding ⇒ SQLite's default BINARY collation compares it exactly as causal
time compares it, so a "delta since" query is a single index range scan with no
custom collation and no per-row parsing.

**Three merge rules cover the entire schema:**

1. **Append-only tables** (`journal_entries` money fields, `journal_lines`,
   `stock_moves`, `payment_allocations`, `fx_rates`, `balance_snapshots`,
   `audit_log`): merge = **set union keyed by UUIDv7 pk**. Idempotent,
   commutative, associative → *any* interleaving of *any* number of devices
   converges, and a replay is a no-op (contract test F2 proves it). This is the
   payoff of immutable postings: the hardest part of sync becomes the easiest.
2. **Mutable tables** (`parties`, `items`, `accounts`, `documents`,
   `document_lines`, settings, reminders, recurring rules): merge =
   **last-writer-wins on `(hlc, node_id)`**. Including the node id makes ties
   *deterministic* instead of "whoever happened to write to the local file", so
   A→B→A re-syncs are byte-identical and never flap.
3. **Derived data** (`account_balances`, `stock_on_hand`, `search_index`,
   `period` rows): **never replicated**. Each device recomputes it from rules
   1–2 (or receives a signed snapshot). Losing it is an inconvenience, not a
   loss — `assets/sql/ops/rebuild_caches.sql` reconstructs it bit-exactly.

**Deletes** are tombstones (`deleted_at` + an oplog `op = 2` row), never
destructive SQL, so a stale peer cannot resurrect a deleted row.

**Conflict receipts.** LWW discards the losing value on purpose; hiding that
would be how users stop trusting the app. Every overwrite is recorded in
`conflict_log` with both versions and both HLCs, surfaced as a dismissible
review card ("Ahmed's phone changed the phone number at 4:12 pm; your edit from
4:15 pm won"). Losing side only, pruned after review.

**Deterministic seeds.** The chart of accounts, taxes and currencies use
hard-coded ids derived from account codes with a zero HLC. Two devices
installed independently converge on that data *without exchanging a byte*, and
any user edit (real HLC) beats the seed on every peer. No seed-merge code path
exists to get wrong.

**Clock sanity.** A device whose clock is wrong can only win LWW earlier than
it should; it can never *lose* correctly-ordered history, because ordering is
HLC (physical ms, counter, node) and never wall-clock `datetime('now')`. The
HLC also never moves backwards: on open and on each write it is
`max(local_physical, last_seen_physical)`, so receiving a future-stamped peer
op does not corrupt subsequent local stamps.

**Catch-up without a server (snapshot protocol).**
`balance_snapshots` carries a merkle root over the ops folded into each
account's balance as of a date. When two devices pair after months apart:
1. exchange snapshots for each account;
2. where roots match, that history is provably identical → never transferred;
3. transfer only the op range above the snapshot, plus a rolling hash chain
   (`audit_log.hash_prev/hash_self`) to detect tampering;
4. run the integrity gate over the applied batch, then commit — or roll back
   the whole batch and report which invariant failed.

Measured effect: a two-year book (~51 000 postings) pairs in seconds on a
phone hotspot instead of pushing ~50 MB over Wi-Fi Direct.

**Garbage collection.** Pruning is bounded by the *minimum* cursor across
trusted peers (`assets/sql/ops/prune.sql`), so a device that has been offline
for six months still gets its deltas. Tombstones are kept for the same horizon.

## 4 · LAN peer sync over WebRTC (no signaling server, no TURN)

* **Discovery:** mDNS/DNS-SD (`_khata-sync._tcp`). Peers on the same Wi-Fi
  find each other. No directory service exists in this design.
* **Pairing:** one device shows a QR containing `{node_id, display_name,
  ephemeral_pubkey, session_salt}`. The other scans it and opens a WebRTC
  offer directly to the hinted address. The QR *is* the out-of-band channel —
  that is why no signaling server is needed.
* **Trust:** the pairing exchange pins the peer's Ed25519 public key (TOFU).
  Later sessions are rejected unless the peer proves possession of the pinned
  key, so a hostile device on the same café Wi-Fi cannot impersonate the
  shop's second phone. `sync_peers.trust_state` + `pinned_pubkey` are
  per-device and never sync (a trust list that travels is a security hole).
* **Transport:** `RTCDataChannel` (DTLS-encrypted, ordered). Application
  framing adds length-prefixed JSON chunks sized to the negotiated MTU with
  backpressure on `bufferedAmount` — no TCP-over-DataChannel hand-rolling.
* **Apply protocol:** every batch is
  `BEGIN IMMEDIATE → write_mode='sync' → INSERT OR IGNORE … → integrity gate →
  COMMIT`, in one transaction. A peer cannot inject an unbalanced entry, a
  cross-ledger line, or a stale overwrite: the same triggers that guard local
  writes guard remote ones, and the batch dies atomically if anything is off.
* **No internet?** Fall back to QR file handoff or the Drive/iCloud relay:
  same op format, worse latency. Cellular is never required.

## 5 · Bring Your Own Cloud (backup)

**Pack format (`KPB1`)** — a `tar` + `gzip` of AES-256-GCM encrypted chunks:
```
manifest.json      { version, ledger_ids, from_hlc, to_hlc, op_count,
                     merkle_root, prev_pack_id, created_at, device_name,
                     key_fingerprint, kdf: "argon2id(m=64MiB,t=3,p=1)" }
ops_0001.jsonl.enc op batches, each with an HMAC-SHA256 tag
caches/balances.enc signed account_balances + stock_on_hand snapshot
attachments/…      optional, opt-in, encrypted per-blob
```
* A **chain** (`prev_pack_id`) keeps packs ordered; `checkpoint_days = 7`
  writes a full checkpoint, so worst-case restore replays ≤ 7 days of ops.
* **Google Drive (Android + everywhere):** `drive.file` scope only — the app
  can see nothing but the folder it creates, and it uses `appDataFolder` so the
  user's Drive UI stays clean. The OAuth client is *yours*; the storage is
  *theirs*. No API keys of ours ship in the binary.
* **iCloud (iOS/macOS):** the app's ubiquity container
  (`iCloud.<bundle-id>`), covered by the user's existing 5 GB free tier.
* **Restore:** download → verify each chunk's GCM tag → verify the merkle root
  against the manifest → apply `write_mode='sync'` → integrity gate → commit.
  A tampered or truncated pack therefore restores *nothing*, rather than half a
  ledger.
* **Key continuity is the real risk, not storage.** The DEK is wrapped for the
  OS keychain on the device; a *recovery phrase* wraps the same DEK with
  Argon2id so a new phone can restore. `recovery_guard` blocks the
  "forgot PIN → wipe" flow unless a verified backup exists or the phrase is
  entered — the single most destructive bug class in this app category.

## 6 · Security at the hardware level

```
user biometrics / PIN  (local_auth)
        │ gates
Android Keystore / iOS Keychain   ← hardware-backed, non-exportable
        │ wraps (AES-256-GCM)
Data Encryption Key (DEK, 32 random bytes)
        │  HKDF-SHA256
   ┌────┴───────────────┬────────────────────┐
   ▼                    ▼                    ▼
SQLCipher key       vault DEK           pack DEK   (independent derivations)
(DB pages)       (attachments)        (Drive/iCloud)
```
* **SQLCipher 4, 256-bit AES.** What SQLCipher is handed is decided by the custody
  level, and the two cases are genuinely different — conflating them was a mistake
  in an earlier draft of this document:
  * **Hardware custody (the normal case).** A **random 32-byte DEK** generated on
    the device, wrapped by an Android Keystore / iOS Secure Enclave key (see
    `lib/platform/security/`), and passed to SQLCipher as a raw key —
    `PRAGMA key = "x'<64 hex>'"`. No SQLCipher KDF runs at all in this path, which
    is why opening the database is milliseconds rather than a second. Argon2id has
    nothing to do with this key: a random key needs no stretching.
  * **Passphrase custody (fallback, or the user's choice).** The DEK is wrapped by
    a KEK derived with **Argon2id** (`m = 64 MiB, t = 3, p = 1`, lanes 1 — more
    lanes help a server, not a phone). Argon2id is applied to the *passphrase*, in
    `lib/core/security/kdf.dart`; it wraps the DEK, and the DEK is what SQLCipher
    receives. Parameters live in `key_material.kdf_params` so they can be re-tuned
    without a migration.
  * A KEK passphrase handed to SQLCipher *as a passphrase* is the last resort: then
    SQLCipher runs its own PBKDF2-HMAC-SHA512 (256 000 rounds), which is exactly the
    per-open cost the singleton connection exists to avoid.
* **Domain separation by HKDF-SHA256.** The vault DEK (attachments, Deliverable 5)
  and the backup pack keys (Deliverable 3) are derived from their own wrapping keys
  — never from the DB DEK — with distinct `info` strings, so a leaked pack key tells
  an attacker nothing about the database. See `lib/sync/backup/kpb1_format.dart`
  (`khata-pro/kpb1/mac/v1`) and `lib/sync/transport/qr_pairing.dart`
  (`khata-pro/pairing/sas/v1`).
* `PRAGMA cipher_memory_security = ON` while unlocked; keys are zeroed on lock.
* **Screenshots:** `FLAG_SECURE` (Android) and a blur overlay on
  `applicationWillResignActive` (iOS) hide amounts in the recents thumbnail.
* **Backups excluded from OS copies:** `android:allowBackup="false"` and
  `NSURLIsExcludedFromBackupKey` on the DB file. An encrypted database without
  its key in a cloud backup is either useless or a liability; we pick useless.
* **Threat model, honestly stated:** protects against a stolen/lost phone,
  casual ADB/file access, and a malicious app on the same device. It does *not*
  protect against a rooted phone with the user's biometrics, or against a user
  who shares their unlocked device — no client-only design can, and pretending
  otherwise would be dishonest.

## 7 · Performance: the frame budget is a design constraint, not a hope

**Rendering (Impeller).** Flutter 3.47 with Impeller on both platforms.
Rules enforced by review: no `saveLayer`, no `Opacity` on scrolling subtree
roots (use `AnimatedOpacity`/colours), `const` constructors everywhere,
`RepaintBoundary` around charts, `SliverList`/`ListView.builder` with stable
keys, and image decode off the UI isolate (`flutter_image_compress` before
encryption, so a 4 MB receipt never becomes a 4 MB decrypt).

**Data.** Measured on a 20 000-entry / 51 009-posting book (2 years of a busy
shop, `tool/benchmark.py`) — plain SQLite, so **SQLCipher only adds page-decrypt
cost on top**:

| Path | Median | Notes |
|---|---|---|
| Dashboard (one row, everything) | **4.3 ms** | ledger-scoped, covering index |
| Trial balance / P&L | **0.1 ms** | reads the audited balance cache |
| Post a 3-line tax invoice (BEGIN→COMMIT) | **0.4 ms** | through every integrity trigger |
| Journal list, current month (200 rows) | 24 ms | paged; renders from memory |
| Party list + balances (600 parties) | 28 ms | paginate ≥ 2 000 parties |
| Party ledger, busiest party | 109 ms | **must** be paged (see below) |
| FTS search | 1.1 ms | 20 601 indexed rows |
| Integrity gate, whole book | 276 ms | nightly/on-demand only |
| Full cache rebuild | 1.06 s | nightly |
| Write throughput | 9 349 lines/s | generation run, triggers on |

**The pagination pattern that matters** (do not skip it): the running balance in
a party ledger is O(history). The app loads a page of 200 rows and computes the
opening balance from the cache
(`accounts[ar].net_minor − Σ(lines newer than the page)`), so the window
function only ever runs over ≤ 200 rows — 109 ms becomes ~2 ms regardless of
how long the customer has been trading. `v_party_ledger` is the *reference*
implementation; the paged DAO is the production path.

**Mitigating the SQLCipher tax** (directive #5), all of it measured:
singleton writer connection (one page cache, one cipher context — no
multi-connection re-decrypt); every write wrapped in `BEGIN IMMEDIATE` batches;
`journal_mode=WAL`, `synchronous=NORMAL`, 16 MiB cache, 256 MiB mmap, 4 KiB
pages, `temp_store=MEMORY` (`assets/sql/ops/open_pragmas.sql`); and index
discipline — indexes were **2.5× the size of the ledger data** in the first cut
(79.4 MB for 51 009 lines). Removing four indexes whose leading columns were
duplicated by wider ones, dropping redundant composite unique keys, and removing
the per-line HLC (a line has no independent existence) took the same book to
**51.9 MB (−35 %)**, cut the `journal_lines` index-to-data ratio from 2.5× to
1.3×, and left every latency equal or better. Bytes on disk are CPU under
SQLCipher: fewer pages = less decryption. `dbstat` ranks objects by size, so
this audit is a repeatable step rather than a one-off — run it whenever a
migration adds an index.

## 8 · Living within a phone for ten years

A shop writing 60 vouchers/day ≈ 150 lines/day ≈ 55 MB/year at the measured
1 KB/line — so a single phone cannot hold a decade of line-level detail, and
pretending otherwise would be the kind of claim that fails at year four.

**Retention design (Phase 3):** year-end rollover.
1. On demand (never silently), close a financial year: write a signed archive
   pack of that year's entries, verify it by restoring it into a scratch
   database, *then* replace the detail with a single opening-balance entry
   (`source = 7`, `is_opening = 1`, dated the first day of the new year).
2. The archive keeps the full audit trail (hash chain + merkle root); the live
   file keeps balances, the current year, and any open documents.
3. The app always shows "archived: FY2026 · verified 2026-07-01" so nothing is
   hidden, and a restore can bring any archived year back.
Result: a steady-state database in the tens of megabytes, not the hundreds.

## 9 · Testing strategy (the parts that must never regress)

| Layer | Tool | What it protects |
|---|---|---|
| Schema contracts | `tool/sql_contract_test.py` (35 tests, no SDK needed) | double-entry law, immutability, CRDT replay idempotence, cache audit + repair, FTS, gate |
| Integrity sweep | `assets/sql/ops/integrity_checks.sql` | 15 critical invariants + 6 warnings, runnable from a SQL console |
| Unit | Dart + `mocktail` | money math, HLC ordering, document totals, allocation logic |
| Widget | `flutter_test` golden files | receipt/invoice layout in EN + UR (RTL, Nastaliq line height) |
| Integration | `integration_test/offline_test.dart` | airplane-mode parity: every feature works with no network |
| Chaos | `integration_test/sync_chaos_test.dart` | random op reordering, duplicate delivery, interrupted batches, clock skew ±2 h, mid-sync kill |
| Scale | `tool/benchmark.py` | regressions in the hot paths above, re-run per release |

The chaos suite is the one that earns the "no data loss" claim: it drives two
simulated nodes through thousands of randomised interleavings and asserts that
both converge to identical balances — which is exactly what the CRDT rules
promise.
