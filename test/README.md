# KhataPro test suite

Run from the package root — the tests locate `assets/sql` relative to the working
directory (or `KHATA_ASSET_ROOT` if you are driving them from a scratch harness):

```bash
flutter test                                   # everything
flutter test test/core/crdt_merge_test.dart     # the merge contract
flutter test test/data/integrity_severity_test.dart
```

| file | what it proves |
| --- | --- |
| `core/crdt_merge_test.dart` | Determinism, commutativity, replay-idempotence, tombstone rules, and that the losing value is always handed back as a reviewable `FieldConflict`. |
| `data/integrity_severity_test.dart` | Severity `1 = critical, 2 = warning` is not inverted; a warning does not block a commit while a critical one rolls it back; a healthy book reports nothing. |

The heavier, environment-shaped proofs live in `tool/` (schema contracts, the
81-check data-layer run, the crypto vector suites) because they need a real
native SQLite/SQLCipher binary rather than a Flutter test host.
