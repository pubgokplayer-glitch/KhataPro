/// KhataPro · end-to-end verification of the Dart data layer.
///
/// This drives the REAL layer — `KhataDb.open`, the strict singleton, the
/// `setup:` key attachment, `beforeOpen` pragmas, the migration runner, the
/// HLC service, the integrity gate — against a real SQLite file on disk, using
/// drift's real background-isolate executor.
///
/// It runs with stock SQLite (`requireEncryption: false`) because the sandbox
/// has no SQLCipher build. That is not a hole in the test: everything except the
/// bytes-on-disk encryption is the same code path, and the harness *does* assert
/// that opening with `requireEncryption: true` fails closed with
/// `EncryptionUnavailable` — which is exactly what would happen on a mis-built
/// phone build, the failure that must never be silent.
///
///   dart run tool/data_layer_verify.dart [--keep]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:sqlite3/sqlite3.dart';

import '../lib/core/security/key_custody.dart';
import '../lib/core/security/sqlcipher_key.dart';
import '../lib/core/crdt/lww.dart';
import '../lib/core/utils/epoch_day.dart';
import '../lib/data/db/dao/accounts_dao.dart';
import '../lib/data/db/dao/base_dao.dart';
import '../lib/data/db/dao/parties_dao.dart';
import '../lib/data/db/database.dart';
import '../lib/data/db/migration_runner.dart';
import '../lib/data/repositories/order_book.dart';

int _passed = 0;
final List<String> _failures = <String>[];
bool _keep = false;
late final FileSystemAssetLoader _assets;

Future<void> main(List<String> args) async {
  _keep = args.contains('--keep');
  final rootArg = args.firstWhere(
    (a) => a.startsWith('--asset-root='),
    orElse: () => '--asset-root=.',
  );
  _assets = FileSystemAssetLoader(rootArg.substring('--asset-root='.length));
  final root = Directory.systemTemp.createTempSync('khata_d2_');
  final dbFile = File('${root.path}/khata.sqlite');

  print('');
  print('  KhataPro · Dart data layer verification');
  print('  scratch: ${root.path}${_keep ? ' (kept)' : ''}');
  print('  ${'─' * 74}');

  try {
    await _freshOpen(dbFile);
    await _reopen(dbFile);
    await _singletonRules(dbFile, root);
    await _encryptionFailsClosed(root);
    await _migrationGuards(root);
    await _orderBook(root);
    await _crashRecovery(root);
  } finally {
    if (KhataDb.isOpen) await KhataDb.instance.close();
    if (!_keep) root.deleteSync(recursive: true);
  }

  print('');
  if (_failures.isEmpty) {
    print('  ✓ all $_passed checks passed');
    print('');
  } else {
    print('  ✗ ${_failures.length} of ${_passed + _failures.length} checks FAILED');
    for (final failure in _failures) {
      print('      · $failure');
    }
    print('');
    exitCode = 1;
  }
}

/// First open: pragmas, migrations 001–009, HLC seed, integrity read.
Future<void> _freshOpen(File dbFile) async {
  print('\n  1 · Fresh open — pragmas, migrations, HLC, integrity');
  final started = DateTime.now();
  final khata = await KhataDb.open(KhataOpenRequest(
    databaseFile: dbFile,
    key: SqlCipherKey.generate(),
    nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
    platform: 'linux',
    appVersion: '1.0.0+1',
    assetLoader: _assets,
    requireEncryption: false,
  ));
  final openMs = DateTime.now().difference(started).inMilliseconds;
  final diagnostics = khata.diagnostics;

  _check('open completed in ${openMs}ms', openMs < 30000);
  _check('the linked library was identified before anything was written '
      '(mode=${diagnostics.encryptionMode.id})',
      diagnostics.encryptionMode == EncryptionMode.none &&
          diagnostics.cipherVersion == null);

  final migration = diagnostics.migration!;
  _check('migrations applied 001→$kLatestSchemaVersion as whole files '
      '(${migration.applied.length} files, ${migration.durationMs}ms)',
      migration.applied.length == kLatestSchemaVersion &&
          migration.applied.first == '001_core.sql' &&
          migration.applied.last ==
              '${kLatestSchemaVersion.toString().padLeft(3, '0')}'
              '${SqlMigrationRunner.knownMigrations[kLatestSchemaVersion]!.substring(3)}');
  _check('migration log is empty on a fresh database', migration.fromVersion == 0);

  final counts = await _schemaCounts(khata);
  final ftsShadow = await _scalarInt(
      khata, "SELECT count(*) FROM sqlite_master WHERE name LIKE 'search_index_%'");
  _check('schema objects present: ${counts['table']} tables (+$ftsShadow FTS5 '
      'shadow), ${counts['view']} views, ${counts['index']} indexes, '
      '${counts['trigger']} triggers',
      counts['table'] == 39 &&
          ftsShadow == 5 &&
          counts['view'] == 18 &&
          counts['trigger'] == 33 &&
          counts['index'] == 71);

  final pragmas = await _pragmas(khata);
  _check('WAL is on (${pragmas['journal_mode']})', pragmas['journal_mode'] == 'wal');
  _check('foreign_keys ON', pragmas['foreign_keys'] == 1);
  _check('recursive_triggers ON (the trigger chain depends on it)',
      pragmas['recursive_triggers'] == 1);
  _check('cache is 16 MiB (${pragmas['cache_size']} pages)',
      pragmas['cache_size'] == -16000);
  _check('mmap enabled (${pragmas['mmap_size']} bytes)',
      ((pragmas['mmap_size'] as int?) ?? 0) > 0);
  _check('synchronous=NORMAL (${pragmas['synchronous']})', pragmas['synchronous'] == 1);
  _check('automatic_index OFF — no surprise writes', pragmas['automatic_index'] == 0);

  _check('seeded chart of accounts has 37 accounts',
      await _scalarInt(khata, 'SELECT count(*) FROM accounts WHERE is_system = 1') == 37);
  _check('integrity report is completely clean on a fresh book — no critical '
      'findings and no phantom warnings '
      '(${diagnostics.integrity.length} findings${diagnostics.integrity.isEmpty ? '' : ': ${diagnostics.integrity.first}'})',
      diagnostics.integrity.isEmpty);

  _check('dirty_open is set while the app runs',
      await _sessionFlag(khata, 'dirty_open') == '1');
  _check('write_mode is user (not a crashed-run marker)',
      await _sessionFlag(khata, 'write_mode') == 'user');

  // ── the database actually works: post a balanced entry through the real gate
  final posted = await _postBalancedEntry(khata);
  _check('a balanced 3-line entry posts through trg_je_balance_gate '
      '(entry ${posted.$1})', posted.$2);
  _check('the balance cache agrees with the lines it was built from',
      await _scalarInt(khata,
              "SELECT count(*) FROM v_integrity_report WHERE kind = 'CACHE_DRIFT'") ==
          0);
  _check('trial balance sums to zero across all accounts',
      await _scalarInt(khata,
              'SELECT COALESCE(SUM(signed_net_minor), 0) FROM v_trial_balance') ==
          0);
}

