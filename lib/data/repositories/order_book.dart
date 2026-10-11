/// KhataPro · the order book: every business action, as one checked transaction.
///
/// This is the layer the UI talks to. A screen never writes SQL; it calls a
/// method here that describes a *business event* ("a sale of Rs 1,250 with 18%
/// tax, half paid in cash, on credit for the rest") and returns a receipt or a
/// typed refusal.
///
/// ## `commitChecked`
///
/// Every write goes through [commitChecked], which is the answer to a specific
/// worry: *"if the database is the only source of truth and there is no server
/// to reconcile against, what stops one bad write from silently corrupting the
/// books?"*
///
/// Three layers already guard the write path, at increasing cost:
///
///   1. **CHECK constraints, STRICT tables, foreign keys** — free. Types cannot
///      lie, money cannot be a float, a line cannot point at another ledger.
///   2. **Triggers** — the balance gate, immutability, period locks, the cache
///      accrual. These run *inside* the write, so a refusal aborts the statement.
///   3. **`commitChecked`** — after the statements, before the commit is made
///      visible, it re-reads the *audited* state and rolls the transaction back
///      if anything critical appeared. This catches the class of bug the first
///      two cannot: an error in the application's own arithmetic, or a cache that
///      drifted one row behind.
///
/// The cost is real (it is a query, not a rubber stamp), so there are two modes:
/// [CommitCheck.quick] verifies only what this transaction touched — a few
/// index lookups — and [CommitCheck.full] runs the whole audited report. The
/// defaults are chosen per operation: posting money uses `quick`, and anything
/// that rewrites history (voiding, opening balances, a restore) uses `full`.
library;

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:meta/meta.dart';

import '../../core/errors/khata_exception.dart';
import '../../core/money/money.dart';
import '../../core/utils/epoch_day.dart';
import '../db/dao/accounts_dao.dart';
import '../db/dao/base_dao.dart';
import '../db/dao/journal_dao.dart';

// Re-exported, not merely imported: `VoidReceipt.mode` is a [VoidMode], and a
// caller that has the receipt needs the enum to read it. One import for the UI.
export '../db/dao/journal_dao.dart'
    show
        DashboardMetrics,
        JournalRow,
        JournalRowLine,
        PostedEntry,
        TrialBalanceRow,
        VoidMode,
        VoidOutcome;
import '../db/database.dart';

/// How much checking to do after a write, before committing.
enum CommitCheck {
  /// Only what this transaction touched: the entry's own balance, the accounts
  /// it moved, and cache-vs-live agreement for exactly those accounts.
  ///
  /// This is the default for money-moving writes because it is proportional to
  /// the size of the change, not to the size of the book — it stays ~1 ms
  /// whether the shop has 100 entries or 100 000.
  quick,

  /// The complete audited sweep (`v_integrity_report`, 15 critical + 6 warning
  /// classes). Used after migrations, after a sync merge, and for the "check my
  /// books" button. On a 20 000-entry book this measured ~275 ms, which is why
  /// it is not the default.
  full,
}

/// What `commitChecked` actually verified, so the app can show it and the tests
/// can assert it.
final class CommitReport {
  const CommitReport({
    required this.mode,
    required this.durationMs,
    required this.accountsChecked,
    required this.findings,
  });

  final CommitCheck mode;
  final int durationMs;
  final int accountsChecked;
  final List<IntegrityFinding> findings;

  bool get isClean => findings.where((f) => f.isCritical).isEmpty;

  @override
  String toString() => 'CommitReport(${mode.name}, ${durationMs}ms, '
      '$accountsChecked accounts, ${findings.length} findings)';
}

/// The result of undoing an entry: which mechanism ran, and what it produced.
@immutable
final class VoidReceipt {
  const VoidReceipt({
    required this.entryId,
    required this.entryNo,
    required this.totalMinor,
    required this.commit,
    required this.mode,
    required this.wasLockedPeriod,
    required this.memo,
    this.mirrorEntryId,
    this.mirrorEntryNo,
    this.reversalDate,
  });

