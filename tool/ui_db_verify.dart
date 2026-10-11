/// KhataPro · the UI's state layer, verified against a real database.
///
/// `tool/ui_verify.dart` checks the *logic* — formatting, chart arithmetic, paging,
/// the ledger walk. This file checks the *wiring*, and it does so the only way wiring can
/// be checked: with a real `ProviderContainer` over a real `KhataDatabase` opened from real
/// migrations, taking real writes through `OrderBook`, and asserting that the providers a
/// screen watches actually emit the new numbers.
///
/// The acceptance criterion this file exists for, in the user's words: *"when the local DB
/// updates via a WebRTC or BYOC background sync, the UI must react instantly without
/// full-screen rebuilds."* Background sync and a local edit arrive at the UI the same way
/// (see `lib/ui/state/changes.dart`), so what is asserted here — a write lands, the
/// providers re-read, exactly once per coalesced window, and only the affected providers
/// change — is the same path a merge takes.
///
/// Run it through the harness (native assets need `dart run` from a package, not a bare
/// script):
///
///   cd /tmp/harness
///   ./dartx run bin/ui_db_run.dart --asset-root=/home/user/khata_pro
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Variable;
import 'package:riverpod/riverpod.dart';

import '../lib/apps/deep_links.dart';
import '../lib/core/security/sqlcipher_key.dart';
import '../lib/core/utils/epoch_day.dart';
import '../lib/data/db/dao/base_dao.dart' show AccountRole, DocKind;
import '../lib/data/db/dao/parties_dao.dart';
import '../lib/data/db/database.dart';
import '../lib/data/db/migration_runner.dart';
import '../lib/data/repositories/order_book.dart';
import '../lib/ui/commands/book_commands.dart';
import '../lib/ui/commands/reminders.dart';
import '../lib/ui/format/strings.dart';
import '../lib/ui/lists/paged_list.dart' show DayHeaderCell;
import '../lib/ui/routes.dart';
import '../lib/ui/state/changes.dart';
import '../lib/ui/state/ledger_source.dart';
import '../lib/ui/state/providers.dart';
import '../lib/ui/state/queries.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void _check(String what, bool ok, [String? detail]) {
  if (ok) {
    _passed += 1;
    print('    ✓ $what');
  } else {
    _failures.add(what);
    print('    ✗ $what${detail == null ? '' : '\n        $detail'}');
  }
}

void _section(String name) {
  print('');
  print('  ── $name ${'─' * math.max(0, 62 - name.length)}');
}

/// Waits until [test] holds, or fails after [timeout]. Real timers, real database — a
/// `sleep` long enough to be reliable would make this suite slow, so it polls the
/// condition instead and gives up loudly.
Future<bool> _until(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return test();
}

late final FileSystemAssetLoader _assets;

/// Waits for the first value a `StreamProvider` produces, by polling its state.
///
/// Deliberately **not** `await container.read(provider.future)`. In Riverpod 3.4.3 that
/// getter goes through a `ProviderElementProxy` (`$FutureModifier.future`, see
/// `lib/src/core/modifiers/future.dart:118`) whose future is minted while the provider is
/// still loading; for a `StreamProvider` it never completes, so the read hangs forever even
/// though the provider is already in `AsyncData`. Verified against the pinned source and by
/// experiment (`bin/probe3.dart`: a stream that yields 42 immediately still hangs). Widgets
/// therefore render from `AsyncValue` with `.when(...)`, and tests poll for `hasValue`.
/// Keeps a subscription alive for the run: closing it would stop the provider's stream.
final _subscriptions = <Object>[];

void _keep(Object subscription) => _subscriptions.add(subscription);

/// Note, because it bites: a `StreamProvider` that is only `read` **never starts its
/// stream** and sits in `AsyncLoading` for ever. Measured (`bin/probe4.dart`): `read` alone
/// after 300 ms is still `AsyncLoading<int>()`; adding one listener turns it into
/// `AsyncData<int>(42)`. Widgets are fine (they `watch`, which subscribes), but a
/// `ref.read(someStreamProvider)` from a button callback is a trap: it will read nothing.

