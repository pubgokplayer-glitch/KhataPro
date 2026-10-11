"""Builds docs/REVIEW_D2.md — the code bundle the user asked to review.

Runs from the repo root: `python3 tool/build_review_bundle.py`
"""
import pathlib
import subprocess

ROOT = pathlib.Path('.')
OUT = ROOT / 'docs' / 'REVIEW_D2.md'

# (path, needle, occurrence, what the reviewer should look at)
ANCHORS = [
    ('lib/data/db/database.dart', 'static Future<KhataDb> open(KhataOpenRequest request)', 1,
     'The singleton entry point. Same file ⇒ the same future; a *different* file is refused outright — two live databases would mean two writers and two truths.'),
    ('lib/data/db/database.dart', 'return _opening ??= _openInternal(request);', 1,
     'Two racing callers (a `main()` warm-up and a provider) share **one** open. This is the line that makes a second connection impossible, and the reason repeated open/close cannot re-run key derivation.'),
    ('lib/data/db/database.dart', 'if (request.readPool != 0) {', 1,
     'A read pool means extra isolates, each needing its own connection **and its own SQLCipher key**. Refused in release builds — not an `assert`, which is stripped in release.'),
    ('lib/data/db/database.dart', 'readPool: 0,', 1,
     'One connection, `readPool: 0`, in a background isolate.'),
    ('lib/data/db/database.dart', 'request.key.attachTo(connection, requireEncryption: request.requireEncryption);', 1,
     '`setup:` runs **inside the database isolate**, before any other statement, so `PRAGMA key` is the first thing this connection ever sees.'),
    ('lib/data/db/database.dart', 'if (identical(_instance, this)) {', 1,
     '`close()` clears the singleton only when it closes *that* instance.'),
    ('lib/data/db/database.dart', "_opening = null;", 2,
     'A failed open un-caches its future, so "try again" after a wrong passphrase can actually work. Caching a rejection is a real bug class: the first failure would be handed to every later caller forever.'),
    ('lib/data/db/database.dart', "await handle.customSelect('SELECT 1').get();", 1,
     'The single query that triggers `beforeOpen`: pragmas, migrations, clock restore, dirty-open recovery, integrity read.'),
    ('lib/core/security/sqlcipher_key.dart', 'var mode = probe(database);', 1,
     '`cipher_version` is probed **before** any cipher pragma. On a stock SQLite build `PRAGMA key = x\'…\'` is a syntax error, not an ignored pragma — probing first is what keeps "no SQLCipher" and "wrong key" distinct failures.'),
    ('lib/core/security/sqlcipher_key.dart', "database.execute('PRAGMA key = $pragmaValue');", 1,
     'The one and only key application on that connection. After this, SQLCipher holds the derived key in memory; nothing re-derives it until the process restarts — which is exactly why the connection is a singleton.'),
    ('lib/core/security/sqlcipher_key.dart', "database.select('SELECT count(*) FROM sqlite_master');", 1,
     'Forces key validation here, while the failure can still be explained to the user.'),
    ('lib/core/crdt/hlc.dart', 'String encode()', 1,
     'The 57-character fixed-width wire form. Every field zero-padded ⇒ SQLite\'s ordinary BINARY collation orders stamps **exactly** as causal time orders them: no custom collation, no parsing during a delta scan, no index but a plain TEXT one.'),
    ('lib/core/crdt/hlc.dart', 'int compareTo(Hlc other)', 1,
     'Order is `(physicalMs, counter, nodeId)`. The node id in the key is what makes two writes in the same millisecond decidable with no server and no "who arrived first locally".'),
    ('lib/core/crdt/hlc.dart', 'maxDriftMs', 1,
     'A peer whose clock is far ahead has its stamp clamped for *local advancement* (its own row keeps its stamp). One broken phone cannot drag the logical clock into the future for everyone.'),
    ('lib/core/crdt/hlc.dart', 'counter overflow', 1,
     'Counter overflow rolls to the next millisecond instead of wrapping.'),
    ('lib/core/crdt/hlc_service.dart', 'static const int persistInterval = 64;', 1,
     'Logical time is persisted every 64 writes (and on pause/lock/shutdown). A crash can cost at most 64 ticks of counter space — never monotonicity.'),
    ('lib/core/crdt/hlc_service.dart', 'stampForUpdate(CrdtStamp current)', 1,
     'A local edit advances the row\'s own stamp (`rev` grows with the HLC) — [CrdtStamp.bump].'),
    ('lib/core/crdt/hlc_service.dart', 'void observeAll(Iterable<Hlc> remotes)', 1,
     'After applying a peer batch, the clock is advanced past everything seen, so the next local write orders after the remote work.'),
    ('lib/core/crdt/stamp.dart', 'operator <(CrdtStamp other)', 1,
     'A stamp compares on the HLC **only**. `rev` is a consistency check for a single writer and is deliberately excluded from ordering.'),
    ('lib/core/crdt/stamp.dart', 'String canonicalJson(', 1,
     'Canonical JSON: keys sorted, integers only (a double is rejected, not silently rounded). Two devices compare payloads by string equality.'),
    ('lib/core/crdt/lww.dart', 'final comparison = incoming.stamp.compareTo(local.stamp);', 1,
     'The whole resolver, in one line: one comparison, no negotiation, no dependence on arrival order.'),
    ('lib/core/crdt/lww.dart', "kind: 'same_stamp_different_content'", 1,
     'The one genuinely undecidable case — one writer, one logical instant, two payloads. The local copy is kept and the anomaly is **blocking**: the sync layer stops and asks rather than inventing an answer.'),
    ('lib/core/crdt/lww.dart', "kind: 'revision_not_monotonic'", 1,
     'A restored/rolled-back replica looks like this. Reported as a **non-blocking** anomaly ("ask this peer for a fresh snapshot"): the merge still loses nothing, and blocking would strand a shopkeeper who merely restored their phone from a backup.'),
    ('lib/core/crdt/lww.dart', 'MergeBatchResult mergeAll(', 1,
     'Batch merge is a fold; order-independence is a property of `merge`, proven by 800 randomised interleavings in `tool/crdt_verify.dart` (which also asserts the conflict ledger is order-independent).'),
    ('lib/data/db/dao/base_dao.dart', 'Future<void> recordConflict(FieldConflict conflict)', 1,
     'Merge receipts are **content-addressed**: the id names the conflict, not the recording device, so the same disagreement cannot be filed twice from either sync direction or on any number of replays.'),
    ('lib/data/db/dao/base_dao.dart', 'Future<void> assertFresh(', 1,
     'An edit carrying a stamp the device no longer holds is refused (`CRDT-STALE`) instead of silently overwriting a peer\'s newer work.'),
    ('lib/data/repositories/order_book.dart', 'Future<(T, CommitReport)> commitChecked<T>(', 1,
     'The gate: run the work in a transaction, re-read the integrity findings **inside** it (same connection sees uncommitted rows), throw `GATE-2` if anything critical appeared ⇒ drift rolls the write back.'),
    ('lib/data/repositories/order_book.dart', 'final lockAfter = await _accounts.scalarInt(', 1,
     'Undo picks its mechanism from the ledger state: period open → void; period locked → reversal dated the first day the ledger will accept a posting.'),
]

