# KhataPro — خاتہ پرو

**A zero-cost, server-free, offline-first double-entry accounting app for SMEs**
(an honest architecture answer to Digi Khata's subscription + sync weaknesses).

> **Deliverable 1 of N** — project skeleton, locked dependency set, and the
> complete SQLCipher/Double-Entry schema. Nothing in this repo talks to a server
> we own, now or at 100 k users.

---

## 1. Requirement → implementation map

| SRS directive | How this repo satisfies it | Where |
|---|---|---|
| **Zero cost, no paid cloud DB / no commercial sync engine** | Primary store is a local SQLCipher file. "Cloud" = the user's own Drive/iCloud quota via *their* OAuth client. Peer sync = LAN WebRTC data channels, no signaling server. | `docs/ARCHITECTURE.md` §1–4, `lib/sync/**` |
| **BYOC backup — Google Drive (Android) + iCloud (iOS)** | `drive.file` scope only (we can't see anything but our own folder), AppDataFolder for iCloud, content-addressed encrypted snapshot packs. | `lib/platform/drive/**`, `lib/platform/icloud/**`, `lib/sync/backup/**` |
| **Local P2P sync via WebRTC** | mDNS discovery + QR pairing (no STUN/TURN needed on-LAN), DTLS-encrypted `RTCDataChannel`, MTU-aware chunking. | `lib/sync/transport/**` |
| **Flutter + Impeller, 60–120 fps** | Flutter 3.47 stable, Impeller on both platforms (`Info.plist` / manifest flags + `--enable-impeller`), const-heavy widget tree, zero `saveLayer`, `SliverList` + keys for O(1) rebuilds, `RepaintBoundary` around charts. | `lib/app/theme/**`, `lib/features/**/presentation` |
| **Offline-first, SQLite as source of truth** | Drift + SQLite (SQLCipher) is authoritative; UI observes streams directly; network is a *background nicety*, never a dependency. | `lib/data/db/**` |
| **CRDTs — lossless concurrent merges, no arbiter** | HLC-stamped, LWW-element-set + append-only register model with deterministic tie-break `(hlc, node_id)`; **journals are immutable so they merge by set-union**; balances are *derived*, never replicated. | `docs/ARCHITECTURE.md` §3, `assets/sql/migrations/003_crdt_sync.sql`, `lib/core/crdt/**` |
| **Strict double-entry: Dr. = Cr. on every transaction** | Enforced **in the database itself** by SQL triggers, not by hopeful Dart code: `Σ(debit) − Σ(credit) = 0`, ≥ 2 lines, no zero/negative amounts, entry must be balanced before `posted`, posted entries are immutable. | `assets/sql/migrations/002_ledger.sql`, `005_triggers.sql` |
| **SQLCipher 256-bit AES + perf mitigation** | `hooks: sqlite3: source: sqlcipher` (build-time native cipher), PBKDF2-HMAC-SHA256 (600k iterations) key held in Keystore/Keychain, **one writer connection per process** (`readPool: 0` refused otherwise), `BEGIN IMMEDIATE` batches, covering indexes on every hot path, `mmap_size`/page-size tuning. | `pubspec.yaml`, `lib/core/security/**`, `docs/DATA_LAYER.md` |

## 2. Money is an integer. Always.

`MoneyMinor` = `INTEGER` in **minor units** (paise). `1 250.75 PKR` is stored as
`125075`. Floats are banned from the schema (`STRICT` tables + `CHECK(typeof(x)='integer')`).
`INT64` headroom ≈ ±92 233 720 368 547 758 paise — no realistic ledger overflows it.

## 3. Bootstrap

```bash
# 1 · Toolchain (Flutter 3.47.7 stable / Dart 3.13.5 — verified 2026-10-11)
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$PATH:$HOME/flutter/bin"
flutter --version                     # expect ≥ 3.47.0 with Impeller flag listed

# 2 · Project
cd khata_pro
flutter pub get                       # resolves; downloads the SQLCipher binaries
                                      # declared in the `hooks:` block
dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n

# 3 · Native extras
bash tool/setup_native.sh             # Drive OAuth client IDs, iCloud container,
                                      # Gradle/Info.plist hardening, fonts
bash tool/fetch_fonts.sh              # OFL fonts → assets/fonts/ (then uncomment
                                      # the `fonts:` block in pubspec.yaml)

# 4 · Prove the database layer on a real SQLite engine *before* the app runs
#     (migrations → 35 contract tests → integrity sweep; add --bench for scale)
bash tool/verify_schema.sh --bench

# 5 · Run (Impeller is default on Android 10+/iOS 13+; keep the flag to be explicit)
flutter run --enable-impeller --profile
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
```

### Android specifics you must not skip
* `android/app/build.gradle.kts`: `ndkVersion`, `minSdk 23`, `packaging { jniLibs { useLegacyPackaging = false } }`.
* **Play Console → App Content → "No backup"** *and* `android:allowBackup="false"`:
  an encrypted DB must never ride a system backup that lacks its key.
* `userDefinedSymbols` for 16 KB page size (Play requirement) — see `tool/setup_native.sh`.

### iOS specifics you must not skip
* iCloud capability + ubiquity container `iCloud.<bundle-id>` in the entitlement.
* `NSUbiquitousContainers` in `Info.plist`, Keychain sharing group for the DB key.
* `ios/Runner/Info.plist`: `UIApplicationSupportsIndirectInputEvents`, `NSLocalNetworkUsageDescription`
  + `NSBonjourServices` (mDNS sync), `NSCameraUsageDescription` (QR pairing / receipts).

## 4. Layout

```
khata_pro/
├─ assets/sql/migrations/   ← THE SCHEMA (001…007, hand-written, reviewed, frozen)
├─ assets/sql/ops/          ← maintenance: integrity, cache rebuild, retention
├─ lib/core/crdt/           ← HLC clock + CRDT merge kernels
├─ lib/core/security/       ← Argon2id KDF, Keystore/Keychain key custody
├─ lib/data/db/             ← Drift database, DAOs, hand-written migrations
├─ lib/sync/{transport,protocol,backup}
├─ lib/platform/{drive,icloud}
├─ lib/ui/{state,lists,charts,format,theme}   ← D4: everything a screen reads
├─ test/sql/                ← schema contract tests (run on desktop SQLite in CI)
├─ tool/                    ← setup_native.sh · fetch_fonts.sh · verify_schema.sh
├─ docs/DATA_LAYER.md       ← D2: the data layer and its proofs
├─ docs/UI.md               ← D4: the reactive contract, and what is left
└─ docs/ARCHITECTURE.md     ← the decisions, with the math
```

## 5. Verified in this drop

```
bash tool/verify_schema.sh --bench
  ▶ all 11 migrations apply, re-apply cleanly    (221 objects, 37 accounts)
  ▶ contract tests                               35/35 hold
  ▶ integrity sweep                              0 critical findings
  ▶ 20 000 entries / 51 009 postings            51.9 MB, Σ(net) over all accounts = 0
      dashboard 4.1 ms · trial balance 0.1 ms · post an invoice 0.35 ms
      FTS search 1.1 ms · write throughput 9 702 lines/s (all triggers on)
```

The Dart side, all runnable in this workspace without a Flutter SDK
(`tool/bootstrap_harness.sh` sets up the harness described in `docs/DATA_LAYER.md`):

```
crypto 72/72 · aes 27/27 · crdt 55/55 · sync 133/133 · security 54/54
data layer 81/81 · sql contracts 35/35 · flutter test 16/16
ui logic 174/174 · ui + database integration 53/53      (docs/UI.md)
dart analyze: no issues found over lib/ and the new tool
```

## 6. Documentation index
* `docs/REVIEW_D2.md` — Deliverable 2 as one reviewable bundle: every source file
  verbatim, the singleton argument, and the evidence.
* `docs/DATA_LAYER.md` — Deliverable 2: the singleton contract, the commit gate,
  void-vs-reversal, and the evidence behind each claim.
* `docs/ARCHITECTURE.md` — sync/CRDT/security/performance decisions, with the measured numbers.
* `docs/SYNC.md` — **Deliverable 3**: key custody (and why background sync never
  prompts), the KPB1 backup pack, resumable uploads, Drive/iCloud, WebRTC LAN sync,
  QR pairing, flow control, SDP surgery, and the fourteen defects the harness and
  the pinned plugin APIs caught.
* `docs/UI.md` — **Deliverable 4**: the reactive contract (`ChangeBus` → providers →
  screens), the four wiring traps that cost real debugging time, the six defects this
  stage found in shipped code, and what only a device can settle.
* `docs/PLATFORM_SETUP.md` — the Android manifest, iOS entitlements and Google Cloud
  steps a release build needs, plus exactly which files have not been compiled here.
* `docs/REPO_AND_BACKUP.md` — the 128 MB workspace budget, the cleanup script, and how
  to push this repository somewhere it can survive.
* `docs/DB_SCHEMA.md` — every table, every index, and *why* it exists; the
  double-entry trigger contract; sync-scope table (which tables replicate).
* `docs/ROADMAP.md` — what is implemented in which deliverable.
* `docs/STRUCTURE.md` — annotated file map and naming conventions.
* `docs/THIRD_PARTY.md` — licence obligations before you ship a binary.

## 7. Licence
App code MIT. SQLCipher community build: BSD-style (Zetetic) — see
`docs/THIRD_PARTY.md` before shipping a closed-source binary.
