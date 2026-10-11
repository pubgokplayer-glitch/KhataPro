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

## ✅ Deliverable 3 — Platform security bindings, BYOC backup, LAN sync — **delivered**

Read `docs/SYNC.md` for the full account. The headers: **54/54** checks in
`tool/security_verify.dart`, **133/133** in `tool/sync_verify.dart`, the whole
Deliverable 2 suite re-run green after the changes, and **every file in `lib/`
type-checked** — including the five that import Flutter and a plugin, which are checked
against signature stubs transcribed from the pinned package versions
(`tool/plugin_stubs/`, see `docs/SYNC.md` §5.1).

* **Platform security bindings** — `lib/platform/security/`: the custody ladder
  (hardwareBiometric → hardwareDevice → passphraseWrapped), the **two-key design**
  that lets a background sync open the database with no biometric prompt while
  export still requires one, Android Keystore (`android/app/src/main/kotlin/com/khata/pro/security/SecurityChannel.kt`)
  and iOS Secure Enclave (`ios/Runner/Security/SecurityChannel.swift`)
  implementations, and a fake keystore whose refusals are faithful enough to test
  the policy against.
* **BYOC backup** — `lib/sync/backup/`: the **KPB1** pack format (per-chunk MACs,
  a merkle root in the header, chunk-index nonces), the resumable transfer engine
  (checkpoints, verified progress, backoff, typed failures), and two cloud stores —
  Google Drive (`drive.file` + `appDataFolder`, resumable sessions) and iCloud
  (ubiquity container, `.part` → rename so a half-upload is never restorable).
* **LAN sync** — `lib/sync/transport/`: WebRTC data channels with **no ICE
  servers**, mDNS discovery whose TXT records carry nothing about the books, QR
  pairing with expiry plus a six-digit authentication string compared by two
  humans, and flow control that keeps a 52 MB first sync from dropping frames.

| # | check | result |
| --- | --- | --- |
| 1 | `tool/security_verify.dart` — the ladder, idempotent key creation, no-prompt sync path, per-use export prompt, device lock, enrolment invalidation, both platform envelope flavours | **54/54** |
| 2 | `tool/sync_verify.dart` — pack round-trip and tamper resistance, upload resumed after a 60 % drop, quota reported rather than retried, Drive 308 handling, iCloud staging/commit, 52 MB flow-control simulation, SDP surgery, QR budget, SAS agreement | **133/133** |
| 3 | Deliverable 2 re-run after the core changes | 81/81 · 55/55 · 72/72 · 27/27 · 35/35 · 16/16 |
| 4 | `dart analyze` on all of `lib/` — the five Flutter-facing files included, against pinned-API stubs | clean |
| 5 | The generated backup bundle, which is the artefact to keep if this workspace is lost (`tool/make_backup_bundle.sh`) | verified |

| # | the six defects the suite caught (each would have shipped) | |
| --- | --- | --- |
| 1 | An empty IV was rejected — which would have broken **every unwrap on iOS**, where ECIES carries its own nonce | fixed |
| 2 | `passphraseOnly` created a keystore key before honouring the user's refusal | fixed |
| 3 | The uploader counted *chunks sent* as *attempts*, so any backup bigger than 6 chunks failed | fixed |
| 4 | The pacing window used a running byte total instead of a per-second window, silently disabling pacing | fixed |
| 5 | `Hlc.encode()` accepted a node id its own parser rejects, so unreadable stamps could be written | fixed |
| 6 | The QR codec *inflated* a realistic pairing ticket 2.55× — 2838 characters against a hard limit of 2953, i.e. one ICE candidate away from a pairing screen that never draws a code | fixed |