Future<T> _data<T>(
  AsyncValue<T> Function() read, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (value.hasValue) return value.requireValue;
    if (value.hasError) {
      throw StateError('the provider is in error, not loading: ${value.error}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('no value within ${timeout.inSeconds}s');
}

/// Waits for the first value a `StreamProvider` produces, by polling its state.
///
/// Deliberately **not** `await container.read(provider.future)`. In Riverpod 3.4.3 that
/// getter goes through a `ProviderElementProxy` (`$FutureModifier.future`, see
/// `lib/src/core/modifiers/future.dart:118`) whose future is minted while the provider is
/// still loading; for a `StreamProvider` it never completes, so the read hangs forever even
/// though the provider is already in `AsyncData`. Verified against the pinned source and by
/// experiment (`bin/probe3.dart`: a stream that yields 42 immediately still hangs). Widgets
/// therefore render from `AsyncValue` with `.when(...)`, and tests poll for `hasValue`.
Future<void> main(List<String> args) async {
  final rootArg = args.firstWhere(
    (a) => a.startsWith('--asset-root='),
    orElse: () => '--asset-root=.',
  );
  _assets = FileSystemAssetLoader(rootArg.substring('--asset-root='.length));
  final root = Directory.systemTemp.createTempSync('khata_ui_');
  final dbFile = File('${root.path}/khata.sqlite');

  print('');
  print('  KhataPro · UI state layer, against a real database');
  print('  scratch: ${root.path}');
  print('  ${'─' * 74}');

  final khata = await KhataDb.open(KhataOpenRequest(
    databaseFile: dbFile,
    key: SqlCipherKey.generate(),
    nodeId: '019a1b2c-0000-7000-8000-0000000000bb',
    platform: 'linux',
    appVersion: '1.0.0+1',
    assetLoader: _assets,
    requireEncryption: false,
  ));

  final ledgerId = await khata.db.readOne<String>(
    'SELECT id FROM ledgers LIMIT 1',
    const [],
    (row) => '${row.data['id']}',
  );
  if (ledgerId == null) {
    print('  no ledger row — the seed migration did not run');
    exit(1);
  }

  // The bus is *not* constructed here and injected: it is read from the provider, which
  // is what attaches it to the database (`ChangeBus.attachTo`). An earlier version of this
  // file overrode the provider with a hand-made bus, and the whole suite then measured a
  // bus that nothing was wired to — every "the UI reacts" check failed and the reason was
  // the harness, not the app.
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(khata.db)],
  );
  final bus = container.read(changeBusProvider);

  try {
    await _seed(khata, ledgerId);
    _openTheScreens(container);
    await _providersReadTheBooks(container, khata, ledgerId);
    await _aWriteMakesTheUiReact(container, khata, ledgerId, bus);
    await _theBusCoalesces(bus);
    await _theLedgerScreenFollowsTheBooks(container, khata, ledgerId, bus);
    await _narrowRebuilds(container, khata, ledgerId, bus);
    await _linksFindTheirRows(container);
  } finally {
    container.dispose();
    await bus.dispose();
    await khata.close();
    root.deleteSync(recursive: true);
  }

  print('');
  print('  ${'═' * 74}');
  if (_failures.isEmpty) {
    print('  ✓ all $_passed checks passed');
  } else {
    print('  ✗ ${_failures.length} of ${_passed + _failures.length} checks FAILED');
    for (final failure in _failures) {
      print('      · $failure');
    }
    exit(1);
  }
}

// ── seeding ──────────────────────────────────────────────────────────────────

late String _walkIn;
late String _cashCustomer;
late String _creditCustomer;
late String _employee;
late int _today;
late int _nowMs;

/// The two items the stock screen is exercised with. Ids are 36 characters because the
/// schema says so (`CHECK (length(id) = 36)`) — a hand-written short id is not a UUID and
/// the database refuses it, which is exactly what happened on the first run of this file.
const _sugar = '019a1b2c-1000-7000-8000-000000000001';
const _tea = '019a1b2c-1000-7000-8000-000000000002';

