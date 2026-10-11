/// KhataPro · the reactive layer, as micro-providers.
///
/// ## Why Riverpod, and why "micro"
///
/// The requirement is that a row written by a background sync appears on screen without a
/// full-screen rebuild — and, equally, that scrolling a 100 000-line ledger never rebuilds
/// the header. That is a question about *granularity*, not about which state library is
/// fashionable:
///
///  * every provider below owns exactly one screen-sized question, so a widget that
///    watches the cash book does not rebuild when the party list changes;
///  * families keyed on a value (`partyProvider(partyId)`) mean opening a second party
///    does not invalidate the first one's cache;
///  * `select` on the consumer side narrows a rebuild to the fields a widget actually
///    reads, so a dashboard whose `draftCount` changed does not re-render the chart.
///
/// ## The dependency seam
///
/// [databaseProvider] throws unless overridden, and `main.dart` overrides it at boot —
/// after the SQLCipher key has been unwrapped from the platform keystore. Nothing in this
/// file can reach for a database that does not exist yet, and no test needs a platform
/// channel to build a container.
///
/// ## Testability
///
/// Written so that `tool/ui_verify.dart` can drive a **real** `ProviderContainer` against a
/// **real** Drift database with real writes — not mocks. A state layer that has only ever
/// been tested against fakes meets a database for the first time in a user's hand.
library;

import 'package:drift/drift.dart' show QueryRow, Variable;
// Riverpod 3.4.3. Two API details this file depends on, both verified against the pinned
// source rather than assumed: `AsyncValue.value` is the nullable accessor (there is no
// `valueOrNull` any more), and `provider.future` yields a `Future` that must be awaited.
import 'package:riverpod/riverpod.dart';

import '../../core/utils/epoch_day.dart';
import '../../data/db/database.dart';
import '../format/formatting.dart';
import '../lists/paged_list.dart';
import 'changes.dart';
import 'ledger_source.dart';
import 'queries.dart';

// ── the seams ────────────────────────────────────────────────────────────────

/// The one database handle for the whole app. Overridden at boot; never null, never
/// re-created (the SQLCipher singleton rule from Deliverable 2).
final databaseProvider = Provider<KhataDatabase>(
  (ref) => throw StateError(
    'databaseProvider was not overridden. main.dart overrides it after the SQLCipher '
    'key is unwrapped — see docs/PLATFORM_SETUP.md. Nothing may open the database a '
    'second time: a second connection re-runs key derivation.',
  ),
);

/// The change bus everything listens to (see `changes.dart`).
final changeBusProvider = Provider<ChangeBus>((ref) {
  final bus = ChangeBus();
  // Attached here rather than in `main.dart`, so that any container — the app's or a
  // test's — has a bus that is actually connected to the database. Every committed write
  // bumps it: a local edit, an invoice, a sync batch, a restored backup.
  bus.attachTo(ref.watch(databaseProvider));
  ref.onDispose(bus.dispose);
  return bus;
});

/// The change *stream*, as a provider, so widgets never hold a subscription of their own.
///
/// `int`, not `void`: a provider whose value never changes is a provider Riverpod will not
/// notify anyone about (see `changes.dart`).
final changesProvider = StreamProvider<int>(
  (ref) => ref.watch(changeBusProvider).changes,
);

/// The single ledger this install keeps books for, read from the database rather than
/// hard-coded, so a future multi-business build changes one row and no code.
final ledgerIdProvider = FutureProvider<String>((ref) async {
  final db = ref.watch(databaseProvider);
  final id = await db.readOne<String>(
    'SELECT id FROM ledgers LIMIT 1',
    const [],
    (row) => '${row.data['id']}',
  );
  return id ?? '';
});

/// Today, as the books see it: `session_flags.today_epoch_day` when a business day is
/// pinned, the device clock otherwise. A Monday-morning entry posted on Sunday night
/// lands in the right day.
final businessDayProvider = FutureProvider<int>((ref) async {
  final db = ref.watch(databaseProvider);
  // Re-read when a change lands: the business day can be moved from Settings, and every
  // date in the UI is derived from this number.
  ref.watch(changesProvider);
  final today = await db.readOne<int>(
    'SELECT today_epoch_day FROM v_now',
    const [],
    (row) => (row.data['today_epoch_day'] as num?)?.toInt() ?? EpochDay.today(),
  );
  return today ?? EpochDay.today();
});

// ── display preferences ──────────────────────────────────────────────────────