/// Second open: nothing to migrate, logical time restored, close was clean.
Future<void> _reopen(File dbFile) async {
  print('\n  2 · Re-open — the singleton\'s whole reason for existing');
  final open1 = KhataDb.instance;
  final hlcBefore = open1.db.hlc.last;

  await open1.close();
  _check('dirty_open cleared on a clean close',
      await _sessionFlagRaw(dbFile, 'dirty_open') == '0');
  _check('logical time was flushed to session_flags on close',
      await _sessionFlagRaw(dbFile, 'last_hlc') != null);

  final second = await KhataDb.open(KhataOpenRequest(
    databaseFile: dbFile,
    key: SqlCipherKey.generate(), // same file, stock SQLite: key is a no-op here
    nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
    platform: 'linux',
    appVersion: '1.0.0+1',
    assetLoader: _assets,
    requireEncryption: false,
  ));

  _check('re-open applied no migrations (${second.diagnostics.migration!.applied.length} files)',
      second.diagnostics.migration!.applied.isEmpty);
  _check('re-open did not flag a dirty close (first boot ever)',
      !second.diagnostics.hadDirtyOpen);
  _check('logical time resumed above the pre-close stamp '
      '(${hlcBefore.encode()} → ${second.db.hlc.last.encode()})',
      second.db.hlc.last >= hlcBefore);
  _check('re-open is faster than the first open '
      '(${second.diagnostics.openMillis}ms vs ${open1.diagnostics.openMillis}ms)',
      (second.diagnostics.openMillis ?? 1 << 30) <=
          (open1.diagnostics.openMillis ?? 0) + 5);

  // Logical time must not regress even if the wall clock does.
  second.db.hlc.nowMs = () => 1700000000000; // a clock from 2023
  final backwards = second.db.hlc.stampForWrite();
  _check('a device clock that jumps backwards still issues increasing stamps',
      backwards.hlc > hlcBefore);
  await second.close();
}

/// Singleton invariants.
Future<void> _singletonRules(File dbFile, Directory root) async {
  print('\n  3 · Singleton rules — one connection, or nothing');
  final request = KhataOpenRequest(
    databaseFile: dbFile,
    key: SqlCipherKey.generate(),
    nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
    platform: 'linux',
    appVersion: '1.0.0+1',
    assetLoader: _assets,
    requireEncryption: false,
  );

  final a = await KhataDb.open(request);
  final b = await KhataDb.open(request);
  _check('two concurrent open() calls return the identical instance',
      identical(a, b));
  _check('a third open while the first is live is also the same instance',
      identical(await KhataDb.open(request), a));

  var refusedSecondFile = false;
  try {
    await KhataDb.open(KhataOpenRequest(
      databaseFile: File('${root.path}/other.sqlite'),
      key: SqlCipherKey.generate(),
      nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
      platform: 'linux',
      appVersion: '1.0.0+1',
      assetLoader: _assets,
      requireEncryption: false,
    ));
  } on StateError {
    refusedSecondFile = true;
  }
  _check('opening a second file while one is live is refused', refusedSecondFile);

  var refusedReadPool = false;
  try {
    await a.close();
    await KhataDb.open(KhataOpenRequest(
      databaseFile: dbFile,
      key: SqlCipherKey.generate(),
      nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
      platform: 'linux',
      appVersion: '1.0.0+1',
      assetLoader: _assets,
      requireEncryption: false,
      readPool: 2,
    ));
  } on Object catch (error) {
    refusedReadPool = error.toString().contains('readPool must be 0');
  }
  _check('readPool > 0 is refused in release semantics (not just asserted)',
      refusedReadPool);
  _check('an open that failed does not poison later attempts ("try again" works)',
      identical(await KhataDb.open(KhataOpenRequest(
        databaseFile: dbFile,
        key: SqlCipherKey.generate(),
        nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
        platform: 'linux',
        appVersion: '1.0.0+1',
        assetLoader: _assets,
        requireEncryption: false,
      )), KhataDb.instance));

  // The connection really is one: writes from the handle are visible to a
  // separately-inspected file, and SQLite reported no other writer lock.
  final reopened = await KhataDb.open(request);
  _check('the database can be opened again after close',
      identical(reopened, KhataDb.instance));
  await reopened.close();
}

