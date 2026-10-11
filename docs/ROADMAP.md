# KhataPro — Delivery Roadmap

Each stage is shippable; nothing later invalidates anything earlier.
Status reflects what exists **in this workspace right now**.

---

## ✅ Deliverable 1 — Foundation (this drop)

| # | Item | Where | Verified |
|---|---|---|---|
| 1 | Project structure, 100+ files placed | whole repo | — |
| 2 | Locked dependency set + native setup | `pubspec.yaml`, `tool/setup_native.sh` | against Flutter 3.47.7 / Dart 3.13.5 |
| 3 | **Complete SQLCipher double-entry schema** (8 migrations) | `assets/sql/migrations/**` | 35/35 contract tests |
| 4 | Integrity gate + 15 invariants | `008_integrity.sql`, `ops/integrity_checks.sql` | gate proven to fire (E2, F3) |
| 5 | Maintenance ops (rebuild caches, rebuild search, prune) | `assets/sql/ops/**` | rebuild proves cache == derived |
| 6 | Contract test harness (no SDK needed) | `tool/sql_contract_test.py` | 35/35 |
| 7 | Scale benchmark | `tool/benchmark.py` | 51 k postings measured |
| 8 | Architecture + schema documentation | `docs/ARCHITECTURE.md`, `docs/DB_SCHEMA.md` | — |

## ✅ Deliverable 2 — Data layer in Dart — **delivered**

Read `docs/DATA_LAYER.md` for the layer-by-layer account and the evidence.
The headline numbers: **81/81** checks in `tool/data_layer_verify.dart`,
**16/16** in `flutter test`, **35/35** SQL contracts, `dart analyze` clean.

* `lib/data/db/database.dart` — Drift database with the SQLCipher `setup`
  (key from Keystore/Keychain), `onOpen` pragma application, migration runner
  that executes `assets/sql/migrations/*.sql` verbatim (single source of truth:
  the SQL you can read is the SQL that runs).
* DAOs: `journal_dao`, `party_dao`, `document_dao`, `item_dao`, `report_dao`,
  each with the `commitChecked()` helper (writes + gate + rollback).
* `lib/core/crdt/hlc.dart` — HLC encode/decode/merge with the contract-test
  vectors.
* `lib/core/money/money.dart` — `MoneyMinor` value type (int-backed, no
  doubles anywhere in the domain).
* `OrderBook` service: the only path that creates posted entries; allocates
  numbers, builds balanced lines, posts through the guarded transition.
* `test/core/crdt_merge_test.dart` — the merge contract: determinism,
  commutativity, replay-idempotence, tombstone rules, and the two undecidable
  cases (one blocking, one a warning).
* `test/data/integrity_severity_test.dart` — severity 1 = critical / 2 = warning
  is not inverted, and a warning never blocks a legitimate posting while a
  critical finding always rolls one back.
* `tool/data_layer_verify.dart` — 81 checks in 7 stages against a real encrypted
  SQLCipher file: boot, reopen and clock resume, the singleton rules, fail-closed
  encryption, migration guards, the OrderBook (post → gate → receipt, void,
  reversal inside a locked period, cache repair), and crash recovery.

| # | check | result |
| --- | --- | --- |
| 1 | SQL contracts, independent Python implementation | 35/35 |
| 2 | `tool/verify_schema.sh` | 35/35, 0 critical findings |
| 3 | `tool/data_layer_verify.dart` | **81/81** |
| 4 | `flutter test` | **16/16** |
| 5 | `tool/crdt_verify.dart` | 55/55 |
| 6 | `tool/crypto_verify.dart` · `tool/aes_verify.dart` | 72/72 · 27/27 |

## ⏭ Deliverable 3 — UI (Impeller, EN + UR)

* Design system: typography (Inter + Noto Nastaliq Urdu, RTL-correct),
  4/8 pt spacing scale, 12 semantic colours, light/dark.
* Screens in order of user value: Dashboard (today's sales, receivables
  collection rate), Party ledger (paged running balance), New sale (numpad-first
  flow, the 3-tap invoice), Purchases, Expenses, Items/stock, Reports
  (trial balance, P&L, party statement PDF), Settings/security.
* Performance guardrails enforced by review + a golden test: no `saveLayer`, no
  layout in `build` hot paths, `RepaintBoundary` on charts, `const` everywhere.

## ⏭ Deliverable 4 — BYOC backup

* Drive: OAuth via the user's own client id, `drive.file` + `appDataFolder`,
  pack chain upload/download, restore-with-verification.
* iCloud: ubiquity container, same pack format.
* Local file target (SD card / SAF) for users with no cloud at all.
* Recovery phrase (BIP-39, Argon2id wrap) + `recovery_guard` flows.

## ⏭ Deliverable 5 — P2P sync

* mDNS advert/discover, QR pairing with Ed25519 pinning, WebRTC data channel
  transport with MTU-aware chunking and backpressure.
* Apply pipeline: `BEGIN → write_mode='sync' → INSERT OR IGNORE → gate →
  COMMIT`, wired to `sync_cursors` and the oplog.
* Snapshot/merkle fast path for long-separated devices.
* The chaos suite (`integration_test/sync_chaos_test.dart`) must pass before
  this ships: random reordering, duplicate delivery, mid-batch kills, ±2 h
  clock skew, replayed history.

## ⏭ Deliverable 6 — Scale & trust features

* Year-end rollover with signed archives (see ARCHITECTURE.md §8).
* Bank reconciliation screen, recurring rules UI, reminders via
  `flutter_local_notifications` + `timezone`.
* Receipt OCR (on-device), e-invoicing (FBR/IRIS) fields already in the schema.
* Play/App Store release: 16 KB page alignment, no-backup flag, data-safety
  forms, privacy policy that states plainly "we have no servers".

## Deliberate non-goals

* No multi-currency consolidation into a single P&L (single base currency per
  ledger, FX revaluation only as an explicit entry).
* No payroll/tax filing automation — we store the numbers correctly and export
  them; statutory filing is a legal service, not an app feature.
* No web dashboard. It would require a server. That is the one thing this
  product cannot have.
