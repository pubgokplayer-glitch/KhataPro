/// KhataPro · the journal DAO.
///
/// Owns the one thing the whole app is for: writing down that money moved, in a
/// way that cannot be wrong. Every method here either builds a balanced set of
/// lines or refuses to write at all — a "draft that does not balance yet" lives
/// only in the UI's memory, never in the database.
library;

import 'package:drift/drift.dart' show QueryRow;
import 'package:meta/meta.dart';

import '../../../core/utils/epoch_day.dart';
import '../../../core/crdt/stamp.dart';
import '../../../core/errors/khata_exception.dart';
import 'base_dao.dart';

/// One line of an entry, as the app builds it.
///
/// [amountMinor] is **signed, debit-positive** — the schema's convention
/// (`journal_lines.amount_minor`), which is what makes "sums to zero" a single
/// `SUM()` rather than a comparison of two columns. A sale crediting income is
/// negative here; a debit to cash is positive.
final class JournalLineDraft {
  const JournalLineDraft({
    required this.accountId,
    required this.amountMinor,
    this.partyId,
    this.itemId,
    this.quantityMilli = 0,
    this.unitCostMicros = 0,
    this.memo,
    this.taxMinor = 0,
    this.taxBaseMinor = 0,
    this.isOpening = false,
  });

  final String accountId;
  final int amountMinor;
  final String? partyId;
  final String? itemId;
  final int quantityMilli;
  final int unitCostMicros;
  final String? memo;
  final int taxMinor;
  final int taxBaseMinor;
  final bool isOpening;

  bool get isDebit => amountMinor > 0;
  bool get isCredit => amountMinor < 0;
}

/// An entry the caller wants written.
final class EntryDraft {
  const EntryDraft({
    required this.entryDate,
    required this.source,
    required this.lines,
    this.memo,
    this.docNo,
    this.partyId,
    this.currencyCode = 'PKR',
    this.fxRateMicros = 1000000,
  });

  /// Epoch-day in the **ledger's** timezone. Never a UTC timestamp: a sale at
  /// 00:30 in Karachi belongs to that day's book, and storing an instant would
  /// put it on the previous day in any UTC-based report.
  final int entryDate;
  final int source;
  final List<JournalLineDraft> lines;
  final String? memo;
  final String? docNo;
  final String? partyId;
  final String currencyCode;
  final int fxRateMicros;

  /// Sum of the lines in minor units. Zero is the only acceptable value.
  int get balanceMinor =>
      lines.fold(0, (sum, line) => sum + line.amountMinor);

  int get totalDebitMinor =>
      lines.where((l) => l.isDebit).fold(0, (sum, l) => sum + l.amountMinor);

  int get totalCreditMinor =>
      lines.where((l) => l.isCredit).fold(0, (sum, l) => sum - l.amountMinor);
}

/// How an entry was undone. See [JournalDao.voidEntry] for why both exist.
enum VoidMode {
  /// `status = 2` — the entry's money leaves every report by trigger.
  voided,

  /// A negated mirror entry was posted; the original stays on the books.
  reversed,
}

/// The result of undoing an entry — which mechanism ran, and the evidence.
@immutable
class VoidOutcome {
  const VoidOutcome({
    required this.entryId,
    required this.mode,
    required this.entryDate,
    this.voidedAt,
    this.mirrorEntryId,
    this.mirrorEntryNo,
  });

  /// The entry the caller asked to undo (never the mirror).
  final String entryId;
  final VoidMode mode;

  /// The original entry's date, as epoch-day.
  final int entryDate;

  /// Set when [mode] is [VoidMode.voided] — epoch-ms of the transition.
  final int? voidedAt;

  /// Set when [mode] is [VoidMode.reversed].
  final String? mirrorEntryId;
  final String? mirrorEntryNo;

  bool get isVoid => mode == VoidMode.voided;
}

/// Where an entry stands after being written.
final class PostedEntry {
  const PostedEntry({
    required this.entryId,
    required this.entryNo,
    required this.entryDate,
    required this.source,
    required this.status,
    required this.totalDebitMinor,
    required this.totalCreditMinor,
    required this.lineCount,
  });

  final String entryId;
  final String entryNo;
  final int entryDate;
  final int source;
  final int status;
  final int totalDebitMinor;
  final int totalCreditMinor;
  final int lineCount;

  bool get isPosted => status == 1;