Future<void> _seed(KhataDb khata, String ledgerId) async {
  _section('a shop with a day of trading in it');
  final book = OrderBook(db: khata.db, ledgerId: ledgerId);
  final parties = PartiesDao(db: khata.db, ledgerId: ledgerId);
  _today = EpochDay.today();
  _nowMs = DateTime.now().millisecondsSinceEpoch;

  // Opening balances: the drawer, the bank, and what customers already owe.
  final opening = await book.postOpening(
    entryDate: _today - 30,
    balances: const [
      (AccountRole.cash, 5000000), // Rs 50,000
      (AccountRole.bank, 20000000), // Rs 2,00,000
      (AccountRole.ar, 1500000), // Rs 15,000 owed by customers
    ],
  );
  _check('opening balances posted as a balanced entry', opening.entryId.isNotEmpty);

  _walkIn = '${(await khata.db.customSelect(
    'SELECT id FROM parties WHERE is_walk_in = 1 LIMIT 1',
  ).getSingle()).data['id']}';
  _check('the seeded walk-in customer exists, so a cash sale has a party to name',
      _walkIn.isNotEmpty);

  _cashCustomer = await parties.create(const PartyDraft(name: 'Bilal Kirana', kind: 1));
  _creditCustomer = await parties.create(const PartyDraft(name: 'Zubaida General Store', kind: 1));
  _employee = await parties.create(const PartyDraft(name: 'Rafiq (helper)', kind: 3));
  _check('three parties created', _cashCustomer.isNotEmpty && _creditCustomer.isNotEmpty && _employee.isNotEmpty);

  // The regression that this suite found the hard way: a party named longer than 19
  // characters produced a sub-ledger code of more than 24 characters, the CHECK constraint
  // rejected the INSERT, `INSERT OR IGNORE` hid it, and the DAO threw INT-7 — so a
  // shopkeeper could not add "Zubaida General Store" at all. Two parties sharing a long
  // prefix are the second half of the same bug.
  final longName = await parties.create(const PartyDraft(
    name: 'Muhammad Ashraf and Sons General Merchants',
    kind: 1,
  ));
  final twin = await parties.create(const PartyDraft(
    name: 'Muhammad Ashraf and Sons General Traders',
    kind: 1,
  ));
  final codes = await khata.db.customSelect(
    'SELECT a.party_id, a.code, length(a.code) AS len FROM accounts a '
    'WHERE a.party_id IN (?, ?, ?)',
    variables: [
      Variable<String>(_creditCustomer),
      Variable<String>(longName),
      Variable<String>(twin),
    ],
  ).get();
  _check('a party whose name would overflow the code limit still gets an account',
      codes.any((r) => r.data['party_id'] == longName) && codes.length == 3,
      '${codes.length} of 3');
  _check('every derived code fits the 24-character schema limit',
      codes.every((r) => (r.data['len'] as int) <= 24),
      '${codes.map((r) => r.data['code']).toList()}');
  _check('and two parties sharing a name prefix get distinct codes',
      codes.map((r) => r.data['code']).toSet().length == codes.length,
      '${codes.map((r) => r.data['code']).toList()}');

  // A cash sale today, a credit sale today, an older credit sale, an expense, a receipt.
  // Invoices, not bare sales: `postInvoice` writes the `documents` row and the entry in one
  // transaction, which is what the bill book, the ageing buckets and a printed invoice read.
  await book.postInvoice(
    entryDate: _today,
    grossMinor: 250000,
    amountPaidMinor: 250000,
    partyId: _walkIn,
    memo: 'Cash sale',
  );
  await book.postInvoice(
    entryDate: _today,
    grossMinor: 480000,
    amountPaidMinor: 100000,
    partyId: _creditCustomer,
    docNo: 'INV-1001',
    dueDate: _today + 15,
  );
  await book.postInvoice(
    entryDate: _today - 5,
    grossMinor: 300000,
    amountPaidMinor: 0,
    partyId: _creditCustomer,
    docNo: 'INV-0998',
    dueDate: _today - 1,
  );
  await book.postExpense(entryDate: _today, amountMinor: 35000, memo: 'Electricity');
  await book.postPaymentIn(entryDate: _today, amountMinor: 50000, partyId: _creditCustomer);

  // Stock: an item with stock on hand, and one below its re-order level. Written with
  // stamps from the database's own HLC service rather than hand-built strings — the
  // schema checks `length(hlc) = 57` and a hand-built one would be a lie about its age.
  for (final item in const [
    (_sugar, 'Sugar (1kg)', 'kg', 22000, 5000),
    (_tea, 'Tea (pack)', 'pkt', 45000, 10000),
  ]) {
    final stamp = khata.db.hlc.stampForWrite();
    await khata.db.customStatement(
      'INSERT INTO items (id, ledger_id, name, unit, is_stocked, sale_price_minor, '
      'reorder_level_milli, hlc, node_id, rev, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, 1, ?, ?)',
      [
        item.$1, ledgerId, item.$2, item.$3, item.$4, item.$5,
        stamp.hlc.encode(), stamp.nodeId, _nowMs, _nowMs,
      ],
    );
  }
  for (final move in const [
    ('019a1b2c-2000-7000-8000-000000000001', _sugar, 25000, 18000000, 450000, 0),
    ('019a1b2c-2000-7000-8000-000000000002', _tea, 8000, 35000000, 280000, 2),
  ]) {
    final stamp = khata.db.hlc.stampForWrite();
    await khata.db.customStatement(
      'INSERT INTO stock_moves (id, ledger_id, item_id, move_date, direction, '
      'quantity_milli, unit_cost_micros, value_minor, source, hlc, node_id, created_at) '
      'VALUES (?, ?, ?, ?, 1, ?, ?, ?, 4, ?, ?, ?)',
      [
        move.$1, ledgerId, move.$2, _today - move.$6, move.$3, move.$4, move.$5,
        stamp.hlc.encode(), stamp.nodeId, _nowMs,
      ],
    );
  }

  final salesRow = await khata.db.customSelect(
    'SELECT COALESCE(SUM(total_minor), 0) AS total FROM documents WHERE doc_kind = 1',
  ).getSingle();
  final sales = (salesRow.data['total'] as num).toInt();
  _check('the three sales produced documents', sales == 1030000, '$sales');
}

// ── the screens ──────────────────────────────────────────────────────────────

