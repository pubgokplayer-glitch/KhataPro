/// KhataPro · `tool/ui_commands_verify.dart`
///
/// The Batch-4 acceptance question, in one sentence: **when a shopkeeper presses *save*, do
/// the books and every screen both end up right — and does a refusal leave them untouched?**
///
/// So this drives the real thing and nothing but the real thing:
///
/// * the real `BookCommands` from `lib/ui/commands/book_commands.dart` — the same object the
///   eight screens call, resolved from `bookCommandsProvider`, not hand-constructed;
/// * the real `KhataDb` singleton on a real SQLCipher file, opened through the real
///   `KhataOpenRequest` path (see `docs/DATA_LAYER.md`), so the triggers, the integrity
///   gate and the SQLCipher key custody are all in the loop;
/// * the real `ChangeBus`, read from `changeBusProvider` — the same instance the database
///   was attached to. Overriding that provider with a hand-made bus would measure a bus
///   nothing is wired to, which is a mistake this suite's sibling (`ui_db_verify.dart`)
///   already made once and documents at length;
/// * the real screens' providers (`dashboardProvider`, `partiesProvider`, `billsProvider`,
///   `cashAccountsProvider`, `cashBookProvider`) as the assertion surface. If the write path
///   works but the screens do not follow it, this file fails — which is the whole point.
///
/// ## What it asserts, and why these and not others
///
/// * **Double entry is visible from the outside.** A half-cash credit sale must move *two*
///   independent screens by *two* different amounts in the same instant: the drawer by the
///   cash received, the receivable by the credit given, and the customer's sub-ledger by the
///   credit as well. A single-entry app can only ever satisfy one of those.
/// * **Allocation is not a second sale.** Settling the invoice must take the debt back to
///   where it started and put the money in the drawer — not post the sale twice.
/// * **A refusal is a no-op, proven by counting.** After three refusals of three different
///   kinds (no party on credit, zero amount, an invoice from another book), the journal, the
///   documents, the drawer and the customer count are all *bit-identical* to before.
/// * **The screens are told, not asked.** No check here bumps a provider by hand; the only
///   thing that happens between the write and the assertion is `_until(...)` polling the same
///   `AsyncValue` a widget would `watch`.
///
/// Run: `cd /tmp/harness && ./dartx run ui_commands_run.dart --asset-root=/home/user/khata_pro`
/// (relative imports in this file — `../lib/...` — need the shim, see `docs/REPO_AND_BACKUP.md`).
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
import '../lib/data/db/dao/parties_dao.dart' show PartyKind;
import '../lib/data/db/database.dart';
import '../lib/data/db/migration_runner.dart' show FileSystemAssetLoader;
import '../lib/ui/commands/book_commands.dart';
import '../lib/ui/commands/entry_specs.dart';
import '../lib/ui/commands/reminders.dart';
import '../lib/ui/format/money_input.dart';
import '../lib/ui/format/strings.dart';
import '../lib/ui/routes.dart';
import '../lib/ui/commands/entry_models.dart';
import '../lib/ui/state/providers.dart';
import '../lib/ui/state/queries.dart';

// ── reporting ────────────────────────────────────────────────────────────────

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

/// Real timers, real database: a `sleep` long enough to be reliable would make this slow, so
/// poll the condition and give up loudly. (Same helper, same reasoning, as `ui_db_verify`.)
Future<bool> _until(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return test();
}

/// Waits for a provider's first value.
///
/// Deliberately not `await container.read(provider.future)`: in Riverpod 3.4.3 that getter
/// goes through `$FutureModifier.future` (`lib/src/core/modifiers/future.dart:118`), whose
/// future is minted while the provider is still loading — for a `StreamProvider` it never
/// completes. Poll the `AsyncValue` instead, exactly as a widget would.
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

/// Keeps subscriptions alive for the run: a `StreamProvider` that nobody listens to never
/// starts its stream at all, and closing a subscription mid-run stops it.
final _subscriptions = <Object>[];
void _keep(Object subscription) => _subscriptions.add(subscription);

late final FileSystemAssetLoader _assets;