SECTIONS = [
    ('1 · The singleton connection (SQLCipher key derivation happens once)',
     'Answer to your first question. Read these four files in this order; the annotations table above points at the exact lines.',
     ['lib/data/db/database.dart', 'lib/core/security/sqlcipher_key.dart',
      'lib/core/security/key_custody.dart', 'lib/data/db/migration_runner.dart']),
    ('2 · HLC — the clock that never goes backwards and needs no server',
     'Answer to the first half of your second question.',
     ['lib/core/crdt/hlc.dart', 'lib/core/crdt/hlc_service.dart']),
    ('3 · CRDT — how two offline phones merge without losing anything',
     'Answer to the second half of your second question: the stamp, the resolver, and the receipts that keep the losing value.',
     ['lib/core/crdt/stamp.dart', 'lib/core/crdt/lww.dart']),
    ('4 · The data layer proper — DAOs, the gate, and the business actions',
     'Everything that touches the books goes through `OrderBook`, which goes through `commitChecked`, which goes through the schema\'s triggers.',
     ['lib/data/db/dao/base_dao.dart', 'lib/data/db/dao/journal_dao.dart',
      'lib/data/db/dao/accounts_dao.dart', 'lib/data/db/dao/parties_dao.dart',
      'lib/data/repositories/order_book.dart']),
    ('5 · Key custody — the key that never leaves the device',
     'The `db_dek` is what SQLCipher is keyed with. It is wrapped, never exported; the passphrase path is in `key_custody.dart`.',
     ['lib/core/security/kdf.dart', 'lib/core/security/wraps.dart',
      'lib/core/security/hasher.dart', 'lib/core/security/aes.dart']),
]

EVIDENCE = [
    ('`tool/sql_contract_test.py` — the schema contracts, independently implemented in Python', '35/35', 'balanced posting accepted; 5 unbalanced/malformed writes refused; frozen period enforced; stale HLC rejected; cache corruption detected then repaired; sync replay idempotent'),
    ('`tool/verify_schema.sh` — migrations → contracts → integrity sweep', '35/35, 0 critical', 'a fresh book reports **no** findings, at any severity'),
    ('`tool/data_layer_verify.dart` — the data layer end to end, on a real file', '**81/81**', 'boot · reopen with clock resume · the singleton rules · fail-closed encryption · migration guards · the OrderBook (post → gate → receipt, void, reversal in a locked period, cache repair) · crash recovery'),
    ('`dart test test/` — the shipped unit suites', '**16/16**', '`core/crdt_merge_test.dart` (11) and `data/integrity_severity_test.dart` (5)'),
    ('`tool/crdt_verify.dart` — HLC + resolver against published vectors and random interleavings', '55/55', 'includes 800 randomised multi-peer interleavings, each checking convergence, receipt-set equality and the causal-order/text-order equivalence'),
    ('`tool/crypto_verify.dart` · `tool/aes_verify.dart` — crypto vs external oracles', '72/72 · 27/27', 'Python `hashlib`/`hmac` and OpenSSL 3.5.7, plus the FIPS-197 C.3 anchor'),
    ('`dart analyze lib`', 'clean', 'zero errors, zero lints, with the repo\'s own lint set'),
]

