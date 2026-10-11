# KhataPro — Database Schema Reference

**39 base tables (+ 5 FTS5 shadow tables) · 18 views · 71 indexes · 33 triggers · 11 migrations.**
15 critical integrity invariants + 6 warnings · 35 contract tests.
Everything below is verified by `bash tool/verify_schema.sh`.

---

## 1 · Encodings (the whole design depends on these)

| Kind | Storage | Example | Why |
|---|---|---|---|
| Money | `INTEGER` minor units | `Rs 1 250.75` → `125075` | floats are banned: `STRICT` tables + `CHECK(typeof(x)='integer')` make a REAL a hard error instead of a rounding ghost that shows up in a customer's balance |
| Calendar day | `INTEGER` epoch-day | `2026-10-11` → `20737` | a sale at 23:00 Karachi belongs to that day. We store the day the user chose, never a UTC instant |
| Instant | `INTEGER` epoch-ms UTC | audit, HLC, sync | |
| Rate | `INTEGER` basis points | 18 % → `1800` | |
| Quantity | `INTEGER` thousandths | 2.5 kg → `2500` | |
| FX rate | `INTEGER` millionths | 278.45 → `278450000` | |
| Id | `TEXT` UUIDv7 | `019a1b2c-…-00000000044c` | time-ordered → append-mostly B-trees, which matters when every dirty page is AES-encrypted |
| HLC | `TEXT(57)` | `00000001800000000:0001:11111111-1111-7111-8111-000000000001` | fixed width ⇒ byte comparison == causal comparison |

`INT64` money headroom: ±92 233 720 368 547 758 paise (~Rs 922 trillion).

## 2 · Table inventory

### Core (001_core.sql)
| Table | Replicates | Purpose / notes |
|---|---|---|
| `schema_meta` | no | migration + encoder version breadcrumbs |
| `session_flags` | no | `session_id`, `write_mode`, `today_epoch_day`, `month_start`, `fy_start` — read by triggers and views |
| `nodes` | yes | one row per device that ever wrote; holds the Ed25519 public key |
| `ledgers` | yes | tenant boundary; `base_currency`, `timezone`, `fiscal_year_start_month`, `lock_after_date` |
| `currencies` | yes | scale is explicit (`JPY` = 0, `KWD` = 3), never inferred from locale |
| `fx_rates` | yes | append-only: the rate on the day of the entry is history |
| `accounts` | yes | chart of accounts; `role` is the stable machine handle reports bind to; `normal_balance` ±1; `is_postable` for headers |
| `parties` | yes | customers/suppliers; **no balance column** — derived |
| `party_contacts` | yes | multiple phone numbers per party |
| `items` | yes | products/services; `average_cost_micros` is a cache |
| `tax_rates` | yes | GST/WHT with their posting account as data, not code |
| `app_settings` | yes | key/value; separate `ledger` and `device` scopes |
| `number_sequences` | no | per (ledger, doc kind, **node**) counters — numbering is identity, and CRDTs must never arbitrate it |
| `device_profile` | no | first-frame UI cache |

### Ledger (002_ledger.sql)
| Table | Replicates | Purpose / notes |
|---|---|---|
| `journal_entries` | yes | the transaction header. `entry_date`, `source` (12 kinds), `status` 0 draft / 1 posted / 2 voided, `totals`, `reversal_of_entry_id`, `hlc/rev` |
| `journal_lines` | yes | the Dr/Cr rows. One signed `amount_minor`; `debit_minor`/`credit_minor` are **generated stored** unions, so "both Dr and Cr" is unrepresentable. No HLC (see §6) |
| `documents` | yes | invoice/bill/quote/receipt face of an entry, 1:1 via `entry_id` |
| `document_lines` | yes | print lines; header totals re-derived by trigger |
| `payment_allocations` | yes | which payment settled which invoice; signed so a correction is a row, not an update |
| `stock_moves` | yes | item ledger; `direction` ±1 carries the sign |
| `stock_on_hand` | no (derived) | per item/warehouse on-hand + moving-average cost |
| `attachments` | yes (metadata) | bytes live in the encrypted vault; only hash/MAC/path replicate |
| `account_balances` | **no (derived)** | period cache: 0 all-time, 1 day, 2 month, 3 fiscal year |
| `balance_snapshots` | yes | merkle-rooted roll-up used as the sync baseline |
| `recurring_rules` | yes | rent/salary templates; idempotent via a UNIQUE index on `(rule_id, period_key)` |
| `reminders` | yes | dismissal state must agree across devices |

### Sync (003_crdt_sync.sql)
`oplog` (local change bus, not replicated), `sync_peers` (per-device trust +
TOFU pin; deliberately never synced), `sync_cursors` (per-peer HLC watermarks
both ways), `sync_sessions` (honest "last sync" telemetry), `conflict_log` (LWW
merge receipts), `audit_log` (hash-chained, replicated), `backup_state` (BYOC
config, no credentials), `key_material` (wrapped DEKs only), `recovery_guard`
(blocks a destructive wipe when no verified backup exists).

### Search (006_search.sql)
`search_index` (FTS5, `unicode61 remove_diacritics 2` — so "احمد" matches
"اَحْمَد"), `search_map` (stable FTS rowid per row ⇒ O(log n) deletes instead of
a full virtual-table scan). Only *posted* entries are indexed.

### Integrity (005, 008)
`invariant_violations` (the abort gate), `balance_audit` (per-transaction cache
proof), `v_integrity_report` (15 critical invariants + 6 warnings).