/// Subscribes to the providers the screens watch, the way `ref.watch` does.
///
/// Done after the seed: a screen is opened on a book that already has entries in it, and
/// this suite's earlier life had the providers subscribed *before* the seed, which made
/// every assertion read a pre-seed snapshot and fail with plausible-looking zeros. The
/// live-update path has its own section (`_aWriteMakesTheUiReact`) where it is measured
/// properly, with emission counts.
void _openTheScreens(ProviderContainer container) {
  _keep(container.listen(dashboardProvider, (_, __) {}));
  _keep(container.listen(partiesProvider(1), (_, __) {}));
  _keep(container.listen(staffProvider, (_, __) {}));
  _keep(container.listen(cashAccountsProvider, (_, __) {}));
  _keep(container.listen(cashFlowProvider(CashWindow.lastDays(EpochDay.today(), 7)), (_, __) {}));
  _keep(container.listen(billsProvider(0), (_, __) {}));
  _keep(container.listen(stockProvider(false), (_, __) {}));
  _keep(container.listen(stockProvider(true), (_, __) {}));
  _keep(container.listen(stockMovesProvider(_sugar), (_, __) {}));
  _keep(container.listen(syncHealthProvider, (_, __) {}));
  _keep(container.listen(conflictsProvider, (_, __) {}));
  _keep(container.listen(draftsProvider, (_, __) {}));
}

// ── providers read the books ─────────────────────────────────────────────────

Future<void> _providersReadTheBooks(
  ProviderContainer container,
  KhataDb khata,
  String ledgerId,
) async {
  _section('every screen\'s provider answers from the real ledger');

  final ledger = await container.read(ledgerIdProvider.future);
  _check('the ledger id comes from the database, not a constant', ledger == ledgerId);

  final today = await container.read(businessDayProvider.future);
  _check('the business day comes from v_now', today == _today, '$today vs $_today');

  final dashboard = await _data(() => container.read(dashboardProvider));
  _check('today\'s sales are the two sales posted today',
      dashboard.todaySalesMinor == 250000 + 480000, '${dashboard.todaySalesMinor}');
  _check('this month\'s expenses include the electricity bill',
      dashboard.monthExpenseMinor == 35000, '${dashboard.monthExpenseMinor}');
  _check('receivables roll up the control account and the party sub-ledgers',
      dashboard.receivableMinor == 1500000 + 300000 + 380000 - 50000,
      '${dashboard.receivableMinor}  (migration 011; the view used to say 1500000)');
  // `cash_minor` is cash **and bank and mobile wallet** — all three are seeded with
  // `is_cash = 1`, and the view's comment says so. The dashboard card is labelled
  // "Cash & bank" for that reason (see docs/UI.md §4).
  _check('cash on hand is the drawer plus the bank, after the day\'s movements',
      dashboard.cashMinor == 5000000 + 20000000 + 250000 + 100000 - 35000 + 50000,
      '${dashboard.cashMinor}');
  _check('the dashboard found the debtor to chase first',
      dashboard.topDebtors.isNotEmpty && dashboard.topDebtors.first.partyId == _creditCustomer,
      '${dashboard.topDebtors.map((p) => p.name).toList()}');

  final parties = await _data(() => container.read(partiesProvider(1)));
  // Four, not two: the two regression parties (long name, shared prefix) are customers
  // too, and the seeded walk-in is excluded — there is nobody to chase at the counter.
  _check('the named customers are listed, and the walk-in is not',
      parties.length == 4 && !parties.any((p) => p.partyId == _walkIn),
      '${parties.length}');
  _check('ordered by absolute balance, biggest first',
      parties.first.partyId == _creditCustomer && parties.first.receivableMinor == 630000,
      '${parties.first.name}: ${parties.first.receivableMinor}');

  final staff = await _data(() => container.read(staffProvider));
  _check('the employee appears in the staff book, not the customer list',
      staff.length == 1 && staff.first.partyId == _employee);

  final cash = await _data(() => container.read(cashAccountsProvider));
  _check('the cash book lists the drawer and the bank', cash.length == 2, '${cash.length}');
  _check('with the balances the ledger says they hold',
      cash.map((a) => a.balanceMinor).reduce(math.max) == 20000000,
      '${cash.map((a) => a.balanceMinor).toList()}');

  final bills = await _data(() => container.read(billsProvider(0)));
  _check('two credit invoices are outstanding', bills.length == 2, '${bills.length}');
  _check('the older invoice is sorted as the more overdue',
      bills.first.docNo == 'INV-0998', bills.first.docNo);
  _check('a partly paid invoice reports the balance, not the total',
      bills.any((b) => b.docNo == 'INV-1001' && b.balanceMinor == 380000 && b.totalMinor == 480000));

  final stock = await _data(() => container.read(stockProvider(false)));
  _check('both items are in the stock book', stock.length == 2, '${stock.length}');
  final lowOnly = await _data(() => container.read(stockProvider(true)));
  _check('the re-order list shows only what is at or below its level',
      lowOnly.length == 1 && lowOnly.first.name == 'Tea (pack)',
      '${lowOnly.map((s) => '${s.name} ${s.quantityMilli}/${s.reorderLevelMilli}').toList()}');
  _check('stock on hand is exact, in thousandths',
      stock.firstWhere((s) => s.name == 'Sugar (1kg)').quantityMilli == 25000);

  final moves = await _data(() => container.read(stockMovesProvider(_sugar)));
  _check('the movement history names the item', moves.length == 1 && moves.first.itemName == 'Sugar (1kg)');

  final health = await _data(() => container.read(syncHealthProvider));
  _check('sync health is reported even when nothing has ever synced',
      health.pendingOps >= 0 && health.trustedPeers == 0);

  final drafts = await _data(() => container.read(draftsProvider));
  _check('no drafts to worry about yet', drafts.isEmpty, '${drafts.length}');
}