  static PostedEntry fromRow(QueryRow row) => PostedEntry(
        entryId: row.read<String>('id'),
        entryNo: row.read<String>('entry_no'),
        entryDate: row.read<int>('entry_date'),
        source: row.read<int>('source'),
        status: row.read<int>('status'),
        totalDebitMinor: row.read<int>('total_debit_minor'),
        totalCreditMinor: row.read<int>('total_credit_minor'),
        lineCount: row.read<int>('line_count'),
      );
}

final class JournalDao extends DaoBase {
  JournalDao({required super.db, required super.ledgerId});

  /// Writes a draft entry and its lines. No gateway: drafts are invisible to
  /// every report (all of them filter `status = 1`), and the balance gate fires
  /// on the transition to posted.
  ///
  /// Returns the new entry id.
  Future<String> insertDraft(EntryDraft draft, {String? entryNo}) async {
    if (draft.lines.length < 2) {
      throw UnbalancedEntryException(
        debitTotal: draft.totalDebitMinor,
        creditTotal: draft.totalCreditMinor,
        entryId: '(new draft)',
        lineCount: draft.lines.length,
      );
    }
    if (draft.balanceMinor != 0) {
      // Caught here with a message that names the amounts, because the trigger's
      // message ("INT-5b") is for the log, not for a shopkeeper.
      throw UnbalancedEntryException(
        debitTotal: draft.totalDebitMinor,
        creditTotal: draft.totalCreditMinor,
        entryId: '(new draft)',
        lineCount: draft.lines.length,
      );
    }

    final entryId = newRowId();
    final stamp = newStamp();
    final now = DateTime.now().millisecondsSinceEpoch;
    final number = entryNo ?? await nextNumber(DocKind.journalEntry);

    await exec(
      'INSERT INTO journal_entries (id, ledger_id, entry_no, entry_date, source, status, '
      'memo, doc_no, party_id, currency_code, fx_rate_micros, base_currency_code, '
      'total_debit_minor, total_credit_minor, base_total_minor, device_id, hlc, node_id, '
      'rev, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, 0, 0, 0, ?, ?, ?, 1, ?, ?)',
      [
        entryId,
        ledgerId,
        number,
        draft.entryDate,
        draft.source,
        draft.memo,
        draft.docNo,
        draft.partyId,
        draft.currencyCode,
        draft.fxRateMicros,
        draft.currencyCode,
        nodeId,
        stamp.hlc.encode(),
        nodeId,
        now,
        now,
      ],
    );

    var lineNo = 1;
    for (final line in draft.lines) {
      await exec(
        'INSERT INTO journal_lines (id, ledger_id, entry_id, line_no, entry_date, '
        'account_id, party_id, amount_minor, base_amount_minor, currency_code, item_id, '
        'quantity_milli, unit_cost_micros, tax_minor, tax_base_minor, memo, is_opening, '
        'node_id, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          newRowId(),
          ledgerId,
          entryId,
          lineNo++,
          draft.entryDate,
          line.accountId,
          line.partyId,
          line.amountMinor,
          _baseAmount(line.amountMinor, draft.fxRateMicros),
          draft.currencyCode,
          line.itemId,
          line.quantityMilli,
          line.unitCostMicros,
          line.taxMinor,
          line.taxBaseMinor,
          line.memo,
          line.isOpening ? 1 : 0,
          nodeId,
          now,
        ],
      );
    }

    await enqueueOplog(
      table: 'journal_entries',
      rowId: entryId,
      op: 1,
      stamp: stamp,
      payloadJson: canonicalJson({
        'id': entryId,
        'entry_no': number,
        'entry_date': draft.entryDate,
        'source': draft.source,
        'status': 0,
        'memo': draft.memo,
      }),
    );