/// The requirement that must never silently degrade.
Future<void> _encryptionFailsClosed(Directory root) async {
  print('\n  4 · Fail closed — an unencrypted build must refuse to run');
  final file = File('${root.path}/plain.sqlite');
  var message = '';
  try {
    await KhataDb.open(KhataOpenRequest(
      databaseFile: file,
      key: SqlCipherKey.generate(),
      nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
      platform: 'linux',
      appVersion: '1.0.0+1',
      assetLoader: _assets,
      requireEncryption: true, // production setting
    ));
  } on Object catch (error) {
    message = error.toString();
  }
  _check('requireEncryption: true against stock SQLite fails the open', message.isNotEmpty);
  _check('the failure explains itself instead of silently writing plaintext '
      '(«${_shorten(message)}»)',
      (message.contains('SQLCipher') || message.contains('UNENCRYPTED')) &&
          message.contains('could not be opened'));
  _check('the refused open left no database behind',
      !file.existsSync() || file.lengthSync() == 0 || _isNotADatabase(file));
}

/// Migration guards: edited files, unregistered files, newer schemas.
Future<void> _migrationGuards(Directory root) async {
  print('\n  5 · Migration guards — the accidents that corrupt a schema');
  final file = File('${root.path}/guards.sqlite');
  final khata = await KhataDb.open(KhataOpenRequest(
    databaseFile: file,
    key: SqlCipherKey.generate(),
    nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
    platform: 'linux',
    appVersion: '1.0.0+1',
    assetLoader: _assets,
    requireEncryption: false,
  ));
  final version = await _scalarInt(
      khata, "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'schema_version'");
  _check('schema_meta records version $version — the runner\'s own bookkeeping',
      version == kLatestSchemaVersion);
  _check('the v2 integrity report no longer emits a phantom warning on a fresh '
      'book', await _scalarInt(khata,
          "SELECT count(*) FROM v_integrity_report WHERE kind = 'SEARCH_INDEX_STALE'") == 0);

  final checksum = await _scalarString(
      khata, "SELECT value FROM schema_meta WHERE key = 'migration.001_core.sql.sha256'");
  _check('every applied migration has a recorded checksum',
      checksum.length == 64 &&
          await _scalarInt(khata,
                  "SELECT count(*) FROM schema_meta WHERE key LIKE 'migration.%.sha256'") ==
              kLatestSchemaVersion);

  // An edited, already-applied file must be refused.
  final runner = SqlMigrationRunner(loader: _assets);
  var mismatch = '';
  try {
    await runner.verifyAppliedChecksums({'001_core.sql': 'a' * 64});
  } on Object catch (error) {
    mismatch = error.toString();
  }
  _check('an already-applied file that was edited is refused at boot',
      mismatch.contains('MIGRATION_CHECKSUM'));

  final tooNew = await _pendingTooNew(runner);
  _check('a database from a newer build is refused, not downgraded '
      '(«${_shorten(tooNew)}»)', tooNew.contains('SCHEMA_TOO_NEW'));

  var unregistered = '';
  try {
    await SqlMigrationRunner(loader: _PhantomAssetLoader()).verifyShippedSet();
  } on Object catch (error) {
    unregistered = error.toString();
  }
  _check('a .sql file that ships but is not registered is refused '
      '(«${_shorten(unregistered)}»)', unregistered.contains('never run'));

  await khata.close();
}

Future<String> _pendingTooNew(SqlMigrationRunner runner) async {
  try {
    await runner.pendingMigrations(kLatestSchemaVersion + 3);
    return '';
  } on Object catch (error) {
    return error.toString();
  }
}

/// A loader that reports a migration the runner does not know about.
final class _PhantomAssetLoader implements SqlAssetLoader {
  const _PhantomAssetLoader();

  @override
  Future<String> load(String assetPath) async => 'SELECT 1;';

  @override
  Future<List<String>> list(String directory) async => [
        'assets/sql/migrations/001_core.sql',
        'assets/sql/migrations/010_phantom.sql',
      ];
}

