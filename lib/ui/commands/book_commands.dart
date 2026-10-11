/// KhataPro · the write side, in one object.
///
/// Every screen's "save" goes through here, and nothing else in the widget layer constructs
/// an `OrderBook`. Three reasons, in order of importance:
///
/// 1. **The gate's refusal is a result, not an exception the UI forgets.** `OrderBook` writes
///    inside a transaction with `GateRunner.verify()` and rolls the whole thing back if the
///    books would end up inconsistent. That refusal is *correct behaviour* — a shopkeeper must
///    see "this entry would break your books; nothing was saved" and not a red screen or,
///    worse, a silently missing entry. So every method here returns [CommandOutcome]:
///    either the receipt (with the entry number, so the user can see the number their new
///    entry got) or the refusal's own sentence.
/// 2. **One receipt, one message.** The entry number, the amount and any warning the gate
///    raised are assembled once, with the user's own money format — not re-formatted
///    per screen, which is how two screens end up showing the same amount differently.
/// 3. **The change signal is not this file's job.** Writes reach the UI through
///    `KhataDatabase.changeSink` → `ChangeBus` → the providers. A command that also poked a
///    provider would double-notify, and a command that *forgot* to would leave the screen
///    stale — so it does neither. `tool/ui_db_verify.dart` asserts exactly this: a write
///    changes the screens with no manual bump anywhere.
///
/// 4. **It is pure Dart on purpose.** No import of `flutter/material.dart` appears in this
///    file, so `tool/ui_commands_verify.dart` can drive the real commands against a real
///    SQLCipher file in the sandbox, where there is no Flutter engine. The one thing that
///    needs a `BuildContext` — the toast that shows an outcome — lives in
///    `lib/ui/widgets/outcome_toast.dart`. Splitting on that line is what makes the write
///    path verifiable at all.
///
/// ## What is *not* here
///
/// Nothing imports the sync or backup layers. Posting an entry is a local transaction; the
/// op-log row that `OrderBook` writes is what a later sync exchanges. A save button that
/// waited for the network would be a save button that fails in a shop with no signal, which
/// is the entire use case this app exists for.
library;

import 'package:drift/drift.dart' show Variable;
import 'package:riverpod/riverpod.dart';

import '../../core/errors/khata_exception.dart';
import '../../data/db/dao/base_dao.dart' show AccountRole, DocKind;
import '../../data/db/dao/parties_dao.dart';
import '../../data/db/database.dart';
import '../../data/repositories/order_book.dart';
import '../format/formatting.dart';
import '../state/providers.dart';
import '../state/queries.dart' show UiQueries;

/// The result of a write attempt.
final class CommandOutcome {
  const CommandOutcome._({
    required this.ok,
    required this.message,
    this.entryNo,
    this.documentId,
    this.documentNo,
    this.warnings = const [],
    this.code,
  });

  /// The entry was posted (or the part was created).
  factory CommandOutcome.posted({
    required String message,
    String? entryNo,
    String? documentId,
    String? documentNo,
    List<String> warnings = const [],
  }) =>
      CommandOutcome._(
        ok: true,
        message: message,
        entryNo: entryNo,
        documentId: documentId,
        documentNo: documentNo,
        warnings: warnings,
      );

  /// Nothing changed: the database refused the write and rolled it back.
  factory CommandOutcome.refused({required String message, String? code}) =>
      CommandOutcome._(ok: false, message: message, code: code);

  final bool ok;
  final String message;

  /// The number the books gave the new journal entry (`JE-0007`). Every money-moving write
  /// gets one, and two writes never share one — so it is what a support conversation is
  /// keyed on.
  final String? entryNo;

  /// The document row this write created or settled, for a screen that wants to open it.
  final String? documentId;

  /// The document's own number (`INV-0007`), which is the number a shopkeeper writes on the
  /// paper bill and the one a reminder quotes. It is *not* [entryNo]: a document and the
  /// journal entry that carries it are numbered by two independent sequences, deliberately —
  /// a device that has never seen this invoice still gets the next `INV` number right
  /// (`number_sequences` is keyed by node, see `docs/DATA_LAYER.md`).
  final String? documentNo;

