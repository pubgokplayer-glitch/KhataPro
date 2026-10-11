# The data layer — what it is, and the evidence that it holds

Deliverable 2. The schema (Deliverable 1) says what *may* be true of the books.
This layer is what *enforces* it from Dart, and the two acceptance criteria the
user set for it were unusually sharp, so they are answered first.

> **"The connection must be a strict singleton — repeated open/close triggers
> expensive SQLCipher key derivation."**
> **"LWW/CRDT conflict resolution must be bulletproof: concurrent offline writes
> must merge automatically without data loss."**

| acceptance criterion | how it is enforced | where it is proven |
| --- | --- | --- |
| One connection, ever | `KhataDb` is a process-wide singleton with a state machine; a second file is refused, a second concurrent `open()` returns the *same* instance, a failed open does not poison the next attempt | `tool/data_layer_verify.dart` stage 3 |
| No repeat key derivation | `readPool: 0` ⇒ exactly one SQLCipher connection; `PRAGMA key` is sent once per process, in `setup:` — never per query | stage 3, plus the `openMillis` in `BootDiagnostics` |
| Writes are gated | `OrderBook.commitChecked` re-reads `v_integrity_report` **inside** the transaction and throws `GATE-2`; the critical finding rolls the whole write back | stage 6, and `test/data/integrity_severity_test.dart` |
| Merge never loses data | `LwwResolver` decides on `(physical, counter, nodeId)` only; the losing value is returned as a `FieldConflict` and stored in `conflict_log` for review | `test/core/crdt_merge_test.dart` (11 checks), `tool/crdt_verify.dart` (55) |

## The layers, from the file up

```
key custody  →  SQLCipher key  →  drift singleton  →  DAOs  →  OrderBook
(Android      (PRAGMA key,       (one connection,    (raw     (business actions,
 Keystore /    probe-first)       one isolate)        SQL,     the integrity gate,
 Secure                                                          receipts)
 Enclave)                                           typed)
```

* **`lib/core/security/`** — PBKDF2-HMAC-SHA256 (600k iterations), HKDF, AES-256,
  `AeadKeyWrap` (CTR + HMAC-SHA256), and `PassphraseKeyCustody` for the
  passphrase path. `CustodyRules.neverExportable = {db_dek, vault_dek}`: the key
  that decrypts the books cannot leave the device, in any form, by design.
  Checked against published vectors: `tool/crypto_verify.dart` 72/72,
  `tool/aes_verify.dart` 27/27 (including the FIPS-197 C.3 anchor).
* **`SqlCipherKey.attachTo`** — probes `cipher_version` **before** touching
  `PRAGMA key`. On a build without SQLCipher that pragma is a *syntax error*, not
  a no-op, so the probe is what makes the failure legible: with
  `requireEncryption: true` the open fails through `EncryptionUnavailable` and
  leaves no plaintext file behind; with it false the app runs unencrypted and
  says so. Never pass `false` from app code.
* **`KhataDb`** (`lib/data/db/database.dart`) — the singleton. `beforeOpen` runs
  the shipped-migration check, the migrations, the dirty-open probe and the clock
  resume, all in the database isolate.
* **DAOs** (`lib/data/db/dao/`) — one per aggregate. `DaoBase` owns the
  ledger-scoped helpers, the CRDT stamp helpers (`newStamp`, `assertFresh` →
  `CRDT-STALE`), the op-log enqueue, the hash-chained audit append, and SQLite
  error translation into `InvariantViolation` / `ImmutableDocumentException`.
* **`OrderBook`** (`lib/data/repositories/order_book.dart`) — the only thing the
  UI calls to move money: `postSale`, `postExpense`, `postPaymentIn`,
  `postOpening`, `voidEntry`, `reverseEntry`, plus `audit`, `rebuildCaches`.

## The gate: `commitChecked`

Every write runs through it:

