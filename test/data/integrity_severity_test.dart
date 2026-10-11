/// KhataPro · the severity contract, and the rule that a gate can only be
/// trusted if it *stops* a bad write and *allows* a good one anyway.
///
/// This file was promised by a comment in `lib/data/db/database.dart` and is the
/// test that comment was talking about — the numbering is load-bearing and easy
/// to invert by accident while refactoring SQL, so it is asserted rather than
/// remembered:
///
///   * `v_integrity_report.severity` is **1 = critical, 2 = warning** — the
///     opposite of the "1 = info" convention most logging systems use.
///   * `IntegrityFinding.isCritical` is exactly `severity == 1`, and *only* a
///     critical finding may roll a commit back.
///
/// Run: `flutter test test/data/integrity_severity_test.dart`
library;

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:khata_pro/core/errors/khata_exception.dart';
import 'package:khata_pro/core/security/sqlcipher_key.dart';
import 'package:khata_pro/core/utils/epoch_day.dart';
import 'package:khata_pro/data/db/database.dart';
import 'package:khata_pro/data/db/dao/base_dao.dart';
import 'package:khata_pro/data/db/dao/parties_dao.dart';
import 'package:khata_pro/data/db/migration_runner.dart';
import 'package:khata_pro/data/repositories/order_book.dart';
import 'package:test/test.dart';

/// The directory that actually contains `assets/sql` — the package root.
String _repoRoot() {
  final declared = Platform.environment['KHATA_ASSET_ROOT'];
  if (declared != null && File('$declared/assets/sql/ops/open_pragmas.sql').existsSync()) {
    return declared;
  }
  var dir = Directory.current;
  for (var depth = 0; depth < 4; depth++) {
    if (File('${dir.path}/assets/sql/ops/open_pragmas.sql').existsSync()) return dir.path;
    dir = dir.parent;
  }
  throw StateError(
    'assets/sql not found from ${Directory.current.path} — run `flutter test` from '
    'the package root, or set KHATA_ASSET_ROOT',
  );
}

void main() {
  late Directory dir;
  late KhataDb khata;
  late String ledgerId;
  late OrderBook book;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('khata_sev_');
    khata = await KhataDb.open(
      KhataOpenRequest(
        databaseFile: File('${dir.path}/sev.sqlite'),
        key: SqlCipherKey.generate(),
        nodeId: '019a1b2c-0000-7000-8000-0000000000cc',
        platform: 'linux',
        appVersion: '1.0.0+1',
        // The shipped SQL is the SQL under test, so the loader is pointed at the
        // package root — found rather than assumed, because `flutter test` runs
        // from the root while a bare `dart test` from a harness may not.
        assetLoader: FileSystemAssetLoader(_repoRoot()),
        requireEncryption: false,
      ),
    );
    final rows = await khata.db.customSelect('SELECT id FROM ledgers LIMIT 1').get();
    ledgerId = rows.first.read<String>('id');
    book = OrderBook(db: khata.db, ledgerId: ledgerId);
  });

  tearDown(() async {
    await khata.close();
    dir.deleteSync(recursive: true);
  });

  test('isCritical is exactly "severity == 1" — the numbering is not inverted',
      () {
    expect(
      const IntegrityFinding(
        severity: 1,
        kind: 'ACCOUNT_BALANCE_DRIFT',
        detail: 'cached Dr/Cr disagree with the lines',
      ).isCritical,
      isTrue,
    );
    expect(
      const IntegrityFinding(
        severity: 2,
        kind: 'SEARCH_INDEX_STALE',
        detail: 'rows awaiting a rebuild',
      ).isCritical,
      isFalse,
    );
    // A future severity added to the SQL must not silently become "critical".
    expect(
      const IntegrityFinding(severity: 3, kind: 'HYPOTHETICAL', detail: 'not a level we emit')
          .isCritical,
      isFalse,
    );
  });

  test('a fresh book is silent — every health arm returns no rows when healthy',
      () async {
    // A regression guard for the SQLite trap that produced migration 010: an
    // aggregate with no GROUP BY always emits a row, so a naive
    // `COUNT(*) ... WHERE stale` arm reported a stale search index on an empty
    // database and made the app greet its user with a warning.
    expect(khata.diagnostics.integrity, isEmpty);
    expect((await book.audit()).findings, isEmpty);
  });

  test('the report only ever emits severities 1 and 2', () async {
    final rows = await khata.db
        .customSelect('SELECT DISTINCT severity FROM v_integrity_report')
        .get();
    for (final row in rows) {
      expect(row.read<int>('severity'), anyOf(1, 2),
          reason: 'v_integrity_report must not invent a third severity level');
    }
  });

  test('a warning does not block a commit, a critical one does', () async {
    final today = EpochDay.fromDateTime(DateTime.now());

    // A payment that is not allocated to any invoice is a *warning*
    // (UNALLOCATED_PAYMENT, severity 2): the money is real, the paperwork is
    // incomplete. It must not stop the shopkeeper from working.
    final parties = PartiesDao(db: khata.db, ledgerId: ledgerId);
    final party = await parties.create(const PartyDraft(name: 'Warn Case'));
    final payment = await book.postPaymentIn(
      entryDate: today,
      amountMinor: 5000,
      partyId: party,
      memo: 'unallocated on purpose',
    );
    final warnings = await book.audit();
    expect(warnings.findings.map((f) => f.kind), contains('UNALLOCATED_PAYMENT'));
    expect(
      warnings.findings
          .where((f) => f.kind == 'UNALLOCATED_PAYMENT')
          .every((f) => !f.isCritical),
      isTrue,
    );
    expect(payment.commit.isClean, isTrue,
        reason: 'a severity-2 finding must not refuse a legitimate posting');

    // Now make the books genuinely inconsistent (a cached balance that disagrees
    // with the lines — severity 1) and try to commit on top of it.
    await khata.db.customStatement(
      'UPDATE account_balances SET credit_minor = credit_minor + 1 WHERE ledger_id = ?',
      [ledgerId],
    );
    await expectLater(
      book.commitChecked(
        () => book.postExpense(
          entryDate: today,
          amountMinor: 100,
          role: AccountRole.miscExpense,
        ),
        check: CommitCheck.full,
      ),
      throwsA(
        isA<InvariantViolation>()
            .having((e) => e.invariantCode, 'invariantCode', 'GATE-2'),
      ),
    );

    // …and the expense really is gone: the gate rolled the transaction back.
    final expenses = await khata.db
        .customSelect(
          'SELECT COUNT(*) AS n FROM journal_entries WHERE memo = ?',
          variables: [const Variable('Expense')],
        )
        .get();
    expect(expenses.first.read<int>('n'), 0);

    // The repair path leaves the book clean, and the warning is all that is left.
    await book.rebuildCaches();
    final after = await book.audit();
    expect(after.findings.where((f) => f.isCritical), isEmpty);
  });

  test('the report is versioned, so a fix to it can be detected', () async {
    final row = await khata.db
        .customSelect(
          "SELECT value FROM schema_meta WHERE key = 'integrity_report_version'",
        )
        .get();
    expect(int.parse(row.first.read<String>('value')), greaterThanOrEqualTo(2),
        reason: 'migration 010 rewrote the report; the version records that');
  });
}