  /// Gate findings that are warnings rather than refusals — surfaced, never swallowed.
  final List<String> warnings;

  /// The invariant code, when the refusal came from the books rather than from a form.
  final String? code;
}

/// The write side.
///
/// Immutable: it holds a database handle and a ledger id, and every method is a transaction
/// of its own. A command object that cached state between saves would be the place a stale
/// balance crept into an entry.
final class BookCommands {
  const BookCommands({required this.db, required this.ledgerId});

  final KhataDatabase db;
  final String ledgerId;

  OrderBook get _book => OrderBook(db: db, ledgerId: ledgerId);

  /// A cash (or part-cash) sale: goods out of the shop, money in the drawer.
  ///
  /// `grossMinor` is the gross total including tax; `amountPaidMinor` is what actually
  /// changed hands, and the remainder becomes a receivable against `partyId` — which the
  /// books refuse to guess, so a credit sale without a party is a refusal, not a walk-in
  /// sale with a mysterious debt.
  Future<CommandOutcome> recordSale({
    required int entryDate,
    required int grossMinor,
    required int amountPaidMinor,
    required MoneyFormat money,
    String? partyId,
    int taxMinor = 0,
    String? docNo,
    String? memo,
  }) async {
    return _run(
      money: money,
      action: () => _book.postSale(
        entryDate: entryDate,
        grossMinor: grossMinor,
        amountPaidMinor: amountPaidMinor,
        partyId: partyId,
        memo: memo,
        docNo: docNo,
      ),
      describe: (receipt) => 'Sale recorded · ${money.format(receipt.totalMinor)}',
    );
  }

  /// A credit sale with a document behind it: this is what the bill book, the aging report
  /// and an SMS reminder all read. Use this one when the goods leave on credit.
  ///
  /// **Sales documents only.** A supplier bill has its own command ([recordBill]) because the
  /// journal is not the same journal: a sale credits revenue, a bill debits inventory. Routing
  /// a `purchaseBill` through here would post revenue for something the shop bought — the kind
  /// of number that reconciles to a plausible total and is wrong in every line — so the
  /// command refuses the doc kind rather than trusting its caller.
  Future<CommandOutcome> recordInvoice({
    required int entryDate,
    required int grossMinor,
    required int amountPaidMinor,
    required String partyId,
    required MoneyFormat money,
    int docKind = DocKind.saleInvoice,
    int? dueDate,
    int taxMinor = 0,
    String? docNo,
    String? memo,
  }) async {
    if (docKind != DocKind.saleInvoice) {
      return CommandOutcome.refused(
        message: 'A supplier bill is not a sale: use the bill form, which posts the purchase '
            'to what you owe your supplier instead of to your sales.',
        code: 'APP-2',
      );
    }
    return _run(
      money: money,
      action: () => _book.postInvoice(
        entryDate: entryDate,
        grossMinor: grossMinor,
        amountPaidMinor: amountPaidMinor,
        partyId: partyId,
        docKind: docKind,
        dueDate: dueDate,
        taxMinor: taxMinor,
        docNo: docNo,
        memo: memo,
      ),
      describe: (receipt) {
        final total = money.format(receipt.totalMinor);
        final no = receipt.documentId == null ? null : receipt.entryNo;
        return no == null ? 'Invoice recorded · $total' : 'Invoice $no · $total';
      },
      documentNoOf: _docNo,
    );
  }

  /// Settles an existing document: the payment is allocated against that bill, which is what
  /// moves it out of the aging buckets.
  Future<CommandOutcome> settleInvoice({
    required int entryDate,
    required int amountMinor,
    required String documentId,
    required MoneyFormat money,
    bool toBank = false,
    String? memo,
  }) async {
    return _run(
      money: money,
      action: () => _book.settleInvoice(
        entryDate: entryDate,
        amountMinor: amountMinor,
        documentId: documentId,
        toBank: toBank,
        memo: memo,
      ),
      describe: (receipt) =>
          'Payment recorded · ${money.format(receipt.totalMinor)}${toBank ? ' · bank' : ''}',
      // The settled invoice, not the payment entry. `settleInvoice` returns the receipt of
      // the *payment* entry it posted inside the allocation, and that receipt has no document
      // of its own — so the id the caller handed in is the one to name.
      documentOverride: documentId,
      documentNoOf: _docNo,
    );
  }