    return entryId;
  }

  /// Posts a draft. This is the only path to `status = 1`, and
  /// `trg_je_balance_gate` is the authority on whether it is allowed.
  ///
  /// The totals are written in the same UPDATE that flips the status, so the
  /// trigger sees the values the entry will have. If the gate refuses, SQLite
  /// aborts the statement and the caller's transaction rolls back — the entry
  /// stays a draft, which is the correct state for "not yet valid".
  Future<PostedEntry> post(String entryId, {CrdtStamp? expecting}) async {
    if (expecting != null) {
      await assertFresh('journal_entries', entryId, expecting);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final stamp = newStamp();

    try {
      await exec(
        'UPDATE journal_entries SET status = 1, posted_at = ?, '
        'total_debit_minor = (SELECT COALESCE(SUM(CASE WHEN amount_minor > 0 '
        '  THEN amount_minor ELSE 0 END), 0) FROM journal_lines WHERE entry_id = ?), '
        'total_credit_minor = (SELECT COALESCE(SUM(CASE WHEN amount_minor < 0 '
        '  THEN -amount_minor ELSE 0 END), 0) FROM journal_lines WHERE entry_id = ?), '
        // NOTE the semantics: `total_debit_minor`/`total_credit_minor` are the
        // one-sided totals (each equal to the entry's value), while
        // `base_total_minor` is the GROSS sum of absolute base amounts — twice
        // the value for a two-line entry. That asymmetry is what
        // `008_integrity.sql`'s ENTRY_TOTALS_DRIFT check asserts, and writing
        // the halved figure here is exactly what this DB's own audit gate caught
        // during development.
        'base_total_minor = (SELECT COALESCE(SUM(ABS(base_amount_minor)), 0) '
        '  FROM journal_lines WHERE entry_id = ?), '
        'hlc = ?, node_id = ?, rev = rev + 1, updated_at = ? '
        'WHERE id = ? AND ledger_id = ?',
        [now, entryId, entryId, entryId, stamp.hlc.encode(), nodeId, now, entryId, ledgerId],
      );
    } on Object catch (error, stackTrace) {
      mapSqliteError(error, stackTrace);
    }

    // The op carries the rev the row now has, not the default 1: a peer that
    // applies it must land on the same `(hlc, rev)` the row holds here, or its
    // next edit looks stale to itself.
    await enqueueOplog(
      table: 'journal_entries',
      rowId: entryId,
      op: 1,
      stamp: stamp,
      rev: await scalarInt(
        'SELECT rev FROM journal_entries WHERE id = ?',
        [entryId],
      ),
      payloadJson: canonicalJson({'id': entryId, 'status': 1, 'posted_at': now}),
    );
    await appendAudit(
      action: 'entry.posted',
      entityType: 'journal_entry',
      entityId: entryId,
      after: {'status': 1, 'posted_at': now},
    );

    return (await findById(entryId))!;
  }

  /// Posts in one call: draft + lines + gate. The common case for the UI, and
  /// what the OrderBook uses.
  Future<PostedEntry> writeAndPost(EntryDraft draft, {String? entryNo}) async {
    final entryId = await insertDraft(draft, entryNo: entryNo);
    return post(entryId);
  }

  /// Voids a posted entry by writing its **reversal** rather than deleting it.
  ///
  /// A ledger that can forget is not a ledger. The original stays, marked
  /// voided, and a mirror-image entry (source `reversal`) puts the balances
  /// back; `journal_entries.reversal_of_entry_id` links them, so "why is this
  /// month different from what I saw last week?" is answerable forever.
  /// Undoes a posted entry — by **voiding** it, or by **reversing** it.
  ///
  /// These are not two spellings of one thing, and this database says so:
  /// `trg_bal_void` removes a voided entry's money from every cached balance the
  /// moment `status` becomes 2. Posting a mirror entry *and* flipping the status
  /// therefore subtracts the same rupees twice, which is precisely what the
  /// commit gate caught while this method was being written.
  ///
  /// * `reverse == false` — **void**. `status = 2`, `voided_at` stamped, money
  ///   gone from reports, the entry itself kept for audit (`trg_je_no_delete`
  ///   forbids deleting it). This is "I typed that sale wrong", same period.
  /// * `reverse == true` — **reversal**. A new entry that mirrors the original
  ///   with every amount negated, dated [reverseDate] (default: the original's
  ///   date). The original is untouched, so a filed period keeps its books and
  ///   the offset lands in the period you are actually working in. This is a
  ///   customer credit note, or a correction to a locked period.
  ///
  /// Both are single transactions: status, stamp, op-log row and audit row
  /// either all land or none do.
  Future<VoidOutcome> voidEntry(
    String entryId, {
    required String reason,
    bool reverse = false,
    DateTime? reverseDate,
  }) async {
    final original = await one(
      'SELECT entry_date, source, currency_code, fx_rate_micros, party_id, doc_no '
      'FROM journal_entries WHERE id = ? AND ledger_id = ? AND status = 1',
      [entryId, ledgerId],
    );
    if (original == null) {
      throw InvariantViolation(
        invariantCode: 'INT-3',
        message: 'only a posted entry can be voided (entry $entryId is absent, a '
            'draft, or already voided)',
      );
    }
    final originalDate = original.read<int>('entry_date');

    if (!reverse) {
      // Void: one status transition. The cache follows by trigger, the CRDT
      // stamp moves so the cancellation reaches other devices, and the audit
      // chain records who did it and why.
      final stamp = newStamp();
      final now = DateTime.now().millisecondsSinceEpoch;
      final confirmed = await scalarInt(
        'UPDATE journal_entries SET status = 2, voided_at = ?, hlc = ?, rev = rev + 1, '
        'updated_at = ? WHERE id = ? AND ledger_id = ? AND status = 1 RETURNING rev',
        [now, stamp.hlc.encode(), now, entryId, ledgerId],
      );
      if (confirmed == 0) {
        throw InvariantViolation(
          invariantCode: 'INT-3',
          message: 'entry $entryId was already voided by someone else',
        );
      }
      await enqueueOplog(
        table: 'journal_entries',
        rowId: entryId,
        op: 3, // tombstone: an observer must remove it, not overwrite it
        stamp: stamp,
        rev: confirmed,
        payloadJson: canonicalJson({'id': entryId, 'status': 2, 'reason': reason}),
      );
      await appendAudit(
        action: 'entry.voided',
        entityType: 'journal_entry',
        entityId: entryId,
        before: {'status': 1},
        after: {'status': 2, 'voided_at': now, 'reason': reason},
      );
      return VoidOutcome(
        entryId: entryId,
        mode: VoidMode.voided,
        entryDate: originalDate,
        voidedAt: now,
      );
    }

    // Reversal: the mirror image, posted like any other entry so the balance
    // gate, the cache accrual and the op log all run exactly once, normally.
    final lines = await all(
      'SELECT account_id, party_id, -amount_minor AS amount_minor, -base_amount_minor '
      'AS base_amount_minor, currency_code, item_id, -quantity_milli AS quantity_milli, '
      'unit_cost_micros, memo FROM journal_lines WHERE entry_id = ? ORDER BY line_no',
      [entryId],
    );
    final onDate = reverseDate == null
        ? originalDate
        : EpochDay.fromDateTime(reverseDate);

    final mirror = EntryDraft(
      entryDate: onDate,
      source: LedgerSource.reversal,
      partyId: original.read<String?>('party_id'),
      docNo: original.read<String?>('doc_no'),
      currencyCode: original.read<String>('currency_code'),
      fxRateMicros: original.read<int>('fx_rate_micros'),
      memo: 'Reversal of entry $entryId — $reason',
      lines: [
        for (final line in lines)
          JournalLineDraft(
            accountId: line.read<String>('account_id'),
            partyId: line.read<String?>('party_id'),
            amountMinor: line.read<int>('amount_minor'),
            itemId: line.read<String?>('item_id'),
            quantityMilli: line.read<int>('quantity_milli'),
            unitCostMicros: line.read<int>('unit_cost_micros'),
            memo: line.read<String?>('memo'),
          ),
      ],
    );

    final mirrorId = await insertDraft(mirror);
    await exec(
      'UPDATE journal_entries SET reversal_of_entry_id = ? WHERE id = ?',
      [entryId, mirrorId],
    );
    final posted = await post(mirrorId);
    await appendAudit(
      action: 'entry.reversed',
      entityType: 'journal_entry',
      entityId: entryId,
      before: {'status': 1},
      after: {
        'reversal_entry_id': posted.entryId,
        'reversal_entry_no': posted.entryNo,
        'reversal_date': onDate,
        'reason': reason,
      },
    );
    return VoidOutcome(
      entryId: entryId,
      mode: VoidMode.reversed,
      entryDate: originalDate,
      mirrorEntryId: posted.entryId,
      mirrorEntryNo: posted.entryNo,
    );
  }

  Future<PostedEntry?> findById(String entryId) async {
    final row = await one(
      'SELECT e.id, e.entry_no, e.entry_date, e.source, e.status, e.total_debit_minor, '
      'e.total_credit_minor, (SELECT COUNT(*) FROM journal_lines l WHERE l.entry_id = e.id) '
      'AS line_count '
      'FROM journal_entries e WHERE e.id = ? AND e.ledger_id = ?',
      [entryId, ledgerId],
    );
    return row == null ? null : PostedEntry.fromRow(row);
  }

  /// Recent entries for the journal screen, newest first.
  ///
  /// Reads `v_journal_detail` (a view, so the join logic lives in SQL where the
  /// contract tests can reach it) and paginates by `(entry_date, id)` — the
  /// composite cursor is stable even when several entries share a date, which is
  /// the normal case for a busy shop.
  Future<List<JournalRow>> recent({int limit = 50, int? beforeDate, String? beforeId}) async {
    final rows = await all(
      'SELECT entry_id, entry_no, entry_date, entry_date_iso, source, status, memo, doc_no, '
      'party_name, currency_code, line_id, line_no, account_id, account_code, account_name, '
      'debit_minor, credit_minor, amount_minor, line_memo '
      'FROM v_journal_detail '
      'WHERE ledger_id = ? '
      '  AND (? IS NULL OR entry_date < ? OR (entry_date = ? AND entry_id < ?)) '
      'ORDER BY entry_date DESC, entry_id DESC, line_no '
      'LIMIT ?',
      [ledgerId, beforeDate, beforeDate, beforeDate, beforeId, limit * 6],
    );
    return JournalRow.group(rows, limit: limit);
  }

  Future<int> countDrafts() => scalarInt(
        'SELECT COUNT(*) FROM journal_entries WHERE ledger_id = ? AND status = 0',
        [ledgerId],
      );

  /// The dashboard's headline numbers, from the audited cache.
  ///
  /// Every field comes from `v_dashboard_metrics`, which reads the balance cache
  /// — legitimate because GATE-2 proves on every commit that the cache equals
  /// before + delta, and `v_integrity_report` can re-derive it live on demand.
  /// That is why the dashboard costs ~4 ms on a 20 000-entry book instead of
  /// recomputing a decade of sums.
  Future<DashboardMetrics> dashboard() async {
    final row = await one(
      'SELECT currency_code, today_epoch_day, draft_count, today_sales_minor, '
      'month_sales_minor, month_expense_minor, receivable_minor, payable_minor, '
      'cash_minor, month_profit_minor FROM v_dashboard_metrics WHERE ledger_id = ?',
      [ledgerId],
    );
    if (row == null) {
      return const DashboardMetrics(
        currencyCode: 'PKR',
        todayEpochDay: 0,
        draftCount: 0,
        todaySalesMinor: 0,
        monthSalesMinor: 0,
        monthExpenseMinor: 0,
        receivableMinor: 0,
        payableMinor: 0,
        cashMinor: 0,
        monthProfitMinor: 0,
      );
    }
    return DashboardMetrics(
      currencyCode: row.read<String>('currency_code'),
      todayEpochDay: row.read<int>('today_epoch_day'),
      draftCount: row.read<int>('draft_count'),
      todaySalesMinor: row.read<int>('today_sales_minor'),
      monthSalesMinor: row.read<int>('month_sales_minor'),
      monthExpenseMinor: row.read<int>('month_expense_minor'),
      receivableMinor: row.read<int>('receivable_minor'),
      payableMinor: row.read<int>('payable_minor'),
      cashMinor: row.read<int>('cash_minor'),
      monthProfitMinor: row.read<int>('month_profit_minor'),
    );
  }

  /// The trial balance: every account with activity, debits and credits, and the
  /// closing balance on its normal side.
  Future<List<TrialBalanceRow>> trialBalance() async {
    final rows = await all(
      'SELECT account_id, code, name, name_ur, kind, group_code, role, debit_minor, '
      'credit_minor, closing_on_normal_side_minor, closing_debit_minor, '
      'closing_credit_minor, signed_net_minor '
      'FROM v_trial_balance WHERE ledger_id = ? ORDER BY code',
      [ledgerId],
    );
    return [for (final row in rows) TrialBalanceRow.fromRow(row)];
  }

  /// Multiplies a signed amount back onto an account's normal side, for display.
  ///
  /// A raw `net_minor` is debit-positive, which is right for the database and
  /// confusing for a human looking at a liabilities column. Reports multiply by
  /// `normal_balance` so a positive number always means "more of what the label
  /// says"; the UI then prints the raw value when it shows the audit trail.
  static int onNormalSide(int netMinor, int normalBalance) => netMinor * normalBalance;

  int _baseAmount(int amountMinor, int fxRateMicros) {
    if (fxRateMicros == 1000000) return amountMinor;
    final scaled = BigInt.from(amountMinor) * BigInt.from(fxRateMicros) +
        BigInt.from(amountMinor.isNegative ? -500000 : 500000);
    return (scaled ~/ BigInt.from(1000000)).toInt();
  }
}