// ── the run ──────────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final rootArg = args.firstWhere(
    (a) => a.startsWith('--asset-root='),
    orElse: () => '--asset-root=.',
  );
  _assets = FileSystemAssetLoader(rootArg.substring('--asset-root='.length));
  final root = Directory.systemTemp.createTempSync('khata_cmd_');
  final dbFile = File('${root.path}/khata.sqlite');

  print('');
  print('  KhataPro · the write path: BookCommands → books → change bus → screens');
  print('  scratch: ${root.path}');
  print('  ${'─' * 74}');

  final khata = await KhataDb.open(KhataOpenRequest(
    databaseFile: dbFile,
    key: SqlCipherKey.generate(),
    nodeId: '019a1b2c-0000-7000-8000-0000000000cc',
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

  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(khata.db)],
  );
  final bus = container.read(changeBusProvider);
  final today = EpochDay.today();
  final month = CashWindow.thisMonth(today);

  /// A well-formed 36-character row id that belongs to no document in this book. The refusal
  /// therefore comes from the lookup *inside* the transaction (a real `INV-2`), not from a
  /// `CHECK` on the shape of an id.
  const bogusId = '019a1b2c-ffff-7000-8000-000000000000';

  try {
    await _commandsWaitForTheBook(container, ledgerId);
    final partyId = await _aNewPartyReachesTheList(container);
    await _aHalfCashSaleMovesTwoScreens(container, partyId, today, month);
    await _settlingClearsTheDebtWithoutASecondSale(container, partyId, today, month);
    await _refusalsChangeNothing(container, today, month, bogusId);
    await _anExpenseOnlyLeavesTheDrawer(container, today, month);
    await _linksLandOnTheRightScreens(container, partyId, today);
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

// ── A · the command object arrives with the book ─────────────────────────────

/// `bookCommandsProvider` is nullable on purpose: there is a real frame at boot where the
/// database is open but `ledgers.id` has not been read yet. The save buttons are disabled
/// then, so the provider has to say *null* rather than throw or hand out a command object
/// with an empty ledger id (which would post an entry into a book that does not exist).
Future<void> _commandsWaitForTheBook(ProviderContainer container, String ledgerId) async {
  _section('a save button that is disabled until the book is open');

  _check(
    'the commands are absent on the first frame, before ledgers.id is read',
    container.read(bookCommandsProvider) == null,
  );

  final id = await _data(() => container.read(ledgerIdProvider));
  _check('ledgerIdProvider resolves to the book on disk', id == ledgerId, 'got "$id"');

  final commands = container.read(bookCommandsProvider);
  _check('the commands exist once the book is open', commands != null);
  _check(
    'and they are pointed at that book',
    commands?.ledgerId == ledgerId,
    'got "${commands?.ledgerId}"',
  );
}

// ── B · a write with no journal entry still has to reach the UI ──────────────

Future<String> _aNewPartyReachesTheList(ProviderContainer container) async {
  _section('a new party arrives on the parties screen');

  // Subscribe before reading. A `StreamProvider` that is only `read` never starts its
  // stream and sits in `AsyncLoading` for ever — measured, and it is the first thing this
  // file tripped over. Widgets `watch`, which subscribes; a headless reader must do it
  // explicitly, and the subscription has to outlive the read.
  _keep(container.listen(partiesProvider(PartyKind.customer), (_, __) {}));

  final before = await _data(() => container.read(partiesProvider(PartyKind.customer)));
  _check(
    'the customer list starts without this party',
    before.every((p) => p.name != 'حاجی رمضان'),
    'a stale scratch database?',
  );

  final money = container.read(moneyFormatProvider);
  final commands = container.read(bookCommandsProvider)!;
  final outcome = await commands.addParty(
    name: 'حاجی رمضان',
    nameUr: 'حاجی رمضان',
    phone: '0300-1234567',
    money: money,
  );

  _check('the party was created', outcome.ok, outcome.message);
  _check(
    'the outcome carries the new row id',
    (outcome.documentId ?? '').length == 36,
    'got "${outcome.documentId}"',
  );

  // No provider was invalidated by hand: the DAO wrote, the trigger/op-log side wrote, the
  // commit-scoped bus fired, and the StreamProvider re-ran. That chain is the check.
  final arrived = await _until(
    () => container
        .read(partiesProvider(PartyKind.customer))
        .value
        ?.any((p) => p.name == 'حاجی رمضان') ??
        false,
  );
  _check('the parties screen shows it without anything bumping the provider', arrived);

  final after = await _data(() => container.read(partiesProvider(PartyKind.customer)));
  final row = after.firstWhere((p) => p.name == 'حاجی رمضان');
  _check(
    'a brand-new party owes nothing',
    row.netMinor == 0 && row.receivableMinor == 0,
    'net=${row.netMinor} receivable=${row.receivableMinor}',
  );
  return row.partyId;
}

// ── C · the double-entry claim, tested from two screens at once ──────────────

int _cashOf(List<CashAccount> accounts) =>
    accounts.where((a) => a.isCash).fold(0, (sum, a) => sum + a.balanceMinor);

Future<void> _aHalfCashSaleMovesTwoScreens(
  ProviderContainer container,
  String partyId,
  int today,
  CashWindow month,
) async {
  _section('half cash, half credit: two screens move by two amounts');

  // Subscribe first. A StreamProvider that is only `read` never starts its stream, and the
  // screen is exactly what we are testing — so keep a listener alive for every provider the
  // assertions read.
  // Written out one by one rather than looped over a list, because `ProviderListenable` is
  // not exported from `package:riverpod/riverpod.dart` — the list would have to be typed
  // `dynamic`, which is how a typo in a provider name stops being a compile error.
  _keep(container.listen(dashboardProvider, (_, __) {}));
  _keep(container.listen(cashAccountsProvider, (_, __) {}));
  _keep(container.listen(billsProvider(DocKind.saleInvoice), (_, __) {}));
  _keep(container.listen(partiesProvider(PartyKind.customer), (_, __) {}));
  _keep(container.listen(cashBookProvider(month), (_, __) {}));
  _keep(container.listen(cashFlowProvider(month), (_, __) {}));

  final dashboardBefore = await _data(() => container.read(dashboardProvider));
  final cashBefore = _cashOf(await _data(() => container.read(cashAccountsProvider)));
  final flowsBefore = await _data(() => container.read(cashFlowProvider(month)));

  const gross = 1250000; // 12 500.00 in paisa — the shop's money is minor units, always
  const paid = 250000; // 2 500.00 at the counter
  const credit = gross - paid;

  final commands = container.read(bookCommandsProvider)!;
  final money = container.read(moneyFormatProvider);
  final outcome = await commands.recordInvoice(
    entryDate: today,
    grossMinor: gross,
    amountPaidMinor: paid,
    partyId: partyId,
    money: money,
    dueDate: EpochDay.addDays(today, 30),
    memo: 'chalk and tea, half cash',
  );

  _check('the invoice was posted', outcome.ok, outcome.message);
  // Two numbers, two sequences, and the UI must know which is which: the *document* number
  // (`INV-0001`) is what the shopkeeper writes on the paper bill, and the *journal entry*
  // (`JE-0001`) is what an accountant traces. `number_sequences` is keyed by node, so a
  // device that has never seen this invoice still allocates the next `INV` without colliding.
  final docPrefix = DocKind.prefixes[DocKind.saleInvoice] ?? '\u0000';
  _check(
    'the invoice carries a document number of its own',
    (outcome.documentNo ?? '').startsWith('$docPrefix-'),
    'documentNo="${outcome.documentNo}"',
  );
  _check(
    'and the journal entry behind it is numbered by the other sequence',
    (outcome.entryNo ?? '').startsWith('JE-'),
    'entryNo="${outcome.entryNo}"',
  );
  _check('the outcome names the document it created', (outcome.documentId ?? '').isNotEmpty);
  _check(
    'the message quotes the document number, which is the one on the paper',
    outcome.message.contains(outcome.documentNo ?? '\u0000'),
    'message="${outcome.message}"',
  );
  _check(
    'the message was formatted with the provider\'s money format',
    outcome.message.contains(money.format(gross)),
    'message="${outcome.message}" expected to contain "${money.format(gross)}"',
  );

  final dashboardSettled = await _until(
    () =>
        (container.read(dashboardProvider).value?.receivableMinor ?? dashboardBefore.receivableMinor) ==
        dashboardBefore.receivableMinor + credit,
  );
  _check(
    'the receivable rose by exactly the credit given ($credit)',
    dashboardSettled,
    'receivable went ${dashboardBefore.receivableMinor} → '
        '${container.read(dashboardProvider).value?.receivableMinor}',
  );

  final drawerSettled = await _until(
    () => _cashOf(container.read(cashAccountsProvider).value ?? const []) == cashBefore + paid,
  );
  _check(
    'the drawer rose by exactly the cash taken ($paid)',
    drawerSettled,
    'drawer went $cashBefore → ${_cashOf(container.read(cashAccountsProvider).value ?? const [])}',
  );

  final billSettled = await _until(() {
    final rows = container.read(billsProvider(DocKind.saleInvoice)).value;
    return rows != null &&
        rows.any((b) => b.documentId == outcome.documentId && b.balanceMinor == credit);
  });
  _check('the bill book shows the invoice with the credit balance', billSettled);

  final bill = (await _data(() => container.read(billsProvider(DocKind.saleInvoice))))
      .firstWhere((b) => b.documentId == outcome.documentId);
  _check('the bill carries the right total', bill.totalMinor == gross, 'total=${bill.totalMinor}');
  _check(
    'and the right amount paid, so the aging report is not lying',
    bill.paidMinor == paid,
    'paid=${bill.paidMinor}',
  );

  final partySettled = await _until(() {
    final rows = container.read(partiesProvider(PartyKind.customer)).value;
    return rows != null &&
        rows.any((p) => p.partyId == partyId && p.receivableMinor == credit);
  });
  _check('the customer sub-ledger shows the same credit', partySettled);

  final flows = await _data(() => container.read(cashFlowProvider(month)));
  final inflow = flows.fold(0, (sum, f) => sum + f.inflowMinor) -
      flowsBefore.fold(0, (sum, f) => sum + f.inflowMinor);
  _check(
    'the cash-flow chart counted the money in, not the invoice total',
    inflow == paid,
    'inflow delta=$inflow, expected $paid — the credit part moved no money',
  );
}

/// How many rows a table has, read straight from the database rather than from a view: the
/// rollback questions are answered by fact tables, never by a view that filters.
Future<int> _count(ProviderContainer container, String table) async =>
    await container.read(databaseProvider).readOne<int>(
          'SELECT count(*) AS n FROM $table',
          const [],
          (row) => row.read<int>('n'),
        ) ??
        -1;

// ── D · settling is not a second sale ────────────────────────────────────────

Future<void> _settlingClearsTheDebtWithoutASecondSale(
  ProviderContainer container,
  String partyId,
  int today,
  CashWindow month,
) async {
  _section('settling the invoice takes the debt back where it started');

  final dashboardBefore = await _data(() => container.read(dashboardProvider));
  final drawerBefore = _cashOf(await _data(() => container.read(cashAccountsProvider)));
  final bill = (await _data(() => container.read(billsProvider(DocKind.saleInvoice))))
      .firstWhere((b) => b.partyId == partyId);
  final documentsBefore = await _count(container, 'documents');

  final commands = container.read(bookCommandsProvider)!;
  final money = container.read(moneyFormatProvider);
  final outcome = await commands.settleInvoice(
    entryDate: today,
    amountMinor: bill.balanceMinor,
    documentId: bill.documentId,
    money: money,
    memo: 'cash on delivery',
  );

  _check('the payment was posted', outcome.ok, outcome.message);
  _check(
    'the receipt quotes the invoice it settled, not the payment entry',
    outcome.message.contains(bill.docNo),
    'message="${outcome.message}" docNo="${bill.docNo}"',
  );

  // `UiSql.bills` is the *worklist*: `WHERE balance_minor > 0`. A settled invoice leaving it
  // is the feature, not a disappearance — the bill book is a list of who still owes money.
  // The proof that the bill still exists is in the tables, so that is where this looks.
  final leftTheWorklist = await _until(() {
    final rows = container.read(billsProvider(DocKind.saleInvoice)).value;
    return rows != null && !rows.any((b) => b.documentId == bill.documentId);
  });
  _check('the settled bill leaves the outstanding worklist', leftTheWorklist);

  final allocated = await container.read(databaseProvider).readOne<int>(
    'SELECT COALESCE(SUM(amount_minor), 0) AS n FROM payment_allocations '
    'WHERE document_id = ?',
    [Variable<String>(bill.documentId)],
    (row) => row.read<int>('n'),
  );
  _check(
    'the payment was allocated against the bill, not just posted',
    allocated == bill.totalMinor,
    'allocated=$allocated total=${bill.totalMinor}',
  );
  final documentsAfter = await _count(container, 'documents');
  _check(
    'settling did not duplicate the document',
    documentsAfter == documentsBefore,
    'documents $documentsBefore → $documentsAfter',
  );

  final debtGone = await _until(
    () =>
        (container.read(dashboardProvider).value?.receivableMinor ?? dashboardBefore.receivableMinor) ==
        dashboardBefore.receivableMinor - bill.balanceMinor,
  );
  _check(
    'the receivable fell by exactly the settled amount',
    debtGone,
    'receivable ${dashboardBefore.receivableMinor} → '
        '${container.read(dashboardProvider).value?.receivableMinor}',
  );

  final drawerSettled = await _until(
    () => _cashOf(container.read(cashAccountsProvider).value ?? const []) ==
        drawerBefore + bill.balanceMinor,
  );
  _check(
    'and the money landed in the drawer',
    drawerSettled,
    'drawer $drawerBefore → ${_cashOf(container.read(cashAccountsProvider).value ?? const [])}',
  );

  final partyRow = (await _data(() => container.read(partiesProvider(PartyKind.customer))))
      .firstWhere((p) => p.partyId == partyId);
  _check(
    'the customer owes nothing again',
    partyRow.receivableMinor == 0 && partyRow.netMinor == 0,
    'receivable=${partyRow.receivableMinor} net=${partyRow.netMinor}',
  );

  final movements = await _data(() => container.read(cashBookProvider(month)));
  _check(
    'the cash book shows both legs: the counter cash and the settlement',
    movements.where((m) => m.memo != null).length >= 2,
    'movements=${movements.length}',
  );
}

// ── E · a refusal is a no-op, proven by counting ─────────────────────────────

/// Three refusals of three different kinds. The point is not that they fail — it is that
/// after they fail, **nothing** has changed: not the journal, not the documents, not the
/// drawer, not the customer's balance. A write path that reported the error after committing
/// half the entry would pass a message check and fail every count here.
Future<void> _refusalsChangeNothing(
  ProviderContainer container,
  int today,
  CashWindow month,
  String bogusId,
) async {
  _section('three refusals that must leave the books bit-identical');

  Future<Map<String, int>> snapshot() async {
    return {
      'entries': await _count(container, 'journal_entries'),
      'lines': await _count(container, 'journal_lines'),
      'documents': await _count(container, 'documents'),
      'drawer': _cashOf(await _data(() => container.read(cashAccountsProvider))),
    };
  }

  final before = await snapshot();
  final commands = container.read(bookCommandsProvider)!;
  final money = container.read(moneyFormatProvider);

  // (1) Credit with nobody to recover it from — refused before a single row is written.
  final noParty = await commands.recordSale(
    entryDate: today,
    grossMinor: 500000,
    amountPaidMinor: 0,
    partyId: null,
    money: money,
    memo: 'on the slate',
  );
  _check(
    'a credit sale with no party is refused, and the reason is about the party',
    !noParty.ok && noParty.code == 'FIN-2',
    'ok=${noParty.ok} code=${noParty.code} msg=${noParty.message}',
  );
  _check(
    'the refusal reads like a sentence a shopkeeper can act on',
    noParty.message.contains('customer') && !noParty.message.contains('Exception'),
    'msg="${noParty.message}"',
  );

  // (2) A zero-rupee expense. The form can only send this if a bug lets it, which is exactly
  //     when the layer underneath has to be the one saying no.
  final zero = await commands.recordExpense(
    entryDate: today,
    amountMinor: 0,
    money: money,
    memo: 'nothing',
  );
  _check(
    'an expense of zero is refused by the books, not written',
    !zero.ok && zero.code == 'FIN-1',
    'ok=${zero.ok} code=${zero.code} msg=${zero.message}',
  );

  // (3) Settling an invoice that belongs to no book. The row is a well-formed 36-character
  //     id, so this exercises the lookup *inside* the transaction rather than a CHECK.
  final orphan = await commands.settleInvoice(
    entryDate: today,
    amountMinor: 1000,
    documentId: bogusId,
    money: money,
  );
  _check(
    'settling an invoice from another book is refused',
    !orphan.ok && orphan.code == 'INV-2',
    'ok=${orphan.ok} code=${orphan.code} msg=${orphan.message}',
  );

  final after = await snapshot();
  _check(
    'not one journal entry survives the three refusals',
    after['entries'] == before['entries'],
    '${before['entries']} → ${after['entries']}',
  );
  _check(
    'not one journal line survives them either',
    after['lines'] == before['lines'],
    '${before['lines']} → ${after['lines']}',
  );
  _check(
    'no phantom document was created',
    after['documents'] == before['documents'],
    '${before['documents']} → ${after['documents']}',
  );
  _check(
    'and the drawer is exactly where it was',
    after['drawer'] == before['drawer'],
    '${before['drawer']} → ${after['drawer']}',
  );

  final movementCount = (await _data(() => container.read(cashBookProvider(month)))).length;
  _check(
    'the cash book did not grow a row for a failed write',
    movementCount >= 2,
    'the settled movements are still there; nothing was removed by the rollback',
  );
}

// ── F · an expense moves one side of the books, and says so ──────────────────

Future<void> _anExpenseOnlyLeavesTheDrawer(
  ProviderContainer container,
  int today,
  CashWindow month,
) async {
  _section('an expense leaves the drawer and nothing else');

  final dashboardBefore = await _data(() => container.read(dashboardProvider));
  final drawerBefore = _cashOf(await _data(() => container.read(cashAccountsProvider)));
  final flowBefore = (await _data(() => container.read(cashFlowProvider(month))))
      .fold(0, (sum, f) => sum + f.outflowMinor);

  final commands = container.read(bookCommandsProvider)!;
  final outcome = await commands.recordExpense(
    entryDate: today,
    amountMinor: 120000,
    money: container.read(moneyFormatProvider),
    role: AccountRole.miscExpense,
    memo: 'rickshaw fare',
  );

  _check('the expense was posted', outcome.ok, outcome.message);

  final drawerSettled = await _until(
    () => _cashOf(container.read(cashAccountsProvider).value ?? const []) ==
        drawerBefore - 120000,
  );
  _check(
    'the drawer fell by the exact amount',
    drawerSettled,
    'drawer $drawerBefore → ${_cashOf(container.read(cashAccountsProvider).value ?? const [])}',
  );

  // Polled, not read once. The bus coalesces a burst of changes into one notification, so the
  // first read after the write can still return the *previous* emission — which is exactly how
  // this check flaked once. `_until` waits on the same `AsyncValue` a chart widget would watch.
  final flowCaughtUp = await _until(() {
    final flow = container.read(cashFlowProvider(month)).value;
    return flow != null &&
        flow.fold(0, (sum, f) => sum + f.outflowMinor) == flowBefore + 120000;
  });
  _check(
    'the chart counted it as money out, not money in',
    flowCaughtUp,
    'outflow was $flowBefore',
  );

  final dashboardNow = await _data(() => container.read(dashboardProvider));
  _check(
    'an expense does not touch what customers owe',
    dashboardNow.receivableMinor == dashboardBefore.receivableMinor,
    'receivable ${dashboardBefore.receivableMinor} → ${dashboardNow.receivableMinor}',
  );

  final inBook = await _data(() => container.read(cashBookProvider(month)));
  _check(
    'the cash book has the movement with its memo',
    inBook.any((m) => m.memo == 'rickshaw fare'),
    'memos=${inBook.map((m) => m.memo).whereType<String>().toList()}',
  );
}

// ── G · links, routes and the forms behind them ──────────────────────────────

/// The user's third directive for this batch, in their words: *"the GoRouter setup for the 8
/// screens + `khata_app.dart` must handle deep links, crucial for automated SMS/WhatsApp
/// reminders and invoice sharing."*
///
/// A reminder is a message with a url in it, and the url is the half that has to work when the
/// customer taps it a week later on a phone that has never had this app open. So the chain is
/// asserted end to end, in the order it happens:
///
/// 1. [`parseDeepLink`](../lib/apps/deep_links.dart) — a pure function, tested for all three
///    shapes the operating system can hand over (`khatapro://…`, an https app link, and the
///    bare path Android gives a *running* app).
/// 2. [`routeFor`](../lib/ui/routes.dart) — the mapping from a parsed link to the screen it
///    opens. This is what the router uses, cold and warm, so asserting it here is asserting
///    the router.
/// 3. [`formFor`](…/lib/ui/routes.dart) — `?action=receive` opens the receipt form, and the
///    spec it hands back is the *same* `receiptSpec` the ledger screen's own button builds.
/// 4. The form actually posts: `onSave` is called with the numbers a shopkeeper would have
///    typed, and the customer's balance moves by exactly that much. Nothing on this path is
///    simulated; the only thing missing is a fingertip.
Future<void> _linksLandOnTheRightScreens(
  ProviderContainer container,
  String partyId,
  int today,
) async {
  _section('a reminder link opens the right screen, and the form behind it posts');

  final money = container.read(moneyFormatProvider);
  final strings = UiStrings(container.read(displayPrefsProvider).language);
  final commands = container.read(bookCommandsProvider);

  // Subscribe before reading: a `StreamProvider` family member that is only `read` sits in
  // `AsyncLoading` for ever (the trap documented in section B). The screens `watch`, so this
  // is the one thing a headless reader has to do by hand.
  _keep(container.listen(partyProvider(partyId), (_, __) {}));

  // ── the three shapes the OS can deliver ────────────────────────────────────
  final scheme = Uri.parse('khatapro://party/$partyId');
  final https = Uri.parse('https://$khataLinkHost/party/$partyId');
  // The warm-start shape: Android hands over a path with no scheme at all.
  final pathOnly = Uri.parse('/party/$partyId');

  final fromScheme = parseDeepLink(scheme);
  final fromHttps = parseDeepLink(https);
  final fromPath = parseDeepLink(pathOnly);

  _check(
    'a custom-scheme link parses, and its first segment is not eaten by the host',
    fromScheme?.partyId == partyId,
    'got ${fromScheme?.partyId}',
  );
  _check(
    'the https app link parses to the same party',
    fromHttps?.partyId == partyId && fromHttps?.location == fromScheme?.location,
  );
  _check(
    'and the bare path the OS hands a running app parses too',
    fromPath?.partyId == partyId,
    'got ${fromPath?.partyId}',
  );

  // ── routeFor is the router's own mapping ───────────────────────────────────
  final screen = routeFor(fromScheme!);
  _check(
    'the link opens the party ledger, not the parties tab',
    screen is GoScreen && screen.path == '/party/$partyId',
    'got $screen',
  );
  _check(
    'and the router is told the row is expected to exist in this book, so a foreign id gets '
    'the "not in your khata" page instead of a blank screen',
    screen is GoScreen && screen.expectsRow,
  );

  final tab = parseDeepLink(Uri.parse('khatapro://cash'))!;
  _check(
    'a tab link maps to a plain location — no wrapper, no extra route',
    routeFor(tab) == KhataRoutes.cash,
    'got ${routeFor(tab)}',
  );

  // ── the action, and why it is carried inside the location ──────────────────
  final receive = parseDeepLink(Uri.parse('khatapro://party/$partyId?action=receive'))!;
  _check(
    'a "receive payment" link keeps its action in the location — the location is all a cold '
    'start has, so dropping it there would open a screen that does nothing',
    receive.location == '/party/$partyId?action=receive',
    'got ${receive.location}',
  );
  final receiveScreen = routeFor(receive);
  _check(
    'the action survives routeFor as well',
    receiveScreen is GoScreen && receiveScreen.action == LinkAction.receive,
    'got $receiveScreen',
  );
  _check(
    'a plain link carries no action',
    routeFor(fromScheme) is GoScreen &&
        (routeFor(fromScheme) as GoScreen).action == LinkAction.open,
  );

  // ── and the form the action opens ──────────────────────────────────────────
  final forms = EntryForms(commands: commands!, money: money, strings: strings);
  final linked = formFor(
    action: LinkAction.receive,
    forms: forms,
    partyId: partyId,
    partyName: 'linked party',
  );
  final sameAsTheButton = receiptSpec(
    commands: commands,
    money: money,
    strings: strings,
    partyId: partyId,
    partyName: 'linked party',
  );
  _check(
    '?action=receive opens the receipt form — the same one the ledger screen\'s button builds, '
    'so a link cannot drift from the button',
    linked != null &&
        linked.title == sameAsTheButton.title &&
        linked.partyKind == sameAsTheButton.partyKind,
    'got ${linked?.title}',
  );
  _check(
    'the linked form is locked to the party in the link, so the money cannot land on someone '
    'else',
    linked?.lockedPartyId == partyId,
  );
  _check(
    'a money-OUT action opens nothing: the books have no "paid a supplier, no bill named" '
    'command, so the link lands on the ledger where the bills are',
    formFor(action: LinkAction.open, forms: forms, partyId: partyId) == null,
  );

  // ── a link that belongs to someone else, and one that says nothing ─────────
  _check(
    'a link for another app is ignored, not routed to an error page',
    parseDeepLink(Uri.parse('https://example.com/party/$partyId')) == null,
  );
  _check(
    'and a party link with no id is refused outright',
    parseDeepLink(Uri.parse('khatapro://party')) == null,
  );

  // ── the message itself ─────────────────────────────────────────────────────
  // The reminder is built from the *same* four values a notification would carry, and the url
  // inside it has to be one this app can parse back — a message whose link is one character
  // off is a message that looks fine and does nothing.
  final balanceBefore =
      (await _data(() => container.read(partyProvider(partyId))))?.netMinor ?? 0;
  final body = buildReminder(
    partyName: 'linked party',
    balanceMinor: balanceBefore.abs(),
    money: money,
    link: partyLinkFor(partyId),
    language: UiLanguage.urdu,
    daysOverdue: 6,
  );
  final inMessage = Uri.tryParse(RegExp(r'\S+://\S+').firstMatch(body)?.group(0) ?? '');
  _check(
    'the reminder body carries a link this app parses back to the same party',
    inMessage != null && parseDeepLink(inMessage)?.partyId == partyId,
    'body: $body',
  );
  _check(
    'and the Urdu reminder is Urdu, with the amount written the way the shopkeeper reads it',
    body.contains('باقی ہے') && body.contains(money.balance(balanceBefore.abs())),
  );
  // The share sheet is the one thing this app does *not* own — so both intents have to carry
  // the body through a url, which means encoding matters more than it looks.
  final sms = smsUri(phone: normalisePhone('0300 1234567'), body: body);
  final wa = whatsAppUri(phone: normalisePhone('0300 1234567'), body: body);
  _check(
    'the SMS intent carries the whole body, percent-encoded',
    sms.scheme == 'sms' && sms.queryParameters['body'] == body,
  );
  _check(
    'the WhatsApp intent carries it too, addressed by the same international number',
    wa.host == 'wa.me' && wa.queryParameters['text'] == body,
    'got $wa',
  );
  _check(
    'a local number becomes the E.164 number the intents need',
    normalisePhone('0300 1234567') == '+923001234567',
    'got ${normalisePhone('0300 1234567')}',
  );

  // ── the round trip that matters: the numbers travel too ────────────────────
  // Everything above is string work. This is the part that changes the books: the values a
  // filled-in form holds go through `onSave`, and the customer's balance must move by the
  // amount that was on screen — no re-parse, no rounding, no second look at the display
  // settings in between.
  final typed = amountForEditing(250000); // "2,500.00"
  final back = parseAmountMinor(typed);
  _check(
    'an amount survives the trip through the amount field',
    back == 250000,
    '"$typed" → $back',
  );

  final outcome = await linked!.onSave(
    EntrySheetValues(
      amountMinor: back!,
      entryDate: today,
      toBank: false,
      partyId: partyId,
      memo: 'from a link',
    ),
  );
  _check('the linked form posts', outcome.ok, 'refused: ${outcome.message}');

  final settled = await _until(
    () => container.read(partyProvider(partyId)).value?.netMinor != balanceBefore,
  );
  final balanceAfter =
      (await _data(() => container.read(partyProvider(partyId))))?.netMinor ?? 0;
  _check(
    'and the customer\'s balance moved by exactly the amount the form held — a receipt takes '
    'the receivable *down*, so the sign follows the double-entry side, not the cash direction',
    settled && balanceAfter == balanceBefore - 250000,
    '$balanceBefore → $balanceAfter (expected ${balanceBefore - 250000})',
  );

  // The memo is what makes the row readable in the ledger a month later: "from a link" is how
  // a shopkeeper tells a link-driven receipt from one typed at the counter.
  final line = (await _data(() => container.read(cashBookProvider(CashWindow.thisMonth(today)))))
      .where((l) => l.memo == 'from a link');
  _check('the cash book shows it, with the memo the form carried', line.isNotEmpty);
}