1. open a transaction (drift's, so nesting is safe);
2. run the caller's work;
3. re-read the integrity report **on the same connection**, which still sees the
   uncommitted rows;
4. throw `InvariantViolation(code: 'GATE-2')` if anything critical appeared ⇒
   drift rolls the transaction back.

Two check depths, because the cost has to be proportional to the work:

| | scope | cost | used by |
| --- | --- | --- | --- |
| `CommitCheck.quick` | only the critical kinds a single posting can cause, plus cache-vs-lines drift for the touched accounts | ~1 ms, flat in book size | `postSale`, `postExpense`, `postPaymentIn` |
| `CommitCheck.full` | the whole `v_integrity_report` | ~275 ms on a 20k-entry book | `postOpening`, `voidEntry`, after a sync merge |

A shopkeeper posting an invoice should not pay 275 ms; a sync merge, which can
touch anything, should.

## Undoing a mistake: void *or* reverse, never both

The schema made this call, and it is right. `trg_bal_void` removes a voided
entry's money from every cached balance the moment `status` becomes 2, and
`trg_je_no_delete` refuses to delete a posted entry. So:

* **Void** (`status = 2`, `voided_at` stamped): same period, typed wrong. The
  money leaves every report; the entry stays for audit.
* **Reversal** (`reversal_of_entry_id`): a negated mirror entry. The original
  stands. Used for a customer credit note, and — automatically — when the
  original falls inside `ledgers.lock_after_date`, because erasing rupees from a
  period that has already been filed would silently change a submitted return.

Writing both at once (post the mirror *and* flip the status) subtracts the same
rupees twice. That bug existed, and this layer's own gate caught it during
development — see `test/data/integrity_severity_test.dart` for the shape of the
gate that caught it. A reversal is dated the first day the ledger will accept a
posting (`lock_after_date + 1`, or today if that is later), because `trg_je_locked_period`
refuses anything dated inside the locked window.

## Three traps the schema taught us

These are recorded because each one cost a debugging cycle and each one is a
property of the database, not an opinion:

1. **`base_total_minor` is gross, not halved.** `total_debit_minor` and
   `total_credit_minor` are one-sided totals; `base_total_minor` is
   `SUM(ABS(base_amount_minor))` — twice the entry's value for a two-line entry.
   `ENTRY_TOTALS_DRIFT` asserts exactly that asymmetry.
2. **One account per role per ledger** (`ux_accounts_role`). A party's
   sub-ledger account therefore carries `party_id` with a **NULL role**; the
   money is attributed to the party through `journal_lines.party_id`, which is
   what `v_party_balances` sums and what the schema's own `UNPAIRED_PARTY_ACCOUNT`
   check looks for. `INSERT OR IGNORE` against that unique index silently
   swallowed a sub-ledger whose role was set, and the failure only appeared later
   as `INT-2d: lines may only post to postable accounts`.
3. **`account_balances.net_minor` is `GENERATED ALWAYS … STORED`.** Nothing can
   forge it, including a test that wants to. Corrupt `debit_minor` when you need
   a broken cache.

## Merge receipts are content-addressed

`conflict_log.id` is derived from the *conflict* — `(table, row, field, loserHlc,
winnerHlc)` — never generated. Two devices describing the same disagreement write
one receipt between them; a replayed batch lands on the row that is already
there. The resolution string is deliberately **not** part of the id: the same pair
of versions reads as `remote_won` on the phone that received it and `local_won`
on the phone that held it, and a perspective-dependent id would file one
disagreement twice. `local_json`/`remote_json` keep the schema's meaning ("what
was here" / "what arrived"), recovered from which side won.

## Verification: what to run, and what it has to say

```bash
bash tool/verify_schema.sh              # 35/35 contracts, 0 critical findings
python3 tool/sql_contract_test.py       # 35/35 — the same contracts, independent implementation
flutter test                            # 16 unit tests: the merge contract + severity contract
```

Plus the environment-shaped runs — a real native SQLite, driven from a scratch
Dart harness so that native-asset build hooks apply:

```bash
cd /tmp/harness
dart run bin/run_layer.dart --asset-root=/home/user/khata_pro   # 81 checks, 7 stages
dart run ../../../home/user/khata_pro/tool/crdt_verify.dart     # 55 checks
```

The 81-check run is the one that matters for this deliverable: it opens a real
encrypted book, seeds it, posts a partly-paid sale with tax, reads the party
statement, refuses a stale edit, voids an entry, corrects one inside a locked
period, corrupts a cached balance and watches the gate refuse to commit on top of
it, then kills the process and watches the next open heal itself.

## What is deliberately not here yet

* `lib/platform/security/` — the Android Keystore / iOS Secure Enclave
  `PlatformKeyCustody` implementation. The *seam* exists (`CustodyLevel`,
  `PassphraseKeyCustody`, the rules); the platform binding is Deliverable 3 work
  because it is the first thing that needs a real device.
* WebRTC transport and the BYOC backup pack format (Google Drive / iCloud). The
  pieces they need already exist and are tested: op log with per-row stamps and
  tombstones, `sync_cursors` for resumable pulls, content-addressed receipts, and
  the merge resolver whose order-independence is proven rather than asserted.