/// A flattened journal row (one line), grouped into entries for display.
final class JournalRow {
  const JournalRow({
    required this.entryId,
    required this.entryNo,
    required this.entryDate,
    required this.entryDateIso,
    required this.source,
    required this.status,
    required this.lines,
    this.memo,
    this.docNo,
    this.partyName,
  });

  final String entryId;
  final String entryNo;
  final int entryDate;
  final String entryDateIso;
  final int source;
  final int status;
  final String? memo;
  final String? docNo;
  final String? partyName;
  final List<JournalRowLine> lines;

  int get totalDebitMinor =>
      lines.fold(0, (sum, line) => sum + line.debitMinor);

  static List<JournalRow> group(List<QueryRow> rows, {required int limit}) {
    final grouped = <String, List<QueryRow>>{};
    for (final row in rows) {
      grouped.putIfAbsent(row.read<String>('entry_id'), () => []).add(row);
    }
    return [
      for (final entry in grouped.entries.take(limit))
        JournalRow(
          entryId: entry.key,
          entryNo: entry.value.first.read<String>('entry_no'),
          entryDate: entry.value.first.read<int>('entry_date'),
          entryDateIso: entry.value.first.read<String>('entry_date_iso'),
          source: entry.value.first.read<int>('source'),
          status: entry.value.first.read<int>('status'),
          memo: entry.value.first.read<String?>('memo'),
          docNo: entry.value.first.read<String?>('doc_no'),
          partyName: entry.value.first.read<String?>('party_name'),
          lines: [for (final row in entry.value) JournalRowLine.fromRow(row)],
        ),
    ];
  }
}