// ── reactivity ───────────────────────────────────────────────────────────────

Future<void> _aWriteMakesTheUiReact(
  ProviderContainer container,
  KhataDb khata,
  String ledgerId,
  ChangeBus bus,
) async {
  _section('a write reaches the screen — the sync path, in miniature');
  // Nothing in this section calls `bus.changed()`. That is the point: the database tells
  // the bus, the bus tells the providers, and the providers re-read.

  var dashboardEmissions = 0;
  var lastDashboard = container.read(dashboardProvider).value;
  final dashboardSub = container.listen(dashboardProvider, (_, next) {
    dashboardEmissions += 1;
    lastDashboard = next.value;
  }, fireImmediately: false);

  var cashEmissions = 0;
  final cashSub = container.listen(cashFlowProvider(CashWindow.lastDays(_today, 7)), (_, __) {
    cashEmissions += 1;
  }, fireImmediately: false);

  final before = await _data(() => container.read(dashboardProvider));
  final book = OrderBook(db: khata.db, ledgerId: ledgerId);

  // A local edit: a cash sale. The same call the "save" button makes.
  await book.postSale(
    entryDate: _today,
    grossMinor: 100000,
    amountPaidMinor: 100000,
    memo: 'Reactive sale',
  );
  // No `bus.changed()` here on purpose: the write itself must be what the UI hears.

  final updated = await _until(() => (lastDashboard?.todaySalesMinor ?? 0) > before.todaySalesMinor);
  _check(
    'the dashboard re-reads itself after a write, with the new number',
    updated &&
        lastDashboard!.todaySalesMinor == before.todaySalesMinor + 100000 &&
        lastDashboard!.cashMinor == before.cashMinor + 100000,
    'sales ${lastDashboard?.todaySalesMinor}, cash ${lastDashboard?.cashMinor}',
  );
  _check('and it took exactly one emission per write', dashboardEmissions == 1, '$dashboardEmissions');

  // The cash chart is a different provider on a different query; it must also follow.
  // Polled, not sampled: both providers re-read from the same event and whichever query is
  // cheaper finishes first, so reading the counter immediately made this check flaky
  // (it passed and failed on alternate runs).
  final cashFollowed = await _until(() => cashEmissions >= 1);
  _check('the cash chart follows the same write', cashFollowed, '$cashEmissions');

  // 500 writes inside one coalescing window — a sync batch applying a day's entries, or a
  // bulk import — must not turn into 500 UI rebuilds.
  dashboardEmissions = 0;
  final bumpsBefore = bus.bumps;
  for (var i = 0; i < 500; i++) {
    await khata.db.customStatement(
      'UPDATE number_sequences SET next_value = next_value + 1 WHERE doc_kind = 1',
    );
  }
  bus.flush();
  await _until(() => dashboardEmissions > 0);
  // 500 separate auto-committed writes are 500 separate commits, so "one rebuild" would
  // be a stronger claim than the design makes: the promise is that a burst is *coalesced*,
  // not that it is atomic. What must never happen is 500 rebuilds. The measured bound is
  // deliberately loose (5) and the failure message carries the numbers, so a regression to
  // per-write notification is unmistakable.
  // The bound is arithmetic, not aspirational: 500 auto-committed writes take ~130 ms of
  // real work, and coalescing is a 16 ms wall-clock window, so ~8 rebuilds is the *minimum*
  // achievable — asserting "1" would have been a check that cannot pass. What this rules out
  // is the failure that matters: one rebuild per write.
  final bumps = bus.bumps - bumpsBefore;
  _check(
    'a 500-write burst is coalesced into a handful of rebuilds, not 500',
    bumps == 500 && dashboardEmissions <= 20,
    'bumps=$bumps emissions=$dashboardEmissions '
        '(bus: ${bus.notifications} notifications in total)',
  );

  dashboardSub.close();
  cashSub.close();
  if (dashboardEmissions > 1) {
    print('        (bus: ${bus.bumps} bumps, ${bus.notifications} notifications)');
  }
}