/// Language and numeral style. A `Notifier` rather than a read of `app_settings`: the UI
/// must render on the first frame, and a preference is not worth a loading state.
/// `main.dart` seeds it from the database and writes changes back.
enum UiLanguage {
  english('en', false),
  urdu('ur', true);

  const UiLanguage(this.code, this.isRtl);

  final String code;
  final bool isRtl;
}

final class DisplayPrefs {
  const DisplayPrefs({
    this.language = UiLanguage.english,
    this.grouping = GroupingStyle.lakh,
    this.currencySymbol = 'Rs',
    this.currencyCode = 'PKR',
  });

  final UiLanguage language;
  final GroupingStyle grouping;
  final String currencySymbol;
  final String currencyCode;

  /// Urdu is not "English with different letters": the digits change too, and a
  /// shopkeeper reading Urdu columns expects `۱،۲۳،۴۵۶`.
  DigitStyle get digits => language == UiLanguage.urdu ? DigitStyle.urdu : DigitStyle.western;

  MoneyFormat get money => MoneyFormat(
        currencySymbol: currencySymbol,
        grouping: grouping,
        digits: digits,
      );

  DisplayPrefs copyWith({
    UiLanguage? language,
    GroupingStyle? grouping,
    String? currencySymbol,
    String? currencyCode,
  }) =>
      DisplayPrefs(
        language: language ?? this.language,
        grouping: grouping ?? this.grouping,
        currencySymbol: currencySymbol ?? this.currencySymbol,
        currencyCode: currencyCode ?? this.currencyCode,
      );
}

final class DisplayPrefsNotifier extends Notifier<DisplayPrefs> {
  @override
  DisplayPrefs build() => const DisplayPrefs();

  void setLanguage(UiLanguage language) => state = state.copyWith(language: language);

  void setGrouping(GroupingStyle grouping) => state = state.copyWith(grouping: grouping);

  /// Seeds the notifier from `app_settings` at boot, without a rebuild for each field.
  void hydrate(DisplayPrefs prefs) => state = prefs;
}

final displayPrefsProvider =
    NotifierProvider<DisplayPrefsNotifier, DisplayPrefs>(DisplayPrefsNotifier.new);

/// The money formatter for the active language — the single object every screen formats
/// with, so a column of amounts cannot end up half in Urdu digits.
final moneyFormatProvider = Provider<MoneyFormat>(
  (ref) => ref.watch(displayPrefsProvider).money,
);

// ── dashboard ────────────────────────────────────────────────────────────────

/// The dashboard: one metrics row plus the "who to chase" shortlist, re-read on every
/// coalesced change signal. Two queries per change, not one per widget.
final dashboardProvider = StreamProvider<Dashboard>((ref) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return (() async* {
    Future<Dashboard> snapshot() async {
      final metrics = await db.readOne(
            UiSql.dashboard,
            [Variable<String>(ledgerId), Variable<String>(ledgerId)],
            Dashboard.fromRow,
          ) ??
          const Dashboard(
            currencyCode: 'PKR',
            todayEpochDay: 0,
            draftCount: 0,
            todaySalesMinor: 0,
            monthSalesMinor: 0,
            monthExpenseMinor: 0,
            monthProfitMinor: 0,
            receivableMinor: 0,
            payableMinor: 0,
            cashMinor: 0,
            monthCollectionsMinor: 0,
            topDebtors: [],
            todayMovements: [],
          );
      // The three biggest debtors: on the same card as the money, because "you are owed
      // Rs 3,40,000" without "by whom" is a worry rather than a tool.
      final debtors = await db.readAll(
        UiSql.topDebtors,
        [Variable<String>(ledgerId), const Variable<int>(3)],
        PartyBalance.fromRow,
      );
      return metrics.withLists(topDebtors: debtors, todayMovements: const []);
    }

    yield await snapshot();
    await for (final _ in changes) {
      yield await snapshot();
    }
  })();
});

// ── parties ──────────────────────────────────────────────────────────────────

/// The party list, filtered by kind. `kind == 0` is every kind.
final partiesProvider = StreamProvider.family<List<PartyBalance>, int>((ref, kind) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return db.watchAll(
    UiSql.parties,
    PartyBalance.fromRow,
    args: [
      Variable<String>(ledgerId),
      Variable<int>(kind),
      Variable<int>(kind),
      const Variable<int>(400),
      const Variable<int>(0),
    ],
    changes: changes,
  );
});