  /// The entry that was undone.
  final String entryId;
  final String entryNo;
  final int totalMinor;
  final CommitReport commit;
  final VoidMode mode;

  /// True when the entry fell inside the locked window — the UI should say
  /// "recorded as a correction in this period" rather than "deleted".
  final bool wasLockedPeriod;

  /// The day the reversing entry was posted to (epoch-day), when [mode] is
  /// [VoidMode.reversed]. It is the first day the ledger accepts postings.
  final int? reversalDate;

  /// The reversing entry, when [mode] is [VoidMode.reversed].
  final String? mirrorEntryId;
  final String? mirrorEntryNo;

  final String memo;

  bool get isVoid => mode == VoidMode.voided;

  @override
  String toString() => 'VoidReceipt(${mode.name}, $entryNo, '
      '$totalMinor minor, mirror: ${mirrorEntryNo ?? '—'}, '
      '${commit.durationMs}ms)';
}

/// A posted business action, returned to the UI so it can show a receipt.
final class OrderReceipt {
  const OrderReceipt({
    required this.entryId,
    required this.entryNo,
    required this.totalMinor,
    required this.commit,
    this.partyId,
    this.memo,
    this.lines = const [],
  });

  final String entryId;
  final String entryNo;
  final int totalMinor;
  final CommitReport commit;
  final String? partyId;
  final String? memo;
  final List<String> lines;

  @override
  String toString() => 'OrderReceipt($entryNo, $totalMinor, ${commit.mode.name})';
}

final class OrderBook {
  OrderBook({required this.db, required this.ledgerId}) : _accounts = AccountsDao(db: db, ledgerId: ledgerId) {
    _journal = JournalDao(db: db, ledgerId: ledgerId);
  }

  final KhataDatabase db;
  final String ledgerId;
  final AccountsDao _accounts;
  late final JournalDao _journal;

  JournalDao get journal => _journal;
  AccountsDao get accounts => _accounts;

  // ───────────────────────────────────────────────────────────────────────────
  //  The gate
  // ───────────────────────────────────────────────────────────────────────────

  /// Runs [work] in one transaction and refuses to commit a book that has
  /// become inconsistent.
  ///
  /// Rolling back on a *newly appeared* critical finding is the whole idea: a
  /// shopkeeper would rather be told "this entry was not saved because it would
  /// have broken the books" than find out a month later that the trial balance
  /// stopped adding up. The findings are read back **inside** the transaction
  /// (same connection, so it sees uncommitted rows) and the refusal throws, which
  /// makes drift roll back.
  Future<(T, CommitReport)> commitChecked<T>(
    Future<T> Function() work, {
    CommitCheck check = CommitCheck.quick,
    Set<String> touchedAccountIds = const {},
  }) async {
    final started = DateTime.now();
    return inTransaction(() async {
      final result = await work();

      final findings = check == CommitCheck.full
          ? await db.integrityReport()
          : await _quickFindings(touchedAccountIds);

      final report = CommitReport(
        mode: check,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        accountsChecked: touchedAccountIds.length,
        findings: findings,
      );

      final critical = findings.where((f) => f.isCritical).toList();
      if (critical.isNotEmpty) {
        throw InvariantViolation(
          invariantCode: 'GATE-2',
          message: 'the write was rolled back because it would have left the books '
              'inconsistent: ${critical.first.detail} '
              '(${critical.length} critical finding${critical.length == 1 ? '' : 's'})',
        );
      }
      return (result, report);
    });
  }

  Future<T> inTransaction<T>(Future<T> Function() work) => db.transaction(() => work());