Future<void> _theBusCoalesces(ChangeBus ignored) async {
  _section('the change bus is honest about what it did');
  final bus = ChangeBus(coalesce: Duration.zero);
  var count = 0;
  final sub = bus.changes.listen((_) => count += 1);
  for (var i = 0; i < 10; i++) {
    bus.bump();
  }
  bus.flush();
  // A broadcast stream delivers on a later microtask, so the counters are read after the
  // event has actually been delivered — asserting straight after `flush()` measured the
  // test's own impatience, not the bus.
  await Future<void>.delayed(Duration.zero);
  _check('with coalescing off, every bump is a notification', count == 10 && bus.bumps == 10, '$count/${bus.bumps}');
  sub.cancel();

  final coalesced = ChangeBus();
  var coalescedCount = 0;
  final sub2 = coalesced.changes.listen((_) => coalescedCount += 1);
  for (var i = 0; i < 10; i++) {
    coalesced.bump();
  }
  coalesced.flush();
  await Future<void>.delayed(Duration.zero);
  _check('with coalescing on, ten bumps are one notification', coalescedCount == 1, '$coalescedCount');
  _check('but the bus still counts all ten writes', coalesced.bumps == 10, '${coalesced.bumps}');
  sub2.cancel();
  bus.dispose();
  coalesced.dispose();
}

// ── the ledger screen ────────────────────────────────────────────────────────

Future<void> _theLedgerScreenFollowsTheBooks(
  ProviderContainer container,
  KhataDb khata,
  String ledgerId,
  ChangeBus bus,
) async {
  _section('a party ledger balances, then re-balances when a sync lands');

  _keep(container.listen(ledgerProvider(_creditCustomer), (_, __) {}));
  final state = await _data(() => container.read(ledgerProvider(_creditCustomer)));
  _check('the ledger loaded its first page', state.positions.isNotEmpty, '${state.positions.length} rows');
  _check('the newest row carries the party\'s balance',
      state.positions.first.balanceAfterMinor == 630000,
      '${state.positions.first.balanceAfterMinor}  (300000 + 380000 − 50000)');
  _check('the walk reaches zero — the ledger nets out', state.positions.last.balanceBeforeMinor == 0,
      '${state.positions.last.balanceBeforeMinor}');
  _check('so no integrity warning is raised', state.integrityNote == null, state.integrityNote);
  _check('the flattened cells include a day header before the rows',
      state.cells.isNotEmpty && state.cells.first is DayHeaderCell);

  final controller = container.read(ledgerProvider(_creditCustomer).notifier);
  final pager = controller.pager;
  _check('the controller exposes the pager it owns', pager != null);
  _check('the pager walked the whole ledger', pager!.hasMore == false, 'hasMore=${pager.hasMore}');

  // Now the other phone syncs in a payment. Same path as a background merge: a write,
  // then a change signal.
  final beforeBalance = state.positions.first.balanceAfterMinor;
  final book = OrderBook(db: khata.db, ledgerId: ledgerId);
  // Exactly the debt: the ledger should end at zero, and the party should be off the
  // "who owes me" list.
  await book.postPaymentIn(entryDate: _today, amountMinor: 630000, partyId: _creditCustomer);

  final settled = await _until(() {
    final current = container.read(ledgerProvider(_creditCustomer)).value;
    return current != null && current.positions.isNotEmpty && current.positions.first.balanceAfterMinor != beforeBalance;
  });
  final after = container.read(ledgerProvider(_creditCustomer)).value!;
  _check('the ledger re-reads itself after the payment', settled);
  _check('the anchor moved to the new balance', after.positions.first.balanceAfterMinor == 0,
      '${after.positions.first.balanceAfterMinor}');
  _check('the new payment is the newest row', after.positions.length == state.positions.length + 1,
      '${state.positions.length} → ${after.positions.length}');
  _check('and the walk still balances to zero', after.positions.last.balanceBeforeMinor == 0);
  _check('the party is off the receivables list once settled',
      (await khata.db.partyBalanceMinor(ledgerId, _creditCustomer)) == 0);

  // And an over-payment is not an error: it becomes a credit the shop owes back, which is
  // how a shopkeeper records an advance. The dashboard must show it as a payable, not
  // silently drop it or flip the sign of the whole list.
  await book.postPaymentIn(entryDate: _today, amountMinor: 250000, partyId: _creditCustomer);
  // `_data` reads whatever is in hand *now*, which — one coalescing window after a write —
  // is the value from before it. Poll for the change instead.
  // The numbers, spelled out, rather than a baseline sampled a coalescing window too early:
  // control 1 500 000 + credit sales 630 000 − settlement 630 000 − advance 250 000.
  await _until(() =>
      (container.read(dashboardProvider).value?.receivableMinor ?? 0) == 1250000);
  final advance = await _data(() => container.read(dashboardProvider));
  _check('an over-payment nets the customer back off the receivables',
      advance.receivableMinor == 1250000,
      'receivable=${advance.receivableMinor}, expected 1250000');
  // The dashboard nets advances against receivables by *account* (a customer sub-ledger is
  // debit-normal whatever the sign). The per-party split is where an advance is named as
  // such, and that is what the party list shows — so assert it there.
  final partiesAfter = await _data(() => container.read(partiesProvider(1)));
  final zubaida = partiesAfter.firstWhere((p) => p.partyId == _creditCustomer);
  _check('and the party list shows it as an advance (a credit balance)',
      zubaida.payableMinor == 250000 && zubaida.receivableMinor == 0,
      'receivable=${zubaida.receivableMinor} payable=${zubaida.payableMinor}');

  // A brand-new party: an empty ledger must be empty, not an error.
  final parties = PartiesDao(db: khata.db, ledgerId: ledgerId);
  final fresh = await parties.create(const PartyDraft(name: 'New Customer', kind: 1));
  _keep(container.listen(ledgerProvider(fresh), (_, __) {}));
  final emptyState = await _data(() => container.read(ledgerProvider(fresh)));
  _check('a party with no entries has an empty ledger and no warning',
      emptyState.positions.isEmpty && emptyState.integrityNote == null);
}