| # | the eight defects the pinned plugin APIs caught (no test here could have) | |
| --- | --- | --- |
| 1 | `setLocalDescription` returns `Future<void>` — and was being handed a *minimised* description | fixed |
| 2 | WebRTC candidates never reached the far side: gathering finished after the ticket was built, and the receiver ignored `ticket.candidates` | fixed |
| 3 | The SDP minimiser dropped `a=sctp-port`; the data channel could never have opened | fixed |
| 4 | `PumpState.copyWith(sentThisWindow:)` named a field that does not exist (`sentThisSecond`) | fixed |
| 5 | mDNS TXT values are `Uint8List?`, not `String` — the read-side version compares unequal forever, so discovery would silently find nothing | fixed |
| 6 | `requiresPairing: version == protocolVersion` inverted the safety flag for incompatible peers | fixed |
| 7 | The mDNS listener was never removed from the `ChangeNotifier`, leaking an `NsdManager` registration per visit to the sync screen | fixed |
| 8 | The iCloud store was built around a container path the plugin does not expose, and treated `upload()` as complete when it only means the local container copy exists | fixed |

## ◐ Deliverable 4 — UI (Impeller, EN + UR) — **state layer delivered, widget layer next**

The half that can be proven in this workspace is done and green; the half that needs
Flutter is listed, file by file, in `docs/UI.md` §6.

**Delivered and verified**

| # | Item | Where | Evidence |
|---|---|---|---|
| 1 | Design tokens (12 semantic colours, 4/8 pt scale, type ramp, Urdu/RTL) | `lib/ui/theme/tokens.dart` | palette audit in `ui_verify` (100 checks of contrast/ordering/dark-light pairing) |
| 2 | Money/date/percent formatting, lakh–crore grouping, Urdu digits, `Dr`/`Cr` | `lib/ui/format/formatting.dart` | `ui_verify` group 1–2 |
| 3 | Chart arithmetic — scales, nice ticks, min/max downsampling, bars, hit testing, cash-flow series | `lib/ui/charts/chart_math.dart` | `ui_verify` groups 3–6, **no chart plugin** (CustomPaint only) |
| 4 | Paging + the ledger walk with an integrity verdict | `lib/ui/lists/paged_list.dart` | 30 060-item and 4 000-row walks, back-scroll, `ui_verify` groups 7–8 |
| 5 | Every read the screens make, as named SQL | `lib/ui/state/queries.dart` | **executed against a real database** in `ui_db_verify` |
| 6 | The reactive state: `ChangeBus` wired to the database's commit, providers, `LedgerController` | `lib/ui/state/{changes,providers,ledger_source}.dart` | `ui_db_verify`, 53 checks, real writes + real Riverpod container |

**Found while building it** — six defects, four of them user-visible, four in code that was
already "delivered": a party sub-ledger code that made **any party with a name longer than
19 characters impossible to create**; a dashboard view that could not see credit sales
(migration 011); a stock query selecting a column that does not exist; a change signal
Riverpod silently dropped; a missing `ref.mounted` guard; and `documents` having no writer
at all, which is what `OrderBook.postInvoice` now fixes. `docs/UI.md` §5 has the table.

**Next, in order** (`docs/UI.md` §6 for the file list and the constraints):

* `lib/apps/khata_app.dart`, `lib/ui/theme/theme.dart` — the app shell;
* `lib/ui/widgets/{biometric_gate,virtual_list,ledger_view,live_charts,skeletons}.dart`;
* the eight screens — Dashboard, Party list, Party ledger, Cash book, Stock book, Staff
  book, Bill book, Settings — each a thin watch-render-command layer over §5;
* `lib/ui/commands/book_commands.dart`, the write side;
* goldens + frame-time checks on a device, which is also where Impeller and Nastaliq
  shaping get their first real test.

## ⏭ Deliverable 5 — more sync surface

* Drive: OAuth via the user's own client id, `drive.file` + `appDataFolder`,
  pack chain upload/download, restore-with-verification.
* iCloud: ubiquity container, same pack format.
* Local file target (SD card / SAF) for users with no cloud at all.
* Recovery phrase (BIP-39, Argon2id wrap) + `recovery_guard` flows.

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
