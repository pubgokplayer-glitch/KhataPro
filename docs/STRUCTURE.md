# Project structure

Feature-first, with a hard boundary between **data**, **domain** and **UI** —
so a rule like "only `OrderBook` may post an entry" is visible in the tree, not
just in a review comment.

```
khata_pro/
├─ pubspec.yaml                     locked deps + the SQLCipher build hook
├─ analysis_options.yaml            strict lints (no dynamic, no floats in money paths)
├─ README.md                        what this is, how to bootstrap, requirement map
│
├─ assets/
│  ├─ sql/
│  │  ├─ migrations/               ★ THE SCHEMA — versioned, hand-reviewed, idempotent
│  │  │  ├─ 001_core.sql            identity, tenancy, CoA, parties, items, tax, settings
│  │  │  ├─ 002_ledger.sql          double-entry core + derived caches
│  │  │  ├─ 003_crdt_sync.sql       oplog, peers, cursors, conflicts, audit, keys, backup
│  │  │  ├─ 004_views.sql           every report, incl. the audited balance cache read path
│  │  │  ├─ 005_triggers.sql        the double-entry law + immutability + cache audit
│  │  │  ├─ 006_search.sql          FTS5 (Urdu-aware) + rowid map
│  │  │  ├─ 007_seed.sql            deterministic CoA / taxes / prefs (zero-sync seeds)
│  │  │  └─ 008_integrity.sql       15 critical invariants + 6 warnings, one definition
│  │  └─ ops/                      NOT migrations — run on demand
│  │     ├─ open_pragmas.sql        WAL/cache/mmap tuning that blunts the SQLCipher tax
│  │     ├─ integrity_checks.sql    the abort gate + repair playbook
│  │     ├─ rebuild_caches.sql      rebuild balances, totals, stock (pure function)
│  │     ├─ rebuild_search.sql      reindex FTS from the source tables
│  │     └─ prune.sql               bounded retention (peer-cursor-aware)
│  ├─ fonts/                       fetched by tool/fetch_fonts.sh (OFL, not in VCS)
│  ├─ i18n/                        en_PK, ur_PK (Nastaliq, RTL)
│  └─ images/
│
├─ lib/
│  ├─ app/                         MaterialApp, router (go_router), theme, typography
│  ├─ core/
│  │  ├─ money/                    MoneyMinor (int-backed) — never a double
│  │  ├─ crdt/                     HLC encode/decode/merge, LWW resolver, tombstone rules
│  │  ├─ security/                 Argon2id KDF, Keystore/Keychain custody, lock policy
│  │  ├─ errors/                   Result types + the invariant-violation exception
│  │  ├─ telemetry/                opt-in crash reporting (off by default)
│  │  └─ utils/
│  ├─ data/
│  │  ├─ db/                       Drift database, SQLCipher setup, hand-written migrator
│  │  │  ├─ dao/                   journal, party, document, item, report, settings
│  │  │  └─ converters/            epoch-day, basis points, minor units
│  │  ├─ repositories/             OrderBook (the ONLY posting path), PartyRepo, …
│  │  └─ models/                   generated row + DTO types
│  ├─ domain/
│  │  ├─ entities/                 Party, Account, JournalEntry draft, Money, HLC…
│  │  └─ usecases/                 PostInvoice, SettleInvoice, DayClose, YearEndRollover…
│  ├─ features/<screen>/
│  │  ├─ application/              Riverpod notifiers + repository wiring
│  │  └─ presentation/             widgets, all const-friendly, Impeller-safe
│  │     (dashboard · parties · ledger · documents · items · reports ·
│  │      backup · sync · settings · onboarding)
│  ├─ sync/
│  │  ├─ transport/                mDNS discovery, QR pairing, WebRTC data channel
│  │  ├─ protocol/                 framing, chunking, apply pipeline + gate
│  │  ├─ crdt/                     op log writer, delta builder, snapshot/merkle
│  │  └─ backup/                   KPB1 pack format, chain, verify-then-restore
│  └─ platform/
│     ├─ android/                  Keystore, FLAG_SECURE, WorkManager
│     ├─ ios/                      Keychain, iCloud container, BGTaskScheduler
│     ├─ drive/                    Google Drive (drive.file + appDataFolder)
│     └─ icloud/                   iCloud Documents
│
├─ test/
│  ├─ unit/                        money math, HLC ordering, document totals
│  ├─ widget/                      golden files: invoice/receipt EN + UR (RTL)
│  ├─ integration/                 offline parity, sync chaos, restore drill
│  ├─ sql/                         Dart mirror of the 35 SQL contracts
│  └─ fixtures/
│
├─ integration_test/               on-device end-to-end (airplane mode first)
│
├─ tool/
│  ├─ setup_native.sh              Gradle NDK/minSdk/16 KB pages, entitlements, plists
│  ├─ fetch_fonts.sh               Inter + Noto Nastaliq Urdu (OFL)
│  ├─ verify_schema.sh             migrations → 35 contracts → integrity sweep [--bench]
│  ├─ sql_contract_test.py         the contract suite (no Flutter SDK required)
│  └─ benchmark.py                 51 k-posting scale + latency/write benchmarks
│
├─ docs/
│  ├─ ARCHITECTURE.md              cost model, CRDT math, sync, BYOC, security, perf
│  ├─ DB_SCHEMA.md                 every table/index/index rationale + the contract table
│  ├─ STRUCTURE.md                 this file
│  ├─ ROADMAP.md                   deliverables 1–6
│  └─ THIRD_PARTY.md               licence obligations (SQLCipher, OFL fonts, …)
│
├─ android/ · ios/                 generated by `flutter create`, then hardened by
│                                  tool/setup_native.sh (never hand-edited blindly)
└─ docs/../README.md
```

## Naming conventions

| Thing | Convention | Example |
|---|---|---|
| Tables | `snake_case`, plural | `journal_entries` |
| Views | `v_` prefix | `v_trial_balance` |
| Indexes | `ix_` (plain), `ux_` (unique) | `ix_jl_acct_date_amt` |
| Triggers | `trg_<table>_<intent>` | `trg_je_balance_gate` |
| Invariant codes | `INT-n` / `DOC-n` / `FIN-n` | `INT-5b` |
| Test ids | `<module><n>` | `B2`, `D6`, `F3` |
| Dart features | noun folders, no `screens/` | `features/parties/presentation` |

## Where a new feature goes

1. SQL: a new migration `00N_name.sql` (+ index only if the benchmark justifies it).
2. Data: a DAO method that runs inside `commitChecked()`.
3. Domain: a use case that expresses the *business* rule, not the SQL.
4. UI: a Riverpod notifier + const widgets in `features/<name>/`.
5. Tests: a contract test if it touches money; a widget golden if it prints money.