  /// Money received from a party without naming a document — the "he paid me 5 000" case.
  Future<CommandOutcome> recordReceipt({
    required int entryDate,
    required int amountMinor,
    required String partyId,
    required MoneyFormat money,
    bool toBank = false,
    String? memo,
  }) async {
    return _run(
      money: money,
      action: () => _book.postPaymentIn(
        entryDate: entryDate,
        amountMinor: amountMinor,
        partyId: partyId,
        toBank: toBank,
        memo: memo,
      ),
      describe: (receipt) => 'Received · ${money.format(receipt.totalMinor)}',
    );
  }

  /// An expense paid from the drawer or the bank.
  Future<CommandOutcome> recordExpense({
    required int entryDate,
    required int amountMinor,
    required MoneyFormat money,
    String role = AccountRole.miscExpense,
    bool fromBank = false,
    String? memo,
  }) async {
    return _run(
      money: money,
      action: () => _book.postExpense(
        entryDate: entryDate,
        amountMinor: amountMinor,
        role: role,
        fromBank: fromBank,
        memo: memo,
      ),
      describe: (receipt) => 'Expense recorded · ${money.format(receipt.totalMinor)}',
    );
  }

  /// A supplier bill: goods or services in, money owed out.
  ///
  /// [debitRole] is what was received — `inventory` by default, an expense role for a service
  /// (a rickshaw fare, an electricity bill). The distinction lives in the chart of accounts, so
  /// the stock screen and the expense report both stay right.
  Future<CommandOutcome> recordBill({
    required int entryDate,
    required int grossMinor,
    required int amountPaidMinor,
    required String partyId,
    required MoneyFormat money,
    int docKind = DocKind.purchaseBill,
    int taxMinor = 0,
    int? dueDate,
    String debitRole = AccountRole.inventory,
    bool fromBank = false,
    String? docNo,
    String? memo,
  }) async {
    return _run(
      money: money,
      action: () => _book.postBill(
        entryDate: entryDate,
        grossMinor: grossMinor,
        amountPaidMinor: amountPaidMinor,
        partyId: partyId,
        taxMinor: taxMinor,
        docKind: docKind,
        dueDate: dueDate,
        debitRole: debitRole,
        fromBank: fromBank,
        docNo: docNo,
        memo: memo,
      ),
      describe: (receipt) {
        final total = money.format(receipt.totalMinor);
        final no = receipt.entryNo;
        return 'Bill $no · $total';
      },
      documentNoOf: _docNo,
    );
  }

  /// Pays a supplier bill — money out, allocated against that bill.
  Future<CommandOutcome> settleBill({
    required int entryDate,
    required int amountMinor,
    required String documentId,
    required MoneyFormat money,
    bool fromBank = false,
    String? memo,
  }) async {
    return _run(
      money: money,
      action: () => _book.settleBill(
        entryDate: entryDate,
        amountMinor: amountMinor,
        documentId: documentId,
        fromBank: fromBank,
        memo: memo,
      ),
      describe: (receipt) =>
          'Paid ${money.format(receipt.totalMinor)}${fromBank ? ' by bank' : ' from the till'}',
      documentOverride: documentId,
      documentNoOf: _docNo,
    );
  }

  /// Creates a party. There is no journal entry in this one, so it has no receipt — but it is
  /// still a write that must land in the op-log for a peer to see, which is why it goes
  /// through the DAO rather than a bare INSERT.
  Future<CommandOutcome> addParty({
    required String name,
    required MoneyFormat money,
    String? nameUr,
    String? phone,
    int kind = PartyKind.customer,
  }) async {
    try {
      final parties = PartiesDao(db: db, ledgerId: ledgerId);
      final id = await parties.create(
        PartyDraft(name: name, nameUr: nameUr, phone: phone, kind: kind),
      );
      return CommandOutcome.posted(message: '$name added', documentId: id);
    } on KhataException catch (error) {
      return CommandOutcome.refused(message: error.message, code: error.code);
    } on Object catch (error) {
      return CommandOutcome.refused(
        message: 'This could not be saved: $error',
        code: 'APP-1',
      );
    }
  }