/// One party's header row (name, phone, current balance) for the ledger screen.
final partyProvider = StreamProvider.family<PartyBalance?, String>((ref, partyId) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return db.watchOne(
    'SELECT party_id, name, name_ur, kind, phone, is_walk_in, '
    'net_minor, receivable_minor, payable_minor, line_count, last_activity_date '
    'FROM v_party_balances WHERE ledger_id = ? AND party_id = ?',
    PartyBalance.fromRow,
    args: [Variable<String>(ledgerId), Variable<String>(partyId)],
    changes: changes,
  );
});

/// What the ledger screen renders: the rows in hand, whether more are coming, and the
/// pager's own verdict on whether the walk balanced.
final class LedgerState {
  const LedgerState({
    this.positions = const [],
    this.isLoading = true,
    this.hasMore = true,
    this.cells = const [],
    this.integrityNote,
    this.generation = 0,
  });

  final List<LedgerPosition> positions;
  final bool isLoading;
  final bool hasMore;

  /// The flattened list the `ListView.builder` indexes — day headers included, so the
  /// item count, the scrollbar and the index arithmetic all agree.
  final List<LedgerCell> cells;

  /// Non-null when the walk did not land on zero: the balances on screen are then not
  /// trustworthy, and this says so rather than showing plausible numbers.
  final String? integrityNote;

  final int generation;

  /// The last balance in the list, for the footer line.
  int get oldestBalanceMinor =>
      positions.isEmpty ? 0 : positions.last.balanceBeforeMinor;

  int get dayCount => cells.whereType<DayHeaderCell>().length;
}

/// Owns one party's ledger pager.
///
/// An `AsyncNotifier` because the anchor is a database read: `build()` waits for the
/// party's current balance and then walks the first page from it. The notifier listens to
/// the change bus itself, so a sync landing while the user is reading updates the same
/// list object — with the anchor moved — instead of replacing the widget subtree and
/// throwing away the scroll offset.
final class LedgerController extends AsyncNotifier<LedgerState> {
  LedgerController(this.partyId);

  final String partyId;

  LedgerPager? _pager;
  var _loadingMore = false;
  var _applyingRemoteChange = false;

  /// The pager, for a test or a debug screen. Null until [build] has completed.
  LedgerPager? get pager => _pager;

  @override
  Future<LedgerState> build() async {
    final db = ref.watch(databaseProvider);
    // `await`ed: `provider.future` is a `Future<String>`, and the missing await here was
    // a compile error the analyzer caught — which is exactly why the Flutter-facing code
    // is type-checked and not just reviewed.
    final ledgerId = await ref.watch(ledgerIdProvider.future);
    final anchor = await db.partyBalanceMinor(ledgerId, partyId);

    final pager = LedgerPager(
      source: SqlLedgerSource(db: db, ledgerId: ledgerId, partyId: partyId),
      closingBalanceMinor: anchor,
    );
    _pager = pager;
    ref.onDispose(() => _pager = null);

    await pager.loadOlder();

    // A local edit and a background sync both arrive through the same bus, and this is the
    // only place that reacts to it. `ref.listen` (not `watch`) so the rebuild is a state
    // update on *this* notifier rather than a re-creation of it — which is what keeps the
    // user's scroll position while a merge lands underneath.
    ref.listen(changesProvider, (_, __) => refresh());

    return _snapshot(pager);
  }

  /// Loads the next (older) page. Called by the scroll listener when the list runs out.
  Future<void> loadMore() async {
    final pager = _pager;
    if (pager == null || _loadingMore || !pager.hasMore) return;
    _loadingMore = true;
    state = AsyncData(_snapshot(pager, loading: true));
    await pager.loadOlder();
    _loadingMore = false;
    // The user can leave the screen mid-read: `ref.mounted` is Riverpod's own guard for
    // exactly this, and without it writing `state` on a disposed notifier throws.
    if (!ref.mounted) return;
    state = AsyncData(_snapshot(pager));
  }

  /// Re-reads the ledger from a freshly-read anchor. Called when the change bus fires.
  ///
  /// Every read here is followed by a `ref.mounted` check, because this method is driven by
  /// a *notification* rather than by a user action: a sync can land at the exact moment the
  /// user leaves the ledger screen, and writing `state` on a disposed notifier throws
  /// ("Cannot use the Ref … after it has been disposed"). The suite found that as an
  /// unhandled exception during teardown, which in a shop would be a crash on the way out
  /// of the screen the user was reading.
  Future<void> refresh() async {
    final pager = _pager;
    if (pager == null || _applyingRemoteChange || !ref.mounted) return;
    _applyingRemoteChange = true;
    try {
      final db = ref.read(databaseProvider);
      final ledgerId = await ref.read(ledgerIdProvider.future);
      final anchor = await db.partyBalanceMinor(ledgerId, partyId);
      if (!ref.mounted) return;
      await pager.setClosingBalance(anchor);
      if (!ref.mounted) return;
      state = AsyncData(_snapshot(pager));
    } finally {
      _applyingRemoteChange = false;
    }
  }