  /// The cheap half of the audit: the checks a single posting could plausibly
  /// break, evaluated only where the posting went.
  ///
  ///   · the entry balances, has both sides, and has at least two lines;
  ///   · for each account the entry touched, the audited cache still equals the
  ///     live sum of its lines (`v_account_balances` vs `v_account_balances_live`).
  ///
  /// Everything else in the audited report (cross-ledger references, audit-chain
  /// integrity, orphaned allocations, stock) cannot be affected by one balanced
  /// entry, and is covered by [CommitCheck.full] and the boot-time sweep.
  Future<List<IntegrityFinding>> _quickFindings(Set<String> accountIds) async {
    final findings = <IntegrityFinding>[];

    final unbalanced = await db.customSelect(
      "SELECT count(*) AS n FROM v_integrity_report WHERE severity = 1 "
      "AND kind IN ('UNBALANCED_ENTRY','PARENT_POSTING','CROSS_LEDGER_LINE')",
    ).get();
    final count = unbalanced.first.read<int>('n');
    if (count > 0) {
      findings.add(IntegrityFinding(
        severity: 1,
        kind: 'UNBALANCED_ENTRY',
        detail: '$count critical finding(s) of a kind this transaction could have caused',
      ));
    }

    if (accountIds.isNotEmpty) {
      final placeholders = List.filled(accountIds.length, '?').join(', ');
      final drift = await db.customSelect(
        'SELECT c.account_id, c.net_minor AS cached, l.net_minor AS live '
        'FROM v_account_balances c '
        'JOIN v_account_balances_live l '
        '  ON l.ledger_id = c.ledger_id AND l.account_id = c.account_id '
        'WHERE c.ledger_id = ? AND c.account_id IN ($placeholders) '
        '  AND c.net_minor <> l.net_minor',
        variables: [Variable<String>(ledgerId), ...[for (final id in accountIds) Variable<String>(id)]],
      ).get();
      for (final row in drift) {
        findings.add(IntegrityFinding(
          severity: 1,
          kind: 'CACHE_DRIFT',
          detail: 'balance cache for account ${row.read<String>('account_id')} reads '
              '${row.read<int>('cached')} while its lines sum to ${row.read<int>('live')}',
          entityId: row.read<String>('account_id'),
        ));
      }
    }

    return findings;
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  Business events
  // ───────────────────────────────────────────────────────────────────────────

  /// A sale. Cash and credit at once, tax included, cost of goods if the items
  /// are stocked.
  ///
  /// The lines it writes, in the schema's signed convention (debit positive):
  ///
  ///   ```text
  ///   Dr  1100 Cash                 amountPaid         (only what was received)
  ///   Dr  1200 · party  (AR)        onCredit           (only if part was unpaid)
  ///   Cr  4100 Sales                netOfTax
  ///   Cr  2300 Tax payable          taxMinor           (only if tax > 0)
  ///   Dr  5100 COGS                 cogsMinor          (only if stocked goods)
  ///   Cr  1300 Inventory            cogsMinor
  ///   ```
  ///
  /// Note what is *not* here: no "discount" fudge line and no rounding plug. If
  /// the caller's numbers do not add up, the entry is refused with the exact
  /// difference — the shopkeeper fixes the invoice, and the books never carry a
  /// mystery cent.
  Future<OrderReceipt> postSale({
    required int entryDate,
    required int grossMinor,
    required int amountPaidMinor,
    int taxMinor = 0,
    int cogsMinor = 0,
    String? partyId,
    String? docNo,
    String? memo,
    String currencyCode = 'PKR',
    CommitCheck check = CommitCheck.quick,
  }) async {
    if (grossMinor <= 0) {
      throw const InvariantViolation(
        invariantCode: 'FIN-1',
        message: 'a sale must be for a positive amount',
      );
    }
    if (amountPaidMinor < 0 || amountPaidMinor > grossMinor) {
      throw const InvariantViolation(
        invariantCode: 'FIN-1',
        message: 'the amount received must be between zero and the invoice total',
      );
    }
    final onCredit = grossMinor - amountPaidMinor;
    if (onCredit > 0 && partyId == null) {
      throw const InvariantViolation(
        invariantCode: 'FIN-2',
        message: 'an unpaid sale needs a customer, or there is nobody to recover '
            'it from',
      );
    }

    final lines = <JournalLineDraft>[];
    final touched = <String>{};

    if (amountPaidMinor > 0) {
      final cash = await _accounts.byRole(AccountRole.cash);
      _require(cash, AccountRole.cash, 'to receive the payment');
      lines.add(JournalLineDraft(
        accountId: cash!.accountId,
        amountMinor: amountPaidMinor,
        memo: 'Received',
      ));
      touched.add(cash.accountId);
    }
    if (onCredit > 0) {
      final arId = await _accounts.partyAccountId(partyId!) ??
          await _accounts.ensurePartySubledger(partyId, controlRole: AccountRole.ar);
      _require(await _accounts.byId(arId), AccountRole.ar, 'to record the unpaid part');
      lines.add(JournalLineDraft(
        accountId: arId,
        amountMinor: onCredit,
        partyId: partyId,
        memo: 'On credit',
      ));
      touched.add(arId);
    }

    // Income is the gross minus the tax that must be handed over; the tax line
    // is informational on the item but authoritative here.
    final netOfTax = grossMinor - taxMinor;
    final sales = await _accounts.byRole(AccountRole.sales);
    _require(sales, AccountRole.sales, 'to record the income');
    lines.add(JournalLineDraft(
      accountId: sales!.accountId,
      amountMinor: -netOfTax,
      memo: memo ?? 'Sale',
    ));
    touched.add(sales.accountId);

    if (taxMinor > 0) {
      final tax = await _accounts.byRole(AccountRole.taxPayable);
      _require(tax, AccountRole.taxPayable, 'to record the tax collected');
      lines.add(JournalLineDraft(
        accountId: tax!.accountId,
        amountMinor: -taxMinor,
        taxMinor: taxMinor,
        taxBaseMinor: netOfTax,
        memo: 'Sales tax collected',
      ));
      touched.add(tax.accountId);
    }

    if (cogsMinor > 0) {
      final cogs = await _accounts.byRole(AccountRole.cogs);
      final inventory = await _accounts.byRole(AccountRole.inventory);
      _require(cogs, AccountRole.cogs, 'to record the cost of what was sold');
      _require(inventory, AccountRole.inventory, 'to relieve the stock of what was sold');
      lines
        ..add(JournalLineDraft(
          accountId: cogs!.accountId,
          amountMinor: cogsMinor,
          memo: 'Cost of goods sold',
        ))
        ..add(JournalLineDraft(
          accountId: inventory!.accountId,
          amountMinor: -cogsMinor,
          memo: 'Stock out',
        ));
      touched
        ..add(cogs.accountId)
        ..add(inventory.accountId);
    }

    final draft = EntryDraft(
      entryDate: entryDate,
      source: LedgerSource.sale,
      lines: lines,
      memo: memo ?? 'Sale',
      docNo: docNo,
      partyId: partyId,
      currencyCode: currencyCode,
    );

    // Balance in Dart first, so the common mistake (a UI that rounded one leg)
    // produces a message naming the amounts rather than the trigger's code.
    if (draft.balanceMinor != 0) {
      throw UnbalancedEntryException(
        debitTotal: draft.totalDebitMinor,
        creditTotal: draft.totalCreditMinor,
        entryId: '(new sale)',
        lineCount: lines.length,
      );
    }

    final (posted, report) = await commitChecked(
      () => _journal.writeAndPost(draft),
      check: check,
      touchedAccountIds: touched,
    );
    return OrderReceipt(
      entryId: posted.entryId,
      entryNo: posted.entryNo,
      totalMinor: grossMinor,
      commit: report,
      partyId: partyId,
      memo: draft.memo,
      lines: [for (final line in lines) _describe(line)],
    );
  }

  /// An expense paid from cash or bank. The simplest double entry there is, and
  /// the one a shopkeeper makes ten times a day.
  Future<OrderReceipt> postExpense({
    required int entryDate,
    required int amountMinor,
    String role = AccountRole.miscExpense,
    bool fromBank = false,
    String? memo,
    String? docNo,
    CommitCheck check = CommitCheck.quick,
  }) async {
    if (amountMinor <= 0) {
      throw const InvariantViolation(
        invariantCode: 'FIN-1',
        message: 'an expense must be for a positive amount',
      );
    }
    final expense = await _accounts.byRole(role);
    _require(expense, role, 'to record this kind of expense');
    final source = await _accounts.byRole(fromBank ? AccountRole.bank : AccountRole.cash);
    _require(source, fromBank ? AccountRole.bank : AccountRole.cash, 'to pay from');

    final draft = EntryDraft(
      entryDate: entryDate,
      source: LedgerSource.expense,
      memo: memo,
      docNo: docNo,
      lines: [
        JournalLineDraft(accountId: expense!.accountId, amountMinor: amountMinor, memo: memo),
        JournalLineDraft(accountId: source!.accountId, amountMinor: -amountMinor),
      ],
    );

    final (posted, report) = await commitChecked(
      () => _journal.writeAndPost(draft),
      check: check,
      touchedAccountIds: {expense.accountId, source.accountId},
    );
    return OrderReceipt(
      entryId: posted.entryId,
      entryNo: posted.entryNo,
      totalMinor: amountMinor,
      commit: report,
      memo: memo,
    );
  }

  /// Money received from a customer against what they owe.
  ///
  /// A payment settles a *balance*, not an invoice — invoice-level allocation
  /// lives in `payment_allocations` and is applied by the documents layer (D3),
  /// because "which bill did this clear?" is a question the user answers, not
  /// one the arithmetic can assume. Until then the money still lands correctly:
  /// cash up, receivable down.
  Future<OrderReceipt> postPaymentIn({
    required int entryDate,
    required int amountMinor,
    required String partyId,
    bool toBank = false,
    String? memo,
    CommitCheck check = CommitCheck.quick,
  }) async {
    if (amountMinor <= 0) {
      throw const InvariantViolation(
        invariantCode: 'FIN-1',
        message: 'a payment must be for a positive amount',
      );
    }
    final destination = await _accounts.byRole(toBank ? AccountRole.bank : AccountRole.cash);
    _require(destination, toBank ? AccountRole.bank : AccountRole.cash, 'to receive into');
    final arId = await _accounts.partyAccountId(partyId) ??
        await _accounts.ensurePartySubledger(partyId, controlRole: AccountRole.ar);

    final draft = EntryDraft(
      entryDate: entryDate,
      source: LedgerSource.paymentIn,
      memo: memo ?? 'Payment received',
      partyId: partyId,
      lines: [
        JournalLineDraft(
          accountId: destination!.accountId,
          amountMinor: amountMinor,
          memo: 'Received',
        ),
        JournalLineDraft(
          accountId: arId,
          amountMinor: -amountMinor,
          partyId: partyId,
          memo: 'Against balance',
        ),
      ],
    );

    final (posted, report) = await commitChecked(
      () => _journal.writeAndPost(draft),
      check: check,
      touchedAccountIds: {destination.accountId, arId},
    );
    return OrderReceipt(
      entryId: posted.entryId,
      entryNo: posted.entryNo,
      totalMinor: amountMinor,
      commit: report,
      partyId: partyId,
      memo: draft.memo,
    );
  }

  /// Writes an opening balance for an account (the shop's cash in the drawer on
  /// the day it started using the app).
  ///
  /// Uses the full sweep: opening balances are the one write where a mistake is
  /// both easy and invisible (it is the base every later number is measured
  /// from), and they happen once per book, so paying ~275 ms is free.
  Future<OrderReceipt> postOpening({
    required int entryDate,
    required List<(String role, int amountMinor)> balances,
    String? memo,
  }) async {
    final lines = <JournalLineDraft>[];
    final touched = <String>{};
    var total = 0;
    for (final (role, amount) in balances) {
      if (amount == 0) continue;
      final account = await _accounts.byRole(role);
      _require(account, role, 'to record its opening balance');
      lines.add(JournalLineDraft(
        accountId: account!.accountId,
        amountMinor: amount,
        memo: 'Opening balance',
        isOpening: true,
      ));
      touched.add(account.accountId);
      total += amount;
    }
    if (lines.length < 2) {
      throw UnbalancedEntryException(
        debitTotal: total,
        creditTotal: 0,
        entryId: '(opening balances)',
        lineCount: lines.length,
      );
    }

    final equity = await _accounts.byRole(AccountRole.openingEquity);
    _require(equity, AccountRole.openingEquity, 'to balance the opening entry');
    // Whatever the assets/liabilities do not account for is the owner's equity
    // at the moment the books open — the plug, in the one place a plug is
    // legitimate, and visible as its own line.
    lines.add(JournalLineDraft(
      accountId: equity!.accountId,
      amountMinor: -total,
      memo: 'Opening equity',
      isOpening: true,
    ));
    touched.add(equity.accountId);

    final draft = EntryDraft(
      entryDate: entryDate,
      source: LedgerSource.opening,
      memo: memo ?? 'Opening balances',
      lines: lines,
    );

    final (posted, report) = await commitChecked(
      () => _journal.writeAndPost(draft),
      check: CommitCheck.full,
      touchedAccountIds: touched,
    );
    return OrderReceipt(
      entryId: posted.entryId,
      entryNo: posted.entryNo,
      totalMinor: total,
      commit: report,
      memo: draft.memo,
    );
  }

  /// Voids a posted entry by writing its reversal. `full` by default: undoing
  /// something is exactly when you want the whole book re-checked.
  /// Undoes a posted entry, choosing the mechanism the books require.
  ///
  /// * Period still open → **void** (`status = 2`): the money leaves every
  ///   report, the row stays for audit.
  /// * Period locked (`ledgers.lock_after_date`) → **reversal**: a negated mirror
  ///   entry dated today, because erasing rupees from a filed period would
  ///   silently change a return that has already been submitted.
  ///
  /// Pass [mode] to override (e.g. a shopkeeper who wants a credit note even
  /// though the period is open). The receipt always says which happened.
  Future<VoidReceipt> voidEntry(
    String entryId, {
    required String reason,
    VoidMode? mode,
  }) async {
    final entry = await _journal.findById(entryId);
    if (entry == null) {
      throw InvariantViolation(
        invariantCode: 'INT-3',
        message: 'no entry $entryId in this book — nothing to undo',
      );
    }
    final lockAfter = await _accounts.scalarInt(
      'SELECT COALESCE(lock_after_date, 0) FROM ledgers WHERE id = ?',
      [ledgerId],
    );
    final isLocked = lockAfter > 0 && entry.entryDate <= lockAfter;
    final chosen = mode ?? (isLocked ? VoidMode.reversed : VoidMode.voided);

    // A reversal must land on an **open** day. `trg_je_locked_period` refuses to
    // post anything dated `<= lock_after_date`, and "closed through today" is a
    // lock whose window includes today — so the first acceptable date is
    // `lock_after_date + 1`, or today when today is already past the window.
    // Dating it *after* the lock is also the honest accounting: the correction
    // belongs to the period you are working in, not to the filed one.
    final today = EpochDay.fromDateTime(DateTime.now());
    final mirrorIsPastLock = !isLocked || today > (lockAfter + 1);

    final (outcome, report) = await commitChecked(
      () => _journal.voidEntry(
        entryId,
        reason: reason,
        reverse: chosen == VoidMode.reversed,
        // A mirror must be dated outside the locked window, or `FIN-1` refuses
        // to post it — the lock is doing its job, we just have to aim at an
        // open period.
        reverseDate: chosen == VoidMode.reversed
            ? (mirrorIsPastLock
                ? DateTime.now()
                : EpochDay.toLocalMidnight(today + 1))
            : null,
      ),
      // A void moves money out of the trial balance, which is exactly the class
      // of write worth re-deriving the whole report for.
      check: CommitCheck.full,
      touchedAccountIds: const {},
    );

    return VoidReceipt(
      entryId: entryId,
      entryNo: entry.entryNo,
      totalMinor: entry.totalDebitMinor,
      commit: report,
      mode: outcome.mode,
      wasLockedPeriod: isLocked,
      reversalDate: chosen == VoidMode.reversed
          ? (mirrorIsPastLock ? today : lockAfter + 1)
          : null,
      mirrorEntryId: outcome.mirrorEntryId,
      mirrorEntryNo: outcome.mirrorEntryNo,
      memo: '${outcome.isVoid ? 'Voided' : 'Reversed'}: $reason',
    );
  }

  /// Posts a correcting mirror of [entryId] dated [date] (today by default).
  ///
  /// Kept separate from [voidEntry] because a credit note is not an undo: the
  /// shopkeeper wants the original invoice to stand and a return to be visible
  /// against it.
  Future<OrderReceipt> reverseEntry(
    String entryId, {
    required String reason,
    DateTime? date,
  }) async {
    final (outcome, report) = await commitChecked(
      () => _journal.voidEntry(
        entryId,
        reason: reason,
        reverse: true,
        reverseDate: date ?? DateTime.now(),
      ),
      check: CommitCheck.full,
      touchedAccountIds: const {},
    );
    final mirror = await _journal.findById(outcome.mirrorEntryId!);
    return OrderReceipt(
      entryId: outcome.mirrorEntryId!,
      entryNo: outcome.mirrorEntryNo ?? mirror?.entryNo ?? '(reversal)',
      totalMinor: mirror?.totalDebitMinor ?? 0,
      commit: report,
      memo: 'Reversal of ${outcome.entryId}: $reason',
    );
  }

  /// The "check my books" action, and what runs after a sync merge.
  Future<CommitReport> audit({CommitCheck check = CommitCheck.full}) async {
    final started = DateTime.now();
    final findings = await db.integrityReport();
    return CommitReport(
      mode: check,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      accountsChecked: 0,
      findings: findings,
    );
  }

  /// Rewrites the audited balance cache from the journal lines.
  ///
  /// Only legitimate after a dirty open, a restore, or a sync merge — the cache
  /// is otherwise maintained by trigger. `GATE-2` re-verifies it immediately
  /// afterwards, so a rebuild that goes wrong is caught rather than trusted.
  Future<CommitReport> rebuildCaches() async {
    final started = DateTime.now();
    await db.customStatement('BEGIN IMMEDIATE');
    try {
      await db.customStatement(
          await db.assetLoader.load('assets/sql/ops/rebuild_caches.sql'));
      await db.customStatement('COMMIT');
    } on Object {
      await db.customStatement('ROLLBACK');
      rethrow;
    }
    final findings = await db.integrityReport();
    return CommitReport(
      mode: CommitCheck.full,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      accountsChecked: 0,
      findings: findings,
    );
  }

  void _require(AccountBalance? account, String role, String why) {
    if (account == null || !account.isPostable) {
      throw InvariantViolation(
        invariantCode: 'INT-4',
        message: 'this book has no postable account for "$role", so it cannot '
            '$why. Restore the default chart of accounts in Settings.',
      );
    }
  }

  String _describe(JournalLineDraft line) =>
      '${line.isDebit ? 'Dr' : 'Cr'} ${MoneyMinor.fromMinor(line.amountMinor.abs(), 2).format()}'
      '${line.memo == null ? '' : ' · ${line.memo}'}';
}

/// Convenience: read one row as a map (used by diagnostics and the sync layer).
Map<String, Object?> rowToMap(QueryRow row) => row.data;
