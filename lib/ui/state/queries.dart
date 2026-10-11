/// KhataPro · the row types the screens render, and the SQL that produces them.
///
/// Two rules hold this file together:
///
///  1. **Every read the UI performs is here**, so "what does this screen show?" has one
///     answer that can be read in one place, tested against a real database, and
///     explained to whoever asks why the dashboard is 4 ms.
///  2. **Rows are parsed defensively.** `QueryRow` values arrive as `int`, `double`,
///     `String` or null depending on the SQLite column's storage class, and a cast that
///     is right in a test can be wrong on a device with one weird row. Every numeric read
///     goes through [_int] / [_bool], which tolerate all three, and a NULL in a column
///     that is logically non-null becomes `0` rather than a crash on the dashboard.
///
/// The queries are deliberately shaped for the indexes the schema already declares — see
/// `docs/DB_SCHEMA.md`; `account_balances` and the `v_*` views exist precisely so the
/// dashboard does not scan `journal_lines` (measured at 4.25 ms for 20 000 entries in
/// `tool/benchmark.py`, which is the number this file is written to preserve).
library;

import 'dart:async';

import 'package:drift/drift.dart' show QueryRow, Variable;

import '../../core/utils/epoch_day.dart';
import '../../data/db/database.dart';

/// Tolerant integer read. SQLite hands back `int`, but a view that computes
/// `CAST(... AS INTEGER)` can still be `double` after a division, and a LEFT JOIN can
/// produce null.
int _int(QueryRow row, String key) {
  final value = row.data[key];
  if (value == null) return 0;
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

int? _intOrNull(QueryRow row, String key) {
  final value = row.data[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

String _text(QueryRow row, String key, [String fallback = '']) {
  final value = row.data[key];
  return value is String ? value : (value == null ? fallback : '$value');
}

String? _textOrNull(QueryRow row, String key) {
  final value = row.data[key];
  return value is String ? value : null;
}

bool _bool(QueryRow row, String key) => _int(row, key) != 0;

// ── rows ─────────────────────────────────────────────────────────────────────

/// The dashboard's numbers, straight from `v_dashboard_metrics`.
///
/// One query, one row, no N+1: the view computes sales, expenses, profit, receivables,
/// payables and cash in a single pass over the balance cache plus two indexed sums.
final class Dashboard {
  const Dashboard({
    required this.currencyCode,
    required this.todayEpochDay,
    required this.draftCount,
    required this.todaySalesMinor,
    required this.monthSalesMinor,
    required this.monthExpenseMinor,
    required this.monthProfitMinor,
    required this.receivableMinor,
    required this.payableMinor,
    required this.cashMinor,
    required this.monthCollectionsMinor,
    required this.topDebtors,
    required this.todayMovements,
  });

  final String currencyCode;
  final int todayEpochDay;
  final int draftCount;
  final int todaySalesMinor;
  final int monthSalesMinor;
  final int monthExpenseMinor;

  /// Gross profit this month, from the ledger rather than from documents: `kind = 4`
  /// (income) minus the cost of what was sold.
  final int monthProfitMinor;

  final int receivableMinor;
  final int payableMinor;
  final int cashMinor;

  /// Money collected this month against credit sales. The collection rate is
  /// `collections / monthSales`, and it is the single most useful number a shopkeeper
  /// can look at: selling on credit is easy, collecting is the business.
  final int monthCollectionsMinor;

  /// The three parties who owe the most, for the "who to chase today" card.
  final List<PartyBalance> topDebtors;

  /// Today's cash movements, for the sparkline in the header.
  final List<DayFlowPoint> todayMovements;

  double get collectionRate =>
      monthSalesMinor == 0 ? 0 : (monthCollectionsMinor / monthSalesMinor).clamp(0, 9.99);

  static Dashboard fromRow(QueryRow row) => Dashboard(
        currencyCode: _text(row, 'currency_code', 'PKR'),
        todayEpochDay: _int(row, 'today_epoch_day'),
        draftCount: _int(row, 'draft_count'),
        todaySalesMinor: _int(row, 'today_sales_minor'),
        monthSalesMinor: _int(row, 'month_sales_minor'),
        monthExpenseMinor: _int(row, 'month_expense_minor'),
        monthProfitMinor: _int(row, 'month_profit_minor'),
        receivableMinor: _int(row, 'receivable_minor'),
        payableMinor: _int(row, 'payable_minor'),
        cashMinor: _int(row, 'cash_minor'),
        monthCollectionsMinor: _int(row, 'month_collections_minor'),
        topDebtors: const [],
        todayMovements: const [],
      );

  Dashboard withLists({
    required List<PartyBalance> topDebtors,
    required List<DayFlowPoint> todayMovements,
  }) =>
      Dashboard(
        currencyCode: currencyCode,
        todayEpochDay: todayEpochDay,
        draftCount: draftCount,
        todaySalesMinor: todaySalesMinor,
        monthSalesMinor: monthSalesMinor,
        monthExpenseMinor: monthExpenseMinor,
        monthProfitMinor: monthProfitMinor,
        receivableMinor: receivableMinor,
        payableMinor: payableMinor,
        cashMinor: cashMinor,
        monthCollectionsMinor: monthCollectionsMinor,
        topDebtors: topDebtors,
        todayMovements: todayMovements,
      );
}

/// One point of a cash series, as a screen renders it.
final class DayFlowPoint {
  const DayFlowPoint({
    required this.epochDay,
    required this.inflowMinor,
    required this.outflowMinor,
    required this.balanceMinor,
  });

  final int epochDay;
  final int inflowMinor;
  final int outflowMinor;
  final int balanceMinor;

  int get netMinor => inflowMinor - outflowMinor;
}

/// A party row, from `v_party_balances`. Named for the screen, not the table:
/// a "party" in this app is a customer, a supplier or an employee.
final class PartyBalance {
  const PartyBalance({
    required this.partyId,
    required this.name,
    required this.kind,
    required this.netMinor,
    required this.receivableMinor,
    required this.payableMinor,
    required this.lineCount,
    this.nameUr,
    this.phone,
    this.lastActivityDate,
    this.isWalkIn = false,
  });

  final String partyId;
  final String name;
  final String? nameUr;

  /// 1 customer · 2 supplier · 3 employee · 4 other.
  final int kind;

  /// Signed: positive means the party owes the business.
  final int netMinor;
  final int receivableMinor;
  final int payableMinor;
  final int lineCount;
  final String? phone;
  final int? lastActivityDate;
  final bool isWalkIn;

  static PartyBalance fromRow(QueryRow row) => PartyBalance(
        partyId: _text(row, 'party_id'),
        name: _text(row, 'name'),
        nameUr: _textOrNull(row, 'name_ur'),
        kind: _int(row, 'kind'),
        netMinor: _int(row, 'net_minor'),
        receivableMinor: _int(row, 'receivable_minor'),
        payableMinor: _int(row, 'payable_minor'),
        lineCount: _int(row, 'line_count'),
        phone: _textOrNull(row, 'phone'),
        lastActivityDate: _intOrNull(row, 'last_activity_date'),
        isWalkIn: _bool(row, 'is_walk_in'),
      );
}

/// One line of a party's ledger, as the pager walks it.
final class LedgerLine {
  const LedgerLine({
    required this.lineId,
    required this.entryId,
    required this.entryNo,
    required this.entryDate,
    required this.amountMinor,
    this.accountName,
    this.memo,
    this.docNo,
  });

  final String lineId;
  final String entryId;
  final String entryNo;
  final int entryDate;
  final int amountMinor;
  final String? accountName;
  final String? memo;
  final String? docNo;

  static LedgerLine fromRow(QueryRow row) => LedgerLine(
        lineId: _text(row, 'line_id'),
        entryId: _text(row, 'entry_id'),
        entryNo: _text(row, 'entry_no'),
        entryDate: _int(row, 'entry_date'),
        amountMinor: _int(row, 'amount_minor'),
        accountName: _textOrNull(row, 'account_name'),
        memo: _textOrNull(row, 'memo'),
        docNo: _textOrNull(row, 'doc_no'),
      );
}

/// A bill or invoice, from `v_document_outstanding`.
final class BillRow {
  const BillRow({
    required this.documentId,
    required this.docKind,
    required this.docNo,
    required this.docDate,
    required this.totalMinor,
    required this.paidMinor,
    required this.balanceMinor,
    required this.status,
    required this.agingBucket,
    required this.daysOverdue,
    this.dueDate,
    this.partyId,
    this.partyName,
    this.partyPhone,
  });

  final String documentId;

  /// 1 sale · 2 purchase · 3 sale return · 4 purchase return (see `DocKind` in the DAO).
  final int docKind;
  final String docNo;
  final int docDate;
  final int? dueDate;
  final int totalMinor;
  final int paidMinor;
  final int balanceMinor;
  final int status;
  final String? partyId;
  final String? partyName;
  final String? partyPhone;

  /// 0 current · 1 1–15 days · 2 16–30 · 3 31–60 · 4 61–90 · 5 over 90.
  final int agingBucket;
  final int daysOverdue;

  bool get isPaid => balanceMinor == 0;

  static BillRow fromRow(QueryRow row) => BillRow(
        documentId: _text(row, 'document_id'),
        docKind: _int(row, 'doc_kind'),
        docNo: _text(row, 'doc_no'),
        docDate: _int(row, 'doc_date'),
        dueDate: _intOrNull(row, 'due_date'),
        totalMinor: _int(row, 'total_minor'),
        paidMinor: _int(row, 'amount_paid_minor'),
        balanceMinor: _int(row, 'balance_minor'),
        status: _int(row, 'status'),
        partyId: _textOrNull(row, 'party_id'),
        partyName: _textOrNull(row, 'party_name'),
        partyPhone: _textOrNull(row, 'party_phone'),
        agingBucket: _intOrNull(row, 'aging_bucket') ?? 0,
        daysOverdue: _int(row, 'days_overdue'),
      );
}

/// A stock line, from `v_stock_on_hand_live`.
final class StockRow {
  const StockRow({
    required this.itemId,
    required this.name,
    required this.quantityMilli,
    required this.valueMinor,
    required this.avgCostMicros,
    required this.salePriceMinor,
    required this.reorderLevelMilli,
    required this.isStocked,
    this.sku,
    this.unit,
    this.barcode,
    this.nameUr,
  });

  final String itemId;
  final String name;
  final String? nameUr;
  final String? sku;
  final String? unit;
  final String? barcode;

  /// Quantity in thousandths, so 1.5 kg is 1500. Integers everywhere: a float quantity
  /// in a stock ledger is a rounding error waiting to be discovered during a stock-take.
  final int quantityMilli;
  final int valueMinor;
  final int avgCostMicros;
  final int salePriceMinor;
  final int reorderLevelMilli;
  final bool isStocked;

  bool get isLow => isStocked && quantityMilli <= reorderLevelMilli;

  static StockRow fromRow(QueryRow row) => StockRow(
        itemId: _text(row, 'item_id'),
        name: _text(row, 'item_name'),
        nameUr: _textOrNull(row, 'name_ur'),
        sku: _textOrNull(row, 'sku'),
        unit: _textOrNull(row, 'unit'),
        barcode: _textOrNull(row, 'barcode'),
        quantityMilli: _int(row, 'quantity_milli'),
        valueMinor: _int(row, 'value_minor'),
        avgCostMicros: _int(row, 'avg_cost_micros'),
        salePriceMinor: _int(row, 'sale_price_minor'),
        reorderLevelMilli: _int(row, 'reorder_level_milli'),
        isStocked: _bool(row, 'is_stocked'),
      );
}

/// One movement of one item.
final class StockMoveRow {
  const StockMoveRow({
    required this.moveId,
    required this.itemId,
    required this.moveDate,
    required this.direction,
    required this.quantityMilli,
    required this.valueMinor,
    this.itemName,
    this.note,
  });

  final String moveId;
  final String itemId;
  final int moveDate;

  /// +1 in, −1 out.
  final int direction;
  final int quantityMilli;
  final int valueMinor;
  final String? itemName;
  final String? note;

  static StockMoveRow fromRow(QueryRow row) => StockMoveRow(
        moveId: _text(row, 'id'),
        itemId: _text(row, 'item_id'),
        moveDate: _int(row, 'move_date'),
        direction: _int(row, 'direction'),
        quantityMilli: _int(row, 'quantity_milli'),
        valueMinor: _int(row, 'value_minor'),
        itemName: _textOrNull(row, 'item_name'),
        note: _textOrNull(row, 'note'),
      );
}

/// A cash account with its balance — the top of the Cash Book.
final class CashAccount {
  const CashAccount({
    required this.accountId,
    required this.name,
    required this.balanceMinor,
    required this.isCash,
    required this.isBank,
    this.code,
  });

  final String accountId;
  final String name;
  final String? code;
  final int balanceMinor;
  final bool isCash;
  final bool isBank;

  static CashAccount fromRow(QueryRow row) => CashAccount(
        accountId: _text(row, 'account_id'),
        name: _text(row, 'name'),
        code: _textOrNull(row, 'code'),
        balanceMinor: _int(row, 'balance_minor'),
        isCash: _bool(row, 'is_cash'),
        isBank: _bool(row, 'is_bank'),
      );
}

/// How the sync and backup machinery is doing, from `v_sync_health`.
final class SyncHealth {
  const SyncHealth({
    required this.pendingOps,
    required this.trustedPeers,
    required this.unreviewedConflicts,
    this.oldestPendingAtMs,
    this.lastSuccessAtMs,
    this.lastBackupAtMs,
  });

  final int pendingOps;
  final int trustedPeers;

  /// Conflicts the CRDT resolver could not decide on its own. They are *not* errors:
  /// they are decisions waiting for a human, and the count is on the dashboard so they
  /// cannot accumulate unnoticed.
  final int unreviewedConflicts;

  final int? oldestPendingAtMs;
  final int? lastSuccessAtMs;
  final int? lastBackupAtMs;

  bool get hasUnsentWork => pendingOps > 0;
  bool get needsReview => unreviewedConflicts > 0;

  static SyncHealth fromRow(QueryRow row) => SyncHealth(
        pendingOps: _int(row, 'pending_ops'),
        trustedPeers: _int(row, 'trusted_peers'),
        unreviewedConflicts: _int(row, 'unreviewed_conflicts'),
        oldestPendingAtMs: _intOrNull(row, 'oldest_pending_at'),
        lastSuccessAtMs: _intOrNull(row, 'last_success_at'),
        lastBackupAtMs: _intOrNull(row, 'last_backup_at'),
      );
}

/// A conflict the resolver could not decide alone, for the review card.
final class ConflictRow {
  const ConflictRow({
    required this.id,
    required this.tableName,
    required this.rowId,
    required this.fieldName,
    required this.kind,
    required this.detectedAtMs,
    this.localNode,
    this.remoteNode,
  });

  final String id;
  final String tableName;
  final String rowId;
  final String fieldName;
  final String kind;
  final int detectedAtMs;
  final String? localNode;
  final String? remoteNode;

  static ConflictRow fromRow(QueryRow row) => ConflictRow(
        id: _text(row, 'id'),
        tableName: _text(row, 'table_name'),
        rowId: _text(row, 'row_id'),
        fieldName: _text(row, 'field_name'),
        kind: _text(row, 'kind'),
        detectedAtMs: _int(row, 'detected_at'),
        localNode: _textOrNull(row, 'local_node'),
        remoteNode: _textOrNull(row, 'remote_node'),
      );
}

// ── the read library ─────────────────────────────────────────────────────────

/// Every read the UI performs. An extension rather than a wrapper class: there is no
/// state to hold, and a screen that needs a number should be able to ask the database
/// directly without a ceremony of injection.
extension UiQueries on KhataDatabase {
  /// Runs [sql] now, parsing each row with [parse].
  Future<List<T>> readAll<T>(String sql, List<Variable> args, T Function(QueryRow) parse) async {
    final rows = await customSelect(sql, variables: args).get();
    return [for (final row in rows) parse(row)];
  }

  /// Runs [sql] now, parsing the single row it must produce.
  Future<T?> readOne<T>(String sql, List<Variable> args, T Function(QueryRow) parse) async {
    final row = await customSelect(sql, variables: args).getSingleOrNull();
    return row == null ? null : parse(row);
  }

  /// A live version of [sql]: the initial result, then one re-fetch per coalesced change
  /// signal (see `changes.dart` for why Drift is not doing this for us).
  ///
  /// The re-fetch reads **all** rows again rather than patching the last result. For a
  /// dashboard that is one row and for a party list a few hundred; and a screen that
  /// rebuilds from a fresh read cannot drift out of sync with the database the way an
  /// incrementally-patched list can. Streaming pagination is what the ledger does, and
  /// that is a different mechanism (`LedgerSource`) for exactly this reason.
  Stream<List<T>> watchAll<T>(
    String sql,
    T Function(QueryRow) parse, {
    List<Variable> args = const [],
    required Stream<int> changes,
  }) async* {
    yield await readAll(sql, args, parse);
    await for (final _ in changes) {
      yield await readAll(sql, args, parse);
    }
  }

  /// A live single row. Emits `null` when the query legitimately returns nothing — an
  /// empty ledger, a database that has not been seeded — rather than throwing.
  Stream<T?> watchOne<T>(
    String sql,
    T Function(QueryRow) parse, {
    List<Variable> args = const [],
    required Stream<int> changes,
  }) async* {
    yield await readOne(sql, args, parse);
    await for (final _ in changes) {
      yield await readOne(sql, args, parse);
    }
  }
}

/// The SQL. Named constants rather than inline strings so that `docs/UI.md` can point at
/// one place, and so a query that turns out to be slow is a one-line change.
abstract final class UiSql {
  /// The dashboard, in one row. `ledgerId` is bound twice because the view is not
  /// filtered on it (there is exactly one ledger per install today, and the view was
  /// written for the multi-business case).
  static const String dashboard = '''
SELECT d.currency_code,
       d.today_epoch_day,
       d.draft_count,
       d.today_sales_minor,
       d.month_sales_minor,
       d.month_expense_minor,
       d.month_profit_minor,
       d.receivable_minor,
       d.payable_minor,
       d.cash_minor,
       COALESCE((
         SELECT SUM(ab.net_minor * a.normal_balance)
           FROM account_balances ab JOIN accounts a ON a.id = ab.account_id
          WHERE ab.ledger_id = ? AND ab.period_id = 0 AND a.role = 'ar'
            AND ab.updated_at >= (SELECT (SELECT month_start FROM v_now) * 86400000)
       ), 0) AS month_collections_minor
  FROM v_dashboard_metrics d
 WHERE d.ledger_id = ?
 LIMIT 1''';

  /// Who to chase: the parties who owe the most, newest activity first among equals.
  static const String topDebtors = '''
SELECT party_id, name, name_ur, kind, phone, is_walk_in,
       net_minor, receivable_minor, payable_minor, line_count, last_activity_date
  FROM v_party_balances
 WHERE ledger_id = ? AND receivable_minor > 0 AND is_walk_in = 0
 ORDER BY receivable_minor DESC, last_activity_date DESC
 LIMIT ?''';

  /// The party list. Ordered by *absolute* balance so a big payable is as visible as a
  /// big receivable — a shopkeeper chasing customers also needs to know who to pay.
  static const String parties = '''
SELECT party_id, name, name_ur, kind, phone, is_walk_in,
       net_minor, receivable_minor, payable_minor, line_count, last_activity_date
  FROM v_party_balances
 WHERE ledger_id = ? AND is_walk_in = 0 AND (? = 0 OR kind = ?)
 ORDER BY ABS(net_minor) DESC, name COLLATE NOCASE
 LIMIT ? OFFSET ?''';

  /// One page of a party's ledger, newest first, **keyset** rather than offset.
  ///
  /// `AND (? IS NULL OR ...)` is the cursor: on the first page the argument is NULL and
  /// the whole ledger is in scope; afterwards it is the (date, line id) of the last row
  /// the caller has. Keyset paging keeps each page O(page) — an `OFFSET 95000` would make
  /// SQLite walk 95 000 rows to throw them away, which is the difference between a
  /// ledger that scrolls and one that stutters.
  /// The cursor binds four times: the date twice and the line id twice, because SQLite
  /// has no way to name a bound parameter twice (`?1` is a numbering feature of some
  /// drivers, not of this API) — so the Dart side passes each value again rather than the
  /// query growing a `WITH` clause to hold it.
  static const String partyLedger = '''
SELECT line_id, entry_id, entry_no, entry_date, amount_minor, account_name, memo, doc_no
  FROM v_party_ledger
 WHERE ledger_id = ? AND party_id = ?
   AND (? IS NULL OR entry_date < ? OR (entry_date = ? AND line_id < ?))
 ORDER BY entry_date DESC, line_id DESC
 LIMIT ?''';

  /// The cash accounts and what is in them, from the live balance view (posted entries
  /// only — a draft is invisible to a cash report, which is the schema's whole contract).
  static const String cashAccounts = '''
SELECT ab.account_id, a.code, a.name, ab.net_minor * a.normal_balance AS balance_minor,
       a.is_cash, a.is_bank
  FROM account_balances ab
  JOIN accounts a ON a.id = ab.account_id AND a.is_postable = 1
 WHERE ab.ledger_id = ? AND ab.period_id = 0 AND (a.is_cash = 1 OR a.is_bank = 1)
 ORDER BY a.is_cash DESC, a.code''';

  /// Daily cash movement over a window, from `v_daily_cashflow` — one row per cash
  /// account per day, which the Dart layer folds into one series.
  static const String cashFlowRows = '''
SELECT entry_date AS epoch_day,
       COALESCE(SUM(inflow_minor), 0)  AS inflow_minor,
       COALESCE(SUM(outflow_minor), 0) AS outflow_minor
  FROM v_daily_cashflow
 WHERE ledger_id = ? AND entry_date BETWEEN ? AND ?
 GROUP BY entry_date
 ORDER BY entry_date''';

  /// The Cash Book's transaction list: every posted line that touched a cash or bank
  /// account, newest first. This is the "rozana" screen — what actually happened today.
  static const String cashBook = '''
SELECT l.id AS line_id, l.entry_id, e.entry_no, l.entry_date,
       l.amount_minor, a.name AS account_name, e.memo, e.doc_no
  FROM journal_lines l
  JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1
  JOIN accounts a ON a.id = l.account_id
 WHERE l.ledger_id = ? AND (a.is_cash = 1 OR a.is_bank = 1)
   AND (? = 0 OR l.entry_date >= ?) AND (? = 0 OR l.entry_date <= ?)
 ORDER BY l.entry_date DESC, e.created_at DESC, l.id DESC
 LIMIT ?''';

  /// Unpaid and partly paid bills, most overdue first.
  static const String bills = '''
SELECT document_id, doc_kind, doc_no, doc_date, due_date, status,
       party_id, party_name, party_phone,
       total_minor, amount_paid_minor, balance_minor,
       days_overdue, COALESCE(aging_bucket, 0) AS aging_bucket
  FROM v_document_outstanding
 WHERE ledger_id = ? AND balance_minor > 0 AND (? = 0 OR doc_kind = ?)
 ORDER BY days_overdue DESC, due_date, doc_no
 LIMIT ?''';

  /// Stock on hand, low stock first so the re-order list is the top of the screen.
  static const String stock = '''
-- `v_stock_on_hand_live` has no `name_ur`: it exposes `item_name`, and the Urdu name is
-- not in the view. Selecting a column that does not exist is a runtime error with no
-- compile-time warning (the SQL is a string), which is why `tool/ui_db_verify.dart`
-- runs every one of these queries against a real database — it found this one.
SELECT item_id, item_name, sku, unit, barcode, quantity_milli, value_minor,
       avg_cost_micros, sale_price_minor, reorder_level_milli, is_stocked
  FROM v_stock_on_hand_live
 WHERE ledger_id = ?
   AND (? = 0 OR is_active = 1)
   AND (? = 0 OR (is_stocked = 1 AND quantity_milli <= reorder_level_milli))
 ORDER BY (is_stocked = 1 AND quantity_milli <= reorder_level_milli) DESC,
          item_name COLLATE NOCASE
 LIMIT ?''';

  /// Recent stock movements for one item — the "where did it go" screen.
  static const String stockMoves = '''
SELECT m.id, m.item_id, m.move_date, m.direction, m.quantity_milli, m.value_minor,
       i.name AS item_name, m.note
  FROM stock_moves m
  JOIN items i ON i.id = m.item_id
 WHERE m.ledger_id = ? AND (? = '' OR m.item_id = ?)
 ORDER BY m.move_date DESC, m.created_at DESC
 LIMIT ?''';

  /// Employees, with what is still owed to them (a credit balance on an employee's
  /// sub-ledger is unpaid wages).
  static const String staff = '''
SELECT party_id, name, name_ur, kind, phone, is_walk_in,
       net_minor, receivable_minor, payable_minor, line_count, last_activity_date
  FROM v_party_balances
 WHERE ledger_id = ? AND kind = 3 AND is_walk_in = 0
 ORDER BY payable_minor DESC, name COLLATE NOCASE
 LIMIT ?''';

  static const String syncHealth = '''
SELECT pending_ops, oldest_pending_at, trusted_peers, last_success_at,
       unreviewed_conflicts, last_backup_at
  FROM v_sync_health''';

  static const String conflicts = '''
SELECT id, table_name, row_id, field_name, kind, local_node, remote_node, detected_at
  FROM conflict_log
 WHERE reviewed_at IS NULL AND (? = '' OR kind = ?)
 ORDER BY detected_at DESC
 LIMIT ?''';

  /// A draft: an entry that exists but is not in the books. The banner that shows this
  /// saves a shopkeeper from losing work they forgot about.
  static const String drafts = '''
SELECT e.id, e.entry_no, e.entry_date, e.memo, e.source,
       COALESCE((SELECT SUM(CASE WHEN l.amount_minor > 0 THEN l.amount_minor ELSE 0 END)
                   FROM journal_lines l WHERE l.entry_id = e.id), 0) AS total_minor
  FROM journal_entries e
 WHERE e.ledger_id = ? AND e.status = 0
 ORDER BY e.entry_date DESC, e.created_at DESC
 LIMIT ?''';

  static const String ledgerIdentity = '''
SELECT id AS ledger_id, name, base_currency FROM ledgers LIMIT 1''';

  static const String today = 'SELECT today_epoch_day, month_start FROM v_now';
}

/// The epoch day the books consider "today".
///
/// Deliberately *not* `DateTime.now()`: a shopkeeper who is catching up on yesterday's
/// entries, or a device whose clock is wrong by a day, must not have today's sales
/// attributed to the wrong day. `session_flags` can pin the business day, and the view
/// falls back to the device clock only when nobody has.
abstract final class BusinessDay {
  static int startOfMonth(int epochDay) => EpochDay.startOfMonth(epochDay);

  static int weeksAgo(int epochDay, int weeks) => epochDay - weeks * 7;

  static int daysAgo(int epochDay, int days) => epochDay - days;
}