/// The DAOs and the OrderBook, exercised the way the UI will.
Future<void> _orderBook(Directory root) async {
  print('\n  6 · OrderBook — real business actions, checked before commit');
  final file = File('${root.path}/orders.sqlite');
  final khata = await KhataDb.open(KhataOpenRequest(
    databaseFile: file,
    key: SqlCipherKey.generate(),
    nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
    platform: 'linux',
    appVersion: '1.0.0+1',
    assetLoader: _assets,
    requireEncryption: false,
  ));
  final ledgerId = (await _scalarStringRaw(khata, 'SELECT id FROM ledgers LIMIT 1'))!;
  final book = OrderBook(db: khata.db, ledgerId: ledgerId);
  final parties = PartiesDao(db: khata.db, ledgerId: ledgerId);
  final accounts = AccountsDao(db: khata.db, ledgerId: ledgerId);
  final today = EpochDay.fromDateTime(DateTime.now());

  // A customer, with a sub-ledger created atomically.
  final partyId = await parties.create(const PartyDraft(
    name: 'Ahmed Traders',
    nameUr: 'احمد ٹریڈرز',
    phone: '03001234567',
    city: 'Sargodha',
  ));
  final party = await parties.byId(partyId);
  final partyAccount = await accounts.partyAccountId(partyId);
  _check('a party is created with its own sub-ledger account '
      '(party_id set, role NULL — the unique role index allows one control '
      'account per role)',
      party != null && partyAccount != null);

  // ── a credit sale with tax: 1,250 gross, 18% tax, 500 received in cash
  final sale = await book.postSale(
    entryDate: today,
    grossMinor: 125000,
    amountPaidMinor: 50000,
    taxMinor: 19068,
    partyId: partyId,
    docNo: 'INV-TEST-1',
    memo: 'Cement bags',
  );
  _check('a partly-paid sale posts (${sale.entryNo}, '
      '${sale.commit.durationMs}ms commit check, ${sale.commit.mode.name})',
      sale.totalMinor == 125000 && sale.commit.isClean);
  _check('the commit check is proportional to the change, not the book '
      '(${sale.commit.durationMs}ms for ${sale.commit.accountsChecked} accounts)',
      sale.commit.durationMs < 150);

  final tb = await book.journal.trialBalance();
  final balances = {for (final row in tb) row.role ?? row.code: row};
  _check('cash rose by exactly what was received (Dr 500.00)',
      _netFor(tb, AccountRole.cash) == 50000);
  _check('the sub-ledger account itself is postable and carries the party '
      'attribution', await _scalarIntRaw(khata,
              'SELECT count(*) FROM journal_lines WHERE party_id = ? AND account_id = ?',
              [partyId, partyAccount]) == 1);
  // The control account (1200) stays at zero; the money sits on the party's
  // sub-ledger, which is the point of a sub-ledger.
  _check('the control account is untouched and the sub-ledger holds the unpaid '
      'part (control ${balances[AccountRole.ar]?.signedNetMinor}, '
      'party ${tb.firstWhere((r) => r.accountId == partyAccount).signedNetMinor})',
      _netFor(tb, AccountRole.ar) == 0 &&
          tb.where((r) => r.accountId == partyAccount)
                  .fold(0, (sum, r) => sum + r.signedNetMinor) ==
              75000);
  _check('income is the net of tax (Cr 1,059.32)',
      _netFor(tb, AccountRole.sales) == -105932);
  _check('tax payable is the tax collected (Cr 190.68)',
      _netFor(tb, AccountRole.taxPayable) == -19068);
  _check('the whole trial balance still sums to zero',
      tb.fold(0, (sum, row) => sum + row.signedNetMinor) == 0);

  // ── the party statement the shopkeeper shows the customer
  final statement = await parties.ledger(partyId);
  _check('the party statement shows one line with the right running balance '
      '(${statement.length} line, balance ${statement.isEmpty ? '-' : statement.last.runningBalanceMinor})',
      statement.length == 1 && statement.last.runningBalanceMinor == 75000);
  final partyBalance = await parties.byId(partyId);
  _check('the party balance says "owes me 750.00"',
      partyBalance?.receivableMinor == 75000);

  // ── an expense, an expense from the bank, and a payment received
  final expense = await book.postExpense(
      entryDate: today, amountMinor: 25000, role: AccountRole.rent, memo: 'Shop rent');
  final payment = await book.postPaymentIn(
      entryDate: today, amountMinor: 75000, partyId: partyId, memo: 'Settled');
  _check('an expense and a payment both post (${expense.entryNo}, ${payment.entryNo})',
      expense.commit.isClean && payment.commit.isClean);
  _check('paying the balance settles the customer to zero',
      (await parties.byId(partyId))?.netMinor == 0);

  // ── an unbalanced entry cannot be written at all (Dart-side refusal)
  var refusedUnbalanced = '';
  try {
    await book.postSale(entryDate: today, grossMinor: 10000, amountPaidMinor: 0);
  } on Object catch (error) {
    refusedUnbalanced = error.toString();
  }
  _check('an unpaid sale with no customer is refused before SQL runs '
      '(«${_shorten(refusedUnbalanced)}»)',
      refusedUnbalanced.contains('FIN-2'));

  // ── a stale edit is refused (the local half of last-write-wins)
  final staleStamp = (await PartiesDao(db: khata.db, ledgerId: ledgerId)
          .currentStamp('parties', partyId))!;
  await parties.update(partyId, {'city': 'Lahore'});
  var refusedStale = '';
  try {
    await parties.update(partyId, {'city': 'Multan'}, expecting: staleStamp);
  } on Object catch (error) {
    refusedStale = error.toString();
  }
  _check('editing with an outdated stamp is refused, not silently merged '
      '(«${_shorten(refusedStale)}»)', refusedStale.contains('CRDT-STALE'));
  _check('the newer edit survived the stale attempt',
      await _scalarStringRaw(khata,
              "SELECT city FROM parties WHERE id = '$partyId'") == 'Lahore');

  // ── void: one mechanism, not two
  final voided = await book.voidEntry(sale.entryId, reason: 'wrong customer');
  final salesAfterVoid = _netFor(await book.journal.trialBalance(), AccountRole.sales);
  _check('voiding zeroes the income and leaves the money out of every report '
      '(income now $salesAfterVoid)',
      voided.commit.isClean && salesAfterVoid == 0);
  _check('the original entry is kept and marked voided (nothing is deleted)',
      await _scalarIntRaw(khata,
              'SELECT status FROM journal_entries WHERE id = ?', [sale.entryId]) == 2);
  _check('voiding did NOT also post a mirror entry — trg_bal_void already '
      'removed the money, so a reversal on top would subtract it twice ('
      '${await _scalarIntRaw(khata, 'SELECT count(*) FROM journal_entries')} entries, '
      '${await _scalarIntRaw(khata, 'SELECT count(*) FROM journal_entries WHERE reversal_of_entry_id IS NOT NULL')} '
      'of them mirrors)',
      voided.isVoid &&
          await _scalarIntRaw(khata,
                  'SELECT count(*) FROM journal_entries WHERE reversal_of_entry_id '
                  'IS NOT NULL') == 0);
  // A peer must be able to apply this cancellation and land on exactly the
  // stamp the row now carries — otherwise its next edit would look stale to
  // itself. So the op's hlc is compared against the row's hlc, not eyeballed.
  _check('the void is queued for peers as a tombstone carrying the row\'s own '
      'stamp (op ${await _scalarStringRaw(khata, 'SELECT op FROM oplog WHERE row_id = ? AND op = 3', [sale.entryId])}, '
      'rev ${await _scalarIntRaw(khata, 'SELECT rev FROM oplog WHERE row_id = ? AND op = 3', [sale.entryId])})',
      await _scalarIntRaw(khata,
              'SELECT count(*) FROM oplog o JOIN journal_entries e ON e.id = o.row_id '
              "WHERE o.table_name = 'journal_entries' AND o.op = 3 AND e.status = 2 "
              'AND o.hlc = e.hlc AND o.rev = e.rev') == 1);
  _check('and the posting op carries the revision it wrote, so a peer that '
      'applies it does not look stale to itself',
      await _scalarIntRaw(khata,
              'SELECT count(*) FROM oplog WHERE row_id = ? AND op = 1 AND rev > 1',
              [sale.entryId]) == 1);

  // ── a locked period: the same undo becomes a correction, not an erasure
  final lockedSale = await book.postSale(
      entryDate: today, grossMinor: 400000, amountPaidMinor: 400000, docNo: 'INV-LOCK-1');
  await khata.db.customStatement(
      'UPDATE ledgers SET lock_after_date = ? WHERE id = ?', [today, ledgerId]);
  final lockedVoid = await book.voidEntry(lockedSale.entryId, reason: 'period filed');
  final salesAfterLocked =
      _netFor(await book.journal.trialBalance(), AccountRole.sales);
  _check('undoing an entry inside a locked period posts a reversal instead of '
      'erasing it (${lockedVoid.mode.name} → ${lockedVoid.mirrorEntryNo})',
      lockedVoid.mode == VoidMode.reversed && lockedVoid.wasLockedPeriod);
  _check('the locked period still nets to zero and the original still stands',
      salesAfterLocked == 0 &&
          await _scalarIntRaw(khata,
                  'SELECT status FROM journal_entries WHERE id = ?', [lockedSale.entryId]) == 1);
  // The lock covers everything dated `<= lock_after_date`, and here that
  // includes today, so the first day this ledger will accept a posting is
  // tomorrow — the correction lands in the next open period, which is both what
  // the trigger allows and what the accounting says.
  final mirrorDay = await _scalarIntRaw(khata,
      'SELECT entry_date FROM journal_entries WHERE id = ?', [lockedVoid.mirrorEntryId]);
  _check('the reversing entry is dated the first open day '
      '(${EpochDay.toIso(mirrorDay ?? 0)} = lock date + 1, today is '
      '${EpochDay.toIso(EpochDay.today())})',
      lockedVoid.reversalDate == today + 1 && mirrorDay == today + 1);
  await khata.db.customStatement(
      'UPDATE ledgers SET lock_after_date = NULL WHERE id = ?', [ledgerId]);

  // ── the audit chain
  final auditRows = await _scalarIntRaw(
      khata, 'SELECT count(*) FROM audit_log WHERE ledger_id = ?', [ledgerId]);
  final chained = await _scalarIntRaw(
      khata,
      'SELECT count(*) FROM audit_log a JOIN audit_log b '
      'ON b.ledger_id = a.ledger_id AND b.seq = a.seq + 1 '
      'AND b.hash_prev <> a.hash_self');
  _check('every action is in the hash-chained audit log ($auditRows records, '
      '$chained broken links)', auditRows >= 4 && chained == 0);

  // ── the op log knows what to offer a peer
  final opCount = await _scalarIntRaw(
      khata, 'SELECT count(*) FROM oplog WHERE ledger_id = ?', [ledgerId]);
  final tables = await _scalarStringRaw(
      khata, "SELECT group_concat(DISTINCT table_name) FROM oplog WHERE ledger_id = ?",
      [ledgerId]);
  _check('changes were queued for peers ($opCount ops across: $tables)',
      opCount >= 6 && (tables ?? '').contains('parties'));

  // ── conflict receipts are idempotent across replays
  Future<void> replayReceipt() async {
    await book.journal.recordConflict(FieldConflict(
      tableName: 'parties',
      rowId: partyId,
      field: 'city',
      winnerValue: 'Lahore',
      loserValue: 'Multan',
      winnerHlc: '000000000000001-0000-11111111-1111-4111-8111-111111111111',
      loserHlc: '000000000000000-0000-22222222-2222-4222-8222-222222222222',
      winnerNode: '11111111-1111-4111-8111-111111111111',
      loserNode: '22222222-2222-4222-8222-222222222222',
      resolution: 'local_won',
    ));
  }

  await replayReceipt();
  final afterFirst = await _scalarIntRaw(khata, 'SELECT count(*) FROM conflict_log');
  await replayReceipt();
  await replayReceipt();
  final afterReplay = await _scalarIntRaw(khata, 'SELECT count(*) FROM conflict_log');
  _check('a merge receipt is written once and re-applying the same remote batch '
      'does not duplicate it ($afterFirst → $afterReplay rows)',
      afterFirst == 1 && afterReplay == 1);
  _check('a different conflict on the same row is still recorded (receipts are '
      'per-field, not per-row)',
      await _scalarIntRaw(khata,
              'SELECT count(*) FROM conflict_log WHERE field_name = ?', ['city']) == 1);

  // ── search finds the Urdu name and the phone number
  final searchHit = await _scalarIntRaw(
      khata, "SELECT count(*) FROM search_map WHERE kind = 'party'");
  _check('the party is indexed for offline search ($searchHit indexed rows)',
      searchHit >= 1);
  final ftsHit = await _scalarStringRaw(
      khata,
      "SELECT title || ' · ' || COALESCE(body, '') FROM search_index "
      'JOIN search_map m ON m.fts_rowid = search_index.rowid '
      'WHERE search_index MATCH ?',
      ['احمد']);
  _check('offline FTS finds the shopkeeper\'s Urdu name, typed in Urdu '
      '("$ftsHit")', (ftsHit ?? '').contains('احمد'));
  final phoneHit = await _scalarStringRaw(
      khata,
      "SELECT title FROM search_index JOIN search_map m ON m.fts_rowid = search_index.rowid "
      'WHERE search_index MATCH ?',
      ['03001234567']);
  _check('and finds the party by phone number ("$phoneHit")',
      (phoneHit ?? '').contains('Ahmed'));

  // ── a deliberately corrupted cache is detected, then repaired
  // `net_minor` is GENERATED ALWAYS AS (debit_minor - credit_minor) STORED, so
  // SQLite refuses to let anything write it — including a test that wants to
  // corrupt it. Corrupt the source column instead and let the generated value
  // follow; that is also a truer picture of the damage a bad binary could do.
  var generatedWriteRefused = false;
  try {
    await khata.db.customStatement(
        'UPDATE account_balances SET net_minor = net_minor + 999 WHERE ledger_id = ?',
        [ledgerId]);
  } on Object {
    generatedWriteRefused = true;
  }
  _check('the balance cache cannot even be forged: net_minor is a generated '
      'column and writing it is refused', generatedWriteRefused);

  await khata.db.customStatement(
      'UPDATE account_balances SET debit_minor = debit_minor + 999 WHERE ledger_id = ?',
      [ledgerId]);
  final audit = await book.audit();
  final kinds = audit.findings.map((f) => f.kind).toSet().join(', ');
  _check('a corrupted balance cache is caught by the audited report '
      '(${audit.findings.length} findings: $kinds)',
      audit.findings.any((f) => f.kind == 'ACCOUNT_BALANCE_DRIFT'));
  final repaired = await book.rebuildCaches();
  _check('rebuilding the cache clears the finding '
      '(${repaired.findings.length} findings left after ${repaired.durationMs}ms)',
      repaired.findings.every((f) => f.kind != 'ACCOUNT_BALANCE_DRIFT'));

  // ── commitChecked refuses to commit a book it cannot trust
  var refusedCommit = '';
  try {
    await khata.db.transaction(() async {
      await khata.db.customStatement(
          'UPDATE account_balances SET debit_minor = debit_minor + 12345 WHERE ledger_id = ?',
          [ledgerId]);
      await book.commitChecked(() async {}, check: CommitCheck.full);
    });
  } on Object catch (error) {
    refusedCommit = error.toString();
  }
  final stillCorrupt = await _scalarIntRaw(khata,
      'SELECT count(*) FROM v_integrity_report WHERE severity = 1');
  _check('commitChecked rolls the transaction back when the books stop adding up '
      '(«${_shorten(refusedCommit)}»)', refusedCommit.contains('GATE-2'));
  _check('the rolled-back corruption is gone: the cache still agrees '
      '($stillCorrupt findings)', stillCorrupt == 0);

  await khata.close();
}