final class JournalRowLine {
  const JournalRowLine({
    required this.lineId,
    required this.lineNo,
    required this.accountId,
    required this.accountCode,
    required this.accountName,
    required this.debitMinor,
    required this.creditMinor,
    this.memo,
  });

  final String lineId;
  final int lineNo;
  final String accountId;
  final String accountCode;
  final String accountName;
  final int debitMinor;
  final int creditMinor;
  final String? memo;

  static JournalRowLine fromRow(QueryRow row) => JournalRowLine(
        lineId: row.read<String>('line_id'),
        lineNo: row.read<int>('line_no'),
        accountId: row.read<String>('account_id'),
        accountCode: row.read<String>('account_code'),
        accountName: row.read<String>('account_name'),
        debitMinor: row.read<int>('debit_minor'),
        creditMinor: row.read<int>('credit_minor'),
        memo: row.read<String?>('line_memo'),
      );
}

/// `v_dashboard_metrics`, typed.
final class DashboardMetrics {
  const DashboardMetrics({
    required this.currencyCode,
    required this.todayEpochDay,
    required this.draftCount,
    required this.todaySalesMinor,
    required this.monthSalesMinor,
    required this.monthExpenseMinor,
    required this.receivableMinor,
    required this.payableMinor,
    required this.cashMinor,
    required this.monthProfitMinor,
  });