  LedgerState _snapshot(LedgerPager pager, {bool loading = false}) => LedgerState(
        positions: pager.positions,
        isLoading: loading,
        hasMore: pager.hasMore,
        cells: LedgerLayout.cells(pager.positions),
        integrityNote: pager.integrityNote,
        generation: pager.generation,
      );
}

/// The ledger for one party. `ref.read(ledgerProvider(id).notifier).loadMore()` is how a
/// scroll listener asks for the next page.
final ledgerProvider =
    AsyncNotifierProvider.family<LedgerController, LedgerState, String>(
  LedgerController.new,
);

// ── cash book ────────────────────────────────────────────────────────────────

/// A window for the cash book and its chart.
final class CashWindow {
  const CashWindow({required this.fromDay, required this.toDay});

  final int fromDay;
  final int toDay;

  static CashWindow lastDays(int today, int days) =>
      CashWindow(fromDay: today - days + 1, toDay: today);

  static CashWindow thisMonth(int today) =>
      CashWindow(fromDay: EpochDay.startOfMonth(today), toDay: today);

  static CashWindow thisYear(int today) =>
      CashWindow(fromDay: EpochDay.startOfYear(today), toDay: today);

  @override
  bool operator ==(Object other) =>
      other is CashWindow && other.fromDay == fromDay && other.toDay == toDay;

  @override
  int get hashCode => Object.hash(fromDay, toDay);
}

/// The cash accounts and their balances.
final cashAccountsProvider = StreamProvider<List<CashAccount>>((ref) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return db.watchAll(
    UiSql.cashAccounts,
    CashAccount.fromRow,
    args: [Variable<String>(ledgerId)],
    changes: changes,
  );
});

/// The day-by-day cash series for the chart: gap-free, and carrying its balance forward
/// across quiet days.
///
/// The opening balance is *derived* — the balance now, minus everything that moved inside
/// the window — because asking the database for a historical balance would mean a second
/// index or a scan of every line before the window.
final cashFlowProvider = StreamProvider.family<List<DayFlowPoint>, CashWindow>((ref, window) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return (() async* {
    Future<List<DayFlowPoint>> snapshot() async {
      final rows = await db.readAll(
        UiSql.cashFlowRows,
        [
          Variable<String>(ledgerId),
          Variable<int>(window.fromDay),
          Variable<int>(window.toDay),
        ],
        (row) => (
          day: (row.data['epoch_day'] as num?)?.toInt() ?? 0,
          inflow: (row.data['inflow_minor'] as num?)?.toInt() ?? 0,
          outflow: (row.data['outflow_minor'] as num?)?.toInt() ?? 0,
        ),
      );
      final closing = await db.readOne<int>(
        'SELECT COALESCE(SUM(ab.net_minor * a.normal_balance), 0) '
        'FROM account_balances ab JOIN accounts a ON a.id = ab.account_id AND a.is_cash = 1 '
        'WHERE ab.ledger_id = ? AND ab.period_id = 0',
        [Variable<String>(ledgerId)],
        (row) => (row.data.values.first as num?)?.toInt() ?? 0,
      );

      var net = 0;
      for (final row in rows) {
        net += row.inflow - row.outflow;
      }
      var balance = (closing ?? 0) - net;

      final byDay = {for (final row in rows) row.day: row};
      final series = <DayFlowPoint>[];
      for (var day = window.fromDay; day <= window.toDay; day++) {
        final movement = byDay[day];
        final inflow = movement?.inflow ?? 0;
        final outflow = movement?.outflow ?? 0;
        balance += inflow - outflow;
        series.add(
          DayFlowPoint(
            epochDay: day,
            inflowMinor: inflow,
            outflowMinor: outflow,
            balanceMinor: balance,
          ),
        );
      }
      return series;
    }

    yield await snapshot();
    await for (final _ in changes) {
      yield await snapshot();
    }
  })();
});

/// The Cash Book's transaction list: posted lines that touched cash or bank, newest
/// first. This is the screen a shopkeeper opens at closing time.
final cashBookProvider = StreamProvider.family<List<LedgerLine>, CashWindow>((ref, window) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return db.watchAll(
    UiSql.cashBook,
    LedgerLine.fromRow,
    args: [
      Variable<String>(ledgerId),
      Variable<int>(window.fromDay),
      Variable<int>(window.fromDay),
      Variable<int>(window.toDay),
      Variable<int>(window.toDay),
      const Variable<int>(400),
    ],
    changes: changes,
  );
});