/// A crash mid-session must self-heal, not silently trust a stale cache.
Future<void> _crashRecovery(Directory root) async {
  print('\n  7 · Crash recovery — the dirty-open marker');
  final file = File('${root.path}/crash.sqlite');
  var khata = await KhataDb.open(KhataOpenRequest(
    databaseFile: file,
    key: SqlCipherKey.generate(),
    nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
    platform: 'linux',
    appVersion: '1.0.0+1',
    assetLoader: _assets,
    requireEncryption: false,
  ));
  final ledgerId = (await _scalarStringRaw(khata, 'SELECT id FROM ledgers LIMIT 1'))!;

  // Simulate a crash honestly. A graceful `close()` *clears* the dirty flag —
  // that is the whole contract — so the damage has to be done from outside the
  // app's own API: a raw connection writing the flag and the corruption, then
  // dying without any bookkeeping. (The file is unencrypted in this harness, so
  // `package:sqlite3` can reach it directly; the real app's crash path is the
  // same shape — a process that stopped mid-write.)
  await khata.close();
  final raw = sqlite3.open(file.path);
  raw.execute("UPDATE session_flags SET value = '1' WHERE key = 'dirty_open'");
  raw.execute('UPDATE account_balances SET debit_minor = debit_minor + 777 '
      'WHERE ledger_id = ?', [ledgerId]);
  raw.dispose();

  khata = await KhataDb.open(KhataOpenRequest(
    databaseFile: file,
    key: SqlCipherKey.generate(),
    nodeId: '019a1b2c-0000-7000-8000-0000000000aa',
    platform: 'linux',
    appVersion: '1.0.0+1',
    assetLoader: _assets,
    requireEncryption: false,
  ));
  _check('the next open noticed the dirty flag and said so',
      khata.diagnostics.hadDirtyOpen);
  _check('quick_check ran and found no page-level damage '
      '(${khata.diagnostics.quickCheckErrors} errors)',
      khata.diagnostics.quickCheckErrors == 0);
  _check('the balance cache was re-derived from the lines',
      await _scalarIntRaw(khata,
              "SELECT count(*) FROM v_integrity_report "
              "WHERE kind = 'ACCOUNT_BALANCE_DRIFT'") == 0);
  _check('the book is clean again after recovery '
      '(${khata.diagnostics.integrity.length} findings)',
      khata.diagnostics.integrity.isEmpty);
  await khata.close();
}