## 3 · The double-entry contract (enforced by the database)

An entry can only become `posted` in **two** ways, and both walk the gate:

```
(a) the guarded transition
    UPDATE journal_entries SET status = 1
     WHERE id = ? AND khata_entry_is_balanced(id)   -- 0 rows = refused
    re-asserted by trigger trg_je_balance_gate
(b) a sync-apply transaction (write_mode = 'sync') that MUST end with
    ops/integrity_checks.sql, or the whole batch rolls back
```

| Code | Trigger | Refuses |
|---|---|---|
| INT-1 | `trg_jl_insert_guard` | adding a line to a posted/voided entry; replaying a known row is a no-op |
| INT-2 | `trg_jl_consistency(+_upd)` | line/entry disagreement on ledger, date or currency; postings to header or deleted accounts; mutating a posted line |
| INT-3 | `trg_jl_no_delete`, `trg_je_no_delete` | deleting posted rows (drafts may be discarded; `write_mode='purge'` is the erase-everything flow) |
| INT-4 | `trg_jl_totals_*` | a wrong "Total: Rs 12,500" on a draft — totals are DB-maintained |
| INT-5 | `trg_je_balance_gate` | **Σ debit − Σ credit ≠ 0**, < 2 lines, no debit side, no credit side, inconsistent totals |
| INT-6 | `trg_je_insert_posted_guard` | an entry born already-posted outside sync mode |
| INT-7 | `trg_je_immutable` | changing a posted entry's ledger/number/date/source/currency/fx/party/doc_no/amounts; backwards status; un-stamped void; **stale HLC or rev** (out-of-order CRDT write) |
| DOC-1…5 | document triggers | header totals drifting from lines; posted document re-issuing itself; **over-settlement** of an invoice; balance not tracking allocations |
| FIN-1 | `trg_je_locked_period` | posting into a locked accounting period |
| FIN-2 | `trg_account_system_guard` | retargeting a system account's role or side (renaming stays free) |
| GATE | `trg_gate_abort` | any row landing in `invariant_violations` aborts the statement with a message, one indexed scan per check, no Dart logic involved |

**Frozen vs LWW, column by column.** Financial content of a posted entry is
absolutely immutable; `memo`, `memo_ur`, `tag_json`, `attachment_count`,
`reconciled_at`, `locked_by_date` are LWW and bump `(hlc, rev)` monotonically.
That split is what makes the append-only set-union merge sound where it counts.

**Cache integrity in O(1).** `account_balances` is maintained by triggers and
audited in the same transaction: `balance_audit` records what the cache *was*
before the transaction and what the transaction claims to have *added*.
`GATE-2` asserts `cache == before + delta` per touched account — a wrong number
on the home screen is caught the moment it is created. Absolute verification
(cache vs Σ lines) runs nightly and on demand (`v_integrity_report` [5]) with
`ops/rebuild_caches.sql` as the repair, which is safe because the cache is a
pure function of immutable postings.

## 4 · Numbering

Per `(ledger_id, doc_kind, node_id)` counters, allocated inside the write
transaction. Two offline devices can both mint `INV-0007` without colliding —
so on a multi-device ledger the printed number carries a node suffix
(`INV-0007-B`), or the user picks a single "numbering device" in Settings. This
is deliberately *not* a CRDT problem: identity must be allocated, not merged.

## 5 · Sync scope map

| Replicated (with envelope) | Replicated (append-only) | Local only |
|---|---|---|
| `accounts`, `parties`, `party_contacts`, `items`, `tax_rates`, `documents`, `document_lines`, `app_settings`, `reminders`, `recurring_rules`, `ledgers`, `currencies`, `nodes`, `backup_state`, `audit_log` | `journal_entries`¹, `journal_lines`, `stock_moves`, `payment_allocations`, `fx_rates`, `balance_snapshots` | `oplog`, `sync_peers`, `sync_cursors`, `sync_sessions`, `conflict_log`, `number_sequences`, `device_profile`, `key_material`, `recovery_guard`, `balance_audit`, `invariant_violations`, `schema_meta`, `session_flags`, `account_balances`, `stock_on_hand`, `search_*` |

¹ `journal_entries` merges as set-union on its financial fields; narration
fields follow LWW (`rev`/`hlc`).

## 6 · Deliberate exceptions

* **`journal_lines` has no `hlc`.** A line is meaningless unless it sums to
  zero with its siblings, so it always travels with its parent entry and
  inherits that entry's stamp. Cost of the omission: zero. Saving: ~9 % of the
  database.
* **`balance_snapshots` and `account_balances` are duals.** The snapshot is the
  shared, signed *claim* about history; the balance is the local, rebuildable
  *view* of it. Verification compares them, and a mismatch is a real incident.
* **`search_index` has no `deleted_at`.** Removing a row from an FTS index is a
  physical delete; tombstones live in `search_map`.

## 7 · Adding a migration

1. Add `assets/sql/migrations/00N_<name>.sql`. Statements must be idempotent
   (`CREATE … IF NOT EXISTS`) — the migrator re-runs cleanly on every open, and
   contract test A1 asserts it.
2. Never edit a shipped migration: add `00N+1`. Users' files already ran it.
3. Add a contract test in `tool/sql_contract_test.py` for the new invariant and
   a check in `v_integrity_report` if a derived value is involved.
4. `bash tool/verify_schema.sh --bench` before and after: a schema change that
   doubles a hot path's latency must be a decision, not an accident.