// ── bill book ────────────────────────────────────────────────────────────────

/// Unpaid and partly-paid bills, most overdue first. `docKind == 0` is every kind.
final billsProvider = StreamProvider.family<List<BillRow>, int>((ref, docKind) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return db.watchAll(
    UiSql.bills,
    BillRow.fromRow,
    args: [
      Variable<String>(ledgerId),
      Variable<int>(docKind),
      Variable<int>(docKind),
      const Variable<int>(300),
    ],
    changes: changes,
  );
});

// ── stock ────────────────────────────────────────────────────────────────────

/// Stock on hand. `lowOnly` is the re-order list, which is the reason a shopkeeper keeps
/// stock records at all.
final stockProvider = StreamProvider.family<List<StockRow>, bool>((ref, lowOnly) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return db.watchAll(
    UiSql.stock,
    StockRow.fromRow,
    args: [
      Variable<String>(ledgerId),
      const Variable<int>(1),
      Variable<int>(lowOnly ? 1 : 0),
      const Variable<int>(300),
    ],
    changes: changes,
  );
});

/// Recent movements, optionally for one item (empty string means "all").
final stockMovesProvider = StreamProvider.family<List<StockMoveRow>, String>((ref, itemId) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return db.watchAll(
    UiSql.stockMoves,
    StockMoveRow.fromRow,
    args: [
      Variable<String>(ledgerId),
      Variable<String>(itemId),
      Variable<String>(itemId),
      const Variable<int>(200),
    ],
    changes: changes,
  );
});

// ── staff ────────────────────────────────────────────────────────────────────

/// Employees, with the balance each is owed — unpaid wages are a liability, and a credit
/// balance on an employee's sub-ledger is exactly that.
final staffProvider = StreamProvider<List<PartyBalance>>((ref) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return db.watchAll(
    UiSql.staff,
    PartyBalance.fromRow,
    args: [Variable<String>(ledgerId), const Variable<int>(200)],
    changes: changes,
  );
});

// ── sync status and drafts ───────────────────────────────────────────────────

/// What the sync has and has not done, for the dashboard: "3 entries not yet sent to your
/// other phone" and "2 conflicts need your decision" are things the owner of the books
/// should see without opening a settings screen.
final syncHealthProvider = StreamProvider<SyncHealth>((ref) {
  final db = ref.watch(databaseProvider);
  final changes = ref.watch(changeBusProvider).changes;
  return db.watchOne(UiSql.syncHealth, SyncHealth.fromRow, changes: changes).map(
        (value) =>
            value ?? const SyncHealth(pendingOps: 0, trustedPeers: 0, unreviewedConflicts: 0),
      );
});

/// Conflicts waiting for a human decision.
final conflictsProvider = StreamProvider<List<ConflictRow>>((ref) {
  final db = ref.watch(databaseProvider);
  final changes = ref.watch(changeBusProvider).changes;
  return db.watchAll(
    UiSql.conflicts,
    ConflictRow.fromRow,
    args: const [Variable<String>(''), Variable<String>(''), Variable<int>(50)],
    changes: changes,
  );
});

/// Drafts, so unfinished work cannot be forgotten.
final draftsProvider = StreamProvider<List<DraftRow>>((ref) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(ledgerIdProvider).value;
  final changes = ref.watch(changeBusProvider).changes;
  if (ledgerId == null) return const Stream.empty();

  return db.watchAll(
    UiSql.drafts,
    DraftRow.fromRow,
    args: [Variable<String>(ledgerId), const Variable<int>(20)],
    changes: changes,
  );
});

/// One unposted entry. A draft is a note to self, not a transaction: it is invisible to
/// every report until it is posted, and this row is how it stays visible to the user.
final class DraftRow {
  const DraftRow({
    required this.entryId,
    required this.entryNo,
    required this.entryDate,
    required this.totalMinor,
    this.memo,
  });

  final String entryId;
  final String entryNo;
  final int entryDate;
  final int totalMinor;
  final String? memo;

  static DraftRow fromRow(QueryRow row) => DraftRow(
        entryId: '${row.data['id']}',
        entryNo: '${row.data['entry_no']}',
        entryDate: (row.data['entry_date'] as num?)?.toInt() ?? 0,
        totalMinor: (row.data['total_minor'] as num?)?.toInt() ?? 0,
        memo: row.data['memo'] as String?,
      );
}