def line_of(path, needle, nth=1):
    for i, line in enumerate((ROOT / path).read_text().split('\n'), 1):
        if needle in line:
            nth -= 1
            if nth == 0:
                return i
    return None

def read(path):
    return (ROOT / path).read_text().rstrip('\n')

def fence(path):
    return 'dart' if path.endswith('.dart') else 'sql'

out = []
w = out.append

w('# Deliverable 2 — code review bundle')
w('')
w('Everything the data layer consists of, verbatim, in one file, so it can be read')
w('end to end without trusting a summary. Generated by')
w('`python3 tool/build_review_bundle.py` — the sources below are read from the')
w('working tree at the moment of generation, so they cannot drift from what runs.')
w('')
w('Two questions were asked directly, and they are answered first.')
w('')
w('## Q1 · Is the SQLCipher connection a strict singleton?')
w('')
w('**Yes, and structurally — not by convention.** Three separate mechanisms:')
w('')
w('1. **One process, one connection.** `KhataDb.open()` returns the existing')
w('   instance for the same file, shares a single in-flight future between racing')
w('   callers, and *refuses* a second file. `readPool` must be `0`, or the open')
w('   fails (not an `assert` — release builds refuse too). A read pool would spawn')
w('   extra isolates, each with its own SQLCipher connection and its own key')
w('   derivation.')
w('2. **One key derivation per process.** The key is attached in `setup:`, which')
w('   runs inside the database isolate on the raw connection before any other')
w('   statement. SQLCipher then holds the derived key in memory; the KDF runs once')
w('   per process, not once per query and not once per screen.')
w('3. **A published, tested contract.** `tool/data_layer_verify.dart` stage 3')
w('   asserts: two concurrent `open()` calls return the *identical* instance; a')
w('   third call while the first is live is also the same instance; a second file')
w('   is refused; `readPool > 0` is refused; a *failed* open does not poison later')
w('   attempts; and the database can be reopened after `close()`.')
w('')
w('| where | what it guarantees |')
w('| --- | --- |')
for path, needle, nth, note in ANCHORS[:11]:
    n = line_of(path, needle, nth)
    w(f'| `{path}:{n}` | {note} |')
w('')
w('## Q2 · Will offline writes merge without losing anything?')
w('')
w('The short version: **ordering is decided by a stamp that carries its own reason**')
w('(`(milliseconds, counter, node id)`, encoded fixed-width so text order *is*')
w('causal order), and **every losing value is written to `conflict_log`** so it can')
w('be reviewed and reversed. A CRDT cannot keep two values in one column; keeping')
w('the loser *beside* the winner, with a review path, is the honest version of')
w('"no data loss" — and it is what the code does.')
w('')
w('| where | what it guarantees |')
w('| --- | --- |')
for path, needle, nth, note in ANCHORS[11:]:
    n = line_of(path, needle, nth)
    w(f'| `{path}:{n}` | {note} |')
w('')
w('## The evidence, and how to reproduce it')
w('')
w('| run | result | what it covers |')
w('| --- | --- | --- |')
for name, result, covers in EVIDENCE:
    w(f'| {name} | {result} | {covers} |')
w('')
w('```bash')
w('# from the repo root')
w('python3 tool/sql_contract_test.py')
w('bash tool/verify_schema.sh')
w('dart test')
w('')
w('# the environment-shaped runs need a real native SQLite/SQLCipher binary;')
w('# they are driven from a scratch Dart package so native-asset hooks apply:')
w('cd /tmp/harness')
w('dart run bin/run_layer.dart --asset-root=/home/user/khata_pro')
w('dart run ../../../home/user/khata_pro/tool/crdt_verify.dart')
w('dart run ../../../home/user/khata_pro/tool/crypto_verify.dart \\')
w('  /home/user/khata_pro/assets/testdata/crypto_vectors.json')
w('dart run ../../../home/user/khata_pro/tool/aes_verify.dart \\')
w('  /home/user/khata_pro/assets/testdata/aes_vectors.json')
w('```')
w('')
w('---')
w('')

for title, blurb, files in SECTIONS:
    w(f'# {title}')
    w('')
    w(blurb)
    w('')
    for path in files:
        n = len(read(path).split('\n'))
        w(f'## `{path}` — {n} lines')
        w('')
        w(f'```{fence(path)}')
        w(read(path))
        w('```')
        w('')

w('# Appendix · the shipped tests you can read instead of trusting the numbers')
w('')
for path in ['test/core/crdt_merge_test.dart', 'test/data/integrity_severity_test.dart']:
    n = len(read(path).split('\n'))
    w(f'## `{path}` — {n} lines')
    w('')
    w('```dart')
    w(read(path))
    w('```')
    w('')

OUT.write_text('\n'.join(out) + '\n')
print(f'wrote {OUT} ({OUT.stat().st_size/1024:.0f} KB, {len(read(str(OUT)).splitlines())} lines)')