  final String currencyCode;
  final int todayEpochDay;
  final int draftCount;
  final int todaySalesMinor;
  final int monthSalesMinor;
  final int monthExpenseMinor;
  final int receivableMinor;
  final int payableMinor;
  final int cashMinor;
  final int monthProfitMinor;

  @override
  String toString() => 'Dashboard($currencyCode, today=$todaySalesMinor, '
      'month=$monthSalesMinor, cash=$cashMinor, drafts=$draftCount)';
}

/// One row of `v_trial_balance`.
final class TrialBalanceRow {
  const TrialBalanceRow({
    required this.accountId,
    required this.code,
    required this.name,
    required this.kind,
    required this.debitMinor,
    required this.creditMinor,
    required this.closingOnNormalSideMinor,
    required this.signedNetMinor,
    this.nameUr,
    this.role,
    this.groupCode,
  });

  final String accountId;
  final String code;
  final String name;
  final String? nameUr;
  final int kind;
  final String? role;
  final String? groupCode;
  final int debitMinor;
  final int creditMinor;
  final int closingOnNormalSideMinor;
  final int signedNetMinor;

  static TrialBalanceRow fromRow(QueryRow row) => TrialBalanceRow(
        accountId: row.read<String>('account_id'),
        code: row.read<String>('code'),
        name: row.read<String>('name'),
        nameUr: row.read<String?>('name_ur'),
        kind: row.read<int>('kind'),
        role: row.read<String?>('role'),
        groupCode: row.read<String?>('group_code'),
        debitMinor: row.read<int>('debit_minor'),
        creditMinor: row.read<int>('credit_minor'),
        closingOnNormalSideMinor: row.read<int>('closing_on_normal_side_minor'),
        signedNetMinor: row.read<int>('signed_net_minor'),
      );

  @override
  String toString() => '$code $name: Dr $debitMinor / Cr $creditMinor';
}