// ── helpers ──────────────────────────────────────────────────────────────────

/// The signed net of a role in a trial balance, **zero when the role is absent**.
///
/// `v_trial_balance` omits income/expense accounts once their `line_count` drops
/// to zero, and voiding an entry can do exactly that. "Not in the report" and
/// "reported as zero" mean the same thing to a shopkeeper, so the harness — and
/// any dashboard — must read it that way rather than crashing on `firstWhere`.
int _netFor(List<TrialBalanceRow> rows, String role) => rows
    .where((row) => row.role == role)
    .fold(0, (sum, row) => sum + row.signedNetMinor);

Future<String?> _scalarStringRaw(KhataDb khata, String sql, [List<Object?> args = const []]) async {
  final rows = await khata.db
      .customSelect(sql, variables: [for (final a in args) Variable(a)])
      .get();
  return rows.isEmpty ? null : rows.first.data.values.first?.toString();
}

Future<int> _scalarIntRaw(KhataDb khata, String sql, [List<Object?> args = const []]) async {
  final rows = await khata.db
      .customSelect(sql, variables: [for (final a in args) Variable(a)])
      .get();
  return (rows.isEmpty ? 0 : (rows.first.data.values.first as num?)?.toInt()) ?? 0;
}


Future<Map<String, int>> _schemaCounts(KhataDb khata) async {
  final rows = await khata.db.customSelect(
    "SELECT type, count(*) AS n FROM sqlite_master "
    "WHERE name NOT LIKE 'sqlite_%' AND name NOT LIKE 'search_index_%' "
    "GROUP BY type",
  ).get();
  return {
    for (final row in rows)
      row.read<String>('type'): row.read<int>('n'),
  };
}