  /// Folds a document number into the message the user reads, without ever printing the same
  /// number twice: the journal-entry number is the fallback when there is no document.
  ///
  /// The fallback matters — a receipt that says nothing at all would leave the user unable to
  /// quote anything, and `JE-0012` is still traceable in the journal.
  static String _withDocumentNo(String message, String? documentNo, String? entryNo) {
    final number = documentNo ?? entryNo;
    if (number == null || message.contains(number)) return message;
    return '$message · $number';
  }

  /// The full integrity sweep, for the "check my books" button.
  ///
  /// Deliberately *not* wrapped in a [CommandOutcome]: nothing is written, the report *is* the
  /// answer, and every finding carries the severity the schema assigned it. A refusal shape
  /// here would flatten fifteen critical classes into one sentence.
  Future<CommitReport> audit({CommitCheck check = CommitCheck.full}) => _book.audit(check: check);

  /// Rebuilds every cached total from the journal.
  ///
  /// The one repair action that is always safe: the caches are derived, the journal is the
  /// truth, and a restore from a backup is the case where they can drift.
  Future<void> rebuildCaches() => _book.rebuildCaches();

  /// The document number behind an id, for the toast. One indexed read, after the write has
  /// already committed — never inside the transaction, where it would extend the lock for a
  /// string the user is about to read.
  Future<String?> _docNo(String documentId) => db.readOne<String>(
        'SELECT doc_no FROM documents WHERE id = ?',
        [Variable<String>(documentId)],
        (row) => '${row.data['doc_no']}',
      );

  /// The shared tail of every money-moving command: run it, translate the outcome, and never
  /// let an exception escape into a callback where Flutter would report it as an unhandled
  /// framework error with no user-visible consequence.
  Future<CommandOutcome> _run({
    required MoneyFormat money,
    required Future<OrderReceipt> Function() action,
    required String Function(OrderReceipt receipt) describe,
    String? documentOverride,
    Future<String?> Function(String documentId)? documentNoOf,
  }) async {
    try {
      final receipt = await action();
      final documentId = documentOverride ?? receipt.documentId;
      final documentNo = documentId == null || documentNoOf == null
          ? null
          : await documentNoOf(documentId);
      final warnings = [
        for (final finding in receipt.commit.findings)
          '${finding.isCritical ? 'Refused' : 'Check'}: ${finding.detail}',
      ];
      return CommandOutcome.posted(
        message: _withDocumentNo(describe(receipt), documentNo, receipt.entryNo),
        entryNo: receipt.entryNo,
        documentId: documentId,
        documentNo: documentNo,
        warnings: warnings,
      );
    } on InvariantViolation catch (error) {
      // The gate's own sentence. `008_integrity.sql` writes these for a human, and rewriting
      // them here would lose the invariant code the user can quote to support.
      return CommandOutcome.refused(
        message: error.message,
        code: error.invariantCode,
      );
    } on KhataException catch (error) {
      return CommandOutcome.refused(message: error.message, code: error.code);
    } on Object catch (error) {
      // A bug, not a refusal — and saying so is better than a screen that pretends the entry
      // was saved when it was not.
      return CommandOutcome.refused(
        message: 'This entry was not saved ($error). Nothing has changed — please report '
            'this with the time it happened.',
        code: 'APP-1',
      );
    }
  }
}

/// The commands for the open book, or null while the ledger id is still being read.
///
/// Nullable rather than throwing, because there is a real moment at boot where the book is
/// open but `ledgers.id` has not been fetched yet: a save button must be *disabled* then,
/// not crash. `ref.watch(ledgerIdProvider)` is a `FutureProvider`, so the first frame after
/// the open genuinely has no value.
final bookCommandsProvider = Provider<BookCommands?>((ref) {
  final ledgerId = ref.watch(ledgerIdProvider).value;
  if (ledgerId == null) return null;
  return BookCommands(db: ref.watch(databaseProvider), ledgerId: ledgerId);
});