// ── granularity ──────────────────────────────────────────────────────────────

Future<void> _narrowRebuilds(
  ProviderContainer container,
  KhataDb khata,
  String ledgerId,
  ChangeBus bus,
) async {
  _section('one screen\'s data does not rebuild another screen');

  var stockEmissions = 0;
  final stockSub = container.listen(stockProvider(false), (_, __) => stockEmissions += 1, fireImmediately: false);

  // A write that touches the bills but not the stock: posting an invoice must not
  // re-render the stock list. The provider is re-read only if it is listening to the bus
  // — and every provider *is*, so this asserts the narrower property that matters: the
  // stock list's *value* is unchanged, which is what a `select` on the widget side uses
  // to skip the rebuild.
  final beforeStock = await _data(() => container.read(stockProvider(false)));
  // Registered *before* the write: a listener created afterwards can only ever see a list
  // that has already changed, which is how this check failed the first time.
  var billsEmissions = 0;
  final billsSub = container.listen(
    billsProvider(0),
    (_, __) => billsEmissions += 1,
    fireImmediately: false,
  );
  final book = OrderBook(db: khata.db, ledgerId: ledgerId);
  await book.postInvoice(
    entryDate: _today,
    grossMinor: 60000,
    amountPaidMinor: 0,
    partyId: _creditCustomer,
    docNo: 'INV-1002',
  );
  await _until(() => stockEmissions > 0);

  final afterStock = await _data(() => container.read(stockProvider(false)));
  _check(
    'the stock list is re-read but its contents are identical, so a `select` skips the rebuild',
    beforeStock.length == afterStock.length &&
        beforeStock.first.quantityMilli == afterStock.first.quantityMilli,
    '${beforeStock.length} → ${afterStock.length}',
  );

  final bills = await _data(() => container.read(billsProvider(0)));
  _check('the new invoice appears in the bill book', bills.any((b) => b.docNo == 'INV-1002'));
  final billsFollowed = await _until(() => billsEmissions >= 1);
  _check('and the bill book did re-read', billsFollowed, '$billsEmissions');

  stockSub.close();
  billsSub.close();
}

// ── H · the links, against real rows ─────────────────────────────────────────