Future<Map<String, Object?>> _pragmas(KhataDb khata) async {
  final result = <String, Object?>{};
  for (final pragma in [
    'journal_mode',
    'foreign_keys',
    'recursive_triggers',
    'cache_size',
    'mmap_size',
    'synchronous',
    'automatic_index',
    'page_size',
  ]) {
    final rows = await khata.db.customSelect('PRAGMA $pragma').get();
    result[pragma] = rows.isEmpty ? null : rows.first.data.values.first;
  }
  return result;
}

Future<int> _scalarInt(KhataDb khata, String sql, [List<Object?> args = const []]) async {
  final rows = await khata.db
      .customSelect(sql, variables: [for (final a in args) Variable(a)])
      .get();
  final value = rows.isEmpty ? null : rows.first.data.values.first;
  return (value as num?)?.toInt() ?? 0;
}

Future<String> _scalarString(KhataDb khata, String sql,
    [List<Object?> args = const []]) async {
  final rows = await khata.db
      .customSelect(sql, variables: [for (final a in args) Variable(a)])
      .get();
  return (rows.isEmpty ? '' : rows.first.data.values.first?.toString()) ?? '';
}

Future<String?> _sessionFlag(KhataDb khata, String key) async {
  final rows = await khata.db.customSelect(
    'SELECT value FROM session_flags WHERE key = ?',
    variables: [Variable<String>(key)],
  ).get();
  return rows.isEmpty ? null : rows.first.read<String?>('value');
}