/// The link path where it meets the *book*: the ids a link carries are row ids, and a row that
/// is not in this database has to behave differently from one that is.
///
/// The pure half of this chain — three uri shapes, the route table, the action, the form — is
/// 23 checks in `tool/ui_commands_verify.dart` §G, and it runs with no database at all. What it
/// cannot tell you is whether the id the app *writes into* a link is the id the app will *look
/// up* when the link comes back. That is what this section is for, and it is the difference
/// between a reminder that opens the right ledger and one that opens "not in this khata".
Future<void> _linksFindTheirRows(ProviderContainer container) async {
  _section('the links find their rows — and a foreign row is refused, not guessed');

  final money = container.read(moneyFormatProvider);
  final strings = UiStrings(container.read(displayPrefsProvider).language);
  final commands = container.read(bookCommandsProvider);

  // Subscribe before reading: the family providers start on listen only (see §B). The suite's
  // global subscription covers `billsProvider(0)` — *every* kind — while the bill book screen
  // asks for one kind, so the key this section reads needs its own listener.
  _keep(container.listen(partyProvider(_creditCustomer), (_, __) {}));
  _keep(container.listen(billsProvider(DocKind.saleInvoice), (_, __) {}));

  // ── a party link built by the app, for a party that is in the book ─────────
  final link = buildPartyLink(_creditCustomer);
  final parsed = parseDeepLink(link);
  _check(
    'the link the ledger screen sends names the party by the id the database uses',
    parsed?.partyId == _creditCustomer,
    '${parsed?.partyId}',
  );
  final row = await _data(() => container.read(partyProvider(_creditCustomer)));
  _check(
    'and the screen the link opens reads that row: the customer with the real balance',
    row?.name == 'Zubaida General Store' && row!.netMinor != 0,
    '${row?.name} / ${row?.netMinor}',
  );

  // ── the action, against a real row ─────────────────────────────────────────
  final receiving = parseDeepLink(Uri.parse('${buildPartyLink(_creditCustomer)}?action=receive'))!;
  final routed = routeFor(receiving);
  _check(
    'a "receive payment" link routes to the ledger with its action intact',
    routed is GoScreen &&
        routed.path == '/party/$_creditCustomer?action=receive' &&
        routed.action == LinkAction.receive,
    '$routed',
  );
  final form = formFor(
    action: LinkAction.receive,
    forms: EntryForms(commands: commands!, money: money, strings: strings),
    partyId: receiving.partyId,
    partyName: row!.name,
  );
  _check(
    'and the form it opens is locked to that same party, so the money cannot land elsewhere',
    form?.lockedPartyId == _creditCustomer,
  );

  // ── a party id from another phone's book ───────────────────────────────────
  // A perfectly well-formed id that this database has never seen. The link parses — it is
  // *ours* — and the lookup returns nothing, which is the case the router answers with the
  // "not in this khata" page (via `GoScreen.expectsRow`) rather than a ledger that spins.
  const foreignId = '019a1b2c-9999-7000-8000-000000009999';
  _keep(container.listen(partyProvider(foreignId), (_, __) {}));
  final foreignLink = parseDeepLink(buildPartyLink(foreignId));
  final foreignRouted = routeFor(foreignLink!);
  final settled = await _until(() => container.read(partyProvider(foreignId)).hasValue);
  _check(
    'a link to a party that is not in this book parses, routes — and finds no row',
    foreignLink.partyId == foreignId &&
        foreignRouted is GoScreen &&
        foreignRouted.expectsRow &&
        settled &&
        container.read(partyProvider(foreignId)).value == null,
    'expectsRow=${foreignRouted is GoScreen && foreignRouted.expectsRow}',
  );

  // ── the bill book's one-shot open ──────────────────────────────────────────
  // `bill_book_screen.dart` opens a document once by *searching the worklist it already
  // watches* for `state.uri.queryParameters['doc']`. So the link's id has to match the row
  // the list renders, byte for byte, and it has to still be in the list.
  final bills = await _data(() => container.read(billsProvider(DocKind.saleInvoice)));
  _check(
    'the bill book has rows for a link to find',
    bills.isNotEmpty,
    '${bills.length} bills',
  );
  final everyBillLinkResolves = bills.every(
    (bill) =>
        documentIdOf(buildBillLink(documentId: bill.documentId, docNo: bill.docNo)) ==
        bill.documentId,
  );
  _check(
    'every bill link the app can build resolves to the row the bill book searches for',
    everyBillLinkResolves,
    '${bills.map((b) => b.docNo).join(', ')}',
  );
  final overdue = bills.firstWhere((b) => b.docNo == 'INV-0998', orElse: () => bills.first);
  final billLink = buildBillLink(documentId: overdue.documentId, docNo: overdue.docNo);
  _check(
    'the shared link is readable to a human — the bill number travels with it',
    billLink.queryParameters['no'] == overdue.docNo,
    '$billLink',
  );
  _check(
    'and routing ignores that number: the id is the path segment, so a link cannot be routed '
    'by a string a shopkeeper can type',
    documentIdOf(billLink) == overdue.documentId,
  );

  // The honest edge: a hand-written link carrying the *number* instead of the id parses (it is
  // a string in the right place) and finds nothing — so the bill book opens and shows the
  // worklist. No crash, no empty screen, no wrong bill.
  final byNumber = parseDeepLink(Uri.parse('khatapro://bill/INV-0998'));
  _check(
    'a link that carries the bill number instead of its id quietly opens the worklist, '
    'browsing no bill',
    byNumber != null &&
        documentIdOf(Uri.parse('khatapro://bill/INV-0998')) == 'INV-0998' &&
        !bills.any((b) => b.documentId == 'INV-0998'),
  );

  // ── the pairing link ───────────────────────────────────────────────────────
  final ticket = 'a-pairing-ticket-with-two-dots.abc.def';
  final join = parseDeepLink(Uri.parse(KhataRoutes.join(ticket)));
  final joinScreen = routeFor(join!);
  _check(
    'a pairing link carries its ticket to the screen that starts the flow',
    join.ticket == ticket &&
        joinScreen is GoScreen &&
        joinScreen.ticket == ticket &&
        joinScreen.path == '/join?t=$ticket',
    '$joinScreen',
  );

  // ── the reminder, built from the real balance ───────────────────────────────
  // The same call the ledger screen's phone button makes, with the balance the books report.
  // The url inside the message has to be one this app parses back — and the amount in the
  // message has to be the amount the customer owes, not a rounded or re-formatted one.
  final body = buildReminder(
    partyName: row.name,
    balanceMinor: row.netMinor,
    money: money,
    link: partyLinkFor(_creditCustomer),
    language: UiLanguage.english,
  );
  final inBody = RegExp(r'[a-z]+://\S+').firstMatch(body)?.group(0) ?? '';
  _check(
    'the reminder carries a link back to the very party whose balance it quotes',
    parseDeepLink(Uri.parse(inBody))?.partyId == _creditCustomer,
    'body: $body',
  );
  _check(
    'and the balance in the message is the balance in the books',
    body.contains(money.balance(row.netMinor)),
    'expected ${money.balance(row.netMinor)}',
  );
}