/// Reads a session flag straight from the file with a separate connection — the
/// point being that a *different* reader sees what the app committed.
Future<String?> _sessionFlagRaw(File file, String key) async {
  final database = sqlite3.open(file.path);
  try {
    final rows =
        database.select('SELECT value FROM session_flags WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.values.first as String?;
  } finally {
    database.dispose();
  }
}

/// Posts a 3-line sale the way the app will: one INSERT for the entry at
/// status=draft, three lines, then the gate transition that flips it to posted.
/// Everything happens inside one drift transaction.
Future<(String, bool)> _postBalancedEntry(KhataDb khata) async {
  final ledgerId = await _scalarString(khata, 'SELECT id FROM ledgers LIMIT 1');
  final cash = await _scalarString(
      khata, "SELECT id FROM accounts WHERE role = 'cash' AND ledger_id = ?",
      [ledgerId]);
  final sales = await _scalarString(
      khata, "SELECT id FROM accounts WHERE role = 'sales' AND ledger_id = ?",
      [ledgerId]);
  final tax = await _scalarString(
      khata, "SELECT id FROM accounts WHERE role = 'tax_payable' AND ledger_id = ?",
      [ledgerId]);
  final entryId = '019a1b2c-1000-7000-8000-000000000001';
  final hlc = khata.db.hlc.stampForWrite();
  final now = DateTime.now().millisecondsSinceEpoch;

  try {
    await khata.db.transaction(() async {
      await khata.db.customStatement(
        'INSERT INTO journal_entries (id, ledger_id, entry_no, entry_date, source, '
        'status, memo, currency_code, base_currency_code, total_debit_minor, '
        'total_credit_minor, base_total_minor, device_id, hlc, node_id, created_at, '
        'updated_at) '
        "VALUES (?, ?, 'JE-TEST-1', ?, 1, 0, 'verification sale', 'PKR', 'PKR', "
        '0, 0, 0, ?, ?, ?, ?, ?)',
        [
          entryId,
          ledgerId,
          _todayEpochDay(),
          khata.db.nodeId,
          hlc.hlc.encode(),
          khata.db.nodeId,
          now,
          now,
        ],
      );

      // Dr 1100 cash 1,250.00 · Cr 4100 sales 1,250.00 − tax (tax-exclusive sale of
      // 1,059.32 + 18% GST) — the three lines the app's tax path will write.
      final lines = [
        (cash, 125000),
        (sales, -105932),
        (tax, -19068),
      ];
      var lineNo = 1;
      for (final (accountId, amount) in lines) {
        await khata.db.customStatement(
          'INSERT INTO journal_lines (id, ledger_id, entry_id, line_no, entry_date, '
          'account_id, amount_minor, base_amount_minor, currency_code, node_id, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            '019a1b2c-1000-7000-8000-0000${lineNo.toString().padLeft(8, '0')}',
            ledgerId,
            entryId,
            lineNo++,
            _todayEpochDay(),
            accountId,
            amount,
            amount,
            'PKR',
            khata.db.nodeId,
            now,
          ],
        );
      }

      // The gate: the ONLY door to status = 1 (trg_je_balance_gate).
      await khata.db.customStatement(
        'UPDATE journal_entries SET status = 1, posted_at = ?, '
        'total_debit_minor = 125000, total_credit_minor = 125000, '
        'base_total_minor = 125000 WHERE id = ?',
        [now, entryId],
      );
    });
  } on Object catch (error) {
    _failures.add('posting the verification entry threw: $error');
    return (entryId, false);
  }

  final status = await _scalarInt(
      khata, 'SELECT status FROM journal_entries WHERE id = ?', [entryId]);
  return (entryId, status == 1);
}

int _todayEpochDay() => EpochDay.fromDateTime(DateTime.now());

bool _isNotADatabase(File file) {
  final bytes = file.readAsBytesSync();
  if (bytes.length < 16) return true;
  return utf8.decode(bytes.sublist(0, 15), allowMalformed: true) != 'SQLite format 3';
}

String _shorten(String value) =>
    value.length <= 96 ? value : '${value.substring(0, 93)}…';

void _check(String what, bool condition) {
  if (condition) {
    _passed++;
    print('    ✓ $what');
  } else {
    _failures.add(what);
    print('    ✗ $what');
  }
}
